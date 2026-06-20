--[=[
	SimulationHarness.lua
	Runs headless deterministic matches to validate the new mechanics and gather
	aggregate metrics. Only runs when explicitly invoked — never on live startup.

	Studio command bar:
	  _G.RunSimulation(200)        -- batch + report
	  _G.RunValidationSuite(300)   -- batch + PASS/FAIL gates
	  _G.RunStadiumGate("Classic") -- single-stadium balance snapshot
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MatchState = require(ReplicatedStorage:WaitForChild("MatchState"))
local BeyParts = require(ReplicatedStorage:WaitForChild("BeyParts"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local BotController = require(script.Parent:WaitForChild("BotController"))

local SimulationHarness = {}

local PRESET_NAMES = { "Balanced", "Attacker", "Defender", "Stamina" }
local PERSONALITIES = BotController.PERSONALITIES

-- Run a single headless match. p1/p2 configs: { loadout = name, personality = name }.
local function runMatch(index, p1Cfg, p2Cfg)
	local p1Id, p2Id = 101, 102
	local matchSeed = math.floor(workspace:GetServerTimeNow() * 10000 + index * 7919) % (2 ^ 31 - 1)

	local state = MatchState.new(matchSeed)
	state.matchId = "SimMatch_" .. tostring(index)
	state.phase = "Active"
	state.playerOrder = { p1Id, p2Id }

	TickManager.SetMatchState(state)
	local rng = TickManager.GetRandom()

	local spawnX = Constants.StadiumRadius * 0.45
	local function makeBey(pid, loadoutName, sx)
		local b = MatchState.createBeyState(pid, BeyParts.PRESETS[loadoutName])
		b.position = Vector3.new(sx, Constants.BeyRadius, 0)
		b.previousPosition = b.position
		b.angularVelocity = Vector3.new(0, Constants.LaunchBaseSpin * b.mods.Stamina, 0)
		b.facingAngle = (sx < 0) and 0 or math.pi
		b.targetFacing = b.facingAngle
		local dir = Vector3.new(math.cos(b.facingAngle), 0, math.sin(b.facingAngle))
		b.velocity = dir * Constants.LaunchImpulseSpeed
		return b
	end

	state.beyStates[p1Id] = makeBey(p1Id, p1Cfg.loadout, -spawnX)
	state.beyStates[p2Id] = makeBey(p2Id, p2Cfg.loadout, spawnX)

	local matchCollisions = 0
	local matchWallBounces = 0

	while state.phase ~= "Finished" do
		-- Bots write the analog input packet, mirroring real players.
		state.inputBuffer[p1Id] = BotController.decide(state.beyStates[p1Id], state.beyStates[p2Id], p1Cfg.personality, rng)
		state.inputBuffer[p2Id] = BotController.decide(state.beyStates[p2Id], state.beyStates[p1Id], p2Cfg.personality, rng)

		TickManager.Step(true)

		for _, ev in ipairs(state.tickEvents) do
			if ev.eventType == "Collision" then
				matchCollisions += 1
			elseif ev.eventType == "WallBounce" then
				matchWallBounces += 1
			end
		end

		if state.tickNumber > 10000 then
			break
		end
	end

	-- Determine loser + finish reason.
	local loserState = nil
	if state.currentWinner == p1Id then
		loserState = state.beyStates[p2Id]
	elseif state.currentWinner == p2Id then
		loserState = state.beyStates[p1Id]
	end

	return {
		winner = state.currentWinner,
		p1Id = p1Id,
		p2Id = p2Id,
		ticks = state.tickNumber,
		collisions = matchCollisions,
		wallBounces = matchWallBounces,
		finishReason = loserState and (loserState.finishReason or "SpinOut") or nil,
		p1ManaEnd = state.beyStates[p1Id].mana,
		p2ManaEnd = state.beyStates[p2Id].mana,
	}
end

function SimulationHarness.RunBatch(numMatches: number)
	numMatches = numMatches or 100
	print(string.format("--- SIMULATION HARNESS STARTED: %d MATCHES ---", numMatches))

	local m = {
		totalMatches = numMatches,
		draws = 0, player1Wins = 0, player2Wins = 0,
		hpBreaks = 0, spinOuts = 0,
		totalDurationTicks = 0, shortestDuration = math.huge, longestDuration = 0,
		totalCollisions = 0, totalWallBounces = 0,
		manaEndSum = 0, manaEndSamples = 0,
	}

	for i = 1, numMatches do
		if i % 25 == 0 then task.wait() end

		-- Vary loadouts and personalities deterministically across the batch.
		local p1Cfg = {
			loadout = PRESET_NAMES[((i - 1) % #PRESET_NAMES) + 1],
			personality = PERSONALITIES[((i - 1) % #PERSONALITIES) + 1],
		}
		local p2Cfg = {
			loadout = PRESET_NAMES[(i % #PRESET_NAMES) + 1],
			personality = PERSONALITIES[(i % #PERSONALITIES) + 1],
		}

		local r = runMatch(i, p1Cfg, p2Cfg)

		m.totalDurationTicks += r.ticks
		m.totalCollisions += r.collisions
		m.totalWallBounces += r.wallBounces
		m.shortestDuration = math.min(m.shortestDuration, r.ticks)
		m.longestDuration = math.max(m.longestDuration, r.ticks)
		m.manaEndSum += r.p1ManaEnd + r.p2ManaEnd
		m.manaEndSamples += 2

		if r.winner == "Draw" then
			m.draws += 1
		elseif r.winner == r.p1Id then
			m.player1Wins += 1
		elseif r.winner == r.p2Id then
			m.player2Wins += 1
		end

		if r.finishReason == "HpBreak" then
			m.hpBreaks += 1
		elseif r.finishReason == "SpinOut" then
			m.spinOuts += 1
		end
	end

	local rate = 1 / Constants.SimulationTickRate
	m.avgDuration = (m.totalDurationTicks / m.totalMatches) * rate
	m.avgCollisions = m.totalCollisions / m.totalMatches
	m.avgWallBounces = m.totalWallBounces / m.totalMatches
	m.avgManaEnd = (m.manaEndSamples > 0) and (m.manaEndSum / m.manaEndSamples) or 0
	local decided = m.hpBreaks + m.spinOuts
	m.hpBreakPct = (decided > 0) and (m.hpBreaks / decided * 100) or 0
	m.spinOutPct = (decided > 0) and (m.spinOuts / decided * 100) or 0

	print("==================================================")
	print("           SIMULATION HARNESS REPORT              ")
	print("==================================================")
	print(string.format("Total Matches:      %d", m.totalMatches))
	print(string.format("Average Duration:   %.2fs", m.avgDuration))
	print(string.format("Shortest / Longest: %.2fs / %.2fs", m.shortestDuration * rate, m.longestDuration * rate))
	print(string.format("Avg Collisions:     %.1f / match", m.avgCollisions))
	print(string.format("Avg Wall Bounces:   %.1f / match", m.avgWallBounces))
	print(string.format("Avg Mana @ end:     %.1f", m.avgManaEnd))
	print("--------------------------------------------------")
	print(string.format("Draw Rate:          %.1f%%", m.draws / m.totalMatches * 100))
	print(string.format("Player 1 Win Rate:  %.1f%%", m.player1Wins / m.totalMatches * 100))
	print(string.format("Player 2 Win Rate:  %.1f%%", m.player2Wins / m.totalMatches * 100))
	print("--------------------------------------------------")
	print("Finish Types (decided wins):")
	print(string.format("  HP Break:         %d (%.1f%%)", m.hpBreaks, m.hpBreakPct))
	print(string.format("  Spin Out:         %d (%.1f%%)", m.spinOuts, m.spinOutPct))
	print("==================================================")

	return m
end

-- Loadout-archetype round-robin (the real ADR-003 balance test): each crafted
-- build should be viable, none dominant. Both bots use the same neutral
-- personality so the LOADOUT decides the outcome. Sides alternated.
local function runLoadoutBalance(perPair)
	local L = { "Attacker", "Defender", "Stamina", "Balanced" }
	local wins, games = {}, {}
	for _, n in ipairs(L) do wins[n] = 0; games[n] = 0 end

	local mi = 0
	for a = 1, #L do
		for b = a + 1, #L do
			for k = 1, perPair do
				mi += 1
				if mi % 25 == 0 then task.wait() end
				local leftL = (k % 2 == 0) and L[a] or L[b]
				local rightL = (k % 2 == 0) and L[b] or L[a]
				local r = runMatch(200000 + mi,
					{ loadout = leftL, personality = "Balanced" },
					{ loadout = rightL, personality = "Balanced" })
				games[leftL] += 1
				games[rightL] += 1
				if r.winner == r.p1Id then
					wins[leftL] += 1
				elseif r.winner == r.p2Id then
					wins[rightL] += 1
				end
			end
		end
	end

	local rates = {}
	for _, n in ipairs(L) do
		rates[n] = (games[n] > 0) and (wins[n] / games[n] * 100) or 0
	end
	return rates, L
end

function SimulationHarness.RunValidationSuite(numMatches)
	numMatches = numMatches or 300
	local m = SimulationHarness.RunBatch(numMatches)

	local rates, L = runLoadoutBalance(math.max(12, math.floor(numMatches / 8)))
	local minRate, maxRate = math.huge, -math.huge
	local rateStr = {}
	for _, n in ipairs(L) do
		minRate = math.min(minRate, rates[n])
		maxRate = math.max(maxRate, rates[n])
		table.insert(rateStr, string.format("%s %.0f%%", n, rates[n]))
	end

	local function gate(name, pass, detail)
		print(string.format("  [%s] %s — %s", pass and "PASS" or "FAIL", name, detail))
		return pass
	end

	print("==================================================")
	print("              VALIDATION GATES                    ")
	print("==================================================")
	local allPass = true
	allPass = gate("G1 HP-Break share 55–80%", m.hpBreakPct >= 55 and m.hpBreakPct <= 80,
		string.format("%.1f%%", m.hpBreakPct)) and allPass
	allPass = gate("G2 SpinOut share 20–45%", m.spinOutPct >= 20 and m.spinOutPct <= 45,
		string.format("%.1f%%", m.spinOutPct)) and allPass
	allPass = gate("G3 Avg duration 20–70s", m.avgDuration >= 20 and m.avgDuration <= 70,
		string.format("%.1fs", m.avgDuration)) and allPass
	allPass = gate("G4 Mana economy 15–85", m.avgManaEnd >= 15 and m.avgManaEnd <= 85,
		string.format("%.1f", m.avgManaEnd)) and allPass
	allPass = gate("G5 No dominant loadout (28–65% each)", minRate >= 28 and maxRate <= 65,
		table.concat(rateStr, " / ")) and allPass
	allPass = gate("G6 Walls active (≥3/match)", m.avgWallBounces >= 3,
		string.format("%.1f/match", m.avgWallBounces)) and allPass
	print("--------------------------------------------------")
	print(string.format("  RESULT: %s", allPass and "ALL GATES PASS" or "ONE OR MORE GATES FAILED"))
	print("==================================================")

	return allPass
end

-- Diagnostic: run one match and print periodic state. Dev tool for balance work.
function SimulationHarness.TraceMatch(loadoutA, loadoutB, personality)
	personality = personality or "Balanced"
	local p1Id, p2Id = 101, 102
	local state = MatchState.new(424242)
	state.matchId = "Trace"
	state.phase = "Active"
	state.playerOrder = { p1Id, p2Id }
	TickManager.SetMatchState(state)
	local rng = TickManager.GetRandom()
	local spawnX = Constants.StadiumRadius * 0.45

	local function makeBey(pid, name, sx)
		local b = MatchState.createBeyState(pid, BeyParts.PRESETS[name])
		b.position = Vector3.new(sx, Constants.BeyRadius, 0)
		b.previousPosition = b.position
		b.angularVelocity = Vector3.new(0, Constants.LaunchBaseSpin * b.mods.Stamina, 0)
		b.facingAngle = (sx < 0) and 0 or math.pi
		b.targetFacing = b.facingAngle
		b.velocity = Vector3.new(math.cos(b.facingAngle), 0, math.sin(b.facingAngle)) * Constants.LaunchImpulseSpeed
		return b
	end
	state.beyStates[p1Id] = makeBey(p1Id, loadoutA, -spawnX)
	state.beyStates[p2Id] = makeBey(p2Id, loadoutB, spawnX)

	print(string.format("TRACE: %s (P1) vs %s (P2)", loadoutA, loadoutB))
	local a, b = state.beyStates[p1Id], state.beyStates[p2Id]
	print(string.format("  P1 maxHp=%d Atk=%.2f Def=%.2f Sta=%.2f Agi=%.2f", a.maxHp, a.mods.Attack, a.mods.Defense, a.mods.Stamina, a.mods.Agility))
	print(string.format("  P2 maxHp=%d Atk=%.2f Def=%.2f Sta=%.2f Agi=%.2f", b.maxHp, b.mods.Attack, b.mods.Defense, b.mods.Stamina, b.mods.Agility))

	while state.phase ~= "Finished" do
		state.inputBuffer[p1Id] = BotController.decide(a, b, personality, rng)
		state.inputBuffer[p2Id] = BotController.decide(b, a, personality, rng)
		TickManager.Step(true)
		if state.tickNumber % 60 == 0 then
			print(string.format("  t=%5.1fs  P1 hp=%5.1f rpm=%5.1f tilt=%4.0f mana=%4.0f | P2 hp=%5.1f rpm=%5.1f tilt=%4.0f mana=%4.0f",
				state.tickNumber / Constants.SimulationTickRate,
				a.hp, a.angularVelocity.Magnitude, a.tilt, a.mana,
				b.hp, b.angularVelocity.Magnitude, b.tilt, b.mana))
		end
		if state.tickNumber > 10000 then break end
	end
	print(string.format("  WINNER: %s  (P1 reason=%s, P2 reason=%s)  ticks=%d",
		tostring(state.currentWinner), tostring(a.finishReason), tostring(b.finishReason), state.tickNumber))
end

function SimulationHarness.RunStadiumGate(stadiumId)
	print(string.format("--- STADIUM GATE: %s ---", tostring(stadiumId)))
	-- Single stadium exists for now; this is a balance snapshot hook.
	return SimulationHarness.RunBatch(120)
end

return SimulationHarness
