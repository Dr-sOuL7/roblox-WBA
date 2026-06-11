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
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local MatchInstance = require(script.Parent:WaitForChild("MatchInstance"))

local MatchManager = {}

local _slots = {} -- slotIndex -> MatchInstance | "pending" | nil
local _stadiumTemplate = nil
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

-- ── Stadium template (CSG once, clone per match) ─────────────────────────────

local function buildStadiumTemplate()
	if _stadiumTemplate then return _stadiumTemplate end

	local R = Constants.BowlSphereRadius
	local MAX_R = Constants.BowlPlayableRadius

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

	-- Generate the smooth curvy bowl using CSG Solid Modeling
	local success, curvyBowl = pcall(function()
		return block:SubtractAsync({ sphere }, Enum.CollisionFidelity.Default, Enum.RenderFidelity.Precise)
	end)

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

	_stadiumTemplate = template
	return template
end

local function spawnStadium(parentFolder, origin)
	local clone = buildStadiumTemplate():Clone()
	clone.Name = "Stadium"
	-- Template is built around (0,0,0); shift every part by the arena origin
	clone:PivotTo(clone:GetPivot() + origin)
	clone.Parent = parentFolder
	return clone
end

-- ── Bey models ────────────────────────────────────────────────────────────────

-- Create a highly visible multi-part Prototype Bey model at the arena origin
local function createPrototypeBeyModel(playerId: number, isPlayer1: boolean, parentFolder, origin)
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

	local beyColor = isPlayer1 and Color3.fromRGB(255, 50, 50) or Color3.fromRGB(50, 120, 255)

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
	disc.Color = Color3.fromRGB(150, 160, 170)
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
	ring.Color = beyColor
	ring.Material = Enum.Material.SmoothPlastic
	ring.Anchored = true
	ring.CanCollide = false
	ring.Parent = model

	-- 5. Blades/Notches (4 protruding blocks to make spin hyper-visible)
	for i = 1, 4 do
		local blade = Instance.new("Part")
		blade.Name = "Blade_" .. i
		blade.Size = Vector3.new(1.2, 2.0, 2.5)
		blade.Color = Color3.fromRGB(255, 255, 0) -- Bright Yellow
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
	bit.Color = Color3.fromRGB(255, 255, 255)
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
	Returns the MatchInstance, or nil if no slot is free (caller re-queues).
]=]
function MatchManager.StartNewMatch(playerIds)
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

	-- Begin with an authoritative countdown
	newState.phase = "Countdown"
	local now = workspace:GetServerTimeNow()
	newState.timers.countdownEndTime = now + 3 -- 3 second countdown
	newState.timers.launchBarEpoch = now       -- timing bar sweeps from countdown start

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

	spawnStadium(folder, origin) -- may yield once ever (template CSG build)

	for i, pid in ipairs(playerIds) do
		local bState = MatchState.createBeyState(pid)
		-- Spawn high above the bowl (Y=10); gentle pre-launch drift only.
		-- The player's launch input supplies the real impulse.
		-- LOCAL space — rendering adds arenaOrigin.
		local side = (i == 1) and -1 or 1
		bState.position = Vector3.new(side * 10, 10, 0)
		bState.velocity = Vector3.new(
			-side * Constants.SpawnInwardSpeed,
			0,
			-side * Constants.SpawnTangentialSpeed
		)
		bState.previousPosition = bState.position
		newState.beyStates[pid] = bState

		createPrototypeBeyModel(pid, i == 1, folder, origin)
	end

	local instance = MatchInstance.fromState(newState, slot, origin)
	instance.folder = folder
	_slots[slot] = instance

	TickManager.RegisterInstance(instance)

	-- Broadcast match start (Countdown phase) to participants
	instance:BroadcastPhase({
		seed = newState.matchSeed,
		players = playerIds,
		countdownEndTime = newState.timers.countdownEndTime,
		launchBarEpoch = newState.timers.launchBarEpoch,
	})

	return instance
end

function MatchManager.CleanupMatch(instance)
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

	-- Queue returning players BEFORE freeing the slot: cleanup triggers the
	-- next start round, and front-of-queue priority gives them first claim
	-- on their own freed arena.
	if _onReadyForRematch then
		_onReadyForRematch(validPlayers)
	end

	MatchManager.CleanupMatch(instance)
end)

return MatchManager
