--[=[
	MatchInstance.lua
	A single match's simulation container: state + seeded RNG + fixed-step
	ticking. Extracted from the former TickManager singleton (ADR-001) so one
	server can run several matches concurrently.

	The instance owns NO Roblox objects — MatchManager owns workspace models
	and folders; TickManager owns the heartbeat that drives StepTick.
	`MatchInstance.fromState` is the headless path used by SimulationHarness:
	identical stepping code live and headless, no fork.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local MatchInstance = {}
MatchInstance.__index = MatchInstance

local TICK_DURATION = 1 / Constants.SimulationTickRate
local REPLICATION_INTERVAL = math.max(1, math.floor(Constants.SimulationTickRate / Constants.ReplicationTickRate))

--[=[
	Wrap an already-built MatchState. Works headless (harness) and live:
	slot/arenaOrigin default to 0 / origin for headless use.
]=]
function MatchInstance.fromState(state, slot, arenaOrigin)
	local self = setmetatable({}, MatchInstance)
	self.state = state
	self.rng = Random.new(state.matchSeed)
	self.slot = slot or 0
	self.arenaOrigin = arenaOrigin or Vector3.new(0, 0, 0)
	state.arenaOrigin = self.arenaOrigin
	self._replicationCounter = 0
	return self
end

-- Send a MatchStateChanged event to this match's participants — or to a
-- single participant when `onlyUserId` is given (reconnect resync).
function MatchInstance:BroadcastPhase(payload, onlyUserId)
	local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
	payload.matchId = self.state.matchId
	payload.arenaOrigin = self.arenaOrigin
	payload.stadiumId = self.state.stadiumId
	for _, pid in ipairs(self.state.playerOrder) do
		if onlyUserId and pid ~= onlyUserId then continue end
		local player = Players:GetPlayerByUserId(pid)
		if player then
			Remotes.MatchStateChanged:FireClient(player, self.state.phase, payload)
		end
	end
end

-- Re-send everything a rejoining client needs to resume rendering this match.
function MatchInstance:ResyncPlayer(userId)
	self:BroadcastPhase({
		seed = self.state.matchSeed,
		players = table.clone(self.state.playerOrder),
		countdownEndTime = self.state.timers.countdownEndTime,
		launchBarEpoch = self.state.timers.launchBarEpoch,
		resync = true,
	}, userId)
end

--[=[
	Advance the match by exactly one simulation tick.
	Mirrors the former TickManager.Step: phase pipeline, replication cadence,
	cooldown ticking, finish detection.
]=]
function MatchInstance:StepTick(isHeadless)
	local state = self.state
	if state.phase == "Finished" then return end

	-- Handlers reach the per-match RNG through TickManager.GetRandom();
	-- the current-instance pointer scopes it for the duration of this tick.
	TickManager.SetCurrentInstance(self)

	if not isHeadless then
		state.serverTimestamp = workspace:GetServerTimeNow()
	end

	-- Clear events from the PREVIOUS tick
	table.clear(state.tickEvents)

	if state.phase == "Countdown" then
		if isHeadless or workspace:GetServerTimeNow() >= state.timers.countdownEndTime then
			state.phase = "Active"
			if not isHeadless then
				print(string.format("[Match %s] Phase transition: Countdown -> Active", state.matchId))
				self:BroadcastPhase({})
			end
			table.insert(state.tickEvents, { eventType = "MatchStarted", eventData = {} })
		end
		if not isHeadless then
			self._replicationCounter += 1
			if self._replicationCounter >= REPLICATION_INTERVAL then
				self._replicationCounter = 0
				TickManager.RunPhase("Replication", state)
			end
		end
	else
		TickManager.RunPhase("Input", state)
		TickManager.RunPhase("Physics", state)
		TickManager.RunPhase("Collision", state)
		TickManager.RunPhase("Clamp", state)
		TickManager.RunPhase("StateUpdate", state)
		TickManager.RunPhase("Evaluation", state)
		if not isHeadless then
			self._replicationCounter += 1
			if self._replicationCounter >= REPLICATION_INTERVAL then
				self._replicationCounter = 0
				TickManager.RunPhase("Replication", state)
			end
		end
	end

	-- Tick collision cooldowns
	for key, ticksLeft in pairs(state.collisionCooldowns) do
		if ticksLeft > 1 then
			state.collisionCooldowns[key] = ticksLeft - 1
		else
			state.collisionCooldowns[key] = nil
		end
	end

	state.tickNumber += 1
	if isHeadless then
		state.serverTimestamp = state.serverTimestamp + TICK_DURATION
	end

	-- Lifecycle: SpinEvaluator flags the match as finished
	if state.finishFlags.matchEnded then
		state.phase = "Finished"
		table.insert(state.tickEvents, {
			eventType = "MatchFinished",
			eventData = { winner = state.currentWinner },
		})

		if not isHeadless then
			print(string.format("[Match %s] Phase transition: Active -> Finished | Winner: %s",
				state.matchId, tostring(state.currentWinner)))
			self:BroadcastPhase({ winner = state.currentWinner })
			TickManager.NotifyInstanceFinished(self)
		end
	end

	TickManager.SetCurrentInstance(nil)
end

return MatchInstance
