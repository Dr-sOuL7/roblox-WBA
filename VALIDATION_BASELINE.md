# Phase 1 Harness Validation Baseline

> Recorded 2026-06-10 · headless runner (`tools/harness-runner/`, Luau CLI, `baseSeed 1337`)
> Suite: `suite 1000 200` — idle sanity 200, physics baseline 1000, command baseline 1000,
> policy matrix 6 × 200 (~3,600 matches total, ~49 s wall clock).
>
> Re-run identically with:
> `python3 tools/harness-runner/build_runner.py --luau <luau> --run suite 1000 200`
> or in Studio: `_G.RunValidationSuite()` (expect the same numbers within sampling
> noise — the runner PRNG differs from Roblox's; see tools/harness-runner/README.md).

## Gate results — ALL PASS (GO)

| Gate | Band | Result |
|---|---|---|
| G0 Idle containment | 0 idle ring-outs | **PASS** — 0 (85% idle draws, expected for two AFK Beys) |
| G1 Stability | 0 forced stops / phase errors | **PASS** — 0 across all batches |
| G2 Duration (cmd baseline) | 15–55 s avg | **PASS** — 21.7 s |
| G3 Finish mix (cmd baseline) | SpinOut 40–65 / Wobble 20–40 / RingOut 10–30 | **PASS** — 54.7 / 31.5 / 13.8 |
| G4 Symmetry (mirror Random) | ≤ 10 pp | **PASS** — 3.1 pp (45.1 vs 48.2) |
| G5 Draw rate | ≤ 10% | **PASS** — 6.7% |
| G6 Collisions | ≥ 2 avg | **PASS** — 7.4 (Light 4287 / Heavy 2816 / Smash 293) |
| G7 Command dominance | no policy > 65% of decided | **PASS** — worst 57.4% (Def vs Eva) |

Finish-mix bands are from the approved plan (GDD §7). G4/G5/G6/G7 values are
engineering-set provisional bands, documented here and in the runbook.

## Key batch summaries

**Command baseline (Random vs Random, 1000):** 21.7 s avg (1.7–28.5 s), 7.4 collisions,
draws 6.7% (54 double-SpinOut, 12 double-Wobble, 1 double-RingOut), command uptime 46.4%,
issue split A 8925 / D 8818 / E 8699.

**Physics baseline (None vs None, 1000):** 28.0 s avg, 11 collisions (all Light/Heavy,
zero Smash — big hits require Attack acceleration, by design), 100% SpinOut, draws 10.9%
(passive twins; not gated — identical play earns identical outcomes).

**Policy matrix (200 each):**

| Matchup | P1 | P2 | Draw | Avg dur |
|---|---|---|---|---|
| Aggressive v Defensive | 48.5% | 45.5% | 6.0% | 17.0 s |
| Aggressive v Evasive | 52.0% | 41.0% | 7.0% | 21.3 s |
| Defensive v Evasive | 52.5% | 39.0% | 8.5% | 24.4 s |
| Aggressive mirror | 46.5% | 47.0% | 6.5% | 15.9 s |
| Defensive mirror | 46.0% | 47.5% | 6.5% | 17.5 s |
| Evasive mirror | 47.0% | 43.5% | 9.5% | 26.0 s |

Durations scale sensibly with aggression (15.9 s aggressive mirror → 26.0 s evasive
mirror): commands have real macro effect.

## What the harness caught (and the tuning that fixed it)

The first-ever baseline run exposed that the shipped constants produced an
unplayable loop — **85% mutual-ring-out draws at 0.59 s**: collision knockback was
uncapped (impact 140 × 0.8 = 112 studs/s) while bowl escape speed is only ~22 studs/s.
Fixes, each iterated against the harness:

1. **`CollisionPushMax = 21`** — just under escape speed; attacker recoil (×1.2 = 25.2)
   is what crosses it, attaching ring-out risk to aggression. (20 → 6% ring-outs,
   24 → 92%; 21 lands the band.)
2. **Command forces resized** (A 35→20, D 15, E 30→17) — old values added ~17 studs/s
   per press and were self-ring-out buttons (96.5% ring-out finishes at 6.5 s).
3. **Evade became a matador dodge** (tangential-biased, `EvadeRadialWeight/TangentialWeight`)
   — radial fleeing just cornered the evader at the rim (Attack beat Evade 72/21;
   now 52/41 with the attacker's whiff momentum carrying rim-ward, per the GDD's
   intended dynamic).
4. **Spawn/launch geometry fixed** — spawn velocity (0,0,±60) self-ring-outed idle
   players in 0.6 s (now gentle orbit, `SpawnTangential/InwardSpeed`); the client's
   fixed launch vector pointed outward from seat 2 (now centre-aimed, `PrototypeLaunchSpeed/Spin`).
5. **Severity thresholds recalibrated** (Heavy ≥ 28) to the contained impact
   distribution — previously 100% of collisions classified Heavy.
6. **Wobble path made real** (StabilityDamage L3/H15/S30, WobbleAmplification 28,
   collapse threshold 70) — wobble finishes went 0% → 31.5%.
7. **Stability→spin coupling** (`StabilitySpinDrainMax = 0.12`) — damaged Beys spin
   down faster; deterministic, skill-linked endgame separation that collapsed
   structural double-SpinOut draws (13.3% → 6.7%) without adding RNG.
8. **`RingOutGraceTicks` 10 → 15** (0.5 s) — the ~330 ms window was already flagged
   as a latency risk in the plan; Defend's centre pull can now function as a save.

## Known quirks (accepted for Phase 1, owned by Phase 2)

* **Late-launch spin advantage:** launching later applies fresh spin (100) later,
  net ~5% spin edge for a 0.5 s delay. Mitigated by ring-out/positional risk while
  drifting unlaunched; eliminated entirely by Phase 2's launch-quality system
  (timing bar replaces the free-timing prototype launch).
* Commands are issuable before launching. Harmless now; folds into the Phase 2
  launch redesign.

---

# Stadium Gate Results (Phase 3)

> Per-stadium ship gates at 1000 matches each (`stadium <id> 1000` runner mode /
> `_G.RunStadiumGate(id)` in Studio). Bands identical to the Phase 1 gates.

| Stadium | SpinOut/Wobble/RingOut | Avg duration | Collisions/match | Verdict |
|---|---|---|---|---|
| Classic (r20, R50, pull 7, launch ×1) | 50/33/17 | 20.6 s | 7.2 | SHIP (baseline) |
| Compact (r17, R34, pull 8, launch ×0.85) | 43/35/21 | 20.0 s | 8.3 | SHIP — pressure/wobble texture |
| Grand (r26, R95, pull 6, launch ×1.25) | 62/24/14 | 21.0 s | 5.3 | SHIP — spacing/endurance texture |

Design law learned from the gate (now encoded in `Stadiums.lua` comments):
**rim escape speed ≈ √(2·g·h) must sit just ABOVE `CollisionPushMax`** (21) —
below it, plain hits eject from anywhere (gate showed 53–91% ring-outs);
above it, ring-out pressure correctly attaches to attacker recoil and rim
adjacency. Concepts the gate CUT: the extreme "deathpit" (constant contact
structurally starves SpinOut below band — softened into the shipped Compact).
