--[=[
	UIController.client.lua
	Battle + meta HUD:
	  • status / countdown / result labels,
	  • the launch ceremony (Setup → aim sliders → READY → 3·2·1·GO → LAUNCH/F),
	  • per-Bey HP + Mana bars (battle),
	  • queue / rank / skin panels (hub).
	Battle steering (joystick + Dash/Revolve) lives in InputController; the camera
	toggle lives in SpectatorCameraController.
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local LaunchQuality = require(ReplicatedStorage:WaitForChild("LaunchQuality"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local Cosmetics = require(ReplicatedStorage:WaitForChild("Cosmetics"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- ── Screen GUI ────────────────────────────────────────────────────────────────

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MatchStatusGui"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

-- ── Status label (top centre) ─────────────────────────────────────────────────

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.Size = UDim2.new(1, 0, 0, 100)
statusLabel.Position = UDim2.new(0, 0, 0, 50)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamBold
statusLabel.TextSize = 48
statusLabel.TextColor3 = Color3.new(1, 1, 1)
statusLabel.TextStrokeTransparency = 0
statusLabel.Text = "Waiting for match..."
statusLabel.Parent = screenGui

-- ── Result label (centre screen) ──────────────────────────────────────────────

local resultLabel = Instance.new("TextLabel")
resultLabel.Name = "ResultLabel"
resultLabel.Size = UDim2.new(1, 0, 0, 150)
resultLabel.Position = UDim2.new(0, 0, 0.5, -75)
resultLabel.BackgroundTransparency = 1
resultLabel.Font = Enum.Font.GothamBlack
resultLabel.TextSize = 72
resultLabel.TextColor3 = Color3.fromRGB(255, 204, 0)
resultLabel.TextStrokeTransparency = 0
resultLabel.Text = ""
resultLabel.Visible = false
resultLabel.Parent = screenGui

-- ── Per-Bey HP + Mana bars ─────────────────────────────────────────────────────
-- A stat block = name + HP bar + Mana bar. `side` is "left" (you) or "right" (opp).

local function makeStatBlock(side, title)
	local holder = Instance.new("Frame")
	holder.Name = "Stat_" .. side
	holder.Size = UDim2.fromOffset(340, 86)
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(side == "left" and 0 or 1, 0)
	holder.Position = side == "left" and UDim2.new(0, 16, 0, 8) or UDim2.new(1, -16, 0, 8)
	holder.Visible = false
	holder.Parent = screenGui

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, 0, 0, 22)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextSize = 18
	name.TextColor3 = Color3.new(1, 1, 1)
	name.TextStrokeTransparency = 0.3
	name.TextXAlignment = side == "left" and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right
	name.Text = title
	name.Parent = holder

	local function bar(yOffset, bgColor)
		local back = Instance.new("Frame")
		back.Size = UDim2.new(1, 0, 0, 26)
		back.Position = UDim2.new(0, 0, 0, yOffset)
		back.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
		back.BackgroundTransparency = 0.25
		back.Parent = holder
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0, 6)
		bc.Parent = back

		local fill = Instance.new("Frame")
		fill.Size = UDim2.new(1, 0, 1, 0)
		fill.BackgroundColor3 = bgColor
		fill.BorderSizePixel = 0
		fill.Parent = back
		local fc = Instance.new("UICorner")
		fc.CornerRadius = UDim.new(0, 6)
		fc.Parent = fill

		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1, -8, 1, 0)
		lbl.Position = UDim2.new(0, 4, 0, 0)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 15
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.TextStrokeTransparency = 0.4
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.Parent = back
		return fill, lbl
	end

	local hpFill, hpLbl = bar(28, Color3.fromRGB(60, 220, 80))
	local manaFill, manaLbl = bar(58, Color3.fromRGB(60, 170, 255))
	return { hpFill = hpFill, hpLbl = hpLbl, manaFill = manaFill, manaLbl = manaLbl, holder = holder }
end

local leftBlock = makeStatBlock("left", "YOU")
local rightBlock = makeStatBlock("right", "OPPONENT")

local function setStatBlocksVisible(visible)
	leftBlock.holder.Visible = visible
	rightBlock.holder.Visible = visible
end

local function hpColor(ratio)
	if ratio > 0.6 then
		return Color3.fromRGB(60, 220, 80)
	elseif ratio > 0.3 then
		return Color3.fromRGB(235, 200, 60)
	end
	return Color3.fromRGB(235, 70, 60)
end

-- ── Match phase state (declared early: ceremony handlers close over these) ───

local currentPhase = "None"
local countdownEndTime = 0

-- ── Launch ceremony UI (Setup → READY → 3·2·1·GO → LAUNCH) ───────────────────
-- Sliders submit ONLY numbers; the server clamps them and builds the vector.

local setupPanel = Instance.new("Frame")
setupPanel.Name = "SetupPanel"
setupPanel.Size = UDim2.fromOffset(340, 190)
setupPanel.Position = UDim2.new(0.5, -170, 1, -240)
setupPanel.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
setupPanel.BackgroundTransparency = 0.15
setupPanel.BorderSizePixel = 0
setupPanel.Visible = false
setupPanel.Parent = screenGui
local setupCorner = Instance.new("UICorner")
setupCorner.CornerRadius = UDim.new(0, 10)
setupCorner.Parent = setupPanel

local setupTitle = Instance.new("TextLabel")
setupTitle.Size = UDim2.new(1, 0, 0, 22)
setupTitle.BackgroundTransparency = 1
setupTitle.Font = Enum.Font.GothamBold
setupTitle.TextSize = 15
setupTitle.TextColor3 = Color3.fromRGB(235, 235, 245)
setupTitle.Text = "AIM YOUR LAUNCH"
setupTitle.Parent = setupPanel

local aim = { height = Constants.LaunchHeightDefault, theta = Constants.LaunchThetaMax, phi = 0 }
local sliders = {}

local function makeSlider(order, label, key, min, max, fmt)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -20, 0, 30)
	row.Position = UDim2.new(0, 10, 0, 22 + (order - 1) * 34)
	row.BackgroundTransparency = 1
	row.Parent = setupPanel

	local caption = Instance.new("TextLabel")
	caption.Size = UDim2.fromOffset(96, 30)
	caption.BackgroundTransparency = 1
	caption.Font = Enum.Font.Gotham
	caption.TextSize = 13
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.TextColor3 = Color3.fromRGB(200, 200, 215)
	caption.Text = label
	caption.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Size = UDim2.fromOffset(54, 30)
	valueLabel.Position = UDim2.new(1, -54, 0, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.TextSize = 13
	valueLabel.TextColor3 = Color3.fromRGB(255, 220, 130)
	valueLabel.Parent = row

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Size = UDim2.new(1, -160, 0, 8)
	bar.Position = UDim2.new(0, 100, 0.5, -4)
	bar.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
	bar.BorderSizePixel = 0
	bar.Parent = row
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(1, 0)
	barCorner.Parent = bar

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.Size = UDim2.fromOffset(16, 16)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(0, 0, 0.5, 0)
	knob.BackgroundColor3 = Color3.fromRGB(235, 235, 245)
	knob.BorderSizePixel = 0
	knob.ZIndex = 2
	knob.Parent = bar
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	local function render()
		local frac = (aim[key] - min) / (max - min)
		knob.Position = UDim2.new(frac, 0, 0.5, 0)
		valueLabel.Text = string.format(fmt, aim[key])
	end

	local dragging = false
	local function applyFromX(x)
		local frac = math.clamp((x - bar.AbsolutePosition.X) / math.max(1, bar.AbsoluteSize.X), 0, 1)
		aim[key] = min + frac * (max - min)
		render()
	end
	bar.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			applyFromX(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			applyFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	sliders[key] = { render = render }
	render()
end

makeSlider(1, "HEIGHT (studs)", "height", Constants.LaunchHeightMin, Constants.LaunchHeightMax, "%.1f")
makeSlider(2, "ANGLE θ (flat 90°)", "theta", Constants.LaunchThetaMin, Constants.LaunchThetaMax, "%.0f°")
makeSlider(3, "AIM φ (compass)", "phi", 0, 359, "%.0f°")

local readyButton = Instance.new("TextButton")
readyButton.Name = "ReadyButton"
readyButton.Size = UDim2.fromOffset(140, 40)
readyButton.Position = UDim2.new(0.5, -70, 1, -48)
readyButton.BackgroundColor3 = Color3.fromRGB(70, 160, 90)
readyButton.BorderSizePixel = 0
readyButton.Font = Enum.Font.GothamBlack
readyButton.TextSize = 18
readyButton.TextColor3 = Color3.new(1, 1, 1)
readyButton.Text = "READY"
readyButton.Parent = setupPanel
local readyCorner = Instance.new("UICorner")
readyCorner.CornerRadius = UDim.new(0, 8)
readyCorner.Parent = readyButton

local readyStatusLabel = Instance.new("TextLabel")
readyStatusLabel.Size = UDim2.new(1, 0, 0, 18)
readyStatusLabel.Position = UDim2.new(0, 0, 1, -66)
readyStatusLabel.BackgroundTransparency = 1
readyStatusLabel.Font = Enum.Font.Gotham
readyStatusLabel.TextSize = 12
readyStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
readyStatusLabel.Text = ""
readyStatusLabel.Parent = setupPanel

-- Big LAUNCH button (and F key): live from countdown start until consumed
local launchButton = Instance.new("TextButton")
launchButton.Name = "LaunchButton"
launchButton.Size = UDim2.fromOffset(220, 64)
launchButton.Position = UDim2.new(0.5, -110, 1, -200)
launchButton.BackgroundColor3 = Color3.fromRGB(200, 60, 50)
launchButton.BorderSizePixel = 0
launchButton.Font = Enum.Font.GothamBlack
launchButton.TextSize = 26
launchButton.TextColor3 = Color3.new(1, 1, 1)
launchButton.Text = "LAUNCH! (F)"
launchButton.Visible = false
launchButton.Parent = screenGui
local launchCorner = Instance.new("UICorner")
launchCorner.CornerRadius = UDim.new(0, 12)
launchCorner.Parent = launchButton

local gradeToast = Instance.new("TextLabel")
gradeToast.Size = UDim2.new(1, 0, 0, 30)
gradeToast.Position = UDim2.new(0, 0, 1, -240)
gradeToast.BackgroundTransparency = 1
gradeToast.Font = Enum.Font.GothamBold
gradeToast.TextSize = 22
gradeToast.TextStrokeTransparency = 0
gradeToast.Text = ""
gradeToast.Visible = false
gradeToast.Parent = screenGui

local GRADE_STYLES = {
	Perfect = { text = "PERFECT LAUNCH!", color = Color3.fromRGB(120, 255, 120) },
	Good    = { text = "Good launch",     color = Color3.fromRGB(190, 230, 120) },
	Poor    = { text = "Poor launch...",  color = Color3.fromRGB(230, 140, 90) },
}

local setupDeadline = 0
local isReady = false
local hasLaunched = false
local launchSequenceId = 0

local function showLaunchGrade(quality, autoLaunched)
	local style = GRADE_STYLES[quality]
	if not style then return end
	gradeToast.Text = autoLaunched and (style.text .. " (AUTO — you missed GO!)") or style.text
	gradeToast.TextColor3 = style.color
	gradeToast.Visible = true
	task.delay(2, function()
		gradeToast.Visible = false
	end)
end

local function sendReady()
	if isReady or currentPhase ~= "Setup" then return end
	isReady = true
	readyButton.Text = "READY ✓"
	readyButton.BackgroundColor3 = Color3.fromRGB(60, 110, 70)
	Remotes.RequestReady:FireServer({ height = aim.height, theta = aim.theta, phi = aim.phi })
end
readyButton.MouseButton1Click:Connect(sendReady)

local function tryLaunch()
	if hasLaunched then return end
	if currentPhase ~= "Countdown" and currentPhase ~= "Active" then return end
	hasLaunched = true
	launchButton.Visible = false
	launchSequenceId += 1
	Remotes.RequestLaunch:FireServer(launchSequenceId, {
		height = aim.height,
		theta = aim.theta,
		phi = aim.phi,
		claimedServerTime = workspace:GetServerTimeNow(),
	})
end
launchButton.MouseButton1Click:Connect(tryLaunch)
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.F then
		tryLaunch()
	end
end)

-- ── Queue & rank panel (hub) ───────────────────────────────────────────────────

local queuePanel = Instance.new("Frame")
queuePanel.Name = "QueuePanel"
queuePanel.Size = UDim2.fromOffset(190, 126)
queuePanel.Position = UDim2.new(1, -200, 0, 10)
queuePanel.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
queuePanel.BackgroundTransparency = 0.25
queuePanel.BorderSizePixel = 0
queuePanel.Parent = screenGui

local queueCorner = Instance.new("UICorner")
queueCorner.CornerRadius = UDim.new(0, 8)
queueCorner.Parent = queuePanel

local rankLabel = Instance.new("TextLabel")
rankLabel.Name = "RankLabel"
rankLabel.Size = UDim2.new(1, -10, 0, 24)
rankLabel.Position = UDim2.new(0, 5, 0, 4)
rankLabel.BackgroundTransparency = 1
rankLabel.Font = Enum.Font.GothamBold
rankLabel.TextSize = 16
rankLabel.TextColor3 = Color3.fromRGB(255, 215, 120)
rankLabel.Text = "Rank: loading..."
rankLabel.Parent = queuePanel

local queueStateLabel = Instance.new("TextLabel")
queueStateLabel.Name = "QueueStateLabel"
queueStateLabel.Size = UDim2.new(1, -10, 0, 18)
queueStateLabel.Position = UDim2.new(0, 5, 0, 28)
queueStateLabel.BackgroundTransparency = 1
queueStateLabel.Font = Enum.Font.Gotham
queueStateLabel.TextSize = 13
queueStateLabel.TextColor3 = Color3.fromRGB(200, 200, 210)
queueStateLabel.Text = "Queue: —"
queueStateLabel.Parent = queuePanel

local function makeQueueButton(name, label, xOffset, color)
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = UDim2.fromOffset(85, 34)
	btn.Position = UDim2.new(0, 5 + xOffset, 0, 52)
	btn.BackgroundColor3 = color
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 14
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Text = label
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn
	btn.Parent = queuePanel
	return btn
end

local casualButton = makeQueueButton("CasualQueue", "CASUAL", 0, Color3.fromRGB(70, 120, 80))
local rankedButton = makeQueueButton("RankedQueue", "RANKED", 95, Color3.fromRGB(140, 90, 50))

-- ── Stadium preference (casual) — cycles Rotation → each ROTATION stadium ────

local stadiumPref = nil -- nil = seeded rotation

local stadiumButton = Instance.new("TextButton")
stadiumButton.Name = "StadiumPref"
stadiumButton.Size = UDim2.fromOffset(180, 24)
stadiumButton.Position = UDim2.new(0, 5, 1, -28)
stadiumButton.AnchorPoint = Vector2.new(0, 1)
stadiumButton.BackgroundColor3 = Color3.fromRGB(55, 55, 75)
stadiumButton.BorderSizePixel = 0
stadiumButton.Font = Enum.Font.Gotham
stadiumButton.TextSize = 12
stadiumButton.TextColor3 = Color3.fromRGB(220, 220, 230)
stadiumButton.Text = "Stadium: Rotation"
local stadiumCorner = Instance.new("UICorner")
stadiumCorner.CornerRadius = UDim.new(0, 6)
stadiumCorner.Parent = stadiumButton
stadiumButton.Parent = queuePanel

casualButton.MouseButton1Click:Connect(function()
	Remotes.RequestQueue:FireServer("Casual", stadiumPref)
end)
rankedButton.MouseButton1Click:Connect(function()
	Remotes.RequestQueue:FireServer("Ranked")
end)

stadiumButton.MouseButton1Click:Connect(function()
	local idx = stadiumPref and table.find(Stadiums.ROTATION, stadiumPref) or 0
	idx += 1
	stadiumPref = Stadiums.ROTATION[idx] -- past the end → nil → Rotation
	stadiumButton.Text = "Stadium: "
		.. (stadiumPref and Stadiums.get(stadiumPref).displayName or "Rotation")
	Remotes.RequestQueue:FireServer("Casual", stadiumPref)
end)

-- ── Skin equip panel (hub) ──────────────────────────────────────────────────────

local skinPanel = Instance.new("Frame")
skinPanel.Name = "SkinPanel"
skinPanel.Size = UDim2.fromOffset(190, 46)
skinPanel.Position = UDim2.new(1, -200, 0, 142)
skinPanel.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
skinPanel.BackgroundTransparency = 0.25
skinPanel.BorderSizePixel = 0
skinPanel.Parent = screenGui
local skinCorner = Instance.new("UICorner")
skinCorner.CornerRadius = UDim.new(0, 8)
skinCorner.Parent = skinPanel

local skinTitle = Instance.new("TextLabel")
skinTitle.Size = UDim2.new(1, -10, 0, 14)
skinTitle.Position = UDim2.new(0, 5, 0, 2)
skinTitle.BackgroundTransparency = 1
skinTitle.Font = Enum.Font.Gotham
skinTitle.TextSize = 11
skinTitle.TextColor3 = Color3.fromRGB(200, 200, 210)
skinTitle.TextXAlignment = Enum.TextXAlignment.Left
skinTitle.Text = "SKIN (cosmetic only)"
skinTitle.Parent = skinPanel

local swatchRow = Instance.new("Frame")
swatchRow.Size = UDim2.new(1, -10, 0, 24)
swatchRow.Position = UDim2.new(0, 5, 0, 18)
swatchRow.BackgroundTransparency = 1
swatchRow.Parent = skinPanel
local rowLayout = Instance.new("UIListLayout")
rowLayout.FillDirection = Enum.FillDirection.Horizontal
rowLayout.Padding = UDim.new(0, 4)
rowLayout.Parent = swatchRow

local skinSwatches = {} -- skinId -> button
local equippedSkin = "Default"

local function refreshSwatchSelection()
	for id, btn in pairs(skinSwatches) do
		btn.BorderSizePixel = (id == equippedSkin) and 2 or 0
		btn.BackgroundTransparency = (id == equippedSkin) and 0 or 0.35
	end
end

local function buildSwatches(ownedIds)
	for _, btn in pairs(skinSwatches) do
		btn:Destroy()
	end
	table.clear(skinSwatches)
	for _, skinId in ipairs(ownedIds) do
		local def = Cosmetics.get(skinId)
		local btn = Instance.new("TextButton")
		btn.Name = skinId
		btn.Size = UDim2.fromOffset(24, 24)
		btn.BackgroundColor3 = def.ringColor
		btn.BorderColor3 = Color3.new(1, 1, 1)
		btn.Text = ""
		btn.Parent = swatchRow
		btn.MouseButton1Click:Connect(function()
			Remotes.RequestEquip:FireServer(skinId)
		end)
		skinSwatches[skinId] = btn
	end
	refreshSwatchSelection()
end

buildSwatches(Cosmetics.ownedSkinIds(nil)) -- starter set until the profile arrives

-- Hub-only panels: hidden during a battle so the HP/Mana bars own the top corners.
local function setHubPanelsVisible(visible)
	queuePanel.Visible = visible
	skinPanel.Visible = visible
end

Remotes.QueueStatus.OnClientEvent:Connect(function(status)
	if status.state == "Queued" then
		queueStateLabel.Text = "Queue: " .. status.mode .. " (searching...)"
	elseif status.state == "Matched" then
		queueStateLabel.Text = "Queue: matched! (" .. tostring(status.mode) .. ")"
	elseif status.state == "Left" then
		queueStateLabel.Text = "Queue: —"
	elseif status.state == "Rejected" then
		queueStateLabel.Text = "Queue: unavailable (" .. tostring(status.reason) .. ")"
	end
end)

Remotes.ProfileSummary.OnClientEvent:Connect(function(summary)
	rankLabel.Text = string.format("%s · %d MMR", summary.tier, summary.mmr)
	if summary.equippedSkin then
		equippedSkin = summary.equippedSkin
	end
	if summary.ownedSkins then
		buildSwatches(summary.ownedSkins)
	else
		refreshSwatchSelection()
	end
end)

Remotes.MmrUpdated.OnClientEvent:Connect(function(update)
	local sign = update.delta >= 0 and "+" or ""
	rankLabel.Text = string.format("%s · %d MMR (%s%d)", update.tier, update.newMmr, sign, update.delta)
	rankLabel.TextColor3 = update.delta >= 0
		and Color3.fromRGB(140, 255, 140)
		or Color3.fromRGB(255, 140, 120)
	task.delay(4, function()
		rankLabel.TextColor3 = Color3.fromRGB(255, 215, 120)
	end)
end)

-- ── HP / Mana bar state (snapshot-driven) ───────────────────────────────────────

local targets = {}   -- [pid] = { hp, maxHp, mana, maxMana }
local displayed = {} -- smoothed values
local sideMap = { left = nil, right = nil }

-- Snapshot beyStates are STRING-keyed (remote serialization canon); compare ids
-- as strings so the local player resolves to the left block.
local function resolveSides(idSet)
	local localId = tostring(localPlayer.UserId)
	local oppId = nil
	for pid in pairs(idSet) do
		if pid ~= localId then
			oppId = pid
			break
		end
	end
	if not idSet[localId] then
		local ids = {}
		for pid in pairs(idSet) do table.insert(ids, pid) end
		table.sort(ids)
		localId = ids[1]
		oppId = ids[2]
	end
	return localId, oppId
end

local function updateBlock(block, pid)
	if not pid or not targets[pid] then return end
	local t = targets[pid]
	local d = displayed[pid]
	d.hp = d.hp + (t.hp - d.hp) * 0.2
	d.mana = d.mana + (t.mana - d.mana) * 0.2
	local hpRatio = math.clamp(d.hp / math.max(1, t.maxHp), 0, 1)
	local manaRatio = math.clamp(d.mana / math.max(1, t.maxMana), 0, 1)
	block.hpFill.Size = UDim2.new(hpRatio, 0, 1, 0)
	block.hpFill.BackgroundColor3 = hpColor(hpRatio)
	block.hpLbl.Text = string.format("HP  %d", math.floor(d.hp + 0.5))
	block.manaFill.Size = UDim2.new(manaRatio, 0, 1, 0)
	block.manaLbl.Text = string.format("MANA  %d", math.floor(d.mana + 0.5))
end

-- ── Snapshot handler: launch grade verdicts + HP/Mana bar targets ───────────────

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	if snapshot.events then
		for _, ev in ipairs(snapshot.events) do
			if ev.eventType == "LaunchGraded" and ev.eventData.playerId == localPlayer.UserId then
				hasLaunched = true
				launchButton.Visible = false
				showLaunchGrade(ev.eventData.quality, ev.eventData.autoLaunched)
			end
		end
	end

	if not snapshot.beyStates then return end
	for pid, st in pairs(snapshot.beyStates) do
		if st.hp ~= nil then
			targets[pid] = { hp = st.hp, maxHp = st.maxHp or 100, mana = st.mana or 0, maxMana = st.maxMana or 100 }
			if not displayed[pid] then
				displayed[pid] = { hp = st.hp, mana = st.mana or 0 }
			end
		end
	end
end)

-- ── Stadium reveal (ranked rotation surprise / casual confirmation) ─────────────

local stadiumRevealLabel = Instance.new("TextLabel")
stadiumRevealLabel.Name = "StadiumReveal"
stadiumRevealLabel.Size = UDim2.new(1, 0, 0, 24)
stadiumRevealLabel.Position = UDim2.new(0, 0, 0, 148)
stadiumRevealLabel.BackgroundTransparency = 1
stadiumRevealLabel.Font = Enum.Font.Gotham
stadiumRevealLabel.TextSize = 18
stadiumRevealLabel.TextColor3 = Color3.fromRGB(180, 200, 255)
stadiumRevealLabel.TextStrokeTransparency = 0
stadiumRevealLabel.Text = ""
stadiumRevealLabel.Parent = screenGui

Remotes.MatchStateChanged.OnClientEvent:Connect(function(phase, data)
	currentPhase = phase

	if data and data.stadiumId then
		stadiumRevealLabel.Text = "⚔ " .. Stadiums.get(data.stadiumId).displayName
		stadiumRevealLabel.Visible = (phase ~= "Finished")
	end

	-- Any battle phase hides the hub panels and shows the battle HUD bars.
	local inBattle = (phase == "Setup" or phase == "Countdown" or phase == "Active" or phase == "Finished")
	setHubPanelsVisible(not inBattle)
	setStatBlocksVisible(inBattle)

	if phase == "Setup" then
		setupDeadline = data.setupDeadline or setupDeadline
		resultLabel.Visible = false
		launchButton.Visible = false
		hasLaunched = false
		-- Fresh match: reset bars + sides
		sideMap.left, sideMap.right = nil, nil
		table.clear(targets)
		table.clear(displayed)
		-- Re-arm READY and default the aim for our seat
		if not (data.resync or data.ready) or not isReady then
			if data.players then
				for index, pid in ipairs(data.players) do
					if pid == localPlayer.UserId then
						local defaults = LaunchQuality.defaultAimFor(index == 1 and -1 or 1)
						aim.height, aim.theta, aim.phi = defaults.height, defaults.theta, defaults.phi
						for _, slider in pairs(sliders) do slider.render() end
						break
					end
				end
			end
			isReady = false
			readyButton.Text = "READY"
			readyButton.BackgroundColor3 = Color3.fromRGB(70, 160, 90)
		end
		setupPanel.Visible = true
		-- Opponent readiness ticks (dictionary payloads arrive STRING-keyed)
		if data.ready then
			local others, readyCount = 0, 0
			for _, pid in ipairs(data.players or {}) do
				if pid ~= localPlayer.UserId then
					others += 1
					if data.ready[tostring(pid)] or data.ready[pid] then readyCount += 1 end
				end
			end
			if others > 0 then
				local vsBot = false
				if data.bots then
					for _, pid in ipairs(data.players or {}) do
						if pid ~= localPlayer.UserId
							and (data.bots[tostring(pid)] ~= nil or data.bots[pid] ~= nil) then
							vsBot = true
						end
					end
				end
				if readyCount >= others then
					readyStatusLabel.Text = vsBot and "Opponent: BOT — READY ✓" or "Opponent: READY ✓"
				else
					readyStatusLabel.Text = vsBot and "Opponent: BOT (readying...)" or "Waiting for opponent..."
				end
			end
		end

	elseif phase == "Countdown" then
		countdownEndTime = data.countdownEndTime or countdownEndTime
		setupPanel.Visible = false
		resultLabel.Visible = false
		launchButton.Visible = not hasLaunched

	elseif phase == "Active" then
		statusLabel.Text = "GO!  SHOOT!"
		task.delay(2, function()
			if currentPhase == "Active" then
				statusLabel.Text = ""
			end
		end)

	elseif phase == "Finished" then
		statusLabel.Text = "MATCH FINISHED"
		setupPanel.Visible = false
		launchButton.Visible = false
		resultLabel.Visible = true

		local winnerId = data.winner
		if data.cancelled then
			statusLabel.Text = "MATCH CANCELLED"
			resultLabel.Text = "OPPONENT LEFT"
			resultLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		elseif winnerId == "Draw" then
			resultLabel.Text = "DRAW"
			resultLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		elseif winnerId == localPlayer.UserId then
			resultLabel.Text = "YOU WIN!"
			resultLabel.TextColor3 = Color3.fromRGB(50, 255, 50)
		else
			resultLabel.Text = "YOU LOSE"
			resultLabel.TextColor3 = Color3.fromRGB(255, 50, 50)
		end
	end
end)

-- ── Per-frame update ──────────────────────────────────────────────────────────

RunService.RenderStepped:Connect(function()
	-- Setup: show the auto-ready countdown so nobody is surprised
	if currentPhase == "Setup" and not isReady and setupDeadline > 0 then
		local left = setupDeadline - workspace:GetServerTimeNow()
		if left > 0 and left < 11 then
			readyStatusLabel.Text = string.format("Auto-ready in %ds...", math.ceil(left))
		end
	end

	-- Countdown: 3 · 2 · 1 · GO! SHOOT!
	if currentPhase == "Countdown" then
		local remaining = countdownEndTime - workspace:GetServerTimeNow()
		if remaining > 0 then
			statusLabel.Text = tostring(math.ceil(remaining))
		else
			statusLabel.Text = "GO!  SHOOT!"
		end
	end

	-- HP / Mana bars (resolve sides once snapshot data exists, then smooth)
	if not sideMap.left and next(targets) then
		local idSet = {}
		for pid in pairs(targets) do idSet[pid] = true end
		sideMap.left, sideMap.right = resolveSides(idSet)
	end
	updateBlock(leftBlock, sideMap.left)
	updateBlock(rightBlock, sideMap.right)
end)
