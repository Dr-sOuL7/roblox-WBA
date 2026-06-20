--[=[
	InterpolationRenderer.client.lua
	Buffers server snapshots and smoothly lerps Bey CFrame states at render rate.
	Handles: spin rotation, tilt amplification, hitstop, spin-down audio, a facing
	arrow (which never spins with the body), a Dash/Revolve/combo ability glow, and
	a motion trail tinted by the active ability.

	Multi-match (ADR-001): models live under workspace.Matches[matchId] and the
	simulation is local arena-space — rendering adds the match's arena origin. The
	arena is FLAT (no bowl): the Bey renders sitting on the floor at y=0.
]=]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local snapshotBuffer = {}
local RENDER_DELAY = Constants.InterpolationDelay
local SNAPSHOT_BUFFER_MAX = Constants.SnapshotBufferMax
local TWO_PI = math.pi * 2

-- Per-player visual state: { rotation, hitstop, facing, facingInit, glow, arrow, trail }
local beyVisuals = {}

-- Multi-match (ADR-001): models live under workspace.Matches[matchId].
local currentMatchId = nil
local arenaOrigin = Vector3.new(0, 0, 0)
local matchFolder = nil

local missingModelWarned = {} -- "matchId:pid" -> true (one diagnostic per Bey per match)

local function getBeyModel(pid)
	if not currentMatchId then return nil end
	if not matchFolder or matchFolder.Parent == nil or matchFolder.Name ~= currentMatchId then
		local matches = workspace:FindFirstChild("Matches")
		matchFolder = matches and matches:FindFirstChild(currentMatchId) or nil
	end
	local model = matchFolder and matchFolder:FindFirstChild("Bey_" .. tostring(pid)) or nil
	if not model then
		local key = tostring(currentMatchId) .. ":" .. tostring(pid)
		if not missingModelWarned[key] then
			missingModelWarned[key] = true
			task.delay(2, function()
				if currentMatchId and not getBeyModel(pid) then
					warn(string.format("[Renderer] Bey model for %s not replicated in match %s — check StreamingEnabled/ReplicationFocus", tostring(pid), tostring(currentMatchId)))
				end
			end)
		end
	end
	return model
end

local function ensureVisuals(pid)
	if beyVisuals[pid] then return beyVisuals[pid] end
	beyVisuals[pid] = { rotation = 0, hitstop = 0, facing = 0, facingInit = false }
	return beyVisuals[pid]
end

-- Bey models are destroyed and rebuilt every rematch; a destroyed instance has
-- Parent == nil and can never be reparented, so cached references must be dropped.
local function isDead(instance)
	return instance == nil or instance.Parent == nil
end

local function ensureAbilityGlow(pid, model)
	local vis = beyVisuals[pid]
	if not isDead(vis.glow) then return vis.glow end
	local pivot = model:FindFirstChild("Pivot") or model.PrimaryPart
	if not pivot then return nil end
	local light = Instance.new("PointLight")
	light.Name = "AbilityGlow"
	light.Brightness = 0
	light.Range = 18
	light.Shadows = false
	light.Parent = pivot
	vis.glow = light
	return light
end

-- A small neon arrow that shows facing WITHOUT spinning with the Bey body.
local function ensureFacingArrow(pid, model)
	local vis = beyVisuals[pid]
	if not isDead(vis.arrow) then return vis.arrow end
	local arrow = Instance.new("Part")
	arrow.Name = "FacingArrow"
	arrow.Size = Vector3.new(0.4, 0.4, 2.4)
	arrow.Anchored = true
	arrow.CanCollide = false
	arrow.CanQuery = false
	arrow.Material = Enum.Material.Neon
	arrow.Color = Color3.fromRGB(255, 255, 255)
	arrow.Parent = model
	vis.arrow = arrow
	return arrow
end

-- Motion trail: draws the Bey's path so movement reads as movement. Tinted by the
-- active ability for at-a-glance feedback.
local function ensureTrail(pid, model)
	local vis = beyVisuals[pid]
	if not isDead(vis.trail) then return vis.trail end
	local pivot = model:FindFirstChild("Pivot") or model.PrimaryPart
	if not pivot then return nil end
	local a0 = Instance.new("Attachment")
	a0.Name = "TrailTop"
	a0.Position = Vector3.new(0, 1.2, 0)
	a0.Parent = pivot
	local a1 = Instance.new("Attachment")
	a1.Name = "TrailBottom"
	a1.Position = Vector3.new(0, -0.8, 0)
	a1.Parent = pivot
	local trail = Instance.new("Trail")
	trail.Name = "MotionTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.35
	trail.MinLength = 0.05
	trail.LightEmission = 0.5
	trail.FaceCamera = true
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Parent = pivot
	vis.trail = trail
	return trail
end

local TRAIL_NEUTRAL = Color3.fromRGB(180, 210, 255)
local GLOW_COMBO = Color3.fromRGB(255, 90, 230)
local GLOW_DASH = Color3.fromRGB(255, 110, 40)
local GLOW_REVOLVE = Color3.fromRGB(120, 90, 255)

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

-- ── Angular lerp helper ─────────────────────────────────────────────────────────
local function lerpAngle(a, b, t)
	local diff = (b - a + math.pi) % TWO_PI - math.pi
	return a + diff * t
end

-- ── Snapshot receive ──────────────────────────────────────────────────────────
Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	-- New match: drop stale snapshots + visuals so nothing lerps across matches.
	if snapshot.matchId ~= currentMatchId then
		currentMatchId = snapshot.matchId
		arenaOrigin = snapshot.arenaOrigin or Vector3.new(0, 0, 0)
		matchFolder = nil
		table.clear(snapshotBuffer)
		table.clear(beyVisuals)
		table.clear(spinDownSounds)
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
				-- beyVisuals is keyed by the snapshot's STRING pids
				local vis = ensureVisuals(tostring(pid))
				if hitstopDuration > 0 then
					vis.hitstop = hitstopDuration
				end
			end
			playCollisionSound(class)
		end
	end
end)

-- ── Render loop ───────────────────────────────────────────────────────────────
RunService.RenderStepped:Connect(function(dt)
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

		if vis.hitstop > 0 then
			vis.hitstop -= dt
			continue
		end

		local angMag = bState0.angularVelocity.Magnitude
		vis.rotation += angMag * dt
		updateSpinDownAudio(pid, angMag)

		if not model then continue end
		if model:GetAttribute("Shattering") then continue end -- break animation owns it now

		-- Position (lerp), rendered so the Bey sits on the flat floor (top at y=0).
		local pos = bState0.position
		local targetFacing = bState0.facingAngle or 0
		if snap1 then
			local bState1 = snap1.beyStates[pid]
			if bState1 then
				pos = bState0.position:Lerp(bState1.position, alpha)
				targetFacing = lerpAngle(bState0.facingAngle or 0, bState1.facingAngle or 0, alpha)
			end
		end
		local renderPos = Vector3.new(pos.X, math.max(0, pos.Y - Constants.BeyRadius), pos.Z) + arenaOrigin

		-- Smooth the displayed facing.
		if not vis.facingInit then
			vis.facing = targetFacing
			vis.facingInit = true
		else
			vis.facing = lerpAngle(vis.facing, targetFacing, math.clamp(dt * 12, 0, 1))
		end

		-- Tilt amplified 1.5× for readability.
		local tiltAngle = math.rad((bState0.tilt or 0) * 1.5)
		model:PivotTo(CFrame.new(renderPos) * CFrame.Angles(tiltAngle, vis.rotation, 0))

		-- Facing arrow: positioned/oriented AFTER PivotTo so it doesn't spin.
		local arrow = ensureFacingArrow(pid, model)
		if arrow then
			local fdir = Vector3.new(math.cos(vis.facing), 0, math.sin(vis.facing))
			local arrowCenter = renderPos + Vector3.new(0, Constants.BeyRadius + 1.6, 0) + fdir * (Constants.BeyRadius + 0.6)
			arrow.CFrame = CFrame.lookAt(arrowCenter, arrowCenter + fdir)
		end

		-- Ability glow + trail tint (combo / dash / revolve).
		local glow = ensureAbilityGlow(pid, model)
		local trail = ensureTrail(pid, model)
		local glowColor, brightness = nil, 0
		if bState0.isDashing and bState0.isRevolving then
			glowColor, brightness = GLOW_COMBO, 4
		elseif bState0.isDashing then
			glowColor, brightness = GLOW_DASH, 4
		elseif bState0.isRevolving then
			glowColor, brightness = GLOW_REVOLVE, 3.5
		end
		if glow then
			if glowColor then glow.Color = glowColor end
			glow.Brightness = brightness
		end
		if trail then
			trail.Color = ColorSequence.new(glowColor or TRAIL_NEUTRAL)
		end
	end
end)
