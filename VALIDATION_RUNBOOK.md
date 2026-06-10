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
   - A solo match starts after ~2 s: countdown → Active.
   - Press **F** → Bey accelerates toward the bowl centre; spin number ~100 on
     the F2 overlay (F2 toggles the debug overlay, default off).
   - Commands: each button glows the Bey (red/blue/green), shows duration then
     cooldown, server confirms within a snapshot or two.
   - Let the match run to a finish → result screen → automatic rematch in 5 s.
   - **Play the rematch too**: command glow, ring-out warning pulse, and
     spin-down audio must still work in match 2+ (regression: destroyed-instance
     caching).
2. Command bar: `_G.RunValidationSuite()` → expect GO with numbers near the
   baseline doc (sampling noise is fine).

## Gate H1 — Live match loop (2 testers, Studio "Start Server + 2 Players")

10 consecutive matches without restart. Every match must: start, accept both
launches, accept commands from both seats, finish with a correct winner/draw
screen on **both** clients, and auto-rematch. Any stall, wrong-winner, or
desync = FAIL → file, fix, restart the count.

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

## On failure

Tune only the live dials (`Constants.lua`: command uptime, ring-out grace,
friction, wobble recovery, push cap) → re-run `_G.RunValidationSuite()` to
confirm the automated gates still hold → repeat the failed human gate.
Never tune from a feeling without a number attached.
