# ADR-001: Server scaling model — multiple stadiums per server

**Status:** Accepted (Phase 2) · **Date:** 2026-06-10

## Context

The plan (§Phase 2, §29) requires choosing between two models before matchmaking
is built, because the choice shapes MatchManager, matchmaking, and reconnects —
and is "architectural and hard to reverse":

- **A. Reserved server per match** — each ranked match teleports 2 players to a
  dedicated instance.
- **B. N stadiums per server** — one server simulates several concurrent matches.

The current code assumes one match per server (module-level singletons in
`TickManager`/`MatchManager`).

## Decision

**B — multiple stadiums per server**, with a per-match simulation instance
(`MatchInstance`) replacing the singletons.

## Rationale

1. **Population reality.** At launch population, reserved servers fragment
   players: every match pays teleport latency (5–15 s), kills "one more match"
   flow, and empties the social space. Multi-stadium keeps queues and rematches
   instant on warm servers.
2. **Phase 5 leverage.** Spectating builds directly on snapshot replication to
   co-present players — free in model B, a cross-server streaming project in A.
3. **Cost & ops.** One 30 Hz match costs ~2 beys × 3 sub-steps of arithmetic —
   trivial CPU. A 50-player server comfortably hosts 10+ concurrent matches.
   Reserved servers multiply instance count and cold-start overhead.
4. **The sim is already isolation-friendly.** All match state lives in one
   `MatchState` table; phase handlers receive it as a parameter. The refactor
   is confining the remaining singleton state, not untangling shared state.
5. **Reversibility hedge.** B's `MatchInstance` abstraction is exactly what A
   would run one-of per reserved server — if high-stakes ranked ever wants
   dedicated instances (Phase 8+ data may say so), B's code runs inside A
   unchanged. The reverse migration (A→B) would be the expensive one.

## Consequences

- Next cycle refactors `TickManager` (module-level `_activeMatchState`,
  `_phases`, RNG) and `MatchManager` (single stadium, fixed spawn origin,
  workspace-name collisions like `Bey_<uid>` / `StadiumFloor`) into
  per-instance state: `MatchInstance.new(players, stadiumSlot)` with its own
  tick loop, arena origin offset, and namespaced workspace folder.
- Snapshot remotes gain a `matchId` and clients filter to their own match
  (`FireAllClients` → per-recipient send to participants; spectators subscribe
  in Phase 5).
- Validators route inputs by player → match instance membership.
- The harness keeps using the same `MatchInstance` API headless (one instance,
  stepped manually) — no fork between live and headless paths.
