--[=[
	PhysicsController.lua
	Responsible for Physics and Collision Resolution.
	Owns stability mutation, recoil, and impulse.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local CollisionClassifier = require(script.Parent:WaitForChild("CollisionClassifier"))

local PhysicsController = {}

function PhysicsController.OnPhysicsPhase(matchState)
	local dt = 1 / Constants.SimulationTickRate

	for pid, bState in pairs(matchState.beyStates) do
		if bState.zoneState == "Finished" then continue end

		-- Friction degrades velocity slightly
		bState.velocity *= Constants.FrictionDecay

		-- Gentle bowl drift toward center
		local toCenter = (Vector3.new(0, 0, 0) - bState.position).Unit
		if toCenter == toCenter then -- NaN guard
			bState.velocity += toCenter * Constants.BowlForce * dt
		end
	end
end

function PhysicsController.OnCollisionPhase(matchState)
	local beys = {}
	for pid, state in pairs(matchState.beyStates) do
		if state.zoneState ~= "Finished" then
			table.insert(beys, state)
		end
	end

	local threshold = Constants.BeyRadius * 2

	for i = 1, #beys do
		for j = i + 1, #beys do
			local bA = beys[i]
			local bB = beys[j]

			local minId, maxId = math.min(bA.playerId, bB.playerId), math.max(bA.playerId, bB.playerId)
			local cooldownKey = minId .. "_" .. maxId

			if matchState.collisionCooldowns[cooldownKey] then continue end

			local diff = bA.position - bB.position
			local dist = diff.Magnitude

			if dist <= threshold then
				local normal = diff.Unit
				-- Safely handle floating-point perfect overlaps
				if dist < 0.001 then normal = Vector3.new(1, 0, 0) end

				local relVel = bA.velocity - bB.velocity
				local impactSpeed = relVel.Magnitude

				-- Determine severity and damage multipliers
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

				-- Tangential recoil with momentum redistribution (Orbit feel)
				local pushForce = math.max(Constants.CollisionPushMin, impactSpeed * Constants.CollisionPushMultiplier)
				local ret = Constants.TangentialEnergyRetention

				bA.velocity = (normal * pushForce) + (bA.velocity - bA.velocity:Dot(normal) * normal) * ret
				bB.velocity = (-normal * pushForce) + (bB.velocity - bB.velocity:Dot(-normal) * -normal) * ret

				-- Immediate post-collision velocity clamp to prevent explosive energy spirals
				local postClamp = Constants.PostCollisionVelocityClamp
				if bA.velocity.Magnitude > postClamp then bA.velocity = bA.velocity.Unit * postClamp end
				if bB.velocity.Magnitude > postClamp then bB.velocity = bB.velocity.Unit * postClamp end

				-- Mutate Stability and Angular Velocity (Spin Bleed)
				bA.stability = math.max(0, bA.stability - stabilityDmg)
				bB.stability = math.max(0, bB.stability - stabilityDmg)
				bA.angularVelocity *= spinDmgMultiplier
				bB.angularVelocity *= spinDmgMultiplier

				-- Apply cooldown map
				matchState.collisionCooldowns[cooldownKey] = Constants.CollisionCooldownTicks

				CollisionClassifier.Classify(matchState, bA, bB, severity, bA.position - (normal * Constants.BeyRadius))
			end
		end
	end
end

function PhysicsController.OnClampPhase(matchState)
	local clampMax = Constants.VelocityClampMax

	for pid, bState in pairs(matchState.beyStates) do
		if bState.velocity.Magnitude > clampMax then
			bState.velocity = bState.velocity.Unit * clampMax
		end
		-- NaN protection
		if bState.velocity ~= bState.velocity then
			warn("[PhysicsController] NaN velocity detected for player " .. tostring(pid) .. ", zeroing.")
			bState.velocity = Vector3.new(0, 0, 0)
		end
		if bState.position ~= bState.position then
			warn("[PhysicsController] NaN position detected for player " .. tostring(pid) .. ", resetting.")
			bState.position = Vector3.new(0, 2, 0)
		end
		-- Floor clamp
		if bState.position.Y < 0 then
			bState.position = Vector3.new(bState.position.X, 0, bState.position.Z)
			bState.velocity = Vector3.new(bState.velocity.X, 0, bState.velocity.Z)
		end
	end
end

TickManager.RegisterHandler("Physics", PhysicsController.OnPhysicsPhase)
TickManager.RegisterHandler("Collision", PhysicsController.OnCollisionPhase)
TickManager.RegisterHandler("Clamp", PhysicsController.OnClampPhase)

return PhysicsController
