--[=[
	UIController.client.lua
	Match UI: status labels, countdown, result screen, and battle command buttons.
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local LaunchQuality = require(ReplicatedStorage:WaitForChild("LaunchQuality"))

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

-- ── Command button panel (bottom centre) ──────────────────────────────────────

local commandPanel = Instance.new("Frame")
commandPanel.Name = "CommandPanel"
commandPanel.Size = UDim2.fromOffset(450, 80)
commandPanel.Position = UDim2.new(0.5, -225, 1, -110)
commandPanel.BackgroundTransparency = 1
commandPanel.Visible = false
commandPanel.Parent = screenGui

local panelLayout = Instance.new("UIListLayout")
panelLayout.FillDirection = Enum.FillDirection.Horizontal
panelLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
panelLayout.VerticalAlignment = Enum.VerticalAlignment.Center
panelLayout.Padding = UDim.new(0, 10)
panelLayout.Parent = commandPanel

local COMMAND_DEFS = {
	{ name = "Attack",  label = "ATTACK",  color = Color3.fromRGB(220, 50,  50)  },
	{ name = "Defend",  label = "DEFEND",  color = Color3.fromRGB(50,  100, 220) },
	{ name = "Evade",   label = "EVADE",   color = Color3.fromRGB(50,  200, 80)  },
}

local buttons = {}
local commandSequenceId = 0

-- Command state tracking (client-predicted)
local activeCommand = nil
local commandActiveTimer = 0       -- seconds remaining on active command
local commandCooldownTimer = 0     -- seconds remaining on cooldown

local CMD_DURATION = Constants.CommandDurationTicks / Constants.SimulationTickRate
local CMD_COOLDOWN = Constants.CommandCooldownTicks / Constants.SimulationTickRate

local function createButton(def)
	local btn = Instance.new("TextButton")
	btn.Name = def.name
	btn.Size = UDim2.fromOffset(130, 64)
	btn.BackgroundColor3 = def.color
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 22
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Text = def.label
	btn.AutoButtonColor = false

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn

	btn.Parent = commandPanel

	btn.MouseButton1Click:Connect(function()
		if commandActiveTimer > 0 or commandCooldownTimer > 0 then return end
		commandSequenceId += 1
		Remotes.RequestCommand:FireServer(commandSequenceId, def.name)
		-- Optimistic local state
		activeCommand = def.name
		commandActiveTimer = CMD_DURATION
		commandCooldownTimer = 0
	end)

	buttons[def.name] = { button = btn, baseColor = def.color }
end

for _, def in ipairs(COMMAND_DEFS) do
	createButton(def)
end

-- Active command label (shows which command is running)
local activeCommandLabel = Instance.new("TextLabel")
activeCommandLabel.Name = "ActiveCommandLabel"
activeCommandLabel.Size = UDim2.fromOffset(450, 30)
activeCommandLabel.Position = UDim2.new(0.5, -225, 1, -145)
activeCommandLabel.BackgroundTransparency = 1
activeCommandLabel.Font = Enum.Font.Gotham
activeCommandLabel.TextSize = 18
activeCommandLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
activeCommandLabel.TextStrokeTransparency = 0
activeCommandLabel.Text = ""
activeCommandLabel.Visible = false
activeCommandLabel.Parent = screenGui

-- ── Launch timing bar (Phase 2 skill layer) ───────────────────────────────────
-- Renders the shared LaunchQuality bar off the synced server clock. The server
-- grades presses with the same module — what you see is what gets judged.

local launchBarFrame = Instance.new("Frame")
launchBarFrame.Name = "LaunchBar"
launchBarFrame.Size = UDim2.fromOffset(420, 30)
launchBarFrame.Position = UDim2.new(0.5, -210, 1, -190)
launchBarFrame.BackgroundColor3 = Color3.fromRGB(35, 35, 45)
launchBarFrame.BorderSizePixel = 0
launchBarFrame.Visible = false
launchBarFrame.Parent = screenGui

local launchBarCorner = Instance.new("UICorner")
launchBarCorner.CornerRadius = UDim.new(0, 6)
launchBarCorner.Parent = launchBarFrame

-- Zone bands, sized from the same Constants the server grades with
local goodBand = Instance.new("Frame")
goodBand.Name = "GoodZone"
goodBand.Size = UDim2.new(Constants.LaunchGoodZone * 2, 0, 1, 0)
goodBand.Position = UDim2.new(0.5 - Constants.LaunchGoodZone, 0, 0, 0)
goodBand.BackgroundColor3 = Color3.fromRGB(70, 110, 70)
goodBand.BorderSizePixel = 0
goodBand.Parent = launchBarFrame

local perfectBand = Instance.new("Frame")
perfectBand.Name = "PerfectZone"
perfectBand.Size = UDim2.new(Constants.LaunchPerfectZone * 2, 0, 1, 0)
perfectBand.Position = UDim2.new(0.5 - Constants.LaunchPerfectZone, 0, 0, 0)
perfectBand.BackgroundColor3 = Color3.fromRGB(120, 200, 90)
perfectBand.BorderSizePixel = 0
perfectBand.Parent = launchBarFrame

local barMarker = Instance.new("Frame")
barMarker.Name = "Marker"
barMarker.Size = UDim2.new(0, 4, 1.4, 0)
barMarker.AnchorPoint = Vector2.new(0.5, 0.5)
barMarker.Position = UDim2.new(0, 0, 0.5, 0)
barMarker.BackgroundColor3 = Color3.new(1, 1, 1)
barMarker.BorderSizePixel = 0
barMarker.ZIndex = 2
barMarker.Parent = launchBarFrame

local launchHint = Instance.new("TextLabel")
launchHint.Name = "LaunchHint"
launchHint.Size = UDim2.fromOffset(420, 22)
launchHint.Position = UDim2.new(0.5, -210, 1, -215)
launchHint.BackgroundTransparency = 1
launchHint.Font = Enum.Font.GothamBold
launchHint.TextSize = 16
launchHint.TextColor3 = Color3.fromRGB(235, 235, 235)
launchHint.TextStrokeTransparency = 0
launchHint.Text = "Press F to LAUNCH — hit the centre!"
launchHint.Visible = false
launchHint.Parent = screenGui

local GRADE_STYLES = {
	Perfect = { text = "PERFECT LAUNCH!", color = Color3.fromRGB(120, 255, 120) },
	Good    = { text = "Good launch",     color = Color3.fromRGB(190, 230, 120) },
	Poor    = { text = "Poor launch...",  color = Color3.fromRGB(230, 140, 90) },
}

local launchBarEpoch = 0
local launchBarActive = false
local hasLaunched = false

local function showLaunchGrade(quality)
	local style = GRADE_STYLES[quality]
	if not style then return end
	launchHint.Text = style.text
	launchHint.TextColor3 = style.color
	launchHint.Visible = true
	task.delay(1.5, function()
		if not launchBarActive then
			launchHint.Visible = false
		end
	end)
end

local function hideLaunchBar()
	launchBarActive = false
	launchBarFrame.Visible = false
end

-- ── Queue & rank panel (Phase 2) ──────────────────────────────────────────────

local queuePanel = Instance.new("Frame")
queuePanel.Name = "QueuePanel"
queuePanel.Size = UDim2.fromOffset(190, 96)
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

casualButton.MouseButton1Click:Connect(function()
	Remotes.RequestQueue:FireServer("Casual")
end)
rankedButton.MouseButton1Click:Connect(function()
	Remotes.RequestQueue:FireServer("Ranked")
end)

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

-- ── Match phase state ─────────────────────────────────────────────────────────

local currentPhase = "None"
local countdownEndTime = 0
local TICK_SECONDS = 1 / Constants.SimulationTickRate

-- Correct client prediction from server snapshots (handles rejected commands, latency races)
Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	-- Launch grade verdicts arrive as tick events in the snapshot stream
	if snapshot.events then
		for _, ev in ipairs(snapshot.events) do
			if ev.eventType == "LaunchGraded" and ev.eventData.playerId == localPlayer.UserId then
				hasLaunched = true
				hideLaunchBar()
				showLaunchGrade(ev.eventData.quality)
			end
		end
	end

	if currentPhase ~= "Active" then return end
	local localState = snapshot.beyStates and snapshot.beyStates[localPlayer.UserId]
	if not localState then return end
	-- Server says no command active: clear any stale local prediction immediately
	if localState.currentCommand == nil and activeCommand ~= nil then
		activeCommand = nil
		commandActiveTimer = 0
	end
	-- Sync cooldown: if server and client disagree by more than 2 ticks, snap to server value
	local serverCooldownSec = (localState.commandCooldownTimer or 0) * TICK_SECONDS
	if math.abs(commandCooldownTimer - serverCooldownSec) > (2 * TICK_SECONDS) then
		commandCooldownTimer = serverCooldownSec
	end
end)

Remotes.MatchStateChanged.OnClientEvent:Connect(function(phase, data)
	currentPhase = phase

	if phase == "Countdown" then
		countdownEndTime = data.countdownEndTime
		resultLabel.Visible = false
		commandPanel.Visible = false
		activeCommandLabel.Visible = false
		-- Arm the launch bar for this match
		launchBarEpoch = data.launchBarEpoch or 0
		hasLaunched = false
		launchBarActive = true
		launchBarFrame.Visible = true
		launchHint.Text = "Press F to LAUNCH — hit the centre!"
		launchHint.TextColor3 = Color3.fromRGB(235, 235, 235)
		launchHint.Visible = true

	elseif phase == "Active" then
		statusLabel.Text = "BATTLE!"
		commandPanel.Visible = true
		activeCommandLabel.Visible = true
		-- Reset local command prediction
		activeCommand = nil
		commandActiveTimer = 0
		commandCooldownTimer = 0
		task.delay(2, function()
			if currentPhase == "Active" then
				statusLabel.Text = ""
			end
		end)

	elseif phase == "Finished" then
		statusLabel.Text = "MATCH FINISHED"
		commandPanel.Visible = false
		activeCommandLabel.Visible = false
		hideLaunchBar()
		launchHint.Visible = false
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

RunService.RenderStepped:Connect(function(dt)
	-- Launch bar marker: same math the server grades with, same synced clock
	if launchBarActive and not hasLaunched then
		local now = workspace:GetServerTimeNow()
		barMarker.Position = UDim2.new(LaunchQuality.barPosition(now, launchBarEpoch), 0, 0.5, 0)
		-- Window closes shortly after Active begins; late launches grade Poor
		if currentPhase == "Active" and countdownEndTime > 0
			and now > countdownEndTime + Constants.LaunchWindowAfterActive then
			hideLaunchBar()
			launchHint.Text = "Launch window closed — late launch = Poor"
			task.delay(2, function()
				if not launchBarActive then launchHint.Visible = false end
			end)
		end
	end

	-- Countdown text
	if currentPhase == "Countdown" then
		local remaining = countdownEndTime - workspace:GetServerTimeNow()
		if remaining > 0 then
			statusLabel.Text = string.format("Match Starting In: %.1f", remaining)
		else
			statusLabel.Text = "READY..."
		end
	end

	-- Command timer prediction
	if currentPhase == "Active" then
		if commandActiveTimer > 0 then
			commandActiveTimer = math.max(0, commandActiveTimer - dt)
			if commandActiveTimer == 0 then
				activeCommand = nil
				commandCooldownTimer = CMD_COOLDOWN
			end
		elseif commandCooldownTimer > 0 then
			commandCooldownTimer = math.max(0, commandCooldownTimer - dt)
		end

		-- Update button visuals
		local canIssue = (commandActiveTimer == 0 and commandCooldownTimer == 0)
		for _, def in ipairs(COMMAND_DEFS) do
			local cmdName = def.name
			local entry = buttons[cmdName]
			if not entry then continue end
			local btn = entry.button
			local isActive = (cmdName == activeCommand)
			local isCooling = (not isActive and not canIssue)

			if isActive then
				btn.BackgroundColor3 = Color3.new(1, 1, 1)
				btn.TextColor3 = entry.baseColor
				btn.Text = string.format("%s (%.1f)", string.upper(cmdName), commandActiveTimer)
				btn.BackgroundTransparency = 0
			elseif isCooling then
				btn.BackgroundColor3 = entry.baseColor
				btn.TextColor3 = Color3.fromRGB(180, 180, 180)
				btn.Text = string.upper(cmdName)
				btn.BackgroundTransparency = 0.55
			else
				btn.BackgroundColor3 = entry.baseColor
				btn.TextColor3 = Color3.new(1, 1, 1)
				btn.Text = string.upper(cmdName)
				btn.BackgroundTransparency = 0
			end
		end

		-- Active command label
		if activeCommand then
			activeCommandLabel.Text = "► " .. string.upper(activeCommand)
		elseif commandCooldownTimer > 0 then
			activeCommandLabel.Text = string.format("Cooldown: %.1fs", commandCooldownTimer)
		else
			activeCommandLabel.Text = ""
		end
	end
end)
