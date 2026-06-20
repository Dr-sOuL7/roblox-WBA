--[=[
	BotController.lua
	Server-side AI opponent for solo players + the headless harness's policy bots.

	The bot is just another participant whose inputs come from a policy instead of
	a RemoteEvent: it launches near GO with a human-like quality mix, then steers
	via the SAME analog input buffer a human fills ({ facingAngle, dash, revolve }).
	It never touches simulation internals — the one-Bey constitution applies to
	bots too.

	`decide` is a PURE policy (no Roblox APIs) so live bots and the headless harness
	produce identical behaviour from the same state + seeded RNG.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local LaunchQuality = require(ReplicatedStorage:WaitForChild("LaunchQuality"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local BotController = {}

local TWO_PI = math.pi * 2

-- Negative id, far from Studio test-player ids
BotController.BOT_USER_ID = -424242
BotController.BOT_NAME = "BOT Bey-Bot"

-- ── Battle personalities (drive `decide`) ─────────────────────────────────────
-- dashFloor/revolveFloor: Mana thresholds to act; the bot banks Mana by coasting
-- then commits. evadeHp: HP ratio below which it bails. comboChance: dash+revolve.
local PERSONALITY = {
	Aggressive = { dashFloor = 22, revolveFloor = 80, facingNoise = 0.15, evadeHp = 0.15, comboChance = 0.05 },
	Defensive  = { dashFloor = 40, revolveFloor = 18, facingNoise = 0.10, evadeHp = 0.45, comboChance = 0.30 },
	Balanced   = { dashFloor = 36, revolveFloor = 30, facingNoise = 0.12, evadeHp = 0.28, comboChance = 0.18 },
}
BotController.PERSONALITIES = { "Aggressive", "Defensive", "Balanced" }

-- ── Launch profiles (live ceremony) ───────────────────────────────────────────
BotController.PROFILES = {
	Practice   = { reactionMin = 0.10, reactionMax = 0.40, personality = "Balanced",
		quality = { { quality = "Perfect", weight = 0.20 }, { quality = "Good", weight = 0.55 }, { quality = "Poor", weight = 0.25 } } },
	Aggressive = { reactionMin = 0.08, reactionMax = 0.30, personality = "Aggressive",
		quality = { { quality = "Perfect", weight = 0.25 }, { quality = "Good", weight = 0.55 }, { quality = "Poor", weight = 0.20 } } },
	Defensive  = { reactionMin = 0.12, reactionMax = 0.45, personality = "Defensive",
		quality = { { quality = "Perfect", weight = 0.15 }, { quality = "Good", weight = 0.55 }, { quality = "Poor", weight = 0.30 } } },
	Balanced   = { reactionMin = 0.10, reactionMax = 0.40, personality = "Balanced",
		quality = { { quality = "Perfect", weight = 0.20 }, { quality = "Good", weight = 0.55 }, { quality = "Poor", weight = 0.25 } } },
}

--[=[
	decide(bState, oppState, personality, rng) -> { facingAngle, dash, revolve }
	Pure. Mana-aware: spend down to a threshold, then coast to recharge.
]=]
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
		facing = angToOpp + math.pi * 0.5
		if mana > w.revolveFloor then
			revolve = true
			if mana > w.dashFloor + 20 and rng and rng:NextNumber() < w.comboChance then
				dash = true
			end
		end
	else
		-- Engage: bank Mana by coasting, then dash. We do NOT idle-revolve (that
		-- would bleed Mana below the dash floor and the Bey never commits).
		local floor = oppDepleted and w.revolveFloor or w.dashFloor
		if mana > floor and dist > 4 then
			dash = true
			if rng and rng:NextNumber() < w.comboChance then
				revolve = true
			end
		end
	end

	if rng then
		facing += rng:NextNumber(-1, 1) * w.facingNoise
	end
	facing = facing % TWO_PI
	if facing < 0 then facing += TWO_PI end

	return { facingAngle = facing, dash = dash, revolve = revolve }
end

-- ── Live launch near GO (queued like a human's LAUNCH click) ──────────────────
local function drawWeighted(rng, entries)
	local roll = rng:NextNumber()
	local cumulative = 0
	for _, entry in ipairs(entries) do
		cumulative += entry.weight
		if roll <= cumulative then
			return entry.quality
		end
	end
	return entries[#entries].quality
end

local function botLaunch(matchState, botId, profile, rng)
	local aim = LaunchQuality.clampAim(matchState.pendingAim[botId])
	aim.phi = (aim.phi + rng:NextNumber(-12, 12)) % 360
	aim.theta = math.clamp(aim.theta - rng:NextNumber(0, 8), Constants.LaunchThetaMin, Constants.LaunchThetaMax)

	local quality = drawWeighted(rng, profile.quality)
	local multiplier = LaunchQuality.multiplierFor(quality)
	local stadium = Stadiums.get(matchState.stadiumId)
	local speed = Constants.PrototypeLaunchSpeed * (stadium.launchSpeedScale or 1) * multiplier

	table.insert(matchState.inputQueue, {
		inputSequenceId = 0,
		playerId = botId,
		data = {
			launchVector = LaunchQuality.aimToVector(aim, speed),
			spinPower = math.clamp(Constants.PrototypeLaunchSpin * multiplier, 0, 200),
			quality = quality,
		},
	})
end

local function findOpponent(matchState, pid)
	for _, oid in ipairs(matchState.playerOrder) do
		if oid ~= pid then
			local o = matchState.beyStates[oid]
			if o and o.zoneState ~= "Finished" then
				return o
			end
		end
	end
	return nil
end

function BotController.OnInputPhase(matchState)
	local bots = matchState.bots
	if not bots then return end
	local rng = TickManager.GetRandom()
	if not rng then return end

	for _, pid in ipairs(matchState.playerOrder) do
		local spec = bots[pid]
		if not spec then continue end
		local bState = matchState.beyStates[pid]
		if not bState or bState.zoneState == "Finished" then continue end

		local profile = BotController.PROFILES[spec] or BotController.PROFILES.Practice

		-- Live launch near GO (headless launches are injected by the harness, which
		-- sets launchConsumed, so this block is skipped there).
		if not matchState.isHeadless and not bState.launchConsumed
			and matchState.timers.countdownEndTime > 0 then
			local now = workspace:GetServerTimeNow()
			if not bState.botLaunchAt then
				bState.botLaunchAt = matchState.timers.countdownEndTime
					+ rng:NextNumber(profile.reactionMin, profile.reactionMax)
			end
			if now >= bState.botLaunchAt then
				botLaunch(matchState, pid, profile, rng)
			end
		end

		-- Steer once launched (in motion). Writes the same buffer a human fills;
		-- BeyController.OnInputPhase applies it.
		if bState.launchConsumed then
			local oppState = findOpponent(matchState, pid)
			matchState.inputBuffer[pid] = BotController.decide(bState, oppState, profile.personality, rng)
		end
	end
end

TickManager.RegisterHandler("Input", BotController.OnInputPhase)

return BotController
