--[=[
	MatchManager.lua
	Match orchestration for the multi-stadium server (ADR-001): arena slot
	allocation, stadium/Bey model lifecycle per match, rematch flow.

	Simulation runs in local bowl-space inside each MatchInstance; this module
	places the visual world (stadium clone, Bey models) at the slot's arena
	origin. Does NOT terminate tick loops directly — TickManager owns stepping.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local MatchState = require(ReplicatedStorage:WaitForChild("MatchState"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local Cosmetics = require(ReplicatedStorage:WaitForChild("Cosmetics"))
local LaunchQuality = require(ReplicatedStorage:WaitForChild("LaunchQuality"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local MatchInstance = require(script.Parent:WaitForChild("MatchInstance"))
local ProfileStore = require(script.Parent:WaitForChild("Persistence"):WaitForChild("ProfileStore"))

local MatchManager = {}

local _slots = {} -- slotIndex -> MatchInstance | "pending" | nil
local _stadiumTemplates = {} -- stadiumId -> Model (CSG built once per stadium)
local _matchesFolder = nil
local _onMatchCleanedUpCallback = nil
local _onReadyForRematch = nil
local _onMatchFinishedListeners = {}

function MatchManager.OnMatchCleanedUp(callback)
	_onMatchCleanedUpCallback = callback
end

function MatchManager.OnReadyForRematch(callback)
	_onReadyForRematch = callback
end

-- Listeners receive the final MatchState before cleanup (winner, beyStates,
-- finishReasons intact). Used by persistence/StatsRecorder; pcall-isolated so
-- a listener bug can never stall the rematch loop.
function MatchManager.OnMatchFinished(callback)
	table.insert(_onMatchFinishedListeners, callback)
end

-- ── Workspace helpers ─────────────────────────────────────────────────────────

local function getMatchesFolder()
	if not _matchesFolder or not _matchesFolder.Parent then
		_matchesFolder = workspace:FindFirstChild("Matches")
		if not _matchesFolder then
			_matchesFolder = Instance.new("Folder")
			_matchesFolder.Name = "Matches"
			_matchesFolder.Parent = workspace
		end
	end
	return _matchesFolder
end

local function arenaOriginForSlot(slot)
	return Vector3.new((slot - 1) * Constants.ArenaSlotSpacing, 0, 0)
end

-- No characters exist (players pilot Beys), so each client's replication
-- focus must be set explicitly — without one, a streaming-enabled place may
-- never send the arena to the client at all (UI works, world invisible).
-- StreamingEnabled is also forced off via default.project.json; this is the
-- belt to that suspender.
local _lobbyFocus = nil

local function getLobbyFocus()
	if not _lobbyFocus or not _lobbyFocus.Parent then
		_lobbyFocus = Instance.new("Part")
		_lobbyFocus.Name = "LobbyFocus"
		_lobbyFocus.Size = Vector3.new(1, 1, 1)
		_lobbyFocus.Transparency = 1
		_lobbyFocus.Anchored = true
		_lobbyFocus.CanCollide = false
		_lobbyFocus.CFrame = CFrame.new(0, 10, 0) -- slot 1 arena
		_lobbyFocus.Parent = getMatchesFolder()
	end
	return _lobbyFocus
end

function MatchManager.SetLobbyFocus(player)
	player.ReplicationFocus = getLobbyFocus()
end

local function setMatchFocus(playerIds, focusPart)
	for _, pid in ipairs(playerIds) do
		local player = Players:GetPlayerByUserId(pid)
		if player then
			player.ReplicationFocus = focusPart
		end
	end
end

-- ── Stadium template (CSG once, clone per match) ─────────────────────────────

local function buildStadiumTemplate(stadiumDef)
	if _stadiumTemplates[stadiumDef.id] then
		return _stadiumTemplates[stadiumDef.id]
	end

	local R = stadiumDef.bowlSphereRadius
	local MAX_R = stadiumDef.playableRadius

	-- ── Create a massive block to carve the bowl into ──────────
	local block = Instance.new("Part")
	block.Name = "StadiumFloor"
	block.Size = Vector3.new(MAX_R * 2 + 6, 12, MAX_R * 2 + 6)
	-- Center it so the top surface rests at Y = 11, and bottom at Y = -1
	block.CFrame = CFrame.new(0, 5, 0)

	-- ── Create a sphere to subtract from the block ──────────
	local sphere = Instance.new("Part")
	sphere.Shape = Enum.PartType.Ball
	sphere.Size = Vector3.new(R * 2, R * 2, R * 2)
	-- Center the sphere exactly R studs above 0, so the lowest tip touches Y=0
	sphere.CFrame = CFrame.new(0, R, 0)

	-- Generate the smooth curvy bowl using CSG Solid Modeling.
	-- Inputs are parented while the operation runs (CSG can fail on
	-- out-of-DataModel parts in some engine paths), then discarded.
	block.Anchored = true
	sphere.Anchored = true
	block.Parent = workspace
	sphere.Parent = workspace
	local success, curvyBowl = pcall(function()
		return block:SubtractAsync({ sphere }, Enum.CollisionFidelity.Default, Enum.RenderFidelity.Precise)
	end)
	sphere:Destroy()
	if success and curvyBowl then
		block:Destroy()
	else
		block.Parent = nil -- keep as the visual fallback below
	end

	if not success or not curvyBowl then
		warn("[MatchManager] Failed to generate curvy stadium (CSG error); falling back to flat floor.")
		curvyBowl = block -- visual-only fallback; simulation is unaffected
	end

	curvyBowl.Name = "StadiumFloor"
	curvyBowl.Anchored = true
	curvyBowl.CanCollide = true
	curvyBowl.Material = Enum.Material.SmoothPlastic
	curvyBowl.Color = Color3.fromRGB(245, 245, 250)

	local template = Instance.new("Model")
	template.Name = "StadiumTemplate"
	curvyBowl.CFrame = CFrame.new(0, 5, 0)
	curvyBowl.Parent = template
	template.PrimaryPart = curvyBowl

	-- ── Center nub (classic Beyblade stadium center marker) ──────────
	local centerMark = Instance.new("Part")
	centerMark.Name = "StadiumCenter"
	centerMark.Size = Vector3.new(0.5, 0.2, 0.5)
	centerMark.CFrame = CFrame.new(0, 0, 0)
	centerMark.Shape = Enum.PartType.Cylinder
	centerMark.Anchored = true
	centerMark.CanCollide = false
	centerMark.Material = Enum.Material.Neon
	centerMark.Color = Color3.fromRGB(255, 55, 35)
	centerMark.Parent = template

	_stadiumTemplates[stadiumDef.id] = template
	return template
end

local function spawnStadium(stadiumDef, parentFolder, origin)
	local clone = buildStadiumTemplate(stadiumDef):Clone()
	clone.Name = "Stadium"
	-- Template is built around (0,0,0); shift every part by the arena origin
	clone:PivotTo(clone:GetPivot() + origin)
	clone.Parent = parentFolder
	return clone
end

-- ── Bey models ────────────────────────────────────────────────────────────────

-- Create a highly visible multi-part Prototype Bey model at the arena origin.
-- Skin colors are COSMETIC ONLY (ring/disc/bit); team identity lives on the
-- blades (P1 red / P2 blue) so skins never blur whose Bey is whose.
local function createPrototypeBeyModel(playerId: number, isPlayer1: boolean, parentFolder, origin, skinDef)
	local model = Instance.new("Model")
	model.Name = "Bey_" .. tostring(playerId)

	-- 1. Primary Part (Pivot at the very bottom tip, offset to rest on the 0.4 thick floor)
	local pivot = Instance.new("Part")
	pivot.Name = "Pivot"
	pivot.Size = Vector3.new(0.1, 0.1, 0.1)
	pivot.Transparency = 1
	pivot.Anchored = true
	pivot.CanCollide = false
	pivot.CFrame = CFrame.new(origin + Vector3.new(0, 0.2, 0))
	pivot.Parent = model
	model.PrimaryPart = pivot

	local teamColor = isPlayer1 and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(50, 120, 255)

	-- 2. Driver (Tip)
	local driver = Instance.new("Part")
	driver.Name = "Driver"
	driver.Size = Vector3.new(1.5, 1.5, 1.5)
	driver.Shape = Enum.PartType.Cylinder
	driver.CFrame = pivot.CFrame * CFrame.new(0, 0.75, 0) * CFrame.Angles(0, 0, math.rad(90))
	driver.Color = Color3.fromRGB(40, 40, 40)
	driver.Anchored = true
	driver.CanCollide = false
	driver.Parent = model

	-- 3. Weight Disc
	local disc = Instance.new("Part")
	disc.Name = "WeightDisc"
	disc.Size = Vector3.new(0.8, 3.5, 3.5)
	disc.Shape = Enum.PartType.Cylinder
	disc.CFrame = pivot.CFrame * CFrame.new(0, 1.9, 0) * CFrame.Angles(0, 0, math.rad(90))
	disc.Color = skinDef.discColor
	disc.Material = Enum.Material.Metal
	disc.Anchored = true
	disc.CanCollide = false
	disc.Parent = model

	-- 4. Attack Ring
	local ring = Instance.new("Part")
	ring.Name = "AttackRing"
	ring.Size = Vector3.new(1.2, 5.0, 5.0)
	ring.Shape = Enum.PartType.Cylinder
	ring.CFrame = pivot.CFrame * CFrame.new(0, 2.9, 0) * CFrame.Angles(0, 0, math.rad(90))
	ring.Color = skinDef.ringColor
	ring.Material = Enum.Material.SmoothPlastic
	ring.Anchored = true
	ring.CanCollide = false
	ring.Parent = model

	-- 5. Blades/Notches (4 protruding blocks to make spin hyper-visible)
	for i = 1, 4 do
		local blade = Instance.new("Part")
		blade.Name = "Blade_" .. i
		blade.Size = Vector3.new(1.2, 2.0, 2.5)
		blade.Color = teamColor -- team identity channel (P1 red / P2 blue)
		blade.Anchored = true
		blade.CanCollide = false
		blade.CFrame = pivot.CFrame
			* CFrame.new(0, 2.9, 0)
			* CFrame.Angles(0, math.rad(i * 90), 0)
			* CFrame.new(0, 0, -2.8)
		blade.Parent = model
	end

	-- Center graphic / Bit Beast placeholder
	local bit = Instance.new("Part")
	bit.Name = "BitChip"
	bit.Size = Vector3.new(0.2, 2.0, 2.0)
	bit.Shape = Enum.PartType.Cylinder
	bit.CFrame = pivot.CFrame * CFrame.new(0, 3.6, 0) * CFrame.Angles(0, 0, math.rad(90))
	bit.Color = skinDef.bitColor
	bit.Material = Enum.Material.Neon
	bit.Anchored = true
	bit.CanCollide = false
	bit.Parent = model

	model.Parent = parentFolder
	print(string.format("[Match] Prototype Bey spawned for player %d (Player 1: %s)", playerId, tostring(isPlayer1)))
	return model
end

-- ── Slot allocation ───────────────────────────────────────────────────────────

local function claimFreeSlot()
	for slot = 1, Constants.MaxConcurrentMatches do
		if _slots[slot] == nil then
			_slots[slot] = "pending" -- claim before any yields (CSG build)
			return slot
		end
	end
	return nil
end

function MatchManager.HasFreeSlot()
	for slot = 1, Constants.MaxConcurrentMatches do
		if _slots[slot] == nil then
			return true
		end
	end
	return false
end

function MatchManager.GetActiveMatchCount()
	local count = 0
	for slot = 1, Constants.MaxConcurrentMatches do
		if _slots[slot] ~= nil then
			count += 1
		end
	end
	return count
end

-- ── Match lifecycle ───────────────────────────────────────────────────────────

--[=[
	Start a match for playerIds in a free arena slot.
	options.queueMode: "Ranked" | "Casual" (default) — stamped on the state so
	finish listeners (rating updates) know the stakes.
	Returns the MatchInstance, or nil if no slot is free (caller re-queues).
]=]
function MatchManager.StartNewMatch(playerIds, options)
	options = options or {}
	local slot = claimFreeSlot()
	if not slot then
		warn("[MatchManager] No free arena slot; match not started.")
		return nil
	end

	local origin = arenaOriginForSlot(slot)

	-- Millisecond-granular seed eliminates same-second collisions; stays in safe integer range
	local matchSeed = math.floor(workspace:GetServerTimeNow() * 1000) % (2^31 - 1)
	local newState = MatchState.new(matchSeed)
	newState.matchId = string.format("Match_%d_s%d", matchSeed, slot)
	newState.queueMode = options.queueMode or "Casual"
	newState.bots = options.bots -- { [botUserId] = profileName } or nil
	-- Stadium: explicit pick (casual select, later) or seeded rotation (ranked)
	newState.stadiumId = options.stadiumId or Stadiums.pickForSeed(matchSeed)
	local stadiumDef = Stadiums.get(newState.stadiumId)

	-- Begin with the aim-and-ready ceremony; countdown starts when both
	-- players are READY (or the deadline auto-readies stragglers)
	newState.phase = "Setup"
	newState.timers.setupDeadline = workspace:GetServerTimeNow() + Constants.SetupTimeoutSeconds

	-- Build canonical sorted player order — all modules iterate this, never pairs()
	local sortedIds = table.clone(playerIds)
	table.sort(sortedIds)
	newState.playerOrder = sortedIds

	print(string.format("[Match] Starting %s | Seed: %d | Players: %d | Slot: %d",
		newState.matchId, matchSeed, #playerIds, slot))

	-- Per-match workspace container: destroyed wholesale on cleanup
	local folder = Instance.new("Folder")
	folder.Name = newState.matchId
	folder.Parent = getMatchesFolder()

	spawnStadium(stadiumDef, folder, origin) -- may yield once per stadium (template CSG build)

	-- Per-match replication focus at this arena (see getLobbyFocus comment)
	local focusPart = Instance.new("Part")
	focusPart.Name = "MatchFocus"
	focusPart.Size = Vector3.new(1, 1, 1)
	focusPart.Transparency = 1
	focusPart.Anchored = true
	focusPart.CanCollide = false
	focusPart.CFrame = CFrame.new(origin + Vector3.new(0, 10, 0))
	focusPart.Parent = folder

	-- Equipped skins, resolved once at match start (mid-match equips are
	-- rejected). COSMETIC ONLY: this map never enters beyStates/physics —
	-- the headless suite proves outcomes are identical with or without it.
	newState.cosmetics = {}
	for _, pid in ipairs(playerIds) do
		if newState.bots and newState.bots[pid] then
			-- Bots wear a deterministic starter skin (seeded, cosmetic only)
			local ids = Cosmetics.ownedSkinIds(nil)
			newState.cosmetics[pid] = ids[(matchSeed % #ids) + 1]
		else
			local profile = ProfileStore.GetProfile(pid)
			local skinId = profile and profile.equippedCosmetics and profile.equippedCosmetics.skin
			newState.cosmetics[pid] = Cosmetics.get(skinId).id
		end
	end

	-- Mirrored spawns at half the playable radius — scales with the stadium
	-- (Classic: ±10, identical to the validated baseline)
	local spawnRadius = stadiumDef.playableRadius * 0.5

	for i, pid in ipairs(playerIds) do
		local bState = MatchState.createBeyState(pid)
		-- Held frozen at the spawn point through Setup/Countdown; the launch
		-- click (or the Poor auto-launch) supplies ALL motion.
		-- LOCAL space — rendering adds arenaOrigin.
		local side = (i == 1) and -1 or 1
		bState.position = Vector3.new(side * spawnRadius, Constants.LaunchHeightDefault, 0)
		bState.velocity = Vector3.new(0, 0, 0)
		bState.previousPosition = bState.position
		newState.beyStates[pid] = bState
		newState.pendingAim[pid] = LaunchQuality.defaultAimFor(side)

		-- Build the model AT its spawn point so it is visible immediately,
		-- before the first snapshot drives the renderer
		createPrototypeBeyModel(pid, i == 1, folder,
			origin + Vector3.new(side * spawnRadius, Constants.LaunchHeightDefault, 0),
			Cosmetics.get(newState.cosmetics[pid]))
	end

	setMatchFocus(playerIds, focusPart)

	local instance = MatchInstance.fromState(newState, slot, origin)
	instance.folder = folder
	_slots[slot] = instance

	TickManager.RegisterInstance(instance)

	-- Broadcast match start (Setup phase) to participants
	instance:BroadcastPhase({
		seed = newState.matchSeed,
		players = playerIds,
		setupDeadline = newState.timers.setupDeadline,
	})

	return instance
end

function MatchManager.CleanupMatch(instance)
	-- Return surviving participants' replication focus to the lobby
	for _, pid in ipairs(instance.state.playerOrder) do
		local player = Players:GetPlayerByUserId(pid)
		if player then
			player.ReplicationFocus = getLobbyFocus()
		end
	end
	TickManager.UnregisterInstance(instance)
	if instance.folder then
		instance.folder:Destroy()
		instance.folder = nil
	end
	if instance.slot and _slots[instance.slot] == instance then
		_slots[instance.slot] = nil
	end
	print(string.format("[Match] %s cleaned up (slot %d freed).", instance.state.matchId, instance.slot or 0))
	if _onMatchCleanedUpCallback then
		_onMatchCleanedUpCallback(instance)
	end
end

-- ── Launch ceremony: READY ────────────────────────────────────────────────────

-- Remote-facing: marks a participant ready and stores their (clamped) aim as
-- the auto-launch fallback. The Setup tick advances to Countdown when all
-- participants are ready.
function MatchManager.HandleReady(player, aim)
	local instance = TickManager.GetInstanceForPlayer(player.UserId)
	if not instance then
		return
	end
	local state = instance.state
	if state.phase ~= "Setup" then
		return
	end
	if not state.beyStates[player.UserId] then
		return
	end

	state.pendingAim[player.UserId] = LaunchQuality.clampAim(aim)
	if not state.ready[player.UserId] then
		state.ready[player.UserId] = true
		print(string.format("[Match %s] Player %d is READY", state.matchId, player.UserId))
	end
	-- Let both clients show ready ticks (phase is still Setup)
	instance:BroadcastPhase({
		setupDeadline = state.timers.setupDeadline,
		ready = state.ready,
	})
end

-- ── Disconnect handling: grace → reconnect or forfeit (plan §Phase 2) ────────

local _disconnectTimers = {} -- userId -> thread (pending forfeit)

local function forfeitPlayer(instance, userId)
	local state = instance.state
	if state.phase ~= "Active" then
		return
	end
	local bState = state.beyStates[userId]
	if not bState or bState.zoneState == "Finished" then
		return
	end

	bState.zoneState = "Finished"
	bState.finishReason = "Forfeit"
	bState.velocity = Vector3.new(0, 0, 0)
	bState.angularVelocity = Vector3.new(0, 0, 0)
	table.insert(state.tickEvents, {
		eventType = "BeyFinished",
		eventData = { playerId = userId, reason = "Forfeit" },
	})
	-- Seat is gone: inputs stop routing and the player may queue again
	TickManager.UnmapPlayer(userId)
	print(string.format("[Match] Player %d forfeited %s (disconnect grace expired)", userId, state.matchId))
	-- SpinEvaluator declares the survivor the winner on the next Evaluation tick
end

local function cancelCountdownMatch(instance, leaverId)
	local state = instance.state
	print(string.format("[Match] %s cancelled (player %d left during countdown)", state.matchId, leaverId))

	state.phase = "Finished"
	instance:BroadcastPhase({ cancelled = true })

	local remaining = {}
	for _, pid in ipairs(state.playerOrder) do
		if pid ~= leaverId and Players:GetPlayerByUserId(pid) then
			table.insert(remaining, pid)
		end
	end

	if _onReadyForRematch then
		_onReadyForRematch(remaining, state)
	end
	MatchManager.CleanupMatch(instance)
end

-- Call on PlayerRemoving. Active match → grace timer (return = resume,
-- expiry = forfeit). Countdown → cancel outright and requeue the remainder.
function MatchManager.HandlePlayerLeft(userId)
	local instance = TickManager.GetInstanceForPlayer(userId)
	if not instance then
		return
	end

	local state = instance.state
	if state.phase == "Setup" or state.phase == "Countdown" then
		cancelCountdownMatch(instance, userId)
		return
	end
	if state.phase ~= "Active" then
		return
	end

	print(string.format("[Match] Player %d disconnected from %s — %ds grace",
		userId, state.matchId, Constants.ReconnectGraceSeconds))
	_disconnectTimers[userId] = task.delay(Constants.ReconnectGraceSeconds, function()
		_disconnectTimers[userId] = nil
		-- Still gone, match still live?
		if Players:GetPlayerByUserId(userId) then
			return
		end
		if TickManager.GetInstanceForPlayer(userId) == instance and state.phase == "Active" then
			forfeitPlayer(instance, userId)
		end
	end)
end

-- Call on PlayerAdded. Returns true if the player resumed a live match seat
-- (callers must then SKIP auto-queueing them).
function MatchManager.HandlePlayerReturned(userId): boolean
	local timer = _disconnectTimers[userId]
	if timer then
		task.cancel(timer)
		_disconnectTimers[userId] = nil
	end

	local instance = TickManager.GetInstanceForPlayer(userId)
	if not instance then
		return false
	end

	local state = instance.state
	local bState = state.beyStates[userId]
	if state.phase == "Finished" or not bState or bState.zoneState == "Finished" then
		-- Nothing to resume (match over or seat already forfeited)
		TickManager.UnmapPlayer(userId)
		return false
	end

	print(string.format("[Match] Player %d reconnected to %s — resyncing", userId, state.matchId))
	instance:ResyncPlayer(userId)
	return true
end

TickManager.SetInstanceFinishedCallback(function(instance)
	local finishedState = instance.state

	for _, listener in ipairs(_onMatchFinishedListeners) do
		local ok, err = pcall(listener, finishedState)
		if not ok then
			warn("[MatchManager] OnMatchFinished listener error: " .. tostring(err))
		end
	end

	print(string.format("[Match] %s finished. Restarting in 5 seconds...", finishedState.matchId))
	task.wait(5)

	local validPlayers = {}
	for _, pid in ipairs(finishedState.playerOrder) do
		if Players:GetPlayerByUserId(pid) then
			table.insert(validPlayers, pid)
		end
	end

	-- Requeue returning players before freeing the slot so they can claim
	-- their own arena for the next round (matchmaking pairs them again).
	if _onReadyForRematch then
		_onReadyForRematch(validPlayers, finishedState)
	end

	MatchManager.CleanupMatch(instance)
end)

return MatchManager
