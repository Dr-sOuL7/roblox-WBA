--[=[
	TelemetryLogger.lua
	Collects per-match metrics and prints structured match summaries.
	Tracks collisions, wall bounces, ability usage, HP/Mana economy, finishes
	and emotional tags.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local TelemetryLogger = {}

-- Per-match accumulators (reset on match start)
local telemetry = {
	collisionCounts  = { Light = 0, Heavy = 0, Smash = 0 },
	heavyTimestamps  = {},
	smashTimestamps  = {},
	recoveryEvents   = 0,
	wallBounces      = 0,
	hpBreaks         = 0,
	spinOuts         = 0,
	abilityTicks     = {}, -- { [pid] = { dash=0, revolve=0, samples=0 } }
	tiltAccumulators = {}, -- { [pid] = { sum=0, samples=0 } }
	matchStartTick   = 0,
	hasLoggedFinish  = false,
}

local function resetTelemetry()
	telemetry.collisionCounts = { Light = 0, Heavy = 0, Smash = 0 }
	telemetry.heavyTimestamps = {}
	telemetry.smashTimestamps = {}
	telemetry.recoveryEvents  = 0
	telemetry.wallBounces     = 0
	telemetry.hpBreaks        = 0
	telemetry.spinOuts        = 0
	telemetry.abilityTicks    = {}
	telemetry.tiltAccumulators = {}
	telemetry.matchStartTick  = 0
	telemetry.hasLoggedFinish = false
end

local function generateEmotionalTag(matchState)
	local tags = {}

	local lowHpCount = 0
	local totalBeys = #matchState.playerOrder
	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]
		if bState.hp < bState.maxHp * 0.25 then
			lowHpCount += 1
		end
	end
	if lowHpCount >= totalBeys and totalBeys > 1 then
		table.insert(tags, "CloseFinish")
	end

	if matchState.currentWinner and matchState.currentWinner ~= "Draw" then
		local winnerState = matchState.beyStates[matchState.currentWinner]
		if winnerState and winnerState.hp > winnerState.maxHp * 0.6 then
			table.insert(tags, "Dominant")
		end
	end

	local totalCollisions = telemetry.collisionCounts.Light + telemetry.collisionCounts.Heavy + telemetry.collisionCounts.Smash
	if totalCollisions > 20 then
		table.insert(tags, "Slugfest")
	end

	if telemetry.recoveryEvents > 0 then
		table.insert(tags, "Comeback")
	end

	if matchState.currentWinner == "Draw" then
		table.insert(tags, "Draw")
	end

	if #tags == 0 then
		table.insert(tags, "Standard")
	end

	return table.concat(tags, ", ")
end

function TelemetryLogger.OnReplicationPhase(matchState)
	if telemetry.matchStartTick == 0 and matchState.phase == "Active" then
		telemetry.matchStartTick = matchState.tickNumber
	end

	if matchState.phase == "Active" then
		-- Per-tick sampling: tilt + ability usage
		for _, pid in ipairs(matchState.playerOrder) do
			local bState = matchState.beyStates[pid]
			if not telemetry.tiltAccumulators[pid] then
				telemetry.tiltAccumulators[pid] = { sum = 0, samples = 0 }
			end
			telemetry.tiltAccumulators[pid].sum += bState.tilt
			telemetry.tiltAccumulators[pid].samples += 1

			if not telemetry.abilityTicks[pid] then
				telemetry.abilityTicks[pid] = { dash = 0, revolve = 0, samples = 0 }
			end
			local a = telemetry.abilityTicks[pid]
			a.samples += 1
			if bState.isDashing then a.dash += 1 end
			if bState.isRevolving then a.revolve += 1 end
		end

		for _, ev in ipairs(matchState.tickEvents) do
			if ev.eventType == "Collision" then
				local class = ev.eventData.collisionClass
				if telemetry.collisionCounts[class] then
					telemetry.collisionCounts[class] += 1
				end
				if class == "Heavy" then
					table.insert(telemetry.heavyTimestamps, matchState.serverTimestamp)
				elseif class == "Smash" then
					table.insert(telemetry.smashTimestamps, matchState.serverTimestamp)
				end
			elseif ev.eventType == "Recovery" then
				telemetry.recoveryEvents += 1
			elseif ev.eventType == "WallBounce" then
				telemetry.wallBounces += 1
			elseif ev.eventType == "BeyFinished" then
				if ev.eventData.reason == "HpBreak" then
					telemetry.hpBreaks += 1
				elseif ev.eventData.reason == "SpinOut" then
					telemetry.spinOuts += 1
				end
			end
		end
	end

	if matchState.phase == "Finished" and not telemetry.hasLoggedFinish then
		telemetry.hasLoggedFinish = true

		local tickDuration = 1 / Constants.SimulationTickRate
		local matchTicks = matchState.tickNumber - telemetry.matchStartTick
		local matchDuration = matchTicks * tickDuration

		local finishType = "Unknown"
		for _, ev in ipairs(matchState.tickEvents) do
			if ev.eventType == "BeyFinished" then
				finishType = ev.eventData.reason or "Unknown"
			end
		end
		if matchState.currentWinner == "Draw" then
			finishType = "Draw"
		end

		local tiltSummary = {}
		for _, pid in ipairs(matchState.playerOrder) do
			local acc = telemetry.tiltAccumulators[pid]
			if acc then
				local avg = (acc.samples > 0) and (acc.sum / acc.samples) or 0
				table.insert(tiltSummary, string.format("  Player %d: %.1f°", pid, avg))
			end
		end

		local emotionalTag = generateEmotionalTag(matchState)

		print("═══════════════════════════════════════════")
		print("        MATCH TELEMETRY SUMMARY")
		print("═══════════════════════════════════════════")
		print(string.format(" Match ID:     %s", matchState.matchId))
		print(string.format(" Winner:       %s", tostring(matchState.currentWinner)))
		print(string.format(" Finish Type:  %s", finishType))
		print(string.format(" Duration:     %.1fs (%d ticks)", matchDuration, matchTicks))
		print("───────────────────────────────────────────")
		print(string.format(" Collisions:   Light=%d  Heavy=%d  Smash=%d",
			telemetry.collisionCounts.Light,
			telemetry.collisionCounts.Heavy,
			telemetry.collisionCounts.Smash))
		print(string.format(" Wall Bounces: %d", telemetry.wallBounces))
		print("───────────────────────────────────────────")
		print(" Final HP / Mana:")
		for _, pid in ipairs(matchState.playerOrder) do
			local b = matchState.beyStates[pid]
			print(string.format("  Player %d:  HP=%.0f/%d  Mana=%.0f  [%s/%s/%s/%s]",
				pid, b.hp, b.maxHp, b.mana,
				b.loadout.blade, b.loadout.disc, b.loadout.core, b.loadout.tip))
		end
		print("───────────────────────────────────────────")
		print(" Avg Tilt:")
		for _, line in ipairs(tiltSummary) do
			print(line)
		end
		print(string.format(" Recoveries:   %d", telemetry.recoveryEvents))
		-- Ability usage (% of active ticks holding each ability)
		print(" Ability Usage:")
		for _, pid in ipairs(matchState.playerOrder) do
			local a = telemetry.abilityTicks[pid]
			if a and a.samples > 0 then
				print(string.format("  Player %d:  Dash=%.0f%%  Revolve=%.0f%%",
					pid, (a.dash / a.samples) * 100, (a.revolve / a.samples) * 100))
			end
		end
		print("───────────────────────────────────────────")
		print(string.format(" Finishes:     HpBreak=%d  SpinOut=%d", telemetry.hpBreaks, telemetry.spinOuts))
		print(string.format(" Emotional:    [%s]", emotionalTag))
		print("═══════════════════════════════════════════")

		resetTelemetry()
	end
end

TickManager.RegisterHandler("Replication", TelemetryLogger.OnReplicationPhase)

return TelemetryLogger
