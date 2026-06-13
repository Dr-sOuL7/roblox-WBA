--[=[
	ChallengeService.lua
	The hub challenge handshake: A triggers B's "Challenge" prompt → B gets an
	invite → if B accepts, both characters despawn and the validated Bey battle
	starts (director feature). Challenging the hub bot dummy starts a bot battle
	immediately (the bot always accepts).

	All match starts funnel through MatchManager.StartNewMatch, which despawns
	the participants' characters — so this service only manages the handshake,
	not the battle.

	Pure Roblox runtime (no headless coverage); never touches the simulation.
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local MatchManager = require(script.Parent:WaitForChild("MatchManager"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local HubService = require(script.Parent:WaitForChild("HubService"))
local BotController = require(script.Parent:WaitForChild("BotController"))

local ChallengeService = {}

local INVITE_TIMEOUT = 15 -- seconds before an unanswered invite expires

-- challengeId -> { fromId, toId, expiresAt }
local _pending = {}
local _nextId = 0
-- userId -> challengeId they are currently involved in (as sender or target)
local _involved = {}

local function isInMatch(userId)
	return TickManager.GetInstanceForPlayer(userId) ~= nil
end

local function isAvailable(player: Player): boolean
	if not player or not player.Parent then return false end
	if isInMatch(player.UserId) then return false end
	if _involved[player.UserId] then return false end
	-- Must have a hub character (not already in a battle / loading)
	return player.Character ~= nil and player.Character:FindFirstChild("HumanoidRootPart") ~= nil
end

local function clearChallenge(challengeId)
	local entry = _pending[challengeId]
	if not entry then return end
	_pending[challengeId] = nil
	if _involved[entry.fromId] == challengeId then _involved[entry.fromId] = nil end
	if _involved[entry.toId] == challengeId then _involved[entry.toId] = nil end
end

local function statusTo(userId, payload)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		Remotes.ChallengeStatus:FireClient(player, payload)
	end
end

-- ── Player vs player ──────────────────────────────────────────────────────────

function ChallengeService.RequestChallenge(fromPlayer: Player, toPlayer: Player)
	if not (fromPlayer and toPlayer) or fromPlayer == toPlayer then return end
	if not isAvailable(fromPlayer) then
		statusTo(fromPlayer.UserId, { state = "Busy", reason = "you are not available" })
		return
	end
	if not isAvailable(toPlayer) then
		statusTo(fromPlayer.UserId, { state = "Unavailable", targetName = toPlayer.Name })
		return
	end

	_nextId += 1
	local challengeId = _nextId
	_pending[challengeId] = {
		fromId = fromPlayer.UserId,
		toId = toPlayer.UserId,
		expiresAt = os.clock() + INVITE_TIMEOUT,
	}
	_involved[fromPlayer.UserId] = challengeId
	_involved[toPlayer.UserId] = challengeId

	Remotes.ChallengeInvite:FireClient(toPlayer, {
		challengeId = challengeId,
		fromName = fromPlayer.Name,
		fromUserId = fromPlayer.UserId,
		timeout = INVITE_TIMEOUT,
	})
	statusTo(fromPlayer.UserId, { state = "Sent", targetName = toPlayer.Name })

	-- Expiry sweep for this challenge
	task.delay(INVITE_TIMEOUT + 0.5, function()
		local entry = _pending[challengeId]
		if entry then
			clearChallenge(challengeId)
			statusTo(entry.fromId, { state = "Expired", targetName = toPlayer.Name })
			statusTo(entry.toId, { state = "Expired" })
		end
	end)
end

local function respond(player: Player, challengeId, accepted: boolean)
	local entry = _pending[challengeId]
	if not entry or entry.toId ~= player.UserId then
		return -- not the invitee, or already resolved
	end

	if not accepted then
		clearChallenge(challengeId)
		statusTo(entry.fromId, { state = "Declined", targetName = player.Name })
		statusTo(entry.toId, { state = "Closed" })
		return
	end

	local fromPlayer = Players:GetPlayerByUserId(entry.fromId)
	local toPlayer = Players:GetPlayerByUserId(entry.toId)
	clearChallenge(challengeId)

	-- Re-validate: either side may have left or entered another match
	if not (fromPlayer and toPlayer) or not isAvailable(fromPlayer) or not isAvailable(toPlayer) then
		statusTo(entry.fromId, { state = "Cancelled" })
		statusTo(entry.toId, { state = "Cancelled" })
		return
	end

	statusTo(entry.fromId, { state = "Accepted", targetName = toPlayer.Name })
	statusTo(entry.toId, { state = "Accepted", targetName = fromPlayer.Name })

	-- StartNewMatch despawns both characters and runs the validated battle
	MatchManager.StartNewMatch({ fromPlayer.UserId, toPlayer.UserId }, { queueMode = "Casual" })
end

Remotes.ChallengeResponse.OnServerEvent:Connect(function(player, challengeId, accepted)
	if type(challengeId) ~= "number" then return end
	respond(player, challengeId, accepted == true)
end)

-- ── Player vs bot ─────────────────────────────────────────────────────────────

function ChallengeService.RequestBotChallenge(fromPlayer: Player)
	if not isAvailable(fromPlayer) then
		statusTo(fromPlayer.UserId, { state = "Busy", reason = "you are not available" })
		return
	end
	statusTo(fromPlayer.UserId, { state = "Accepted", targetName = "Practice Bot" })
	MatchManager.StartNewMatch(
		{ fromPlayer.UserId, BotController.BOT_USER_ID },
		{ queueMode = "Casual", bots = { [BotController.BOT_USER_ID] = "Practice" } }
	)
end

-- Clean up if an involved player leaves
Players.PlayerRemoving:Connect(function(player)
	local challengeId = _involved[player.UserId]
	if challengeId then
		local entry = _pending[challengeId]
		clearChallenge(challengeId)
		if entry then
			local otherId = (entry.fromId == player.UserId) and entry.toId or entry.fromId
			statusTo(otherId, { state = "Cancelled" })
		end
	end
end)

-- Register the hub prompt handlers (one-directional dependency)
HubService.onPlayerChallenge = ChallengeService.RequestChallenge
HubService.onBotChallenge = ChallengeService.RequestBotChallenge

return ChallengeService
