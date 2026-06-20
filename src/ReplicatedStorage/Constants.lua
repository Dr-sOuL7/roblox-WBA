local Constants = {
	-- ── Tick rates ────────────────────────────────────────────────────────────
	SimulationTickRate = 30,    -- Hz authoritative server simulation
	ReplicationTickRate = 15,   -- Hz snapshot broadcast (every 2nd sim tick)
	MaxCatchupTicks = 5,

	-- ── Launch ceremony ────────────────────────────────────────────────────────
	-- Setup (aim) → both READY → 3·2·1·GO → the Bey is fired into the flat arena
	-- with spin + forward momentum. Grading scales spin/impulse, bounded by the cap.
	LaunchBonusCap = 0.15,      -- ±15% cap on launch quality advantage
	PrototypeLaunchSpeed = 21,
	PrototypeLaunchSpin = 100,
	LaunchBaseSpin = 90,        -- baseline angular velocity (RPM proxy) granted on GO
	LaunchImpulseSpeed = 24,    -- initial forward velocity (studs/s) toward the centre

	LaunchPerfectWindow = 0.12,      -- s from GO → Perfect
	LaunchGoodWindow = 0.30,         -- s from GO → Good; beyond → Poor
	LaunchBonusPerfect = 0.15,       -- == LaunchBonusCap; the ceiling
	LaunchBonusGood = 0.07,
	LaunchBonusPoor = -0.08,         -- "a bad start, correspondingly"
	LaunchClaimSkewMax = 0.5,        -- s; max |claimed - receipt| accepted
	SetupTimeoutSeconds = 30,        -- auto-ready: AFK can't hold the match hostage
	AutoLaunchDelay = 2,             -- s after GO; missed clicks launch at Poor

	-- Aim slider ranges (the flat-arena launch keeps the azimuth as the aim).
	LaunchHeightMin = 6,
	LaunchHeightMax = 18,
	LaunchHeightDefault = 10,
	LaunchThetaMin = 45,
	LaunchThetaMax = 90,

	-- ── Multi-match server (ADR-001) ──────────────────────────────────────────
	-- One server simulates several concurrent matches. Each match gets an arena
	-- slot; physics runs in local arena-space and rendering offsets by the slot's
	-- world origin, so simulation math is identical in every slot.
	MaxConcurrentMatches = 4,
	ArenaSlotSpacing = 200,     -- studs between stadium origins on X
	ReconnectGraceSeconds = 20, -- a dropped player keeps their seat this long

	-- ── Arena geometry (flat, walled stadium — single source of truth) ─────────
	-- No bowl, no ring-out: a flat circular floor ringed by a wall. The Bey
	-- bounces off the wall (restitution), takes a small impact-scaled nick + tilt,
	-- and charges Mana. StadiumRadius is the default; each stadium may override it.
	BeyRadius            = 2,     -- collision radius used for overlap detection
	StadiumRadius        = 22,    -- flat circle radius (studs); wall sits here
	StadiumWallHeight    = 8,     -- visual wall height (studs)
	StadiumWallBounce    = 0.65,  -- restitution coefficient for wall bounce
	StadiumFloorFriction = 0.993, -- per-tick velocity decay on the flat floor

	-- Wall impact: a gentle touch barely matters, a full-speed dash into the wall
	-- stings. Scaled by inbound normal speed against WallImpactRefSpeed.
	WallImpactRefSpeed  = 42,     -- normal speed that yields the full base values
	WallHpDamageBase    = 1.6,    -- HP nick at reference inbound speed
	WallTiltBase        = 2.2,    -- degrees of wobble added at reference speed
	WallStabilityBase   = 0.6,    -- structural balance eroded at reference speed
	WallImpactMaxScale  = 1.6,    -- clamp on the speed scale (a wall can't one-shot)

	-- ── Collision ─────────────────────────────────────────────────────────────
	CollisionCooldownTicks = 5,
	TangentialEnergyRetention = 0.75,
	CollisionPushMultiplier = 0.8,
	CollisionPushMin = 10,
	CollisionPushMax = 60,       -- safety cap on knockback (no ring-out to regulate)
	CollisionSubSteps = 3,       -- Physics+Collision loop iterations per tick

	-- Damage variance: ±12.5% — skill over RNG.
	CollisionDamageVarianceMin = 0.875,
	CollisionDamageVarianceMax = 1.125,

	-- ── Physics decay ─────────────────────────────────────────────────────────
	-- AngularDecay per-tick at 30 Hz. ~0.9985 ⇒ natural spin lasts ~65 s at 1×
	-- Stamina — room for HP battles, while a low-Stamina build still feels the clock.
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
	StabilityDamageLight = 0.4,
	StabilityDamageHeavy = 1.3,
	StabilityDamageSmash = 2.8,

	-- ── Collision severity thresholds (impact speed) ──────────────────────────
	SmashSpeedThreshold = 50,
	HeavySpeedThreshold = 20,

	-- ══ HP system ═════════════════════════════════════════════════════════════
	BeyMaxHp          = 160,    -- baseline; scaled by the Stamina stat
	HpDamageLight     = 1.9,    -- baseline HP per Light collision (before stats/zone)
	HpDamageHeavy     = 4.3,    -- baseline HP per Heavy collision
	HpDamageSmash     = 8.6,    -- baseline HP per Smash collision
	HpDamageMaxFrac   = 0.12,   -- a single hit can never remove more than this fraction of max HP

	-- ══ Mana system ═══════════════════════════════════════════════════════════
	BeyMaxMana             = 100,
	StartingMana           = 25,    -- small opening reserve so the first move is possible
	ManaGainPerHit         = 8,     -- flat mana gained per Bey-vs-Bey collision (main charge)
	ManaGainWall           = 1,     -- mana from a wall bounce (small — walls aren't a free refuel)
	ManaRegenPerTick       = 0.8,   -- passive trickle while coasting (no ability held)
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
