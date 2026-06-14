--[=[
	BeyParts.lua
	The crafting catalog + stat derivation (ADR-003). PURE MODULE — no Roblox
	APIs in the derivation; headless-tested.

	A build = 4 parts (Tip / Disc / Blade / Core), each with:
	  shape  (id from this catalog), height, weight (both clamped), color (cosmetic).

	Derivation (sidegrade / conserved budget):
	  Each part contributes to four stat axes — Attack, Defense, Stamina, Agility
	  — via its shape's affinity, scaled by its weight and biased by its height
	  (taller = higher centre of gravity → more Attack/Agility, less Defense/
	  Stamina). The four raw totals are normalized to FRACTIONS that sum to 1, so
	  no build has more total power — only a different distribution. Multipliers
	  applied to the simulation are `1 + GAIN*(fraction - 0.25)`, so the neutral
	  build (every fraction 0.25) yields all multipliers = 1.0 and reproduces the
	  validated baseline EXACTLY. GAIN is the single "how much build matters" dial.

	Colour never enters derivation (cosmetic).
]=]

local BeyParts = {}

BeyParts.SLOTS = { "Tip", "Disc", "Blade", "Core" }
BeyParts.STATS = { "Attack", "Defense", "Stamina", "Agility" }

-- How strongly build distribution swings the sim multipliers. Tuned via the
-- build-matrix gate (no archetype may dominate). 0 = builds are cosmetic.
BeyParts.STAT_GAIN = 0.5
-- Height centre-of-gravity bias strength (tall → A/G up, D/S down).
BeyParts.HEIGHT_BIAS = 0.5

-- Per-slot property limits (height in studs, weight in abstract units).
-- Defaults sit at the midpoints so the neutral build is exactly centred.
BeyParts.LIMITS = {
	Tip   = { height = { min = 0.5, max = 2.0 }, weight = { min = 1, max = 10 } },
	Disc  = { height = { min = 0.4, max = 1.6 }, weight = { min = 2, max = 14 } },
	Blade = { height = { min = 0.6, max = 2.6 }, weight = { min = 1, max = 12 } },
	Core  = { height = { min = 0.3, max = 1.4 }, weight = { min = 1, max = 8 } },
}

local function midpoint(range)
	return (range.min + range.max) / 2
end

-- ── Shape catalog ─────────────────────────────────────────────────────────────
-- affinity {a,d,s,g} need not sum to 1 here; derivation normalizes. "Standard"
-- (balanced 1/1/1/1) is each slot's neutral default. render{} is consumed by the
-- model builder (later); derivation ignores it. Generous + wild per the brief.

local function shape(id, name, a, d, s, g, render)
	return { id = id, name = name, a = a, d = d, s = s, g = g, render = render or {} }
end

BeyParts.SHAPES = {
	Tip = {
		shape("Standard", "Standard",    1, 1, 1, 1, { kind = "cone", sides = 12, radius = 0.5 }),
		shape("Needle",   "Needle",      1, 0, 1, 4, { kind = "point", sides = 6, radius = 0.12 }),
		shape("Spike",    "Spike",       3, 0, 0, 3, { kind = "point", sides = 4, radius = 0.18 }),
		shape("Ball",     "Ball Bearing",1, 2, 2, 2, { kind = "ball", radius = 0.45 }),
		shape("Flat",     "Flat",        0, 3, 4, 1, { kind = "cylinder", radius = 0.7 }),
		shape("WideFlat", "Wide Flat",   0, 4, 5, 0, { kind = "cylinder", radius = 1.0 }),
		shape("Dome",     "Dome",        1, 3, 3, 1, { kind = "ball", radius = 0.6 }),
		shape("Claw",     "Claw",        3, 1, 0, 3, { kind = "claw", sides = 3, radius = 0.4 }),
		shape("Rubber",   "Rubber Grip", 2, 3, 0, 2, { kind = "cylinder", radius = 0.55, material = "rubber" }),
		shape("Cone",     "Sharp Cone",  2, 0, 1, 4, { kind = "cone", sides = 16, radius = 0.3 }),
		shape("Twin",     "Twin Point",  2, 1, 1, 2, { kind = "twin", radius = 0.35 }),
		shape("Crystal",  "Crystal",     4, 0, 0, 4, { kind = "point", sides = 8, radius = 0.2, wild = true }),
		shape("Hollow",   "Hollow Ring", 0, 2, 4, 1, { kind = "ring", radius = 0.8 }),
	},
	Disc = {
		shape("Standard", "Standard",    1, 1, 1, 1, { kind = "disc", sides = 16, radius = 1.7 }),
		shape("Round",    "Round Heavy", 0, 2, 5, 0, { kind = "disc", sides = 24, radius = 1.8 }),
		shape("Heavy",    "Heavy Core",  1, 3, 4, 0, { kind = "disc", sides = 12, radius = 1.6 }),
		shape("Wide",     "Wide Frame",  0, 3, 4, 1, { kind = "disc", sides = 20, radius = 2.0 }),
		shape("Gear",     "Gear",        3, 2, 1, 1, { kind = "gear", sides = 10, radius = 1.7, wild = true }),
		shape("Star",     "Star",        4, 1, 0, 2, { kind = "star", points = 5, radius = 1.8, wild = true }),
		shape("Eccentric","Eccentric",   3, 0, 1, 4, { kind = "eccentric", radius = 1.7, wild = true }),
		shape("Shield",   "Shield",      0, 5, 2, 0, { kind = "disc", sides = 8, radius = 1.7 }),
		shape("Oval",     "Oval",        1, 3, 3, 1, { kind = "oval", radius = 1.7 }),
		shape("Turbine",  "Turbine",     1, 1, 3, 3, { kind = "turbine", blades = 8, radius = 1.7, wild = true }),
		shape("Cross",    "Cross",       3, 1, 1, 2, { kind = "cross", radius = 1.7 }),
		shape("Solid",    "Solid Plate", 0, 4, 3, 0, { kind = "disc", sides = 32, radius = 1.7 }),
	},
	Blade = {
		shape("Standard", "Standard",    1, 1, 1, 1, { kind = "ring", sides = 12, radius = 2.4 }),
		shape("Ring",     "Smooth Ring", 0, 3, 3, 1, { kind = "ring", sides = 32, radius = 2.4 }),
		shape("Spike",    "Spike Ring",  4, 0, 1, 2, { kind = "spikes", spikes = 6, radius = 2.5 }),
		shape("Star",     "Star Blade",  4, 1, 0, 2, { kind = "star", points = 5, radius = 2.5, wild = true }),
		shape("Shuriken", "Shuriken",    5, 0, 0, 2, { kind = "spikes", spikes = 4, radius = 2.6, wild = true }),
		shape("Sawblade", "Sawblade",    5, 0, 1, 1, { kind = "spikes", spikes = 12, radius = 2.5, wild = true }),
		shape("Wing",     "Wing",        3, 1, 0, 3, { kind = "wing", wings = 3, radius = 2.5 }),
		shape("Round",    "Round Guard", 0, 4, 2, 1, { kind = "ring", sides = 48, radius = 2.4 }),
		shape("Bumper",   "Bumper",      2, 3, 1, 0, { kind = "bumper", bumps = 6, radius = 2.4 }),
		shape("Cross",    "Cross Blade", 3, 1, 1, 2, { kind = "cross", radius = 2.5 }),
		shape("Hexa",     "Hexa",        2, 2, 1, 1, { kind = "ring", sides = 6, radius = 2.4 }),
		shape("Claw",     "Claw Ring",   4, 0, 0, 3, { kind = "claw", claws = 3, radius = 2.6, wild = true }),
		shape("Orb",      "Orb Guard",   0, 4, 3, 0, { kind = "ring", sides = 64, radius = 2.3 }),
	},
	Core = {
		shape("Standard", "Standard",    1, 1, 1, 1, { kind = "crown", sides = 8, radius = 0.8 }),
		shape("Crown",    "Crown",       1, 2, 2, 1, { kind = "crown", sides = 6, radius = 0.9 }),
		shape("Orb",      "Orb",         0, 3, 3, 1, { kind = "ball", radius = 0.7 }),
		shape("Spike",    "Spike Core",  4, 0, 1, 2, { kind = "point", sides = 4, radius = 0.5 }),
		shape("Hollow",   "Hollow",      1, 0, 2, 4, { kind = "ring", radius = 0.7 }),
		shape("Heavy",    "Heavy Crown", 0, 4, 3, 0, { kind = "crown", sides = 4, radius = 0.8 }),
		shape("Wing",     "Wing Core",   2, 0, 1, 4, { kind = "wing", wings = 4, radius = 0.8 }),
		shape("Star",     "Star Core",   4, 1, 0, 2, { kind = "star", points = 5, radius = 0.8, wild = true }),
		shape("Twin",     "Twin Core",   2, 2, 1, 2, { kind = "twin", radius = 0.7 }),
		shape("Gem",      "Gemstone",    2, 2, 2, 2, { kind = "gem", radius = 0.6, wild = true }),
		shape("Spire",    "Spire",       3, 0, 1, 3, { kind = "point", sides = 8, radius = 0.4 }),
		shape("Plate",    "Plate",       0, 4, 3, 0, { kind = "cylinder", radius = 0.9 }),
	},
}

-- Fast lookup: slot -> id -> shapeDef
local _shapeIndex = {}
for slot, list in pairs(BeyParts.SHAPES) do
	_shapeIndex[slot] = {}
	for _, def in ipairs(list) do
		_shapeIndex[slot][def.id] = def
	end
end

function BeyParts.getShape(slot, shapeId)
	local bySlot = _shapeIndex[slot]
	if not bySlot then return nil end
	return bySlot[shapeId] or bySlot["Standard"]
end

-- ── Default (neutral) build — the regression anchor ──────────────────────────
-- Standard shape (balanced affinity) + midpoint height/weight in every slot →
-- every stat fraction = 0.25 → every multiplier = 1.0 → validated baseline.

function BeyParts.defaultBuild()
	local build = {}
	for _, slot in ipairs(BeyParts.SLOTS) do
		local limits = BeyParts.LIMITS[slot]
		build[slot] = {
			shape = "Standard",
			height = midpoint(limits.height),
			weight = midpoint(limits.weight),
			color = { 170, 175, 185 }, -- cosmetic; editor overrides
		}
	end
	return build
end

-- ── Validation / clamping (server-authoritative) ─────────────────────────────

local function clampNumber(value, range, fallback)
	value = tonumber(value)
	if not value then return fallback end
	return math.clamp(value, range.min, range.max)
end

local function clampColor(color)
	if type(color) ~= "table" then return { 170, 175, 185 } end
	local function ch(v) return math.clamp(math.floor(tonumber(v) or 170), 0, 255) end
	return { ch(color[1]), ch(color[2]), ch(color[3]) }
end

-- Returns a fully valid part (unknown shapes → Standard, out-of-range clamped)
function BeyParts.clampPart(slot, part)
	local limits = BeyParts.LIMITS[slot]
	part = type(part) == "table" and part or {}
	local shapeDef = BeyParts.getShape(slot, part.shape)
	return {
		shape = shapeDef.id,
		height = clampNumber(part.height, limits.height, midpoint(limits.height)),
		weight = clampNumber(part.weight, limits.weight, midpoint(limits.weight)),
		color = clampColor(part.color),
	}
end

-- Returns a fully valid build (every slot present and clamped)
function BeyParts.clampBuild(build)
	build = type(build) == "table" and build or {}
	local clean = {}
	for _, slot in ipairs(BeyParts.SLOTS) do
		clean[slot] = BeyParts.clampPart(slot, build[slot])
	end
	return clean
end

-- ── Derivation ────────────────────────────────────────────────────────────────

local function heightFraction(slot, height)
	local range = BeyParts.LIMITS[slot].height
	return (height - range.min) / (range.max - range.min) -- 0..1
end

--[=[
	deriveStats(build) -> {
	  fractions = { Attack, Defense, Stamina, Agility },  -- sum == 1
	  multipliers = { Attack, Defense, Stamina, Agility }, -- ~1.0, neutral = 1
	}
	Accepts a raw or clamped build (clamps internally).
]=]
function BeyParts.deriveStats(build)
	local clean = BeyParts.clampBuild(build)
	local raw = { Attack = 0, Defense = 0, Stamina = 0, Agility = 0 }

	for _, slot in ipairs(BeyParts.SLOTS) do
		local part = clean[slot]
		local def = BeyParts.getShape(slot, part.shape)
		local w = part.weight
		local hNorm = heightFraction(slot, part.height)
		local d = (hNorm - 0.5) * BeyParts.HEIGHT_BIAS -- ~[-0.25, 0.25]
		raw.Attack  += def.a * w * (1 + d)
		raw.Agility += def.g * w * (1 + d)
		raw.Defense += def.d * w * (1 - d)
		raw.Stamina += def.s * w * (1 - d)
	end

	local total = raw.Attack + raw.Defense + raw.Stamina + raw.Agility
	local fractions, multipliers = {}, {}
	if total <= 0 then
		-- Degenerate (all-zero affinity) → treat as neutral
		for _, stat in ipairs(BeyParts.STATS) do
			fractions[stat] = 0.25
			multipliers[stat] = 1.0
		end
		return { fractions = fractions, multipliers = multipliers }
	end

	for _, stat in ipairs(BeyParts.STATS) do
		local frac = raw[stat] / total
		fractions[stat] = frac
		multipliers[stat] = 1 + BeyParts.STAT_GAIN * (frac - 0.25)
	end
	return { fractions = fractions, multipliers = multipliers }
end

return BeyParts
