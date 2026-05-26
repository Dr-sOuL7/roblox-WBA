--[=[
	DebugVisualizer.client.lua
	World-space debug visualization for Prototype 1 testing.
	Toggle all visuals with F3.

	Renders:
	- Velocity vectors (blue arrows)
	- Collision normals (yellow arrows at contact point)
	- Wobble direction (magenta line from bey top)
	- Bowl-center influence (faint green line to origin)
	- Collision severity markers (flash sphere: green=Light, orange=Heavy, red=Smash)
]=]
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local DEBUG_ENABLED = false
local DEBUG_FOLDER_NAME = "DebugVisuals"

-- ── Part Pool ────────────────────────────────────────────────────────
local partPool = {}
local activePartCount = 0

local function getDebugFolder()
	local folder = workspace:FindFirstChild(DEBUG_FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = DEBUG_FOLDER_NAME
		folder.Parent = workspace
	end
	return folder
end

local function acquirePart()
	activePartCount += 1
	if partPool[activePartCount] then
		local p = partPool[activePartCount]
		p.Transparency = 0
		return p
	end

	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = getDebugFolder()
	partPool[activePartCount] = part
	return part
end

local function resetPool()
	for i = activePartCount + 1, #partPool do
		partPool[i].Transparency = 1
		partPool[i].Size = Vector3.new(0.01, 0.01, 0.01)
	end
	-- Also hide anything beyond current count
	for i = 1, #partPool do
		if i > activePartCount then
			partPool[i].Transparency = 1
			partPool[i].Size = Vector3.new(0.01, 0.01, 0.01)
		end
	end
	activePartCount = 0
end

local function drawLine(from: Vector3, to: Vector3, color: Color3, thickness: number)
	local part = acquirePart()
	local mid = (from + to) / 2
	local diff = to - from
	local length = diff.Magnitude

	if length < 0.01 then
		part.Transparency = 1
		return
	end

	part.Size = Vector3.new(thickness, thickness, length)
	part.CFrame = CFrame.lookAt(mid, to)
	part.Color = color
	part.Transparency = 0.3
end

local function drawSphere(position: Vector3, radius: number, color: Color3, transparency: number)
	local part = acquirePart()
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
	part.Position = position
	part.Color = color
	part.Transparency = transparency or 0.4
end

-- ── Collision Event Cache ────────────────────────────────────────────
local recentCollisions = {} -- { {position, severity, timeRemaining} }

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	if not DEBUG_ENABLED then return end

	for _, ev in ipairs(snapshot.events) do
		if ev.eventType == "Collision" then
			table.insert(recentCollisions, {
				position = ev.eventData.position,
				severity = ev.eventData.collisionClass,
				timeRemaining = 0.5, -- Flash duration
			})
		end
	end
end)

-- ── Toggle ───────────────────────────────────────────────────────────
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.F3 then
		DEBUG_ENABLED = not DEBUG_ENABLED
		print(string.format("[DebugViz] World-space debug visualization: %s", DEBUG_ENABLED and "ON" or "OFF"))

		if not DEBUG_ENABLED then
			-- Hide all
			for _, p in ipairs(partPool) do
				p.Transparency = 1
				p.Size = Vector3.new(0.01, 0.01, 0.01)
			end
			recentCollisions = {}
		end
	end
end)

-- ── Severity Colors ──────────────────────────────────────────────────
local SEVERITY_COLORS = {
	Light = Color3.fromRGB(80, 220, 80), -- Green
	Heavy = Color3.fromRGB(255, 165, 0), -- Orange
	Smash = Color3.fromRGB(255, 40, 40), -- Red
}

-- ── Render Loop ──────────────────────────────────────────────────────
local latestSnapshot = nil

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	latestSnapshot = snapshot
end)

RunService.RenderStepped:Connect(function(dt)
	if not DEBUG_ENABLED then return end

	resetPool()

	local snapshot = latestSnapshot
	if not snapshot then return end

	for pid, bState in pairs(snapshot.beyStates) do
		local pos = bState.position
		if not pos then continue end

		-- 1. Velocity vector (blue arrow)
		local vel = bState.velocity
		if vel and vel.Magnitude > 0.5 then
			local velEnd = pos + vel.Unit * math.min(vel.Magnitude * 0.15, 10)
			drawLine(pos, velEnd, Color3.fromRGB(60, 130, 255), 0.15)
		end

		-- 2. Bowl-center influence (faint green line to origin)
		local origin = Vector3.new(0, pos.Y, 0)
		drawLine(pos, origin, Color3.fromRGB(40, 180, 40), 0.06)

		-- 3. Wobble direction (magenta tilt indicator from bey top)
		local tiltRad = math.rad(bState.tilt or 0)
		if tiltRad > 0.01 then
			local tiltDir = Vector3.new(math.sin(tiltRad), 0, math.cos(tiltRad))
			local topPos = pos + Vector3.new(0, 2, 0)
			local wobbleEnd = topPos + tiltDir * math.min(bState.tilt * 0.1, 5)
			drawLine(topPos, wobbleEnd, Color3.fromRGB(220, 60, 220), 0.12)
		end
	end

	-- 4. Collision severity markers (flash spheres)
	local remaining = {}
	for _, col in ipairs(recentCollisions) do
		col.timeRemaining -= dt
		if col.timeRemaining > 0 then
			local color = SEVERITY_COLORS[col.severity] or SEVERITY_COLORS.Light
			local fadeAlpha = math.clamp(col.timeRemaining / 0.5, 0, 1)
			drawSphere(col.position, 1.5 * fadeAlpha + 0.5, color, 1 - fadeAlpha * 0.6)
			table.insert(remaining, col)
		end
	end
	recentCollisions = remaining
end)
