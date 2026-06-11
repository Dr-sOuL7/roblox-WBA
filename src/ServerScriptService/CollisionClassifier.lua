--[=[
    CollisionClassifier.lua
    Responsible for categorizing collisions (Light, Heavy, Smash) for telemetry and VFX.
    DOES NOT mutate gameplay state (the per-tick id sequence lives on MatchState
    so concurrent matches never share a counter).
]=]
local CollisionClassifier = {}

function CollisionClassifier.ResetTickCounter(matchState)
    matchState.collisionSeqCounter = 0
end

-- Called by PhysicsController after an overlap resolves
function CollisionClassifier.Classify(matchState, beyA, beyB, severityClass, contactPosition)
    matchState.collisionSeqCounter = (matchState.collisionSeqCounter or 0) + 1

    local minId, maxId = math.min(beyA.playerId, beyB.playerId), math.max(beyA.playerId, beyB.playerId)
    local collisionId = string.format("%d_%d_%d_%d", matchState.tickNumber, minId, maxId, matchState.collisionSeqCounter)

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

return CollisionClassifier
