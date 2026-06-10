# BEY ARENA — Project Status

> Single source of truth for phase progress. Update on every implementation cycle.
> Roadmap authority: `BEY_ARENA_PRODUCTION_PLAN.md` (approved).
> Last update: 2026-06-10 — Phase 1 completion engineering + harness gates GREEN.

## Phase

**Phase 1 — Core Gameplay Validation: engineering COMPLETE, harness gates PASS, human gates PENDING.**

Phase 2 (persistence, matchmaking, launch quality, ranked) is **not started**, by
mandate: it opens only when the human gates in `VALIDATION_RUNBOOK.md` pass.

## Gate board

| Phase 1 completion criterion | State |
|---|---|
| Harness stability (1000-match baseline) | ✅ **PASS** — 0 errors/forced stops in ~3,600 matches (`VALIDATION_BASELINE.md`) |
| Finish-type distribution in GDD §7 bands | ✅ **PASS** — 54.7 / 31.5 / 13.8 |
| Command balance (no dominant policy) | ✅ **PASS** — worst matchup 57.4% of decided |
| Live match loop (10 matches, 2 humans) | ⬜ pending — Gate H1 |
| Readability baseline | ⬜ pending — Gate H2 |
| Command usability live (50 matches) | ⬜ pending — Gate H3 |
| Networking 0/100/200 ms · 5/10% loss | ⬜ pending — Gate H4 |
| Two-tester fun consensus | ⬜ pending — Gate H5 |

## What changed in this cycle (Phase 1 completion engineering)

**Blockers removed**
- `default.project.json` mapped 8 nonexistent directories → Rojo could not build;
  now maps only real sources. Validation in Studio is unblocked.
- `SpectatorCameraController` actually locks the isometric bowl view now
  (was commented out + reverting to `Custom` — the named Phase 1 risk),
  enforced per-frame, constants-driven.
- `CharacterAutoLoads = false` — avatars no longer spawn into the stadium.

**Core-loop correctness**
- Rematch no longer kills client feedback: command glow / ring-out pulse /
  spin-down audio recreate after Bey models are destroyed (match 2+ regression).
- Lobby race fixed: party forms at wake time from the live waiting list (a solo
  match can no longer strand a present second player); rematch handler caps at
  2 players and can't double-start against a scheduled lobby start.
- Launch geometry: client aims at bowl centre from its own seat (the fixed
  world-space vector self-ring-outed seat 2); spawn drift is gentle orbit
  (the old ±60 tangential spawn self-ring-outed idle players in 0.6 s).

**Balance — first-ever harness baseline caught an unplayable loop and it was
tuned into band** (full story + numbers: `VALIDATION_BASELINE.md`):
push cap (new), command forces resized, Evade redesigned to the GDD's dodge
(matador sidestep), severity thresholds recalibrated, wobble path made real,
stability→spin coupling (new, kills structural draws), ring-out grace 0.33→0.5 s.

**Validation infrastructure**
- `SimulationHarness`: deterministic A/D/E policy bots through the real command
  queue, fixed-seed reproducible batches, severity/draw-type metrics, and an
  8-gate GO/NO-GO suite (`_G.RunValidationSuite()` in Studio).
- `tools/harness-runner/`: runs the actual sim modules under the Luau CLI for
  CI — non-zero exit on NO-GO.
- Debug overlay default-hidden (F2) for clean readability sessions.
- `TickManager` counts pcall-isolated phase errors (stability gate input).

## Next actions (strict order)

1. **Run the human gates** (H1–H5, `VALIDATION_RUNBOOK.md`) — 2 testers, ~2 h.
   Owner: design/test. This is the only thing between here and Phase 2.
2. On H-gate failures: tune live dials → re-run `_G.RunValidationSuite()` → retry.
3. On full Phase 1 GO → open Phase 2 in this order (per plan §Phase 2):
   a. **Persistence layer** (DataStore + session locking + BindToClose + retry —
      the gating dependency for Phases 2/4/5/6; build once, carefully).
   b. Server-scaling decision (multi-stadium vs reserved servers) — architectural,
      decide before matchmaking code.
   c. Launch-quality system (timing bar → Poor/Good/Perfect within
      `LaunchBonusCap`; also retires the late-launch quirk noted in the baseline).
   d. Matchmaking (MemoryStore queue), MMR + ranked/casual split.

## Known issues / debt (tracked, not blocking Phase 1)

- Late-launch spin advantage (~5%/0.5 s) — folded into Phase 2 launch redesign.
- Commands issuable pre-launch — same owner.
- `SoundId = ""` placeholders (collision/spin-down audio silent) — Phase 7 scope.
- Command colours red/green are a colourblind risk — Phase 7 accessibility pass.
- Replay buffer is in-memory, `Vector3` not serialized — Phase 5 scope (existing TODO).
- `Wave Beyblade Arena (Prototype).rbxl` / `Prototype1.rbxlx` are stale binary
  snapshots predating this cycle — do not trust them; build from Rojo.
- Solo "match" (1 player) is a debug convenience: SpinEvaluator returns the lone
  player as winner. Phase 2 matchmaking replaces lobby flow entirely.
