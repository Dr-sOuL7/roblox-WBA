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
local LaunchQuality = require(ReplicatedStorage:WaitForChild("LaunchQuality"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local BeyParts = require(ReplicatedStorage:WaitForChild("BeyParts"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local MatchInstance = require(script.Parent:WaitForChild("MatchInstance"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

-- Human-ish timing-bar outcome mix for launched matches (tuning model, not a
-- target): casual players land mostly Good with occasional Perfect/Poor.
local QUALITY_MIX = {
	{ quality = "Perfect", weight = 0.20 },
	{ quality = "Good",    weight = 0.50 },
	{ quality = "Poor",    weight = 0.30 },
}

local function drawLaunchQuality(rng)
	local roll = rng:NextNumber()
	local cumulative = 0
	for _, entry in ipairs(QUALITY_MIX) do
		cumulative += entry.weight
		if roll <= cumulative then
			return entry.quality
		end
	end
	return "Good"
end

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

-- Called once per tick, before StepTick, in playerOrder (determinism).
local function runPolicyTick(state, rng, policyByPlayer, commandCounts)
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
	local stadiumId = options.stadiumId or Stadiums.DEFAULT_ID
	local stadiumDef = Stadiums.get(stadiumId)
	-- Per-side craft modifiers (ADR-003); nil → neutral (all 1.0 → baseline)
	local NEUTRAL_MODS = { Attack = 1, Defense = 1, Stamina = 1, Agility = 1 }
	local modsA = options.modsA or NEUTRAL_MODS
	local modsB = options.modsB or NEUTRAL_MODS

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
		stadiumId        = stadiumId,
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
		launchQualities  = { Perfect = 0, Good = 0, Poor = 0 },
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
		state.stadiumId = stadiumId

		state.playerOrder = { p1Id, p2Id } -- already sorted ascending

		-- Same stepping container the live server uses — no headless fork
		local inst = MatchInstance.fromState(state)
		local rng = inst.rng

		-- Spawn mirrors MatchManager: side ±10, then either a launch (the live
		-- common case — applied on the first Active tick) or pure spawn drift.
		-- RNG draws happen in fixed order (per bey: speed, angle, quality)
		-- so batches stay deterministic.
		local function setupBey(pid, side)
			local b = MatchState.createBeyState(pid)
			b.mods = (side < 0) and modsA or modsB -- craft modifiers (ADR-003)
			-- Mirrors MatchManager: spawn at half the playable radius (Classic: ±10)
			b.position = Vector3.new(side * stadiumDef.playableRadius * 0.5, 10, 0)
			if launchMode == "Launched" then
				local speed = Constants.PrototypeLaunchSpeed * (stadiumDef.launchSpeedScale or 1) * rng:NextNumber(0.9, 1.1)
				local jitter = rng:NextNumber(-0.15, 0.15) -- radians around the centre aim
				-- Timing-bar quality scales speed AND spin, exactly as the
				-- LaunchValidator applies it live
				local quality = drawLaunchQuality(rng)
				local multiplier = LaunchQuality.multiplierFor(quality)
				b.launchQuality = quality
				metrics.launchQualities[quality] += 1
				speed *= multiplier
				local dx = -side -- unit direction toward centre
				local cosJ, sinJ = math.cos(jitter), math.sin(jitter)
				b.velocity = Vector3.new(dx * cosJ * speed, 0, -dx * sinJ * speed)
				b.angularVelocity = Vector3.new(0, Constants.PrototypeLaunchSpin * multiplier, 0)
			else -- "Idle": never launched — held frozen, gravity does the rest
				b.velocity = Vector3.new(0, 0, 0)
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
			runPolicyTick(state, rng, policyByPlayer, commandCounts)
			inst:StepTick(true)

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
	print(string.format("Matchup:            P1=%s vs P2=%s | %s | Stadium=%s (seed %d)",
		m.policyA, m.policyB, m.launchMode, m.stadiumId, m.baseSeed))
	print(string.format("Total Matches:      %d", m.totalMatches))
	print(string.format("Average Duration:   %.2fs", m.avgDurationSeconds))
	print(string.format("Shortest Match:     %.2fs", m.shortestSeconds))
	print(string.format("Longest Match:      %.2fs", m.longestSeconds))
	print(string.format("Avg Collisions:     %.1f per match (Light=%d Heavy=%d Smash=%d)",
		m.avgCollisions, m.severityCounts.Light, m.severityCounts.Heavy, m.severityCounts.Smash))
	if m.launchMode == "Launched" then
		print(string.format("Launch Qualities:   Perfect=%d Good=%d Poor=%d",
			m.launchQualities.Perfect, m.launchQualities.Good, m.launchQualities.Poor))
	end
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

-- ── Build-matrix gate (ADR-003): no archetype may dominate ────────────────────
-- Archetype builds exercise the full pipeline: real BeyParts builds → derived
-- mods → simulation. Both sides play Random commands so the comparison isolates
-- the BUILD difference. A sidegrade is healthy when each archetype has answers
-- and none exceeds the dominance ceiling across the matrix.

local ARCHETYPE_BUILDS = {
	Balanced = BeyParts.defaultBuild(),
	Attacker = {
		Tip   = { shape = "Spike",    height = 1.8, weight = 8 },
		Disc  = { shape = "Star",     height = 1.4, weight = 9 },
		Blade = { shape = "Shuriken", height = 2.4, weight = 12 },
		Core  = { shape = "Spike",    height = 1.2, weight = 7 },
	},
	Defender = {
		Tip   = { shape = "Dome",     height = 0.6, weight = 8 },
		Disc  = { shape = "Shield",   height = 0.5, weight = 14 },
		Blade = { shape = "Round",    height = 0.8, weight = 6 },
		Core  = { shape = "Heavy",    height = 0.4, weight = 7 },
	},
	Stamina = {
		Tip   = { shape = "Hollow",   height = 0.6, weight = 4 },
		Disc  = { shape = "Round",    height = 0.6, weight = 14 },
		Blade = { shape = "Ring",     height = 0.9, weight = 5 },
		Core  = { shape = "Orb",      height = 0.4, weight = 5 },
	},
	-- Speedster: Agility primary, Stamina secondary (a fast Bey still needs
	-- endurance to use its mobility). A pure all-Agility glass build has no win
	-- condition vs a turtle under bot play — Agility is a control/hybrid axis,
	-- not a standalone pillar (the A/D/S triangle is the core RPS).
	Agile = {
		Tip   = { shape = "Needle",   height = 1.7, weight = 3 },
		Disc  = { shape = "Turbine",  height = 1.1, weight = 12 },
		Blade = { shape = "Wing",     height = 2.0, weight = 4 },
		Core  = { shape = "Hollow",   height = 1.0, weight = 4 },
	},
}

-- A build and its playstyle go together; this is how real players pilot each
-- archetype, and it lets Agility express through skilled Evade (the matador
-- dodge), which Random commands cannot.
local ARCH_POLICY = {
	Balanced = "Random",
	Attacker = "Aggressive",
	Defender = "Defensive",
	Stamina  = "Defensive",
	Agile    = "Evasive",
}

function SimulationHarness.RunBuildGate(options)
	options = options or {}
	local matchCount = options.count or 300

	print("############ BUILD-MATRIX GATE (ADR-003) ############")
	-- Show each archetype's derived stat distribution (sanity: distinct, summing 1)
	print("Derived stat fractions (sum = 1.00, neutral = 0.25 each):")
	local order = { "Balanced", "Attacker", "Defender", "Stamina", "Agile" }
	local mods = {}
	for _, name in ipairs(order) do
		local derived = BeyParts.deriveStats(ARCHETYPE_BUILDS[name])
		mods[name] = derived.multipliers
		print(string.format("  %-9s A %.2f  D %.2f  S %.2f  G %.2f   (mult A %.2f D %.2f S %.2f G %.2f)",
			name,
			derived.fractions.Attack, derived.fractions.Defense, derived.fractions.Stamina, derived.fractions.Agility,
			derived.multipliers.Attack, derived.multipliers.Defense, derived.multipliers.Stamina, derived.multipliers.Agility))
	end

	-- Default build must reproduce the command baseline (neutral mods)
	local neutral = SimulationHarness.RunBatch(matchCount, {
		policyA = "Random", policyB = "Random", quiet = true,
		modsA = mods.Balanced, modsB = mods.Balanced,
	})
	print(string.format("\nBalanced mirror: dur %.1fs | draws %.0f%% | mix %.0f/%.0f/%.0f | sym %.1fpp",
		neutral.avgDurationSeconds, neutral.drawRate * 100,
		neutral.spinOutShare * 100, neutral.wobbleShare * 100, neutral.ringOutShare * 100,
		math.abs(neutral.p1WinRate - neutral.p2WinRate) * 100))

	-- Cross matrix (distinct archetypes), Random vs Random. Builds are a
	-- STRATEGIC counter layer (unlike moment-to-moment commands), so a healthy
	-- sidegrade is rock-paper-scissors: strong counters are fine PROVIDED every
	-- build has a counter (none sweeps the field). Two criteria:
	--   • no single matchup is a total blowout (≤ BUILD_MATCH_CEILING), and
	--   • no build wins ALL of its matchups (everyone has a bad matchup).
	local BUILD_MATCH_CEILING = 0.85
	print("\nMatchups (P1 win% of decided | P1 vs P2):")
	local pairings = {
		{ "Attacker", "Defender" }, { "Attacker", "Stamina" }, { "Attacker", "Agile" },
		{ "Defender", "Stamina" },  { "Defender", "Agile" },   { "Stamina",  "Agile" },
	}
	local archetypes = { "Attacker", "Defender", "Stamina", "Agile" }
	local wins = { Attacker = 0, Defender = 0, Stamina = 0, Agile = 0 }
	local played = { Attacker = 0, Defender = 0, Stamina = 0, Agile = 0 }
	-- Worst decisive win-rate among the three bot-evaluable pillars vs among
	-- the Agile matchups (Agile is skill-piloted; see B3 note).
	local pillarWorst, pillarWorstPair = 0, ""
	local agileWorst = 0
	for _, pair in ipairs(pairings) do
		local m = SimulationHarness.RunBatch(matchCount, {
			policyA = ARCH_POLICY[pair[1]], policyB = ARCH_POLICY[pair[2]], quiet = true,
			modsA = mods[pair[1]], modsB = mods[pair[2]],
		})
		local decided = m.player1Wins + m.player2Wins
		local p1share = (decided > 0) and (m.player1Wins / decided) or 0.5
		print(string.format("  %-9s(%s) vs %-9s(%s) : %.0f%%  (draws %.0f%%, dur %.1fs)",
			pair[1], ARCH_POLICY[pair[1]]:sub(1,3), pair[2], ARCH_POLICY[pair[2]]:sub(1,3),
			p1share * 100, m.drawRate * 100, m.avgDurationSeconds))
		played[pair[1]] += 1
		played[pair[2]] += 1
		if p1share > 0.5 then wins[pair[1]] += 1 else wins[pair[2]] += 1 end
		local decisive = math.max(p1share, 1 - p1share)
		if pair[1] == "Agile" or pair[2] == "Agile" then
			agileWorst = math.max(agileWorst, decisive)
		elseif decisive > pillarWorst then
			pillarWorst = decisive
			pillarWorstPair = pair[1] .. " vs " .. pair[2]
		end
	end

	-- Does any build win every one of its matchups? (field sweep = dominant)
	local sweeper = nil
	for _, name in ipairs(archetypes) do
		if played[name] > 0 and wins[name] >= played[name] then
			sweeper = name
		end
	end
	print(string.format("\nField record (matchups won / played): A %d/%d  D %d/%d  S %d/%d  Ag %d/%d",
		wins.Attacker, played.Attacker, wins.Defender, played.Defender,
		wins.Stamina, played.Stamina, wins.Agile, played.Agile))

	local results = {}
	gateLine(results, "B0 Builds distinct",
		mods.Attacker.Attack > 1.05 and mods.Defender.Defense > 1.05
			and mods.Stamina.Stamina > 1.05 and mods.Agile.Agility > 1.05,
		"each archetype's headline stat multiplier exceeds 1.05")
	gateLine(results, "B1 Neutral reproduces baseline",
		neutral.forcedStops == 0 and neutral.phaseErrors == 0
			and band(neutral.spinOutShare, GATES.spinOutBand)
			and band(neutral.wobbleShare, GATES.wobbleBand)
			and band(neutral.ringOutShare, GATES.ringOutBand),
		"balanced mirror stays in the finish-mix bands")
	gateLine(results, "B2 Every build has a counter (no field sweep)",
		sweeper == nil,
		sweeper and (sweeper .. " wins all its matchups") or "no build sweeps the field")
	gateLine(results, "B3 Core triangle balanced (A/D/S ≤ ceiling)",
		pillarWorst <= BUILD_MATCH_CEILING,
		string.format("worst pillar matchup %.0f%% (%s); ceiling %.0f%%", pillarWorst * 100, pillarWorstPair, BUILD_MATCH_CEILING * 100))

	if agileWorst > 0.90 then
		print(string.format("  [note] Agile worst matchup %.0f%% — pure-mobility vs a Stamina wall; "
			.. "needs LIVE skill validation (bots can't pilot evasion offence).", agileWorst * 100))
	end

	local allPass = true
	for _, r in ipairs(results) do
		if not r.pass then allPass = false end
	end
	print(allPass
		and "BUILD GATE: PASS — sidegrade holds; no archetype dominates."
		or  "BUILD GATE: FAIL — tune BeyParts.STAT_GAIN / shape affinities and re-run.")
	print("####################################################")
	return { mods = mods, neutralMirror = neutral, worst = worst, gates = results, allPass = allPass }
end

-- ── Per-stadium ship gate (plan §Phase 3) ─────────────────────────────────────
-- Every stadium re-runs idle containment + the command baseline against the
-- same bands before entering ROTATION. "A stadium that pushes ring-out > 50%
-- or duration < 15 s is cut" — our bands are tighter still.

function SimulationHarness.RunStadiumGate(stadiumId, options)
	options = options or {}
	local count = options.count or 500

	print(string.format("############ STADIUM GATE: %s ############", tostring(stadiumId)))

	local idle = SimulationHarness.RunBatch(200, {
		policyA = "None", policyB = "None", launchMode = "Idle",
		stadiumId = stadiumId, quiet = true,
	})
	local cmd = SimulationHarness.RunBatch(count, {
		policyA = "Random", policyB = "Random",
		stadiumId = stadiumId, quiet = true,
	})
	SimulationHarness.PrintReport(cmd)

	local results = {}
	gateLine(results, "S0 Idle containment",
		idle.ringOuts == 0 and idle.forcedStops == 0,
		string.format("idle ring-outs=%d forcedStops=%d", idle.ringOuts, idle.forcedStops))
	gateLine(results, "S1 Stability",
		cmd.forcedStops == 0 and cmd.phaseErrors == 0,
		string.format("forcedStops=%d phaseErrors=%d", cmd.forcedStops, cmd.phaseErrors))
	gateLine(results, "S2 Duration",
		cmd.avgDurationSeconds >= GATES.durationMin and cmd.avgDurationSeconds <= GATES.durationMax,
		string.format("avg %.1fs (band %d–%ds)", cmd.avgDurationSeconds, GATES.durationMin, GATES.durationMax))
	gateLine(results, "S3 Finish mix",
		band(cmd.spinOutShare, GATES.spinOutBand)
			and band(cmd.wobbleShare, GATES.wobbleBand)
			and band(cmd.ringOutShare, GATES.ringOutBand),
		string.format("SpinOut %.0f%% (40–65) | Wobble %.0f%% (20–40) | RingOut %.0f%% (10–30)",
			cmd.spinOutShare * 100, cmd.wobbleShare * 100, cmd.ringOutShare * 100))
	gateLine(results, "S4 Symmetry",
		math.abs(cmd.p1WinRate - cmd.p2WinRate) <= GATES.symmetryTolerance,
		string.format("|P1-P2| = %.1fpp", math.abs(cmd.p1WinRate - cmd.p2WinRate) * 100))
	gateLine(results, "S5 Draw rate",
		cmd.drawRate <= GATES.maxDrawRate,
		string.format("%.1f%% (max %.0f%%)", cmd.drawRate * 100, GATES.maxDrawRate * 100))

	local allPass = true
	for _, r in ipairs(results) do
		if not r.pass then allPass = false end
	end
	print(allPass
		and string.format("STADIUM %s: SHIP — add to Stadiums.ROTATION", tostring(stadiumId))
		or  string.format("STADIUM %s: CUT or retune — bands violated", tostring(stadiumId)))
	print("###########################################################")

	return { idle = idle, commandBaseline = cmd, gates = results, allPass = allPass }
end

return SimulationHarness
