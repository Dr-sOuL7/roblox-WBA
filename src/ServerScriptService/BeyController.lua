--[=[
	BeyController.lua
	Processes the validated launch queue, applies the per-player analog input
	(facing + Dash/Revolve held-state) each tick, and owns the Poor auto-launch:
	a player who never clicks LAUNCH gets their aimed (or default) launch 2 s after
	GO — "a bad start, correspondingly".

	The flat arena has no bowl to fall into, so the launch flattens to the floor:
	it grants spin + a horizontal impulse toward the centre (real-world physics
	carries it from there). Battle steering (facing turn, dash, revolve orbit)
	lives in PhysicsController; this module only records intent onto the BeyState.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local LaunchQuality = require(ReplicatedStorage:WaitForChild("LaunchQuality"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local BeyController = {}

local TWO_PI = math.pi * 2
local FLOOR_Y = Constants.BeyRadius

-- Single application path for clicked AND auto launches. The Bey is fired into
-- the FLAT arena: spin from the launch quality, a horizontal impulse toward the
-- centre, and a facing that matches the launch direction.
local function applyLaunch(matchState, pid, data, autoLaunched)
	local bState = matchState.beyStates[pid]
	if not bState then
		return
	end

	-- Flatten the launch vector onto the floor plane (no bowl to plunge into).
	local lv = data.launchVector or Vector3.new(0, 0, 0)
	local horiz = Vector3.new(lv.X, 0, lv.Z)
	local horizSpeed = horiz.Magnitude

	-- Guarantee a meaningful entry so the Beys actually engage. Aim toward the
	-- centre when the launch carried no horizontal component.
	local minImpulse = Constants.LaunchImpulseSpeed * 0.6
	local dir
	if horizSpeed < 0.01 then
		local toCentre = Vector3.new(-bState.position.X, 0, -bState.position.Z)
		dir = (toCentre.Magnitude > 0.01) and toCentre.Unit or Vector3.new(1, 0, 0)
		horizSpeed = Constants.LaunchImpulseSpeed
	else
		dir = horiz.Unit
		if horizSpeed < minImpulse then horizSpeed = minImpulse end
	end

	bState.position = Vector3.new(bState.position.X, FLOOR_Y, bState.position.Z)
	bState.velocity = dir * horizSpeed
	bState.previousPosition = bState.position
	bState.angularVelocity = Vector3.new(0, data.spinPower or Constants.LaunchBaseSpin, 0)
	bState.facingAngle = math.atan2(dir.Z, dir.X)
	bState.targetFacing = bState.facingAngle
	bState.launchQuality = data.quality
	bState.launchConsumed = true

	table.insert(matchState.tickEvents, {
		eventType = "LaunchGraded",
		eventData = { playerId = pid, quality = data.quality, autoLaunched = autoLaunched or false },
	})
end

BeyController.applyLaunch = applyLaunch

-- Apply the latest validated analog input for one player onto its BeyState.
local function applyInput(bState, packet)
	if not packet then return end
	if packet.facingAngle then
		local f = packet.facingAngle % TWO_PI
		if f < 0 then f += TWO_PI end
		bState.targetFacing = f
	end
	bState.isDashing = packet.dash == true
	bState.isRevolving = packet.revolve == true
end

function BeyController.OnInputPhase(matchState)
	-- ── Launch inputs (clicked LAUNCH) ────────────────────────────────────────
	for _, inputEvent in ipairs(matchState.inputQueue) do
		local bState = matchState.beyStates[inputEvent.playerId]
		if bState and not bState.launchConsumed then
			applyLaunch(matchState, inputEvent.playerId, inputEvent.data, false)
		end
	end
	table.clear(matchState.inputQueue)

	-- ── Poor auto-launch for missed clicks (live only; harness launches directly)
	if not matchState.isHeadless then
		local now = workspace:GetServerTimeNow()
		if matchState.timers.countdownEndTime > 0
			and now >= matchState.timers.countdownEndTime + Constants.AutoLaunchDelay then
			for _, pid in ipairs(matchState.playerOrder) do
				local bState = matchState.beyStates[pid]
				if bState and not bState.launchConsumed and bState.zoneState ~= "Finished" then
					local aim = LaunchQuality.clampAim(matchState.pendingAim[pid])
					local stadium = Stadiums.get(matchState.stadiumId)
					local multiplier = LaunchQuality.multiplierFor("Poor")
					local speed = Constants.PrototypeLaunchSpeed * (stadium.launchSpeedScale or 1) * multiplier
					applyLaunch(matchState, pid, {
						launchVector = LaunchQuality.aimToVector(aim, speed),
						spinPower = math.clamp(Constants.PrototypeLaunchSpin * multiplier, 0, 200),
						quality = "Poor",
					}, true)
					print(string.format("[BeyController] Auto-launch (Poor) for player %d", pid))
				end
			end
		end
	end

	-- ── Analog input: facing + Dash/Revolve held-state ────────────────────────
	-- Bots write their decision into the same buffer (see BotController), so this
	-- is the single application path for humans and bots alike.
	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]
		if bState.zoneState ~= "Finished" then
			applyInput(bState, matchState.inputBuffer[pid])
		end
	end
end

function BeyController.OnStateUpdatePhase(matchState)
	-- Position integration lives inside PhysicsController sub-steps.
	-- This phase records previousPosition for debug/sweep reference.
	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]
		bState.previousPosition = bState.position
	end
end

TickManager.RegisterHandler("Input", BeyController.OnInputPhase)
TickManager.RegisterHandler("StateUpdate", BeyController.OnStateUpdatePhase)

return BeyController
