local Constants = {
	-- Tick rates decoupled
	SimulationTickRate = 10, -- Hz
	ReplicationTickRate = 10, -- Hz
	MaxCatchupTicks = 5, -- Drift protection

	-- Launch Bonus
	LaunchBonusCap = 0.15, -- +/- 15% cap

	-- Physics & Core Mechanics
	BeyRadius = 2,
	CollisionCooldownTicks = 2, -- Prevent spam but allow chained clashes (1-2 ticks)
	TangentialEnergyRetention = 0.75, -- Prevent infinite orbits (tunable 0.65-0.85)

	-- Physics Forces
	FrictionDecay = 0.98, -- Per-tick velocity multiplier
	BowlForce = 6, -- Gentle drift toward center
	VelocityClampMax = 200, -- Hard cap in ClampPhase
	PostCollisionVelocityClamp = 150, -- Immediate post-recoil cap
	CollisionPushMultiplier = 0.8, -- impactSpeed * this = push force
	CollisionPushMin = 10, -- Minimum push force

	-- Angular & Wobble
	AngularDecay = 0.99, -- Per-tick angular velocity multiplier
	WobbleAmplification = 25, -- Tilt escalation rate when unstable
	WobbleTiltRecoveryRate = 5, -- Tilt recovery per second during stable motion
	WobbleCollapseThreshold = 80, -- Tilt degrees that trigger elimination

	-- Spin & Stability
	MinEffectiveSpinThreshold = 5, -- Finish limit instead of strict 0
	CriticalSpinWindow = 0.35, -- Delay before elimination to create readable collapse
	BaseStability = 100,
	StabilityDamageLight = 2,
	StabilityDamageHeavy = 10,
	StabilityDamageSmash = 25,
	SpinDamageMultiplierHeavy = 0.9, -- 10% spin loss on heavy
	SpinDamageMultiplierSmash = 0.8, -- 20% spin loss on smash

	-- Hitstop (visual microfreeze on collision, seconds)
	HitstopHeavy = 0.04,
	HitstopSmash = 0.08,
	HitstopDurationRange = { Min = 0.03, Max = 0.06 }, -- Legacy range

	-- Interpolation
	InterpolationDelay = 0.1, -- 100ms render buffer
	SnapshotBufferMax = 20,

	-- Collision Severity Thresholds (impact speed)
	SmashSpeedThreshold = 50,
	HeavySpeedThreshold = 20,

	-- Spin-down Audio
	SpinDownAudioThreshold = 30, -- Angular velocity below this triggers spin-down sound
}

return Constants
