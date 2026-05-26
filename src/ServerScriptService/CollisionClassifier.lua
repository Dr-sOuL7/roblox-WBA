--[=[
    CollisionClassifier.lua
    Responsible for categorizing collisions (Light, Heavy, Smash) for telemetry and VFX.
    DOES NOT mutate gameplay state.
]=]
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local CollisionClassifier = {}

-- Maintain a sequence counter per tick to ensure unique deterministic IDs
local tickSequenceCounter = 0

function CollisionClassifier.OnPhysicsPhaseStart(matchState)
    tickSequenceCounter = 0
end

-- Called by PhysicsController after an overlap resolves
function CollisionClassifier.Classify(matchState, beyA, beyB, severityClass, contactPosition)
    tickSequenceCounter += 1
    
    local minId, maxId = math.min(beyA.playerId, beyB.playerId), math.max(beyA.playerId, beyB.playerId)
    local collisionId = string.format("%d_%d_%d_%d", matchState.tickNumber, minId, maxId, tickSequenceCounter)
    
    -- Emit event to MatchState tickEvents for Replay/Replication
    table.insert(matchState.tickEvents, {
        eventType = "Collision",
        eventData = {
            collisionId = collisionId,
            tickNumber = matchState.tickNumber,
            involvedBeys = {beyA.playerId, beyB.playerId},
            collisionClass = severityClass,
            position = contactPosition
        }
    })
end

-- Reset the counter at the start of the physics phase
TickManager.RegisterHandler("Physics", CollisionClassifier.OnPhysicsPhaseStart)

return CollisionClassifier
