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

function TickManager.GetRandom()
	return TickManager._randomGenerator
end

local function executePhase(phaseName: string, matchState)
	for _, handlerFn in ipairs(TickManager._phases[phaseName]) do
		local success, err = pcall(handlerFn, matchState)
		if not success then
			warn(string.format("[TickManager] Error in Phase '%s' — %s", phaseName, tostring(err)))
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

		local state = TickManager._activeMatchState

		if state.phase == "Countdown" then
			if workspace:GetServerTimeNow() >= state.timers.countdownEndTime then
				state.phase = "Active"
				print("[Match] Phase transition: Countdown -> Active")
				table.insert(state.tickEvents, { eventType = "MatchStarted", eventData = {} })
			end
			-- During countdown, skip Physics/Collision/Evaluation, just Replicate
			executePhase("Replication", state)
		else
			executePhase("Input", state)
			executePhase("Physics", state)
			executePhase("Collision", state)
			executePhase("Clamp", state)
			executePhase("StateUpdate", state)
			executePhase("Evaluation", state)
			executePhase("Replication", state)
		end

		-- Clear events for the next tick
		table.clear(state.tickEvents)

		-- Tick cooldowns
		for key, ticksLeft in pairs(state.collisionCooldowns) do
			if ticksLeft > 1 then
				state.collisionCooldowns[key] = ticksLeft - 1
			else
				state.collisionCooldowns[key] = nil
			end
		end

		state.tickNumber += 1
		state.serverTimestamp = workspace:GetServerTimeNow()

		-- Lifecycle: Check if SpinEvaluator flagged the match as finished
		if state.finishFlags.matchEnded then
			state.phase = "Finished"
			print(string.format("[Match] Phase transition: Active -> Finished | Winner: %s", tostring(state.currentWinner)))
			table.insert(state.tickEvents, {
				eventType = "MatchFinished",
				eventData = { winner = state.currentWinner },
			})
		end
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
