export type ReplaySnapshot = {
    tickNumber: number,
    serverTimestamp: number,
    beyStates: { [number]: BeyState },
    events: { [number]: ReplayEvent }, -- Event markers support
}

export type ReplayEvent = {
    eventType: string, -- "Collision", "Launch", "Warning", "Finish"
    eventData: any,
}

export type BeyState = {
    playerId: number,
    position: Vector3,
    previousPosition: Vector3, -- Future-proof for swept overlaps
    velocity: Vector3,
    angularVelocity: Vector3,
    tilt: number,
    stability: number,
    momentum: number,
    heat: number,
    criticalSpinTimer: number,
    collisionFlags: { [string]: boolean },
    zoneState: string,
}

export type CollisionEventPayload = {
    tickNumber: number,
    collisionId: string,
    involvedBeys: { number }, -- Array of player IDs involved
    collisionClass: string,
    position: Vector3,
}

return {}
