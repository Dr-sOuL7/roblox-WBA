--[=[
	BotController.lua
	Headless AI policy for the SimulationHarness. Produces the same analog input
	packet a player would send — { facingAngle, dash, revolve } — from the current
	Bey + opponent state. Three personalities weight the choices differently.

	Mana-aware: bots spend down to a threshold then coast to recharge, which keeps
	the Mana economy oscillating (so it never sits pinned at full or empty).
]=]
local BotController = {}

local TWO_PI = math.pi * 2

local PERSONALITY = {
	Aggressive = { dashFloor = 22, revolveFloor = 80, facingNoise = 0.15, evadeHp = 0.15, comboChance = 0.05 },
	Defensive  = { dashFloor = 40, revolveFloor = 18, facingNoise = 0.10, evadeHp = 0.45, comboChance = 0.30 },
	Balanced   = { dashFloor = 36, revolveFloor = 30, facingNoise = 0.12, evadeHp = 0.28, comboChance = 0.18 },
}

BotController.PERSONALITIES = { "Aggressive", "Defensive", "Balanced" }

function BotController.decide(bState, oppState, personality, rng)
	local w = PERSONALITY[personality] or PERSONALITY.Balanced

	local myPos = bState.position
	local oppPos = oppState and oppState.position or Vector3.new(0, 0, 0)
	local dx = oppPos.X - myPos.X
	local dz = oppPos.Z - myPos.Z
	local angToOpp = math.atan2(dz, dx)
	local dist = math.sqrt(dx * dx + dz * dz)

	local mana = bState.mana
	local hpRatio = bState.hp / math.max(1, bState.maxHp)
	local oppDashing = oppState and oppState.isDashing or false
	local oppMana = oppState and oppState.mana or 0
	local oppDepleted = oppMana < 12 -- opponent can't dash/revolve — a window to punish

	local facing = angToOpp
	local dash = false
	local revolve = false

	-- Evade when hurt or about to be rammed — but NOT if the attacker is out of
	-- Mana (then we counter-attack and capitalise on their over-commitment).
	local evading = ((hpRatio < w.evadeHp) or (oppDashing and dist < 10)) and not oppDepleted

	if evading then
		-- Slip tangentially and orbit out of the way; build Mana back.
		facing = angToOpp + math.pi * 0.5
		if mana > w.revolveFloor then
			revolve = true
			-- Sometimes spin up the 3× combo to reposition fast / shoulder-charge.
			if mana > w.dashFloor + 20 and rng and rng:NextNumber() < w.comboChance then
				dash = true
			end
		end
	else
		-- Engage: bank Mana by coasting, then dash at the opponent. We deliberately
		-- do NOT idle-revolve here — that would bleed Mana below the dash floor and
		-- the Bey would never commit to an attack. Press with less Mana when the
		-- opponent is depleted and can't punish.
		local floor = oppDepleted and w.revolveFloor or w.dashFloor
		if mana > floor and dist > 4 then
			dash = true
			-- Combo dash+revolve = 3× orbit: a fast curving approach.
			if rng and rng:NextNumber() < w.comboChance then
				revolve = true
			end
		end
		-- otherwise: coast (no ability) to regenerate Mana for the next dash
	end

	if rng then
		facing += rng:NextNumber(-1, 1) * w.facingNoise
	end

	facing = facing % TWO_PI
	if facing < 0 then facing += TWO_PI end

	return { facingAngle = facing, dash = dash, revolve = revolve }
end

return BotController
