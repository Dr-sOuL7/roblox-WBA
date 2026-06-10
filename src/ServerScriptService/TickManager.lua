--[=[
	TickManager.lua
	Enforces deterministic simulation updates.
	Includes drift protection and simulation lifecycle ownership.
]=]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local TickManager = {
	_activeMatchState = nil,
	_randomGenerator = nil, -- Deterministic per-match RNG

	_phases = {
		Input = {},
		Physics = {},
		Collision = {},
		Clamp = {},
		StateUpdate = {},
		Evaluation = {},
		Replication = {},
	},

	_accumulator = 0,
	_tickDuration = 1 / Constants.SimulationTickRate,
	_connection = nil,
	_onMatchFinishedCallback = nil,

	-- Replication fires every N sim ticks so snapshot rate stays at ReplicationTickRate Hz
	-- regardless of SimulationTickRate. At 30 sim / 15 rep = every 2nd tick.
	_replicationTickInterval = math.max(1, math.floor(Constants.SimulationTickRate / Constants.ReplicationTickRate)),
	_replicationTickCounter = 0,
}

function TickManager.RegisterHandler(phaseName: string, handlerFn: (any) -> ())
	if TickManager._phases[phaseName] then
		table.insert(TickManager._phases[phaseName], handlerFn)
	end
end

function TickManager.SetMatchState(matchState)
	TickManager._activeMatchState = matchState
	TickManager._randomGenerator = Random.new(matchState.matchSeed)
end

function TickManager.SetMatchFinishedCallback(callback)
	TickManager._onMatchFinishedCallback = callback
end

function TickManager.GetRandom()
	return TickManager._randomGenerator
end

-- Phase errors are swallowed by pcall isolation; the harness stability gate
-- needs them counted, not just warned.
TickManager._phaseErrorCount = 0

function TickManager.GetAndResetPhaseErrorCount(): number
	local count = TickManager._phaseErrorCount
	TickManager._phaseErrorCount = 0
	return count
end

local function executePhase(phaseName: string, matchState)
	for _, handlerFn in ipairs(TickManager._phases[phaseName]) do
		local success, err = pcall(handlerFn, matchState)
		if not success then
			TickManager._phaseErrorCount += 1
			warn(string.format("[TickManager] Error in Phase '%s' — %s", phaseName, tostring(err)))
		end
	end
end

function TickManager.Step(isHeadless)
	local state = TickManager._activeMatchState
	if not state or state.phase == "Finished" then return end

	-- Timestamp before any phase runs so Replication snapshots carry the current server time
	if not isHeadless then
		state.serverTimestamp = workspace:GetServerTimeNow()
	end

	-- Clear events from the PREVIOUS tick
	table.clear(state.tickEvents)

	if state.phase == "Countdown" then
		-- In headless mode, we usually manually force state to Active, but if not:
		if isHeadless or workspace:GetServerTimeNow() >= state.timers.countdownEndTime then
			state.phase = "Active"
			if not isHeadless then
				print("[Match] Phase transition: Countdown -> Active")
				local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
				Remotes.MatchStateChanged:FireAllClients(state.phase, { matchId = state.matchId })
			end
			table.insert(state.tickEvents, { eventType = "MatchStarted", eventData = {} })
		end
		if not isHeadless then
			TickManager._replicationTickCounter += 1
			if TickManager._replicationTickCounter >= TickManager._replicationTickInterval then
				TickManager._replicationTickCounter = 0
				executePhase("Replication", state)
			end
		end
	else
		executePhase("Input", state)
		executePhase("Physics", state)
		executePhase("Collision", state)
		executePhase("Clamp", state)
		executePhase("StateUpdate", state)
		executePhase("Evaluation", state)
		if not isHeadless then
			TickManager._replicationTickCounter += 1
			if TickManager._replicationTickCounter >= TickManager._replicationTickInterval then
				TickManager._replicationTickCounter = 0
				executePhase("Replication", state)
			end
		end
	end

	-- Tick cooldowns
	for key, ticksLeft in pairs(state.collisionCooldowns) do
		if ticksLeft > 1 then
			state.collisionCooldowns[key] = ticksLeft - 1
		else
			state.collisionCooldowns[key] = nil
		end
	end

	state.tickNumber += 1
	if isHeadless then
		state.serverTimestamp = state.serverTimestamp + TickManager._tickDuration
	end

	-- Lifecycle: Check if SpinEvaluator flagged the match as finished
	if state.finishFlags.matchEnded then
		state.phase = "Finished"
		table.insert(state.tickEvents, {
			eventType = "MatchFinished",
			eventData = { winner = state.currentWinner },
		})
		
		if not isHeadless then
			print(string.format("[Match] Phase transition: Active -> Finished | Winner: %s", tostring(state.currentWinner)))
			local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
			Remotes.MatchStateChanged:FireAllClients(state.phase, { 
				matchId = state.matchId, 
				winner = state.currentWinner 
			})

			if TickManager._onMatchFinishedCallback then
				task.spawn(TickManager._onMatchFinishedCallback, state)
			end
		end
	end
end

local function onHeartbeat(dt: number)
	if not TickManager._activeMatchState or TickManager._activeMatchState.phase == "Finished" then return end

	TickManager._accumulator += dt

	-- Drift Protection: Prevent death spirals if server lags heavily
	if TickManager._accumulator > (Constants.MaxCatchupTicks * TickManager._tickDuration) then
		warn("[TickManager] Server lagging, clamping drift: " .. string.format("%.3f", TickManager._accumulator))
		TickManager._accumulator = TickManager._tickDuration -- Clamp to 1 tick
	end

	while TickManager._accumulator >= TickManager._tickDuration do
		TickManager._accumulator -= TickManager._tickDuration
		TickManager.Step(false)
	end
end

function TickManager.Start()
	if not TickManager._connection then
		TickManager._connection = RunService.Heartbeat:Connect(onHeartbeat)
		print("[TickManager] Simulation started.")
	end
end

function TickManager.Stop()
	if TickManager._connection then
		TickManager._connection:Disconnect()
		TickManager._connection = nil
		print("[TickManager] Simulation stopped.")
	end
end

return TickManager
