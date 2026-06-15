--[=[
    DebugStatePublisher.lua
    Publishes real-time state snapshots to each match's PARTICIPANTS.
    (Multi-match: broadcasting every match to every client both leaks state and
    wastes bandwidth. Phase 5 spectators subscribe here later.)
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local DebugStatePublisher = {}

function DebugStatePublisher.OnReplicationPhase(matchState)
    local snapshot = {
        matchId = matchState.matchId,
        stadiumId = matchState.stadiumId,
        arenaOrigin = matchState.arenaOrigin,
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

    -- STRING keys: Roblox remote serialization converts numeric dictionary
    -- keys to strings on the receiving side; sending them as strings makes
    -- both sides agree instead of silently mismatching client lookups.
    for _, pid in ipairs(matchState.playerOrder) do
        local bState = matchState.beyStates[pid]
        snapshot.beyStates[tostring(pid)] = {
            position = bState.position,
            velocity = bState.velocity,
            angularVelocity = bState.angularVelocity,
            tilt = bState.tilt,
            stability = bState.stability,
            zoneState = bState.zoneState,
            currentCommand = bState.currentCommand,
            commandCooldownTimer = bState.commandCooldownTimer,
        }
    end

    for _, pid in ipairs(matchState.playerOrder) do
        local player = Players:GetPlayerByUserId(pid)
        if player then
            Remotes.StateSnapshot:FireClient(player, snapshot)
        end
    end
end

TickManager.RegisterHandler("Replication", DebugStatePublisher.OnReplicationPhase)

return DebugStatePublisher
