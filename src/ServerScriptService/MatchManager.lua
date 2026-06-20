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
local BeyParts = require(ReplicatedStorage:WaitForChild("BeyParts"))
local BeyModelBuilder = require(ReplicatedStorage:WaitForChild("BeyModelBuilder"))
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

-- Fires with playerIds when a match starts (any entry path). Used by
-- matchmaking to drop participants from queues so a queued player who entered
-- a match another way (e.g. a proximity challenge) is never double-matched.
local _onMatchStartedListeners = {}
function MatchManager.OnMatchStarted(callback)
	table.insert(_onMatchStartedListeners, callback)
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

	-- Flat, walled circular arena (no bowl, no ring-out). The wall bounce is
	-- resolved analytically in PhysicsController; the wall parts are visual only.
	local R = stadiumDef.radius
	local floorColor = stadiumDef.floorColor or { 245, 245, 250 }
	local wallColor = stadiumDef.wallColor or { 90, 130, 255 }
	local wallHeight = Constants.StadiumWallHeight

	local template = Instance.new("Model")
	template.Name = "StadiumTemplate"

	-- Flat circular floor. A Roblox Cylinder lies along its X axis, so rotate it
	-- 90° about Z to stand the circular face horizontal; the top face sits at Y=0
	-- (matching the simulation floor: a Bey renders at Y=0).
	local FLOOR_THICKNESS = 1
	local floor = Instance.new("Part")
	floor.Name = "StadiumFloor"
	floor.Shape = Enum.PartType.Cylinder
	floor.Size = Vector3.new(FLOOR_THICKNESS, R * 2, R * 2)
	floor.CFrame = CFrame.new(0, -FLOOR_THICKNESS / 2, 0) * CFrame.Angles(0, 0, math.rad(90))
	floor.Anchored = true
	floor.CanCollide = true
	floor.Material = Enum.Material.SmoothPlastic
	floor.Color = Color3.fromRGB(floorColor[1], floorColor[2], floorColor[3])
	floor.Parent = template
	template.PrimaryPart = floor

	-- Wall ring: thin tangent segments around the rim (translucent forcefield).
	local walls = Instance.new("Folder")
	walls.Name = "StadiumWalls"
	walls.Parent = template
	local SEGMENTS = 48
	local segWidth = (2 * math.pi * R) / SEGMENTS + 0.6
	for i = 1, SEGMENTS do
		local ang = (i / SEGMENTS) * math.pi * 2
		local px, pz = math.cos(ang) * R, math.sin(ang) * R
		local seg = Instance.new("Part")
		seg.Name = "Wall_" .. i
		seg.Size = Vector3.new(segWidth, wallHeight, 0.6) -- X spans tangent after lookAt
		seg.CFrame = CFrame.lookAt(
			Vector3.new(px, wallHeight / 2, pz),
			Vector3.new(0, wallHeight / 2, 0)
		)
		seg.Anchored = true
		seg.CanCollide = false
		seg.CanQuery = false
		seg.Material = Enum.Material.ForceField
		seg.Transparency = 0.25
		seg.Color = Color3.fromRGB(wallColor[1], wallColor[2], wallColor[3])
		seg.Parent = walls
	end

	-- ── Center nub (classic stadium center marker) ──────────
	local centerMark = Instance.new("Part")
	centerMark.Name = "StadiumCenter"
	centerMark.Size = Vector3.new(0.4, 0.2, 0.4)
	centerMark.CFrame = CFrame.new(0, 0.05, 0) * CFrame.Angles(0, 0, math.rad(90))
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

-- Build the player's CRAFTED Bey (ADR-003) at the arena origin. Shapes,
-- heights, and per-part colours come from the build; a team-coloured base ring
-- (P1 red / P2 blue) is the identity channel so per-part colours never blur
-- whose Bey is whose.
local function createBeyModel(playerId: number, isPlayer1: boolean, parentFolder, origin, buildSpec)
	local teamColor = isPlayer1 and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(50, 120, 255)
	local model = BeyModelBuilder.build(buildSpec, origin + Vector3.new(0, 0.2, 0), {
		name = "Bey_" .. tostring(playerId),
		teamColor = teamColor,
	})
	model.Parent = parentFolder
	print(string.format("[Match] Crafted Bey spawned for player %d (Player 1: %s)", playerId, tostring(isPlayer1)))
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
	-- Physics reads these per-match so concurrent matches on different stadiums
	-- stay independent (flat radius + wall restitution).
	newState.stadiumRadius = stadiumDef.radius
	newState.stadiumWallBounce = stadiumDef.wallBounce

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

	-- Mirrored spawns near the rim — scales with the stadium radius.
	local spawnRadius = stadiumDef.radius * 0.45
	local floorY = Constants.BeyRadius

	for i, pid in ipairs(playerIds) do
		-- Resolve the player's crafted build (ADR-003). Bots and profile-less
		-- sessions use the neutral default → mods stay 1.0 (validated baseline).
		-- The build drives BOTH the 4 stats and the part-based damage profile.
		local buildSpec = BeyParts.defaultBuild()
		if not (newState.bots and newState.bots[pid]) then
			local profile = ProfileStore.GetProfile(pid)
			if profile and profile.build then
				buildSpec = profile.build
			end
		end

		local bState = MatchState.createBeyState(pid, buildSpec)
		-- Held frozen at the spawn point through Setup/Countdown; the launch
		-- click (or the Poor auto-launch) supplies ALL motion.
		-- LOCAL space — rendering adds arenaOrigin.
		local side = (i == 1) and -1 or 1
		bState.position = Vector3.new(side * spawnRadius, floorY, 0)
		bState.velocity = Vector3.new(0, 0, 0)
		bState.previousPosition = bState.position
		-- Face the centre before launch (nice pre-GO read; launch overrides it).
		bState.facingAngle = (side < 0) and 0 or math.pi
		bState.targetFacing = bState.facingAngle
		newState.beyStates[pid] = bState
		newState.pendingAim[pid] = LaunchQuality.defaultAimFor(side)

		-- Build the CRAFTED model AT its spawn point so it is visible immediately,
		-- before the first snapshot drives the renderer
		createBeyModel(pid, i == 1, folder,
			origin + Vector3.new(side * spawnRadius, floorY, 0),
			buildSpec)
	end

	setMatchFocus(playerIds, focusPart)

	-- Despawn hub characters: from here only the Beys remain, which the
	-- players control. Covers EVERY entry path (challenge, bot, ranked queue).
	-- Players respawn in the hub when the match is cleaned up.
	for _, pid in ipairs(playerIds) do
		local player = Players:GetPlayerByUserId(pid)
		if player and player.Character then
			player.Character:Destroy()
			player.Character = nil
		end
	end

	local instance = MatchInstance.fromState(newState, slot, origin)
	instance.folder = folder
	_slots[slot] = instance

	TickManager.RegisterInstance(instance)

	for _, listener in ipairs(_onMatchStartedListeners) do
		local ok, err = pcall(listener, playerIds)
		if not ok then
			warn("[MatchManager] OnMatchStarted listener error: " .. tostring(err))
		end
	end

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
	-- Defer so the rejoining client's MatchStateChanged listener (and battle
	-- camera) are connected before the resync arrives.
	task.delay(1, function()
		if TickManager.GetInstanceForPlayer(userId) == instance and state.phase ~= "Finished" then
			instance:ResyncPlayer(userId)
		end
	end)
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
