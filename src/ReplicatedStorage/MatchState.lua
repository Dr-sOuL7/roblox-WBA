--[=[
    MatchState.lua
    Schema and factory for authoritative MatchState.
    IMPORTANT: This module contains NO LIVE STATE. It only defines structure and defaults.
]=]

local MatchState = {}

function MatchState.new(matchSeed: number)
    return {
        matchId = "",
        phase = "Setup", -- Setup (aim + ready), Countdown, Active, Finished
        tickNumber = 0,
        serverTimestamp = workspace:GetServerTimeNow(),
        matchSeed = matchSeed or os.time(), -- Deterministic RNG seed
        
        timers = {
            matchStart = 0,
            setupDeadline = 0,     -- auto-ready moment (synced server clock)
            countdownEndTime = 0,  -- the GO instant: launch grading anchor
            duration = 0,
        },
        activePlayers = {},
        beyStates = {}, -- mapping of playerId -> BeyState

        -- Launch ceremony (Setup phase)
        ready = {},      -- playerId -> true once they clicked READY
        pendingAim = {}, -- playerId -> clamped {height, theta, phi}; auto-launch fallback
        
        -- Artificial Collision Cooldown Map: e.g. ["idA_idB"] = remainingTicks
        collisionCooldowns = {}, 
        
        -- Event markers for this tick (flushed to ReplayRecorder at replication)
        tickEvents = {}, 

        telemetryRefs = {},
        replayRefs = {},
        currentWinner = nil,
        finishFlags = {},
        inputQueue = {},   -- Validated launch inputs: { inputSequenceId, playerId, data }
        commandQueue = {}, -- Validated command inputs: { playerId, command }
        playerOrder = {},  -- Sorted array of playerIds; set by MatchManager — canonical iteration order

        -- Multi-match additions (ADR-001)
        arenaOrigin = Vector3.new(0, 0, 0), -- world offset for rendering; sim stays local-space
        collisionSeqCounter = 0,            -- per-tick collision id sequence (was module state)
        stadiumId = "Classic",              -- registry key; physics resolves per-stadium params
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
        zoneState = "Active",      -- "Active" | "RingOut" | "Finished"
        -- Command state
        currentCommand = nil,      -- nil | "Attack" | "Defend" | "Evade"
        commandTimer = 0,          -- ticks remaining on active command
        commandCooldownTimer = 0,  -- ticks until next command is allowed
        launchConsumed = false,    -- single-fire guard: only one launch per match
        launchQuality = nil,       -- nil | "Perfect" | "Good" | "Poor" (set on launch)
        -- Ring-out state
        ringOutTimer = 0,          -- ticks spent past the rim (grace period counter)
        finishReason = nil,        -- "SpinOut" | "WobbleCollapse" | "RingOut"
    }
end

function MatchState.validate(stateInstance)
    assert(type(stateInstance.tickNumber) == "number", "Invalid tickNumber")
    return true
end

return MatchState
