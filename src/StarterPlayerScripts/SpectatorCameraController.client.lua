--[=[
	SpectatorCameraController.client.lua
	Live, toggleable camera. Mode is published by the HUD via the local player's
	"CameraMode" attribute (Spectator → Top → Side → BeyView), and can also be
	cycled with the V key.

	  • Spectator — fixed isometric view of the flat arena (default).
	  • Top       — straight-down.
	  • Side      — low-angle side view.
	  • BeyView   — first-person at the player's Bey, looking outward along its
	                facing. Follows facing with damping (never spins with the Bey's
	                angular velocity — that would be nauseating).
]=]
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local localPlayer = Players.LocalPlayer
local R = Constants.StadiumRadius

-- ── Track the local Bey's facing from snapshots ──────────────────────────────────
local localFacing = 0
local smoothedFacing = 0

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	local st = snapshot.beyStates and snapshot.beyStates[localPlayer.UserId]
	if st and st.facingAngle then
		localFacing = st.facingAngle
	end
end)

local function getLocalBeyPos()
	local model = workspace:FindFirstChild("Bey_" .. tostring(localPlayer.UserId))
	if model and model.PrimaryPart then
		return model:GetPivot().Position
	end
	return nil
end

-- Shortest-path angular lerp.
local function lerpAngle(a, b, t)
	local diff = (b - a + math.pi) % (math.pi * 2) - math.pi
	return a + diff * t
end

local function getMode()
	return localPlayer:GetAttribute("CameraMode") or "Spectator"
end

-- V cycles modes locally too (mirrors the HUD button).
local MODES = { "Spectator", "Top", "Side", "BeyView" }
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.V then
		local cur = getMode()
		local idx = table.find(MODES, cur) or 1
		localPlayer:SetAttribute("CameraMode", MODES[(idx % #MODES) + 1])
	end
end)

local camera = workspace.CurrentCamera
if camera then
	camera.CameraType = Enum.CameraType.Scriptable
end

RunService.RenderStepped:Connect(function(dt)
	camera = workspace.CurrentCamera
	if not camera then return end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	local mode = getMode()
	local target

	if mode == "Top" then
		target = CFrame.lookAt(Vector3.new(0, R * 2.4, 0.01), Vector3.new(0, 0, 0))
	elseif mode == "Side" then
		target = CFrame.lookAt(Vector3.new(0, 7, R * 2.0), Vector3.new(0, 2, 0))
	elseif mode == "BeyView" then
		local pos = getLocalBeyPos()
		if pos then
			smoothedFacing = lerpAngle(smoothedFacing, localFacing, math.clamp(dt * 8, 0, 1))
			local dir = Vector3.new(math.cos(smoothedFacing), 0, math.sin(smoothedFacing))
			local camPos = pos - dir * (Constants.BeyRadius + 1.5) + Vector3.new(0, 2.5, 0)
			target = CFrame.lookAt(camPos, pos + dir * 12)
		else
			target = CFrame.lookAt(Vector3.new(0, R * 1.5, R * 1.4), Vector3.new(0, 0, 0))
		end
	else -- Spectator
		target = CFrame.lookAt(Vector3.new(0, R * 1.5, R * 1.4), Vector3.new(0, 0, 0))
	end

	-- Smooth transitions (snappier for BeyView so it tracks the Bey).
	local blend = (mode == "BeyView") and math.clamp(dt * 12, 0, 1) or math.clamp(dt * 6, 0, 1)
	camera.CFrame = camera.CFrame:Lerp(target, blend)
end)
