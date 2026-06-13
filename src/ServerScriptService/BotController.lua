--[=[
	BotController.lua
	Server-side AI opponent for solo players (director feature request).

	The bot is just another participant whose inputs come from a policy
	instead of a RemoteEvent: it readies up, launches near GO with a
	human-like quality mix, and issues Attack/Defend/Evade through the SAME
	post-validation queues human input flows through. It never touches
	simulation internals — the one-Bey constitution applies to bots too.

	All decisions draw from the per-match seeded RNG (TickManager.GetRandom),
	so a bot match replays deterministically from its seed. Never runs
	headless: the harness drives its own policy bots.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local LaunchQuality = require(ReplicatedStorage:WaitForChild("LaunchQuality"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local BotController = {}

-- Negative and far from Studio test-player ids (-1, -2, ...)
BotController.BOT_USER_ID = -424242
BotController.BOT_NAME = "BOT Bey-Bot"

BotController.PROFILES = {
	-- The practice partner: competent, beatable, plays all three commands.
	Practice = {
		reactionMin = 0.10, -- s after GO before the launch click
		reactionMax = 0.40,
		quality = { -- launch timing outcomes (must sum to 1)
			{ quality = "Perfect", weight = 0.20 },
			{ quality = "Good",    weight = 0.55 },
			{ quality = "Poor",    weight = 0.25 },
		},
		issueChance = 0.15, -- per-tick command probability while able
		weights = { Attack = 0.45, Defend = 0.30, Evade = 0.25 },
	},
}

local COMMAND_NAMES = { "Attack", "Defend", "Evade" }

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

local function pickCommand(rng, weights)
	local total = 0
	for _, name in ipairs(COMMAND_NAMES) do
		total += weights[name]
	end
	local roll = rng:NextNumber(0, total)
	local cumulative = 0
	for _, name in ipairs(COMMAND_NAMES) do
		cumulative += weights[name]
		if roll <= cumulative then
			return name
		end
	end
	return COMMAND_NAMES[#COMMAND_NAMES]
end

local function botLaunch(matchState, botId, profile, rng)
	local bState = matchState.beyStates[botId]
	bState.launchConsumed = true

	-- Aim: centre-ward default with a little personality
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
			height = aim.height,
		},
	})
	print(string.format("[BotController] Bot launched (Quality: %s)", quality))
end

function BotController.OnInputPhase(matchState)
	if not matchState.bots or matchState.isHeadless then
		return
	end
	local rng = TickManager.GetRandom()
	if not rng then
		return
	end
	local now = workspace:GetServerTimeNow()

	for botId, profileName in pairs(matchState.bots) do
		local profile = BotController.PROFILES[profileName] or BotController.PROFILES.Practice
		local bState = matchState.beyStates[botId]
		if not bState or bState.zoneState == "Finished" then
			continue
		end

		-- Launch near GO with a human-like reaction delay
		if not bState.launchConsumed and matchState.timers.countdownEndTime > 0 then
			if not bState.botLaunchAt then
				bState.botLaunchAt = matchState.timers.countdownEndTime
					+ rng:NextNumber(profile.reactionMin, profile.reactionMax)
			end
			if now >= bState.botLaunchAt then
				botLaunch(matchState, botId, profile, rng)
			end
		end

		-- Commands through the same queue human input uses
		if bState.launchConsumed
			and bState.commandTimer == 0 and bState.commandCooldownTimer == 0
			and rng:NextNumber() < profile.issueChance then
			table.insert(matchState.commandQueue, {
				playerId = botId,
				command = pickCommand(rng, profile.weights),
			})
		end
	end
end

TickManager.RegisterHandler("Input", BotController.OnInputPhase)

return BotController
