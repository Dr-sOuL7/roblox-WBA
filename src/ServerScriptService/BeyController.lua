--[=[
	BeyController.lua
	Processes validated input queues (launch + commands) and manages command timers.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local BeyController = {}

function BeyController.OnInputPhase(matchState)
	-- ── Launch inputs ─────────────────────────────────────────────────────────
	for _, inputEvent in ipairs(matchState.inputQueue) do
		local pid = inputEvent.playerId
		local bState = matchState.beyStates[pid]
		if bState then
			bState.velocity = inputEvent.data.launchVector
			bState.angularVelocity = Vector3.new(0, inputEvent.data.spinPower, 0)
		end
	end
	table.clear(matchState.inputQueue)

	-- ── Command inputs ────────────────────────────────────────────────────────
	for _, cmdEvent in ipairs(matchState.commandQueue) do
		local bState = matchState.beyStates[cmdEvent.playerId]
		if bState and bState.commandTimer == 0 and bState.commandCooldownTimer == 0 then
			bState.currentCommand = cmdEvent.command
			bState.commandTimer = Constants.CommandDurationTicks
			table.insert(matchState.tickEvents, {
				eventType = "CommandIssued",
				eventData = { playerId = cmdEvent.playerId, command = cmdEvent.command },
			})
		end
	end
	table.clear(matchState.commandQueue)

	-- ── Command timer tick ────────────────────────────────────────────────────
	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]

		if bState.commandTimer > 0 then
			bState.commandTimer -= 1
			if bState.commandTimer == 0 then
				bState.currentCommand = nil
				bState.commandCooldownTimer = Constants.CommandCooldownTicks
			end
		elseif bState.commandCooldownTimer > 0 then
			bState.commandCooldownTimer -= 1
		end
	end
end

function BeyController.OnStateUpdatePhase(matchState)
	-- Position integration lives inside PhysicsController sub-steps.
	-- This phase records previousPosition for debug/sweep reference.
	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]
		bState.previousPosition = bState.position
	end
end

TickManager.RegisterHandler("Input", BeyController.OnInputPhase)
TickManager.RegisterHandler("StateUpdate", BeyController.OnStateUpdatePhase)

return BeyController
