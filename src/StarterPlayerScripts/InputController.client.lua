--[=[
	InputController.client.lua
	Listens for user inputs and securely pushes them to the server.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local sequenceId = 0

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	-- Press 'F' to launch
	if input.KeyCode == Enum.KeyCode.F then
		sequenceId += 1
		print("[Client:Input] Local input received: Launch (F key)")

		-- Prototype 1 deterministic fixed launch data
		local launchData = {
			launchVector = Vector3.new(15, 0, -15), -- Fixed vector for testing repeatability
			spinPower = 100,
		}

		Remotes.RequestLaunch:FireServer(sequenceId, launchData)
		print(string.format("[Client:Input] Remote launch request sent (Seq: %d)", sequenceId))
	end
end)
