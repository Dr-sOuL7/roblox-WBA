# BEY ARENA — Phase 1 Implementation Walkthrough

## What was done

Phase 1 closes the gap between the launch-and-watch prototype and the target gameplay loop:

> **launch → command → collide reliably → wobble → spin finish or ring-out → rematch**

All 12 steps were completed in dependency order. No new mechanics were invented. Every change maps directly to a risk or improvement identified in the architecture review.

---

## Step-by-step changes

### Step 1 — Gate the headless simulation flag
**File:** `src/ServerScriptService/Main.server.lua`

- `RUN_SIMULATION_ON_START = true` was shipping hot and blocking all live play.
- Replaced with `HEADLESS_MODE = false and RunService:IsStudio()` — the double-gate (`false and`) means it can never accidentally be `true` in production even if the Studio check somehow passes.
- Added a `matchInProgress` flag to prevent overlapping match starts when a second player joins during the 2-second startup delay.
- Added `MatchManager.OnMatchCleanedUp` callback hook so `matchInProgress` resets correctly after each match ends.
- `_G.RunSimulation(N)` still works from the Studio command bar on demand.

---

### Step 2 — Deterministic simulation
**Files:** `src/ReplicatedStorage/MatchState.lua`, `src/ServerScriptService/MatchManager.lua`, and every module that iterated `matchState.beyStates`

The root cause: `pairs()` over a table keyed by `userId` has no guaranteed iteration order. Same seed → different RNG draw sequence → different outcomes.

- Added `playerOrder = {}` and `commandQueue = {}` to `MatchState.new()`.
- `MatchManager.StartNewMatch` builds `playerOrder` as a sorted copy of `playerIds` before any logic runs.
- Every `for pid, bState in pairs(matchState.beyStates)` in every module replaced with `for _, pid in ipairs(matchState.playerOrder)`.

**Files changed:** `PhysicsController`, `BeyController`, `SpinEvaluator`, `ReplayRecorder`, `TelemetryLogger`, `DebugStatePublisher`.

---

### Step 3 — Arena constants consolidated
**Files:** `src/ReplicatedStorage/Constants.lua`, `src/ServerScriptService/PhysicsController.lua`, `src/ServerScriptService/MatchManager.lua`

Three sources of truth for the arena radius (`BowlRadius = 12` in Constants unused; `R = 50`, `MAX_R = 20` hardcoded in two files).

- Removed `BowlRadius = 12`.
- Added `BowlSphereRadius = 50` and `BowlPlayableRadius = 20` to Constants.
- Both PhysicsController and MatchManager now reference Constants. MatchManager gained the `Constants` require it was missing.
- All new Phase 1 constants added in one place: ring-out, command system, sub-stepping, networking, balance.

---

### Step 4 — Friction and angular decay recalculation
**File:** `src/ReplicatedStorage/Constants.lua`

`FrictionDecay = 0.98` and `AngularDecay = 0.99` were tuned at 10 Hz. Applying them at 30 Hz would make Beys decelerate 3× faster.

Formula: `newDecay = oldDecay ^ (oldHz / newHz)`

| Constant | Old (10 Hz) | New (30 Hz) |
|----------|-------------|-------------|
| FrictionDecay | 0.98 | 0.9932 |
| AngularDecay | 0.99 | 0.9966 |

Both preserve identical decay-per-second across the tick rate change.

---

### Step 5 — Sub-stepping (collision tunneling fix)
**Files:** `src/ServerScriptService/PhysicsController.lua`, `src/ServerScriptService/BeyController.lua`

The old architecture: positions updated in `StateUpdate` (after collision). Collision checked at previous-tick positions. At 10 Hz a Bey moving 60 studs/s could skip clean through another in a single tick.

The new architecture (inside `OnPhysicsPhase`):

```
for step = 1, CollisionSubSteps (3) do
    integrate position
    apply gravity
    floor clamp (spherical bowl)
    friction
    bowl drift
    command steering forces   ← new
    rim / ring-out check      ← new
    collision detection
end
```

- `CollisionSubSteps = 3` at 30 Hz raises the minimum detectable pass-through speed from ~40 studs/s to ~360 studs/s — well above the `VelocityClampMax = 200`.
- Position integration moved from `BeyController.OnStateUpdatePhase` into the sub-step loop. `OnStateUpdatePhase` now only records `previousPosition`.
- `OnCollisionPhase` is kept registered but is a no-op — collision lives inside the sub-step loop so the TickManager phase order is undisturbed.
- `OnClampPhase` is now pure safety: NaN protection and hard velocity cap only. All physics moved to Physics phase.
- `CollisionClassifier.ResetTickCounter()` is called once per tick at the top of `OnPhysicsPhase`, before sub-steps begin.

---

### Step 6 — Ring-out win condition
**Files:** `src/ServerScriptService/PhysicsController.lua`, `src/ReplicatedStorage/MatchState.lua`, `src/ReplicatedStorage/Constants.lua`

Ring-out was previously impossible — the Clamp phase reflected Beys off the rim and pushed them back inside unconditionally.

New rim logic inside the sub-step loop's `_doRimCheck` section:

- Bey crosses rim → `zoneState = "RingOut"`, `ringOutTimer` starts, `RingOutWarning` event emitted.
- Stays outside for `RingOutGraceTicks = 10` ticks (~0.33 s at 30 Hz) → `zoneState = "Finished"`, `finishReason = "RingOut"`, `BeyFinished` event emitted with `reason = "RingOut"`.
- Returns inside before grace expires → `zoneState = "Active"`, `ringOutTimer` reset, `RingOutEscaped` event emitted.

`SpinEvaluator` already skips Beys where `zoneState == "Finished"`, so the ring-out path feeds naturally into the existing match-end logic.

New BeyState fields: `zoneState` (was `"Center"`, now `"Active"/"RingOut"/"Finished"`), `ringOutTimer`, `finishReason`.

---

### Step 7 — Collision RNG tightened
**File:** `src/ReplicatedStorage/Constants.lua`

Old variance: `rng:NextNumber(0.5, 1.5)` — a 3× swing on every collision. Contradicted the "fair, skill-based" design pillar.

New variance: `CollisionDamageVarianceMin = 0.875`, `CollisionDamageVarianceMax = 1.125` — ±12.5%, matching the `LaunchBonusCap` philosophy. Enough texture to break perfect symmetry; not enough to decide outcomes.

---

### Step 8 — Attack / Defend / Evade — server side
**New file:** `src/ServerScriptService/CommandValidator.lua`
**Modified:** `src/ReplicatedStorage/MatchState.lua`, `src/ReplicatedStorage/Remotes.lua`, `src/ServerScriptService/BeyController.lua`, `src/ServerScriptService/PhysicsController.lua`, `src/ServerScriptService/SpinEvaluator.lua`, `src/ServerScriptService/Main.server.lua`

#### CommandValidator
Mirrors `LaunchValidator`. Validates the command string against an allowlist (`Attack`, `Defend`, `Evade`). Rejects if the Bey is finished, a command is already active or cooling, or a duplicate is already queued for this tick.

#### BeyController — Input phase additions
Processes `commandQueue` each tick:
- Sets `currentCommand`, starts `commandTimer = CommandDurationTicks`.
- Emits `CommandIssued` tickEvent.
- Ticks down `commandTimer` each tick; when it expires sets `currentCommand = nil` and starts `commandCooldownTimer = CommandCooldownTicks`.

#### PhysicsController — steering forces
Applied inside the sub-step loop after bowl drift, before collision:

| Command | Steering effect |
|---------|----------------|
| **Attack** | Accelerates toward opponent's current position |
| **Defend** | Accelerates toward stadium centre (stacks with BowlForce) |
| **Evade** | Accelerates away from opponent |

Forces are additive to velocity — they influence, never override. Inertia remains visible. The Bey still drifts, collides, and wobbles naturally.

Attack also amplifies the attacker's own post-collision recoil by `CommandRecoilMultiplier = 1.2` — the risk/reward the spec describes.

#### SpinEvaluator — Defend stability bonus
When `currentCommand == "Defend"`, tilt recovery rate is multiplied by `(1 + CommandStabilityRecoveryBonus)` = +15%. This makes Defend meaningfully different from passive centre-drift (BowlForce already pulls there), giving it a unique survival benefit.

#### New BeyState fields
`currentCommand`, `commandTimer`, `commandCooldownTimer`, `launchConsumed`.

---

### Step 9 — Attack / Defend / Evade — client UI
**Files:** `src/StarterPlayerScripts/UIController.client.lua`, `src/StarterPlayerScripts/InterpolationRenderer.client.lua`

#### UIController — command buttons
Three buttons (Attack/Defend/Evade) appear at the bottom-centre of the screen during `"Active"` phase only. Buttons are hidden during `Countdown` and `Finished`.

- Press fires `Remotes.RequestCommand:FireServer(sequenceId, commandName)`.
- Client-predicted timer: buttons show the remaining active time, dim during cooldown, re-enable when the cooldown expires. No server round-trip needed for visual feedback.
- `CommandDurationTicks / SimulationTickRate` and `CommandCooldownTicks / SimulationTickRate` are read from Constants — one source of truth.

#### InterpolationRenderer — command glow and ring-out pulse
Both effects are driven entirely from the existing `StateSnapshot` payload — no new RemoteEvents.

- **Command glow:** A `PointLight` is lazily created on each Bey's pivot part. Color and brightness change each frame based on `bState0.currentCommand` from the snapshot:
  - Attack → red glow
  - Defend → blue glow
  - Evade → green glow
  - nil → brightness 0
- **Ring-out danger pulse:** A `SelectionBox` is lazily attached to the Bey model. It becomes visible when `bState0.zoneState == "RingOut"` and pulses its surface transparency at 5 Hz using `math.sin`. Invisible otherwise.

---

### Step 10 — Tick rate to 30 Hz
**Files:** `src/ReplicatedStorage/Constants.lua`, `src/ServerScriptService/TickManager.lua`, `src/ServerScriptService/ReplayRecorder.lua`

- `SimulationTickRate` 10 → **30 Hz**
- `ReplicationTickRate` 10 → **15 Hz** (snapshot every 2nd sim tick)
- `InterpolationDelay` 0.1 → **0.15 s** (2.25 snapshot headroom vs. 1.0 before)

TickManager gained `_replicationTickInterval = 2` and `_replicationTickCounter`. The Replication phase only fires when the counter hits the interval, decoupling snapshot broadcast rate from simulation rate.

ReplayRecorder buffer: 1200 → **3600** (120 seconds at 30 Hz).

---

### Step 11 — Launch single-fire guard
**File:** `src/ServerScriptService/LaunchValidator.lua`

Previously a client could fire `RequestLaunch` every frame, re-setting velocity and spin on each Input phase. This was both an exploit and a remote spam vector.

- `bState.launchConsumed` checked before queuing. Set to `true` immediately on acceptance.
- Secondary rate-limit: max 5 fires per second per player before suppressing. The single-fire guard catches legitimate abuse; the rate limit catches clients that spam before the match has BeyState.
- Clamping now uses `VelocityClampMax` from Constants instead of a hardcoded `200`.

---

### Step 12 — Replay header and seed persistence
**Files:** `src/ServerScriptService/ReplayRecorder.lua`, `src/ServerScriptService/MatchManager.lua`, `src/ServerScriptService/SimulationHarness.lua`

#### Replay header
`ReplayRecorder` now writes a match header on the first `MatchStarted` event:
```lua
{ matchId, matchSeed, playerOrder, startTimestamp }
```
Accessible via `ReplayRecorder.GetHeader()`. The seed is the exact value used to construct the `Random` generator — sufficient to reproduce the entire match deterministically.

#### Improved seeding
`MatchManager` seed: `math.floor(workspace:GetServerTimeNow() * 1000) % (2^31 - 1)` — millisecond granularity. Two matches starting in the same second no longer share a seed.

`SimulationHarness` seed: `math.floor(time * 10000 + i * 7919) % (2^31 - 1)` — sub-millisecond with a prime multiplier per match index.

#### SimulationHarness fix
The old finish-reason detection checked `angularVelocity.Magnitude < MinEffectiveSpinThreshold` after the match ended — but `SpinEvaluator` zeros `angularVelocity` for all finish types, so the check always returned `SpinOut`. It now reads `bState.finishReason`, which is set correctly at the moment of finish (`"SpinOut"`, `"WobbleCollapse"`, or `"RingOut"`). The harness also now reports ring-out count separately.

---

## Files changed summary

| File | Type | Change |
|------|------|--------|
| `src/ServerScriptService/Main.server.lua` | Modified | Headless gate, CommandValidator wire-up, matchInProgress guard |
| `src/ServerScriptService/MatchManager.lua` | Modified | Constants import, playerOrder build, improved seed, OnMatchCleanedUp |
| `src/ServerScriptService/PhysicsController.lua` | Rewritten | Sub-step loop, position integration, ring-out, command steering, consolidated constants |
| `src/ServerScriptService/BeyController.lua` | Rewritten | Command queue processing, command timer management, StateUpdate simplified |
| `src/ServerScriptService/SpinEvaluator.lua` | Modified | Defend stability bonus, finishReason field set, playerOrder iteration |
| `src/ServerScriptService/LaunchValidator.lua` | Rewritten | Single-fire guard, rate limiter |
| `src/ServerScriptService/CommandValidator.lua` | **New** | Validates and queues command inputs |
| `src/ServerScriptService/CollisionClassifier.lua` | Modified | `ResetTickCounter()` public method added |
| `src/ServerScriptService/TickManager.lua` | Modified | Replication sub-rate counter |
| `src/ServerScriptService/ReplayRecorder.lua` | Modified | Match header, new snapshot fields, buffer size |
| `src/ServerScriptService/TelemetryLogger.lua` | Modified | Ring-out + command tracking, summary print |
| `src/ServerScriptService/DebugStatePublisher.lua` | Modified | `currentCommand`, `commandCooldownTimer` in snapshot |
| `src/ServerScriptService/SimulationHarness.lua` | Rewritten | Fixed finish-reason, ring-out metrics, improved seeding |
| `src/ReplicatedStorage/Constants.lua` | Modified | Full reorganisation, new constants, tick rate, friction recalc |
| `src/ReplicatedStorage/MatchState.lua` | Modified | `playerOrder`, `commandQueue`, all new BeyState fields |
| `src/ReplicatedStorage/Remotes.lua` | Modified | `RequestCommand` remote added |
| `src/ReplicatedStorage/Types.lua` | (no change needed) | New fields are already in MatchState schema |
| `src/StarterPlayerScripts/UIController.client.lua` | Rewritten | Command buttons, active/cooldown state, client prediction |
| `src/StarterPlayerScripts/InterpolationRenderer.client.lua` | Rewritten | Command glow, ring-out pulse, consolidated render loop |

---

## What the game loop looks like now

```
Player joins
  → match starts (countdown)
  → Beys spawn and fall into bowl

During Active phase:
  Every tick (30 Hz):
    Input:       process launch queue, process command queue, tick command timers
    Physics:     [×3 sub-steps]
                   integrate position
                   gravity + floor
                   friction + bowl drift
                   command steering (Attack/Defend/Evade)
                   rim check → ring-out grace
                   collision detection + resolution
    Clamp:       NaN protection + velocity cap
    StateUpdate: record previousPosition
    Evaluation:  spin decay, wobble escalation/recovery, finish detection
    Replication: [every 2nd tick → 15 Hz] snapshot to clients

  Client (60 fps):
    interpolates position between snapshots
    renders tilt (1.5x amplified)
    renders command glow (colour per command)
    pulses ring-out warning box
    plays spin-down audio

Match ends when:
  - One Bey's spin/wobble crosses threshold (SpinOut / WobbleCollapse)
  - One Bey stays outside the rim for 10 ticks (RingOut)
  - Both finish simultaneously (Draw)

→ Results screen → 5-second pause → rematch
```

---

## What comes next (Phase 2)

The harness is now trustworthy (deterministic, correct finish-reason reporting). After a 1000-match baseline run to establish win-rate and command-distribution benchmarks:

1. **Launch quality tiers** (Poor/Good/Perfect) feeding the existing `LaunchBonusCap`.
2. **Spectator camera** — `SpectatorCameraController.client.lua` currently reverts to `CameraType.Custom`. Lock it to the isometric bowl view for production.
3. **Audio asset IDs** — all `SoundId = ""` placeholders in `InterpolationRenderer` need real asset IDs.
4. **Records/persistence** — Stage C of the production roadmap. Only begin after the harness confirms balanced command win-rates.
5. **Vector3 replay serialization** — replace direct `Vector3` storage in `ReplayRecorder` with `{x, y, z}` tables for cross-session replay exportability.
