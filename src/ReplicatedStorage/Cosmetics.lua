--[=[
	Cosmetics.lua
	Cosmetic skin registry (plan §Phase 3, GDD §13/§14).

	HARD INVARIANT (audited): cosmetics are rendering-only. Nothing in this
	registry is ever read by the simulation — a fully customized Bey and a
	default Bey are physically identical. The headless suite proves it by
	construction (identical seeds ± cosmetics → identical outcomes), and the
	live neutrality audit watches per-skin win rates for drift.

	Team identity lives on the BLADES (red/blue, applied by MatchManager), so
	skins can restyle the ring/disc/bit without blurring whose Bey is whose.

	Phase 3 ships starter skins (all owned by default). Phase 4 adds earned
	unlocks through the same ownership fields; Phase 6 adds purchased ones.
	Ownership is always validated server-side.
]=]

local Cosmetics = {}

Cosmetics.DEFAULT_SKIN = "Default"

Cosmetics.SKINS = {
	Default = {
		id = "Default",
		displayName = "Factory Steel",
		description = "The original. Honest metal.",
		starterOwned = true,
		ringColor = Color3.fromRGB(170, 175, 185),
		discColor = Color3.fromRGB(150, 160, 170),
		bitColor = Color3.fromRGB(255, 255, 255),
	},
	Crimson = {
		id = "Crimson",
		displayName = "Crimson Fang",
		description = "Bites first.",
		starterOwned = true,
		ringColor = Color3.fromRGB(165, 35, 35),
		discColor = Color3.fromRGB(60, 25, 25),
		bitColor = Color3.fromRGB(255, 90, 70),
	},
	Abyss = {
		id = "Abyss",
		displayName = "Abyss",
		description = "Pressure from the deep.",
		starterOwned = true,
		ringColor = Color3.fromRGB(30, 50, 110),
		discColor = Color3.fromRGB(20, 30, 60),
		bitColor = Color3.fromRGB(90, 220, 255),
	},
	Verdant = {
		id = "Verdant",
		displayName = "Verdant Edge",
		description = "Grows on you. Then cuts.",
		starterOwned = true,
		ringColor = Color3.fromRGB(45, 120, 60),
		discColor = Color3.fromRGB(30, 60, 40),
		bitColor = Color3.fromRGB(150, 255, 130),
	},
	Solar = {
		id = "Solar",
		displayName = "Solar Crown",
		description = "Burns brightest mid-spin.",
		starterOwned = true,
		ringColor = Color3.fromRGB(220, 150, 40),
		discColor = Color3.fromRGB(120, 80, 30),
		bitColor = Color3.fromRGB(255, 230, 120),
	},
	Void = {
		id = "Void",
		displayName = "Void Walker",
		description = "What the rim sees last.",
		starterOwned = true,
		ringColor = Color3.fromRGB(40, 30, 55),
		discColor = Color3.fromRGB(25, 20, 35),
		bitColor = Color3.fromRGB(200, 110, 255),
	},
}

function Cosmetics.get(skinId)
	return Cosmetics.SKINS[skinId] or Cosmetics.SKINS[Cosmetics.DEFAULT_SKIN]
end

-- Server-side ownership check (GDD §11: the server validates, never the client)
function Cosmetics.canEquip(skinId, ownedCosmetics): boolean
	local def = Cosmetics.SKINS[skinId]
	if not def then
		return false
	end
	if def.starterOwned then
		return true
	end
	return ownedCosmetics ~= nil and ownedCosmetics[skinId] == true
end

-- All skins a profile may equip (starter set ∪ owned)
function Cosmetics.ownedSkinIds(ownedCosmetics)
	local ids = {}
	for id, def in pairs(Cosmetics.SKINS) do
		if def.starterOwned or (ownedCosmetics and ownedCosmetics[id] == true) then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

function Cosmetics.validate(def): (boolean, string?)
	if type(def.id) ~= "string" or def.id == "" then
		return false, "missing id"
	end
	if type(def.displayName) ~= "string" then
		return false, "missing displayName"
	end
	if not (def.ringColor and def.discColor and def.bitColor) then
		return false, "missing colors"
	end
	return true, nil
end

return Cosmetics
