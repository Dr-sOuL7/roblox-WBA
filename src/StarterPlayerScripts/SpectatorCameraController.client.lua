--[=[
    SpectatorCameraController.client.lua
    Locks the local player's camera to a fixed isometric stadium view.
    Ensures players can watch the battle clearly from launch to finish.

    The lock is enforced every frame: Roblox resets CameraType/CameraSubject
    whenever a character spawns or the camera subject changes, so a one-shot
    assignment silently reverts (the exact failure called out in the Phase 1
    validation plan).
]=]
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

-- Frame the bowl from a 45° isometric angle, scaled to the match's stadium so
-- every variant stays framed. At radius 20: eye (0, 30, 30) → ~42 studs from
-- origin; default 70° FOV spans ~59 studs there, containing the stadium block.
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

-- Multi-match (ADR-001): the server assigns this client's match an arena
-- origin; the camera frames THAT bowl. Defaults to slot 1 until assigned.
local arenaOrigin = Vector3.new(0, 0, 0)

Remotes.MatchStateChanged.OnClientEvent:Connect(function(_phase, data)
	if data and data.arenaOrigin then
		arenaOrigin = data.arenaOrigin
	end
	if data and data.stadiumId then
		eyeOffset = eyeOffsetFor(Stadiums.get(data.stadiumId).playableRadius)
	end
end)

local function enforceCameraLock()
	local camera = workspace.CurrentCamera
	if not camera then return end

	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	camera.CFrame = CFrame.lookAt(arenaOrigin + eyeOffset, arenaOrigin)
end

enforceCameraLock()
RunService.RenderStepped:Connect(enforceCameraLock)

-- No character exists (CharacterAutoLoads is off), so the core Reset button is
-- meaningless; disable it. SetCore throws if CoreGui hasn't registered yet — retry.
task.spawn(function()
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", false)
		end)
		if ok then return end
		task.wait(1)
	end
end)
