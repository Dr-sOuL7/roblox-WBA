--[=[
    BeyController.lua
    Responsible for mutating MatchState for Beys (Inputs, StateUpdates).
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local BeyController = {}

function BeyController.OnInputPhase(matchState)
    -- Process the validated inputQueue
    for _, inputEvent in ipairs(matchState.inputQueue) do
        local pid = inputEvent.playerId
        local bState = matchState.beyStates[pid]
        if bState then
            -- Apply launch vector and angular velocity
            bState.velocity = inputEvent.data.launchVector
            bState.angularVelocity = Vector3.new(0, inputEvent.data.spinPower, 0)
        end
    end
    -- Clear queue after processing
    table.clear(matchState.inputQueue)
end

function BeyController.OnStateUpdatePhase(matchState)
    local dt = 1 / Constants.SimulationTickRate

    for pid, bState in pairs(matchState.beyStates) do
        -- Save previous position for overlap checks/future sweeping
        bState.previousPosition = bState.position
        
        -- Apply velocity to position
        bState.position += bState.velocity * dt
    end
end

TickManager.RegisterHandler("Input", BeyController.OnInputPhase)
TickManager.RegisterHandler("StateUpdate", BeyController.OnStateUpdatePhase)

return BeyController
