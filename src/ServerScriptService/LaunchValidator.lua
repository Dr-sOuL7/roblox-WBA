--[=[
	LaunchValidator.lua
	Validates and queues launch inputs from clients.

	The client submits ONLY aim numbers + a claimed press time:
	  { height, theta, phi, claimedServerTime }
	The server clamps every number, grades |click − GO| with the shared
	LaunchQuality math off the SYNCED clock, and constructs the velocity
	vector itself — no client-supplied vectors exist anywhere. A fabricated
	time claim earns at most Perfect (+LaunchBonusCap): the cap is the
	anti-cheat ceiling. Single-fire per match; missed clicks are handled by
	the server-side Poor auto-launch (BeyController).
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local LaunchQuality = require(ReplicatedStorage:WaitForChild("LaunchQuality"))
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

-- Per-player remote rate limiting: max 1 accepted launch per match
-- Additional guard: reject if more than RATE_LIMIT fires arrive per second
local RATE_LIMIT_WINDOW = 1    -- seconds
local RATE_LIMIT_MAX = 5       -- fires allowed per window before suppressing
local _rateCounts = {}         -- { [userId] = { count, windowStart } }

local LaunchValidator = {}

local function checkRateLimit(userId)
	local now = os.clock()
	local entry = _rateCounts[userId]
	if not entry then
		_rateCounts[userId] = { count = 1, windowStart = now }
		return true
	end
	if now - entry.windowStart > RATE_LIMIT_WINDOW then
		entry.count = 1
		entry.windowStart = now
		return true
	end
	entry.count += 1
	if entry.count > RATE_LIMIT_MAX then
		warn(string.format("[LaunchValidator] Rate limit hit for userId %d", userId))
		return false
	end
	return true
end

function LaunchValidator.ValidateAndQueue(player, sequenceId, launchData)
	if not checkRateLimit(player.UserId) then return end

	local matchState = TickManager.GetMatchStateForPlayer(player.UserId)
	if not matchState then
		warn("[LaunchValidator] No active match for player " .. player.Name)
		return
	end
	if matchState.phase ~= "Countdown" and matchState.phase ~= "Active" then
		return -- Setup: wait for GO; Finished: too late
	end

	local bState = matchState.beyStates[player.UserId]
	if not bState then
		warn("[LaunchValidator] No BeyState for player " .. player.Name)
		return
	end

	-- Single-fire guard: one launch per Bey per match
	if bState.launchConsumed then
		warn(string.format("[LaunchValidator] Duplicate launch rejected for %s (Seq: %d)", player.Name, sequenceId))
		return
	end

	-- ── Clamp the aim; never trust client geometry ────────────────────────────
	local aim = LaunchQuality.clampAim(launchData)
	matchState.pendingAim[player.UserId] = aim -- keep fallback in sync

	-- ── GO-moment grading ─────────────────────────────────────────────────────
	local now = workspace:GetServerTimeNow()
	local claimed = launchData and tonumber(launchData.claimedServerTime) or now
	-- Bound the claim: no future presses, no stale/forged timestamps
	if claimed > now or (now - claimed) > Constants.LaunchClaimSkewMax then
		claimed = now
	end
	local quality = LaunchQuality.gradeAtGo(claimed, matchState.timers.countdownEndTime)

	-- ── Server-built velocity: aim × server speed × quality × stadium ─────────
	local multiplier = LaunchQuality.multiplierFor(quality)
	local stadium = Stadiums.get(matchState.stadiumId)
	local speed = Constants.PrototypeLaunchSpeed * (stadium.launchSpeedScale or 1) * multiplier
	local vector = LaunchQuality.aimToVector(aim, speed)
	local power = math.clamp(Constants.PrototypeLaunchSpin * multiplier, 0, 200)

	-- Mark consumed before queuing to prevent race conditions
	bState.launchConsumed = true

	table.insert(matchState.inputQueue, {
		inputSequenceId = sequenceId,
		playerId = player.UserId,
		data = {
			launchVector = vector,
			spinPower = power,
			quality = quality,
			height = aim.height,
		},
	})

	print(string.format("[LaunchValidator] Launch queued for %s (Seq: %d, Quality: %s)", player.Name, sequenceId, quality))
end

return LaunchValidator
