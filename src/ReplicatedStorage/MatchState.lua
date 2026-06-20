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
        inputQueue = {},   -- Validated launch inputs: { inputSequenceId, playerId, data }
        inputBuffer = {},  -- Latest validated analog input per player: [pid] = { facingAngle, dash, revolve }
        playerOrder = {},  -- Sorted array of playerIds; set by MatchManager — canonical iteration order
    }
end

-- playerId, [loadout]: the part loadout drives stats + the part-based damage profile.
function MatchState.createBeyState(playerId: number, loadout)
    local profile = BeyParts.computeProfile(loadout)
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
        loadout = profile.loadout,
        mods = profile.mods,           -- { Attack, Defense, Stamina, Agility }
        profile = profile,             -- physical part profile for the damage model

        launchConsumed = false,        -- single-fire guard: only one launch per match
        launchQuality = nil,
        finishReason = nil,            -- "HpBreak" | "SpinOut"
    }
end

function MatchState.validate(stateInstance)
    assert(type(stateInstance.tickNumber) == "number", "Invalid tickNumber")
    return true
end

return MatchState
