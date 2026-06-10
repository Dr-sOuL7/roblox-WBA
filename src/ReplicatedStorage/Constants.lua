local Constants = {
	-- ── Tick rates ────────────────────────────────────────────────────────────
	SimulationTickRate = 30,    -- Hz authoritative server simulation
	ReplicationTickRate = 15,   -- Hz snapshot broadcast (every 2nd sim tick)
	MaxCatchupTicks = 5,

	-- ── Launch ────────────────────────────────────────────────────────────────
	LaunchBonusCap = 0.15,      -- ±15% cap on launch quality advantage

	-- ── Arena geometry (single source of truth) ───────────────────────────────
	-- R=50 sphere subtracted from a block gives the curvy bowl floor.
	-- MAX_R=20 is the XZ playable radius before ring-out triggers.
	-- BeyRadius is the collision radius used for overlap detection.
	BowlSphereRadius = 50,
	BowlPlayableRadius = 20,
	BowlRimBuffer = 0.8,        -- BeyRadius multiplier; softens rim edge
	BeyRadius = 2,

	-- ── Collision ─────────────────────────────────────────────────────────────
	CollisionCooldownTicks = 2,
	TangentialEnergyRetention = 0.75,
	CollisionPushMultiplier = 0.8,
	CollisionPushMin = 10,
	CollisionSubSteps = 3,       -- Physics+Collision loop iterations per tick

	-- Damage variance: was 0.5–1.5 (3× swing). Now ±12.5% — skill over RNG.
	CollisionDamageVarianceMin = 0.875,
	CollisionDamageVarianceMax = 1.125,

	-- ── Physics forces ────────────────────────────────────────────────────────
	-- FrictionDecay and AngularDecay are expressed per-tick at 30 Hz.
	-- Derivation: old 10 Hz value^(10/30) preserves identical decay-per-second.
	--   FrictionDecay:  0.98^(10/30) = 0.9932
	--   AngularDecay:   0.99^(10/30) = 0.9966
	Gravity = 50,
	FrictionDecay = 0.9932,
	BowlForce = 6,
	VelocityClampMax = 200,
	PostCollisionVelocityClamp = 150,

	-- ── Angular & Wobble ──────────────────────────────────────────────────────
	AngularDecay = 0.9966,
	WobbleAmplification = 25,
	WobbleTiltRecoveryRate = 8,
	WobbleCollapseThreshold = 80,

	-- ── Spin & Stability ──────────────────────────────────────────────────────
	MinEffectiveSpinThreshold = 5,
	CriticalSpinWindow = 0.35,
	BaseStability = 100,
	StabilityDamageLight = 2,
	StabilityDamageHeavy = 10,
	StabilityDamageSmash = 25,
	SpinDamageMultiplierHeavy = 0.9,
	SpinDamageMultiplierSmash = 0.8,

	-- ── Ring-out ──────────────────────────────────────────────────────────────
	RingOutGraceTicks = 10,      -- ~0.33 s at 30 Hz; Bey must stay outside to finish

	-- ── Battle commands ───────────────────────────────────────────────────────
	CommandDurationTicks = 15,          -- 0.5 s at 30 Hz
	CommandCooldownTicks = 30,          -- 1.0 s at 30 Hz; 33% uptime prevents spam
	CommandAttackForce = 35,
	CommandDefendForce = 15,            -- supplements BowlForce; was 30 (too strong)
	CommandEvadeForce = 30,
	CommandStabilityRecoveryBonus = 0.15,  -- Defend: +15% tilt recovery rate
	CommandRecoilMultiplier = 1.2,         -- Attack: recoil amplifier on collision

	-- ── Hitstop ───────────────────────────────────────────────────────────────
	HitstopHeavy = 0.04,
	HitstopSmash = 0.08,
	HitstopDurationRange = { Min = 0.03, Max = 0.06 },

	-- ── Interpolation ─────────────────────────────────────────────────────────
	-- 150 ms = 2.25 snapshots at 15 Hz — comfortable jitter headroom
	InterpolationDelay = 0.15,
	SnapshotBufferMax = 20,

	-- ── Collision severity thresholds (impact speed) ──────────────────────────
	SmashSpeedThreshold = 50,
	HeavySpeedThreshold = 20,

	-- ── Audio ─────────────────────────────────────────────────────────────────
	SpinDownAudioThreshold = 30,
}

return Constants
