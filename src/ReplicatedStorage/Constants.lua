local Constants = {
	-- ── Tick rates ────────────────────────────────────────────────────────────
	SimulationTickRate = 30,    -- Hz authoritative server simulation
	ReplicationTickRate = 15,   -- Hz snapshot broadcast (every 2nd sim tick)
	MaxCatchupTicks = 5,

	-- ── Launch ────────────────────────────────────────────────────────────────
	-- Launch is now a flat-spawn "GO": the Bey is fired into the arena with spin
	-- and forward momentum (real-world physics carries it from there).
	LaunchBonusCap = 0.15,      -- ±15% cap on launch quality advantage
	LaunchBaseSpin = 90,        -- base angular velocity (RPM proxy) granted on GO
	LaunchImpulseSpeed = 24,    -- initial forward velocity (studs/s) toward the centre
	StartingMana = 25,          -- small opening reserve so the first move is possible

	-- ── Arena geometry (single source of truth) ───────────────────────────────
	-- Flat, walled circular stadium. No bowl, no ring-out.
	BeyRadius          = 2,     -- collision radius used for overlap detection
	StadiumRadius      = 22,    -- flat circle radius (studs); wall sits here
	StadiumWallHeight  = 8,     -- visual wall height (studs)
	StadiumWallBounce  = 0.65,  -- restitution coefficient for wall bounce
	StadiumFloorFriction = 0.993, -- per-tick velocity decay on the flat floor

	-- ── Collision ─────────────────────────────────────────────────────────────
	CollisionCooldownTicks = 5,
	TangentialEnergyRetention = 0.75,
	CollisionPushMultiplier = 0.8,
	CollisionPushMin = 10,
	CollisionSubSteps = 3,       -- Physics+Collision loop iterations per tick

	-- Damage variance: ±12.5% — skill over RNG.
	CollisionDamageVarianceMin = 0.875,
	CollisionDamageVarianceMax = 1.125,

	-- ── Physics decay ─────────────────────────────────────────────────────────
	-- AngularDecay per-tick at 30 Hz. ~0.9985 ⇒ natural spin lasts ~65s at 1× Stamina —
	-- enough room for HP battles, while a low-Stamina build still feels the clock.
	AngularDecay = 0.9985,
	VelocityClampMax = 200,
	PostCollisionVelocityClamp = 150,

	-- ── Wobble / destabilization ──────────────────────────────────────────────
	WobbleAmplification = 15,
	WobbleTiltRecoveryRate = 9,
	TiltCollapseThreshold = 110, -- tilt above this collapses into a SpinOut topple

	-- ── Spin & Stability ──────────────────────────────────────────────────────
	MinEffectiveSpinThreshold = 5,
	CriticalSpinWindow = 0.35,
	BaseStability = 100,
	-- Base structural-balance damage per severity (low/tip hits scale these up)
	StabilityDamageLight = 0.4,
	StabilityDamageHeavy = 1.3,
	StabilityDamageSmash = 2.8,

	-- ── Collision severity thresholds (impact speed) ──────────────────────────
	SmashSpeedThreshold = 50,
	HeavySpeedThreshold = 20,

	-- ══ HP system ═════════════════════════════════════════════════════════════
	BeyMaxHp          = 160,    -- baseline; scaled by the Stamina stat
	HpDamageLight     = 1.0,    -- baseline HP per Light collision (before stats/zone)
	HpDamageHeavy     = 2.5,    -- baseline HP per Heavy collision
	HpDamageSmash     = 6,      -- baseline HP per Smash collision
	HpDamageMaxFrac   = 0.10,   -- a single hit can never remove more than this fraction of max HP

	-- ══ Mana system ═══════════════════════════════════════════════════════════
	BeyMaxMana             = 100,
	ManaGainPerHit         = 8,     -- flat mana gained per Bey-vs-Bey collision (main charge)
	ManaGainWall           = 1,     -- mana from a wall bounce (small — walls aren't a free refuel)
	ManaRegenPerTick       = 0.8,   -- passive trickle while coasting (no ability held) → defense can sustain
	ManaCostDashPerTick    = 2.6,   -- mana drained while Dash held (per sim tick)
	ManaCostRevolvePerTick = 1.4,   -- mana drained while Revolve held (per sim tick)

	-- ══ Dash ══════════════════════════════════════════════════════════════════
	DashBaseSpeed       = 21,    -- base speed reference (avoids 3× near-zero)
	DashSpeedMultiplier = 3.0,   -- dash drives the Bey to 3× base speed in facing dir

	-- ══ Revolve ═══════════════════════════════════════════════════════════════
	RevolveOrbitRadius   = 18,   -- studs from centre (near the wall edge)
	RevolveOrbitSpeed    = 19,   -- tangential orbit speed (studs/s)
	RevolveRadialPull    = 6,    -- how hard centripetal force snaps toward orbit radius
	RevolveComboMultiplier = 3.0, -- Dash+Revolve held together → revolve at 3× speed

	-- ══ Facing / Steering ═════════════════════════════════════════════════════
	FacingTurnSpeed = math.pi * 4, -- rad/s max turn rate (~2 full turns/s) at 1× Agility

	-- ── Hitstop ───────────────────────────────────────────────────────────────
	HitstopHeavy = 0.04,
	HitstopSmash = 0.08,
	HitstopDurationRange = { Min = 0.03, Max = 0.06 },

	-- ── Interpolation ─────────────────────────────────────────────────────────
	InterpolationDelay = 0.15,
	SnapshotBufferMax = 20,

	-- ── Audio ─────────────────────────────────────────────────────────────────
	SpinDownAudioThreshold = 30,
}

return Constants
