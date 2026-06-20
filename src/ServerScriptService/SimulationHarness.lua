--[=[
	SimulationHarness.lua
	Headless deterministic match runner + balance gates for the flat-arena battle.
	Only runs when explicitly invoked — never on live server startup.

	Studio command bar:
	  _G.RunSimulation(200)              -- baseline batch (Balanced mirror)
	  _G.RunValidationSuite()            -- full gate report (GO / NO-GO)
	  _G.RunStadiumGate("Compact")       -- per-stadium band check

	It drives the REAL code: each match is a MatchInstance stepped headless, with
	BotController writing the same analog input buffer a human fills. Bots draw
	from the per-match seeded RNG, so a batch with the same baseSeed reproduces.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MatchState = require(ReplicatedStorage:WaitForChild("MatchState"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local BeyParts = require(ReplicatedStorage:WaitForChild("BeyParts"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local MatchInstance = require(script.Parent:WaitForChild("MatchInstance"))
local BeyController = require(script.Parent:WaitForChild("BeyController"))

local SimulationHarness = {}

local DEFAULT_BASE_SEED = 1337
local FORCED_STOP_TICKS = 12000 -- ~6.7 min at 30 Hz; a match this long is "Timeout"

-- ── Single headless match ─────────────────────────────────────────────────────
--[=[
	runMatch(seed, cfg) -> result
	cfg:
	  personA / personB : bot personality ("Balanced" | "Aggressive" | "Defensive")
	  buildA / buildB    : crafted build (defaults to neutral)
	  stadiumId          : registry key (default "Classic")
	result = { winner, loserReason, durationSec, collisions, walls,
	           manaAvg, p1Wins, p2Wins, draw, timedOut }
]=]
local function runMatch(seed, cfg)
	cfg = cfg or {}
	local stadiumId = cfg.stadiumId or Stadiums.DEFAULT_ID
	local sd = Stadiums.get(stadiumId)

	local state = MatchState.new(seed)
	state.matchId = "Sim_" .. tostring(seed)
	state.isHeadless = true
	state.stadiumId = stadiumId
	state.stadiumRadius = sd.radius
	state.stadiumWallBounce = sd.wallBounce
	state.playerOrder = { 1, 2 }
	state.bots = { [1] = cfg.personA or "Balanced", [2] = cfg.personB or "Balanced" }

	local spawnRadius = sd.radius * 0.45
	local builds = { [1] = cfg.buildA or BeyParts.defaultBuild(), [2] = cfg.buildB or BeyParts.defaultBuild() }
	for i, pid in ipairs(state.playerOrder) do
		local b = MatchState.createBeyState(pid, builds[pid])
		local side = (i == 1) and -1 or 1
		b.position = Vector3.new(side * spawnRadius, Constants.BeyRadius, 0)
		b.previousPosition = b.position
		state.beyStates[pid] = b
	end

	-- Headless launch: the ceremony is skipped, so fire each Bey toward the centre
	-- with spin (the same applyLaunch path live launches use).
	for i, pid in ipairs(state.playerOrder) do
		local side = (i == 1) and -1 or 1
		BeyController.applyLaunch(state, pid, {
			launchVector = Vector3.new(-side, 0, 0) * Constants.LaunchImpulseSpeed,
			spinPower = Constants.LaunchBaseSpin,
			quality = "Good",
		}, false)
	end

	local instance = MatchInstance.fromState(state, 0, Vector3.new(0, 0, 0))

	local collisions, walls = 0, 0
	local manaSum, manaSamples = 0, 0
	while state.phase ~= "Finished" and state.tickNumber < FORCED_STOP_TICKS do
		instance:StepTick(true)
		for _, ev in ipairs(state.tickEvents) do
			if ev.eventType == "Collision" then
				collisions += 1
			elseif ev.eventType == "WallBounce" then
				walls += 1
			end
		end
		for _, pid in ipairs(state.playerOrder) do
			manaSum += state.beyStates[pid].mana
			manaSamples += 1
		end
	end

	local timedOut = state.phase ~= "Finished"
	local winner = state.currentWinner
	local loserReason = nil
	if not timedOut and winner ~= "Draw" then
		for _, pid in ipairs(state.playerOrder) do
			if pid ~= winner then
				loserReason = state.beyStates[pid].finishReason
			end
		end
	end

	return {
		winner = winner,
		loserReason = loserReason,
		timedOut = timedOut,
		durationSec = state.tickNumber / Constants.SimulationTickRate,
		collisions = collisions,
		walls = walls,
		manaAvg = (manaSamples > 0) and (manaSum / manaSamples) or 0,
		p1Wins = (winner == 1),
		p2Wins = (winner == 2),
		draw = (winner == "Draw"),
	}
end

SimulationHarness.RunMatch = runMatch

-- ── Batch runner ──────────────────────────────────────────────────────────────
function SimulationHarness.RunBatch(numMatches, options)
	numMatches = numMatches or 100
	options = options or {}
	local baseSeed = options.baseSeed or DEFAULT_BASE_SEED

	local agg = {
		matches = numMatches,
		hpBreak = 0, spinOut = 0, timeout = 0, draws = 0,
		durationSum = 0, collisionSum = 0, wallSum = 0, manaSum = 0,
		p1 = 0, p2 = 0,
	}

	for i = 1, numMatches do
		local r = runMatch(baseSeed + i, {
			personA = options.personA, personB = options.personB,
			buildA = options.buildA, buildB = options.buildB,
			stadiumId = options.stadiumId,
		})
		if r.timedOut then
			agg.timeout += 1
		elseif r.draw then
			agg.draws += 1
		elseif r.loserReason == "HpBreak" then
			agg.hpBreak += 1
		elseif r.loserReason == "SpinOut" then
			agg.spinOut += 1
		end
		if r.p1Wins then agg.p1 += 1 end
		if r.p2Wins then agg.p2 += 1 end
		agg.durationSum += r.durationSec
		agg.collisionSum += r.collisions
		agg.wallSum += r.walls
		agg.manaSum += r.manaAvg
	end

	agg.avgDuration = agg.durationSum / numMatches
	agg.avgCollisions = agg.collisionSum / numMatches
	agg.avgWalls = agg.wallSum / numMatches
	agg.avgMana = agg.manaSum / numMatches
	local decisive = agg.hpBreak + agg.spinOut
	agg.hpBreakPct = decisive > 0 and (agg.hpBreak / decisive * 100) or 0
	agg.spinOutPct = decisive > 0 and (agg.spinOut / decisive * 100) or 0

	if not options.quiet then
		print(string.format(
			"[Harness] %d matches | HPBreak %.0f%% SpinOut %.0f%% | dur %.1fs | coll %.1f walls %.1f mana %.0f | draws %d timeout %d | P1/P2 %d/%d",
			numMatches, agg.hpBreakPct, agg.spinOutPct, agg.avgDuration,
			agg.avgCollisions, agg.avgWalls, agg.avgMana, agg.draws, agg.timeout, agg.p1, agg.p2))
	end
	return agg
end

-- ── Loadout balance (round-robin of the 4 presets) ────────────────────────────
function SimulationHarness.RunLoadoutBalance(perPair, baseSeed)
	perPair = perPair or 30
	baseSeed = baseSeed or 5000
	local names = { "Balanced", "Attacker", "Defender", "Stamina" }
	local wins, games = {}, {}
	for _, n in ipairs(names) do wins[n] = 0; games[n] = 0 end

	local seed = baseSeed
	for ai = 1, #names do
		for bi = 1, #names do
			if ai == bi then continue end
			local A, B = names[ai], names[bi]
			for k = 1, perPair do
				seed += 1
				-- Alternate sides each game to cancel any seat bias.
				local swap = (k % 2 == 0)
				local r = runMatch(seed, {
					personA = "Balanced", personB = "Balanced",
					buildA = swap and BeyParts.PRESETS[B] or BeyParts.PRESETS[A],
					buildB = swap and BeyParts.PRESETS[A] or BeyParts.PRESETS[B],
				})
				games[A] += 1; games[B] += 1
				if not r.timedOut and not r.draw then
					local winnerPreset
					if r.winner == 1 then winnerPreset = swap and B or A
					else winnerPreset = swap and A or B end
					wins[winnerPreset] += 1
				end
			end
		end
	end

	local rates = {}
	for _, n in ipairs(names) do
		rates[n] = games[n] > 0 and (wins[n] / games[n] * 100) or 0
	end
	return rates, names
end

-- ── Validation suite (GO / NO-GO) ─────────────────────────────────────────────
function SimulationHarness.RunValidationSuite(numMatches)
	numMatches = (type(numMatches) == "number") and numMatches or 160
	print("══════════════════════════════════════════════════════════")
	print(string.format("  VALIDATION SUITE — %d mirror matches + loadout round-robin", numMatches))
	print("══════════════════════════════════════════════════════════")

	local m = SimulationHarness.RunBatch(numMatches, { personA = "Balanced", personB = "Balanced", quiet = true })
	local rates, names = SimulationHarness.RunLoadoutBalance(24)

	local gates = {}
	local function gate(id, ok, detail)
		table.insert(gates, { id = id, ok = ok, detail = detail })
	end

	gate("G1 HP-break 55-80%", m.hpBreakPct >= 55 and m.hpBreakPct <= 80, string.format("%.0f%%", m.hpBreakPct))
	gate("G2 SpinOut 20-45%", m.spinOutPct >= 20 and m.spinOutPct <= 45, string.format("%.0f%%", m.spinOutPct))
	gate("G3 duration 20-70s", m.avgDuration >= 20 and m.avgDuration <= 70, string.format("%.1fs", m.avgDuration))
	gate("G4 mana 15-85", m.avgMana >= 15 and m.avgMana <= 85, string.format("%.0f", m.avgMana))
	gate("G6 walls >= 3/match", m.avgWalls >= 3, string.format("%.1f", m.avgWalls))

	local g5ok = true
	local g5parts = {}
	for _, n in ipairs(names) do
		local r = rates[n]
		if r < 28 or r > 65 then g5ok = false end
		table.insert(g5parts, string.format("%s %.0f%%", n, r))
	end
	gate("G5 loadout 28-65% each", g5ok, table.concat(g5parts, " "))

	print(string.format("  Mirror: HPBreak %.0f%% SpinOut %.0f%% | dur %.1fs | coll %.1f walls %.1f mana %.0f | timeout %d draws %d",
		m.hpBreakPct, m.spinOutPct, m.avgDuration, m.avgCollisions, m.avgWalls, m.avgMana, m.timeout, m.draws))
	print("  ── Gates ──")
	local allPass = true
	for _, g in ipairs(gates) do
		if not g.ok then allPass = false end
		print(string.format("   [%s] %s  (%s)", g.ok and "PASS" or "FAIL", g.id, g.detail))
	end
	print("══════════════════════════════════════════════════════════")
	print(string.format("  RESULT: %s", allPass and "GO ✅" or "NO-GO ❌"))
	print("══════════════════════════════════════════════════════════")
	return allPass
end

-- ── Per-stadium band check ────────────────────────────────────────────────────
function SimulationHarness.RunStadiumGate(stadiumId, numMatches)
	stadiumId = stadiumId or "Classic"
	numMatches = (type(numMatches) == "number") and numMatches or 120
	print(string.format("── Stadium gate: %s (%d matches) ──", stadiumId, numMatches))
	local m = SimulationHarness.RunBatch(numMatches, {
		personA = "Balanced", personB = "Balanced", stadiumId = stadiumId, quiet = true,
	})
	local ok = m.avgDuration >= 15 and m.avgDuration <= 80 and m.timeout <= numMatches * 0.10
	print(string.format("  HPBreak %.0f%% SpinOut %.0f%% | dur %.1fs | walls %.1f | timeout %d → %s",
		m.hpBreakPct, m.spinOutPct, m.avgDuration, m.avgWalls, m.timeout, ok and "PASS" or "FAIL"))
	return ok
end

-- ── Single-match trace (diagnostic) ───────────────────────────────────────────
function SimulationHarness.TraceMatch(seed, cfg)
	local r = runMatch(seed or 99, cfg)
	print(string.format("[Trace] winner=%s reason=%s dur=%.1fs coll=%d walls=%d manaAvg=%.0f timedOut=%s",
		tostring(r.winner), tostring(r.loserReason), r.durationSec, r.collisions, r.walls, r.manaAvg, tostring(r.timedOut)))
	return r
end

return SimulationHarness
