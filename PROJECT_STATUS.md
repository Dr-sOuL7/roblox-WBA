# BEY ARENA — Project Status

> Single source of truth for phase progress. Update on every implementation cycle.
> Roadmap authority: `BEY_ARENA_PRODUCTION_PLAN.md` (approved).
> Last update: 2026-06-10 — Phase 2 engineering COMPLETE; V-gates + H-gates pending.

## Phase

**Phase 3 — Content Expansion: engineering COMPLETE; validation pending (W-gates below + carried H/V debt).**

Validation debt carried forward (release gates, unaffected by Phase 3 work):
Phase 1 H1–H5 and Phase 2 V1–V6 (`VALIDATION_RUNBOOK.md`) — need 2 testers +
a published place, ~3 h total.

### Launch ceremony (director's redesign, post-Phase 3)

Setup phase (HEIGHT/θ/φ aim sliders) → both READY (30 s auto-ready) →
3·2·1·GO–SHOOT! → click at the GO instant (±0.12 s Perfect / ±0.30 s Good /
else Poor); missed clicks auto-launch Poor 2 s after GO. Client submits only
slider numbers — the server clamps and builds all vectors (anti-cheat
strictly tightened). H-gate scripts updated in the runbook.

### Post-Phase-3 director features & live-test fixes

- **BOT opponent for solo players** (`BotController.lua`): a lone casual
  player battles the AI — it readies, launches near GO (20/55/25
  Perfect/Good/Poor), and plays A/D/E through the same validated queues as
  humans. Deterministic per match seed; never runs headless; no profile, no
  stats, no rating impact.
- **World-invisibility fixes** (first live report: UI worked, no 3D):
  StreamingEnabled forced off via project file; per-player ReplicationFocus
  (lobby + per-match — required because no characters exist); Bey models
  built at their spawn points; CSG inputs parented during SubtractAsync;
  renderer prints a diagnostic if a Bey model fails to replicate within 2 s.
- **Remote key canon**: snapshot/ready/bots dictionaries are STRING-keyed
  over the wire (Roblox converts numeric dict keys anyway) — fixed silently
  dead client lookups (command sync, hitstop, ready ticks).

### Phase 3 progress

| Item | State |
|---|---|
| Stadium registry + data-driven generation | ✅ done — `Stadiums.lua`; physics resolves per-match stadium; Classic == validated baseline EXACTLY |
| Per-stadium ship gate | ✅ done — `_G.RunStadiumGate(id)` / runner `stadium` mode; bands enforced before ROTATION |
| Bey-variant decision documented and locked | ✅ done — `docs/ADR-002-bey-variants.md`: cosmetic-only, by constitution |
| 3+ validated stadiums in rotation | ✅ done — Classic/Compact/Grand all SHIP at 1000-match gates; three distinct textures (see VALIDATION_BASELINE.md) |
| Cosmetic skin system (+ neutrality audit) | ✅ done — 6 starter skins, server-validated equip, team identity on blades; neutrality proven by construction (headless) + live audit (`_G.PrintNeutralityAudit()`) |
| Stadium select (casual) / reveal (ranked) UI | ✅ done — casual preference (agreement/single-pref/rotation fallback), ranked rotation-only, reveal label |

### Phase 2 (engineering complete, validation pending)

Phase 2 was opened by director instruction with Phase 1 human gates (H1–H5)
still pending. This is sound for the current work because the persistence layer
touches zero simulation code — but **the human gates remain a hard release gate
for ranked**: no ranked queue goes live before they pass (`VALIDATION_RUNBOOK.md`).

### Phase 2 progress

| Item | State |
|---|---|
| Persistence layer (locking, retries, autosave, BindToClose, versioned schema) | ✅ built — `Persistence/`; 16/16 pure-logic tests pass headless |
| Stats recording (first real persistence consumer) | ✅ wired via `MatchManager.OnMatchFinished` |
| Server-scaling decision | ✅ decided — multi-stadium per server, `docs/ADR-001-server-scaling.md` |
| Multi-match refactor (`MatchInstance`, scheduler `TickManager`, slots) | ✅ done — full harness suite reproduces the Phase 1 baseline EXACTLY (zero sim drift); 4 arena slots live |
| Launch-quality system (timing bar → Poor/Good/Perfect ≤ `LaunchBonusCap`) | ✅ done — shared synced-clock bar math (`LaunchQuality.lua`), server-graded, late-launch exploit retired; suite GREEN (draws 6.7%→3.6%) |
| Matchmaking (queues → arena slots), ranked/casual split | ✅ done — `Matchmaking/`; MMR-proximity pairing with widening tolerance; cross-server (MemoryStore) isolated behind the same interface, deferred until multi-server population |
| MMR + rating updates + rank display | ✅ done — Elo with placement K, convergence PROVEN headless (ρ 0.94 @ 60 matches); ranked results update profiles; rank/queue UI live |
| Reconnect + abandonment | ✅ done — 20 s disconnect grace (resume on return), forfeit on expiry, countdown-leave cancels, leaver's rating loss delivered via pending-adjustment queue |
| Phase 2 validation (V1–V6 live gates) | ⬜ pending — `VALIDATION_RUNBOOK.md` Phase 2 section |

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

1. **Run the Phase 1 human gates** (H1–H5, `VALIDATION_RUNBOOK.md`) — 2 testers,
   ~2 h. Still open; hard release gate for ranked. Can run any time — the
   persistence work does not affect them.
2. **Run the Phase 2 V-gates** (V1–V6, runbook): persistence restart-survival,
   concurrent matches, ranked loop, reconnect, abandonment, queue edges.
3. **Run the Phase 3 W-gates** (W1–W3, runbook): stadium variety live check,
   skin equip/persist/render, neutrality audit baseline.
4. On all gates GREEN → Phase 4 (progression: XP/levels, soft currency,
   unlocks — on the reserved schema fields).

## Known issues / debt (tracked, not blocking Phase 1)

- ~~Late-launch spin advantage~~ — RETIRED: launches after the window grade
  Poor (−8%), which cancels the decay edge.
- Commands issuable while unlaunched (during Active) — harmless; revisit with
  matchmaking UX.
- ~~Ranked leaver dodges rating loss~~ — CLOSED: rating math runs on the
  start-of-match snapshot and lands via the pending-adjustment queue.
- `SoundId = ""` placeholders (collision/spin-down audio silent) — Phase 7 scope.
- Command colours red/green are a colourblind risk — Phase 7 accessibility pass.
- Replay buffer is in-memory, `Vector3` not serialized — Phase 5 scope (existing TODO).
- `Wave Beyblade Arena (Prototype).rbxl` / `Prototype1.rbxlx` are stale binary
  snapshots predating this cycle — do not trust them; build from Rojo.
- Solo "match" (1 player) is a debug convenience: SpinEvaluator returns the lone
  player as winner. Phase 2 matchmaking replaces lobby flow entirely.
