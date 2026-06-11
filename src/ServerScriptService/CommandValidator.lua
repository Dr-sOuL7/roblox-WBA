--[=[
	CommandValidator.lua
	Validates and queues battle command inputs from clients.
	Mirrors the structure of LaunchValidator — one validated entry per fire.
]=]
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local VALID_COMMANDS = { Attack = true, Defend = true, Evade = true }

local RATE_LIMIT_WINDOW = 1
local RATE_LIMIT_MAX = 10
local _rateCounts = {}

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
		warn(string.format("[CommandValidator] Rate limit exceeded for userId %d", userId))
		return false
	end
	return true
end

local CommandValidator = {}

function CommandValidator.ValidateAndQueue(player, _sequenceId, command)
	if not checkRateLimit(player.UserId) then return end

	local matchState = TickManager.GetMatchStateForPlayer(player.UserId)
	if not matchState then
		return
	end
	if matchState.phase ~= "Active" then
		return
	end

	-- Reject unknown command strings (anti-cheat)
	if not VALID_COMMANDS[command] then
		warn(string.format("[CommandValidator] Invalid command '%s' from %s", tostring(command), player.Name))
		return
	end

	local bState = matchState.beyStates[player.UserId]
	if not bState or bState.zoneState == "Finished" then
		return
	end

	-- Reject if a command is already active or on cooldown
	if bState.commandTimer > 0 or bState.commandCooldownTimer > 0 then
		return
	end

	-- Rate-limit: cap at one queued command per player per tick
	for _, entry in ipairs(matchState.commandQueue) do
		if entry.playerId == player.UserId then
			return
		end
	end

	table.insert(matchState.commandQueue, {
		playerId = player.UserId,
		command = command,
	})
end

return CommandValidator
