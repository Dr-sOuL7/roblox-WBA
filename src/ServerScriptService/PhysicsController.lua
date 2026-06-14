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
local Stadiums = require(ReplicatedStorage:WaitForChild("Stadiums"))
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

				-- Craft mods (ADR-003): knockback dealt scales with the striker's
				-- Attack and inversely with the receiver's GUARD (mostly Defense,
				-- a little Agility — a nimble Bey takes glancing blows). The mod is
				-- applied INSIDE the push cap, so no build can knock past ring-out
				-- speed more than baseline — Attack's real win lever is the
				-- (uncapped) stability/spin damage below, i.e. wearing the opponent
				-- down to a wobble collapse, not a binary ring-out. Neutral mods
				-- == 1 → identical to the validated baseline.
				-- Command-Attack self-recoil is applied AFTER the cap (the
				-- attacker's own knockback can exceed it — the existing risk).
				local guardA = bA.mods.Defense * 0.8 + bA.mods.Agility * 0.2
				local guardB = bB.mods.Defense * 0.8 + bB.mods.Agility * 0.2
				local pushForceA = math.clamp(
					impactSpeed * Constants.CollisionPushMultiplier * (bB.mods.Attack / guardA),
					Constants.CollisionPushMin, Constants.CollisionPushMax
				) * (bA.currentCommand == "Attack" and Constants.CommandRecoilMultiplier or 1)
				local pushForceB = math.clamp(
					impactSpeed * Constants.CollisionPushMultiplier * (bA.mods.Attack / guardB),
					Constants.CollisionPushMin, Constants.CollisionPushMax
				) * (bB.currentCommand == "Attack" and Constants.CommandRecoilMultiplier or 1)

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

				-- Stability damage taken scales with striker Attack / receiver guard².
				-- Guard is squared HERE (not on the ring-out push, which stays
				-- capped) so Defense's real payoff is durability: defenders outlast
				-- attackers, who then pay their low-Stamina cost — closing the
				-- Defense→beats→Attack link. Neutral guard == 1 → unchanged.
				bA.stability = math.max(0, bA.stability - stabilityDmg * dmgMultA * (bB.mods.Attack / guardA ^ 1.5))
				bB.stability = math.max(0, bB.stability - stabilityDmg * dmgMultB * (bA.mods.Attack / guardB ^ 1.5))

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
	CollisionClassifier.ResetTickCounter(matchState)

	local tickDt = 1 / Constants.SimulationTickRate
	local subDt = tickDt / Constants.CollisionSubSteps
	-- Spatial parameters come from the match's stadium (plan §Phase 3: the
	-- stadium is the content axis). Classic mirrors Constants exactly.
	local stadium = Stadiums.get(matchState.stadiumId)
	local R = stadium.bowlSphereRadius
	local rimLimit = stadium.playableRadius - (Constants.BeyRadius * stadium.rimBuffer)
	local bowlForce = stadium.bowlForce
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

			-- 5. Gentle bowl drift toward center (XZ-only so drift is horizontal).
			--    Centre pull → ring-out resistance (ADR-003): mostly Defense, a
			--    little Agility (nimble Beys recover position). Blended so neutral
			--    == 1 → identical to baseline.
			local toCenter = Vector3.new(-bState.position.X, 0, -bState.position.Z).Unit
			if toCenter == toCenter then -- NaN guard: .Unit is NaN when Bey is exactly at centre
				bState.velocity += toCenter * bowlForce * subDt
					* (bState.mods.Defense * 0.75 + bState.mods.Agility * 0.25)
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
				-- Agility scales command steering force → more responsive maneuvers
				-- (ADR-003). Neutral Agility == 1 → identical to baseline.
				local agility = bState.mods.Agility
				if cmd == "Attack" then
					local toOpponent = (opponentState.position - bState.position).Unit
					if toOpponent == toOpponent then -- NaN guard: positions identical when beys overlap perfectly
						bState.velocity += toOpponent * Constants.CommandAttackForce * subDt * agility
					end
				elseif cmd == "Defend" then
					-- Stacks with BowlForce for a stronger centre pull
					if toCenter == toCenter then
						bState.velocity += toCenter * Constants.CommandDefendForce * subDt * agility
					end
				elseif cmd == "Evade" then
					-- Matador dodge: mostly sidestep, slight separation. A radial
					-- flee just runs up the bowl wall and corners the evader at
					-- the rim (harness: Attack beat radial-Evade 72/21). The
					-- tangential sidestep makes the attacker's lunge overshoot —
					-- their momentum, not the evader's, carries toward the rim.
					local away = bState.position - opponentState.position
					local awayFlat = Vector3.new(away.X, 0, away.Z).Unit
					if awayFlat == awayFlat then
						local tangent = Vector3.new(-awayFlat.Z, 0, awayFlat.X)
						-- Sidestep toward the side that curves away from the rim
						if toCenter == toCenter and tangent:Dot(toCenter) < 0 then
							tangent = -tangent
						end
						local dodge = (awayFlat * Constants.EvadeRadialWeight
							+ tangent * Constants.EvadeTangentialWeight).Unit
						if dodge == dodge then
							bState.velocity += dodge * Constants.CommandEvadeForce * subDt * agility
						end
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
