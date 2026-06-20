--[=[
	InputValidator.lua
	Validates the continuous analog input packet from clients and stores the latest
	validated intent per player on that player's match. BeyController applies it
	during the Input phase so the simulation stays deterministic.

	Packet: { facingAngle: number (radians), dash: boolean, revolve: boolean }
	Dash and Revolve may BOTH be held (combo = revolve at 3× speed), so they are
	not mutually exclusive. Mana gating is enforced authoritatively in physics; we
	still clear ability flags here when Mana is empty to avoid spamming intent.

	Multi-match aware (ADR-001): the player's match is resolved via TickManager's
	player→instance routing, so input reaches the correct concurrent match.
]=]
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local TWO_PI = math.pi * 2

-- Rate limit: clients send ~15 Hz; allow generous headroom, drop floods.
local RATE_LIMIT_WINDOW = 1
local RATE_LIMIT_MAX = 40
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
		return false
	end
	return true
end

local InputValidator = {}

function InputValidator.HandleInput(player, packet)
	if type(packet) ~= "table" then return end
	if not checkRateLimit(player.UserId) then return end

	local matchState = TickManager.GetMatchStateForPlayer(player.UserId)
	if not matchState or matchState.phase ~= "Active" then return end

	local bState = matchState.beyStates[player.UserId]
	if not bState or bState.zoneState == "Finished" then return end

	-- Sanitise facing angle (reject NaN/inf, wrap into [0, 2π)).
	local facing = tonumber(packet.facingAngle)
	if facing == nil or facing ~= facing or facing == math.huge or facing == -math.huge then
		facing = bState.targetFacing
	else
		facing = facing % TWO_PI
		if facing < 0 then facing += TWO_PI end
	end

	local dash = packet.dash == true
	local revolve = packet.revolve == true
	if bState.mana <= 0 then
		dash = false
		revolve = false
	end

	matchState.inputBuffer[player.UserId] = {
		facingAngle = facing,
		dash = dash,
		revolve = revolve,
	}
end

return InputValidator
