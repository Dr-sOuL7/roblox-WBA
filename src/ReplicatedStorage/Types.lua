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

export type Mods = { Attack: number, Defense: number, Stamina: number, Agility: number }

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
    -- HP / Mana
    hp: number,
    maxHp: number,
    mana: number,
    maxMana: number,
    -- Facing & abilities
    facingAngle: number,
    targetFacing: number,
    isDashing: boolean,
    isRevolving: boolean,
    -- Craft profile
    loadout: { blade: string, disc: string, core: string, tip: string },
    mods: Mods,
    finishReason: string?,
}

export type CollisionEventPayload = {
    tickNumber: number,
    collisionId: string,
    involvedBeys: { number }, -- Array of player IDs involved
    collisionClass: string,
    position: Vector3,
}

return {}
