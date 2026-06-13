--[=[
    ChallengeUI.client.lua
    Hub challenge UX: shows the incoming "X challenges you" invite with
    Accept/Decline, surfaces status toasts (sent/declined/expired/…), and hides
    the local player's own "Challenge" prompt (you can't challenge yourself).
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "ChallengeGui"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- ── Status toast (top-centre) ─────────────────────────────────────────────────

local toast = Instance.new("TextLabel")
toast.Name = "ChallengeToast"
toast.Size = UDim2.fromOffset(460, 36)
toast.Position = UDim2.new(0.5, -230, 0, 160)
toast.BackgroundTransparency = 1
toast.Font = Enum.Font.GothamBold
toast.TextSize = 20
toast.TextColor3 = Color3.fromRGB(235, 235, 245)
toast.TextStrokeTransparency = 0
toast.Text = ""
toast.Visible = false
toast.Parent = gui

local toastToken = 0
local function showToast(text, color)
	toast.Text = text
	toast.TextColor3 = color or Color3.fromRGB(235, 235, 245)
	toast.Visible = true
	toastToken += 1
	local myToken = toastToken
	task.delay(3, function()
		if myToken == toastToken then
			toast.Visible = false
		end
	end)
end

-- ── Invite panel (centre) ─────────────────────────────────────────────────────

local invitePanel = Instance.new("Frame")
invitePanel.Name = "InvitePanel"
invitePanel.Size = UDim2.fromOffset(360, 150)
invitePanel.Position = UDim2.new(0.5, -180, 0.5, -75)
invitePanel.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
invitePanel.BackgroundTransparency = 0.05
invitePanel.BorderSizePixel = 0
invitePanel.Visible = false
invitePanel.Parent = gui
local inviteCorner = Instance.new("UICorner")
inviteCorner.CornerRadius = UDim.new(0, 12)
inviteCorner.Parent = invitePanel

local inviteTitle = Instance.new("TextLabel")
inviteTitle.Size = UDim2.new(1, -20, 0, 60)
inviteTitle.Position = UDim2.new(0, 10, 0, 10)
inviteTitle.BackgroundTransparency = 1
inviteTitle.Font = Enum.Font.GothamBold
inviteTitle.TextSize = 20
inviteTitle.TextWrapped = true
inviteTitle.TextColor3 = Color3.fromRGB(255, 220, 130)
inviteTitle.Text = ""
inviteTitle.Parent = invitePanel

local inviteTimerLabel = Instance.new("TextLabel")
inviteTimerLabel.Size = UDim2.new(1, -20, 0, 18)
inviteTimerLabel.Position = UDim2.new(0, 10, 0, 70)
inviteTimerLabel.BackgroundTransparency = 1
inviteTimerLabel.Font = Enum.Font.Gotham
inviteTimerLabel.TextSize = 13
inviteTimerLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
inviteTimerLabel.Text = ""
inviteTimerLabel.Parent = invitePanel

local function makeInviteButton(name, text, xOffset, color)
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.Size = UDim2.fromOffset(150, 42)
	btn.Position = UDim2.new(0, xOffset, 1, -52)
	btn.BackgroundColor3 = color
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBlack
	btn.TextSize = 18
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Text = text
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn
	btn.Parent = invitePanel
	return btn
end

local acceptButton = makeInviteButton("Accept", "ACCEPT", 10, Color3.fromRGB(70, 160, 90))
local declineButton = makeInviteButton("Decline", "DECLINE", 200, Color3.fromRGB(160, 70, 70))

local activeInvite = nil -- { challengeId, expiresAt }

local function closeInvite()
	activeInvite = nil
	invitePanel.Visible = false
end

acceptButton.MouseButton1Click:Connect(function()
	if activeInvite then
		Remotes.ChallengeResponse:FireServer(activeInvite.challengeId, true)
		closeInvite()
	end
end)
declineButton.MouseButton1Click:Connect(function()
	if activeInvite then
		Remotes.ChallengeResponse:FireServer(activeInvite.challengeId, false)
		closeInvite()
	end
end)

Remotes.ChallengeInvite.OnClientEvent:Connect(function(data)
	activeInvite = {
		challengeId = data.challengeId,
		expiresAt = os.clock() + (data.timeout or 15),
	}
	inviteTitle.Text = string.format("%s challenges you to a battle!", tostring(data.fromName))
	invitePanel.Visible = true
end)

Remotes.ChallengeStatus.OnClientEvent:Connect(function(status)
	local s = status.state
	if s == "Sent" then
		showToast(string.format("Challenge sent to %s…", tostring(status.targetName)), Color3.fromRGB(190, 220, 255))
	elseif s == "Declined" then
		showToast(string.format("%s declined your challenge.", tostring(status.targetName)), Color3.fromRGB(255, 170, 120))
	elseif s == "Expired" then
		showToast("Challenge expired.", Color3.fromRGB(200, 200, 200))
		closeInvite()
	elseif s == "Unavailable" then
		showToast(string.format("%s is busy right now.", tostring(status.targetName)), Color3.fromRGB(255, 170, 120))
	elseif s == "Busy" then
		showToast("You can't challenge right now.", Color3.fromRGB(255, 170, 120))
	elseif s == "Accepted" then
		showToast(string.format("Battle on vs %s!", tostring(status.targetName)), Color3.fromRGB(140, 255, 140))
		closeInvite()
	elseif s == "Cancelled" then
		showToast("Challenge cancelled.", Color3.fromRGB(200, 200, 200))
		closeInvite()
	elseif s == "Closed" then
		closeInvite()
	end
end)

-- Invite countdown
RunService.RenderStepped:Connect(function()
	if activeInvite then
		local left = activeInvite.expiresAt - os.clock()
		if left <= 0 then
			closeInvite()
		else
			inviteTimerLabel.Text = string.format("Responds in %ds", math.ceil(left))
		end
	end
end)

-- ── Hide our own "Challenge" prompt (you can't challenge yourself) ────────────
-- Setting .Enabled = false on the client only affects this client's view.

local function disablePromptsIn(character)
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.Name == "ChallengePrompt" then
			d.Enabled = false
		end
	end
	character.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") and d.Name == "ChallengePrompt" then
			d.Enabled = false
		end
	end)
end

localPlayer.CharacterAdded:Connect(disablePromptsIn)
if localPlayer.Character then
	disablePromptsIn(localPlayer.Character)
end
