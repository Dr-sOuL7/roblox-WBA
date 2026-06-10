--[=[
	ProfileSchema.lua
	Versioned player profile schema (GDD §22 data model) + migration table.

	PURE MODULE — no Roblox API calls. Headless-testable under tools/harness-runner.

	Versioning rules:
	  * Additive fields do NOT need a migration: ProfileLogic.reconcile fills
	    missing keys from defaults on every load.
	  * Shape changes (rename/move/retype) DO need an entry in MIGRATIONS.
	  * SCHEMA_VERSION bumps only when a migration is added.
]=]

local ProfileSchema = {}

ProfileSchema.SCHEMA_VERSION = 1

-- Defaults are deep-copied per player by ProfileLogic.reconcile.
-- Fields are reserved per the approved data model even when their systems
-- arrive in later phases (XP/currency = Phase 4, premium = Phase 6) so those
-- phases ship without a schema migration. Their LOGIC stays out until then.
function ProfileSchema.defaults()
	return {
		-- Phase 2: ranked foundation
		mmr = 1000,
		rankedWins = 0,
		rankedLosses = 0,

		-- Lifetime stats (recorded from match results)
		stats = {
			wins = 0,
			losses = 0,
			draws = 0,
			matchesPlayed = 0,
			finishesBy = { SpinOut = 0, WobbleCollapse = 0, RingOut = 0 },
			lossesBy = { SpinOut = 0, WobbleCollapse = 0, RingOut = 0 },
		},

		-- Phase 4 reservations (no earn/spend logic until Phase 4)
		xp = 0,
		level = 1,
		softCurrency = 0,

		-- Phase 6 reservation (no purchase logic until Phase 6)
		premiumCurrency = 0,

		-- Phase 3/4 reservations
		ownedCosmetics = {},
		equippedCosmetics = {},

		settings = {},
	}
end

-- MIGRATIONS[v] upgrades a profile's data table from schema version v to v+1.
-- Applied in sequence by ProfileLogic.migrate. Keep every migration forever.
ProfileSchema.MIGRATIONS = {
	-- [1] = function(data) ... end,  -- v1 -> v2 when the day comes
}

return ProfileSchema
