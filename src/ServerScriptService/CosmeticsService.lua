--[=[
	CosmeticsService.lua
	Server-side cosmetic equip validation + the standing win-rate-neutrality
	audit (plan §Phase 3 telemetry: "per-skin pick rate must not correlate
	with win rate; if it does, that's a bug").

	Equips are rejected mid-match: a match renders the skins it started with,
	and the audit attributes results to the skin actually worn.

	The audit aggregates in-server and prints on demand
	(_G.PrintNeutralityAudit()); Phase 8 promotes it to persisted analytics.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local Cosmetics = require(ReplicatedStorage:WaitForChild("Cosmetics"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local MatchManager = require(script.Parent:WaitForChild("MatchManager"))
local ProfileStore = require(script.Parent:WaitForChild("Persistence"):WaitForChild("ProfileStore"))

local CosmeticsService = {}

-- ── Equip ─────────────────────────────────────────────────────────────────────

function CosmeticsService.GetEquippedSkin(userId): string
	local profile = ProfileStore.GetProfile(userId)
	local skinId = profile and profile.equippedCosmetics and profile.equippedCosmetics.skin
	return Cosmetics.get(skinId).id
end

Remotes.RequestEquip.OnServerEvent:Connect(function(player, skinId)
	if type(skinId) ~= "string" then
		return
	end
	if TickManager.GetInstanceForPlayer(player.UserId) then
		return -- no mid-match wardrobe changes; keeps the audit attribution clean
	end
	local profile = ProfileStore.GetProfile(player.UserId)
	if not profile then
		return
	end
	if not Cosmetics.canEquip(skinId, profile.ownedCosmetics) then
		warn(string.format("[Cosmetics] %s tried to equip unowned/unknown skin '%s'", player.Name, skinId))
		return
	end

	ProfileStore.UpdateProfile(player.UserId, function(data)
		data.equippedCosmetics.skin = skinId
	end)

	-- Confirm through the same summary channel the rank panel already uses
	local MatchmakingService = require(script.Parent:WaitForChild("Matchmaking"):WaitForChild("MatchmakingService"))
	MatchmakingService.PushProfileSummary(player.UserId)
end)

-- ── Win-rate-neutrality audit ─────────────────────────────────────────────────

-- skinId -> { picks, wins, decided }
local _audit = {}

local function auditEntry(skinId)
	local entry = _audit[skinId]
	if not entry then
		entry = { picks = 0, wins = 0, decided = 0 }
		_audit[skinId] = entry
	end
	return entry
end

MatchManager.OnMatchFinished(function(state)
	if #state.playerOrder < 2 or not state.cosmetics then
		return
	end
	for _, pid in ipairs(state.playerOrder) do
		local skinId = state.cosmetics[pid] or Cosmetics.DEFAULT_SKIN
		local entry = auditEntry(skinId)
		entry.picks += 1
		if state.currentWinner ~= "Draw" then
			entry.decided += 1
			if state.currentWinner == pid then
				entry.wins += 1
			end
		end
	end
end)

function CosmeticsService.PrintNeutralityAudit()
	print("──────── COSMETIC NEUTRALITY AUDIT ────────")
	print(" Skin            Picks  Decided  WinRate   Δ from 50%")
	local flagged = false
	for skinId, e in pairs(_audit) do
		local winRate = (e.decided > 0) and (e.wins / e.decided) or 0.5
		local deviation = (winRate - 0.5) * 100
		local flag = ""
		-- Provisional: ≥100 decided matches and >5pp deviation warrants a look
		if e.decided >= 100 and math.abs(deviation) > 5 then
			flag = "  ← INVESTIGATE"
			flagged = true
		end
		print(string.format(" %-15s %5d  %7d  %5.1f%%   %+5.1fpp%s",
			skinId, e.picks, e.decided, winRate * 100, deviation, flag))
	end
	print(flagged
		and "AUDIT: deviation flagged — cosmetics must NOT correlate with winning. Investigate before release."
		or  "AUDIT: no skin deviates beyond tolerance (or samples still small).")
	print("───────────────────────────────────────────")
end

_G.PrintNeutralityAudit = CosmeticsService.PrintNeutralityAudit

return CosmeticsService
