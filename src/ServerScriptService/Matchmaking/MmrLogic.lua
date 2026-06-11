--[=[
	MmrLogic.lua
	Pure rating math: Elo updates, K-factor schedule, rank tiers.

	PURE MODULE — no Roblox API calls. Headless-tested, including the plan's
	required convergence simulation, before any of it touches live profiles.
	All numbers are provisional dials; tune from telemetry, not by feel.
]=]

local MmrLogic = {}

MmrLogic.DEFAULT_RATING = 1000
MmrLogic.RATING_FLOOR = 100

-- Placement matches converge fast, then updates settle down.
MmrLogic.K_PLACEMENT = 64
MmrLogic.K_STANDARD = 32
MmrLogic.PLACEMENT_MATCHES = 10

-- Visible ladder (plan: "visible rank tiers"). Ordered ascending by min.
MmrLogic.TIERS = {
	{ name = "Bronze",   min = 0 },
	{ name = "Silver",   min = 900 },
	{ name = "Gold",     min = 1100 },
	{ name = "Platinum", min = 1300 },
	{ name = "Diamond",  min = 1500 },
}

-- Probability that a rating-A player beats a rating-B player (Elo curve)
function MmrLogic.expectedScore(ratingA: number, ratingB: number): number
	return 1 / (1 + 10 ^ ((ratingB - ratingA) / 400))
end

function MmrLogic.kFor(rankedMatchesPlayed: number): number
	if rankedMatchesPlayed < MmrLogic.PLACEMENT_MATCHES then
		return MmrLogic.K_PLACEMENT
	end
	return MmrLogic.K_STANDARD
end

--[=[
	Apply one result. scoreA: 1 = A won, 0.5 = draw, 0 = B won.
	kA/kB may differ (placement vs settled). Returns (newA, newB).
]=]
function MmrLogic.updateRatings(ratingA: number, ratingB: number, scoreA: number, kA: number, kB: number)
	local expectedA = MmrLogic.expectedScore(ratingA, ratingB)
	local newA = ratingA + kA * (scoreA - expectedA)
	local newB = ratingB + kB * ((1 - scoreA) - (1 - expectedA))
	newA = math.max(MmrLogic.RATING_FLOOR, math.floor(newA + 0.5))
	newB = math.max(MmrLogic.RATING_FLOOR, math.floor(newB + 0.5))
	return newA, newB
end

function MmrLogic.tierFor(mmr: number): string
	local tierName = MmrLogic.TIERS[1].name
	for _, tier in ipairs(MmrLogic.TIERS) do
		if mmr >= tier.min then
			tierName = tier.name
		end
	end
	return tierName
end

return MmrLogic
