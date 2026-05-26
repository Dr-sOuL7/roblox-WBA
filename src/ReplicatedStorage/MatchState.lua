--[=[
    MatchState.lua
    Schema and factory for authoritative MatchState.
    IMPORTANT: This module contains NO LIVE STATE. It only defines structure and defaults.
]=]

local MatchState = {}

function MatchState.new(matchSeed: number)
    return {
        matchId = "",
        phase = "Countdown", -- Countdown, Active, Finished
        tickNumber = 0,
        serverTimestamp = workspace:GetServerTimeNow(),
        matchSeed = matchSeed or os.time(), -- Deterministic RNG seed
        
        timers = {
            matchStart = 0,
            countdownEndTime = 0,
            duration = 0,
        },
        activePlayers = {},
        beyStates = {}, -- mapping of playerId -> BeyState
        
        -- Artificial Collision Cooldown Map: e.g. ["idA_idB"] = remainingTicks
        collisionCooldowns = {}, 
        
        -- Event markers for this tick (flushed to ReplayRecorder at replication)
        tickEvents = {}, 

        telemetryRefs = {},
        replayRefs = {},
        currentWinner = nil,
        finishFlags = {},
        inputQueue = {}, -- Validated inputs: { inputSequenceId, playerId, data }
    }
end

function MatchState.createBeyState(playerId: number)
    return {
        playerId = playerId,
        position = Vector3.new(0, 5, 0),
        previousPosition = Vector3.new(0, 5, 0),
        velocity = Vector3.new(0, 0, 0),
        angularVelocity = Vector3.new(0, 50, 0), -- Initial RPM proxy
        tilt = 0,
        stability = 100,
        momentum = 0,
        heat = 0,
        criticalSpinTimer = 0,
        collisionFlags = {},
        zoneState = "Center",
    }
end

function MatchState.validate(stateInstance)
    assert(type(stateInstance.tickNumber) == "number", "Invalid tickNumber")
    return true
end

return MatchState
