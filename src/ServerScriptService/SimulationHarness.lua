--[=[
	SimulationHarness.lua
	Runs headless deterministic matches to validate physics and gather aggregate metrics.
	Only runs when explicitly invoked — never on live server startup.

	Studio command bar:
	  _G.RunSimulation(1000)        -- baseline batch (no commands)
	  _G.RunValidationSuite()       -- full Phase 1 harness gate: baseline,
	                                   command batches, policy matrix, GO/NO-GO report

	Command policy bots:
	  Bots inject commands into matchState.commandQueue — the same post-validation
	  queue human input flows through — so the simulation path is identical to live.
	  All bot decisions draw from the per-match seeded RNG: a batch with the same
	  baseSeed reproduces exactly.

	Gate bands come from the approved production plan (GDD §7 finish distribution;
	Phase 1 completion criteria). Policy weights and the dominance threshold are
	provisional tuning dials — adjust from data, not by guessing.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MatchState = require(ReplicatedStorage:WaitForChild("MatchState"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local SimulationHarness = {}

-- ── Command policies ──────────────────────────────────────────────────────────
-- issueChance: per-tick probability of issuing while the Bey can act.
-- At 0.25 the expected reaction delay is ~4 ticks (~0.13 s) — near-max uptime.

local POLICIES = {
	None       = nil,
	Random     = { issueChance = 0.15, weights = { Attack = 1.0,  Defend = 1.0,  Evade = 1.0 } },
	Aggressive = { issueChance = 0.25, weights = { Attack = 0.70, Defend = 0.15, Evade = 0.15 } },
	Defensive  = { issueChance = 0.25, weights = { Attack = 0.15, Defend = 0.70, Evade = 0.15 } },
	Evasive    = { issueChance = 0.25, weights = { Attack = 0.15, Defend = 0.15, Evade = 0.70 } },
}

local COMMAND_NAMES = { "Attack", "Defend", "Evade" } -- fixed order for deterministic weighted picks

local function pickWeightedCommand(rng, weights)
	local total = 0
	for _, name in ipairs(COMMAND_NAMES) do
		total += weights[name]
	end
	local roll = rng:NextNumber(0, total)
	local cumulative = 0
	for _, name in ipairs(COMMAND_NAMES) do
		cumulative += weights[name]
		if roll <= cumulative then
			return name
		end
	end
	return COMMAND_NAMES[#COMMAND_NAMES]
end

-- Called once per tick, before TickManager.Step, in playerOrder (determinism).
local function runPolicyTick(state, policyByPlayer, commandCounts)
	local rng = TickManager.GetRandom()
	for _, pid in ipairs(state.playerOrder) do
		local policy = policyByPlayer[pid]
		if not policy then continue end

		local bState = state.beyStates[pid]
		if bState.zoneState == "Finished" then continue end
		if bState.commandTimer > 0 or bState.commandCooldownTimer > 0 then continue end

		if rng:NextNumber() < policy.issueChance then
			local command = pickWeightedCommand(rng, policy.weights)
			table.insert(state.commandQueue, { playerId = pid, command = command })
			commandCounts[pid][command] += 1
		end
	end
end

-- ── Batch runner ──────────────────────────────────────────────────────────────

local DEFAULT_BASE_SEED = 1337
local FORCED_STOP_TICKS = 10000

--[=[
	RunBatch(numMatches, options) -> metrics
	options:
	  policyA / policyB : "None" | "Random" | "Aggressive" | "Defensive" | "Evasive"
	  launchMode        : "Launched" (default) — both players launch at the bowl
	                      centre with jittered speed/angle, modelling live play.
	                      "Idle" — nobody launches; Beys keep only the gentle
	                      spawn drift (sanity: idle players must not self-ring-out).
	  baseSeed          : number (default 1337) — fixed for reproducible batches
	  quiet             : suppress the printed report (used by RunValidationSuite)
]=]
function SimulationHarness.RunBatch(numMatches: number, options)
	numMatches = numMatches or 100
	options = options or {}
	local policyNameA = options.policyA or "None"
	local policyNameB = options.policyB or "None"
	local launchMode = options.launchMode or "Launched"
	local baseSeed = options.baseSeed or DEFAULT_BASE_SEED

	assert(POLICIES[policyNameA] ~= nil or policyNameA == "None", "Unknown policy: " .. tostring(policyNameA))
	assert(POLICIES[policyNameB] ~= nil or policyNameB == "None", "Unknown policy: " .. tostring(policyNameB))

	if not options.quiet then
		print(string.format("--- SIMULATION HARNESS: %d matches | P1=%s vs P2=%s | %s | baseSeed=%d ---",
			numMatches, policyNameA, policyNameB, launchMode, baseSeed))
	end

	local metrics = {
		totalMatches     = numMatches,
		policyA          = policyNameA,
		policyB          = policyNameB,
		launchMode       = launchMode,
		baseSeed         = baseSeed,
		draws            = 0,
		player1Wins      = 0,
		player2Wins      = 0,
		spinOuts         = 0,
		wobbleCollapses  = 0,
		ringOuts         = 0,
		totalDurationTicks = 0,
		shortestDuration = math.huge,
		longestDuration  = 0,
		totalCollisions  = 0,
		forcedStops      = 0,
		phaseErrors      = 0,
		commandTicks     = 0,  -- ticks where at least one Bey had an active command
		activeTicks      = 0,  -- total simulated ticks (uptime denominator)
		commandTotals    = { Attack = 0, Defend = 0, Evade = 0 },
		severityCounts   = { Light = 0, Heavy = 0, Smash = 0 },
	}

	local p1Id = 101
	local p2Id = 102

	TickManager.GetAndResetPhaseErrorCount() -- discard errors from before this batch

	for i = 1, numMatches do
		if i % 25 == 0 then
			task.wait() -- prevent Roblox Studio timeout
		end

		-- Deterministic seed series: same baseSeed → identical batch
		local matchSeed = (baseSeed + i * 7919) % (2^31 - 1)

		local state = MatchState.new(matchSeed)
		state.matchId = "SimMatch_" .. tostring(i)
		state.phase = "Active"
		state.isHeadless = true -- suppresses per-finish console prints in hot paths

		-- Build playerOrder before SetMatchState so RNG is seeded first
		state.playerOrder = { p1Id, p2Id } -- already sorted ascending

		TickManager.SetMatchState(state)
		local rng = TickManager.GetRandom()

		-- Spawn mirrors MatchManager: side ±10, then either a launch (the live
		-- common case — applied on the first Active tick) or pure spawn drift.
		-- RNG draws happen in fixed order (b1 speed, b1 angle, b2 speed, b2 angle)
		-- so batches stay deterministic.
		local function setupBey(pid, side)
			local b = MatchState.createBeyState(pid)
			b.position = Vector3.new(side * 10, 10, 0)
			if launchMode == "Launched" then
				local speed = Constants.PrototypeLaunchSpeed * rng:NextNumber(0.9, 1.1)
				local jitter = rng:NextNumber(-0.15, 0.15) -- radians around the centre aim
				local dx = -side -- unit direction toward centre
				local cosJ, sinJ = math.cos(jitter), math.sin(jitter)
				b.velocity = Vector3.new(dx * cosJ * speed, 0, -dx * sinJ * speed)
				b.angularVelocity = Vector3.new(0, Constants.PrototypeLaunchSpin, 0)
			else -- "Idle": never launched, spawn drift only
				b.velocity = Vector3.new(
					-side * Constants.SpawnInwardSpeed,
					0,
					-side * Constants.SpawnTangentialSpeed
				)
			end
			b.previousPosition = b.position
			state.beyStates[pid] = b
			return b
		end

		local b1 = setupBey(p1Id, -1)
		local b2 = setupBey(p2Id, 1)

		local policyByPlayer = {
			[p1Id] = POLICIES[policyNameA],
			[p2Id] = POLICIES[policyNameB],
		}
		local commandCounts = {
			[p1Id] = { Attack = 0, Defend = 0, Evade = 0 },
			[p2Id] = { Attack = 0, Defend = 0, Evade = 0 },
		}

		local matchCollisions = 0

		while state.phase ~= "Finished" do
			runPolicyTick(state, policyByPlayer, commandCounts)
			TickManager.Step(true)

			metrics.activeTicks += 1
			if b1.commandTimer > 0 or b2.commandTimer > 0 then
				metrics.commandTicks += 1
			end

			for _, ev in ipairs(state.tickEvents) do
				if ev.eventType == "Collision" then
					matchCollisions += 1
					local class = ev.eventData.collisionClass
					if metrics.severityCounts[class] then
						metrics.severityCounts[class] += 1
					end
				end
			end

			if state.tickNumber > FORCED_STOP_TICKS then
				metrics.forcedStops += 1
				print("[Harness] Forced stop: exceeded " .. FORCED_STOP_TICKS .. " ticks at match " .. i)
				break
			end
		end

		-- Record duration
		metrics.totalDurationTicks += state.tickNumber
		metrics.totalCollisions += matchCollisions
		if state.tickNumber < metrics.shortestDuration then
			metrics.shortestDuration = state.tickNumber
		end
		if state.tickNumber > metrics.longestDuration then
			metrics.longestDuration = state.tickNumber
		end

		for pid, counts in pairs(commandCounts) do
			local _ = pid
			for cmd, n in pairs(counts) do
				metrics.commandTotals[cmd] += n
			end
		end

		-- Winner
		if state.currentWinner == "Draw" then
			metrics.draws += 1
			local key = table.concat({ b1.finishReason or "?", b2.finishReason or "?" }, "+")
			metrics.drawTypes = metrics.drawTypes or {}
			metrics.drawTypes[key] = (metrics.drawTypes[key] or 0) + 1
		elseif state.currentWinner == p1Id then
			metrics.player1Wins += 1
		elseif state.currentWinner == p2Id then
			metrics.player2Wins += 1
		end

		-- Finish reason — read from finishReason field set by SpinEvaluator/PhysicsController.
		-- (angularVelocity is zeroed on finish so checking its magnitude is unreliable.)
		local loserState = nil
		if state.currentWinner == p1Id then
			loserState = b2
		elseif state.currentWinner == p2Id then
			loserState = b1
		end

		if loserState then
			local reason = loserState.finishReason or "SpinOut"
			if reason == "SpinOut" then
				metrics.spinOuts += 1
			elseif reason == "WobbleCollapse" then
				metrics.wobbleCollapses += 1
			elseif reason == "RingOut" then
				metrics.ringOuts += 1
			end
		end
	end

	metrics.phaseErrors = TickManager.GetAndResetPhaseErrorCount()

	-- Derived values
	metrics.avgDurationSeconds = (metrics.totalDurationTicks / metrics.totalMatches) / Constants.SimulationTickRate
	metrics.shortestSeconds = metrics.shortestDuration / Constants.SimulationTickRate
	metrics.longestSeconds = metrics.longestDuration / Constants.SimulationTickRate
	metrics.avgCollisions = metrics.totalCollisions / metrics.totalMatches
	metrics.drawRate = metrics.draws / metrics.totalMatches
	metrics.p1WinRate = metrics.player1Wins / metrics.totalMatches
	metrics.p2WinRate = metrics.player2Wins / metrics.totalMatches
	metrics.commandUptime = (metrics.activeTicks > 0) and (metrics.commandTicks / metrics.activeTicks) or 0

	local decided = metrics.spinOuts + metrics.wobbleCollapses + metrics.ringOuts
	metrics.decidedMatches = decided
	metrics.spinOutShare = (decided > 0) and (metrics.spinOuts / decided) or 0
	metrics.wobbleShare = (decided > 0) and (metrics.wobbleCollapses / decided) or 0
	metrics.ringOutShare = (decided > 0) and (metrics.ringOuts / decided) or 0

	if not options.quiet then
		SimulationHarness.PrintReport(metrics)
	end

	return metrics
end

function SimulationHarness.PrintReport(m)
	print("==================================================")
	print("           SIMULATION HARNESS REPORT              ")
	print("==================================================")
	print(string.format("Matchup:            P1=%s vs P2=%s | %s (seed %d)", m.policyA, m.policyB, m.launchMode, m.baseSeed))
	print(string.format("Total Matches:      %d", m.totalMatches))
	print(string.format("Average Duration:   %.2fs", m.avgDurationSeconds))
	print(string.format("Shortest Match:     %.2fs", m.shortestSeconds))
	print(string.format("Longest Match:      %.2fs", m.longestSeconds))
	print(string.format("Avg Collisions:     %.1f per match (Light=%d Heavy=%d Smash=%d)",
		m.avgCollisions, m.severityCounts.Light, m.severityCounts.Heavy, m.severityCounts.Smash))
	print(string.format("Forced Stops:       %d | Phase Errors: %d", m.forcedStops, m.phaseErrors))
	print("--------------------------------------------------")
	print(string.format("Draw Rate:          %.1f%%", m.drawRate * 100))
	if m.drawTypes then
		for key, n in pairs(m.drawTypes) do
			print(string.format("  Draw type:        %s ×%d", key, n))
		end
	end
	print(string.format("Player 1 Win Rate:  %.1f%%", m.p1WinRate * 100))
	print(string.format("Player 2 Win Rate:  %.1f%%", m.p2WinRate * 100))
	print("--------------------------------------------------")
	print(string.format("Finish Types (%d decided):", m.decidedMatches))
	print(string.format("  SpinOut:          %d  (%.1f%%)", m.spinOuts, m.spinOutShare * 100))
	print(string.format("  WobbleCollapse:   %d  (%.1f%%)", m.wobbleCollapses, m.wobbleShare * 100))
	print(string.format("  RingOut:          %d  (%.1f%%)", m.ringOuts, m.ringOutShare * 100))
	if m.policyA ~= "None" or m.policyB ~= "None" then
		print("--------------------------------------------------")
		print(string.format("Command Uptime:     %.1f%% of active ticks", m.commandUptime * 100))
		print(string.format("Commands Issued:    Attack=%d  Defend=%d  Evade=%d",
			m.commandTotals.Attack, m.commandTotals.Defend, m.commandTotals.Evade))
	end
	print("==================================================")
end

-- ── Phase 1 validation suite ──────────────────────────────────────────────────
-- Gate bands (sources: GDD §7 finish-type targets; Phase 1 completion criteria).
-- Symmetry/draw/collision bands are engineering-set and documented in
-- VALIDATION_RUNBOOK.md — provisional until live data says otherwise.

local GATES = {
	durationMin       = 15,   -- s, average
	durationMax       = 55,   -- s, average
	spinOutBand       = { 0.40, 0.65 },
	wobbleBand        = { 0.20, 0.40 },
	ringOutBand       = { 0.10, 0.30 },
	symmetryTolerance = 0.10, -- |P1 - P2| win rate in mirror matchups
	maxDrawRate       = 0.10,
	minAvgCollisions  = 2,
	dominanceCeiling  = 0.65, -- no policy above this vs another in the matrix
}

local function band(value, range)
	return value >= range[1] and value <= range[2]
end

local function gateLine(results, name, pass, detail)
	table.insert(results, { name = name, pass = pass, detail = detail })
	print(string.format("  [%s] %s — %s", pass and "PASS" or "FAIL", name, detail))
end

function SimulationHarness.RunValidationSuite(options)
	options = options or {}
	local baselineCount = options.baselineCount or 1000
	local matrixCount = options.matrixCount or 200

	print("############################################################")
	print("#        PHASE 1 HARNESS VALIDATION SUITE                  #")
	print("############################################################")

	-- 1. Idle sanity: nobody launches — idle Beys must never self-ring-out
	local idleCount = math.min(200, baselineCount)
	print(string.format("\n[1/4] Idle sanity — %d matches, no launches, no commands...", idleCount))
	local idle = SimulationHarness.RunBatch(idleCount, { policyA = "None", policyB = "None", launchMode = "Idle", quiet = true })
	SimulationHarness.PrintReport(idle)

	-- 2. Physics-only baseline (launched, no commands): pure sim stability + finish mix
	print(string.format("\n[2/4] Physics baseline — %d matches, launched, no commands...", baselineCount))
	local baseline = SimulationHarness.RunBatch(baselineCount, { policyA = "None", policyB = "None", quiet = true })
	SimulationHarness.PrintReport(baseline)

	-- 3. Command baseline (both Random): represents real played matches
	print(string.format("\n[3/4] Command baseline — %d matches, Random vs Random...", baselineCount))
	local cmdBaseline = SimulationHarness.RunBatch(baselineCount, { policyA = "Random", policyB = "Random", quiet = true })
	SimulationHarness.PrintReport(cmdBaseline)

	-- 4. Policy matrix: command-balance triangle + mirrors
	print(string.format("\n[4/4] Policy matrix — %d matches per pairing...", matrixCount))
	local pairings = {
		{ "Aggressive", "Defensive" },
		{ "Aggressive", "Evasive" },
		{ "Defensive",  "Evasive" },
		{ "Aggressive", "Aggressive" },
		{ "Defensive",  "Defensive" },
		{ "Evasive",    "Evasive" },
	}
	local matrix = {}
	for _, pair in ipairs(pairings) do
		local m = SimulationHarness.RunBatch(matrixCount, { policyA = pair[1], policyB = pair[2], quiet = true })
		table.insert(matrix, m)
		print(string.format("  %-10s vs %-10s : P1 %.1f%% | P2 %.1f%% | Draw %.1f%% | avg %.1fs",
			pair[1], pair[2], m.p1WinRate * 100, m.p2WinRate * 100, m.drawRate * 100, m.avgDurationSeconds))
	end

	-- ── Gate evaluation ───────────────────────────────────────────────────────
	print("\n──────────────── GATE RESULTS ────────────────")
	local results = {}

	gateLine(results, "G0 Idle containment",
		idle.ringOuts == 0 and idle.forcedStops == 0,
		string.format("idle ring-outs=%d forcedStops=%d (draw rate %.0f%% is expected for two idle Beys)",
			idle.ringOuts, idle.forcedStops, idle.drawRate * 100))

	gateLine(results, "G1 Stability (baseline)",
		baseline.forcedStops == 0 and baseline.phaseErrors == 0
			and cmdBaseline.forcedStops == 0 and cmdBaseline.phaseErrors == 0,
		string.format("forcedStops=%d/%d phaseErrors=%d/%d",
			baseline.forcedStops, cmdBaseline.forcedStops, baseline.phaseErrors, cmdBaseline.phaseErrors))

	gateLine(results, "G2 Duration (command baseline)",
		cmdBaseline.avgDurationSeconds >= GATES.durationMin and cmdBaseline.avgDurationSeconds <= GATES.durationMax,
		string.format("avg %.1fs (band %d–%ds)", cmdBaseline.avgDurationSeconds, GATES.durationMin, GATES.durationMax))

	gateLine(results, "G3 Finish mix (command baseline)",
		band(cmdBaseline.spinOutShare, GATES.spinOutBand)
			and band(cmdBaseline.wobbleShare, GATES.wobbleBand)
			and band(cmdBaseline.ringOutShare, GATES.ringOutBand),
		string.format("SpinOut %.0f%% (40–65) | Wobble %.0f%% (20–40) | RingOut %.0f%% (10–30)",
			cmdBaseline.spinOutShare * 100, cmdBaseline.wobbleShare * 100, cmdBaseline.ringOutShare * 100))

	local symmetryDelta = math.abs(cmdBaseline.p1WinRate - cmdBaseline.p2WinRate)
	gateLine(results, "G4 Symmetry (mirror Random)",
		symmetryDelta <= GATES.symmetryTolerance,
		string.format("|P1-P2| = %.1fpp (tolerance %.0fpp)", symmetryDelta * 100, GATES.symmetryTolerance * 100))

	gateLine(results, "G5 Draw rate",
		cmdBaseline.drawRate <= GATES.maxDrawRate,
		string.format("%.1f%% (max %.0f%%)", cmdBaseline.drawRate * 100, GATES.maxDrawRate * 100))

	gateLine(results, "G6 Collisions",
		cmdBaseline.avgCollisions >= GATES.minAvgCollisions,
		string.format("avg %.1f per match (min %d)", cmdBaseline.avgCollisions, GATES.minAvgCollisions))

	local dominancePass = true
	local dominanceDetail = "no policy exceeds 65% in the triangle"
	for _, m in ipairs(matrix) do
		if m.policyA ~= m.policyB then
			local decisive = math.max(m.p1WinRate, m.p2WinRate)
			if decisive > GATES.dominanceCeiling then
				dominancePass = false
				dominanceDetail = string.format("%s vs %s reached %.1f%%", m.policyA, m.policyB, decisive * 100)
				break
			end
		end
	end
	gateLine(results, "G7 Command dominance", dominancePass, dominanceDetail)

	local allPass = true
	for _, r in ipairs(results) do
		if not r.pass then allPass = false end
	end

	print("───────────────────────────────────────────────")
	print(allPass
		and "HARNESS GATES: GO — automated gates pass. Human gates (legibility, networking, fun consensus) still required."
		or  "HARNESS GATES: NO-GO — tune the flagged dials and re-run. Do not proceed to live validation.")
	print("###########################################################")

	return { idle = idle, baseline = baseline, commandBaseline = cmdBaseline, matrix = matrix, gates = results, allPass = allPass }
end

return SimulationHarness
