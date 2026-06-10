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
		return block:SubtractAsync({sphere}, Enum.CollisionFidelity.Default, Enum.RenderFidelity.Precise)
	end)

	if success and curvyBowl then
		curvyBowl.Name = "StadiumFloor"
		curvyBowl.Anchored = true
		curvyBowl.CanCollide = true
		curvyBowl.Material = Enum.Material.SmoothPlastic
		curvyBowl.Color = Color3.fromRGB(245, 245, 250)
		curvyBowl.CFrame = block.CFrame
		curvyBowl.Parent = workspace
	else
		warn("[MatchManager] Failed to generate perfectly curvy stadium! CSG Error.")
		stadiumSpawned = false
		return
	end

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

	for i, pid in ipairs(playerIds) do
		local bState = MatchState.createBeyState(pid)
		-- Spawn high above the bowl (Y=10); gentle pre-launch drift only.
		-- The player's launch input supplies the real impulse.
		local side = (i == 1) and -1 or 1
		bState.position = Vector3.new(side * 10, 10, 0)
		bState.velocity = Vector3.new(
			-side * Constants.SpawnInwardSpeed,
			0,
			-side * Constants.SpawnTangentialSpeed
		)
		bState.previousPosition = bState.position
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
			or n == "StadiumFloor" or n == "StadiumWall"
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
