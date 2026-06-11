--[=[
	LaunchValidator.lua
	Validates and queues launch inputs from clients.
	Enforces single-fire-per-match and basic sanity bounds.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
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
	if matchState.phase == "Finished" then
		return
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

	-- Sanitise inputs
	local vector = launchData and launchData.launchVector or Vector3.new(0, 0, 0)
	local power  = launchData and launchData.spinPower   or 50

	if vector.Magnitude > Constants.VelocityClampMax then
		vector = vector.Unit * Constants.VelocityClampMax
	end
	power = math.clamp(power, 0, 200)

	-- Mark consumed before queuing to prevent race conditions
	bState.launchConsumed = true

	table.insert(matchState.inputQueue, {
		inputSequenceId = sequenceId,
		playerId = player.UserId,
		data = {
			launchVector = vector,
			spinPower = power,
		},
	})

	print(string.format("[LaunchValidator] Launch queued for %s (Seq: %d)", player.Name, sequenceId))
end

return LaunchValidator
