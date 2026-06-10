-- src/StarterPlayerScripts/DebugOverlayUI.client.lua
-- Developer overlay. Hidden by default so readability sessions see a clean
-- screen (the Phase 1 legibility gate asks whether players can read the match
-- WITHOUT debug aids). Toggle with F2.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "BeyArenaDebugOverlay"
gui.ResetOnSpawn = false
gui.Enabled = false

local textLabel = Instance.new("TextLabel")
textLabel.Size = UDim2.new(0, 300, 0, 400)
textLabel.Position = UDim2.new(0, 10, 0, 10)
textLabel.BackgroundTransparency = 0.5
textLabel.BackgroundColor3 = Color3.new(0,0,0)
textLabel.TextColor3 = Color3.new(1,1,1)
textLabel.TextXAlignment = Enum.TextXAlignment.Left
textLabel.TextYAlignment = Enum.TextYAlignment.Top
textLabel.TextSize = 14
textLabel.Font = Enum.Font.Code
textLabel.Parent = gui

gui.Parent = playerGui

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.F2 then
		gui.Enabled = not gui.Enabled
		print(string.format("[DebugOverlay] %s", gui.Enabled and "ON" or "OFF"))
	end
end)

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
    local display = "--- BEY ARENA DEBUG ---\n"
    display ..= "Tick: " .. snapshot.tickNumber .. "\n"
    display ..= "Time: " .. string.format("%.2f", snapshot.serverTimestamp) .. "\n\n"
    
    for pid, bState in pairs(snapshot.beyStates) do
        display ..= "Player " .. tostring(pid) .. " (" .. bState.zoneState .. ")\n"
        display ..= string.format(" Pos: %.1f, %.1f, %.1f\n", bState.position.X, bState.position.Y, bState.position.Z)
        display ..= string.format(" Vel: %.1f, %.1f, %.1f\n", bState.velocity.X, bState.velocity.Y, bState.velocity.Z)
        display ..= string.format(" RPM: %.1f | Tilt: %.1f\n", bState.angularVelocity.Magnitude, bState.tilt)
        display ..= string.format(" Stability: %.1f\n\n", bState.stability)
    end
    
    for _, ev in ipairs(snapshot.events) do
        display ..= "EVENT: " .. ev.eventType .. "\n"
    end
    
    textLabel.Text = display
end)
