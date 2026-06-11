local Constants = {
	-- ── Tick rates ────────────────────────────────────────────────────────────
	SimulationTickRate = 30,    -- Hz authoritative server simulation
	ReplicationTickRate = 15,   -- Hz snapshot broadcast (every 2nd sim tick)
	MaxCatchupTicks = 5,

	-- ── Launch ────────────────────────────────────────────────────────────────
	LaunchBonusCap = 0.15,      -- ±15% cap on launch quality advantage

	-- Prototype fixed launch (Phase 2 replaces this with the quality-tier system).
	-- Client aims at the bowl centre from its own spawn; same numbers feed the
	-- harness so headless matches model exactly what live testers play.
	PrototypeLaunchSpeed = 21,
	PrototypeLaunchSpin = 100,

	-- Pre-launch spawn drift (server-set at spawn, overridden by the launch).
	-- Tangential 15 + inward 5 keeps an idle Bey orbiting INSIDE the bowl:
	-- the old (0,0,±60) tangential spawn reached the rim in 0.26 s and
	-- self-ring-outed any player who didn't launch within the first second.
	SpawnTangentialSpeed = 15,
	SpawnInwardSpeed = 5,

	-- ── Multi-match server (ADR-001) ──────────────────────────────────────────
	-- One server simulates several concurrent matches. Each match gets an
	-- arena slot; physics runs in local bowl-space and rendering offsets by
	-- the slot's world origin, so simulation math is identical in every slot.
	MaxConcurrentMatches = 4,
	ArenaSlotSpacing = 200,     -- studs between stadium origins on X

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
	-- Knockback cap — THE ring-out regulator. Bowl escape speed from centre is
	-- ~22 studs/s (rim height 3.5 → sqrt(2·g·h) ≈ 19, plus grace-window slack).
	-- Uncapped push (impact 140 × 0.8 = 112) ejected BOTH beys on the first
	-- smash: 85% mutual-ring-out draws at 0.6 s in the harness. 21 sits just
	-- UNDER escape: plain hits stay contained, while an Attacker's recoil
	-- (× CommandRecoilMultiplier 1.2 = 25.2) crosses it — ring-out risk
	-- attaches to aggression and rim adjacency, per the design. Harness-tuned:
	-- 20 → 6% ring-outs, 24 → 92%; 21 lands the 10–30% band.
	CollisionPushMax = 21,
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
	BowlForce = 7,
	VelocityClampMax = 200,
	PostCollisionVelocityClamp = 150,

	-- ── Angular & Wobble ──────────────────────────────────────────────────────
	AngularDecay = 0.9966,
	WobbleAmplification = 28,
	WobbleTiltRecoveryRate = 8,
	WobbleCollapseThreshold = 70,

	-- ── Spin & Stability ──────────────────────────────────────────────────────
	MinEffectiveSpinThreshold = 5,
	-- Damaged Beys spin down faster: at stability 0 the angular decay exponent
	-- grows by this fraction (linear from 1.0 at full stability). Deterministic
	-- skill-linked separation — the Bey that took more hits dies first — which
	-- collapsed the structural double-SpinOut draw rate in mirror matches.
	StabilitySpinDrainMax = 0.12,
	CriticalSpinWindow = 0.35,
	BaseStability = 100,
	StabilityDamageLight = 3,
	StabilityDamageHeavy = 15,
	StabilityDamageSmash = 30,
	SpinDamageMultiplierHeavy = 0.93,
	SpinDamageMultiplierSmash = 0.8,

	-- ── Ring-out ──────────────────────────────────────────────────────────────
	-- 15 ticks = 0.5 s at 30 Hz. The original 10 (~0.33 s) was flagged as too
	-- short to react at 200 ms latency, and harness showed glancing rim
	-- excursions converting to deaths: Defend's centre pull needs the extra
	-- window to function as a save. Live dial — tune from playtests.
	RingOutGraceTicks = 15,

	-- ── Battle commands ───────────────────────────────────────────────────────
	CommandDurationTicks = 15,          -- 0.5 s at 30 Hz
	CommandCooldownTicks = 30,          -- 1.0 s at 30 Hz; 33% uptime prevents spam
	-- Steering forces are sized against the ~22 studs/s bowl-escape speed:
	-- one full command adds force × 0.5 s of velocity. The old values
	-- (35/30, tuned for uncapped physics) added ~17 studs/s per press and
	-- turned commands into self-ring-out buttons — harness showed 96.5%
	-- ring-out finishes at 6.5 s average. Current values steer, not eject.
	CommandAttackForce = 20,
	CommandDefendForce = 15,            -- supplements BowlForce; centre-pull is safe
	CommandEvadeForce = 17,
	-- Evade dodge direction blend (normalized): mostly tangential sidestep,
	-- some radial separation. See PhysicsController's matador-dodge comment.
	EvadeRadialWeight = 0.35,
	EvadeTangentialWeight = 0.65,
	CommandStabilityRecoveryBonus = 0.15,  -- Defend: +15% tilt recovery rate
	CommandRecoilMultiplier = 1.2,         -- Attack recoil: 21 × 1.2 = 25.2 > bowl escape — see CollisionPushMax

	-- ── Hitstop ───────────────────────────────────────────────────────────────
	HitstopHeavy = 0.04,
	HitstopSmash = 0.08,
	HitstopDurationRange = { Min = 0.03, Max = 0.06 },

	-- ── Interpolation ─────────────────────────────────────────────────────────
	-- 150 ms = 2.25 snapshots at 15 Hz — comfortable jitter headroom
	InterpolationDelay = 0.15,
	SnapshotBufferMax = 20,

	-- ── Collision severity thresholds (impact speed) ──────────────────────────
	-- Calibrated to the contained-physics impact distribution (typical clash
	-- 20–45 studs/s relative): below 28 = glancing Light, 28–50 = committed
	-- Heavy, 50+ = Smash (reachable mainly through Attack acceleration, which
	-- makes big hits a skill statement rather than ambient noise).
	SmashSpeedThreshold = 50,
	HeavySpeedThreshold = 28,

	-- ── Audio ─────────────────────────────────────────────────────────────────
	SpinDownAudioThreshold = 30,
}

return Constants
