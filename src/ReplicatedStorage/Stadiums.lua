--[=[
	Stadiums.lua
	Stadium registry — the game's sanctioned content axis (plan §Phase 3, GDD §5).

	Every stadium varies SPATIAL play only: bowl size, rim, centre pull. All
	stadiums are radially symmetric by construction (parameters are radial), so
	neither seat ever has a positional advantage. The Bey is identical
	everywhere — that invariant is constitutional (see docs/ADR-002).

	Classic references Constants directly: it IS the baseline the entire
	validation history was tuned on, and must never drift from it.

	Adding a stadium:
	  1. Add an entry here (geometry + bowlForce are the spatial dials).
	  2. Gate it headless: _G.RunStadiumGate("YourId") — full band check.
	     A stadium pushing ring-out > 30% band or duration < 15 s gets cut
	     or retuned, per the plan's balancing rule.
	  3. Add to ROTATION only after the gate passes.
]=]

local Constants = require(script.Parent:WaitForChild("Constants"))

local Stadiums = {}

Stadiums.DEFAULT_ID = "Classic"

Stadiums.REGISTRY = {
	Classic = {
		id = "Classic",
		displayName = "Classic Bowl",
		description = "The standard arena. Balanced in every direction.",
		bowlSphereRadius = Constants.BowlSphereRadius, -- floor curvature
		playableRadius = Constants.BowlPlayableRadius, -- ring-out boundary
		rimBuffer = Constants.BowlRimBuffer,           -- BeyRadius multiplier
		bowlForce = Constants.BowlForce,               -- ambient centre pull
	},
}

-- Ranked/casual rotation pool. Entries must exist in REGISTRY and have
-- passed the per-stadium harness gate before shipping here.
Stadiums.ROTATION = { "Classic" }

function Stadiums.get(stadiumId)
	return Stadiums.REGISTRY[stadiumId] or Stadiums.REGISTRY[Stadiums.DEFAULT_ID]
end

-- Deterministic rotation pick (seeded by match seed: reproducible, fair)
function Stadiums.pickForSeed(seed: number): string
	return Stadiums.ROTATION[(seed % #Stadiums.ROTATION) + 1]
end

-- Sanity contract for registry entries (enforced by the headless tests)
function Stadiums.validate(def): (boolean, string?)
	if type(def.id) ~= "string" or def.id == "" then
		return false, "missing id"
	end
	if not (def.playableRadius and def.playableRadius > Constants.BeyRadius * 4) then
		return false, "playableRadius too small to fight in"
	end
	if not (def.bowlSphereRadius and def.bowlSphereRadius > def.playableRadius) then
		return false, "bowlSphereRadius must exceed playableRadius"
	end
	if not (def.rimBuffer and def.rimBuffer > 0) then
		return false, "rimBuffer must be positive"
	end
	if not (def.bowlForce and def.bowlForce >= 0) then
		return false, "bowlForce must be non-negative"
	end
	return true, nil
end

return Stadiums
