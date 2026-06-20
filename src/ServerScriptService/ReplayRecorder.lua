--[=[
	ReplayRecorder.lua
	Records per-tick state snapshots and a match header for replay reconstruction.
	Buffers are keyed by matchId — concurrent matches record independently.

	NOTE: Vector3 values are stored as-is for in-session replay.
	Phase 5 TODO: serialize to {x,y,z} tables for cross-session exportability.
]=]
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local ReplayRecorder = {}
ReplayRecorder.BUFFER_SIZE = 3600 -- 120 seconds at 30 Hz

-- matchId -> { header, headerWritten, buffer }
local _sessions = {}

local function getSession(matchId)
	local session = _sessions[matchId]
	if not session then
		session = { header = nil, headerWritten = false, buffer = {} }
		_sessions[matchId] = session
	end
	return session
end

local function writeHeader(session, matchState)
	session.header = {
		matchId        = matchState.matchId,
		matchSeed      = matchState.matchSeed,
		playerOrder    = table.clone(matchState.playerOrder),
		startTimestamp = matchState.serverTimestamp,
	}
	session.headerWritten = true
end

function ReplayRecorder.GetHeader(matchId)
	local session = _sessions[matchId]
	return session and session.header or nil
end

function ReplayRecorder.GetBuffer(matchId)
	local session = _sessions[matchId]
	return session and session.buffer or nil
end

function ReplayRecorder.OnReplicationPhase(matchState)
	local session = getSession(matchState.matchId)

	-- Write header on the first tick of an active match
	if not session.headerWritten then
		for _, ev in ipairs(matchState.tickEvents) do
			if ev.eventType == "MatchStarted" then
				writeHeader(session, matchState)
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
			position        = state.position,
			velocity        = state.velocity,
			angularVelocity = state.angularVelocity,
			tilt            = state.tilt,
			stability       = state.stability,
			zoneState       = state.zoneState,
			hp              = state.hp,
			mana            = state.mana,
			facingAngle     = state.facingAngle,
			isDashing       = state.isDashing,
			isRevolving     = state.isRevolving,
			finishReason    = state.finishReason,
		}
	end

	table.insert(session.buffer, snapshot)

	if #session.buffer > ReplayRecorder.BUFFER_SIZE then
		table.remove(session.buffer, 1)
	end

	-- Drop the session when this match finishes (in-memory only for now)
	if matchState.phase == "Finished" then
		_sessions[matchState.matchId] = nil
	end
end

TickManager.RegisterHandler("Replication", ReplayRecorder.OnReplicationPhase)

return ReplayRecorder
