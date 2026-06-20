--[=[
	SpinEvaluator.lua
	Natural spin decay, destabilization (wobble) and the Spin-Out finish.

	Two finish conditions exist in the game:
	  • HP Break  — handled in PhysicsController the instant hp hits 0.
	  • Spin Out  — handled here: the Bey runs out of effective spin OR is
	    destabilized past the tilt-collapse threshold and topples.

	Stamina slows spin decay; structural balance speeds tilt recovery.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local SpinEvaluator = {}

function SpinEvaluator.OnEvaluationPhase(matchState)
	local dt = 1 / Constants.SimulationTickRate
	local activeCount = 0
	local lastActiveBey = nil

	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]
		if bState.zoneState == "Finished" then continue end

		-- Natural spin decay — higher Stamina meaningfully extends spin life.
		-- Per-tick spin loss scales inversely with Stamina, so the gap between
		-- builds actually matters (a Stamina build clearly out-spins a Defender).
		local stamina = (bState.mods and bState.mods.Stamina) or 1.0
		local decay = 1 - (1 - Constants.AngularDecay) * (0.58 + 0.42 / math.max(0.5, stamina))
		bState.angularVelocity *= decay
		local rpm = bState.angularVelocity.Magnitude

		local stabilityRatio = bState.stability / Constants.BaseStability
		if stabilityRatio < 0.3 then
			-- Non-linear wobble escalation (death spiral from destabilization)
			bState.tilt = bState.tilt + math.pow(1 - stabilityRatio, 2) * Constants.WobbleAmplification * dt
		else
			-- Tilt recovery — better-balanced Beys settle faster.
			if bState.tilt > 0 then
				local balance = (bState.profile and bState.profile.balance) or 1.0
				local recoveryRate = Constants.WobbleTiltRecoveryRate * balance
				bState.tilt = math.max(0, bState.tilt - recoveryRate * dt)
			end
		end

		-- Finish thresholds: out of spin, or toppled by destabilization.
		if rpm < Constants.MinEffectiveSpinThreshold or bState.tilt > Constants.TiltCollapseThreshold then
			bState.criticalSpinTimer += dt
			if bState.criticalSpinTimer >= Constants.CriticalSpinWindow then
				bState.zoneState = "Finished"
				bState.finishReason = "SpinOut"
				bState.angularVelocity = Vector3.new(0, 0, 0)
				bState.velocity = Vector3.new(0, 0, 0)
				bState.isDashing = false
				bState.isRevolving = false

				print(string.format("[SpinEvaluator] Bey %d finished: SpinOut (RPM: %.1f, Tilt: %.1f)", pid, rpm, bState.tilt))
				table.insert(matchState.tickEvents, {
					eventType = "BeyFinished",
					eventData = { playerId = pid, reason = "SpinOut" },
				})
			end
		else
			if bState.criticalSpinTimer > 0 then
				table.insert(matchState.tickEvents, {
					eventType = "Recovery",
					eventData = { playerId = pid, recoveredFromTimer = bState.criticalSpinTimer },
				})
			end
			bState.criticalSpinTimer = 0
		end

		if bState.zoneState ~= "Finished" then
			activeCount += 1
			lastActiveBey = pid
		end
	end

	local totalPlayers = #matchState.playerOrder

	if activeCount == 0 then
		matchState.finishFlags.matchEnded = true
		if totalPlayers == 1 then
			matchState.currentWinner = matchState.playerOrder[1]
		else
			matchState.currentWinner = "Draw"
		end
	elseif totalPlayers > 1 and activeCount == 1 then
		matchState.finishFlags.matchEnded = true
		matchState.currentWinner = lastActiveBey
	end
end

TickManager.RegisterHandler("Evaluation", SpinEvaluator.OnEvaluationPhase)

return SpinEvaluator
