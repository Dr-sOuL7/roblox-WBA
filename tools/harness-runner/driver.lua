--[=[
	driver.lua — entry point appended after the wrapped game modules.

	Usage (via build_runner.py):
	  suite [baselineCount] [matrixCount]      -- full Phase 1 validation suite
	  batch [count] [policyA] [policyB] [seed] -- single batch
]=]

-- Mirror Main.server.lua load order, minus the Replication-phase modules
-- (TelemetryLogger / ReplayRecorder / DebugStatePublisher). The Replication
-- phase never executes under TickManager.Step(true), so this matches live
-- headless behaviour exactly.
require(__tokens["ServerScriptService/BeyController"])
require(__tokens["ServerScriptService/PhysicsController"])
require(__tokens["ServerScriptService/SpinEvaluator"])

local SimulationHarness = require(__tokens["ServerScriptService/SimulationHarness"])

local args = { ... }
local mode = args[1] or "suite"

if mode == "suite" then
	local suiteOptions = {
		baselineCount = tonumber(args[2]) or 1000,
		matrixCount = tonumber(args[3]) or 200,
	}
	local results = SimulationHarness.RunValidationSuite(suiteOptions)
	if not results.allPass then
		error("Validation suite reported NO-GO", 0)
	end
elseif mode == "batch" then
	SimulationHarness.RunBatch(tonumber(args[2]) or 100, {
		policyA = args[3] or "None",
		policyB = args[4] or "None",
		baseSeed = tonumber(args[5]),
	})
else
	error("Unknown mode: " .. tostring(mode) .. " (expected 'suite' or 'batch')", 0)
end
