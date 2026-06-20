--[=[
	PhysicsController.lua
	Owns all physics simulation for the flat, walled arena.

	Movement model (per the design):
	  • NEITHER ability held → real-world physics: momentum carries, friction bleeds
	    it off naturally. The joystick only re-orients the Bey's facing.
	  • DASH held            → the Bey is driven to 3× base speed along its facing.
	    On release the velocity is NOT reset — momentum is retained and decays
	    naturally via floor friction.
	  • REVOLVE held         → a strong centripetal force curves the path into a
	    circular orbit near the wall (gravity-assist style).
	  • DASH + REVOLVE held  → revolve at 3× speed.
	  Dash and Revolve both spend Mana; at 0 Mana they auto-cancel.

	Walls bounce the Bey (restitution) and charge Mana. Bey-vs-Bey collisions deal
	part-based damage (see DamageModel) across HP, stability, tilt and spin, plus
	self-recoil, and charge Mana.

	Sub-step architecture preserved: CollisionSubSteps iterations per tick prevent
	tunnelling at dash speeds.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local CollisionClassifier = require(script.Parent:WaitForChild("CollisionClassifier"))
local DamageModel = require(script.Parent:WaitForChild("DamageModel"))

local PhysicsController = {}

local TWO_PI = math.pi * 2

-- Turn `current` toward `target` (radians) by at most `maxStep`, shortest path.
local function angleTowards(current, target, maxStep)
	local diff = (target - current + math.pi) % TWO_PI - math.pi
	if diff > maxStep then
		diff = maxStep
	elseif diff < -maxStep then
		diff = -maxStep
	end
	return current + diff
end

-- ── Finish helpers ────────────────────────────────────────────────────────────

local function finishBey(matchState, bState, reason)
	if bState.zoneState == "Finished" then return end
	bState.zoneState = "Finished"
	bState.finishReason = reason
	bState.velocity = Vector3.new(0, 0, 0)
	bState.angularVelocity = Vector3.new(0, 0, 0)
	bState.isDashing = false
	bState.isRevolving = false

	table.insert(matchState.tickEvents, {
		eventType = "BeyFinished",
		eventData = { playerId = bState.playerId, reason = reason },
	})
	if reason == "HpBreak" then
		table.insert(matchState.tickEvents, {
			eventType = "HpBreak",
			eventData = { playerId = bState.playerId, position = bState.position },
		})
	end
end

local function checkBreak(matchState, bState)
	if bState.hp <= 0 and bState.zoneState ~= "Finished" then
		finishBey(matchState, bState, "HpBreak")
	end
end

-- ── Revolve orbit: centripetal pull into a circle near the wall ───────────────

local function applyOrbit(bState, speedMult)
	local xz = Vector3.new(bState.position.X, 0, bState.position.Z)
	local dist = xz.Magnitude

	local radialDir
	if dist < 0.1 then
		-- Near the centre: kick outward along facing to seed the orbit.
		radialDir = Vector3.new(math.cos(bState.facingAngle), 0, math.sin(bState.facingAngle))
		if radialDir.Magnitude < 0.01 then
			radialDir = Vector3.new(1, 0, 0)
		end
	else
		radialDir = xz.Unit
	end

	-- Two tangent directions; pick the one matching current motion for continuity.
	local tangent = Vector3.new(-radialDir.Z, 0, radialDir.X)
	if bState.velocity:Dot(tangent) < 0 then
		tangent = -tangent
	end

	local tangentialSpeed = Constants.RevolveOrbitSpeed * speedMult * bState.mods.Agility
	local radialError = Constants.RevolveOrbitRadius - dist
	local radialSpeed = radialError * Constants.RevolveRadialPull
	if radialSpeed > tangentialSpeed then
		radialSpeed = tangentialSpeed
	elseif radialSpeed < -tangentialSpeed then
		radialSpeed = -tangentialSpeed
	end

	bState.velocity = tangent * tangentialSpeed + radialDir * radialSpeed
end

-- ── Bey-vs-Bey collision pass (part-based damage) ─────────────────────────────

local function severityFromSpeed(speed)
	if speed > Constants.SmashSpeedThreshold then
		return "Smash"
	elseif speed > Constants.HeavySpeedThreshold then
		return "Heavy"
	end
	return "Light"
end

local function doCollisionSubStep(matchState)
	local beys = {}
	for _, pid in ipairs(matchState.playerOrder) do
		local state = matchState.beyStates[pid]
		if state.zoneState ~= "Finished" then
			table.insert(beys, state)
		end
	end

	local threshold = Constants.BeyRadius * 2
	local rng = TickManager.GetRandom()
	local vMin, vMax = Constants.CollisionDamageVarianceMin, Constants.CollisionDamageVarianceMax
	local postClamp = Constants.PostCollisionVelocityClamp

	local function applyHp(target, dmg)
		if dmg <= 0 then return end
		dmg = math.min(dmg, target.maxHp * Constants.HpDamageMaxFrac) -- cap any single hit
		target.hp = math.max(0, target.hp - dmg)
	end

	for i = 1, #beys do
		for j = i + 1, #beys do
			local bA = beys[i]
			local bB = beys[j]

			local minId = math.min(bA.playerId, bB.playerId)
			local maxId = math.max(bA.playerId, bB.playerId)
			local cooldownKey = minId .. "_" .. maxId
			if matchState.collisionCooldowns[cooldownKey] then continue end

			local diff = bA.position - bB.position
			local dist = diff.Magnitude
			if dist > threshold then continue end

			local normal = (dist < 0.001) and Vector3.new(1, 0, 0) or diff.Unit -- points B → A
			local relVel = bA.velocity - bB.velocity
			local impactSpeed = relVel.Magnitude

			-- How hard each Bey drives into the other decides ITS strike severity.
			local closingA = math.max(0, bA.velocity:Dot(-normal))
			local closingB = math.max(0, bB.velocity:Dot(normal))
			local sevA = severityFromSpeed(math.max(closingA, impactSpeed * 0.5))
			local sevB = severityFromSpeed(math.max(closingB, impactSpeed * 0.5))
			local overall = severityFromSpeed(impactSpeed)

			-- Part-based outcomes: A's strike on B, and B's strike on A.
			local outAB = DamageModel.resolve(bA, bB, sevA)
			local outBA = DamageModel.resolve(bB, bA, sevB)

			-- Knockback (scaled by each strike's knock factor / mass ratio).
			local basePush = math.max(Constants.CollisionPushMin, impactSpeed * Constants.CollisionPushMultiplier)
			local ret = Constants.TangentialEnergyRetention
			bA.velocity = (normal * basePush * outBA.knockScale) + (bA.velocity - bA.velocity:Dot(normal) * normal) * ret
			bB.velocity = (-normal * basePush * outAB.knockScale) + (bB.velocity - bB.velocity:Dot(normal) * normal) * ret
			if bA.velocity.Magnitude > postClamp then bA.velocity = bA.velocity.Unit * postClamp end
			if bB.velocity.Magnitude > postClamp then bB.velocity = bB.velocity.Unit * postClamp end

			local vA = rng and rng:NextNumber(vMin, vMax) or 1.0
			local vB = rng and rng:NextNumber(vMin, vMax) or 1.0

			-- HP: damage dealt to the defender + self-recoil to the attacker.
			applyHp(bB, outAB.hpDamage * vB)
			applyHp(bA, outBA.hpDamage * vA)
			applyHp(bA, outAB.recoilHp * vB)
			applyHp(bB, outBA.recoilHp * vA)

			-- Destabilization: structural balance + visible tilt.
			bB.stability = math.max(0, bB.stability - outAB.stabilityDamage * vB)
			bA.stability = math.max(0, bA.stability - outBA.stabilityDamage * vA)
			bB.tilt += outAB.tiltAdd * vB
			bA.tilt += outBA.tiltAdd * vA

			-- Spin loss.
			bB.angularVelocity *= outAB.spinRetain
			bA.angularVelocity *= outBA.spinRetain

			-- Mana: the hit-to-charge loop.
			bA.mana = math.min(bA.maxMana, bA.mana + Constants.ManaGainPerHit)
			bB.mana = math.min(bB.maxMana, bB.mana + Constants.ManaGainPerHit)

			matchState.collisionCooldowns[cooldownKey] = Constants.CollisionCooldownTicks

			checkBreak(matchState, bA)
			checkBreak(matchState, bB)

			CollisionClassifier.Classify(matchState, bA, bB, overall, bA.position - (normal * Constants.BeyRadius), {
				zoneOnB = outAB.zone,
				zoneOnA = outBA.zone,
			})
		end
	end
end

-- ── Physics phase: sub-step loop ─────────────────────────────────────────────

function PhysicsController.OnPhysicsPhase(matchState)
	CollisionClassifier.ResetTickCounter()

	local tickDt = 1 / Constants.SimulationTickRate
	local subDt = tickDt / Constants.CollisionSubSteps
	local subSteps = Constants.CollisionSubSteps
	local frictionPerSubStep = Constants.StadiumFloorFriction ^ (1 / subSteps)
	local maxDist = Constants.StadiumRadius - Constants.BeyRadius
	local wallBounce = Constants.StadiumWallBounce
	local floorY = Constants.BeyRadius

	for _ = 1, subSteps do
		for _, pid in ipairs(matchState.playerOrder) do
			local bState = matchState.beyStates[pid]
			if bState.zoneState == "Finished" then continue end

			local dashActive = bState.isDashing and bState.mana > 0
			local revolveActive = bState.isRevolving and bState.mana > 0

			-- 1. Facing — joystick only steers when NEITHER ability is held.
			if not dashActive and not revolveActive then
				local turnRate = Constants.FacingTurnSpeed * bState.mods.Agility
				bState.facingAngle = angleTowards(bState.facingAngle, bState.targetFacing, turnRate * subDt)
			end

			-- 2. Movement.
			if revolveActive then
				local mult = dashActive and Constants.RevolveComboMultiplier or 1.0
				applyOrbit(bState, mult)
				if bState.velocity.Magnitude > 0.01 then
					bState.facingAngle = math.atan2(bState.velocity.Z, bState.velocity.X)
				end
			elseif dashActive then
				local facingDir = Vector3.new(math.cos(bState.facingAngle), 0, math.sin(bState.facingAngle))
				local dashSpeed = Constants.DashBaseSpeed * Constants.DashSpeedMultiplier * bState.mods.Agility
				bState.velocity = facingDir * dashSpeed
			else
				-- Passive: real-world physics — momentum + friction only. The Bey also
				-- recharges a small amount of Mana while coasting (lets defensive /
				-- evasive play sustain instead of starving).
				bState.velocity *= frictionPerSubStep
				bState.mana = math.min(bState.maxMana, bState.mana + Constants.ManaRegenPerTick / subSteps)
			end

			-- 3. Mana drain (distributed across sub-steps so cost is per-tick).
			if dashActive then
				bState.mana = math.max(0, bState.mana - Constants.ManaCostDashPerTick / subSteps)
			end
			if revolveActive then
				bState.mana = math.max(0, bState.mana - Constants.ManaCostRevolvePerTick / subSteps)
			end

			-- 4. Integrate on the flat plane (no gravity; the Bey rides the floor).
			bState.velocity = Vector3.new(bState.velocity.X, 0, bState.velocity.Z)
			bState.position += bState.velocity * subDt
			bState.position = Vector3.new(bState.position.X, floorY, bState.position.Z)

			-- 5. Wall bounce (restitution + facing ricochet) + Mana charge.
			local xz = Vector3.new(bState.position.X, 0, bState.position.Z)
			local dist = xz.Magnitude
			if dist > maxDist and dist > 0.001 then
				local n = xz.Unit -- outward normal
				local vn = bState.velocity:Dot(n)
				if vn > 0 then
					bState.velocity = bState.velocity - (1 + wallBounce) * vn * n
				end
				-- Ricochet the facing so a dash continues along the bounce.
				local fd = Vector3.new(math.cos(bState.facingAngle), 0, math.sin(bState.facingAngle))
				local fdn = fd:Dot(n)
				if fdn > 0 then
					fd = fd - 2 * fdn * n
					bState.facingAngle = math.atan2(fd.Z, fd.X)
				end
				bState.position = Vector3.new(n.X * maxDist, floorY, n.Z * maxDist)
				bState.mana = math.min(bState.maxMana, bState.mana + Constants.ManaGainWall)
				table.insert(matchState.tickEvents, {
					eventType = "WallBounce",
					eventData = { playerId = pid, position = bState.position },
				})
			end
		end

		doCollisionSubStep(matchState)
	end
end

-- ── Collision phase: no-op (collision lives inside OnPhysicsPhase) ────────────

function PhysicsController.OnCollisionPhase()
end

-- ── Clamp phase: pure safety ──────────────────────────────────────────────────

function PhysicsController.OnClampPhase(matchState)
	local clampMax = Constants.VelocityClampMax

	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]

		if bState.velocity ~= bState.velocity then
			warn("[PhysicsController] NaN velocity for player " .. tostring(pid) .. ", zeroing.")
			bState.velocity = Vector3.new(0, 0, 0)
		end
		if bState.position ~= bState.position then
			warn("[PhysicsController] NaN position for player " .. tostring(pid) .. ", resetting.")
			bState.position = Vector3.new(0, Constants.BeyRadius, 0)
		end
		if bState.velocity.Magnitude > clampMax then
			bState.velocity = bState.velocity.Unit * clampMax
		end
	end
end

TickManager.RegisterHandler("Physics", PhysicsController.OnPhysicsPhase)
TickManager.RegisterHandler("Collision", PhysicsController.OnCollisionPhase)
TickManager.RegisterHandler("Clamp", PhysicsController.OnClampPhase)

return PhysicsController
