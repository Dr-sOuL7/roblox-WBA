--[=[
	BreakAnimationController.client.lua
	Plays the HP-break "shatter" when a Bey's HP hits 0. Listens for the "HpBreak"
	event in the StateSnapshot stream, then:
	  • flags the model so InterpolationRenderer stops driving it,
	  • blows its parts apart with physics (Tip/Disc/Blade/Core fly outward),
	  • flashes the screen and spawns a spark burst at the break point.

	Multi-match (ADR-001): models live under workspace.Matches[matchId]. The shatter
	is delayed by the interpolation delay so it lines up with the rendered position.
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local handled = {} -- pid -> true (guard against duplicate events)

-- ── Screen flash ─────────────────────────────────────────────────────────────
local flashGui = Instance.new("ScreenGui")
flashGui.Name = "BreakFlashGui"
flashGui.ResetOnSpawn = false
flashGui.IgnoreGuiInset = true
flashGui.DisplayOrder = 50
flashGui.Parent = playerGui

local flash = Instance.new("Frame")
flash.Size = UDim2.fromScale(1, 1)
flash.BackgroundColor3 = Color3.new(1, 1, 1)
flash.BackgroundTransparency = 1
flash.Parent = flashGui

local function doFlash()
	flash.BackgroundTransparency = 0.1
	task.spawn(function()
		for i = 1, 18 do
			flash.BackgroundTransparency = 0.1 + (i / 18) * 0.9
			task.wait(0.02)
		end
		flash.BackgroundTransparency = 1
	end)
end

-- ── Spark burst at the break point ───────────────────────────────────────────
local function sparkBurst(position)
	local core = Instance.new("Part")
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.Shape = Enum.PartType.Ball
	core.Material = Enum.Material.Neon
	core.Color = Color3.fromRGB(255, 240, 180)
	core.Size = Vector3.new(1, 1, 1)
	core.CFrame = CFrame.new(position)
	core.Parent = workspace
	task.spawn(function()
		for i = 1, 16 do
			local s = 1 + i * 1.1
			core.Size = Vector3.new(s, s, s)
			core.Transparency = i / 16
			task.wait(0.02)
		end
		core:Destroy()
	end)
end

-- ── Shatter a model's parts ──────────────────────────────────────────────────
local function shatter(model)
	if not model then return end
	model:SetAttribute("Shattering", true) -- InterpolationRenderer will skip it

	local origin = model:GetPivot().Position
	local rng = Random.new(os.clock() * 1000)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = true
			part.CanQuery = false
			local dir = (part.Position - origin)
			if dir.Magnitude < 0.1 then
				dir = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
			end
			dir = dir.Unit
			part.AssemblyLinearVelocity = dir * rng:NextNumber(18, 34)
				+ Vector3.new(0, rng:NextNumber(14, 26), 0)
			part.AssemblyAngularVelocity = Vector3.new(
				rng:NextNumber(-30, 30), rng:NextNumber(-30, 30), rng:NextNumber(-30, 30))
			Debris:AddItem(part, 2.5)
		end
	end
end

-- Locate the live Bey model for a break event under its match folder.
local function findModel(matchId, pid)
	local matches = workspace:FindFirstChild("Matches")
	local folder = matches and matchId and matches:FindFirstChild(matchId) or nil
	return folder and folder:FindFirstChild("Bey_" .. tostring(pid)) or nil
end

local function onBreak(matchId, arenaOrigin, pid, localPos)
	if handled[pid] then return end
	handled[pid] = true

	-- Align the visual with the interpolated render position.
	task.delay(Constants.InterpolationDelay, function()
		local model = findModel(matchId, pid)
		local pos
		if model then
			pos = model:GetPivot().Position
		elseif localPos then
			pos = localPos + (arenaOrigin or Vector3.new(0, 0, 0))
		else
			pos = (arenaOrigin or Vector3.new(0, 0, 0)) + Vector3.new(0, Constants.BeyRadius, 0)
		end
		doFlash()
		sparkBurst(pos)
		shatter(model)
	end)
end

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	if not snapshot.events then return end
	for _, ev in ipairs(snapshot.events) do
		if ev.eventType == "HpBreak" then
			onBreak(snapshot.matchId, snapshot.arenaOrigin, ev.eventData.playerId, ev.eventData.position)
		end
	end
end)

-- Reset the guard at the start of each match.
Remotes.MatchStateChanged.OnClientEvent:Connect(function(phase)
	if phase == "Countdown" then
		handled = {}
	end
end)
