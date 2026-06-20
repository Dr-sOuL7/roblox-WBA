--[=[
	BeyParts.lua
	Craft-driven Bey definition (ADR-003 preserved and extended).

	A Bey is built from four parts — BLADE (outer top / attack layer),
	DISC (middle / mass), CORE (inner top / structure) and TIP (bottom / control).
	Each part contributes raw physical attributes. `computeProfile` aggregates a
	loadout into:
	  • mods    — the 4 gameplay stats (Attack / Defense / Stamina / Agility)
	  • a physical profile used by the part-based damage model (attackHeight,
	    shape factors, mass, burst resistance, low-centre, friction).

	This module is pure (no Roblox services) so the server, client and the
	headless harness all derive identical numbers from the same loadout.
]=]

local BeyParts = {}

-- ── Part registries ───────────────────────────────────────────────────────────
-- attackHeight ∈ [0,1]: where this Bey's blade lands (0 = tip-low, 1 = upper/core).
-- shape factors ∈ [0,1]: aggression (jagged → burst+recoil), width (flat → push),
-- point (sharp → destabilize), round (smooth → glance + stamina).

BeyParts.BLADES = {
	Balance = { attackPower = 1.00, attackHeight = 0.58, aggression = 0.55, width = 0.50, point = 0.45, round = 0.45 },
	Smash   = { attackPower = 1.22, attackHeight = 0.82, aggression = 0.85, width = 0.40, point = 0.60, round = 0.20 }, -- upper / smash
	Guard   = { attackPower = 0.82, attackHeight = 0.50, aggression = 0.35, width = 0.72, point = 0.30, round = 0.72 }, -- round / defensive
}

BeyParts.DISCS = {
	Heavy = { mass = 1.30, balance = 0.72 },
	Mid   = { mass = 1.00, balance = 0.85 },
	Light = { mass = 0.76, balance = 0.92 },
}

BeyParts.CORES = {
	Iron     = { burstResistance = 1.25, integrity = 1.20 },
	Standard = { burstResistance = 1.00, integrity = 1.00 },
	Hollow   = { burstResistance = 0.78, integrity = 0.85 }, -- fragile, pairs with attack builds
}

BeyParts.TIPS = {
	Flat  = { friction = 1.25, lowCenter = 0.85, agility = 1.22 }, -- aggressive, drains fast
	Ball  = { friction = 1.00, lowCenter = 1.00, agility = 1.00 },
	Sharp = { friction = 0.80, lowCenter = 1.15, agility = 0.85 }, -- stamina, low movement
}

-- ── Preset loadouts ────────────────────────────────────────────────────────────

BeyParts.DEFAULT_LOADOUT = { blade = "Balance", disc = "Mid", core = "Standard", tip = "Ball" }

BeyParts.PRESETS = {
	Balanced = { blade = "Balance", disc = "Mid",   core = "Standard", tip = "Ball" },
	Attacker = { blade = "Smash",   disc = "Heavy", core = "Hollow",   tip = "Flat" },
	-- Defender walls up (tank + burst-immune) but its Ball tip gives it only
	-- mediocre stamina — a grinder out-spins it.
	Defender = { blade = "Guard",   disc = "Heavy", core = "Iron",     tip = "Ball" },
	Stamina  = { blade = "Guard",   disc = "Light", core = "Standard", tip = "Sharp" },
}

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

-- Resolve a loadout (with fallbacks) into the part attribute tables.
function BeyParts.resolve(loadout)
	loadout = loadout or BeyParts.DEFAULT_LOADOUT
	return BeyParts.BLADES[loadout.blade] or BeyParts.BLADES.Balance,
		BeyParts.DISCS[loadout.disc] or BeyParts.DISCS.Mid,
		BeyParts.CORES[loadout.core] or BeyParts.CORES.Standard,
		BeyParts.TIPS[loadout.tip] or BeyParts.TIPS.Ball
end

--[=[
	computeProfile(loadout) -> profile
	profile = {
		loadout = <copy>,
		mods = { Attack, Defense, Stamina, Agility },
		mass, attackHeight, aggression, width, point, round,
		burstResistance, integrity, balance, lowCenter, friction,
		maxHp,
	}
]=]
function BeyParts.computeProfile(loadout)
	local blade, disc, core, tip = BeyParts.resolve(loadout)

	local Attack = clamp(blade.attackPower * (0.90 + 0.20 * blade.aggression), 0.70, 1.35)
	local Defense = clamp(0.45 * core.integrity + 0.30 * disc.mass + 0.25 * tip.lowCenter, 0.70, 1.35)
	local Stamina = clamp(0.45 + 0.35 * blade.round + 0.25 * (1.30 - tip.friction) + 0.20 * disc.balance, 0.70, 1.35)
	local Agility = clamp(0.55 + 0.45 * tip.agility - 0.20 * (disc.mass - 1.00), 0.70, 1.35)

	return {
		loadout = {
			blade = loadout and loadout.blade or "Balance",
			disc = loadout and loadout.disc or "Mid",
			core = loadout and loadout.core or "Standard",
			tip = loadout and loadout.tip or "Ball",
		},
		mods = { Attack = Attack, Defense = Defense, Stamina = Stamina, Agility = Agility },

		mass = disc.mass,
		attackHeight = blade.attackHeight,
		aggression = blade.aggression,
		width = blade.width,
		point = clamp(blade.point + (tip.friction < 1.0 and 0.10 or 0.0), 0, 1), -- sharp tips destabilize a touch more
		round = blade.round,

		burstResistance = core.burstResistance,
		integrity = core.integrity,
		balance = disc.balance,
		lowCenter = tip.lowCenter,
		friction = tip.friction,
	}
end

-- maxHp depends on a constant that lives outside this pure module; expose a helper
-- so callers (which already have Constants) can finalize it without a circular require.
function BeyParts.maxHpFor(profile, baseMaxHp)
	return math.floor(baseMaxHp * (0.60 + 0.40 * profile.mods.Stamina) + 0.5)
end

return BeyParts
