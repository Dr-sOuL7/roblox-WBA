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

-- Aim the prototype launch at the bowl centre from this Bey's own spawn.
-- A fixed world-space vector is wrong for one of the two seats: from the
-- +X spawn it points outward and ring-outs the launcher immediately.
local function computeLaunchVector(): Vector3
	local fallback = Vector3.new(0, 0, -Constants.PrototypeLaunchSpeed)

	local beyModel = workspace:FindFirstChild("Bey_" .. tostring(localPlayer.UserId))
	if not beyModel or not beyModel.PrimaryPart then
		return fallback
	end

	local pos = beyModel.PrimaryPart.Position
	local toCenter = Vector3.new(-pos.X, 0, -pos.Z)
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
