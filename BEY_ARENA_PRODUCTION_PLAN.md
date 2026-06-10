# BEY ARENA — Production Plan

> Master planning artifact. Part I is the development roadmap (Phases 1–10).
> Part II is the full Game Design Document (30 sections).
> No implementation begins until this is approved.

---

# PART I — DEVELOPMENT ROADMAP

## Guiding principles (apply to every phase)

1. **Server-authoritative, always.** The client never owns simulation state. Every input is validated server-side before it touches `MatchState`.
2. **Prove fun before building scale.** No progression, social, or monetization system is built until the 30-second core loop is validated by humans.
3. **Cosmetic-only monetization.** Nothing purchasable touches the simulation. Skins, trails, launch effects, nameplates, emotes — never stats, never Beys-with-advantages.
4. **Small-team maintainability.** Every system added is a system someone maintains forever. Default to cutting, not adding.
5. **Determinism is for reproducibility, not netcode.** The fixed-step sim makes the harness and replays reproducible. It is not lockstep multiplayer.

---

## Phase 1 — Core Gameplay Validation

**Objective:** Prove the launch → command → collide → wobble → finish → rematch loop is fun, fair, readable, and stable with two humans. This is the single most important phase. Everything downstream is speculation until it passes.

| Category | Detail |
|----------|--------|
| **Systems required** | Already built: fixed-step sim, sub-stepped collision, A/D/E commands, ring-out, spin/wobble finish, rematch loop, interpolation, telemetry, in-memory replay. |
| **Engineering tasks** | None new. Bug-fix and tuning passes already applied. Camera must be confirmed to actually frame the bowl (current `SpectatorCameraController` reverts to `CameraType.Custom` — unverified). |
| **Gameplay tasks** | Run the harness baseline (1000 matches). Run 10-match legibility session, then 50-match balance session. |
| **UI tasks** | Confirm result screen, command buttons, cooldown feedback, ring-out warning all render correctly in live play. |
| **Networking tasks** | Validate at 0/100/200 ms latency and 5/10% packet loss using Studio's network emulator. |
| **Balancing tasks** | Tune from harness + playtest data only. Do not guess. Command uptime, ring-out grace, friction, wobble recovery are the live dials. |
| **Telemetry requirements** | Existing `TelemetryLogger` summary (collisions, ring-outs, command distribution, emotional tags). No new telemetry needed yet. |
| **Testing requirements** | The full validation plan: harness ranges, command balance, duration, finish-type distribution, readability, networking, go/no-go gates. |
| **Risks** | Camera may not frame the bowl. Ring-out reaction window (~330 ms) may be too short at 200 ms latency. Commands may feel invisible. Core loop may simply not be fun — this is the honest risk nobody has tested. |
| **Dependencies** | None. This is the foundation. |
| **Completion criteria** | All six go/no-go gates pass: harness stability, live match loop, readability baseline, command usability, networking threshold, and two-tester consensus that the game is fun and skill-driven. |

---

## Phase 2 — Competitive Gameplay

**Objective:** Turn a proven 1v1 into a *competitive* 1v1 — skill expression depth, matchmaking, ranking, and the infrastructure for fair ranked play.

| Category | Detail |
|----------|--------|
| **Objectives** | Launch quality skill tier, MMR-based matchmaking, ranked ladder, casual queue, server architecture that supports more than one match per server. |
| **Systems required** | Launch quality system (Poor/Good/Perfect feeding existing `LaunchBonusCap`). Matchmaking service (MemoryStore queue + reserved servers or N-stadium servers). MMR/rating store (DataStore + session locking). Ranked/casual queue split. |
| **Engineering tasks** | Build the **persistence layer from scratch** — there is currently zero DataStore code. Build matchmaking. Decide and implement the server-scaling model (multiple stadiums per server vs reserved-server-per-match). Refactor `MatchManager` to support concurrent matches if multi-stadium. |
| **Gameplay tasks** | Implement launch quality (timing-based or meter-based) as the pre-match skill layer. Tune A/D/E counterplay depth so high-skill mirror matches have a meta. |
| **UI tasks** | Rank display, MMR, queue UI, launch-quality meter, pre-match loadout (cosmetic only), post-match rating delta. |
| **Networking tasks** | Cross-server matchmaking messaging. Reserved server provisioning. Reconnect handling (player drops mid-ranked-match). |
| **Balancing tasks** | Rank distribution targets. MMR K-factor tuning. Launch-quality advantage cap (must stay ≤ `LaunchBonusCap` philosophy — skill expression, not a wall). |
| **Telemetry requirements** | Per-rank win rates, command distribution by rank, match abandonment rate, queue times, MMR convergence speed. |
| **Testing requirements** | Matchmaking load test. MMR simulation (does it converge?). Reconnect/abandon edge cases. Smurf/derank detection baseline. |
| **Risks** | Persistence is a from-scratch foundation with all the DataStore pitfalls (throttling, session locking, data loss on BindToClose). Matchmaking at low population = long queues. Server-scaling decision is architectural and hard to reverse. |
| **Dependencies** | Phase 1 complete. Persistence layer is the gating dependency for everything in Phases 2, 4, 5, 6. |
| **Completion criteria** | Ranked and casual queues live. MMR converges. Persistence survives server restarts without data loss. Concurrent matches stable. Per-rank balance within target bands. |

---

## Phase 3 — Content Expansion

**Objective:** Add variety *without* breaking the one-Bey, skill-first vision. This phase is where the "no Bey classes" constraint collides with "content," and it must be resolved honestly.

| Category | Detail |
|----------|--------|
| **Objectives** | More stadiums (the safest content axis), cosmetic Bey variety, and a decision on whether Bey *variants* exist at all. |
| **Systems required** | Stadium variant system (different bowl geometry/physics constants per stadium — but all symmetric and fair). Cosmetic Bey skin system. Stadium hazard rules (optional, must be symmetric). |
| **Engineering tasks** | Parameterize stadium generation (currently one hardcoded CSG bowl in `MatchManager`). Move stadium tuning into data. Build a stadium registry. Asset pipeline for skins. |
| **Gameplay tasks** | Design 3–5 stadiums that change *spatial* play (rim shape, size, center pull) without changing the Bey. Validate each is symmetric and ring-out rates stay in band. |
| **UI tasks** | Stadium select (casual), stadium reveal (ranked rotation), skin equip. |
| **Networking tasks** | Stadium ID in match-start payload. Skin IDs in snapshot for rendering. |
| **Balancing tasks** | Each stadium re-runs the full harness + finish-type validation. A stadium that pushes ring-out > 50% or duration < 15 s is cut. |
| **Telemetry requirements** | Per-stadium win rate, finish-type split, duration, ring-out rate. Per-skin pick rate (cosmetic only — must not correlate with win rate; if it does, that's a bug). |
| **Testing requirements** | Per-stadium harness pass. Symmetry verification. Skin rendering at all latencies. |
| **Risks** | **The honest tension:** "Collection" and "Customization" with one Bey can only be cosmetic. If the vision relaxes to Bey *variants*, they must be sidegrades (different feel, equal power) — extremely hard to balance, and one step from pay-to-win. Recommend: stay cosmetic, make stadiums the variety axis. |
| **Dependencies** | Phase 2 (so new content enters a ranked context with telemetry to catch imbalance). |
| **Completion criteria** | 3+ validated stadiums in rotation. Cosmetic skin system live with zero win-rate correlation. Vision decision on Bey variants documented and locked. |

---

## Phase 4 — Progression Systems

**Objective:** Give players reasons to return that are *earned*, cosmetic, and never pay-to-win.

| Category | Detail |
|----------|--------|
| **Objectives** | Account level/XP, cosmetic unlock track, soft currency, collection of cosmetics. All horizontal (cosmetic), never vertical (power). |
| **Systems required** | XP/level system. Soft currency (earned). Unlock system (cosmetics gated by level/currency/achievement). Collection/inventory. All backed by the Phase 2 persistence layer. |
| **Engineering tasks** | Inventory data model. Unlock validation (server grants, never client). Currency ledger with server authority. Anti-duplication/anti-rollback safeguards. |
| **Gameplay tasks** | XP curve design (per-match XP from participation + performance, not just wins, to avoid demoralizing losers). Currency earn rates. |
| **UI tasks** | Progression bar, level-up moment, unlock gallery, currency wallet, collection screen. |
| **Networking tasks** | Server-granted rewards pushed to client. No client-side currency math. |
| **Balancing tasks** | Earn-rate vs unlock-cost economy. Time-to-unlock targets. Must feel rewarding without being grindy or forcing purchase. |
| **Telemetry requirements** | XP/session, currency earn/spend, unlock completion rate, which cosmetics are chased, churn vs progression milestones. |
| **Testing requirements** | Economy simulation (can a free player unlock meaningfully?). Exploit testing (currency dupe, reward replay). Persistence stress. |
| **Risks** | Economy design is easy to get wrong (too grindy = churn, too generous = no monetization headroom). Server-authority on every grant is non-negotiable and adds latency to reward moments. |
| **Dependencies** | Phase 2 persistence layer. Phase 3 cosmetic content (you need things to unlock). |
| **Completion criteria** | Progression loop live, economy balanced, all grants server-authoritative, zero successful dupe exploits in testing. |

---

## Phase 5 — Social Systems

**Objective:** Retention through connection — but lean. This is the phase most likely to over-scope for a small team.

| Category | Detail |
|----------|--------|
| **Objectives** | Friends/rematch, spectating, replay sharing, and a *light* community layer. Recommend cutting heavy clan/tournament systems at launch. |
| **Systems required** | Friend invite/rematch. Spectator mode (build on existing snapshot replication). Replay save/share (currently in-memory only — needs persistence). Leaderboards (global/friends/seasonal). **Recommend deferring:** full clan system, automated tournaments. |
| **Engineering tasks** | Spectator camera + spectator-only snapshot subscription. Replay persistence (serialize the current snapshot buffer; switch `Vector3` to `{x,y,z}` per the existing TODO). Leaderboard via OrderedDataStore. |
| **Gameplay tasks** | Spectator UX (what does a watcher see/hear). Rematch flow. |
| **UI tasks** | Friends list, spectate button, replay browser, leaderboard screens, share flow. |
| **Networking tasks** | Spectator snapshot fan-out (the existing `FireAllClients` already broadcasts to all — extend to non-players in the server). Cross-server replay fetch. |
| **Balancing tasks** | None gameplay; moderation load planning (shared content needs moderation). |
| **Telemetry requirements** | Spectator counts, replay views/shares, friend-rematch rate, leaderboard engagement. |
| **Testing requirements** | Spectator at scale (N watchers, 1 match). Replay fidelity (does a saved replay reconstruct correctly?). Moderation pipeline. |
| **Risks** | **Scope.** Clans and tournaments are each a multi-month backend + moderation burden. A small team cannot maintain them well. Strong recommendation: ship spectator + replay + leaderboards + friends; defer clans/tournaments until population justifies the maintenance cost. |
| **Dependencies** | Phase 2 (persistence), Phase 4 (identity/profile to attach social to). |
| **Completion criteria** | Spectating, replay save/share, friends-rematch, and leaderboards live and stable. Clan/tournament explicitly deferred with documented re-evaluation trigger (e.g., 10k DAU). |

---

## Phase 6 — Monetization

**Objective:** Revenue without a single pay-to-win lever. Reaffirms the constraint the project has held since day one.

| Category | Detail |
|----------|--------|
| **Objectives** | Premium currency, cosmetic store, optional battle pass (cosmetic track), all strictly horizontal. |
| **Systems required** | Robux → premium currency. Cosmetic store (rotating + permanent). Optional seasonal cosmetic pass. Gifting (optional). |
| **Engineering tasks** | Roblox MarketplaceService integration. Receipt validation + idempotent grant (the classic Roblox double-grant pitfall). Store inventory backend. Pass progression tied to existing XP. |
| **Gameplay tasks** | None to the simulation — this is the firewall. Monetization must be provably gameplay-neutral. |
| **UI tasks** | Store, pass track, purchase flow, owned-item states, gifting flow. |
| **Networking tasks** | Server-side purchase grant only. Client never asserts ownership. |
| **Balancing tasks** | Price points. Pass value curve. Earn-vs-buy ratio (free players must still progress cosmetically). |
| **Telemetry requirements** | Conversion, ARPDAU, store pick rates, pass completion, refund/chargeback rate, **a standing audit that no purchasable item correlates with win rate.** |
| **Testing requirements** | Receipt-validation exploit testing (double-grant, replay, rollback). Purchase failure recovery. The win-rate-neutrality audit as a release gate. |
| **Risks** | Receipt handling bugs cause real-money loss or duplication. Any perception of pay-to-win damages a competitive game permanently. The neutrality audit must be a hard gate, not a nice-to-have. |
| **Dependencies** | Phase 4 (currency/inventory foundation), Phase 3 (cosmetic content to sell). |
| **Completion criteria** | Store + currency live. Receipt grants idempotent and exploit-free in testing. Documented, automated win-rate-neutrality audit passing. |

---

## Phase 7 — Polish

**Objective:** Move from "functional" to "premium feel." This is where the game earns its quality reputation.

| Category | Detail |
|----------|--------|
| **Objectives** | Audio, VFX, camera feel, UI animation, haptics, performance, accessibility. |
| **Systems required** | Full audio pass (collision SFX by severity, spin-down loop, UI, ambience — all the `SoundId = ""` placeholders filled). VFX (collision sparks, ring-out burst, command auras beyond the current PointLight). Camera juice (shake on smash, zoom on finish). |
| **Engineering tasks** | Audio asset integration. Particle systems. Camera controller upgrade. UI tween pass. Performance profiling (sub-step loop cost, snapshot size, render budget). |
| **Gameplay tasks** | Game-feel tuning: hitstop timing, screen shake intensity, finish slow-mo. |
| **UI tasks** | Animated transitions, juice on every state change, responsive layouts, controller/mobile support. |
| **Networking tasks** | Snapshot size optimization (bandwidth budget per player). Possible delta-compression of snapshots. |
| **Balancing tasks** | Ensure polish (e.g., hitstop) doesn't desync feel from server truth. |
| **Telemetry requirements** | Client FPS distribution, snapshot bandwidth, device/platform split, crash/error rates. |
| **Testing requirements** | Performance on low-end mobile. Audio mix. Accessibility (colorblind-safe command colors — current red/blue/green is a risk). |
| **Risks** | Polish is unbounded; needs a strict scope cap. Mobile performance with particle VFX. The red/green command colors are a colorblind accessibility problem to fix here. |
| **Dependencies** | Phases 1–3 (you polish validated mechanics, not speculative ones). |
| **Completion criteria** | Audio/VFX complete, 60 FPS on mid-tier mobile, accessibility pass done, game-feel reviewed and signed off. |

---

## Phase 8 — Beta Testing

**Objective:** Validate at real scale with real players before launch.

| Category | Detail |
|----------|--------|
| **Objectives** | Closed then open beta. Find balance, economy, infra, and retention problems at population. |
| **Systems required** | Beta access gating. Feedback pipeline. Crash/error reporting. Telemetry dashboards (live). |
| **Engineering tasks** | Live telemetry aggregation (the current per-match console print must become aggregated analytics). Feature flags / kill switches. Hotfix pipeline. |
| **Gameplay tasks** | Balance response loop (read telemetry → tune constants → redeploy). |
| **UI tasks** | Feedback/report UI. |
| **Networking tasks** | Load testing at target CCU. Matchmaking under real population. |
| **Balancing tasks** | First real meta will emerge — respond to A/D/E dominance, stadium imbalance, rank inflation. |
| **Telemetry requirements** | Full funnel: acquisition, D1/D7/D30 retention, match completion, queue times, economy flow, monetization, balance. |
| **Testing requirements** | Stress at peak CCU. Economy at scale. Anti-cheat under adversarial players. |
| **Risks** | The first real meta may break assumptions. Infra may not scale. Cheaters appear at population. |
| **Dependencies** | Phases 1–7 substantially complete. |
| **Completion criteria** | Retention targets met, infra stable at target CCU, no critical exploits open, balance within bands under real play. |

---

## Phase 9 — Launch Preparation

**Objective:** Ship-readiness.

| Category | Detail |
|----------|--------|
| **Objectives** | Final hardening, content readiness, marketing-side hooks, support readiness. |
| **Systems required** | Season 1 content locked. Launch event. Onboarding/tutorial. Support/refund tooling. |
| **Engineering tasks** | Final exploit audit. DataStore migration/versioning safety. Rollback plan. Capacity planning. |
| **Gameplay tasks** | New-player onboarding (first-match tutorial teaching launch + A/D/E + ring-out). |
| **UI tasks** | Onboarding flow, first-time UX, store launch state. |
| **Networking tasks** | Capacity headroom for launch spike. |
| **Balancing tasks** | Launch-state balance lock + rapid-response plan. |
| **Telemetry requirements** | Launch dashboard: CCU, crashes, conversion, retention, queue health — real-time. |
| **Testing requirements** | Full regression. Disaster-recovery drill (data loss, server fleet failure). |
| **Risks** | Launch spike overwhelms infra. A day-one exploit or data-loss bug. Onboarding fails to teach the loop. |
| **Dependencies** | Phase 8 beta signoff. |
| **Completion criteria** | Onboarding teaches the loop, infra has spike headroom, DR plan tested, all critical/high bugs closed. |

---

## Phase 10 — Live Service Operations

**Objective:** Sustain and grow.

| Category | Detail |
|----------|--------|
| **Objectives** | Seasonal cadence, balance patches, content drops, events, community management — at a pace a small team can sustain. |
| **Systems required** | Season system. Event scheduler. Balance-patch pipeline. Live config (tune `Constants` without redeploy). Community/CM tooling. |
| **Engineering tasks** | Live-config service (data-driven constants). Season rollover automation. Event framework (reuse, don't rebuild per event). |
| **Gameplay tasks** | Seasonal balance passes from telemetry. New stadium per season (the sustainable content axis). |
| **UI tasks** | Season UI, event UI, patch notes in-client. |
| **Networking tasks** | Hot config push. Zero-downtime season rollover. |
| **Balancing tasks** | Ongoing meta management. Per-season rank reset/soft-reset tuning. |
| **Telemetry requirements** | Season-over-season retention, meta health (A/D/E + stadium balance), economy health, LTV. |
| **Testing requirements** | Each patch regression-tested. Event dry-runs. |
| **Risks** | **Sustainability.** A small team must not build a content treadmill it can't feed. Lean cadence (one stadium + one cosmetic set + balance per season) over ambitious live events. |
| **Dependencies** | Launch (Phase 9). |
| **Completion criteria** | Ongoing — measured by retention, meta health, and team sustainability, not a fixed endpoint. |

---

# PART II — GAME DESIGN DOCUMENT

## 1. Core Gameplay Loop

The atomic loop, ~30–55 seconds:

```
Launch  →  Command (Attack/Defend/Evade)  →  Collide  →  Wobble  →  Finish (SpinOut / WobbleCollapse / RingOut)  →  Result  →  Rematch
```

The skill expression lives in three places: **launch quality** (Phase 2 timing layer), **command timing/choice** (the live skill loop), and **positional reading** (where you are in the bowl relative to your opponent and the rim). No stats, no classes, no RPG layer. The depth comes from a small ruleset with high interaction richness — like a fighting game's neutral, not an RPG's number-growth.

## 2. Match Flow

Driven by `MatchState.phase`: **Countdown → Active → Finished**, owned by `TickManager`.

- **Countdown (3 s):** Both Beys spawned, players see countdown, launch window opens.
- **Active:** Fixed-step 30 Hz simulation. Players issue commands. Physics resolves collisions, ring-out, spin/wobble.
- **Finished:** Winner declared via `currentWinner`, result UI, 5-second pause, automatic rematch with returning + waiting players.

Match flow is already correct and tested in the loop sense. Phase 2 adds matchmaking *before* Countdown and rating updates *after* Finished.

## 3. Beyblade System

**One Bey. Period — for the competitive integrity of the game.** Every player pilots an identical Bey with identical physics. This is the project's strongest competitive decision and must be defended.

The Bey is defined by `MatchState.createBeyState`: position, velocity, angularVelocity (spin), tilt, stability, plus command and ring-out state. These are *simulation* fields, identical for all players. Visual identity (skins, trails, colors) is cosmetic and rendering-only — it never enters `BeyState` in a way that affects physics.

If the vision ever relaxes to variants, they must be **sidegrades** (equal total power, different distribution of feel) and balanced like fighting-game characters. This is a multi-month balance commitment and is explicitly out of scope until proven necessary. Default: stay single-Bey.

## 4. Attack / Defend / Evade System

The primary skill expression. Implemented as steering-force biases in the physics sub-step loop, not as damage/teleport abilities.

| Command | Effect (server) | Risk | Reward |
|---------|-----------------|------|--------|
| **Attack** | Steers toward opponent (`CommandAttackForce`); attacker takes amplified recoil on collision (`CommandRecoilMultiplier`, attacker-only after the asymmetry fix) | Self-recoil destabilizes you | Forces collisions, applies pressure |
| **Defend** | Steers toward center (`CommandDefendForce`, stacks with `BowlForce`); boosts tilt recovery (`CommandStabilityRecoveryBonus`) | Passive, cedes initiative | Survives, stabilizes, escapes rim |
| **Evade** | Steers away from opponent (`CommandEvadeForce`) | Cedes center, risks rim/ring-out | Avoids collisions, repositions |

Commands have a duration (`CommandDurationTicks`) and cooldown (`CommandCooldownTicks = 30` post-tuning → 33% uptime), enforcing **commitment** — you cannot hold a command permanently, and choosing one denies the others. Counterplay: Attack beats passive Defend positioning but risks self-destabilization; Evade dodges Attack but flirts with ring-out; Defend outlasts but cedes tempo. This rock-paper-scissors-with-positioning is the meta. Phase 2's job is to validate it has real depth at high skill.

## 5. Stadium System

Currently one CSG bowl (sphere subtracted from a block) generated in `MatchManager`, parameterized by `BowlSphereRadius`, `BowlPlayableRadius`, `BowlRimBuffer`. Physics: spherical floor clamp + slope slide + center drift (`BowlForce`).

**The stadium is the primary content axis** (Phase 3) precisely because it adds variety without touching the Bey. Variant stadiums change bowl size, rim shape, and center-pull strength — altering *spatial* play while every Bey stays identical and every stadium stays symmetric. Each new stadium re-runs the full harness + finish-type validation before shipping.

## 6. Physics Rules

Server-authoritative, fixed-step 30 Hz with 3 collision sub-steps (`PhysicsController.OnPhysicsPhase`). Per sub-step, per Bey: integrate position → gravity → spherical floor clamp + slope slide → friction (`frictionPerSubStep`, correctly derived) → center drift → command steering → rim state transition. Then one collision pass at the sub-step's positions. Ring-out grace timer increments once per tick after all sub-steps.

Collision: overlap detection at `BeyRadius * 2`, impulse resolution with tangential retention (`TangentialEnergyRetention`), severity classification (Light/Heavy/Smash by impact speed), stability + spin damage with ±12.5% variance, per-pair cooldown to prevent collision spam. Sub-stepping raises the anti-tunneling speed ceiling above the velocity clamp.

Determinism: seeded `Random` per match, sorted `playerOrder` iteration everywhere. This makes the harness and (potentially) replays reproducible. It is **not** cross-machine lockstep — Luau floating point isn't guaranteed identical across hardware, and the netcode doesn't need it to be (single server simulates, clients interpolate).

## 7. Win Conditions

Three finish types, all in the current build:

- **SpinOut:** `angularVelocity.Magnitude < MinEffectiveSpinThreshold` for `CriticalSpinWindow` — natural friction death.
- **WobbleCollapse:** `tilt > WobbleCollapseThreshold` for the window — instability death from collisions.
- **RingOut:** outside `rimLimit` for `RingOutGraceTicks` — knocked out of play.

Match resolves when one Bey remains (`SpinEvaluator`). Solo finish returns the player's own id (post-fix). Simultaneous finish = Draw. Target distribution (validation): SpinOut 40–65%, WobbleCollapse 20–40%, RingOut 10–30%.

## 8. Ranked System

**Phase 2.** MMR per player (DataStore + session locking). Skill-based matchmaking via queue (MemoryStore). Visible rank tiers. Seasonal soft-reset. K-factor tuned for reasonable convergence without volatility. Ranked uses a fixed/rotating stadium set (no casual stadium-pick advantage). Abandonment penalties. The entire ranked edifice depends on the from-scratch persistence + matchmaking foundation that does not yet exist.

## 9. Casual System

**Phase 2.** Unranked queue, looser matchmaking, stadium selection allowed, no rating stakes. The on-ramp and the experimentation space (try cosmetics, learn stadiums, warm up). Shares the simulation entirely with ranked — same physics, same fairness.

## 10. Progression System

**Phase 4, cosmetic-only.** Account XP from match *participation + performance* (not wins alone — losers must still progress or they churn). Levels unlock cosmetic milestones. No power, ever. The progression's job is "reason to return," not "advantage accrued."

## 11. Unlock System

**Phase 4.** Cosmetics gated by level, soft currency, or achievement. Every unlock is **server-granted** — the client requests, the server validates and grants, never the reverse. Unlocks are the bridge between progression and the collection.

## 12. Currency System

**Phase 4 (soft) + Phase 6 (premium).** Soft currency earned through play. Premium currency from Robux. **Both spend only on cosmetics.** Server-authoritative ledger, idempotent grants, anti-dupe/anti-rollback. Soft currency must let free players reach meaningful cosmetics, or the game reads as paywalled.

## 13. Collection System

**Phase 4.** The inventory of owned cosmetics — skins, trails, launch effects, nameplates, emotes. With one Bey, "collection" is necessarily cosmetic breadth, not power breadth. This is the honest answer to the collection-with-one-Bey tension, and it's the *correct* answer for competitive integrity.

## 14. Customization System

**Phase 3/4.** Equip cosmetics onto the universal Bey: skin, trail color, launch VFX, win animation, nameplate. Rendered client-side from IDs in the snapshot. Zero simulation impact — a fully customized Bey and a default Bey are physically identical. This is a hard, audited invariant.

## 15. Quest System

**Phase 4, recommend lean.** Daily/weekly objectives that reward soft currency/XP — but designed to encourage *playing the game as intended* (win with each command, survive a ring-out attempt, win without ring-out), never grind-for-grind's-sake. **Director's note:** quests are a maintenance cost; a small rotating set beats an elaborate quest engine. Cut anything that needs per-quest bespoke logic.

## 16. Achievement System

**Phase 4.** Permanent milestone markers (first win, 100 wins, ring-out master, flawless victory). Reward cosmetics/titles. Lighter-weight than quests — set once, persist forever. Good retention-per-maintenance ratio.

## 17. Tournament System

**Phase 5 — recommend DEFER.** Automated brackets are a significant backend + scheduling + moderation system. At small population it's empty; at scale it's a maintenance burden. **Recommendation: do not build for launch.** Re-evaluate at a defined population trigger (e.g., 10k DAU). The ranked ladder *is* the competitive structure at launch.

## 18. Clan / Team System

**Phase 5 — recommend DEFER or CUT.** Clans are among the highest-maintenance social systems (creation, roles, chat, moderation, clan-vs-clan, leaderboards). For a small team this is a trap. **Recommendation: ship friends + rematch + leaderboards instead; defer clans until population and team capacity justify it.** Be honest with stakeholders that this is a deliberate cut, not an oversight.

## 19. Spectator System

**Phase 5.** Build directly on existing snapshot replication — `DebugStatePublisher` already `FireAllClients`. Extend so non-player clients in the server subscribe to the same snapshot stream and get a spectator camera. Cheap relative to its retention/social value. A natural fit for the existing architecture.

## 20. Replay System

**Phase 5.** `ReplayRecorder` exists but is **in-memory only and resets each match.** To ship replays: (a) serialize the snapshot buffer (switch `Vector3` → `{x,y,z}` per the existing TODO), (b) persist to DataStore, (c) build a playback client that re-renders from snapshots.

**Architectural fork to decide:** snapshot-replay (heavy — 3600 snapshots/match, but robust) vs seed+input-replay (light — store seed + input log, re-simulate). The latter leverages determinism and is far cheaper to store, but requires the sim to be *exactly* reproducible on playback, which the floating-point caveat complicates. Recommendation: start with snapshot-replay (already 90% built), evaluate seed-replay only if storage cost becomes real.

## 21. Anti-Cheat Strategy

The architecture's biggest strength: **server-authoritative simulation.** The client sends only *intents* (`RequestLaunch`, `RequestCommand`), validated by `LaunchValidator` / `CommandValidator` (allowlists, rate limits, single-fire guards, phase/state checks) before touching `MatchState`. The client cannot set position, velocity, or outcome.

Remaining surface: (1) rate-limit/spam — covered by the validators' `os.clock()` windows; (2) automation/scripting inputs — mitigated by command cooldowns capping action density; (3) information — currently all state is broadcast to all clients (fine for a symmetric-information game; revisit only if hidden info is ever added). Phase 8 adds adversarial testing at population. No client-trust ever enters the simulation — that invariant is the whole strategy.

## 22. Data Model

**Does not exist yet — Phase 2 builds it from scratch.** Proposed entities:

- **Player profile:** userId, MMR, rank, XP, level, soft currency, premium currency, equipped cosmetics, settings.
- **Inventory:** owned cosmetic IDs (skins, trails, VFX, nameplates, emotes, titles).
- **Stats:** wins/losses, finish-type counts, per-command usage, ring-outs, by season.
- **Match record:** matchId, seed, playerOrder, participants, result, finish type, duration, replay ref.
- **Economy ledger:** currency grants/spends with idempotency keys.

All server-authoritative, all session-locked.

## 23. Save Architecture

**Roblox DataStore, with every pitfall planned for:**

- **Session locking** to prevent concurrent writes / data loss across servers.
- **`BindToClose`** flush on shutdown.
- **Retry with backoff** on throttle.
- **Versioned schema** with forward-migration (Phase 9 must not lose Phase 4 data).
- **Idempotent purchase grants** (receipt key dedupe) — the classic Roblox double-grant bug.
- **OrderedDataStore** for leaderboards.
- Consider **MemoryStore** for matchmaking queue + transient cross-server state.

This is load-bearing for Phases 2/4/5/6 and must be built carefully once, not bolted on per-system.

## 24. Live Ops Events

**Phase 10, lean.** A reusable event *framework* (not bespoke code per event): time-boxed challenges, themed cosmetic sets, double-XP windows, seasonal stadiums. Driven by live config so events ship without redeploys. The discipline: **one framework, many events** — never a new system per event.

## 25. Analytics Plan

Current telemetry is a per-match **console print** (`TelemetryLogger`). For production this must become **aggregated, persisted analytics** (Phase 8). Funnel: acquisition → onboarding completion → D1/D7/D30 retention → match completion → queue health → economy flow → monetization conversion → balance (per-rank/per-stadium/per-command win rates). The standing **win-rate-neutrality audit** for cosmetics is an analytics-enforced release gate.

## 26. Retention Strategy

Layered: **core fun** (Phase 1 — the foundation; nothing retains if the loop isn't fun) → **mastery** (ranked climb, skill ceiling) → **collection** (cosmetic chase) → **social** (friends, spectate, leaderboards) → **cadence** (seasons, events). Each layer only matters if the one beneath it holds. The honest sequencing risk is building outer layers before the core is proven — which is exactly why Phase 1 gates everything.

## 27. Monetization Strategy

**Cosmetic-only, pay-to-win-free, by constitution.** Premium currency → cosmetics. Optional seasonal cosmetic pass. Rotating store. Gifting. Free players progress cosmetically through play. The competitive integrity (one Bey, skill-decided) is the product's identity and the monetization's guardrail simultaneously — protecting one protects the other. Revenue comes from *expression*, never *advantage*.

## 28. Content Pipeline

The sustainable axes for a small team: **stadiums** (one per season — variety without rebalancing the Bey) and **cosmetics** (skins/trails/VFX — art pipeline, no balance cost). Each stadium passes the harness gate before ship. Each cosmetic passes the neutrality audit (zero win-rate correlation). Avoid content types that require per-item gameplay logic or rebalancing — they don't scale to a small team.

## 29. Technical Architecture

**Current (validated for 1v1):** Phase-pipeline `TickManager` (Input → Physics → Collision → Clamp → StateUpdate → Evaluation → Replication) on a fixed-step accumulator with drift protection. Controllers self-register as phase handlers. Server simulates at 30 Hz, replicates snapshots at 15 Hz, clients interpolate with 150 ms delay. Centralized `Constants`, `Remotes`, `MatchState` schema. `pcall`-isolated phase handlers.

**Required additions by phase:** persistence layer (P2), matchmaking service (P2), server-scaling model — multi-stadium-per-server vs reserved-server-per-match (P2, architectural and hard to reverse — decide early), live-config service (P10), analytics aggregation (P8). The single-match-per-server assumption is the biggest architectural constraint to resolve in Phase 2.

## 30. Production Roadmap

See Part I. The spine: **validate the loop (1) → make it competitive + build the data foundation (2) → add fair variety (3) → cosmetic progression (4) → lean social (5) → cosmetic monetization (6) → polish (7) → beta (8) → launch (9) → sustainable live ops (10).** Phase 1 gates everything. Persistence (P2) is the second gate. Recommended cuts: clans, automated tournaments, elaborate quest engines — defer until population and team capacity justify the maintenance.

---

# DIRECTOR'S BOTTOM LINE

The prototype is **well-architected for what it is and dangerously small for what's being asked of it.** The engineering quality is real — server-authority, fixed-step determinism, clean phase pipeline, honest telemetry. But it is one Bey, three commands, one stadium, **never tested by a human**, with **no persistence, no matchmaking, no data model.** The distance from here to "premium live-service release" is a foundation-up build, not a feature-add.

The roadmap is correctly shaped. The risk is sequencing: every instinct will push toward visible features (cosmetics, clans, monetization) before the invisible foundations (proven fun, persistence, matchmaking) are real. Resist it. **Prove the loop is fun. Build persistence once, carefully. Cut the social systems you can't maintain. Keep the simulation sacred and cosmetic-only forever.** Do those four things and this becomes a real game.
