--[=[
	BeyController.lua
	Processes validated input queues (launch + commands) and manages command timers.
	Also owns the Poor auto-launch: a player who never clicks LAUNCH gets their
	aimed (or default) launch 2 s after GO — "a bad start, correspondingly".
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local LaunchQuality = require(ReplicatedStorage:WaitForChild("LaunchQuality"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local BeyController = {}

-- Single application path for clicked AND auto launches: position snaps to
-- the chosen release height, velocity/spin come pre-built (server-side only).
local function applyLaunch(matchState, pid, data, autoLaunched)
	local bState = matchState.beyStates[pid]
	if not bState then
		return
	end
	bState.position = Vector3.new(bState.position.X, data.height or Constants.LaunchHeightDefault, bState.position.Z)
	bState.velocity = data.launchVector
	bState.angularVelocity = Vector3.new(0, data.spinPower, 0)
	bState.launchQuality = data.quality
	table.insert(matchState.tickEvents, {
		eventType = "LaunchGraded",
		eventData = { playerId = pid, quality = data.quality, autoLaunched = autoLaunched or false },
	})
end

function BeyController.OnInputPhase(matchState)
	-- ── Launch inputs ─────────────────────────────────────────────────────────
	for _, inputEvent in ipairs(matchState.inputQueue) do
		applyLaunch(matchState, inputEvent.playerId, inputEvent.data, false)
	end
	table.clear(matchState.inputQueue)

	-- ── Poor auto-launch for missed clicks (live only; harness injects) ───────
	if not matchState.isHeadless then
		local now = workspace:GetServerTimeNow()
		if matchState.timers.countdownEndTime > 0
			and now >= matchState.timers.countdownEndTime + Constants.AutoLaunchDelay then
			for _, pid in ipairs(matchState.playerOrder) do
				local bState = matchState.beyStates[pid]
				if bState and not bState.launchConsumed and bState.zoneState ~= "Finished" then
					bState.launchConsumed = true
					local aim = LaunchQuality.clampAim(matchState.pendingAim[pid])
					local stadium = Stadiums.get(matchState.stadiumId)
					local multiplier = LaunchQuality.multiplierFor("Poor")
					local speed = Constants.PrototypeLaunchSpeed * (stadium.launchSpeedScale or 1) * multiplier
					applyLaunch(matchState, pid, {
						launchVector = LaunchQuality.aimToVector(aim, speed),
						spinPower = math.clamp(Constants.PrototypeLaunchSpin * multiplier, 0, 200),
						quality = "Poor",
						height = aim.height,
					}, true)
					print(string.format("[BeyController] Auto-launch (Poor) for player %d", pid))
				end
			end
		end
	end

	-- ── Command inputs ────────────────────────────────────────────────────────
	for _, cmdEvent in ipairs(matchState.commandQueue) do
		local bState = matchState.beyStates[cmdEvent.playerId]
		if bState and bState.commandTimer == 0 and bState.commandCooldownTimer == 0 then
			bState.currentCommand = cmdEvent.command
			bState.commandTimer = Constants.CommandDurationTicks
			table.insert(matchState.tickEvents, {
				eventType = "CommandIssued",
				eventData = { playerId = cmdEvent.playerId, command = cmdEvent.command },
			})
		end
	end
	table.clear(matchState.commandQueue)

	-- ── Command timer tick ────────────────────────────────────────────────────
	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]

		if bState.commandTimer > 0 then
			bState.commandTimer -= 1
			if bState.commandTimer == 0 then
				bState.currentCommand = nil
				bState.commandCooldownTimer = Constants.CommandCooldownTicks
			end
		elseif bState.commandCooldownTimer > 0 then
			bState.commandCooldownTimer -= 1
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
