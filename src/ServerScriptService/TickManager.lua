--[=[
	TickManager.lua
	Fixed-step scheduler for concurrent MatchInstances (ADR-001).

	Owns: the phase-handler registry, the heartbeat accumulator that steps every
	active instance at SimulationTickRate, player→instance routing, and the
	pcall isolation + error counting around phase handlers.

	Per-match state (MatchState, RNG, replication cadence) lives in
	MatchInstance. Handlers keep their signature `fn(matchState)` — the
	per-match RNG is reached via GetRandom(), scoped to the stepping instance.
]=]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local TickManager = {
	_phases = {
		Input = {},
		Physics = {},
		Collision = {},
		Clamp = {},
		StateUpdate = {},
		Evaluation = {},
		Replication = {},
	},

	_instances = {},        -- array of active MatchInstance (registration order)
	_instanceByPlayer = {}, -- userId -> MatchInstance
	_currentInstance = nil, -- set by MatchInstance:StepTick for handler RNG access

	_accumulator = 0,
	_tickDuration = 1 / Constants.SimulationTickRate,
	_connection = nil,
	_onInstanceFinished = nil,
	_phaseErrorCount = 0,
}

-- ── Handler registry ──────────────────────────────────────────────────────────

function TickManager.RegisterHandler(phaseName: string, handlerFn: (any) -> ())
	if TickManager._phases[phaseName] then
		table.insert(TickManager._phases[phaseName], handlerFn)
	end
end

-- Phase errors are swallowed by pcall isolation; the harness stability gate
-- needs them counted, not just warned.
function TickManager.GetAndResetPhaseErrorCount(): number
	local count = TickManager._phaseErrorCount
	TickManager._phaseErrorCount = 0
	return count
end

function TickManager.RunPhase(phaseName: string, matchState)
	for _, handlerFn in ipairs(TickManager._phases[phaseName]) do
		local success, err = pcall(handlerFn, matchState)
		if not success then
			TickManager._phaseErrorCount += 1
			warn(string.format("[TickManager] Error in Phase '%s' — %s", phaseName, tostring(err)))
		end
	end
end

-- ── Instance routing ──────────────────────────────────────────────────────────

function TickManager.SetCurrentInstance(instance)
	TickManager._currentInstance = instance
end

-- Per-match seeded RNG of the instance currently stepping. Valid inside phase
-- handlers (stepping is synchronous; handlers must not yield).
function TickManager.GetRandom()
	local instance = TickManager._currentInstance
	return instance and instance.rng or nil
end

function TickManager.GetInstanceForPlayer(userId)
	return TickManager._instanceByPlayer[userId]
end

function TickManager.GetMatchStateForPlayer(userId)
	local instance = TickManager._instanceByPlayer[userId]
	return instance and instance.state or nil
end

function TickManager.GetActiveInstances()
	return TickManager._instances
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function TickManager.SetInstanceFinishedCallback(callback)
	TickManager._onInstanceFinished = callback
end

-- Called by MatchInstance when its match reaches Finished (live path only)
function TickManager.NotifyInstanceFinished(instance)
	if TickManager._onInstanceFinished then
		task.spawn(TickManager._onInstanceFinished, instance)
	end
end

function TickManager.RegisterInstance(instance)
	table.insert(TickManager._instances, instance)
	for _, pid in ipairs(instance.state.playerOrder) do
		TickManager._instanceByPlayer[pid] = instance
	end
	TickManager.Start()
end

-- Detach one player from instance routing (forfeited seat): their inputs no
-- longer reach the match and they may queue again before cleanup.
function TickManager.UnmapPlayer(userId)
	TickManager._instanceByPlayer[userId] = nil
end

function TickManager.UnregisterInstance(instance)
	local idx = table.find(TickManager._instances, instance)
	if idx then
		table.remove(TickManager._instances, idx)
	end
	for pid, inst in pairs(TickManager._instanceByPlayer) do
		if inst == instance then
			TickManager._instanceByPlayer[pid] = nil
		end
	end
	if #TickManager._instances == 0 then
		TickManager.Stop()
	end
end

-- ── Heartbeat stepping ────────────────────────────────────────────────────────

local function onHeartbeat(dt: number)
	if #TickManager._instances == 0 then return end

	TickManager._accumulator += dt

	-- Drift Protection: Prevent death spirals if server lags heavily
	if TickManager._accumulator > (Constants.MaxCatchupTicks * TickManager._tickDuration) then
		warn("[TickManager] Server lagging, clamping drift: " .. string.format("%.3f", TickManager._accumulator))
		TickManager._accumulator = TickManager._tickDuration -- Clamp to 1 tick
	end

	while TickManager._accumulator >= TickManager._tickDuration do
		TickManager._accumulator -= TickManager._tickDuration
		-- Shallow copy: an instance finishing mid-tick may unregister itself
		local stepping = table.clone(TickManager._instances)
		for _, instance in ipairs(stepping) do
			instance:StepTick(false)
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
		TickManager._accumulator = 0
		print("[TickManager] Simulation stopped.")
	end
end

return TickManager
