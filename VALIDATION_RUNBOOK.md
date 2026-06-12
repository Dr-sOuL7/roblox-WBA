# Phase 1 Validation Runbook — Human Gates

The automated harness gates are GREEN (see `VALIDATION_BASELINE.md`). Phase 1
completes when the four **human** gates below also pass. Per the approved plan,
Phase 2 work does not start until then.

Hardware: 2 desktop testers (mouse/keyboard). Build: sync with Rojo
(`rojo serve` → Studio plugin, or `rojo build -o build.rbxl`).

---

## Session 0 — Studio smoke check (~10 min, 1 person)

1. Open the place, **Play Solo**. Confirm:
   - Camera frames the whole bowl from the isometric angle and never snaps away
     (no character spawns — this is intended).
   - A solo practice match starts after ~6–8 s (matchmaking auto-queues you
     into Casual; a lone player on an idle server gets practice).
   - Expect a loud "[ProfileStore] DataStores unavailable in Studio" warning —
     the in-memory mock is intended in Studio without API access.
   - **Launch ceremony:** aim panel appears (HEIGHT / ANGLE θ / AIM φ sliders)
     → click READY → 3·2·1 countdown → big "GO! SHOOT!" → click LAUNCH (or F)
     AT the GO instant. Grade toast shows Perfect/Good/Poor. Let one match
     auto-launch (don't click): ~2 s after GO it fires at Poor with "(AUTO)".
   - Commands: each button glows the Bey (red/blue/green), shows duration then
     cooldown, server confirms within a snapshot or two.
   - Let the match run to a finish → result screen → automatic rematch in 5 s.
   - **Play the rematch too**: command glow, ring-out warning pulse, and
     spin-down audio must still work in match 2+ (regression: destroyed-instance
     caching).
2. Command bar: `_G.RunValidationSuite()` → expect GO with numbers near the
   baseline doc (sampling noise is fine).

## Gate H1 — Live match loop (2 testers, Studio "Start Server + 2 Players")

10 consecutive matches without restart. Every match must: enter Setup (both
see the aim panel), proceed on both READY clicks (also test the 30 s
auto-ready once by not clicking), count down 3·2·1·GO on both screens,
grade both launches, accept commands from both seats, finish with a correct
winner/draw screen on **both** clients, and auto-rematch. Any stall,
wrong-winner, or desync = FAIL → file, fix, restart the count.

## Gate H2 — Readability baseline (during H1's 10 matches)

Debug overlay OFF. After each match each tester answers without coaching:

1. Who is winning right now? (ask mid-match, ~15 s in)
2. What command is your opponent using? (during a glow)
3. Why did the match end? (SpinOut / WobbleCollapse / RingOut)

Target: ≥ 8/10 correct per question per tester. The wobble→collapse and
ring-out-pulse moments must be visibly readable. Misses = note what was
unreadable; that note is the Phase 7 VFX shopping list, but **systemic**
unreadability (nobody can tell who's winning) fails the gate.

## Gate H3 — Command balance, live (50 matches, 2 testers)

Both testers play to win, varying strategy freely. Log per match (the telemetry
summary prints everything needed): winner, finish type, command counts.

Expected from the harness (live numbers should be in the same neighbourhood):
- Finish mix inside bands: SpinOut 40–65% / Wobble 20–40% / RingOut 10–30%.
- Average duration 15–55 s.
- Draws ≤ 10%.
- No command feels mandatory or useless (post-session questionnaire: rank
  commands by perceived strength; a unanimous "always X" = FAIL).

## Gate H4 — Networking thresholds (Studio network emulator)

Settings → Network → enable emulation. Matrix, ≥ 3 matches per cell:

| Latency | Loss | Pass criteria |
|---|---|---|
| 0 ms | 0% | control |
| 100 ms | 0% | no perceived warp; commands feel responsive |
| 200 ms | 0% | playable; ring-out grace (0.5 s) still reactable |
| 100 ms | 5% | interpolation hides loss; no teleporting |
| 200 ms | 10% | degraded but playable; no desync of result screens |

Watch for: Beys teleporting (snapshot starvation), command button state
mismatch vs server glow, late result screens. The interpolation delay is
150 ms with a 20-snapshot buffer — 200 ms + loss is the honest stress case.

## Gate H5 — Fun consensus (the one that matters)

After H1–H4, both testers answer independently:

1. Did you want one more match? (the rematch-button impulse)
2. Did wins feel earned — launch + commands + positioning, not RNG?
3. One change that would most improve the next session?

PASS = both answer yes to 1 and 2. Anything else: capture the answers
verbatim in PROJECT_STATUS.md and tune before re-running H3/H5.

---

# Phase 2 Validation (V-gates)

Run after H1–H5, in a **published test place with Studio API access enabled**
(real DataStores; the in-memory mock proves nothing about persistence).
Automated prerequisites already pass headless: 36 logic tests including MMR
convergence (ρ 0.94), plus the full sim suite.

## Gate V1 — Persistence survives restarts
Play 3+ matches (stats accrue), note MMR/W-L, shut the server down (or
`game:Shutdown()` from the command bar), rejoin. PASS: stats and MMR intact,
no duplicate-session kick, no data loss. Repeat with a second device joining
FIRST after restart (lock steal path: rejoin within ~90 s must not wipe data).

## Gate V2 — Concurrent matches
4+ testers → two simultaneous matches must run in different arena slots.
PASS: each pair sees only its own match (camera, snapshots, result screens),
telemetry prints two distinct match summaries, no cross-match interference.

## Gate V3 — Ranked loop
Two testers queue Ranked (UI panel) → match completes → both see an MMR delta
toast; rejoin later and confirm the new rating persisted. Placement K (first
10) should move ratings ~±32; settled ~±16.

## Gate V4 — Reconnect (grace)
Mid-match, one tester closes the client and rejoins within 20 s. PASS: their
seat resumes (camera on the right arena, commands work, opponent never saw a
forfeit). The Bey drifted unpiloted meanwhile — that's intended.

## Gate V5 — Abandonment
Mid-ranked-match, one tester leaves and stays gone. PASS: ~20 s later the
opponent wins (forfeit), and the leaver's NEXT login shows the rating loss
applied (pending-adjustment consumption). Verify the winner's gain applied
immediately.

## Gate V6 — Queue edges
Switching queues moves you (one queue at a time); Leave clears; a lone casual
player on an idle server gets solo practice after ~6 s; queueing while in a
match is rejected.

**Phase 2 completes when V1–V6 and H1–H5 all pass.** Per the plan's criteria:
ranked/casual live, MMR converges, persistence survives restarts, concurrent
matches stable.

---

# Phase 3 Validation (W-gates)

Automated prerequisites already pass headless: per-stadium ship gates at 1000
matches each (Classic/Compact/Grand — `VALIDATION_BASELINE.md`), cosmetic
neutrality by construction (identical seeds ± skins → identical outcomes).

## Gate W1 — Stadium variety, live
Play 2+ matches in each stadium (casual select button cycles preference).
PASS: each arena renders correctly (size/curvature visibly different, camera
frames each), matches feel distinct (Compact = pressure, Grand = spacing),
stadium reveal label correct, ranked ignores the casual preference.

## Gate W2 — Skins
Each tester equips a different skin (swatch panel, top right). PASS: both
clients render both skins correctly mid-match; team blades stay red/blue and
"whose Bey is whose" is never ambiguous (re-ask the H2 questions once);
equip persists across rejoin; equip is rejected mid-match; the unknown-skin
path falls back to Factory Steel.

## Gate W3 — Neutrality audit mechanism
After the session, run `_G.PrintNeutralityAudit()` in the server console.
PASS: every skin worn this session appears with picks/decided/win-rate, and
the report flags nothing (small samples print as within tolerance). This
gate validates the MECHANISM; statistical power arrives with population
(Phase 8 promotes the audit to persisted analytics and a release gate).

---

## On failure

Tune only the live dials (`Constants.lua`: command uptime, ring-out grace,
friction, wobble recovery, push cap) → re-run `_G.RunValidationSuite()` to
confirm the automated gates still hold → repeat the failed human gate.
Never tune from a feeling without a number attached.
