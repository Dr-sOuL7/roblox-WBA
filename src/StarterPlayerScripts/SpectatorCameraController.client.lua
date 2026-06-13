--[=[
    SpectatorCameraController.client.lua
    Two camera modes:
      • Hub      — normal follow camera while walking around as a character.
      • Battle   — fixed isometric lock on the player's arena during a match.

    Switches to Battle when a match starts for this client (MatchStateChanged
    reaches Setup/Countdown/Active) and back to Hub when the character respawns
    (CharacterAdded after the match). The isometric lock is enforced every frame
    during battle, matching the validated single-arena framing.
]=]
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local localPlayer = Players.LocalPlayer

local CAMERA_HEIGHT_FACTOR = 1.5
local CAMERA_DISTANCE_FACTOR = 1.5

local function eyeOffsetFor(playableRadius: number): Vector3
	return Vector3.new(
		0,
		playableRadius * CAMERA_HEIGHT_FACTOR,
		playableRadius * CAMERA_DISTANCE_FACTOR
	)
end

local eyeOffset = eyeOffsetFor(Constants.BowlPlayableRadius)
local arenaOrigin = Vector3.new(0, 0, 0)
local inBattle = false

local function enterHubCamera()
	inBattle = false
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		local character = localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

Remotes.MatchStateChanged.OnClientEvent:Connect(function(phase, data)
	if data and data.arenaOrigin then
		arenaOrigin = data.arenaOrigin
	end
	if data and data.stadiumId then
		eyeOffset = eyeOffsetFor(Stadiums.get(data.stadiumId).playableRadius)
	end
	-- Any in-match phase pins the battle camera. (Finished keeps it until the
	-- character respawns in the hub.)
	if phase == "Setup" or phase == "Countdown" or phase == "Active" or phase == "Finished" then
		inBattle = true
	end
end)

-- Respawning in the hub returns control to the normal follow camera.
localPlayer.CharacterAdded:Connect(function()
	-- Small wait so Roblox finishes its own camera setup before we claim it
	task.wait(0.1)
	enterHubCamera()
end)
if localPlayer.Character then
	enterHubCamera()
end

RunService.RenderStepped:Connect(function()
	if not inBattle then return end
	local camera = workspace.CurrentCamera
	if not camera then return end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	camera.CFrame = CFrame.lookAt(arenaOrigin + eyeOffset, arenaOrigin)
end)

-- Disable the core Reset button: resetting mid-battle would spawn a hub
-- character while the Bey is still fighting and desync the camera. Respawning
-- is automatic when a match ends. SetCore throws until CoreGui registers — retry.
task.spawn(function()
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end)
		if ok then return end
		task.wait(1)
	end
end)
