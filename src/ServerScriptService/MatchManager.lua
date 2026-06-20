--[=[
	MatchManager.lua
	Orchestrates match initialization and cleanup.
	Does NOT terminate the Tick loop directly.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local MatchState = require(ReplicatedStorage:WaitForChild("MatchState"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local MatchManager = {}

local stadiumSpawned = false
local currentPlayers = {}
local _onMatchCleanedUpCallback = nil
local _onReadyForRematch = nil

function MatchManager.OnMatchCleanedUp(callback)
    _onMatchCleanedUpCallback = callback
end

function MatchManager.OnReadyForRematch(callback)
    _onReadyForRematch = callback
end

-- Create a highly visible multi-part Prototype Bey model
local function createPrototypeBeyModel(playerId: number, isPlayer1: boolean)
	local modelName = "Bey_" .. tostring(playerId)
	local model = workspace:FindFirstChild(modelName)
	if model then return model end

	model = Instance.new("Model")
	model.Name = modelName

	-- 1. Primary Part (Pivot at the very bottom tip, offset to rest on the 0.4 thick floor)
	local pivot = Instance.new("Part")
	pivot.Name = "Pivot"
	pivot.Size = Vector3.new(0.1, 0.1, 0.1)
	pivot.Transparency = 1
	pivot.Anchored = true
	pivot.CanCollide = false
	pivot.CFrame = CFrame.new(0, 0.2, 0)
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

	model.Parent = workspace
	print(string.format("[Match] Prototype Bey spawned for player %d (Player 1: %s)", playerId, tostring(isPlayer1)))
	return model
end

local function spawnStadium()
	if stadiumSpawned then return end
	stadiumSpawned = true

	local R = Constants.StadiumRadius
	local wallHeight = Constants.StadiumWallHeight

	-- ── Flat circular floor (top surface at Y = 0) ──────────
	local floor = Instance.new("Part")
	floor.Name = "StadiumFloor"
	floor.Shape = Enum.PartType.Cylinder
	-- Cylinder: X = height/thickness, Y & Z = diameter. Rotate 90° about Z to lay flat.
	floor.Size = Vector3.new(1, R * 2, R * 2)
	floor.CFrame = CFrame.new(0, -0.5, 0) * CFrame.Angles(0, 0, math.rad(90))
	floor.Anchored = true
	floor.CanCollide = true
	floor.Material = Enum.Material.SmoothPlastic
	floor.Color = Color3.fromRGB(40, 40, 50)
	floor.Parent = workspace

	-- ── Open-top wall: a ring of thin segments (physics handled in our own math,
	--    so these are visual only — CanCollide = false) ──────────
	local wallFolder = Instance.new("Folder")
	wallFolder.Name = "StadiumWalls"
	wallFolder.Parent = workspace

	local segments = 48
	local segWidth = (2 * math.pi * R / segments) * 1.06 -- slight overlap, no gaps
	for i = 1, segments do
		local angle = (i / segments) * math.pi * 2
		local pos = Vector3.new(math.cos(angle) * R, wallHeight / 2, math.sin(angle) * R)
		local seg = Instance.new("Part")
		seg.Name = "WallSeg"
		-- X = tangential width, Y = height, Z = radial thickness (lookAt makes Z radial)
		seg.Size = Vector3.new(segWidth, wallHeight, 0.5)
		seg.CFrame = CFrame.lookAt(pos, Vector3.new(0, wallHeight / 2, 0))
		seg.Anchored = true
		seg.CanCollide = false
		seg.CastShadow = false
		seg.Material = Enum.Material.ForceField
		seg.Color = Color3.fromRGB(100, 150, 255)
		seg.Transparency = 0.25
		seg.Parent = wallFolder
	end

	-- ── Center marker ──────────
	local centerMark = Instance.new("Part")
	centerMark.Name = "StadiumCenter"
	centerMark.Size = Vector3.new(0.5, 0.2, 0.5)
	centerMark.CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, math.rad(90))
	centerMark.Shape = Enum.PartType.Cylinder
	centerMark.Anchored = true
	centerMark.CanCollide = false
	centerMark.Material = Enum.Material.Neon
	centerMark.Color = Color3.fromRGB(255, 55, 35)
	centerMark.Parent = workspace
end

function MatchManager.StartNewMatch(playerIds)
	currentPlayers = playerIds
	-- Millisecond-granular seed eliminates same-second collisions; stays in safe integer range
	local matchSeed = math.floor(workspace:GetServerTimeNow() * 1000) % (2^31 - 1)
	local newState = MatchState.new(matchSeed)
	newState.matchId = "Match_" .. tostring(matchSeed)

	-- Begin with an authoritative countdown
	newState.phase = "Countdown"
	newState.timers.countdownEndTime = workspace:GetServerTimeNow() + 3 -- 3 second countdown

	-- Build canonical sorted player order — all modules iterate this, never pairs()
	local sortedIds = table.clone(playerIds)
	table.sort(sortedIds)
	newState.playerOrder = sortedIds

	print(string.format("[Match] Starting new match: %s | Seed: %d | Players: %d", newState.matchId, matchSeed, #playerIds))
	print("[Match] Phase: Countdown (3 second countdown)")

	-- Register state with TickManager immediately so RNG is available
	TickManager.SetMatchState(newState)

	-- Spawn Beys
	spawnStadium()

	local spawnX = Constants.StadiumRadius * 0.45
	for i, pid in ipairs(playerIds) do
		-- TODO: pull each player's crafted loadout from persistence; default for now.
		local bState = MatchState.createBeyState(pid, nil)
		-- Flat spawn on opposite sides, resting on the floor, spun up and facing the centre.
		local sx = (i == 1) and -spawnX or spawnX
		bState.position = Vector3.new(sx, Constants.BeyRadius, 0)
		bState.previousPosition = bState.position
		bState.angularVelocity = Vector3.new(0, Constants.LaunchBaseSpin * bState.mods.Stamina, 0)
		-- Face the centre (opponent): +X spawn faces -X (π), -X spawn faces +X (0).
		bState.facingAngle = (sx < 0) and 0 or math.pi
		bState.targetFacing = bState.facingAngle
		-- Launched into the arena with forward momentum toward the centre.
		local dir = Vector3.new(math.cos(bState.facingAngle), 0, math.sin(bState.facingAngle))
		bState.velocity = dir * Constants.LaunchImpulseSpeed
		newState.beyStates[pid] = bState

		createPrototypeBeyModel(pid, i == 1)
	end

	TickManager.Start()

	-- Broadcast match start (Countdown phase)
	local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
	Remotes.MatchStateChanged:FireAllClients(newState.phase, {
		matchId = newState.matchId,
		seed = newState.matchSeed,
		players = playerIds,
		countdownEndTime = newState.timers.countdownEndTime,
	})
end

function MatchManager.CleanupMatch()
	TickManager.Stop()
	stadiumSpawned = false
	for _, part in ipairs(workspace:GetChildren()) do
		local n = part.Name
		if string.sub(n, 1, 4) == "Bey_"
			or n == "StadiumFloor" or n == "StadiumWalls"
			or n == "StadiumCenter" then
			part:Destroy()
		end
	end
	print("[Match] Match cleaned up.")
	if _onMatchCleanedUpCallback then
		_onMatchCleanedUpCallback()
	end
end

TickManager.SetMatchFinishedCallback(function()
	print("[Match] Match finished callback triggered. Restarting in 5 seconds...")
	task.wait(5)

	local Players = game:GetService("Players")
	local validPlayers = {}
	for _, pid in ipairs(currentPlayers) do
		if Players:GetPlayerByUserId(pid) then
			table.insert(validPlayers, pid)
		end
	end

	MatchManager.CleanupMatch()

	if _onReadyForRematch then
		_onReadyForRematch(validPlayers)
	elseif #validPlayers > 0 then
		MatchManager.StartNewMatch(validPlayers)
	else
		print("[Match] Not enough players to restart match.")
	end
end)

return MatchManager
