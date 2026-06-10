--[=[
	UIController.client.lua
	Match UI: status labels, countdown, result screen, and battle command buttons.
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

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

-- ── Match phase state ─────────────────────────────────────────────────────────

local currentPhase = "None"
local countdownEndTime = 0
local TICK_SECONDS = 1 / Constants.SimulationTickRate

-- Correct client prediction from server snapshots (handles rejected commands, latency races)
Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
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
		resultLabel.Visible = true

		local winnerId = data.winner
		if winnerId == "Draw" then
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
