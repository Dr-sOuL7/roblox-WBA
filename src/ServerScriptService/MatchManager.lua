--[=[
    MatchManager.lua
    Orchestrates match initialization and cleanup.
    Does NOT terminate the Tick loop directly.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MatchState = require(ReplicatedStorage:WaitForChild("MatchState"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

local MatchManager = {}

-- Create a basic generic Bey model (a cylinder) for testing
local function createGenericBeyModel(playerId: number)
    local bey = Instance.new("Part")
    bey.Name = "Bey_" .. tostring(playerId)
    bey.Shape = Enum.PartType.Cylinder
    bey.Size = Vector3.new(4, 2, 4) -- Radius 2
    bey.Position = Vector3.new(0, 5, 0)
    
    local rng = TickManager.GetRandom()
    if rng then
        bey.Color = Color3.new(rng:NextNumber(), rng:NextNumber(), rng:NextNumber())
    else
        bey.Color = Color3.new(math.random(), math.random(), math.random())
    end
    
    bey.Anchored = true -- Server moves it manually via CFrame, no Roblox physics
    bey.CanCollide = false -- No roblox collisions
    bey.Parent = workspace
    return bey
end

function MatchManager.StartNewMatch(playerIds)
    local matchSeed = os.time()
    local newState = MatchState.new(matchSeed)
    newState.matchId = "Match_" .. tostring(matchSeed)
    
    -- Begin with an authoritative countdown
    newState.phase = "Countdown"
    newState.timers.countdownEndTime = workspace:GetServerTimeNow() + 3 -- 3 second countdown
    
    -- Register state with TickManager immediately so RNG is available
    TickManager.SetMatchState(newState)
    
    -- Spawn Beys
    for i, pid in ipairs(playerIds) do
        local bState = MatchState.createBeyState(pid)
        -- Simple offset for spawning 2 players
        bState.position = Vector3.new((i == 1) and -10 or 10, 2, 0)
        bState.previousPosition = bState.position
        newState.beyStates[pid] = bState
        
        createGenericBeyModel(pid)
    end
    
    TickManager.Start()

    -- Broadcast match start (Countdown phase)
    local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
    Remotes.MatchStateChanged:FireAllClients(newState.phase, {
        matchId = newState.matchId,
        seed = newState.matchSeed,
        players = playerIds,
        countdownEndTime = newState.timers.countdownEndTime
    })
end

function MatchManager.CleanupMatch()
    TickManager.Stop()
    for _, part in ipairs(workspace:GetChildren()) do
        if string.sub(part.Name, 1, 4) == "Bey_" then
            part:Destroy()
        end
    end
end

return MatchManager
