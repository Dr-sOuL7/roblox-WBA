--[=[
	DamageModel.lua
	Pure, deterministic part-based collision outcome math.

	A Beyblade doesn't "damage" like a machine — the useful forms are burst risk,
	spin loss, destabilization and self-recoil. This module resolves a *directional*
	strike (attacker → defender) into those forms based on:

	  • WHERE the force lands  — attacker.attackHeight selects the contact zone on the
	    defender (High → smash/upper/burst, Mid → body push, Low → destabilize).
	  • HOW the force concentrates — attacker shape (aggression/width/point/round).
	  • HOW MUCH momentum is carried — closing impact speed + attacker mass.
	  • HOW MUCH recoil returns — aggressive/jagged shapes hurt the attacker too.

	Returns physical multipliers/amounts; the caller applies stats variance, the
	maxHp cap and writes the results to state. No state is mutated here.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local DamageModel = {}

-- Contact zone on the defender, chosen by the attacker's blade height.
local function zoneFor(attackHeight)
	if attackHeight >= 0.66 then
		return "High"
	elseif attackHeight >= 0.40 then
		return "Mid"
	end
	return "Low"
end

-- Per-zone behaviour. hp/stab/tilt/knock/recoil are relative weights; spinLoss is the
-- fraction of spin stripped at full severity.
local ZONE = {
	High = { hp = 1.22, stab = 0.60, tilt = 5.0, knock = 1.10, recoil = 0.72, spinLoss = 0.03, burst = true },
	Mid  = { hp = 1.00, stab = 0.80, tilt = 1.5, knock = 1.45, recoil = 0.45, spinLoss = 0.02, burst = false },
	Low  = { hp = 0.55, stab = 1.60, tilt = 7.0, knock = 0.70, recoil = 0.30, spinLoss = 0.05, burst = false },
}

local function severityBaseHp(severity)
	if severity == "Smash" then return Constants.HpDamageSmash end
	if severity == "Heavy" then return Constants.HpDamageHeavy end
	return Constants.HpDamageLight
end

local function severityBaseStab(severity)
	if severity == "Smash" then return Constants.StabilityDamageSmash end
	if severity == "Heavy" then return Constants.StabilityDamageHeavy end
	return Constants.StabilityDamageLight
end

local function severityFactor(severity)
	if severity == "Smash" then return 1.4 end
	if severity == "Heavy" then return 1.0 end
	return 0.5
end

--[=[
	resolve(attacker, defender, severity) -> outcome
	`attacker`/`defender` are BeyStates (need .profile and .mods).
	outcome = {
		zone,           -- "High" | "Mid" | "Low"
		hpDamage,       -- HP removed from the defender (pre-variance, pre-cap)
		stabilityDamage,-- structural balance removed from the defender
		tiltAdd,        -- degrees of wobble added to the defender
		spinRetain,     -- multiplier applied to defender angular velocity (<1)
		knockScale,     -- multiplier on the knockback push the defender receives
		recoilHp,       -- HP the attacker loses to self-recoil
	}
]=]
function DamageModel.resolve(attacker, defender, severity)
	local ap = attacker.profile
	local dp = defender.profile
	local atkMod = attacker.mods.Attack
	local defMod = defender.mods.Defense

	local zoneName = zoneFor(ap.attackHeight)
	local z = ZONE[zoneName]
	local sev = severityFactor(severity)

	-- Defender vulnerability from its OWN centre of gravity: a tall (high-attackHeight)
	-- Bey is easier to hit hard and to destabilize; a low Bey is harder to topple.
	local hpVuln = 0.80 + 0.42 * dp.attackHeight
	local stabVuln = 0.78 + 0.60 * dp.attackHeight

	-- ── HP damage (burst / smash / knockout track) ──
	-- Both Attack and Defense use diminishing returns so neither stat alone can
	-- run away with a matchup (keeps the four archetypes in a viable band).
	local hp = severityBaseHp(severity)
		* (0.55 + 0.45 * atkMod)
		* z.hp
		* (0.80 + 0.50 * ap.aggression)   -- jagged concentrates force
		* (1.10 - 0.40 * ap.round)        -- round shapes glance
		* (0.85 + 0.15 * ap.mass)         -- heavier carries more momentum
		* hpVuln
		/ (0.62 + 0.38 * defMod)

	-- Burst bonus: a HIGH strike (smash / upper blade) splits the core open. Scaled
	-- by the attacker's aggression and only MITIGATED — not negated — by the
	-- defender's core, so a dedicated smash Attacker punches through a tank's armour
	-- (the archetype counter). Neutral builds land in the Mid zone (no burst), so
	-- this never touches the mirror-match finish balance.
	if z.burst and dp.burstResistance < 1.0 then
		hp += severityBaseHp(severity) * (1.0 - dp.burstResistance) * 1.5
	end

	-- ── Structural balance damage (destabilization track) ──
	local stab = severityBaseStab(severity)
		* z.stab
		* (0.70 + 0.70 * ap.point)        -- sharp/pointed contact destabilizes
		* stabVuln
		/ (dp.lowCenter * dp.balance)
		/ (0.6 + 0.4 * defMod)

	-- ── Tilt impulse (visible wobble) ──
	local tilt = z.tilt * sev * (0.60 + 0.90 * ap.point) / dp.lowCenter

	-- ── Spin loss ──
	local spinRetain = 1.0 - (z.spinLoss * sev * (0.85 + 0.30 * ap.point))
	if spinRetain < 0.5 then spinRetain = 0.5 end

	-- ── Knockback ──
	local knock = z.knock
		* (0.80 + 0.50 * ap.width)        -- flat/wide pushes
		* (attacker.profile.mass / math.max(0.4, defender.profile.mass))

	-- ── Self-recoil (aggressive shapes bounce back into the attacker) ──
	local recoil = severityBaseHp(severity)
		* z.recoil
		* (0.45 + 0.70 * ap.aggression)
		* (1.00 - 0.50 * ap.round)
		/ attacker.mods.Defense

	return {
		zone = zoneName,
		hpDamage = math.max(0, hp),
		stabilityDamage = math.max(0, stab),
		tiltAdd = math.max(0, tilt),
		spinRetain = spinRetain,
		knockScale = knock,
		recoilHp = math.max(0, recoil),
	}
end

DamageModel.zoneFor = zoneFor

return DamageModel
