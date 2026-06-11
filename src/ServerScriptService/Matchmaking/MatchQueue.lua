--[=[
	MatchQueue.lua
	Pure matchmaking queue: join/leave + MMR-proximity pairing with a
	tolerance that widens the longer a player waits.

	PURE MODULE — callers pass timestamps; no Roblox API calls. One instance
	per queue mode (ranked tight tolerance, casual effectively unbounded).
	Cross-server queueing (MemoryStore) would slot in BEHIND this same
	interface — deferred until population spans multiple servers.
]=]

local MatchQueue = {}
MatchQueue.__index = MatchQueue

local DEFAULT_CONFIG = {
	baseTolerance = 100,          -- MMR distance accepted immediately
	toleranceGrowthPerSecond = 5, -- widening while waiting
	toleranceMax = 500,
}

function MatchQueue.new(mode: string, config)
	local self = setmetatable({}, MatchQueue)
	self.mode = mode
	self.config = config or DEFAULT_CONFIG
	self._entries = {} -- array of { userId, mmr, joinedAt }
	self._byUser = {}  -- userId -> entry
	return self
end

function MatchQueue:contains(userId): boolean
	return self._byUser[userId] ~= nil
end

function MatchQueue:size(): number
	return #self._entries
end

function MatchQueue:join(userId, mmr: number, now: number): boolean
	if self._byUser[userId] then
		return false
	end
	local entry = { userId = userId, mmr = mmr, joinedAt = now }
	table.insert(self._entries, entry)
	self._byUser[userId] = entry
	return true
end

function MatchQueue:leave(userId): boolean
	local entry = self._byUser[userId]
	if not entry then
		return false
	end
	self._byUser[userId] = nil
	local idx = table.find(self._entries, entry)
	if idx then
		table.remove(self._entries, idx)
	end
	return true
end

function MatchQueue:toleranceFor(entry, now: number): number
	local waited = math.max(0, now - entry.joinedAt)
	return math.min(
		self.config.toleranceMax,
		self.config.baseTolerance + self.config.toleranceGrowthPerSecond * waited
	)
end

--[=[
	Produce as many fair pairs as possible right now; matched players are
	removed from the queue. Greedy adjacent pairing over the MMR-sorted list:
	both players' (widening) tolerances must cover the gap.
	Returns { { a = entryA, b = entryB }, ... } (a.joinedAt <= b.joinedAt order
	not guaranteed; callers treat pairs as unordered).
]=]
function MatchQueue:tick(now: number)
	if #self._entries < 2 then
		return {}
	end

	-- Sort by MMR; ties broken by wait time (longer wait first) then userId
	-- so pairing is deterministic for identical inputs.
	local sorted = table.clone(self._entries)
	table.sort(sorted, function(x, y)
		if x.mmr ~= y.mmr then
			return x.mmr < y.mmr
		end
		if x.joinedAt ~= y.joinedAt then
			return x.joinedAt < y.joinedAt
		end
		return tostring(x.userId) < tostring(y.userId)
	end)

	local pairs_ = {}
	local i = 1
	while i < #sorted do
		local a, b = sorted[i], sorted[i + 1]
		local gap = math.abs(a.mmr - b.mmr)
		if gap <= self:toleranceFor(a, now) and gap <= self:toleranceFor(b, now) then
			table.insert(pairs_, { a = a, b = b })
			i += 2
		else
			i += 1
		end
	end

	for _, pair in ipairs(pairs_) do
		self:leave(pair.a.userId)
		self:leave(pair.b.userId)
	end

	return pairs_
end

return MatchQueue
