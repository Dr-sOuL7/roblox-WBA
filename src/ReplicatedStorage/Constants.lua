local Constants = {
    -- Tick rates decoupled
    SimulationTickRate = 10, -- Hz
    ReplicationTickRate = 10, -- Hz 
    MaxCatchupTicks = 5,     -- Drift protection

    -- Launch Bonus
    LaunchBonusCap = 0.15, -- +/- 15% cap

    -- Physics & Core Mechanics
    BeyRadius = 2,
    HitstopDurationRange = { Min = 0.03, Max = 0.06 }, -- Seconds
    CollisionCooldownTicks = 2, -- Prevent spam but allow chained clashes (1-2 ticks)
    TangentialEnergyRetention = 0.75, -- Prevent infinite orbits (tunable 0.65-0.85)

    -- Spin & Stability
    MinEffectiveSpinThreshold = 5, -- Finish limit instead of strict 0
    CriticalSpinWindow = 0.35, -- Delay before elimination to create readable collapse
    BaseStability = 100,
    StabilityDamageLight = 2,
    StabilityDamageHeavy = 10,
    StabilityDamageSmash = 25,
}

return Constants
