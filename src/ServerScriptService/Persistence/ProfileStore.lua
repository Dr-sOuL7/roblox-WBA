--[=[
	ProfileStore.lua
	DataStore adapter for player profiles. Thin by design — all decisions live
	in ProfileLogic (pure, headless-tested); this file only talks to Roblox.

	Engineering per plan §23 Save Architecture:
	  * Session locking via UpdateAsync arbitration (steal only stale locks)
	  * Retry with exponential backoff on DataStore failures
	  * Periodic autosave (refreshes the session lock)
	  * BindToClose flush
	  * Versioned schema with forward-migration; NEVER writes over data from a
	    newer schema version (returns "newer-version" instead)
	  * Studio-without-API fallback: in-memory mock store with a loud warning

	Lock contention policy: if another live server holds the lock after
	retries, the caller kicks the player. Kicking is ugly; silently running
	two writable sessions and losing one of them is uglier.
]=]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local ProfileLogic = require(script.Parent:WaitForChild("ProfileLogic"))
local ProfileSchema = require(script.Parent:WaitForChild("ProfileSchema"))

local STORE_NAME = "PlayerProfiles"
local KEY_PREFIX = "p_"
local AUTOSAVE_INTERVAL = 60 -- seconds; must stay well under ProfileLogic.LOCK_TIMEOUT_SECONDS
local LOAD_LOCK_RETRIES = 3  -- extra rounds waiting for a foreign lock to clear

-- JobId is "" in Studio; the GUID suffix keeps lock identity unique anyway.
local SESSION_ID = game.JobId .. "-" .. HttpService:GenerateGUID(false)

local ProfileStore = {}

local _profiles = {} -- userId -> { data, version, dirty, released }
local _useMock = false
local _mockData = {} -- key -> envelope (Studio fallback)
local _dataStore = nil

local function getDataStore()
	if not _dataStore then
		_dataStore = DataStoreService:GetDataStore(STORE_NAME)
	end
	return _dataStore
end

-- ── Store access with retry + Studio fallback ─────────────────────────────────

local function mockUpdateAsync(key, transform)
	local current = ProfileLogic.deepCopy(_mockData[key])
	local result = transform(current)
	if result ~= nil then
		_mockData[key] = result
	end
	return result
end

local function updateWithRetry(key, transform)
	if _useMock then
		return true, mockUpdateAsync(key, transform)
	end

	local attempt = 1
	while true do
		local ok, result = pcall(function()
			return getDataStore():UpdateAsync(key, transform)
		end)
		if ok then
			return true, result
		end

		if string.find(tostring(result), "Studio", 1, true) then
			warn("[ProfileStore] DataStores unavailable in Studio — using IN-MEMORY mock. Nothing will persist.")
			_useMock = true
			return true, mockUpdateAsync(key, transform)
		end

		local delay = ProfileLogic.backoffDelay(attempt)
		if not delay then
			warn(string.format("[ProfileStore] UpdateAsync failed after %d attempts for %s: %s",
				attempt, key, tostring(result)))
			return false, nil
		end
		warn(string.format("[ProfileStore] UpdateAsync attempt %d failed for %s (%s); retrying in %ds",
			attempt, key, tostring(result), delay))
		task.wait(delay)
		attempt += 1
	end
end

-- ── Envelope transforms ───────────────────────────────────────────────────────

local function newEnvelope()
	return {
		schemaVersion = ProfileSchema.SCHEMA_VERSION,
		data = ProfileSchema.defaults(),
		lock = nil,
		lastSaved = 0,
		pending = nil, -- offline adjustments awaiting the owning session
	}
end

-- Attempts one lock-acquiring load pass. Returns (decision, envelope).
local function tryAcquire(key)
	local decision = nil
	local ok, envelope = updateWithRetry(key, function(stored)
		stored = stored or newEnvelope()

		if (stored.schemaVersion or 1) > ProfileSchema.SCHEMA_VERSION then
			decision = "newer-version"
			return nil -- never touch data from a newer server build
		end

		decision = ProfileLogic.arbitrateLock(stored.lock, SESSION_ID, os.time())
		if decision == "held" then
			return nil
		end

		-- Consume offline adjustments atomically with taking the lock
		local _, remaining = ProfileLogic.applyPending(stored.data, stored.pending)
		stored.pending = (#remaining > 0) and remaining or nil

		stored.lock = ProfileLogic.makeLock(SESSION_ID, os.time())
		return stored
	end)

	if not ok then
		return "error", nil
	end
	return decision, envelope
end

-- ── Public API ────────────────────────────────────────────────────────────────

--[=[
	Load (or get cached) profile for userId. Yields. Returns (data, failReason).
	failReason: "held" (live session elsewhere), "newer-version", "error".
]=]
function ProfileStore.LoadProfile(userId)
	local cached = _profiles[userId]
	if cached and not cached.released then
		return cached.data, nil
	end

	local key = KEY_PREFIX .. tostring(userId)

	for round = 1, 1 + LOAD_LOCK_RETRIES do
		local decision, envelope = tryAcquire(key)

		if decision == "acquire" or decision == "steal" then
			if decision == "steal" then
				warn(string.format("[ProfileStore] Stole stale session lock for user %s", tostring(userId)))
			end
			local data, version = ProfileLogic.migrate(
				envelope.data,
				envelope.schemaVersion or 1,
				ProfileSchema.SCHEMA_VERSION,
				ProfileSchema.MIGRATIONS
			)
			ProfileLogic.reconcile(data, ProfileSchema.defaults())
			_profiles[userId] = { data = data, version = version, dirty = false, released = false }
			return data, nil
		elseif decision == "held" then
			-- The other server may be mid-shutdown; give its BindToClose a chance
			if round <= LOAD_LOCK_RETRIES then
				task.wait(2 * round)
			end
		else
			return nil, decision -- "newer-version" | "error"
		end
	end

	return nil, "held"
end

function ProfileStore.GetProfile(userId)
	local entry = _profiles[userId]
	if entry and not entry.released then
		return entry.data
	end
	return nil
end

--[=[
	Mutate a loaded profile through a function. The ONLY sanctioned write path —
	server modules never hold long-lived references into profile data.
	Returns true if applied (profile was loaded).
]=]
function ProfileStore.UpdateProfile(userId, mutator)
	local entry = _profiles[userId]
	if not entry or entry.released then
		return false
	end
	mutator(entry.data)
	entry.dirty = true
	return true
end

-- Persist one profile. `release` also clears the session lock.
local function saveProfile(userId, release)
	local entry = _profiles[userId]
	if not entry then
		return false
	end

	local key = KEY_PREFIX .. tostring(userId)
	local lostLock = false

	local ok = updateWithRetry(key, function(stored)
		stored = stored or newEnvelope()

		-- Respect a legitimate steal: if a live foreign session owns the lock
		-- now, our copy is stale — drop the write rather than clobber.
		if stored.lock and stored.lock.jobId ~= SESSION_ID then
			local age = os.time() - stored.lock.timestamp
			if age <= ProfileLogic.LOCK_TIMEOUT_SECONDS then
				lostLock = true
				return nil
			end
		end

		-- Adjustments appended while we held the cache are consumed into OUR
		-- copy inside this same transform — the full-envelope write below can
		-- neither lose them nor apply them twice.
		local _, remaining = ProfileLogic.applyPending(entry.data, stored.pending)

		stored.schemaVersion = entry.version
		stored.data = entry.data
		stored.lastSaved = os.time()
		stored.pending = (#remaining > 0) and remaining or nil
		-- NOT `release and nil or ...`: and-or collapses a nil first branch
		stored.lock = if release then nil else ProfileLogic.makeLock(SESSION_ID, os.time())
		return stored
	end)

	if lostLock then
		warn(string.format("[ProfileStore] Lock for user %s was taken by another live session; local changes dropped", tostring(userId)))
	end
	if ok and not lostLock then
		entry.dirty = false
	end
	if release then
		entry.released = true
		_profiles[userId] = nil
	end
	return ok and not lostLock
end

function ProfileStore.SaveProfile(userId)
	return saveProfile(userId, false)
end

--[=[
	Write to a profile that may not be loaded here. Loaded → applied through
	the normal cached path. Not loaded → appended to the stored envelope's
	pending list (a minimal merge that never touches data or the lock); the
	owning session consumes it atomically. Yields. Returns true on success.
]=]
function ProfileStore.QueueOfflineAdjustment(userId, adjustment)
	local entry = _profiles[userId]
	if entry and not entry.released then
		ProfileLogic.applyPending(entry.data, { adjustment })
		entry.dirty = true
		return true
	end

	local key = KEY_PREFIX .. tostring(userId)
	local ok = updateWithRetry(key, function(stored)
		stored = stored or newEnvelope()
		stored.pending = stored.pending or {}
		table.insert(stored.pending, adjustment)
		return stored
	end)
	return ok
end

-- Save + unlock on leave. Yields.
function ProfileStore.ReleaseProfile(userId)
	if not _profiles[userId] then
		return
	end
	saveProfile(userId, true)
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

-- Autosave: persists dirty profiles and refreshes session locks (a lock left
-- unrefreshed past LOCK_TIMEOUT_SECONDS becomes stealable).
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for userId, entry in pairs(_profiles) do
			if not entry.released then
				saveProfile(userId, false)
			end
		end
	end
end)

game:BindToClose(function()
	local pending = 0
	for userId, entry in pairs(_profiles) do
		if not entry.released then
			pending += 1
			task.spawn(function()
				saveProfile(userId, true)
				pending -= 1
			end)
		end
	end
	local deadline = os.clock() + 25 -- BindToClose budget is 30 s
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end)

-- Standard kick messages so callers stay consistent
ProfileStore.FAIL_MESSAGES = {
	["held"] = "Your data is still saving on another server. Please rejoin in a minute.",
	["newer-version"] = "This server is running an older version. Please join a different server.",
	["error"] = "Your data could not be loaded safely. Please rejoin.",
}

function ProfileStore.KickForFailure(userId, reason)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		player:Kick(ProfileStore.FAIL_MESSAGES[reason] or ProfileStore.FAIL_MESSAGES.error)
	end
end

return ProfileStore
