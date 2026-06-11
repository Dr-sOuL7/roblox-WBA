--[=[
	ProfileLogic.lua
	Pure decision logic for the persistence layer: session-lock arbitration,
	schema migration/reconcile, and retry backoff policy.

	PURE MODULE — no Roblox API calls, no os.clock; callers pass timestamps.
	Headless-tested by tools/harness-runner (persistence mode). Keeping every
	decision here means the DataStore adapter (ProfileStore) stays thin enough
	to be reviewed by eye, which is the only "test" Roblox service code gets.
]=]

local ProfileLogic = {}

-- A lock older than this is considered abandoned (crashed server) and may be
-- stolen. Autosave refreshes the lock well inside this window.
ProfileLogic.LOCK_TIMEOUT_SECONDS = 90

-- ── Session locks ─────────────────────────────────────────────────────────────

--[=[
	Decide whether `jobId` may take the lock embedded in a stored envelope.
	Returns "acquire" | "held" | "steal".
	  acquire — no lock, or we already hold it (refresh)
	  steal   — lock exists but is stale (crashed server)
	  held    — a live foreign session holds it; caller must not write
]=]
function ProfileLogic.arbitrateLock(existingLock, jobId, now)
	if existingLock == nil then
		return "acquire"
	end
	if existingLock.jobId == jobId then
		return "acquire"
	end
	if (now - existingLock.timestamp) > ProfileLogic.LOCK_TIMEOUT_SECONDS then
		return "steal"
	end
	return "held"
end

function ProfileLogic.makeLock(jobId, now)
	return { jobId = jobId, timestamp = now }
end

-- ── Schema migration & reconcile ──────────────────────────────────────────────

--[=[
	Run MIGRATIONS sequentially from the envelope's version to targetVersion.
	Returns (data, version). Unknown FUTURE versions are returned untouched —
	never downgrade data written by a newer server (plan §23: forward-migration
	safety; the caller must treat futureVersion > target as read-only).
]=]
function ProfileLogic.migrate(data, fromVersion, targetVersion, migrations)
	if fromVersion >= targetVersion then
		return data, fromVersion
	end
	local version = fromVersion
	while version < targetVersion do
		local step = migrations[version]
		if not step then
			error(string.format("Missing migration for schema v%d -> v%d", version, version + 1))
		end
		data = step(data) or data
		version += 1
	end
	return data, version
end

--[=[
	Deep-fill missing keys in `data` from `defaults` (additive schema changes
	need no migration). Arrays and present values are left untouched; only
	absent keys are copied. Returns data (mutated in place).
]=]
function ProfileLogic.reconcile(data, defaults)
	for key, defaultValue in pairs(defaults) do
		local current = data[key]
		if current == nil then
			data[key] = ProfileLogic.deepCopy(defaultValue)
		elseif type(current) == "table" and type(defaultValue) == "table" and #defaultValue == 0 then
			-- Recurse into dictionary-shaped defaults only; never reshape arrays
			ProfileLogic.reconcile(current, defaultValue)
		end
	end
	return data
end

function ProfileLogic.deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = ProfileLogic.deepCopy(v)
	end
	return copy
end

-- ── Retry backoff policy ──────────────────────────────────────────────────────

ProfileLogic.MAX_ATTEMPTS = 5

-- DataStore throttle budgets refill on the order of seconds: 1s base doubling
-- (1, 2, 4, 8) clears a burst throttle by the final attempt without stalling
-- joins for half a minute.
function ProfileLogic.backoffDelay(attempt)
	if attempt >= ProfileLogic.MAX_ATTEMPTS then
		return nil -- give up
	end
	return 2 ^ (attempt - 1)
end

-- ── Pending adjustments (offline-safe writes) ─────────────────────────────────
-- Writes targeting a profile that is NOT loaded here (e.g. a ranked leaver's
-- rating loss) are appended to the stored envelope's `pending` list via a
-- minimal UpdateAsync merge. The session that owns the profile consumes the
-- list atomically inside its own load/save transforms — adjustments cannot be
-- lost to a full-envelope overwrite or applied twice. This is also the
-- foundation Phase 6 receipt-granting reuses.

--[=[
	Apply every recognised adjustment to `data` (in place). Unrecognised types
	(from a newer build) are RETURNED as the remaining list — never dropped.
	Returns (data, remaining).
]=]
function ProfileLogic.applyPending(data, pending)
	local remaining = {}
	if not pending then
		return data, remaining
	end

	for _, adjustment in ipairs(pending) do
		if adjustment.type == "rankedResult" then
			data.mmr = math.max(0, (data.mmr or 0) + (adjustment.mmrDelta or 0))
			data.rankedDraws = data.rankedDraws or 0
			if adjustment.result == "Win" then
				data.rankedWins += 1
			elseif adjustment.result == "Loss" then
				data.rankedLosses += 1
			elseif adjustment.result == "Draw" then
				data.rankedDraws += 1
			end
		else
			table.insert(remaining, adjustment)
		end
	end

	return data, remaining
end

-- ── Stats application (kept pure so the recorder is testable) ─────────────────

--[=[
	Apply one match result to a profile's stats table, in place.
	outcome: "Win" | "Loss" | "Draw"
	finishReason: how the LOSER finished ("SpinOut"|"WobbleCollapse"|"RingOut")
	              or nil for draws.
]=]
function ProfileLogic.applyMatchResult(stats, outcome, finishReason)
	stats.matchesPlayed += 1
	if outcome == "Win" then
		stats.wins += 1
		if finishReason and stats.finishesBy[finishReason] ~= nil then
			stats.finishesBy[finishReason] += 1
		end
	elseif outcome == "Loss" then
		stats.losses += 1
		if finishReason and stats.lossesBy[finishReason] ~= nil then
			stats.lossesBy[finishReason] += 1
		end
	elseif outcome == "Draw" then
		stats.draws += 1
	end
	return stats
end

return ProfileLogic
