--[=[
    SpectatorCameraController.client.lua
    Camera ownership for the two game contexts:
      • Hub      — normal follow camera while walking around as a character.
      • Battle   — a player-chosen view that LOCKS onto the live Bey positions so
                   the steering commands (TOWARDS / CENTRE / AWAY) read clearly.

    Battle offers three switchable modes (cycle with the on-screen button or the
    `C` key):
      • First Person — eye rides the player's own Bey and always faces the
                       opponent's Bey, so a TOWARDS lunge rushes the screen and an
                       AWAY dodge pulls back.
      • Top View     — straight-down plan view; relative motion (towards / centre /
                       away) reads as a clean 2-D diagram.
      • Side View    — low broadcast angle framed across the duel so both Beys and
                       the bowl curvature are visible.

    Positions come from the rendered Bey models (InterpolationRenderer already
    smooths them), and the camera lerps toward its target each frame so mode
    switches and Bey motion stay fluid.
]=]
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local UP = Vector3.new(0, 1, 0)

-- ── Battle state ──────────────────────────────────────────────────────────────

local playableRadius = Constants.BowlPlayableRadius
local arenaOrigin = Vector3.new(0, 0, 0)
local inBattle = false
local smoothedCF = nil -- running camera CFrame; nil → snap on the next frame
local lastSide = Vector3.new(0, 0, 1) -- Side-view continuity (avoids 180° flips)

-- ── Camera modes ──────────────────────────────────────────────────────────────

local MODES = { "FirstPerson", "Top", "Side" }
local MODE_LABELS = { FirstPerson = "FIRST PERSON", Top = "TOP VIEW", Side = "SIDE VIEW" }
local modeIndex = 3 -- default: Side (cinematic, both Beys framed)

local function currentMode()
	return MODES[modeIndex]
end

-- ── Locate the live Bey models for this client's match ────────────────────────
-- Models live under workspace.Matches[matchId]; we find ours by the folder that
-- contains Bey_<localUserId>, then the opponent is the other Bey_* in it.

local function findMatchFolder()
	local matches = workspace:FindFirstChild("Matches")
	if not matches then return nil end
	local selfName = "Bey_" .. tostring(localPlayer.UserId)
	for _, folder in ipairs(matches:GetChildren()) do
		if folder:FindFirstChild(selfName) then
			return folder
		end
	end
	return nil
end

local function beyPositions()
	local folder = findMatchFolder()
	if not folder then return nil, nil end
	local selfModel = folder:FindFirstChild("Bey_" .. tostring(localPlayer.UserId))
	local oppModel = nil
	for _, child in ipairs(folder:GetChildren()) do
		if child ~= selfModel and child:IsA("Model") and string.sub(child.Name, 1, 4) == "Bey_" then
			oppModel = child
			break
		end
	end
	local selfPos = selfModel and selfModel:GetPivot().Position or nil
	local oppPos = oppModel and oppModel:GetPivot().Position or nil
	return selfPos, oppPos
end

-- ── Target CFrame per mode ─────────────────────────────────────────────────────

local function targetCFrame()
	local center = arenaOrigin
	local selfPos, oppPos = beyPositions()
	local mode = currentMode()

	if mode == "Top" then
		-- Straight down; fix "north" so the plan view never spins.
		local eye = center + Vector3.new(0, playableRadius * 2.4, 0)
		return CFrame.lookAt(eye, center, Vector3.new(0, 0, -1))

	elseif mode == "FirstPerson" then
		if selfPos then
			local look = oppPos or center
			local flat = Vector3.new(look.X - selfPos.X, 0, look.Z - selfPos.Z)
			if flat.Magnitude < 0.05 then
				flat = Vector3.new(0, 0, -1)
			else
				flat = flat.Unit
			end
			-- Eye just above and slightly behind our own Bey, aimed at the
			-- opponent (a sliver above it so it sits in frame, not at the floor).
			local eye = selfPos + UP * 2.4 - flat * 3.2
			return CFrame.lookAt(eye, Vector3.new(look.X, look.Y + 1.0, look.Z))
		end
		-- Before models stream in: a low forward shot toward the bowl.
		local eye = center + Vector3.new(0, playableRadius * 0.6, playableRadius * 1.4)
		return CFrame.lookAt(eye, center)

	else -- Side
		-- Frame perpendicular to the line between the Beys so both spread across
		-- the screen; keep the chosen side continuous to avoid 180° flips.
		local side = lastSide
		if selfPos and oppPos then
			local axis = Vector3.new(oppPos.X - selfPos.X, 0, oppPos.Z - selfPos.Z)
			if axis.Magnitude > 0.1 then
				axis = axis.Unit
				local perp = Vector3.new(-axis.Z, 0, axis.X)
				if perp:Dot(lastSide) < 0 then
					perp = -perp
				end
				side = perp
			end
		end
		lastSide = side
		local eye = center + side * (playableRadius * 2.2) + UP * (playableRadius * 0.7)
		return CFrame.lookAt(eye, center + UP * (playableRadius * 0.15))
	end
end

-- ── Mode-toggle UI (touch + keyboard) ─────────────────────────────────────────

local camGui = Instance.new("ScreenGui")
camGui.Name = "CameraModeGui"
camGui.ResetOnSpawn = false
camGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
camGui.Parent = playerGui

-- Right edge, vertically centred: clear of the command panel (bottom centre),
-- the queue/skin panels (top right) and the mobile movement controls (corners).
local camButton = Instance.new("TextButton")
camButton.Name = "CameraModeButton"
camButton.Size = UDim2.fromOffset(176, 48)
camButton.AnchorPoint = Vector2.new(1, 0.5)
camButton.Position = UDim2.new(1, -16, 0.5, 60)
camButton.BackgroundColor3 = Color3.fromRGB(35, 35, 52)
camButton.BackgroundTransparency = 0.1
camButton.BorderSizePixel = 0
camButton.Font = Enum.Font.GothamBold
camButton.TextSize = 17
camButton.TextColor3 = Color3.fromRGB(235, 235, 245)
camButton.AutoButtonColor = true
camButton.Text = MODE_LABELS[currentMode()]
camButton.Visible = false
local camCorner = Instance.new("UICorner")
camCorner.CornerRadius = UDim.new(0, 10)
camCorner.Parent = camButton
camButton.Parent = camGui

local camHint = Instance.new("TextLabel")
camHint.Name = "CameraModeHint"
camHint.Size = UDim2.fromOffset(176, 16)
camHint.AnchorPoint = Vector2.new(1, 0.5)
camHint.Position = UDim2.new(1, -16, 0.5, 28)
camHint.BackgroundTransparency = 1
camHint.Font = Enum.Font.Gotham
camHint.TextSize = 12
camHint.TextColor3 = Color3.fromRGB(190, 190, 205)
camHint.TextStrokeTransparency = 0.6
camHint.Text = "CAMERA · tap / C"
camHint.Visible = false
camHint.Parent = camGui

local function refreshCamButton()
	camButton.Text = MODE_LABELS[currentMode()]
end

local function cycleMode()
	modeIndex = (modeIndex % #MODES) + 1
	refreshCamButton()
end

camButton.MouseButton1Click:Connect(cycleMode)

local function setCamUiVisible(visible)
	camButton.Visible = visible
	camHint.Visible = visible
end

-- ── Hub camera restore ─────────────────────────────────────────────────────────

local function enterHubCamera()
	inBattle = false
	smoothedCF = nil
	setCamUiVisible(false)
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

-- ── Phase wiring ────────────────────────────────────────────────────────────────

Remotes.MatchStateChanged.OnClientEvent:Connect(function(phase, data)
	if data and data.arenaOrigin then
		arenaOrigin = data.arenaOrigin
	end
	if data and data.stadiumId then
		playableRadius = Stadiums.get(data.stadiumId).playableRadius
	end
	-- Any in-match phase pins the battle camera. (Finished keeps the lock until
	-- the character respawns in the hub, but hides the toggle so the result is clean.)
	if phase == "Setup" or phase == "Countdown" or phase == "Active" or phase == "Finished" then
		if not inBattle then
			smoothedCF = nil -- snap to the first battle frame instead of swooping in
		end
		inBattle = true
		setCamUiVisible(phase ~= "Finished")
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if inBattle and input.KeyCode == Enum.KeyCode.C then
		cycleMode()
	end
end)

-- Respawning in the hub returns control to the normal follow camera.
localPlayer.CharacterAdded:Connect(function()
	task.wait(0.1) -- let Roblox finish its own camera setup before we claim it
	enterHubCamera()
end)
if localPlayer.Character then
	enterHubCamera()
end

RunService.RenderStepped:Connect(function(dt)
	if not inBattle then return end
	local camera = workspace.CurrentCamera
	if not camera then return end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	local target = targetCFrame()
	if smoothedCF == nil then
		smoothedCF = target
	else
		-- Frame-rate-independent smoothing; first person follows tighter since
		-- the eye rides a fast-moving Bey.
		local k = (currentMode() == "FirstPerson") and 16 or 9
		local alpha = 1 - math.exp(-k * dt)
		smoothedCF = smoothedCF:Lerp(target, alpha)
	end
	camera.CFrame = smoothedCF
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
