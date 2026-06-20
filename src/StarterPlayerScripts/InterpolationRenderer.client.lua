--[=[
	InterpolationRenderer.client.lua
	Buffers server snapshots and lerps Bey CFrames at render rate.
	Handles: position interpolation, spin rotation, tilt, facing indicator,
	Dash/Revolve glow, hitstop, collision audio and spin-down audio.
]=]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local snapshotBuffer = {}
local RENDER_DELAY = Constants.InterpolationDelay
local SNAPSHOT_BUFFER_MAX = Constants.SnapshotBufferMax
local TWO_PI = math.pi * 2

-- Per-player visual state
local beyVisuals = {}

local function getBeyModel(pid)
	return workspace:FindFirstChild("Bey_" .. tostring(pid))
end

local function ensureVisuals(pid)
	if beyVisuals[pid] then return beyVisuals[pid] end
	beyVisuals[pid] = { rotation = 0, hitstop = 0, facing = 0, facingInit = false }
	return beyVisuals[pid]
end

local function ensureAbilityGlow(pid, model)
	local vis = beyVisuals[pid]
	if vis.glow then return vis.glow end
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
	if vis.arrow then return vis.arrow end
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

-- ── Collision audio ───────────────────────────────────────────────────────────
local COLLISION_SOUNDS = {
	Light = { id = "", pitch = 1.3, volume = 0.25 },
	Heavy = { id = "", pitch = 1.0, volume = 0.6 },
	Smash = { id = "", pitch = 0.7, volume = 1.0 },
}

local function playCollisionSound(severity)
	local cfg = COLLISION_SOUNDS[severity] or COLLISION_SOUNDS.Light
	if cfg.id == "" then return end
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

-- ── Angular lerp helper ─────────────────────────────────────────────────────────
local function lerpAngle(a, b, t)
	local diff = (b - a + math.pi) % TWO_PI - math.pi
	return a + diff * t
end

-- ── Ability glow colours ──────────────────────────────────────────────────────
local function applyAbilityGlow(glow, isDashing, isRevolving)
	if not glow then return end
	if isDashing and isRevolving then
		glow.Color = Color3.fromRGB(255, 90, 230) -- combo: magenta
		glow.Brightness = 4
	elseif isDashing then
		glow.Color = Color3.fromRGB(255, 110, 40) -- dash: orange
		glow.Brightness = 4
	elseif isRevolving then
		glow.Color = Color3.fromRGB(120, 90, 255) -- revolve: purple
		glow.Brightness = 3.5
	else
		glow.Brightness = 0
	end
end

-- ── New-match reset ─────────────────────────────────────────────────────────────
-- Old Bey models (and their child glow/arrow/sounds) are destroyed during cleanup,
-- so just drop the stale references; they'll be recreated for the new models.
Remotes.MatchStateChanged.OnClientEvent:Connect(function(phase)
	if phase == "Countdown" then
		table.clear(snapshotBuffer)
		table.clear(beyVisuals)
		table.clear(spinDownSounds)
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
		local renderPos = Vector3.new(pos.X, math.max(0, pos.Y - Constants.BeyRadius), pos.Z)

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

		-- Ability glow.
		applyAbilityGlow(ensureAbilityGlow(pid, model), bState0.isDashing, bState0.isRevolving)
	end
end)
