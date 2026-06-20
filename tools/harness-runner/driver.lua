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
	-- Mirror Main.server.lua battle load order, minus the Replication-phase
	-- modules. BotController is required BEFORE BeyController so the bot's input
	-- buffer is fresh when BeyController applies it (same as live).
	require(__tokens["ServerScriptService/BotController"])
	require(__tokens["ServerScriptService/BeyController"])
	require(__tokens["ServerScriptService/PhysicsController"])
	require(__tokens["ServerScriptService/SpinEvaluator"])

	local SimulationHarness = require(__tokens["ServerScriptService/SimulationHarness"])

	if mode == "suite" then
		local ok = SimulationHarness.RunValidationSuite(tonumber(args[2]) or 160)
		if not ok then
			error("Validation suite reported NO-GO", 0)
		end
	else
		SimulationHarness.RunBatch(tonumber(args[2]) or 100, {
			personA = args[3] or "Balanced",
			personB = args[4] or "Balanced",
			baseSeed = tonumber(args[5]),
			stadiumId = args[6],
		})
	end

elseif mode == "stadium" then
	require(__tokens["ServerScriptService/BotController"])
	require(__tokens["ServerScriptService/BeyController"])
	require(__tokens["ServerScriptService/PhysicsController"])
	require(__tokens["ServerScriptService/SpinEvaluator"])
	local SimulationHarness = require(__tokens["ServerScriptService/SimulationHarness"])

	local stadiumId = args[2] or "Classic"
	local ok = SimulationHarness.RunStadiumGate(stadiumId, tonumber(args[3]) or 120)
	if not ok then
		error("Stadium gate reported CUT for " .. stadiumId, 0)
	end

elseif mode == "persistence" then
	local ProfileLogic = require(__tokens["ServerScriptService/Persistence/ProfileLogic"])
	local ProfileSchema = require(__tokens["ServerScriptService/Persistence/ProfileSchema"])
	local LaunchQuality = require(__tokens["ReplicatedStorage/LaunchQuality"])
	local Constants = require(__tokens["ReplicatedStorage/Constants"])

	print("──────── Launch ceremony tests (GO grading + spherical aim) ────────")

	test("grade: GO instant is Perfect, windows are ordered", function()
		local go = 1000
		expect(LaunchQuality.gradeAtGo(go, go) == "Perfect")
		expect(LaunchQuality.gradeAtGo(go + Constants.LaunchPerfectWindow - 0.001, go) == "Perfect")
		expect(LaunchQuality.gradeAtGo(go - Constants.LaunchPerfectWindow + 0.001, go) == "Perfect")
		expect(LaunchQuality.gradeAtGo(go + Constants.LaunchPerfectWindow + 0.01, go) == "Good")
		expect(LaunchQuality.gradeAtGo(go + Constants.LaunchGoodWindow - 0.001, go) == "Good")
		expect(LaunchQuality.gradeAtGo(go - Constants.LaunchGoodWindow - 0.01, go) == "Poor")
		expect(LaunchQuality.gradeAtGo(go + 2, go) == "Poor")
	end)
	test("bonus: every tier honours LaunchBonusCap", function()
		for quality, bonus in pairs(LaunchQuality.BONUS) do
			expect(math.abs(bonus) <= Constants.LaunchBonusCap,
				quality .. " exceeds the cap")
		end
		expect(LaunchQuality.multiplierFor("Perfect") == 1 + Constants.LaunchBonusPerfect)
		expect(LaunchQuality.multiplierFor("NotATier") == 1)
	end)
	test("aim: clamp enforces ranges, wraps phi, survives garbage", function()
		local a = LaunchQuality.clampAim({ height = 99, theta = 10, phi = 725 })
		expect(a.height == Constants.LaunchHeightMax)
		expect(a.theta == Constants.LaunchThetaMin)
		expect(math.abs(a.phi - 5) < 1e-9, "phi should wrap to 5, got " .. tostring(a.phi))
		local b = LaunchQuality.clampAim(nil)
		expect(b.height == Constants.LaunchHeightDefault and b.theta == Constants.LaunchThetaMax)
		local c = LaunchQuality.clampAim({ height = "evil", theta = {}, phi = "nan?" })
		expect(c.height == Constants.LaunchHeightDefault and c.phi == 0)
	end)
	test("aim: vectors honour theta/phi and never aim upward", function()
		local function near(x, y) return math.abs(x - y) < 1e-6 end
		-- Flat launch along +X
		local flat = LaunchQuality.aimToVector({ height = 10, theta = 90, phi = 0 }, 21)
		expect(near(flat.X, 21) and near(flat.Y, 0) and near(flat.Z, 0))
		-- Flat launch along +Z
		local z = LaunchQuality.aimToVector({ height = 10, theta = 90, phi = 90 }, 21)
		expect(near(z.Z, 21) and near(z.X, 0))
		-- Steep 45° plunge: downward Y, reduced horizontal, magnitude preserved
		local steep = LaunchQuality.aimToVector({ height = 10, theta = 45, phi = 0 }, 21)
		expect(steep.Y < 0, "steep launch must plunge")
		expect(near(steep.Magnitude, 21), "speed must be preserved")
		expect(steep.X < flat.X, "steeper = less carry")
	end)
	test("aim: seat defaults face the bowl centre", function()
		local p1 = LaunchQuality.defaultAimFor(-1)
		local p2 = LaunchQuality.defaultAimFor(1)
		local v1 = LaunchQuality.aimToVector(p1, 21)
		local v2 = LaunchQuality.aimToVector(p2, 21)
		expect(v1.X > 0, "P1 spawns at -X and must aim +X")
		expect(v2.X < 0, "P2 spawns at +X and must aim -X")
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
		ProfileLogic.applyMatchResult(stats, "Win", "HpBreak")
		expect(stats.wins == 1 and stats.matchesPlayed == 1 and stats.finishesBy.HpBreak == 1)
	end)
	test("stats: loss records own finish type", function()
		local stats = ProfileSchema.defaults().stats
		ProfileLogic.applyMatchResult(stats, "Loss", "SpinOut")
		expect(stats.losses == 1 and stats.lossesBy.SpinOut == 1)
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
	local Cosmetics = require(__tokens["ReplicatedStorage/Cosmetics"])
	local BeyParts = require(__tokens["ReplicatedStorage/BeyParts"])

	print("──────── BeyParts derivation tests (ADR-003) ────────")

	local function sumFractions(frac)
		return frac.Attack + frac.Defense + frac.Stamina + frac.Agility
	end

	test("derive: default build is neutral (all multipliers 1.0)", function()
		local d = BeyParts.deriveStats(BeyParts.defaultBuild())
		for _, stat in ipairs(BeyParts.STATS) do
			expect(math.abs(d.fractions[stat] - 0.25) < 1e-9, stat .. " fraction not 0.25")
			expect(math.abs(d.multipliers[stat] - 1.0) < 1e-9, stat .. " multiplier not 1.0")
		end
	end)
	test("derive: fractions always sum to 1 (conserved budget)", function()
		for _, name in ipairs({ "Attacker", "Defender", "Stamina", "Agile" }) do
			-- reuse the harness archetypes indirectly via hand specs
		end
		local builds = {
			{ Tip={shape="Spike"}, Disc={shape="Star"}, Blade={shape="Shuriken"}, Core={shape="Spike"} },
			{ Tip={shape="Flat"}, Disc={shape="Shield"}, Blade={shape="Orb"}, Core={shape="Heavy"} },
			{ Tip={shape="Hollow"}, Disc={shape="Round"}, Blade={shape="Ring"}, Core={shape="Orb"} },
			BeyParts.defaultBuild(),
		}
		for _, b in ipairs(builds) do
			local d = BeyParts.deriveStats(b)
			expect(math.abs(sumFractions(d.fractions) - 1.0) < 1e-9, "fractions must sum to 1")
		end
	end)
	test("derive: archetypes lead in their headline stat", function()
		local atk = BeyParts.deriveStats({ Tip={shape="Spike",height=1.8,weight=8}, Disc={shape="Star",weight=9}, Blade={shape="Shuriken",height=2.4,weight=12}, Core={shape="Spike",weight=7} })
		expect(atk.fractions.Attack > 0.25, "attacker should exceed neutral Attack")
		expect(atk.multipliers.Attack > 1.0 and atk.multipliers.Stamina < 1.0, "attack up, stamina down (sidegrade)")
		local def = BeyParts.deriveStats({ Tip={shape="Dome",height=0.6,weight=8}, Disc={shape="Shield",height=0.5,weight=14}, Blade={shape="Round",weight=6}, Core={shape="Heavy",weight=7} })
		expect(def.fractions.Defense > 0.25, "defender should exceed neutral Defense")
	end)
	test("derive: clamps out-of-range + unknown shape", function()
		local d = BeyParts.deriveStats({ Tip={shape="NotReal", height=999, weight=-5} })
		expect(math.abs(sumFractions(d.fractions) - 1.0) < 1e-9, "still valid after clamping garbage")
		local part = BeyParts.clampPart("Blade", { shape = "Nope", height = 99, weight = 99 })
		expect(part.shape == "Standard", "unknown shape -> Standard")
		expect(part.height <= BeyParts.LIMITS.Blade.height.max, "height clamped")
		expect(part.weight <= BeyParts.LIMITS.Blade.weight.max, "weight clamped")
	end)
	test("derive: color never affects stats", function()
		local a = BeyParts.deriveStats(BeyParts.defaultBuild())
		local withColor = BeyParts.defaultBuild()
		withColor.Tip.color = { 255, 0, 0 }
		local b = BeyParts.deriveStats(withColor)
		for _, stat in ipairs(BeyParts.STATS) do
			expect(a.multipliers[stat] == b.multipliers[stat], "color changed a stat")
		end
	end)
	test("derive: catalog is generous (>= 10 shapes per slot)", function()
		for _, slot in ipairs(BeyParts.SLOTS) do
			expect(#BeyParts.SHAPES[slot] >= 10, slot .. " has < 10 shapes")
		end
	end)

	print("──────── Cosmetics registry tests ────────")

	test("cosmetics: Default exists and every skin validates", function()
		expect(Cosmetics.SKINS[Cosmetics.DEFAULT_SKIN] ~= nil)
		for id, def in pairs(Cosmetics.SKINS) do
			local ok, why = Cosmetics.validate(def)
			expect(ok, id .. ": " .. tostring(why))
			expect(def.id == id, id .. ": id field mismatch")
		end
	end)
	test("cosmetics: unknown skin falls back to Default", function()
		expect(Cosmetics.get("NotASkin").id == Cosmetics.DEFAULT_SKIN)
		expect(Cosmetics.get(nil).id == Cosmetics.DEFAULT_SKIN)
	end)
	test("cosmetics: equip validation — starter vs unowned vs owned", function()
		expect(Cosmetics.canEquip("Crimson", nil), "starter skin must equip")
		expect(not Cosmetics.canEquip("NotASkin", nil), "unknown must not equip")
		-- Simulate a future non-starter skin via ownership map semantics
		expect(not Cosmetics.canEquip("NotASkin", { NotASkin = true }), "unknown stays unequippable even if 'owned'")
	end)
	test("cosmetics: ownedSkinIds returns sorted starter ∪ owned", function()
		local ids = Cosmetics.ownedSkinIds(nil)
		expect(#ids >= 6, "starter set missing")
		for i = 2, #ids do
			expect(ids[i - 1] < ids[i], "not sorted")
		end
	end)

	print("──────── Cosmetic neutrality (by construction) ────────")

	test("neutrality: identical seeds ± cosmetics → identical outcomes", function()
		-- Guards the GDD §14 invariant: if anyone ever wires a cosmetic into
		-- physics, this test breaks loudly.
		require(__tokens["ServerScriptService/BeyController"])
		require(__tokens["ServerScriptService/PhysicsController"])
		require(__tokens["ServerScriptService/SpinEvaluator"])
		local MatchState = require(__tokens["ReplicatedStorage/MatchState"])
		local MatchInstance = require(__tokens["ServerScriptService/MatchInstance"])

		local function runMatch(seed, withCosmetics)
			local state = MatchState.new(seed)
			state.matchId = "NeutralityTest"
			state.phase = "Active"
			state.isHeadless = true
			state.playerOrder = { 101, 102 }
			if withCosmetics then
				state.cosmetics = { [101] = "Solar", [102] = "Void" }
			end
			local inst = MatchInstance.fromState(state)
			local rng = inst.rng
			for i, pid in ipairs(state.playerOrder) do
				local side = (i == 1) and -1 or 1
				local b = MatchState.createBeyState(pid)
				b.position = Vector3.new(side * 10, 10, 0)
				local speed = 21 * rng:NextNumber(0.9, 1.1)
				local jitter = rng:NextNumber(-0.15, 0.15)
				b.velocity = Vector3.new(-side * math.cos(jitter) * speed, 0, side * math.sin(jitter) * speed)
				b.angularVelocity = Vector3.new(0, 100, 0)
				b.previousPosition = b.position
				state.beyStates[pid] = b
			end
			while state.phase ~= "Finished" and state.tickNumber < 5000 do
				inst:StepTick(true)
			end
			return tostring(state.currentWinner) .. ":" .. tostring(state.tickNumber)
		end

		for seed = 1, 30 do
			local bare = runMatch(seed * 7919, false)
			local skinned = runMatch(seed * 7919, true)
			expect(bare == skinned, string.format("seed %d diverged: %s vs %s", seed, bare, skinned))
		end
	end)

	print("──────── Stadium registry tests ────────")

	test("stadiums: Classic mirrors the validated Constants exactly", function()
		local classic = Stadiums.get("Classic")
		expect(classic.radius == Constants.StadiumRadius, "Classic radius must match the baseline")
		expect(classic.wallBounce == Constants.StadiumWallBounce, "Classic wall bounce must match the baseline")
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
		expect(not Stadiums.validate({ id = "X", radius = 4, wallBounce = 0.65 }), "radius too small")
		expect(not Stadiums.validate({ id = "X", radius = 22, wallBounce = 1.5 }), "wallBounce out of range")
		expect(not Stadiums.validate({ id = "", radius = 22, wallBounce = 0.65 }), "empty id")
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
