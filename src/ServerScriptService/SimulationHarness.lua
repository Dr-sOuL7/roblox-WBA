--[=[
	SimulationHarness.lua
	Runs headless deterministic matches to validate physics and gather aggregate metrics.
	Only runs when explicitly invoked — never on live server startup.
	Invoke from Studio command bar: _G.RunSimulation(100)
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MatchState = require(ReplicatedStorage:WaitForChild("MatchState"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local Constants = require(ReplicatedStorage:WaitForChild("Constants"))

local SimulationHarness = {}

function SimulationHarness.RunBatch(numMatches: number)
	numMatches = numMatches or 100
	print(string.format("--- SIMULATION HARNESS STARTED: %d MATCHES ---", numMatches))

	local metrics = {
		totalMatches     = numMatches,
		draws            = 0,
		player1Wins      = 0,
		player2Wins      = 0,
		spinOuts         = 0,
		wobbleCollapses  = 0,
		ringOuts         = 0,
		totalDurationTicks = 0,
		shortestDuration = math.huge,
		longestDuration  = 0,
		totalCollisions  = 0,
	}

	local p1Id = 101
	local p2Id = 102

	for i = 1, numMatches do
		if i % 25 == 0 then
			task.wait() -- prevent Roblox Studio timeout
		end

		-- High-entropy seed: sub-millisecond time + prime-multiplied index
		local matchSeed = math.floor(workspace:GetServerTimeNow() * 10000 + i * 7919) % (2^31 - 1)

		local state = MatchState.new(matchSeed)
		state.matchId = "SimMatch_" .. tostring(i)
		state.phase = "Active"

		-- Build playerOrder before SetMatchState so RNG is seeded first
		state.playerOrder = { p1Id, p2Id } -- already sorted ascending

		TickManager.SetMatchState(state)
		local rng = TickManager.GetRandom()

		local b1 = MatchState.createBeyState(p1Id)
		b1.position = Vector3.new(-10, 10, 0)
		b1.velocity = Vector3.new(rng:NextNumber(60, 80), 0, rng:NextNumber(-5, 5))
		state.beyStates[p1Id] = b1

		local b2 = MatchState.createBeyState(p2Id)
		b2.position = Vector3.new(10, 10, 0)
		b2.velocity = Vector3.new(rng:NextNumber(-80, -60), 0, rng:NextNumber(-5, 5))
		state.beyStates[p2Id] = b2

		local matchCollisions = 0

		while state.phase ~= "Finished" do
			TickManager.Step(true)

			for _, ev in ipairs(state.tickEvents) do
				if ev.eventType == "Collision" then
					matchCollisions += 1
				end
			end

			if state.tickNumber > 10000 then
				print("[Harness] Forced stop: exceeded 10000 ticks at match " .. i)
				break
			end
		end

		-- Record duration
		metrics.totalDurationTicks += state.tickNumber
		metrics.totalCollisions += matchCollisions
		if state.tickNumber < metrics.shortestDuration then
			metrics.shortestDuration = state.tickNumber
		end
		if state.tickNumber > metrics.longestDuration then
			metrics.longestDuration = state.tickNumber
		end

		-- Winner
		if state.currentWinner == "Draw" then
			metrics.draws += 1
		elseif state.currentWinner == p1Id then
			metrics.player1Wins += 1
		elseif state.currentWinner == p2Id then
			metrics.player2Wins += 1
		end

		-- Finish reason — read from finishReason field set by SpinEvaluator/PhysicsController.
		-- (angularVelocity is zeroed on finish so checking its magnitude is unreliable.)
		local loserState = nil
		if state.currentWinner == p1Id then
			loserState = b2
		elseif state.currentWinner == p2Id then
			loserState = b1
		end

		if loserState then
			local reason = loserState.finishReason or "SpinOut"
			if reason == "SpinOut" then
				metrics.spinOuts += 1
			elseif reason == "WobbleCollapse" then
				metrics.wobbleCollapses += 1
			elseif reason == "RingOut" then
				metrics.ringOuts += 1
			end
		end
	end

	-- Report
	local avgDuration  = (metrics.totalDurationTicks / metrics.totalMatches) / Constants.SimulationTickRate
	local shortDur     = metrics.shortestDuration / Constants.SimulationTickRate
	local longDur      = metrics.longestDuration  / Constants.SimulationTickRate
	local avgCollisions = metrics.totalCollisions / metrics.totalMatches

	local drawRate  = (metrics.draws         / metrics.totalMatches) * 100
	local p1WinRate = (metrics.player1Wins   / metrics.totalMatches) * 100
	local p2WinRate = (metrics.player2Wins   / metrics.totalMatches) * 100

	print("==================================================")
	print("           SIMULATION HARNESS REPORT              ")
	print("==================================================")
	print(string.format("Total Matches:      %d", metrics.totalMatches))
	print(string.format("Average Duration:   %.2fs", avgDuration))
	print(string.format("Shortest Match:     %.2fs", shortDur))
	print(string.format("Longest Match:      %.2fs", longDur))
	print(string.format("Avg Collisions:     %.1f per match", avgCollisions))
	print("--------------------------------------------------")
	print(string.format("Draw Rate:          %.1f%%", drawRate))
	print(string.format("Player 1 Win Rate:  %.1f%%", p1WinRate))
	print(string.format("Player 2 Win Rate:  %.1f%%", p2WinRate))
	print("--------------------------------------------------")
	print("Finish Types (decided wins):")
	print(string.format("  SpinOut:          %d", metrics.spinOuts))
	print(string.format("  WobbleCollapse:   %d", metrics.wobbleCollapses))
	print(string.format("  RingOut:          %d", metrics.ringOuts))
	print("==================================================")
end

return SimulationHarness
