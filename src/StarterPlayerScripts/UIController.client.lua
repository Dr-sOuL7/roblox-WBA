--[=[
	UIController.client.lua
	HUD: per-Bey HP + Mana bars, match status / countdown / result, and the
	camera-mode toggle (Spectator → Top → Side → BeyView). Reads server snapshots
	for HP/Mana; the camera toggle publishes the chosen mode via a player attribute
	that SpectatorCameraController reads.
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MatchStatusGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

-- ── Status + result labels ─────────────────────────────────────────────────────
local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.Size = UDim2.new(1, 0, 0, 90)
statusLabel.Position = UDim2.new(0, 0, 0, 110)
statusLabel.BackgroundTransparency = 1
statusLabel.Font = Enum.Font.GothamBold
statusLabel.TextSize = 44
statusLabel.TextColor3 = Color3.new(1, 1, 1)
statusLabel.TextStrokeTransparency = 0
statusLabel.Text = "Waiting for match..."
statusLabel.Parent = screenGui

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

-- ── Bar widgets ─────────────────────────────────────────────────────────────────
-- A stat block = name + HP bar + Mana bar. `side` is "left" or "right".
local function makeStatBlock(side, title)
	local holder = Instance.new("Frame")
	holder.Name = "Stat_" .. side
	holder.Size = UDim2.fromOffset(360, 86)
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(side == "left" and 0 or 1, 0)
	holder.Position = side == "left" and UDim2.new(0, 20, 0, 20) or UDim2.new(1, -20, 0, 20)
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
leftBlock.holder.Visible = false
rightBlock.holder.Visible = false

-- ── Camera toggle ────────────────────────────────────────────────────────────────
local CAMERA_MODES = { "Spectator", "Top", "Side", "BeyView" }
local cameraModeIndex = 1
localPlayer:SetAttribute("CameraMode", CAMERA_MODES[cameraModeIndex])

local camButton = Instance.new("TextButton")
camButton.Name = "CameraToggle"
camButton.AnchorPoint = Vector2.new(1, 0)
camButton.Position = UDim2.new(1, -20, 0, 120)
camButton.Size = UDim2.fromOffset(150, 40)
camButton.BackgroundColor3 = Color3.fromRGB(40, 44, 60)
camButton.BackgroundTransparency = 0.15
camButton.Font = Enum.Font.GothamBold
camButton.TextSize = 16
camButton.TextColor3 = Color3.new(1, 1, 1)
camButton.Text = "📷 Spectator"
camButton.Parent = screenGui
local camCorner = Instance.new("UICorner")
camCorner.CornerRadius = UDim.new(0, 8)
camCorner.Parent = camButton

local function cycleCamera()
	cameraModeIndex = (cameraModeIndex % #CAMERA_MODES) + 1
	local mode = CAMERA_MODES[cameraModeIndex]
	localPlayer:SetAttribute("CameraMode", mode)
	camButton.Text = "📷 " .. mode
end
camButton.MouseButton1Click:Connect(cycleCamera)

-- ── Snapshot → bar targets ───────────────────────────────────────────────────────
local targets = {} -- [pid] = { hp, maxHp, mana, maxMana }
local displayed = {} -- smoothed values

local function resolveSides(beyStates)
	-- Local player on the left; first other id on the right.
	local localId = localPlayer.UserId
	local oppId = nil
	for pid in pairs(beyStates) do
		if pid ~= localId then
			oppId = pid
			break
		end
	end
	-- If the local player isn't in the match (spectator), just take the first two.
	if not beyStates[localId] then
		local ids = {}
		for pid in pairs(beyStates) do table.insert(ids, pid) end
		table.sort(ids)
		localId = ids[1]
		oppId = ids[2]
	end
	return localId, oppId
end

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	for pid, st in pairs(snapshot.beyStates) do
		if st.hp ~= nil then
			targets[pid] = { hp = st.hp, maxHp = st.maxHp or 100, mana = st.mana or 0, maxMana = st.maxMana or 100 }
			if not displayed[pid] then
				displayed[pid] = { hp = st.hp, mana = st.mana or 0 }
			end
		end
	end
end)

-- ── Match phase ──────────────────────────────────────────────────────────────────
local currentPhase = "None"
local countdownEndTime = 0
local sideMap = { left = nil, right = nil }

Remotes.MatchStateChanged.OnClientEvent:Connect(function(phase, data)
	currentPhase = phase
	if phase == "Countdown" then
		countdownEndTime = data.countdownEndTime or 0
		resultLabel.Visible = false
		leftBlock.holder.Visible = true
		rightBlock.holder.Visible = true
		-- Fresh match: recompute sides and drop stale bar targets.
		sideMap.left, sideMap.right = nil, nil
		table.clear(targets)
		table.clear(displayed)
	elseif phase == "Active" then
		statusLabel.Text = "BATTLE!"
		task.delay(2, function()
			if currentPhase == "Active" then statusLabel.Text = "" end
		end)
	elseif phase == "Finished" then
		statusLabel.Text = ""
		resultLabel.Visible = true
		local winnerId = data and data.winner
		if winnerId == "Draw" then
			resultLabel.Text = "DRAW"
			resultLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		elseif winnerId == localPlayer.UserId then
			resultLabel.Text = "YOU WIN!"
			resultLabel.TextColor3 = Color3.fromRGB(60, 255, 60)
		else
			resultLabel.Text = "YOU LOSE"
			resultLabel.TextColor3 = Color3.fromRGB(255, 60, 60)
		end
	end
end)

-- ── Render: smooth bars + countdown ──────────────────────────────────────────────
local function hpColor(ratio)
	if ratio > 0.6 then
		return Color3.fromRGB(60, 220, 80)
	elseif ratio > 0.3 then
		return Color3.fromRGB(235, 200, 60)
	end
	return Color3.fromRGB(235, 70, 60)
end

local function updateBlock(block, pid)
	if not pid or not targets[pid] then
		return false
	end
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
	return true
end

RunService.RenderStepped:Connect(function()
	if currentPhase == "Countdown" then
		local remaining = countdownEndTime - workspace:GetServerTimeNow()
		statusLabel.Text = (remaining > 0) and string.format("Match Starting In: %.1f", remaining) or "READY..."
	end

	-- Resolve sides once we have snapshot data.
	if not sideMap.left and next(targets) then
		local snapStates = {}
		for pid in pairs(targets) do snapStates[pid] = true end
		sideMap.left, sideMap.right = resolveSides(snapStates)
	end

	updateBlock(leftBlock, sideMap.left)
	updateBlock(rightBlock, sideMap.right)
end)
