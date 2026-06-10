--[=[
	TelemetryLogger.lua
	Collects per-match metrics and prints structured match summaries.
	Tracks collision counts, timestamps, stability, recovery events, and emotional tags.
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
	ringOutWarnings  = 0,
	ringOutEscapes   = 0,
	ringOutFinishes  = 0,
	commandCounts    = {}, -- { [pid] = { Attack=0, Defend=0, Evade=0 } }
	tiltAccumulators = {}, -- { [pid] = { sum=0, samples=0 } }
	matchStartTick   = 0,
	hasLoggedFinish  = false,
}

local function resetTelemetry()
	telemetry.collisionCounts = { Light = 0, Heavy = 0, Smash = 0 }
	telemetry.heavyTimestamps = {}
	telemetry.smashTimestamps = {}
	telemetry.recoveryEvents  = 0
	telemetry.ringOutWarnings = 0
	telemetry.ringOutEscapes  = 0
	telemetry.ringOutFinishes = 0
	telemetry.commandCounts   = {}
	telemetry.tiltAccumulators = {}
	telemetry.matchStartTick  = 0
	telemetry.hasLoggedFinish = false
end

local function generateEmotionalTag(matchState)
	local tags = {}

	-- Close Finish: both/all beys below 25% stability at end
	local lowStabilityCount = 0
	local totalBeys = #matchState.playerOrder
	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]
		if bState.stability < Constants.BaseStability * 0.25 then
			lowStabilityCount += 1
		end
	end
	if lowStabilityCount >= totalBeys and totalBeys > 1 then
		table.insert(tags, "CloseFinish")
	end

	-- Dominant: winner has >60% stability remaining
	if matchState.currentWinner and matchState.currentWinner ~= "Draw" then
		local winnerState = matchState.beyStates[matchState.currentWinner]
		if winnerState and winnerState.stability > Constants.BaseStability * 0.6 then
			table.insert(tags, "Dominant")
		end
	end

	-- Slugfest: high collision count
	local totalCollisions = telemetry.collisionCounts.Light + telemetry.collisionCounts.Heavy + telemetry.collisionCounts.Smash
	if totalCollisions > 20 then
		table.insert(tags, "Slugfest")
	end

	-- Comeback: at least one recovery event
	if telemetry.recoveryEvents > 0 then
		table.insert(tags, "Comeback")
	end

	-- Draw
	if matchState.currentWinner == "Draw" then
		table.insert(tags, "Draw")
	end

	if #tags == 0 then
		table.insert(tags, "Standard")
	end

	return table.concat(tags, ", ")
end

function TelemetryLogger.OnReplicationPhase(matchState)
	-- Track start tick
	if telemetry.matchStartTick == 0 and matchState.phase == "Active" then
		telemetry.matchStartTick = matchState.tickNumber
	end

	-- Accumulate per-tick data during active play
	if matchState.phase == "Active" then
		-- Tilt tracking
		for _, pid in ipairs(matchState.playerOrder) do
			local bState = matchState.beyStates[pid]
			if not telemetry.tiltAccumulators[pid] then
				telemetry.tiltAccumulators[pid] = { sum = 0, samples = 0 }
			end
			telemetry.tiltAccumulators[pid].sum += bState.tilt
			telemetry.tiltAccumulators[pid].samples += 1
		end

		-- Event tracking
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
			elseif ev.eventType == "CommandIssued" then
				local pid = ev.eventData.playerId
				local cmd = ev.eventData.command
				if not telemetry.commandCounts[pid] then
					telemetry.commandCounts[pid] = { Attack = 0, Defend = 0, Evade = 0 }
				end
				if telemetry.commandCounts[pid][cmd] then
					telemetry.commandCounts[pid][cmd] += 1
				end
			elseif ev.eventType == "RingOutWarning" then
				telemetry.ringOutWarnings += 1
			elseif ev.eventType == "RingOutEscaped" then
				telemetry.ringOutEscapes += 1
			elseif ev.eventType == "BeyFinished" then
				if ev.eventData.reason == "RingOut" then
					telemetry.ringOutFinishes += 1
				end
			end
		end
	end

	-- Print structured summary at match end
	if matchState.phase == "Finished" and not telemetry.hasLoggedFinish then
		telemetry.hasLoggedFinish = true

		local tickDuration = 1 / Constants.SimulationTickRate
		local matchTicks = matchState.tickNumber - telemetry.matchStartTick
		local matchDuration = matchTicks * tickDuration

		-- Determine finish type
		local finishType = "Unknown"
		for _, ev in ipairs(matchState.tickEvents) do
			if ev.eventType == "BeyFinished" then
				finishType = ev.eventData.reason or "Unknown"
			end
		end
		if matchState.currentWinner == "Draw" then
			finishType = "Draw"
		end

		-- Average tilts (in playerOrder for deterministic print order)
		local tiltSummary = {}
		for _, pid in ipairs(matchState.playerOrder) do
			local acc = telemetry.tiltAccumulators[pid]
			if acc then
				local avg = (acc.samples > 0) and (acc.sum / acc.samples) or 0
				table.insert(tiltSummary, string.format("  Player %d: %.1f°", pid, avg))
			end
		end

		-- Emotional tag
		local emotionalTag = generateEmotionalTag(matchState)

		-- Print structured report
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
		if #telemetry.heavyTimestamps > 0 then
			local ts = {}
			for _, t in ipairs(telemetry.heavyTimestamps) do table.insert(ts, string.format("%.1f", t)) end
			print(" Heavy @:      " .. table.concat(ts, ", "))
		end
		if #telemetry.smashTimestamps > 0 then
			local ts = {}
			for _, t in ipairs(telemetry.smashTimestamps) do table.insert(ts, string.format("%.1f", t)) end
			print(" Smash @:      " .. table.concat(ts, ", "))
		end
		print("───────────────────────────────────────────")
		print(" Avg Tilt:")
		for _, line in ipairs(tiltSummary) do
			print(line)
		end
		print(string.format(" Recoveries:   %d", telemetry.recoveryEvents))
		print("───────────────────────────────────────────")
		print(string.format(" Ring-Outs:    Warnings=%d  Escapes=%d  Finishes=%d",
			telemetry.ringOutWarnings,
			telemetry.ringOutEscapes,
			telemetry.ringOutFinishes))
		-- Command distribution
		if next(telemetry.commandCounts) then
			print(" Commands:")
			for _, pid in ipairs(matchState.playerOrder) do
				local cc = telemetry.commandCounts[pid]
				if cc then
					print(string.format("  Player %d:  Attack=%d  Defend=%d  Evade=%d",
						pid, cc.Attack, cc.Defend, cc.Evade))
				end
			end
		end
		print("───────────────────────────────────────────")
		print(string.format(" Emotional:    [%s]", emotionalTag))
		print("═══════════════════════════════════════════")

		-- Reset for next match
		resetTelemetry()
	end
end

TickManager.RegisterHandler("Replication", TelemetryLogger.OnReplicationPhase)

return TelemetryLogger
