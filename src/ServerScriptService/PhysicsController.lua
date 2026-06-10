--[=[
	PhysicsController.lua
	Owns all physics simulation: movement, gravity, floor, collision, and steering.

	Sub-step architecture:
	  OnPhysicsPhase runs CollisionSubSteps iterations per tick.
	  Each sub-step: integrate position → apply forces → detect/resolve collisions.
	  This prevents tunneling at high speeds without changing the tick rate.

	OnCollisionPhase is kept registered but empty — collision now lives inside the sub-step loop.
	OnClampPhase is pure safety: NaN protection and hard velocity cap only.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local CollisionClassifier = require(script.Parent:WaitForChild("CollisionClassifier"))

local PhysicsController = {}

-- ── Private: one collision pass for the current sub-step positions ────────────

local function doCollisionSubStep(matchState)
	local beys = {}
	for _, pid in ipairs(matchState.playerOrder) do
		local state = matchState.beyStates[pid]
		if state.zoneState ~= "Finished" then
			table.insert(beys, state)
		end
	end

	local threshold = Constants.BeyRadius * 2

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

			if dist <= threshold then
				local normal = diff.Unit
				if dist < 0.001 then
					normal = Vector3.new(1, 0, 0)
				end

				local relVel = bA.velocity - bB.velocity
				local impactSpeed = relVel.Magnitude

				local severity = "Light"
				local stabilityDmg = Constants.StabilityDamageLight
				local spinDmgMultiplier = 1.0

				if impactSpeed > Constants.SmashSpeedThreshold then
					severity = "Smash"
					stabilityDmg = Constants.StabilityDamageSmash
					spinDmgMultiplier = Constants.SpinDamageMultiplierSmash
				elseif impactSpeed > Constants.HeavySpeedThreshold then
					severity = "Heavy"
					stabilityDmg = Constants.StabilityDamageHeavy
					spinDmgMultiplier = Constants.SpinDamageMultiplierHeavy
				end

				local basePush = math.max(Constants.CollisionPushMin, impactSpeed * Constants.CollisionPushMultiplier)
				-- Attack: only the attacker absorbs amplified recoil; opponent receives base push
				local pushForceA = basePush * (bA.currentCommand == "Attack" and Constants.CommandRecoilMultiplier or 1)
				local pushForceB = basePush * (bB.currentCommand == "Attack" and Constants.CommandRecoilMultiplier or 1)

				local ret = Constants.TangentialEnergyRetention
				bA.velocity = (normal * pushForceA) + (bA.velocity - bA.velocity:Dot(normal) * normal) * ret
				bB.velocity = (-normal * pushForceB) + (bB.velocity - bB.velocity:Dot(normal) * normal) * ret

				local postClamp = Constants.PostCollisionVelocityClamp
				if bA.velocity.Magnitude > postClamp then
					bA.velocity = bA.velocity.Unit * postClamp
				end
				if bB.velocity.Magnitude > postClamp then
					bB.velocity = bB.velocity.Unit * postClamp
				end

				local rng = TickManager.GetRandom()
				local dmgMultA = rng and rng:NextNumber(Constants.CollisionDamageVarianceMin, Constants.CollisionDamageVarianceMax) or 1.0
				local dmgMultB = rng and rng:NextNumber(Constants.CollisionDamageVarianceMin, Constants.CollisionDamageVarianceMax) or 1.0

				bA.stability = math.max(0, bA.stability - stabilityDmg * dmgMultA)
				bB.stability = math.max(0, bB.stability - stabilityDmg * dmgMultB)

				local spinDmgA = (1 - spinDmgMultiplier) * dmgMultA
				local spinDmgB = (1 - spinDmgMultiplier) * dmgMultB
				bA.angularVelocity *= (1 - spinDmgA)
				bB.angularVelocity *= (1 - spinDmgB)

				matchState.collisionCooldowns[cooldownKey] = Constants.CollisionCooldownTicks

				CollisionClassifier.Classify(matchState, bA, bB, severity, bA.position - (normal * Constants.BeyRadius))
			end
		end
	end
end

-- ── Physics phase: sub-step loop ─────────────────────────────────────────────

function PhysicsController.OnPhysicsPhase(matchState)
	-- Reset classifier counter once per tick (before sub-steps produce events)
	CollisionClassifier.ResetTickCounter()

	local tickDt = 1 / Constants.SimulationTickRate
	local subDt = tickDt / Constants.CollisionSubSteps
	local R = Constants.BowlSphereRadius
	local rimLimit = Constants.BowlPlayableRadius - (Constants.BeyRadius * Constants.BowlRimBuffer)
	-- Derived so (frictionPerSubStep ^ CollisionSubSteps) == FrictionDecay, preserving per-second decay
	local frictionPerSubStep = Constants.FrictionDecay ^ (1 / Constants.CollisionSubSteps)

	for _ = 1, Constants.CollisionSubSteps do
		for _, pid in ipairs(matchState.playerOrder) do
			local bState = matchState.beyStates[pid]
			if bState.zoneState == "Finished" then continue end

			-- 1. Integrate position with current velocity
			bState.position += bState.velocity * subDt

			-- 2. Gravity
			bState.velocity -= Vector3.new(0, Constants.Gravity * subDt, 0)

			-- 3. Spherical bowl floor clamp: y = R - sqrt(R² - r²)
			local xzPos = Vector3.new(bState.position.X, 0, bState.position.Z)
			local xzDist = xzPos.Magnitude
			local floorY = 0
			if xzDist < R then
				floorY = R - math.sqrt(R * R - xzDist * xzDist)
			end
			if bState.position.Y <= floorY then
				bState.position = Vector3.new(bState.position.X, floorY, bState.position.Z)
				if bState.velocity.Y < 0 then
					bState.velocity = Vector3.new(bState.velocity.X, 0, bState.velocity.Z)
				end
				-- Slope slide: gravity component along bowl curve
				if xzDist > 0.1 then
					local slideDir = -xzPos.Unit
					local slopeAngle = xzDist / math.sqrt(R * R - xzDist * xzDist)
					bState.velocity += slideDir * (Constants.Gravity * slopeAngle * subDt)
				end
			end

			-- 4. Friction: per-sub-step value preserves the intended per-second deceleration
			bState.velocity *= frictionPerSubStep

			-- 5. Gentle bowl drift toward center (XZ-only so drift is horizontal)
			local toCenter = Vector3.new(-bState.position.X, 0, -bState.position.Z).Unit
			if toCenter == toCenter then -- NaN guard: .Unit is NaN when Bey is exactly at centre
				bState.velocity += toCenter * Constants.BowlForce * subDt
			end

			-- 6. Command steering forces
			--    Finds the first active opponent for direction reference.
			local opponentState = nil
			for _, oid in ipairs(matchState.playerOrder) do
				if oid ~= pid then
					local other = matchState.beyStates[oid]
					if other.zoneState ~= "Finished" then
						opponentState = other
						break
					end
				end
			end

			if opponentState then
				local cmd = bState.currentCommand
				if cmd == "Attack" then
					local toOpponent = (opponentState.position - bState.position).Unit
					if toOpponent == toOpponent then -- NaN guard: positions identical when beys overlap perfectly
						bState.velocity += toOpponent * Constants.CommandAttackForce * subDt
					end
				elseif cmd == "Defend" then
					-- Stacks with BowlForce for a stronger centre pull
					if toCenter == toCenter then
						bState.velocity += toCenter * Constants.CommandDefendForce * subDt
					end
				elseif cmd == "Evade" then
					local awayFromOpponent = (bState.position - opponentState.position).Unit
					if awayFromOpponent == awayFromOpponent then
						bState.velocity += awayFromOpponent * Constants.CommandEvadeForce * subDt
					end
				end
			end

			-- 7. Rim state transition — grace timer increments once per tick after sub-steps
			if xzDist > rimLimit then
				if bState.zoneState == "Active" then
					bState.zoneState = "RingOut"
					bState.ringOutTimer = 0
					table.insert(matchState.tickEvents, {
						eventType = "RingOutWarning",
						eventData = { playerId = pid },
					})
				end
			else
				if bState.zoneState == "RingOut" then
					bState.zoneState = "Active"
					bState.ringOutTimer = 0
					table.insert(matchState.tickEvents, {
						eventType = "RingOutEscaped",
						eventData = { playerId = pid },
					})
				end
			end
		end

		-- Run collision detection at updated sub-step positions
		doCollisionSubStep(matchState)
	end

	-- Ring-out grace: increment once per simulation tick so RingOutGraceTicks = 10 ≈ 0.33 s at 30 Hz
	for _, pid in ipairs(matchState.playerOrder) do
		local bState = matchState.beyStates[pid]
		if bState.zoneState == "RingOut" then
			bState.ringOutTimer += 1
			if bState.ringOutTimer >= Constants.RingOutGraceTicks then
				bState.zoneState = "Finished"
				bState.finishReason = "RingOut"
				bState.velocity = Vector3.new(0, 0, 0)
				bState.angularVelocity = Vector3.new(0, 0, 0)
				table.insert(matchState.tickEvents, {
					eventType = "BeyFinished",
					eventData = { playerId = pid, reason = "RingOut" },
				})
			end
		end
	end
end

-- ── Collision phase: no-op (collision now lives inside OnPhysicsPhase) ────────

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
			bState.position = Vector3.new(0, 2, 0)
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
