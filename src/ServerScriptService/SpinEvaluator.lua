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

	for pid, bState in pairs(matchState.beyStates) do
		if bState.zoneState == "Finished" then continue end

		-- Natural spin decay
		bState.angularVelocity *= Constants.AngularDecay
		local rpm = bState.angularVelocity.Magnitude

		local stabilityRatio = bState.stability / Constants.BaseStability
		if stabilityRatio < 0.3 then
			-- Non-linear wobble escalation (Death spiral)
			bState.tilt = bState.tilt + math.pow(1 - stabilityRatio, 2) * Constants.WobbleAmplification * dt
		else
			-- Slight tilt recovery damping during stable motion
			if bState.tilt > 0 then
				bState.tilt = math.max(0, bState.tilt - Constants.WobbleTiltRecoveryRate * dt)
			end
		end

		-- Check thresholds
		if rpm < Constants.MinEffectiveSpinThreshold or bState.tilt > Constants.WobbleCollapseThreshold then
			bState.criticalSpinTimer += dt
			if bState.criticalSpinTimer >= Constants.CriticalSpinWindow then
				bState.zoneState = "Finished"
				bState.angularVelocity = Vector3.new(0, 0, 0)
				bState.velocity = Vector3.new(0, 0, 0)

				local reason = (rpm < Constants.MinEffectiveSpinThreshold) and "SpinOut" or "WobbleCollapse"
				print(string.format("[SpinEvaluator] Bey %d finished: %s (RPM: %.1f, Tilt: %.1f)", pid, reason, rpm, bState.tilt))

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

	-- Explicit Draw handling when all Beys collapse simultaneously
	local totalPlayers = 0
	for _ in pairs(matchState.beyStates) do
		totalPlayers += 1
	end

	if totalPlayers > 1 then
		if activeCount == 1 then
			matchState.finishFlags.matchEnded = true
			matchState.currentWinner = lastActiveBey
		elseif activeCount == 0 then
			matchState.finishFlags.matchEnded = true
			matchState.currentWinner = "Draw"
		end
	end
end

TickManager.RegisterHandler("Evaluation", SpinEvaluator.OnEvaluationPhase)

return SpinEvaluator
