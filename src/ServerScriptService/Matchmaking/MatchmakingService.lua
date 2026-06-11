--[=[
	MatchmakingService.lua
	Roblox-facing matchmaking: ranked + casual queues feeding the multi-match
	arena slots, and Elo rating updates on ranked finishes.

	Thin by design — pairing lives in MatchQueue and rating math in MmrLogic
	(both pure, headless-tested, including the convergence simulation the
	plan requires). Cross-server queueing (MemoryStore) would replace the two
	in-server MatchQueue instances behind the same calls; deferred until the
	population spans multiple servers.

	Known gap (owned by the reconnect/abandonment cycle): a player who leaves
	mid-ranked-match has released their profile, so their rating loss cannot
	be applied here. Leaving currently dodges the MMR hit — the plan's
	abandonment-penalty task closes this.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local MmrLogic = require(script.Parent:WaitForChild("MmrLogic"))
local MatchQueue = require(script.Parent:WaitForChild("MatchQueue"))
local MatchManager = require(script.Parent.Parent:WaitForChild("MatchManager"))
local TickManager = require(script.Parent.Parent:WaitForChild("TickManager"))
local ProfileStore = require(script.Parent.Parent:WaitForChild("Persistence"):WaitForChild("ProfileStore"))

local TICK_SECONDS = 1
local SOLO_PRACTICE_WAIT = 6 -- lone casual player on an idle server gets practice

local MatchmakingService = {}

local _queues = {
	Ranked = MatchQueue.new("Ranked", { baseTolerance = 100, toleranceGrowthPerSecond = 5, toleranceMax = 500 }),
	-- Casual pairs anyone with anyone; the huge base tolerance makes the
	-- MMR-sorted pairing effectively order-preserving.
	Casual = MatchQueue.new("Casual", { baseTolerance = 100000, toleranceGrowthPerSecond = 0, toleranceMax = 100000 }),
}

local function pushQueueStatus(userId, payload)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		Remotes.QueueStatus:FireClient(player, payload)
	end
end

local function pushProfileSummary(userId)
	local player = Players:GetPlayerByUserId(userId)
	local profile = ProfileStore.GetProfile(userId)
	if player and profile then
		Remotes.ProfileSummary:FireClient(player, {
			mmr = profile.mmr,
			tier = MmrLogic.tierFor(profile.mmr),
			rankedWins = profile.rankedWins,
			rankedLosses = profile.rankedLosses,
			wins = profile.stats.wins,
			losses = profile.stats.losses,
		})
	end
end
MatchmakingService.PushProfileSummary = pushProfileSummary

-- ── Queue membership ──────────────────────────────────────────────────────────

function MatchmakingService.JoinQueue(userId, mode: string): (boolean, string?)
	local queue = _queues[mode]
	if not queue then
		return false, "unknown-mode"
	end
	if TickManager.GetInstanceForPlayer(userId) then
		return false, "in-match"
	end
	local profile = ProfileStore.GetProfile(userId)
	if not profile then
		return false, "no-profile" -- still loading, or load failed (kick pending)
	end

	-- One queue at a time
	for _, other in pairs(_queues) do
		if other ~= queue then
			other:leave(userId)
		end
	end

	local joined = queue:join(userId, profile.mmr, os.clock())
	if joined then
		pushQueueStatus(userId, { state = "Queued", mode = mode })
	end
	return joined, nil
end

function MatchmakingService.LeaveAllQueues(userId, silent: boolean?)
	local left = false
	for _, queue in pairs(_queues) do
		if queue:leave(userId) then
			left = true
		end
	end
	if left and not silent then
		pushQueueStatus(userId, { state = "Left" })
	end
	return left
end

-- Remote: client asks to join "Ranked"/"Casual" or "Leave"
Remotes.RequestQueue.OnServerEvent:Connect(function(player, mode)
	if mode == "Leave" then
		MatchmakingService.LeaveAllQueues(player.UserId)
		return
	end
	if mode == "Ranked" or mode == "Casual" then
		local ok, reason = MatchmakingService.JoinQueue(player.UserId, mode)
		if not ok and reason then
			pushQueueStatus(player.UserId, { state = "Rejected", reason = reason })
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	MatchmakingService.LeaveAllQueues(player.UserId, true)
end)

-- ── Pairing loop ──────────────────────────────────────────────────────────────

local function startPair(mode, pair)
	local party = { pair.a.userId, pair.b.userId }
	local instance = MatchManager.StartNewMatch(party, { queueMode = mode })
	if instance then
		pushQueueStatus(pair.a.userId, { state = "Matched", mode = mode })
		pushQueueStatus(pair.b.userId, { state = "Matched", mode = mode })
		return true
	end
	-- No free slot: requeue with original wait times so tolerance keeps widening
	local queue = _queues[mode]
	queue:join(pair.a.userId, pair.a.mmr, pair.a.joinedAt)
	queue:join(pair.b.userId, pair.b.mmr, pair.b.joinedAt)
	return false
end

task.spawn(function()
	while true do
		task.wait(TICK_SECONDS)
		local now = os.clock()

		for mode, queue in pairs(_queues) do
			for _, pair in ipairs(queue:tick(now)) do
				if not startPair(mode, pair) then
					break -- slots exhausted; stop pairing this round
				end
			end
		end

		-- Solo practice: a lone casual player on a completely idle server
		local casual = _queues.Casual
		if casual:size() == 1 and _queues.Ranked:size() == 0
			and MatchManager.GetActiveMatchCount() == 0 then
			local entry = casual._entries[1]
			if (now - entry.joinedAt) >= SOLO_PRACTICE_WAIT then
				casual:leave(entry.userId)
				print("Server: Starting solo practice match.")
				local instance = MatchManager.StartNewMatch({ entry.userId }, { queueMode = "Casual" })
				if instance then
					pushQueueStatus(entry.userId, { state = "Matched", mode = "Casual" })
				else
					casual:join(entry.userId, entry.mmr, entry.joinedAt)
				end
			end
		end
	end
end)

-- ── Ranked rating updates ─────────────────────────────────────────────────────

local function rankedMatchesPlayed(profile)
	return profile.rankedWins + profile.rankedLosses + (profile.rankedDraws or 0)
end

local function applyRankedResult(state)
	if #state.playerOrder ~= 2 then
		return -- solo practice or malformed; no rating stakes
	end

	local idA, idB = state.playerOrder[1], state.playerOrder[2]
	local profileA = ProfileStore.GetProfile(idA)
	local profileB = ProfileStore.GetProfile(idB)
	if not profileA or not profileB then
		-- A leaver's profile is already released; see module header. The
		-- present player keeps their pre-match rating this round.
		warn(string.format("[Matchmaking] Ranked result for %s not fully applied (missing profile)", state.matchId))
		return
	end

	local scoreA
	if state.currentWinner == "Draw" then
		scoreA = 0.5
	elseif state.currentWinner == idA then
		scoreA = 1
	elseif state.currentWinner == idB then
		scoreA = 0
	else
		return -- no decisive result recorded
	end

	local oldA, oldB = profileA.mmr, profileB.mmr
	local newA, newB = MmrLogic.updateRatings(
		oldA, oldB, scoreA,
		MmrLogic.kFor(rankedMatchesPlayed(profileA)),
		MmrLogic.kFor(rankedMatchesPlayed(profileB))
	)

	ProfileStore.UpdateProfile(idA, function(data)
		data.mmr = newA
		data.rankedDraws = data.rankedDraws or 0
		if scoreA == 1 then data.rankedWins += 1
		elseif scoreA == 0 then data.rankedLosses += 1
		else data.rankedDraws += 1 end
	end)
	ProfileStore.UpdateProfile(idB, function(data)
		data.mmr = newB
		data.rankedDraws = data.rankedDraws or 0
		if scoreA == 0 then data.rankedWins += 1
		elseif scoreA == 1 then data.rankedLosses += 1
		else data.rankedDraws += 1 end
	end)

	for _, info in ipairs({ { id = idA, old = oldA, new = newA }, { id = idB, old = oldB, new = newB } }) do
		local player = Players:GetPlayerByUserId(info.id)
		if player then
			Remotes.MmrUpdated:FireClient(player, {
				oldMmr = info.old,
				newMmr = info.new,
				delta = info.new - info.old,
				tier = MmrLogic.tierFor(info.new),
			})
		end
		pushProfileSummary(info.id)
	end

	print(string.format("[Matchmaking] Ranked result %s: %d %d→%d | %d %d→%d",
		state.matchId, idA, oldA, newA, idB, oldB, newB))
end

MatchManager.OnMatchFinished(function(state)
	if state.queueMode == "Ranked" then
		applyRankedResult(state)
	end
end)

return MatchmakingService
