--[=[
    ReplayRecorder.lua
    Handles state snapshot logging.
    Stores only primitive data (NO Roblox Instances).
    
    NOTE: Currently storing Vector3 directly for Prototype 1 convenience.
    Future optimization: Serialize to {x,y,z} for true cross-session replay exportability.
]=]
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local ReplayRecorder = {}
ReplayRecorder.BUFFER_SIZE = 1200 -- 120 seconds at 10 Hz
local _buffer = {}

function ReplayRecorder.OnReplicationPhase(matchState)
    -- Serialize state into primitives
    local snapshot = {
        tickNumber = matchState.tickNumber,
        serverTimestamp = matchState.serverTimestamp,
        events = {},
        beyStates = {}
    }
    
    for _, ev in ipairs(matchState.tickEvents) do
        table.insert(snapshot.events, {
            eventType = ev.eventType,
            eventData = ev.eventData 
        })
    end
    
    for pid, state in pairs(matchState.beyStates) do
        snapshot.beyStates[pid] = {
            position = state.position,
            velocity = state.velocity,
            angularVelocity = state.angularVelocity,
            tilt = state.tilt,
            stability = state.stability,
            zoneState = state.zoneState,
        }
    end
    
    table.insert(_buffer, snapshot)
    
    if #_buffer > ReplayRecorder.BUFFER_SIZE then
        table.remove(_buffer, 1)
    end
end

TickManager.RegisterHandler("Replication", ReplayRecorder.OnReplicationPhase)

return ReplayRecorder
