--[=[
    DebugStatePublisher.lua
    Publishes real-time state snapshots to clients.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local DebugStatePublisher = {}

function DebugStatePublisher.OnReplicationPhase(matchState)
    local snapshot = {
        tickNumber = matchState.tickNumber,
        serverTimestamp = matchState.serverTimestamp,
        beyStates = {},
        events = {}
    }
    
    for _, ev in ipairs(matchState.tickEvents) do
        table.insert(snapshot.events, {
            eventType = ev.eventType,
            eventData = ev.eventData 
        })
    end
    
    for _, pid in ipairs(matchState.playerOrder) do
        local bState = matchState.beyStates[pid]
        snapshot.beyStates[pid] = {
            position = bState.position,
            velocity = bState.velocity,
            angularVelocity = bState.angularVelocity,
            tilt = bState.tilt,
            stability = bState.stability,
            zoneState = bState.zoneState,
            -- HP / Mana / control state for the new HUD and renderer
            hp = bState.hp,
            maxHp = bState.maxHp,
            mana = bState.mana,
            maxMana = bState.maxMana,
            facingAngle = bState.facingAngle,
            isDashing = bState.isDashing,
            isRevolving = bState.isRevolving,
            finishReason = bState.finishReason,
        }
    end
    
    Remotes.StateSnapshot:FireAllClients(snapshot)
end

TickManager.RegisterHandler("Replication", DebugStatePublisher.OnReplicationPhase)

return DebugStatePublisher
