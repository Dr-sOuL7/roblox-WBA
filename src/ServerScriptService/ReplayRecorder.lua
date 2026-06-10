--[=[
	ReplayRecorder.lua
	Records per-tick state snapshots and a match header for replay reconstruction.

	NOTE: Vector3 values are stored as-is for Prototype 1 in-session replay.
	Phase 2 TODO: serialize to {x,y,z} tables for cross-session exportability.
]=]
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local ReplayRecorder = {}
ReplayRecorder.BUFFER_SIZE = 3600 -- 120 seconds at 30 Hz

local _buffer = {}
local _matchHeader = nil
local _headerWritten = false

-- Called once per match when the first MatchStarted event is seen.
local function writeHeader(matchState)
	_matchHeader = {
		matchId       = matchState.matchId,
		matchSeed     = matchState.matchSeed,
		playerOrder   = table.clone(matchState.playerOrder),
		startTimestamp = matchState.serverTimestamp,
	}
	_headerWritten = true
end

function ReplayRecorder.GetHeader()
	return _matchHeader
end

function ReplayRecorder.GetBuffer()
	return _buffer
end

function ReplayRecorder.OnReplicationPhase(matchState)
	-- Write header on the first tick of an active match
	if not _headerWritten then
		for _, ev in ipairs(matchState.tickEvents) do
			if ev.eventType == "MatchStarted" then
				writeHeader(matchState)
				break
			end
		end
	end

	local snapshot = {
		tickNumber      = matchState.tickNumber,
		serverTimestamp = matchState.serverTimestamp,
		events          = {},
		beyStates       = {},
	}

	for _, ev in ipairs(matchState.tickEvents) do
		table.insert(snapshot.events, {
			eventType = ev.eventType,
			eventData = ev.eventData,
		})
	end

	for _, pid in ipairs(matchState.playerOrder) do
		local state = matchState.beyStates[pid]
		snapshot.beyStates[pid] = {
			position       = state.position,
			velocity       = state.velocity,
			angularVelocity = state.angularVelocity,
			tilt           = state.tilt,
			stability      = state.stability,
			zoneState      = state.zoneState,
			currentCommand = state.currentCommand,
			ringOutTimer   = state.ringOutTimer,
			finishReason   = state.finishReason,
		}
	end

	table.insert(_buffer, snapshot)

	if #_buffer > ReplayRecorder.BUFFER_SIZE then
		table.remove(_buffer, 1)
	end

	-- Reset for next match when this match finishes
	if matchState.phase == "Finished" then
		_headerWritten = false
		table.clear(_buffer)
		_matchHeader = nil
	end
end

TickManager.RegisterHandler("Replication", ReplayRecorder.OnReplicationPhase)

return ReplayRecorder
