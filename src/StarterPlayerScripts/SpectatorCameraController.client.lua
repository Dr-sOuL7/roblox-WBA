--[=[
    SpectatorCameraController.client.lua
    Locks the local player's camera to a fixed isometric stadium view.
    Ensures players can watch the battle clearly from launch to finish.
]=]
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer

local function lockCamera()
    local camera = workspace.CurrentCamera
    if not camera then return end

    -- Position high and slightly back, looking at center (0,0,0)
    local targetCFrame = CFrame.lookAt(Vector3.new(0, 30, 30), Vector3.new(0, 0, 0))
    
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = targetCFrame
end

-- Constantly enforce the camera lock so it doesn't reset when characters spawn/die
-- RunService.RenderStepped:Connect(lockCamera)

-- Re-enable custom camera if it was locked
local camera = workspace.CurrentCamera
if camera then
    camera.CameraType = Enum.CameraType.Custom
end
