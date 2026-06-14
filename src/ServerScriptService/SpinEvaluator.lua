--[=[
	SpinEvaluator.lua
	Evaluates effective spin, detects finish conditions and wobble collapse.
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

		-- Natural spin decay, accelerated by accumulated damage: a destabilized
		-- Bey scrubs energy faster (StabilitySpinDrainMax at stability 0).
		-- Stamina (ADR-003) slows decay: dividing the exponent by Stamina raises
		-- AngularDecay (<1) toward 1 → less loss per tick. Neutral Stamina == 1
		-- → identical to baseline.
		local stabilityFraction = math.clamp(bState.stability / Constants.BaseStability, 0, 1)
		local drainExponent = (1 + Constants.StabilitySpinDrainMax * (1 - stabilityFraction)) / bState.mods.Stamina
		bState.angularVelocity *= Constants.AngularDecay ^ drainExponent
		local rpm = bState.angularVelocity.Magnitude

		local stabilityRatio = bState.stability / Constants.BaseStability
		if stabilityRatio < 0.3 then
			-- Non-linear wobble escalation (death spiral)
			bState.tilt = bState.tilt + math.pow(1 - stabilityRatio, 2) * Constants.WobbleAmplification * dt
		else
			-- Tilt recovery — Defend command boosts recovery rate
			if bState.tilt > 0 then
				local recoveryRate = Constants.WobbleTiltRecoveryRate
				if bState.currentCommand == "Defend" then
					recoveryRate = recoveryRate * (1 + Constants.CommandStabilityRecoveryBonus)
				end
				bState.tilt = math.max(0, bState.tilt - recoveryRate * dt)
			end
		end

		-- Check finish thresholds
		if rpm < Constants.MinEffectiveSpinThreshold or bState.tilt > Constants.WobbleCollapseThreshold then
			bState.criticalSpinTimer += dt
			if bState.criticalSpinTimer >= Constants.CriticalSpinWindow then
				bState.zoneState = "Finished"
				bState.angularVelocity = Vector3.new(0, 0, 0)
				bState.velocity = Vector3.new(0, 0, 0)

				local reason = (rpm < Constants.MinEffectiveSpinThreshold) and "SpinOut" or "WobbleCollapse"
				bState.finishReason = reason
				if not matchState.isHeadless then
					print(string.format("[SpinEvaluator] Bey %d finished: %s (RPM: %.1f, Tilt: %.1f)", pid, reason, rpm, bState.tilt))
				end

				table.insert(matchState.tickEvents, {
					eventType = "BeyFinished",
					eventData = { playerId = pid, reason = reason },
				})
			end
		else
			-- Recovery event: was in critical, now recovered
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
			-- Solo match: return the player's own id so the result UI doesn't show nil/"YOU LOSE"
			matchState.currentWinner = matchState.playerOrder[1]
		else
			matchState.currentWinner = "Draw"
		end
	elseif totalPlayers > 1 and activeCount == 1 then
		-- Last bey standing in a multiplayer match
		matchState.finishFlags.matchEnded = true
		matchState.currentWinner = lastActiveBey
	end
end

TickManager.RegisterHandler("Evaluation", SpinEvaluator.OnEvaluationPhase)

return SpinEvaluator
