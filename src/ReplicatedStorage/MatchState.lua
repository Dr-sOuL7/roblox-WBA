--[=[
    MatchState.lua
    Schema and factory for authoritative MatchState.
    IMPORTANT: This module contains NO LIVE STATE. It only defines structure and defaults.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local BeyParts = require(ReplicatedStorage:WaitForChild("BeyParts"))

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
        inputBuffer = {},  -- Latest validated analog input per player: [pid] = { facingAngle, dash, revolve }
        playerOrder = {},  -- Sorted array of playerIds; set by MatchManager — canonical iteration order

        -- Multi-match additions (ADR-001)
        arenaOrigin = Vector3.new(0, 0, 0), -- world offset for rendering; sim stays local-space
        collisionSeqCounter = 0,            -- per-tick collision id sequence (was module state)
        stadiumId = "Classic",              -- registry key; physics resolves per-stadium params
        stadiumRadius = Constants.StadiumRadius,     -- flat play radius (MatchManager sets per stadium)
        stadiumWallBounce = Constants.StadiumWallBounce,
    }
end

-- playerId, [build]: the crafted build (gallant catalog) drives BOTH the 4 stats
-- (deriveStats) and the part-based damage profile (computeProfile). Defaults to
-- the neutral build → all mods 1.0 → validated baseline.
function MatchState.createBeyState(playerId: number, build)
    local profile = BeyParts.computeProfile(build or BeyParts.defaultBuild())
    local maxHp = BeyParts.maxHpFor(profile, Constants.BeyMaxHp)

    return {
        playerId = playerId,
        position = Vector3.new(0, Constants.BeyRadius, 0),
        previousPosition = Vector3.new(0, Constants.BeyRadius, 0),
        velocity = Vector3.new(0, 0, 0),
        angularVelocity = Vector3.new(0, 0, 0), -- spun up on launch/GO
        tilt = 0,
        stability = Constants.BaseStability, -- structural balance; low/tip hits erode it → wobble
        momentum = 0,
        heat = 0,
        criticalSpinTimer = 0,
        collisionFlags = {},
        zoneState = "Active", -- "Active" | "Finished"

        -- ── HP system ──
        hp = maxHp,
        maxHp = maxHp,

        -- ── Mana system ──
        mana = Constants.StartingMana,
        maxMana = Constants.BeyMaxMana,

        -- ── Facing & abilities (replaces A/D/E commands) ──
        facingAngle = 0,        -- radians; the Bey's actual (smoothed) facing; 0 = +X
        targetFacing = 0,       -- radians; raw joystick target — facingAngle turns toward this
        isDashing = false,      -- true while DASH held (and mana > 0)
        isRevolving = false,    -- true while REVOLVE held (and mana > 0)

        -- ── Craft profile (ADR-003) ──
        mods = profile.mods,    -- { Attack, Defense, Stamina, Agility }
        profile = profile,      -- physical part profile for the damage model

        launchConsumed = false, -- single-fire guard: only one launch per match
        launchQuality = nil,    -- nil | "Perfect" | "Good" | "Poor" (set on launch)
        finishReason = nil,     -- "HpBreak" | "SpinOut"
    }
end

function MatchState.validate(stateInstance)
    assert(type(stateInstance.tickNumber) == "number", "Invalid tickNumber")
    return true
end

return MatchState
