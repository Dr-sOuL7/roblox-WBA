# ADR-003: Craft-driven Beys — supersedes ADR-002 (one-Bey)

**Status:** Accepted (Director decision, 2026-06-14) · **Supersedes:** ADR-002

## Context

ADR-002 locked the game to one identical Bey with identical physics, with a
re-evaluation trigger (10k DAU + team capacity). The Director has chosen to
pivot earlier: a deep 4-part crafting system (TIP / DISC / BLADE / CORE) where
**how you build your Bey affects how it fights**. This overturns ADR-002 and
GDD §3's "one Bey, period."

## Decision

Beys are **crafted from 4 parts**, and the build **affects battle** — but under
three guardrails chosen by the Director that preserve competitive integrity:

1. **Sidegrade, equal power (conserved budget).** A build determines the
   *distribution* of power across four stat axes — **Attack, Defense, Stamina,
   Agility** — not its magnitude. The derived stat vector is normalized to a
   fixed budget, so no build is objectively stronger; builds differ in *style*,
   like real Beyblade's Attack→Stamina→Defense→Attack triangle. There is no
   "max everything" build.
2. **Free and equal access.** Every part, shape, height, and weight option is
   available to every player from the start. Build power is a knowledge/matchup
   skill, never a purchase. **The no-pay-to-win pillar still holds** — crafting
   is never monetized; cosmetics (colour, and cosmetic-only flourishes) remain
   the monetization axis.
3. **Preset shapes only (a large catalog).** Parts use a rich library of preset
   shapes with dimension/height/weight sliders (bounded). No freeform
   hand-drawing — it is intractable to balance and to stop degenerate shapes.

## Invariants (enforced)

- **Default build == the validated baseline.** The neutral default build yields
  all four stat multipliers = 1.0, so an un-customized Bey reproduces the
  Phase 1/3 validated simulation *exactly*. This is the regression anchor.
- **Conserved budget.** Σ(stat fractions) = 1 by construction → boosting one
  stat necessarily lowers others. Proven in headless tests.
- **No dominant build.** A new harness gate runs an archetype build-matrix
  (Attacker/Defender/Stamina/Agile/Balanced) and fails if any archetype exceeds
  the dominance ceiling — the build analogue of the command-dominance gate.
- **Server-authoritative.** The client sends only part choices (shape id,
  height, weight, colour); the server clamps every value, validates shape ids,
  derives stats, and builds the simulation modifiers. Colour is cosmetic and
  never enters derivation.

## Consequences

- `BeyParts.lua` (pure) owns the catalog + derivation; headless-tested.
- The profile schema gains a validated `build`; the editor venue writes it.
- PhysicsController / SpinEvaluator / BeyController read per-Bey stat multipliers
  (default 1.0). The single-Bey assumption in those modules is replaced by
  per-Bey modifiers — but the default path is unchanged.
- The cosmetic neutrality audit (ADR-002 era) still applies to **colour**:
  colour must not correlate with win rate. Shapes/weights DO affect battle by
  design now (the sidegrade), so they are excluded from that audit and covered
  instead by the no-dominant-build gate.

## Re-evaluation

If the build-matrix gate cannot be kept within bands despite tuning, fall back
toward narrower stat gains (less build impact) rather than abandoning fairness.
The sidegrade guarantee (equal power) is non-negotiable; build *impact* is a dial.
