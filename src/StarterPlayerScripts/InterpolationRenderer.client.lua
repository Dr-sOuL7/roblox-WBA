--[=[
	InterpolationRenderer.client.lua
	Buffers server snapshots to smoothly Lerp authoritative CFrame states.
	Preserves arcs, visualizes hitstop, and dynamically renders RPM spin.
]=]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local snapshotBuffer = {}
local RENDER_DELAY = Constants.InterpolationDelay
local SNAPSHOT_BUFFER_MAX = Constants.SnapshotBufferMax

local beyVisuals = {} -- { [pid] = { rotation = 0, hitstop = 0, spinDownPlaying = false } }

local function getBeyModel(playerId)
	return workspace:FindFirstChild("Bey_" .. tostring(playerId))
end

-- Collision audio by severity
local COLLISION_SOUNDS = {
	Light = { id = "rbxassetid://131154564", pitch = 1.3, volume = 0.25 },
	Heavy = { id = "rbxassetid://131154564", pitch = 1.0, volume = 0.6 },
	Smash = { id = "rbxassetid://131154564", pitch = 0.7, volume = 1.0 },
}

local function playCollisionSound(severity)
	local cfg = COLLISION_SOUNDS[severity] or COLLISION_SOUNDS.Light
	local sound = Instance.new("Sound")
	sound.SoundId = cfg.id
	sound.PlaybackSpeed = cfg.pitch
	sound.Volume = cfg.volume
	sound.Parent = workspace
	sound:Play()
	game.Debris:AddItem(sound, 2)
end

-- Spin-down audio: low grinding/whirring when angular velocity drops
local spinDownSounds = {} -- { [pid] = Sound }

local function updateSpinDownAudio(pid, angularMagnitude)
	if not beyVisuals[pid] then return end

	local model = getBeyModel(pid)
	if not model then return end

	if angularMagnitude < Constants.SpinDownAudioThreshold and angularMagnitude > Constants.MinEffectiveSpinThreshold then
		-- Should be playing spin-down
		if not spinDownSounds[pid] then
			local sound = Instance.new("Sound")
			sound.SoundId = "rbxassetid://131154564" -- Placeholder grinding
			sound.Looped = true
			sound.Volume = 0
			sound.PlaybackSpeed = 0.4
			sound.Parent = model
			sound:Play()
			spinDownSounds[pid] = sound
		end

		-- Fade in as spin drops — louder as it nears threshold
		local ratio = 1 - (angularMagnitude - Constants.MinEffectiveSpinThreshold) / (Constants.SpinDownAudioThreshold - Constants.MinEffectiveSpinThreshold)
		spinDownSounds[pid].Volume = math.clamp(ratio * 0.5, 0, 0.5)
		spinDownSounds[pid].PlaybackSpeed = 0.3 + ratio * 0.2
	else
		-- Stop spin-down audio
		if spinDownSounds[pid] then
			spinDownSounds[pid]:Stop()
			spinDownSounds[pid]:Destroy()
			spinDownSounds[pid] = nil
		end
	end
end

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
	table.insert(snapshotBuffer, snapshot)

	if #snapshotBuffer > SNAPSHOT_BUFFER_MAX then
		table.remove(snapshotBuffer, 1)
	end

	-- Process events for hitstop and audio
	for _, ev in ipairs(snapshot.events) do
		if ev.eventType == "Collision" then
			local class = ev.eventData.collisionClass

			-- Hitstop
			local hitstopDuration = 0
			if class == "Smash" then
				hitstopDuration = Constants.HitstopSmash
			elseif class == "Heavy" then
				hitstopDuration = Constants.HitstopHeavy
			end

			-- Apply hitstop to involved beys
			for _, pid in ipairs(ev.eventData.involvedBeys) do
				if not beyVisuals[pid] then beyVisuals[pid] = { rotation = 0, hitstop = 0 } end
				if hitstopDuration > 0 then
					beyVisuals[pid].hitstop = hitstopDuration
				end
			end

			-- Collision audio
			playCollisionSound(class)
		end
	end
end)

RunService.RenderStepped:Connect(function(dt)
	local renderTime = os.clock() - RENDER_DELAY

	local snap0, snap1 = nil, nil
	for i = #snapshotBuffer, 1, -1 do
		if snapshotBuffer[i].serverTimestamp <= renderTime then
			snap0 = snapshotBuffer[i]
			snap1 = snapshotBuffer[i + 1]
			break
		end
	end

	if snap0 and snap1 then
		-- Epsilon denominator protection against NaN
		local timeDiff = math.max(0.0001, snap1.serverTimestamp - snap0.serverTimestamp)
		local alpha = math.clamp((renderTime - snap0.serverTimestamp) / timeDiff, 0, 1)

		for pid, bState0 in pairs(snap0.beyStates) do
			local bState1 = snap1.beyStates[pid]
			if bState1 then
				if not beyVisuals[pid] then beyVisuals[pid] = { rotation = 0, hitstop = 0 } end
				local vis = beyVisuals[pid]

				-- Process visual hitstop freeze
				if vis.hitstop > 0 then
					vis.hitstop -= dt
					continue
				end

				-- Accumulate spin derived from actual physical RPM
				local angMag = bState0.angularVelocity.Magnitude
				vis.rotation += angMag * dt

				-- Spin-down audio
				updateSpinDownAudio(pid, angMag)

				local model = getBeyModel(pid)
				if model then
					local interpPos = bState0.position:Lerp(bState1.position, alpha)
					local tiltAngle = math.rad(bState0.tilt)

					model.CFrame = CFrame.new(interpPos) * CFrame.Angles(tiltAngle, vis.rotation, 0)
				end
			end
		end
	elseif snap0 then
		for pid, bState0 in pairs(snap0.beyStates) do
			if not beyVisuals[pid] then beyVisuals[pid] = { rotation = 0, hitstop = 0 } end
			local vis = beyVisuals[pid]

			if vis.hitstop > 0 then
				vis.hitstop -= dt
				continue
			end

			local angMag = bState0.angularVelocity.Magnitude
			vis.rotation += angMag * dt

			updateSpinDownAudio(pid, angMag)

			local model = getBeyModel(pid)
			if model then
				model.CFrame = CFrame.new(bState0.position) * CFrame.Angles(math.rad(bState0.tilt), vis.rotation, 0)
			end
		end
	end
end)
