--[=[
	InputController.client.lua
	Listens for user inputs and securely pushes them to the server.
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local localPlayer = Players.LocalPlayer
local sequenceId = 0

-- Multi-match (ADR-001): Bey models live under workspace.Matches[matchId] and
-- our arena's centre is its origin, not the world origin.
local currentMatchId = nil
local arenaOrigin = Vector3.new(0, 0, 0)

Remotes.MatchStateChanged.OnClientEvent:Connect(function(_phase, data)
	if data and data.matchId then
		currentMatchId = data.matchId
	end
	if data and data.arenaOrigin then
		arenaOrigin = data.arenaOrigin
	end
end)

local function findBeyModel()
	local matches = workspace:FindFirstChild("Matches")
	local folder = matches and currentMatchId and matches:FindFirstChild(currentMatchId)
	return folder and folder:FindFirstChild("Bey_" .. tostring(localPlayer.UserId)) or nil
end

-- Aim the prototype launch at the bowl centre from this Bey's own spawn.
-- A fixed world-space vector is wrong for one of the two seats: from the
-- +X spawn it points outward and ring-outs the launcher immediately.
-- The launch vector is consumed in the simulation's LOCAL space; aiming at
-- the arena origin in world space yields exactly that local-space direction.
local function computeLaunchVector(): Vector3
	local fallback = Vector3.new(0, 0, -Constants.PrototypeLaunchSpeed)

	local beyModel = findBeyModel()
	if not beyModel or not beyModel.PrimaryPart then
		return fallback
	end

	local toCenter = arenaOrigin - beyModel.PrimaryPart.Position
	toCenter = Vector3.new(toCenter.X, 0, toCenter.Z)
	if toCenter.Magnitude < 0.5 then
		return fallback -- already at centre; direction is arbitrary
	end

	return toCenter.Unit * Constants.PrototypeLaunchSpeed
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	-- Press 'F' to launch
	if input.KeyCode == Enum.KeyCode.F then
		sequenceId += 1
		print("[Client:Input] Local input received: Launch (F key)")

		local launchData = {
			launchVector = computeLaunchVector(),
			spinPower = Constants.PrototypeLaunchSpin,
		}

		Remotes.RequestLaunch:FireServer(sequenceId, launchData)
		print(string.format("[Client:Input] Remote launch request sent (Seq: %d)", sequenceId))
	end
end)
