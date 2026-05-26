# BEY ARENA — Comprehensive Implementation Plan

## 0) Project Objective

Build a multiplayer Roblox Beyblade combat game where the **core physical fantasy is readable, fair, and satisfying online**.

The first deliverable is **Prototype 1**, not a feature-complete game.

Prototype 1 exists to answer one question:

**Does the core spin-and-clink combat loop feel good in real multiplayer conditions?**

Everything else is secondary.

---

# 1) Hard Scope Lock

## In scope for Prototype 1

* One generic Bey model
* One standard bowl stadium
* Server-authoritative multiplayer physics
* Launch system with sliders plus timing bar
* Core collision resolution
* Effective Spin / wobble-based finish logic
* Telemetry logging
* Replay/state snapshot logging
* Live debug overlay
* Spectator mode for developers
* 50+ match stress test
* Emotional tagging per match

## Explicitly out of scope

* Special moves
* Action windows
* AI
* Progression
* Cosmetics beyond basic debugging visuals
* Ranked mode
* Multiple Bey types
* Multiple stadiums
* Burst system
* Meta systems

If a feature does not help validate the core loop, it stays out.

---

# 2) Design Principles

## A. Readability over realism

Physics should be **believable**, not physically pure.

## B. Server authority over client authority

Clients may request inputs. The server decides outcomes.

## C. Visible state over hidden punishment

Players should be able to **see** when a Bey is winning, wobbling, or dying.

## D. Soft failure, not instant cliffs

No sudden “gotcha” deaths from invisible math spikes.

## E. Test-driven production

Telemetry and replay data are part of the core product, not optional tooling.

---

# 3) Prototype 1 Success Criteria

Prototype 1 is successful only if all of the following are true:

1. Multiplayer battles complete reliably under real network conditions.
2. Players can understand who is winning from a glance.
3. Match pacing produces tension without stalling.
4. The launch timing mechanic feels skillful but not oppressive.
5. Collisions feel tactile, fair, and satisfying.
6. The system produces usable telemetry and replay logs.
7. A spectator can predict the likely winner before the match ends.
8. The game produces a strong “one more match” impulse in at least some test players.

---

# 4) Engineering Architecture

## Core server modules

### 4.1 `MatchManager`

Responsibilities:

* create and end matches
* manage match state transitions
* assign players to a match
* reset stadium and Beys
* trigger telemetry finalization
* trigger replay finalization

### 4.2 `TickManager`

Responsibilities:

* run the deterministic gameplay loop
* enforce 10 Hz simulation updates
* sequence all gameplay phases in a fixed order
* clamp values at the end of each physics phase

### 4.3 `BeyController`

Responsibilities:

* track each Bey’s state
* apply launch inputs
* apply movement influences
* store tilt, velocity, angular velocity, stability, momentum state, heat state

### 4.4 `PhysicsController`

Responsibilities:

* apply movement bias
* resolve collision responses
* enforce clamps
* apply environmental penalty zones
* apply hitstop on qualifying impacts
* keep physics assisted, not fully raw

### 4.5 `CollisionClassifier`

Responsibilities:

* classify every collision into:

  * Light
  * Heavy
  * Destabilizing
  * Smash
* apply the correct damage, wobble, and visual profile

### 4.6 `SpinEvaluator`

Responsibilities:

* compute effective spin
* detect spin finish
* identify wobble threshold collapse
* decide whether the Bey is visually and mechanically beyond recovery

### 4.7 `TelemetryLogger`

Responsibilities:

* collect per-match metrics
* store event markers
* write state snapshots
* finalize match payloads
* send to DataStore or analytics endpoint

---

# 5) Simulation Order

The TickManager must execute in a fixed order every simulation step.

## Required order

1. Input collection
2. Physics influence
3. Collision resolution
4. State updates
5. Spin evaluation
6. Telemetry snapshot
7. Client replication

## Why this order matters

* Collision effects must resolve before state mutation.
* State mutation must finish before finish detection.
* Telemetry must record the final state of the tick.
* Replication must reflect the authoritative result, not the intermediate guess.

---

# 6) Tick-Rate Strategy

## Gameplay-state simulation

* Hard-locked to **10 Hz**

## Visual interpolation

* Client-side smoothing at normal frame rate

## Rule

Do not try to make the server simulate visually smooth motion every frame.
The server must be stable and deterministic.
The client should make it look smooth.

---

# 7) Physics Philosophy

## Use assisted physics

Do not rely on free, uncontrolled Roblox physics to define the game.

Instead:

* use forces and angular influences as guided inputs
* clamp velocity and rotation
* bias trajectories rather than hard-lock them
* use physics as the visible expression of hidden state

## Core rule

The math decides the match.
The physics shows the match.

---

# 8) Launch System

The launch phase is the first major skill expression.

## Player inputs

* Spin direction: Left / Right
* Launch direction: directional wheel
* Launch height: slider
* Launch power: slider
* Timing bar: active execution mechanic

## Launch timing bar

The player must hit a timing zone.

### Timing zones

* Poor
* Good
* Perfect

### Launch bonus cap

The launch bonus must be capped at approximately **±15%**.

This means:

* the timing bar matters
* but it does not decide the match on its own

## Launch outputs

The launch result affects:

* starting stability
* initial momentum
* wobble resistance
* early movement quality

---

# 9) Launch Math Model

Use softened, readable math.

## Effective launch bonus

* Perfect: +15%
* Good: moderate positive bonus
* Poor: small negative penalty

## Launch result should modify:

* initial velocity
* initial stability
* initial wobble threshold

## Design rule

A bad launch should be recoverable.
A good launch should create a real advantage.
A perfect launch should not be an instant win.

---

# 10) Core Hidden Battle Variables

Prototype 1 should track these internal values:

## A. Stability

Resistance to wobble and destabilization.

## B. Angular Velocity

Current spin rate.

## C. Effective Spin

A computed value combining spin rate and wobble state.

## D. Momentum State

A hidden value from negative to positive dominance.

## E. Heat

A hidden instability amplifier, not raw exhaustion.

## F. Tilt Angle

The Bey’s visible lean away from upright.

## G. Edge Pressure

Proximity to the outer ring.

---

# 11) Effective Spin Model

Effective spin must account for wobble.

## Basic principle

A Bey with the same RPM should die faster if it is unstable and tilted.

## Implementation guidance

Use:

* angular velocity
* stability ratio
* tilt modifier

## Design goal

Players should visibly see a Bey dying **before** angular velocity reaches zero.

This makes the finish feel fair and readable.

---

# 12) Collision System

Collisions must feel meaningful and classified.

## Collision classes

### Light

* small stamina or spin loss
* minimal visual reaction

### Heavy

* strong spark response
* clear rebound
* moderate stability loss
* hitstop candidate

### Destabilizing

* major stability damage
* visible tilt increase
* sharp sound cue
* pronounced wobble escalation

### Smash

* highest recoil
* strongest ring-out risk
* strongest camera and audio cue
* major stability collapse

---

# 13) Hitstop

Add very small hitstop for meaningful impacts.

## Suggested duration

* 0.03 to 0.06 seconds

## Purpose

* make collisions feel weighty
* improve readability
* reinforce impact without ruining flow

Use it sparingly, only on stronger collisions.

---

# 14) Heat System

Heat is a visibility-driven instability system.

## Purpose

Heat should not mainly feel like hidden exhaustion.
It should feel like:

* wobble intensification
* instability amplification
* greater vulnerability after repeated collisions

## Behavior

* repeated heavy collisions increase Heat
* higher Heat increases wobble consequences
* Heat decays when the Bey avoids collision for a short time

## Rule

Heat should escalate tension, not punish aggression so hard that combat becomes passive.

---

# 15) Outer Ring Anti-Stall System

Do not change Roblox engine friction dynamically mid-match.

Use spatial logic.

## Stadium zones

* Center Zone
* Outer Ring

## Escalation rule

After a fixed time threshold, the outer ring becomes a danger zone through:

* visual glow
* stronger destabilization logic
* increased penalty if a Bey enters that zone

## Recommended approach

* client-side VFX for the warning
* server-side stability penalty for actual effect

## Penalty strength

Start softened. Do not begin with extreme multipliers.
Tune from mild to moderate pressure, not instant death.

---

# 16) Launch / Collision / Wobble Readability

Players must be able to read the game quickly.

## Visual language mapping

* High positive momentum: sharper, more saturated trail
* High negative momentum: lighter, drag-like trail
* Light collision: dull click, small bounce
* Heavy collision: metallic clang, bright spark
* Destabilizing collision: heavy thud, visible tilt, micro-shake
* Smash: deep impact sound, red flash, strong recoil

## Goal

At a glance, a spectator should know:

* who has momentum
* who is wobbling
* who is near death

---

# 17) Debug Overlay

Build the debug overlay before normal gameplay polish.

## Must show

* current stability
* angular velocity
* effective spin
* momentum
* heat
* tilt angle
* collision class
* zone state
* launch quality
* finish threshold proximity

## Purpose

Make invisible systems visible during testing.

Without this, tuning will be blind.

---

# 18) Spectator Mode

## Purpose

The game must be readable by someone who is not actively playing.

## Spectator requirements

* fixed isometric camera
* clear visibility of tilt, spark intensity, motion, and finish state
* ability to identify likely winner before match end

If a spectator cannot predict the outcome 5 seconds before the end, the game’s visual language needs adjustment.

---

# 19) Telemetry Framework

Telemetry is mandatory for Prototype 1.

## Required metrics

* Match_Duration
* Abandoned_Early
* Launch_Quality_P1
* Launch_Quality_P2
* Total_Collisions
* Finish_Type
* Avg_Tilt_Angle
* Time_In_Outer_Ring
* First_Heavy_Collision_Time
* Recovery_Events_Per_Match

## Purpose of each

* **Match_Duration**: pacing analysis
* **Abandoned_Early**: emotional failure signal
* **Launch_Quality**: timing bar effectiveness
* **Total_Collisions**: aggression vs passivity
* **Finish_Type**: desired ratio tuning
* **Avg_Tilt_Angle**: wobble effectiveness
* **Time_In_Outer_Ring**: edge-camping detection
* **First_Heavy_Collision_Time**: interaction speed
* **Recovery_Events_Per_Match**: comeback mechanics visibility

---

# 20) Replay Logging

Telemetry alone is not enough.

## Save per-tick snapshots

* position
* velocity
* angular velocity
* tilt angle
* collision flags
* zone state
* state transitions
* finish triggers

## Why

Physics bugs are hard to reproduce.
Replays make debugging possible.

---

# 21) Emotional Tagging

Every match should be tagged with one subjective outcome:

* Satisfying
* Chaotic
* Passive
* Frustrating

## Purpose

Telemetry tells you what happened.
Emotional tagging tells you how it felt.

This is essential for tuning.

---

# 22) Test Protocol

## Primary stress test

Run **50+ multiplayer matches** with Prototype 1.

## Test conditions

* real multiplayer latency
* real spectators
* repeated launches
* repeated collision events
* no tactical systems yet

## What to observe

* average match duration
* launch timing behavior
* finish distribution
* collision pacing
* readibility from spectator mode
* early abandonment
* replay consistency
* desync frequency

## Key success question

Do players ask for one more match?

---

# 23) Balancing Targets

These are starting targets, not final rules.

## Desired feel

* early interaction within a few seconds
* strong but readable collisions
* visible wobble before death
* match duration that does not drag
* finish states that feel earned

## Avoid

* long dead-spin lingering
* invisible stability cliffs
* infinite stall behavior
* overly frequent ring-outs
* random-looking knockbacks
* homing movement that feels fake

---

# 24) Error Handling and Clamping

Clamp aggressively at the end of each physics phase.

## Clamp:

* linear velocity
* angular velocity
* force multipliers
* tilt extremes
* momentum extremes
* heat amplification
* ring-out escalation

## Goal

Prevent runaway chaos, exploits, and network instability.

---

# 25) Development Phases

## Phase 1 — Prototype 1 Build

### Deliverables

* server authority
* tick manager
* one Bey
* one stadium
* launch system
* collision classifier
* spin evaluator
* telemetry logger
* replay logging
* debug overlay
* spectator camera

### Exit criteria

* stable multiplayer battles
* usable telemetry
* readable outcomes
* no catastrophic desync

---

## Phase 2 — Tactical Layer

Only after Prototype 1 is validated.

### Add

* Attack / Defend / Evade action windows
* momentum-based counter logic
* heat interactions
* recovery logic

### Exit criteria

* tactical choices create pressure
* no dominant spam strategy
* actions remain readable

---

## Phase 3 — Escalation Layer

### Add

* refined anti-stall behavior
* special move
* AI with deliberate imperfection
* more detailed match pacing

### Exit criteria

* matches have clear arcs
* escalation feels natural
* no infinite stall loops

---

## Phase 4 — Meta Layer

### Add

* matchmaking
* progression
* cosmetics
* UI polish
* analytics refinement
* ranked or tournament support

### Exit criteria

* stable retention loop
* clear player motivation
* no pay-to-win damage to combat integrity

---

# 26) Recommended Roblox Script Structure

A minimal server-side folder structure:

```text
ServerScriptService/
  MatchManager
  TickManager
  BeyController
  PhysicsController
  CollisionClassifier
  SpinEvaluator
  TelemetryLogger
  ReplayRecorder
  DebugStatePublisher
```

Client-side:

```text
StarterPlayerScripts/
  InputController
  UIController
  SpectatorCameraController
  DebugOverlayUI
  InterpolationRenderer
```

---

# 27) Implementation Order

Build in this order:

1. Match lifecycle
2. Single Bey spawning
3. Server tick loop
4. Basic movement and rotation
5. Launch inputs
6. Collision classification
7. Spin evaluation
8. End conditions
9. Telemetry logging
10. Replay snapshots
11. Debug overlay
12. Spectator mode
13. Stress testing
14. Tuning pass

Do not invert this order.

---

# 28) Data-Driven Tuning Loop

After every test run:

1. inspect telemetry
2. inspect replay logs
3. inspect emotional tags
4. identify failure patterns
5. adjust only one major variable at a time
6. rerun tests

This prevents chasing random noise.

---

# 29) Design Risks to Watch

## Risk 1: Too much hidden math

Fix by improving visual language and debug clarity.

## Risk 2: Too much physics chaos

Fix by clamping and assisting movement.

## Risk 3: Too much passive waiting

Fix by tuning early collision timing and anti-stall escalation.

## Risk 4: Overly punishing launch

Fix by capping launch bonus and keeping recovery possible.

## Risk 5: Readability collapse

Fix by reducing VFX, using hitstop carefully, and testing spectator comprehension.

---

# 30) Final Acceptance Criteria for Prototype 1

Prototype 1 can move forward only when:

* multiplayer matches run reliably
* state snapshots reconstruct anomalies
* telemetry is being written correctly
* launch quality affects outcomes without dominating them
* effective spin and tilt create believable finishes
* spectators can read match state clearly
* players feel the core loop has impact
* the game produces real emotional response, not just technical curiosity

---

# 31) Final Mandate

Prototype 1 is not trying to prove the whole game.

It is trying to prove:
**the combat fantasy is real.**

If that core truth holds up under 50+ live matches, then the rest of the game can be built safely on top of it.
