--[=[
	driver.lua — entry point appended after the wrapped game modules.

	Usage (via build_runner.py):
	  suite [baselineCount] [matrixCount]      -- full Phase 1 validation suite
	  batch [count] [policyA] [policyB] [seed] -- single batch
	  persistence                              -- pure persistence-logic tests
]=]

local args = { ... }
local mode = args[1] or "suite"

-- ── Tiny test kit ─────────────────────────────────────────────────────────────

local __passCount, __failCount = 0, 0

local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		__passCount += 1
		print(string.format("  [PASS] %s", name))
	else
		__failCount += 1
		print(string.format("  [FAIL] %s — %s", name, tostring(err)))
	end
end

local function expect(condition, message)
	if not condition then
		error(message or "expectation failed", 2)
	end
end

local function finishTests(label)
	print(string.format("%s: %d passed, %d failed", label, __passCount, __failCount))
	if __failCount > 0 then
		error(label .. " reported failures", 0)
	end
end

-- ── Modes ─────────────────────────────────────────────────────────────────────

if mode == "suite" or mode == "batch" then
	-- Mirror Main.server.lua load order, minus the Replication-phase modules
	-- (TelemetryLogger / ReplayRecorder / DebugStatePublisher). The Replication
	-- phase never executes under TickManager.Step(true), so this matches live
	-- headless behaviour exactly.
	require(__tokens["ServerScriptService/BeyController"])
	require(__tokens["ServerScriptService/PhysicsController"])
	require(__tokens["ServerScriptService/SpinEvaluator"])

	local SimulationHarness = require(__tokens["ServerScriptService/SimulationHarness"])

	if mode == "suite" then
		local suiteOptions = {
			baselineCount = tonumber(args[2]) or 1000,
			matrixCount = tonumber(args[3]) or 200,
		}
		local results = SimulationHarness.RunValidationSuite(suiteOptions)
		if not results.allPass then
			error("Validation suite reported NO-GO", 0)
		end
	else
		SimulationHarness.RunBatch(tonumber(args[2]) or 100, {
			policyA = args[3] or "None",
			policyB = args[4] or "None",
			baseSeed = tonumber(args[5]),
			stadiumId = args[6],
		})
	end

elseif mode == "stadium" then
	require(__tokens["ServerScriptService/BeyController"])
	require(__tokens["ServerScriptService/PhysicsController"])
	require(__tokens["ServerScriptService/SpinEvaluator"])
	local SimulationHarness = require(__tokens["ServerScriptService/SimulationHarness"])

	local stadiumId = args[2] or "Classic"
	local results = SimulationHarness.RunStadiumGate(stadiumId, { count = tonumber(args[3]) or 500 })
	if not results.allPass then
		error("Stadium gate reported CUT for " .. stadiumId, 0)
	end

elseif mode == "persistence" then
	local ProfileLogic = require(__tokens["ServerScriptService/Persistence/ProfileLogic"])
	local ProfileSchema = require(__tokens["ServerScriptService/Persistence/ProfileSchema"])
	local LaunchQuality = require(__tokens["ReplicatedStorage/LaunchQuality"])
	local Constants = require(__tokens["ReplicatedStorage/Constants"])

	print("──────── Launch quality tests ────────")

	test("bar: triangle sweep 0 -> 1 -> 0", function()
		local period = Constants.LaunchBarPeriod
		local function near(a, b)
			return math.abs(a - b) < 1e-9
		end
		expect(near(LaunchQuality.barPosition(0, 0), 0))
		expect(near(LaunchQuality.barPosition(period / 4, 0), 0.5))
		expect(near(LaunchQuality.barPosition(period / 2, 0), 1))
		expect(near(LaunchQuality.barPosition(3 * period / 4, 0), 0.5))
		expect(near(LaunchQuality.barPosition(period, 0), 0))
	end)
	test("grade: centre is Perfect, bands are ordered", function()
		local period = Constants.LaunchBarPeriod
		expect(LaunchQuality.gradeAt(period / 4, 0) == "Perfect")
		-- position 0.5 + LaunchGoodZone - small epsilon -> Good
		local goodTime = (0.5 + Constants.LaunchGoodZone - 0.01) * (period / 2)
		expect(LaunchQuality.gradeAt(goodTime, 0) == "Good", "got " .. LaunchQuality.gradeAt(goodTime, 0))
		-- far edge -> Poor
		expect(LaunchQuality.gradeAt(0.01, 0) == "Poor")
	end)
	test("bonus: every tier honours LaunchBonusCap", function()
		for quality, bonus in pairs(LaunchQuality.BONUS) do
			expect(math.abs(bonus) <= Constants.LaunchBonusCap,
				quality .. " exceeds the cap")
		end
		expect(LaunchQuality.multiplierFor("Perfect") == 1 + Constants.LaunchBonusPerfect)
		expect(LaunchQuality.multiplierFor("NotATier") == 1)
	end)

	print("──────── Persistence logic tests ────────")

	-- Lock arbitration
	test("lock: no existing lock -> acquire", function()
		expect(ProfileLogic.arbitrateLock(nil, "job-A", 1000) == "acquire")
	end)
	test("lock: own lock -> acquire (refresh)", function()
		local lock = ProfileLogic.makeLock("job-A", 1000)
		expect(ProfileLogic.arbitrateLock(lock, "job-A", 1050) == "acquire")
	end)
	test("lock: fresh foreign lock -> held", function()
		local lock = ProfileLogic.makeLock("job-B", 1000)
		expect(ProfileLogic.arbitrateLock(lock, "job-A", 1000 + ProfileLogic.LOCK_TIMEOUT_SECONDS) == "held")
	end)
	test("lock: stale foreign lock -> steal", function()
		local lock = ProfileLogic.makeLock("job-B", 1000)
		expect(ProfileLogic.arbitrateLock(lock, "job-A", 1001 + ProfileLogic.LOCK_TIMEOUT_SECONDS) == "steal")
	end)

	-- Migration
	test("migrate: same version is a no-op", function()
		local data = { x = 1 }
		local out, v = ProfileLogic.migrate(data, 1, 1, {})
		expect(out == data and v == 1)
	end)
	test("migrate: chain applies in order", function()
		local migrations = {
			[1] = function(d) d.steps = (d.steps or "") .. "a"; return d end,
			[2] = function(d) d.steps = d.steps .. "b"; return d end,
		}
		local out, v = ProfileLogic.migrate({}, 1, 3, migrations)
		expect(out.steps == "ab" and v == 3, "got " .. tostring(out.steps) .. " v" .. tostring(v))
	end)
	test("migrate: missing step errors", function()
		local ok = pcall(ProfileLogic.migrate, {}, 1, 2, {})
		expect(not ok)
	end)
	test("migrate: never downgrades future versions", function()
		local data = { fromTheFuture = true }
		local out, v = ProfileLogic.migrate(data, 99, ProfileSchema.SCHEMA_VERSION, ProfileSchema.MIGRATIONS)
		expect(out == data and v == 99)
	end)

	-- Reconcile
	test("reconcile: fills missing scalars and nested tables", function()
		local data = { mmr = 1234 }
		ProfileLogic.reconcile(data, ProfileSchema.defaults())
		expect(data.mmr == 1234, "existing value clobbered")
		expect(data.stats ~= nil and data.stats.wins == 0, "nested default missing")
		expect(data.stats.finishesBy.SpinOut == 0, "deep default missing")
		expect(data.level == 1 and data.softCurrency == 0, "reserved fields missing")
	end)
	test("reconcile: preserves existing nested values", function()
		local data = { stats = { wins = 7 } }
		ProfileLogic.reconcile(data, ProfileSchema.defaults())
		expect(data.stats.wins == 7 and data.stats.losses == 0)
	end)
	test("reconcile: deep-copies defaults (no shared tables)", function()
		local a, b = {}, {}
		ProfileLogic.reconcile(a, ProfileSchema.defaults())
		ProfileLogic.reconcile(b, ProfileSchema.defaults())
		a.stats.wins = 99
		expect(b.stats.wins == 0, "two profiles share a defaults table")
	end)

	-- Backoff
	test("backoff: 1,2,4,8 then give up", function()
		expect(ProfileLogic.backoffDelay(1) == 1)
		expect(ProfileLogic.backoffDelay(2) == 2)
		expect(ProfileLogic.backoffDelay(3) == 4)
		expect(ProfileLogic.backoffDelay(4) == 8)
		expect(ProfileLogic.backoffDelay(5) == nil)
	end)

	-- Stats application
	test("stats: win records finish type", function()
		local stats = ProfileSchema.defaults().stats
		ProfileLogic.applyMatchResult(stats, "Win", "RingOut")
		expect(stats.wins == 1 and stats.matchesPlayed == 1 and stats.finishesBy.RingOut == 1)
	end)
	test("stats: loss records own finish type", function()
		local stats = ProfileSchema.defaults().stats
		ProfileLogic.applyMatchResult(stats, "Loss", "WobbleCollapse")
		expect(stats.losses == 1 and stats.lossesBy.WobbleCollapse == 1)
	end)
	test("stats: draw has no finish type", function()
		local stats = ProfileSchema.defaults().stats
		ProfileLogic.applyMatchResult(stats, "Draw", nil)
		expect(stats.draws == 1 and stats.matchesPlayed == 1)
	end)
	test("stats: unknown finish reason is ignored safely", function()
		local stats = ProfileSchema.defaults().stats
		ProfileLogic.applyMatchResult(stats, "Win", "NotARealReason")
		expect(stats.wins == 1)
	end)

	local MmrLogic = require(__tokens["ServerScriptService/Matchmaking/MmrLogic"])
	local MatchQueue = require(__tokens["ServerScriptService/Matchmaking/MatchQueue"])

	local Stadiums = require(__tokens["ReplicatedStorage/Stadiums"])

	print("──────── Stadium registry tests ────────")

	test("stadiums: Classic mirrors the validated Constants exactly", function()
		local classic = Stadiums.get("Classic")
		expect(classic.bowlSphereRadius == Constants.BowlSphereRadius)
		expect(classic.playableRadius == Constants.BowlPlayableRadius)
		expect(classic.rimBuffer == Constants.BowlRimBuffer)
		expect(classic.bowlForce == Constants.BowlForce)
	end)
	test("stadiums: every registry entry validates", function()
		for id, def in pairs(Stadiums.REGISTRY) do
			local ok, why = Stadiums.validate(def)
			expect(ok, id .. ": " .. tostring(why))
			expect(def.id == id, id .. ": id field mismatch")
		end
	end)
	test("stadiums: rotation entries exist in the registry", function()
		expect(#Stadiums.ROTATION >= 1)
		for _, id in ipairs(Stadiums.ROTATION) do
			expect(Stadiums.REGISTRY[id] ~= nil, "rotation references unknown stadium " .. tostring(id))
		end
	end)
	test("stadiums: unknown id falls back to default", function()
		expect(Stadiums.get("NotARealStadium").id == Stadiums.DEFAULT_ID)
		expect(Stadiums.get(nil).id == Stadiums.DEFAULT_ID)
	end)
	test("stadiums: validate rejects malformed definitions", function()
		expect(not Stadiums.validate({ id = "X", playableRadius = 4, bowlSphereRadius = 50, rimBuffer = 0.8, bowlForce = 7 }))
		expect(not Stadiums.validate({ id = "X", playableRadius = 20, bowlSphereRadius = 10, rimBuffer = 0.8, bowlForce = 7 }))
		expect(not Stadiums.validate({ id = "", playableRadius = 20, bowlSphereRadius = 50, rimBuffer = 0.8, bowlForce = 7 }))
	end)
	test("stadiums: seeded rotation pick is deterministic and in range", function()
		for seed = 0, 25 do
			local id = Stadiums.pickForSeed(seed)
			expect(Stadiums.REGISTRY[id] ~= nil)
			expect(Stadiums.pickForSeed(seed) == id)
		end
	end)

	print("──────── Pending adjustment tests (offline-safe writes) ────────")

	test("pending: ranked loss applies delta and tally", function()
		local data = ProfileSchema.defaults()
		data.mmr = 1200
		local _, remaining = ProfileLogic.applyPending(data, {
			{ type = "rankedResult", mmrDelta = -16, result = "Loss" },
		})
		expect(data.mmr == 1184 and data.rankedLosses == 1 and #remaining == 0)
	end)
	test("pending: multiple adjustments apply in order", function()
		local data = ProfileSchema.defaults()
		ProfileLogic.applyPending(data, {
			{ type = "rankedResult", mmrDelta = 20, result = "Win" },
			{ type = "rankedResult", mmrDelta = -10, result = "Loss" },
			{ type = "rankedResult", mmrDelta = 0, result = "Draw" },
		})
		expect(data.mmr == 1010, "got " .. tostring(data.mmr))
		expect(data.rankedWins == 1 and data.rankedLosses == 1 and data.rankedDraws == 1)
	end)
	test("pending: mmr never goes negative", function()
		local data = ProfileSchema.defaults()
		data.mmr = 5
		ProfileLogic.applyPending(data, { { type = "rankedResult", mmrDelta = -50, result = "Loss" } })
		expect(data.mmr == 0)
	end)
	test("pending: unknown types are preserved, not dropped", function()
		local data = ProfileSchema.defaults()
		local _, remaining = ProfileLogic.applyPending(data, {
			{ type = "rankedResult", mmrDelta = 1, result = "Win" },
			{ type = "futureGiftGrant", itemId = "hat" },
		})
		expect(#remaining == 1 and remaining[1].type == "futureGiftGrant")
	end)
	test("pending: nil list is a no-op", function()
		local data = ProfileSchema.defaults()
		local _, remaining = ProfileLogic.applyPending(data, nil)
		expect(data.mmr == 1000 and #remaining == 0)
	end)

	print("──────── MMR logic tests ────────")

	test("elo: expected scores are complementary", function()
		expect(math.abs(MmrLogic.expectedScore(1000, 1000) - 0.5) < 1e-9)
		local e1 = MmrLogic.expectedScore(1200, 1000)
		local e2 = MmrLogic.expectedScore(1000, 1200)
		expect(math.abs((e1 + e2) - 1) < 1e-9)
		expect(e1 > 0.7, "200-point favourite should be > 70%")
	end)
	test("elo: equal-K updates are zero-sum", function()
		local a, b = MmrLogic.updateRatings(1100, 1000, 1, 32, 32)
		expect(a > 1100 and b < 1000)
		expect((a - 1100) + (b - 1000) == 0, "gain must equal loss")
	end)
	test("elo: draw moves unequal ratings together", function()
		local a, b = MmrLogic.updateRatings(1200, 1000, 0.5, 32, 32)
		expect(a < 1200 and b > 1000)
	end)
	test("elo: rating floor holds", function()
		local _, b = MmrLogic.updateRatings(2000, 105, 1, 32, 32)
		expect(b >= MmrLogic.RATING_FLOOR)
	end)
	test("k-factor: placement boundary", function()
		expect(MmrLogic.kFor(MmrLogic.PLACEMENT_MATCHES - 1) == MmrLogic.K_PLACEMENT)
		expect(MmrLogic.kFor(MmrLogic.PLACEMENT_MATCHES) == MmrLogic.K_STANDARD)
	end)
	test("tiers: boundaries map correctly", function()
		expect(MmrLogic.tierFor(899) == "Bronze")
		expect(MmrLogic.tierFor(900) == "Silver")
		expect(MmrLogic.tierFor(1100) == "Gold")
		expect(MmrLogic.tierFor(1500) == "Diamond")
	end)

	print("──────── Match queue tests ────────")

	test("queue: join/dup/leave/size", function()
		local q = MatchQueue.new("Ranked")
		expect(q:join(1, 1000, 0))
		expect(not q:join(1, 1000, 0), "duplicate join must fail")
		expect(q:contains(1) and q:size() == 1)
		expect(q:leave(1) and q:size() == 0)
		expect(not q:leave(1), "double leave must fail")
	end)
	test("queue: close MMRs pair immediately, far ones wait", function()
		local q = MatchQueue.new("Ranked")
		q:join(1, 1000, 0)
		q:join(2, 1010, 0)
		q:join(3, 1700, 0)
		local pairs1 = q:tick(0)
		expect(#pairs1 == 1, "expected exactly one pair")
		local matched = { [pairs1[1].a.userId] = true, [pairs1[1].b.userId] = true }
		expect(matched[1] and matched[2], "the close pair should match")
		expect(q:contains(3), "outlier stays queued")
	end)
	test("queue: tolerance widens with wait time", function()
		local q = MatchQueue.new("Ranked", { baseTolerance = 100, toleranceGrowthPerSecond = 5, toleranceMax = 500 })
		q:join(1, 1000, 0)
		q:join(2, 1300, 0)
		expect(#q:tick(0) == 0, "300 gap must not pair at t0")
		expect(#q:tick(45) == 1, "tolerance 325 at t45 covers the 300 gap")
	end)
	test("queue: tolerance cap is a hard wall", function()
		local q = MatchQueue.new("Ranked", { baseTolerance = 100, toleranceGrowthPerSecond = 5, toleranceMax = 500 })
		q:join(1, 1000, 0)
		q:join(2, 1600, 0)
		expect(#q:tick(10000) == 0, "600 gap must never pair (cap 500)")
	end)
	test("queue: pairs by proximity, drains evens", function()
		local q = MatchQueue.new("Casual", { baseTolerance = 100000, toleranceGrowthPerSecond = 0, toleranceMax = 100000 })
		q:join(1, 900, 0)
		q:join(2, 950, 0)
		q:join(3, 1400, 0)
		q:join(4, 1450, 0)
		local got = q:tick(0)
		expect(#got == 2 and q:size() == 0)
	end)

	print("──────── MMR convergence simulation (plan: 'does it converge?') ────────")

	test("convergence: rating order matches true skill (rho >= 0.85)", function()
		-- 20 players with hidden true skills; everyone starts at 1000.
		-- Each round pairs rating-neighbours (mirroring queue pairing) and
		-- resolves wins probabilistically from TRUE skill. Deterministic seed.
		local rng = Random.new(42)
		local players = {}
		for i = 1, 20 do
			players[i] = { id = i, trueSkill = 800 + (i - 1) * 40, rating = MmrLogic.DEFAULT_RATING, played = 0 }
		end

		local function spearman()
			local byRating = table.clone(players)
			table.sort(byRating, function(x, y)
				if x.rating ~= y.rating then return x.rating < y.rating end
				return x.id < y.id
			end)
			local ratingRank = {}
			for rank, p in ipairs(byRating) do
				ratingRank[p.id] = rank
			end
			-- true-skill rank == id (skills are strictly increasing by id)
			local sumD2 = 0
			for _, p in ipairs(players) do
				local d = ratingRank[p.id] - p.id
				sumD2 += d * d
			end
			local n = #players
			return 1 - (6 * sumD2) / (n * (n * n - 1))
		end

		local function playRounds(rounds)
			for _ = 1, rounds do
				local order = table.clone(players)
				table.sort(order, function(x, y)
					if x.rating ~= y.rating then return x.rating < y.rating end
					return x.id < y.id
				end)
				for i = 1, #order - 1, 2 do
					local a, b = order[i], order[i + 1]
					local pWinA = MmrLogic.expectedScore(a.trueSkill, b.trueSkill)
					local scoreA = (rng:NextNumber() < pWinA) and 1 or 0
					a.rating, b.rating = MmrLogic.updateRatings(
						a.rating, b.rating, scoreA,
						MmrLogic.kFor(a.played), MmrLogic.kFor(b.played)
					)
					a.played += 1
					b.played += 1
				end
			end
		end

		playRounds(5)
		local earlyRho = spearman()
		playRounds(55)
		local finalRho = spearman()

		print(string.format("    rho after 5 rounds: %.3f | after 60 rounds: %.3f", earlyRho, finalRho))
		expect(finalRho >= 0.85, string.format("final rho %.3f below 0.85", finalRho))
		expect(finalRho > earlyRho, "convergence should improve with more matches")
	end)

	finishTests("Logic tests")

else
	error("Unknown mode: " .. tostring(mode) .. " (expected 'suite', 'batch', 'stadium' or 'persistence')", 0)
end
