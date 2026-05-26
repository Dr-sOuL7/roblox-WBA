--[=[
    TelemetryLogger.lua
    Collects per-match metrics.
]=]
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local TelemetryLogger = {}

function TelemetryLogger.OnReplicationPhase(matchState)
    -- Only log at end of match for now
    if matchState.phase == "Finished" then
        print("Telemetry: Match finished! Winner:", matchState.currentWinner)
        print("Total ticks:", matchState.tickNumber)
    end
end

TickManager.RegisterHandler("Replication", TelemetryLogger.OnReplicationPhase)

return TelemetryLogger
