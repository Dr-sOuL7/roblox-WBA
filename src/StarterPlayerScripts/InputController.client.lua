--[=[
	InputController.client.lua
	Real-time analog control: a virtual joystick (sets facing) plus DASH and
	REVOLVE hold-buttons, mirrored on the keyboard. Sends a compact input packet
	{ facingAngle, dash, revolve } to the server ~15 Hz, and an F-key launch ("GO").

	Joystick is world-relative for the default top-down camera: pushing UP aims the
	Bey "north" (world −Z), RIGHT aims +X. Dash and Revolve may be held together
	(combo = revolve at 3× speed). The server only applies facing when neither
	ability is held, and gates abilities on Mana — this is purely intent.
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local TWO_PI = math.pi * 2

-- ── Shared intent state ────────────────────────────────────────────────────────
local facingAngle = 0
local dashHeld = false
local revolveHeld = false
local currentPhase = "None"
local launchSeq = 0

-- Joystick state
local joystickActive = false
local joystickInput = nil -- the InputObject currently driving the stick (touch/mouse)

-- Keyboard direction held-set
local keyVec = { x = 0, z = 0 }

-- ── GUI ─────────────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "ControlsGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- Joystick (bottom-left)
local JOY_RADIUS = 80
local joyBase = Instance.new("Frame")
joyBase.Name = "JoystickBase"
joyBase.AnchorPoint = Vector2.new(0.5, 0.5)
joyBase.Position = UDim2.new(0, 130, 1, -130)
joyBase.Size = UDim2.fromOffset(JOY_RADIUS * 2, JOY_RADIUS * 2)
joyBase.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
joyBase.BackgroundTransparency = 0.4
joyBase.Parent = gui
local joyBaseCorner = Instance.new("UICorner")
joyBaseCorner.CornerRadius = UDim.new(1, 0)
joyBaseCorner.Parent = joyBase
local joyBaseStroke = Instance.new("UIStroke")
joyBaseStroke.Color = Color3.fromRGB(120, 150, 255)
joyBaseStroke.Thickness = 2
joyBaseStroke.Transparency = 0.3
joyBaseStroke.Parent = joyBase

local joyThumb = Instance.new("Frame")
joyThumb.Name = "Thumb"
joyThumb.AnchorPoint = Vector2.new(0.5, 0.5)
joyThumb.Position = UDim2.fromScale(0.5, 0.5)
joyThumb.Size = UDim2.fromOffset(64, 64)
joyThumb.BackgroundColor3 = Color3.fromRGB(120, 150, 255)
joyThumb.BackgroundTransparency = 0.1
joyThumb.Parent = joyBase
local joyThumbCorner = Instance.new("UICorner")
joyThumbCorner.CornerRadius = UDim.new(1, 0)
joyThumbCorner.Parent = joyThumb

-- Ability buttons (bottom-right)
local function makeAbilityButton(name, posY, color)
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.AnchorPoint = Vector2.new(1, 1)
	btn.Position = UDim2.new(1, -40, 1, -posY)
	btn.Size = UDim2.fromOffset(150, 90)
	btn.BackgroundColor3 = color
	btn.AutoButtonColor = false
	btn.Font = Enum.Font.GothamBlack
	btn.TextSize = 26
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Text = name
	btn.Parent = gui
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 16)
	c.Parent = btn
	local s = Instance.new("UIStroke")
	s.Color = Color3.new(1, 1, 1)
	s.Thickness = 2
	s.Transparency = 0.5
	s.Parent = btn
	return btn
end

local dashButton = makeAbilityButton("DASH", 40, Color3.fromRGB(220, 70, 40))
local revolveButton = makeAbilityButton("REVOLVE", 150, Color3.fromRGB(90, 70, 220))

-- ── Joystick handling ──────────────────────────────────────────────────────────
local function updateJoystick(screenPos)
	local center = joyBase.AbsolutePosition + joyBase.AbsoluteSize * 0.5
	local delta = Vector2.new(screenPos.X - center.X, screenPos.Y - center.Y)
	local mag = delta.Magnitude
	if mag > JOY_RADIUS then
		delta = delta.Unit * JOY_RADIUS
		mag = JOY_RADIUS
	end
	joyThumb.Position = UDim2.new(0.5, delta.X, 0.5, delta.Y)
	if mag > JOY_RADIUS * 0.18 then
		-- screen-right (delta.X+) → world +X; screen-down (delta.Y+) → world +Z
		facingAngle = math.atan2(delta.Y, delta.X) % TWO_PI
	end
end

local function resetJoystick()
	joystickActive = false
	joystickInput = nil
	joyThumb.Position = UDim2.fromScale(0.5, 0.5)
end

joyBase.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		joystickActive = true
		joystickInput = input
		updateJoystick(input.Position)
	end
end)

-- ── Ability button hold handling (mouse + touch) ────────────────────────────────
local function bindHold(button, setHeld)
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			setHeld(true)
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			setHeld(false)
		end
	end)
end
bindHold(dashButton, function(v) dashHeld = v end)
bindHold(revolveButton, function(v) revolveHeld = v end)

-- ── Global input (drag continuation, release, keyboard) ─────────────────────────
local function recomputeKeyFacing()
	if keyVec.x ~= 0 or keyVec.z ~= 0 then
		facingAngle = math.atan2(keyVec.z, keyVec.x) % TWO_PI
	end
end

UserInputService.InputChanged:Connect(function(input)
	if joystickActive and input == joystickInput and input.UserInputType == Enum.UserInputType.Touch then
		updateJoystick(input.Position)
	elseif joystickActive and input.UserInputType == Enum.UserInputType.MouseMovement then
		updateJoystick(input.Position)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input == joystickInput then
		resetJoystick()
	end
	-- Release keyboard direction / abilities
	if input.UserInputType == Enum.UserInputType.Keyboard then
		local kc = input.KeyCode
		if kc == Enum.KeyCode.D or kc == Enum.KeyCode.Right then keyVec.x = (keyVec.x == 1) and 0 or keyVec.x end
		if kc == Enum.KeyCode.A or kc == Enum.KeyCode.Left then keyVec.x = (keyVec.x == -1) and 0 or keyVec.x end
		if kc == Enum.KeyCode.S or kc == Enum.KeyCode.Down then keyVec.z = (keyVec.z == 1) and 0 or keyVec.z end
		if kc == Enum.KeyCode.W or kc == Enum.KeyCode.Up then keyVec.z = (keyVec.z == -1) and 0 or keyVec.z end
		if kc == Enum.KeyCode.Space then dashHeld = false end
		if kc == Enum.KeyCode.LeftShift or kc == Enum.KeyCode.RightShift then revolveHeld = false end
		recomputeKeyFacing()
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local kc = input.KeyCode
	if kc == Enum.KeyCode.D or kc == Enum.KeyCode.Right then keyVec.x = 1 end
	if kc == Enum.KeyCode.A or kc == Enum.KeyCode.Left then keyVec.x = -1 end
	if kc == Enum.KeyCode.S or kc == Enum.KeyCode.Down then keyVec.z = 1 end
	if kc == Enum.KeyCode.W or kc == Enum.KeyCode.Up then keyVec.z = -1 end
	if kc == Enum.KeyCode.Space then dashHeld = true end
	if kc == Enum.KeyCode.LeftShift or kc == Enum.KeyCode.RightShift then revolveHeld = true end
	recomputeKeyFacing()

	-- F = launch / GO
	if kc == Enum.KeyCode.F then
		launchSeq += 1
		Remotes.RequestLaunch:FireServer(launchSeq, {
			spinPower = 90,
			facingAngle = facingAngle,
			launchQuality = 1.0,
		})
	end
end)

-- ── Phase tracking ──────────────────────────────────────────────────────────────
Remotes.MatchStateChanged.OnClientEvent:Connect(function(phase)
	currentPhase = phase
	if phase ~= "Active" then
		dashHeld = false
		revolveHeld = false
	end
end)

-- ── Button visual feedback ──────────────────────────────────────────────────────
local function styleButton(btn, held)
	btn.BackgroundTransparency = held and 0 or 0.25
	local stroke = btn:FindFirstChildOfClass("UIStroke")
	if stroke then stroke.Transparency = held and 0 or 0.5 end
end

-- ── Send loop (~15 Hz) ──────────────────────────────────────────────────────────
local sendAccum = 0
local SEND_INTERVAL = 1 / 15
RunService.Heartbeat:Connect(function(dt)
	styleButton(dashButton, dashHeld)
	styleButton(revolveButton, revolveHeld)

	if currentPhase ~= "Active" then return end
	sendAccum += dt
	if sendAccum < SEND_INTERVAL then return end
	sendAccum = 0

	Remotes.InputUpdate:FireServer({
		facingAngle = facingAngle,
		dash = dashHeld,
		revolve = revolveHeld,
	})
end)
