-- src/ServerScriptService/LaunchValidator.lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local LaunchValidator = {}

function LaunchValidator.ValidateAndQueue(player, sequenceId, launchData)
    local matchState = TickManager._activeMatchState
    if not matchState then return end
    
    if matchState.phase == "Finished" then return end
    
    -- Basic validation
    local vector = launchData.launchVector or Vector3.new(0,0,0)
    local power = launchData.spinPower or 50
    
    -- Sanitize/Clamp
    if vector.Magnitude > 200 then
        vector = vector.Unit * 200
    end
    power = math.clamp(power, 0, 200)
    
    -- Queue it for the next Input phase
    table.insert(matchState.inputQueue, {
        inputSequenceId = sequenceId,
        playerId = player.UserId,
        data = {
            launchVector = vector,
            spinPower = power
        }
    })
end

return LaunchValidator
