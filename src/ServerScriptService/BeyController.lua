--[=[
	BeyController.lua
	Applies validated inputs to BeyStates during the Input phase:
	  • Launch ("GO") inputs — spin the Bey up and set its initial facing.
	  • Continuous analog input — joystick facing + Dash/Revolve held-state.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local BeyController = {}

function BeyController.OnInputPhase(matchState)
	-- ── Launch / GO inputs ─────────────────────────────────────────────────────
	for _, inputEvent in ipairs(matchState.inputQueue) do
		local pid = inputEvent.playerId
		local bState = matchState.beyStates[pid]
		if bState and bState.zoneState ~= "Finished" then
			-- Spin up (Stamina extends spin; launch quality is a small bonus).
			local quality = inputEvent.data.launchQuality or 1.0
			bState.angularVelocity = Vector3.new(0, inputEvent.data.spinPower * quality * bState.mods.Stamina, 0)
			bState.launchQuality = quality
			if inputEvent.data.facingAngle then
				bState.facingAngle = inputEvent.data.facingAngle
				bState.targetFacing = inputEvent.data.facingAngle
			end
		end
	end
	table.clear(matchState.inputQueue)

	-- ── Continuous analog input ─────────────────────────────────────────────────
	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]
		if bState.zoneState == "Finished" then continue end

		local packet = matchState.inputBuffer[pid]
		if packet then
			bState.targetFacing = packet.facingAngle
			-- Authoritative Mana gate: no Mana → abilities forced off.
			if bState.mana > 0 then
				bState.isDashing = packet.dash
				bState.isRevolving = packet.revolve
			else
				bState.isDashing = false
				bState.isRevolving = false
			end
		elseif bState.mana <= 0 then
			bState.isDashing = false
			bState.isRevolving = false
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
