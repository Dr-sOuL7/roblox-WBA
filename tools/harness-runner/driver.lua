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
		})
	end

elseif mode == "persistence" then
	local ProfileLogic = require(__tokens["ServerScriptService/Persistence/ProfileLogic"])
	local ProfileSchema = require(__tokens["ServerScriptService/Persistence/ProfileSchema"])

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

	finishTests("Persistence logic tests")

else
	error("Unknown mode: " .. tostring(mode) .. " (expected 'suite', 'batch' or 'persistence')", 0)
end
