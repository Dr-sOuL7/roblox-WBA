--[=[
	Stadiums.lua
	Stadium registry — the game's sanctioned content axis (Phase 3, GDD §5).

	Every stadium is a FLAT, WALLED circular arena (no bowl, no ring-out). They
	vary SPATIAL play only: the play radius, wall restitution, and entry speed.
	All stadiums are radially symmetric by construction, so neither seat ever has
	a positional advantage. The Bey is identical everywhere — that invariant is
	constitutional (see docs/ADR-002).

	Classic IS the baseline the battle balance was tuned on (radius ==
	Constants.StadiumRadius) and must never drift from it.

	Adding a stadium:
	  1. Add an entry here (radius / wallBounce are the spatial dials).
	  2. Gate it headless: _G.RunStadiumGate("YourId") — full band check.
	  3. Add to ROTATION only after the gate passes.
]=]

local Constants = require(script.Parent:WaitForChild("Constants"))

local Stadiums = {}

Stadiums.DEFAULT_ID = "Classic"

Stadiums.REGISTRY = {
	Classic = {
		id = "Classic",
		displayName = "Classic Arena",
		description = "The standard flat arena. Balanced in every direction.",
		radius = Constants.StadiumRadius,        -- the validated baseline (22)
		wallBounce = Constants.StadiumWallBounce,
		floorColor = { 245, 245, 250 },
		wallColor = { 90, 130, 255 },
	},
	Compact = {
		id = "Compact",
		displayName = "Compact Pit",
		description = "Tighter and meaner than Classic. Pressure arrives early.",
		radius = 17,
		wallBounce = 0.70,                        -- livelier walls in tight space
		floorColor = { 250, 235, 235 },
		wallColor = { 255, 110, 90 },
		launchSpeedScale = 0.85,                  -- gentler entries for the shorter flight
	},
	Grand = {
		id = "Grand",
		displayName = "Grand Coliseum",
		description = "Wide arena. Spacing, chases, and patience win here.",
		radius = 28,
		wallBounce = 0.62,
		floorColor = { 238, 245, 238 },
		wallColor = { 90, 220, 140 },
		launchSpeedScale = 1.20,                  -- big space, big entries
	},
}

-- Ranked/casual rotation pool. Entries must exist in REGISTRY and have passed
-- the per-stadium harness gate before shipping here.
Stadiums.ROTATION = { "Classic", "Compact", "Grand" }

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
	if not (def.radius and def.radius > Constants.BeyRadius * 4) then
		return false, "radius too small to fight in"
	end
	if not (def.wallBounce and def.wallBounce >= 0 and def.wallBounce <= 1) then
		return false, "wallBounce must be in [0,1]"
	end
	return true, nil
end

return Stadiums
