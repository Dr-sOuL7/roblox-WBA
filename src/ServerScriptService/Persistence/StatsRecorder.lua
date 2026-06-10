--[=[
	StatsRecorder.lua
	Applies finished-match results to player profiles (lifetime stats).
	First real consumer of the persistence layer — exercising it from day one
	is the point: every live match becomes a persistence test.

	MMR is NOT updated here: rating changes belong to the ranked/matchmaking
	cycle, where match context (queue type) exists.
]=]

local MatchManager = require(script.Parent.Parent:WaitForChild("MatchManager"))
local ProfileLogic = require(script.Parent:WaitForChild("ProfileLogic"))
local ProfileStore = require(script.Parent:WaitForChild("ProfileStore"))

local StatsRecorder = {}

local function recordResult(state)
	-- Solo sessions are a lobby convenience, not a match
	if #state.playerOrder < 2 then
		return
	end

	local winner = state.currentWinner

	for _, pid in ipairs(state.playerOrder) do
		local outcome
		local finishReason

		if winner == "Draw" then
			outcome = "Draw"
		elseif pid == winner then
			outcome = "Win"
			-- A win is categorized by HOW the opponent fell
			for _, otherId in ipairs(state.playerOrder) do
				if otherId ~= pid then
					local other = state.beyStates[otherId]
					finishReason = other and other.finishReason or nil
					break
				end
			end
		else
			outcome = "Loss"
			local own = state.beyStates[pid]
			finishReason = own and own.finishReason or nil
		end

		local applied = ProfileStore.UpdateProfile(pid, function(data)
			ProfileLogic.applyMatchResult(data.stats, outcome, finishReason)
		end)
		if not applied then
			-- Profile not loaded (load failed or still in flight) — never block
			-- the match loop on persistence; the result is simply not recorded.
			warn(string.format("[StatsRecorder] No loaded profile for %d; result not recorded", pid))
		end
	end
end

MatchManager.OnMatchFinished(function(state)
	recordResult(state)
end)

return StatsRecorder
