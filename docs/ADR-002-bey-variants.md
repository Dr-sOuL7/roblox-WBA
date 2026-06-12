# ADR-002: Bey variants — cosmetic-only, locked

**Status:** Accepted and LOCKED (Phase 3 completion criterion) · **Date:** 2026-06-10

## Context

Phase 3 must resolve the tension the plan names honestly: "Collection" and
"Customization" with one Bey can only be cosmetic — unless the vision relaxes
to Bey *variants* (different feel, equal power).

## Decision

**No Bey variants. One Bey, identical physics for every player, permanently.**
Variety ships through stadiums (spatial play) and cosmetics (expression).
Customization equips skins, trails, launch VFX, nameplates — rendering-only,
from IDs in the snapshot, never entering `BeyState` physics fields.

## Rationale

1. The plan's own recommendation (§Phase 3 risks, GDD §3): sidegrades are "a
   multi-month balance commitment and one step from pay-to-win." A small team
   cannot carry fighting-game character balance on top of everything else.
2. The one-Bey rule is the product's competitive identity AND its monetization
   guardrail (GDD §27): wins are skill, purchases are expression. Variants
   blur exactly the line the project must keep sharp.
3. Every system built since Phase 1 (harness bands, neutrality audits,
   stadium gates) assumes a single physics identity. Variants would multiply
   every validation matrix by the variant count.

## Re-evaluation trigger

Only if BOTH hold, and then only as a deliberate vision change with full
stakeholder sign-off: (a) sustained population > 10k DAU with retention data
showing variety exhaustion that stadiums + cosmetics cannot address, and
(b) team capacity for a permanent balance discipline. Until then, proposals
to add Bey types/classes/stats are out of scope by constitution.

## Enforcement

- `MatchState.createBeyState` stays the single Bey definition; cosmetic IDs
  never modify simulation fields (audited invariant, GDD §14).
- The Phase 3+ cosmetic pipeline carries a standing win-rate-neutrality audit;
  any purchasable/equippable item correlating with win rate is a release
  blocker (GDD §25).
