--[=[
    CollisionClassifier.lua
    Responsible for categorizing collisions (Light, Heavy, Smash) for telemetry and VFX.
    DOES NOT mutate gameplay state.
]=]
local CollisionClassifier = {}

-- Maintain a sequence counter per tick to ensure unique deterministic IDs
local tickSequenceCounter = 0

function CollisionClassifier.ResetTickCounter()
    tickSequenceCounter = 0
end

-- Called by PhysicsController after an overlap resolves.
-- `zones` (optional): { zoneOnA, zoneOnB } — which part-zone each Bey was struck on.
function CollisionClassifier.Classify(matchState, beyA, beyB, severityClass, contactPosition, zones)
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
            position = contactPosition,
            zoneOnA = zones and zones.zoneOnA or nil,
            zoneOnB = zones and zones.zoneOnB or nil,
        }
    })
end

return CollisionClassifier
