--[=[
	InterpolationRenderer.client.lua
	Buffers server snapshots and smoothly lerps Bey CFrame states at render rate.
	Handles: spin rotation, tilt amplification, hitstop, spin-down audio,
	         command-state glow (Attack/Defend/Evade), ring-out danger pulse.
]=]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local snapshotBuffer = {}
local RENDER_DELAY = Constants.InterpolationDelay
local SNAPSHOT_BUFFER_MAX = Constants.SnapshotBufferMax

-- Per-player visual state
-- { rotation, hitstop, commandGlow (PointLight), ringOutBox (SelectionBox) }
local beyVisuals = {}

-- Multi-match (ADR-001): models live under workspace.Matches[matchId] and the
-- simulation is local-space — rendering adds the match's arena origin.
local currentMatchId = nil
local arenaOrigin = Vector3.new(0, 0, 0)
local matchFolder = nil

local function getBeyModel(pid)
	if not currentMatchId then return nil end
	if not matchFolder or matchFolder.Parent == nil or matchFolder.Name ~= currentMatchId then
		local matches = workspace:FindFirstChild("Matches")
		matchFolder = matches and matches:FindFirstChild(currentMatchId) or nil
	end
	return matchFolder and matchFolder:FindFirstChild("Bey_" .. tostring(pid)) or nil
end

-- Lazily create and attach visual effect instances to the Bey model.
local function ensureVisuals(pid)
	if beyVisuals[pid] then return beyVisuals[pid] end
	beyVisuals[pid] = { rotation = 0, hitstop = 0, commandGlow = nil, ringOutBox = nil }
	return beyVisuals[pid]
end

-- Bey models are destroyed and rebuilt every rematch, taking attached effect
-- instances with them. A destroyed instance has Parent == nil and can never be
-- reparented, so cached references must be dropped and recreated or the glow,
-- warning box, and audio silently stop working from the second match onward.
local function isDead(instance)
	return instance == nil or instance.Parent == nil
end

local function ensureCommandGlow(pid, model)
	local vis = beyVisuals[pid]
	if not isDead(vis.commandGlow) then return vis.commandGlow end
	local pivot = model:FindFirstChild("Pivot") or model.PrimaryPart
	if not pivot then return nil end
	local light = Instance.new("PointLight")
	light.Name = "CommandGlow"
	light.Brightness = 0
	light.Range = 16
	light.Shadows = false
	light.Parent = pivot
	vis.commandGlow = light
	return light
end

local function ensureRingOutBox(pid, model)
	local vis = beyVisuals[pid]
	if not isDead(vis.ringOutBox) then return vis.ringOutBox end
	local box = Instance.new("SelectionBox")
	box.Name = "RingOutWarning"
	box.Color3 = Color3.fromRGB(255, 60, 0)
	box.LineThickness = 0.08
	box.SurfaceTransparency = 0.85
	box.SurfaceColor3 = Color3.fromRGB(255, 60, 0)
	box.Visible = false
	box.Adornee = model
	box.Parent = model
	vis.ringOutBox = box
	return box
end

-- ── Command glow colours ──────────────────────────────────────────────────────

local COMMAND_GLOW = {
	Attack = { color = Color3.fromRGB(255, 60,  60),  brightness = 3 },
	Defend = { color = Color3.fromRGB(60,  100, 255), brightness = 3 },
	Evade  = { color = Color3.fromRGB(60,  220, 60),  brightness = 3 },
}

-- ── Collision audio ───────────────────────────────────────────────────────────

local COLLISION_SOUNDS = {
	Light = { id = "", pitch = 1.3, volume = 0.25 },
	Heavy = { id = "", pitch = 1.0, volume = 0.6 },
	Smash = { id = "", pitch = 0.7, volume = 1.0 },
}

local function playCollisionSound(severity)
	local cfg = COLLISION_SOUNDS[severity] or COLLISION_SOUNDS.Light
	if cfg.id == "" then return end -- no asset id assigned yet; skip to avoid console errors
	local sound = Instance.new("Sound")
	sound.SoundId = cfg.id
	sound.PlaybackSpeed = cfg.pitch
	sound.Volume = cfg.volume
	sound.Parent = workspace
	sound:Play()
	game.Debris:AddItem(sound, 2)
end

-- ── Spin-down audio ───────────────────────────────────────────────────────────

local spinDownSounds = {}

local function updateSpinDownAudio(pid, angMag)
	if not beyVisuals[pid] then return end
	local model = getBeyModel(pid)
	if not model then return end

	-- Drop references to sounds destroyed with last match's Bey model
	if spinDownSounds[pid] and spinDownSounds[pid].Parent == nil then
		spinDownSounds[pid] = nil
	end

	if angMag < Constants.SpinDownAudioThreshold and angMag > Constants.MinEffectiveSpinThreshold then
		if not spinDownSounds[pid] then
			local sound = Instance.new("Sound")
			sound.SoundId = ""
			sound.Looped = true
			sound.Volume = 0
			sound.PlaybackSpeed = 0.4
			sound.Parent = model
			sound:Play()
			spinDownSounds[pid] = sound
		end
		local ratio = 1 - (angMag - Constants.MinEffectiveSpinThreshold)
			/ (Constants.SpinDownAudioThreshold - Constants.MinEffectiveSpinThreshold)
		spinDownSounds[pid].Volume = math.clamp(ratio * 0.5, 0, 0.5)
		spinDownSounds[pid].PlaybackSpeed = 0.3 + ratio * 0.2
	else
		if spinDownSounds[pid] then
			spinDownSounds[pid]:Stop()
			spinDownSounds[pid]:Destroy()
			spinDownSounds[pid] = nil
		end
	end
end

-- ── Snapshot receive ──────────────────────────────────────────────────────────

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	-- New match: drop stale snapshots so interpolation never lerps across matches
	if snapshot.matchId ~= currentMatchId then
		currentMatchId = snapshot.matchId
		arenaOrigin = snapshot.arenaOrigin or Vector3.new(0, 0, 0)
		matchFolder = nil
		table.clear(snapshotBuffer)
	end

	table.insert(snapshotBuffer, snapshot)
	if #snapshotBuffer > SNAPSHOT_BUFFER_MAX then
		table.remove(snapshotBuffer, 1)
	end

	for _, ev in ipairs(snapshot.events) do
		if ev.eventType == "Collision" then
			local class = ev.eventData.collisionClass
			local hitstopDuration = 0
			if class == "Smash" then
				hitstopDuration = Constants.HitstopSmash
			elseif class == "Heavy" then
				hitstopDuration = Constants.HitstopHeavy
			end
			for _, pid in ipairs(ev.eventData.involvedBeys) do
				local vis = ensureVisuals(pid)
				if hitstopDuration > 0 then
					vis.hitstop = hitstopDuration
				end
			end
			playCollisionSound(class)
		end
	end
end)

-- ── Render loop ───────────────────────────────────────────────────────────────

local ringOutPulseTime = 0

RunService.RenderStepped:Connect(function(dt)
	ringOutPulseTime += dt
	local renderTime = workspace:GetServerTimeNow() - RENDER_DELAY

	local snap0, snap1 = nil, nil
	for i = #snapshotBuffer, 1, -1 do
		if snapshotBuffer[i].serverTimestamp <= renderTime then
			snap0 = snapshotBuffer[i]
			snap1 = snapshotBuffer[i + 1]
			break
		end
	end

	if not snap0 then return end

	local alpha = 0
	if snap1 then
		local timeDiff = math.max(0.0001, snap1.serverTimestamp - snap0.serverTimestamp)
		alpha = math.clamp((renderTime - snap0.serverTimestamp) / timeDiff, 0, 1)
	end

	for pid, bState0 in pairs(snap0.beyStates) do
		local vis = ensureVisuals(pid)
		local model = getBeyModel(pid)

		-- Hitstop freeze
		if vis.hitstop > 0 then
			vis.hitstop -= dt
			continue
		end

		-- Spin accumulation
		local angMag = bState0.angularVelocity.Magnitude
		vis.rotation += angMag * dt

		updateSpinDownAudio(pid, angMag)

		if model then
			-- Position
			local pos = bState0.position
			if snap1 then
				local bState1 = snap1.beyStates[pid]
				if bState1 then
					pos = bState0.position:Lerp(bState1.position, alpha)
				end
			end

			-- Tilt amplified 1.5x for readability — makes wobble unmistakable
			local tiltAngle = math.rad(bState0.tilt * 1.5)
			model:PivotTo(CFrame.new(pos + arenaOrigin) * CFrame.Angles(tiltAngle, vis.rotation, 0))

			-- ── Command glow ──────────────────────────────────────────────
			local glow = ensureCommandGlow(pid, model)
			if glow then
				local cmd = bState0.currentCommand
				if cmd and COMMAND_GLOW[cmd] then
					glow.Color = COMMAND_GLOW[cmd].color
					glow.Brightness = COMMAND_GLOW[cmd].brightness
				else
					glow.Brightness = 0
				end
			end

			-- ── Ring-out danger pulse ─────────────────────────────────────
			local ringBox = ensureRingOutBox(pid, model)
			if ringBox then
				if bState0.zoneState == "RingOut" then
					ringBox.Visible = true
					-- 5 Hz pulse: transparency oscillates 0.6–0.9
					local pulse = 0.75 + 0.15 * math.sin(ringOutPulseTime * math.pi * 10)
					ringBox.SurfaceTransparency = pulse
				else
					ringBox.Visible = false
				end
			end
		end
	end
end)
