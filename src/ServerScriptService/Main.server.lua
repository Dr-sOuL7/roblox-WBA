-- src/ServerScriptService/Main.server.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local MatchManager = require(script.Parent:WaitForChild("MatchManager"))

-- Require all controllers to register their TickManager phases
require(script.Parent:WaitForChild("BeyController"))
require(script.Parent:WaitForChild("PhysicsController"))
require(script.Parent:WaitForChild("CollisionClassifier"))
require(script.Parent:WaitForChild("SpinEvaluator"))
require(script.Parent:WaitForChild("ReplayRecorder"))
require(script.Parent:WaitForChild("TelemetryLogger"))
require(script.Parent:WaitForChild("DebugStatePublisher"))

local SimulationHarness = require(script.Parent:WaitForChild("SimulationHarness"))

-- Expose to Studio command bar for on-demand harness runs (_G.RunSimulation(100))
_G.RunSimulation = function(count)
    task.spawn(function()
        SimulationHarness.RunBatch(count)
    end)
end

local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Remotes"))
local LaunchValidator = require(script.Parent:WaitForChild("LaunchValidator"))
local CommandValidator = require(script.Parent:WaitForChild("CommandValidator"))

local waitingPlayers = {}
local matchInProgress = false

-- HEADLESS MODE: only runs in Studio when explicitly set to true.
-- NEVER ship with this enabled — live players will never get a match.
local HEADLESS_MODE = false and RunService:IsStudio()
local HEADLESS_MATCH_COUNT = 100

if HEADLESS_MODE then
    print("Server: Headless simulation mode active. Running " .. HEADLESS_MATCH_COUNT .. " matches...")
    task.wait(1)
    SimulationHarness.RunBatch(HEADLESS_MATCH_COUNT)
else
    Players.PlayerAdded:Connect(function(player)
        print("Server: Player joined: " .. player.Name)
        table.insert(waitingPlayers, player.UserId)

        if matchInProgress then return end

        if #waitingPlayers == 1 then
            print("Server: 1 player. Starting solo match in 2 seconds...")
            task.wait(2)
            if matchInProgress then return end -- another coroutine won the race
            if #waitingPlayers >= 1 then
                matchInProgress = true
                MatchManager.StartNewMatch({waitingPlayers[1]})
            end
        elseif #waitingPlayers >= 2 then
            print("Server: 2 players. Starting multiplayer match in 2 seconds...")
            task.wait(2)
            if matchInProgress then return end -- another coroutine won the race
            if #waitingPlayers >= 2 then
                matchInProgress = true
                MatchManager.StartNewMatch({waitingPlayers[1], waitingPlayers[2]})
            end
        end
    end)

    MatchManager.OnMatchCleanedUp(function()
        matchInProgress = false
    end)

    -- After each match, merge returning players with anyone who joined mid-match
    MatchManager.OnReadyForRematch(function(returningPlayers)
        local seen = {}
        local nextPlayers = {}
        for _, pid in ipairs(returningPlayers) do
            if not seen[pid] then
                seen[pid] = true
                table.insert(nextPlayers, pid)
            end
        end
        for _, pid in ipairs(waitingPlayers) do
            if not seen[pid] then
                seen[pid] = true
                table.insert(nextPlayers, pid)
            end
        end
        table.clear(waitingPlayers)
        if #nextPlayers > 0 then
            matchInProgress = true
            MatchManager.StartNewMatch(nextPlayers)
        else
            print("Server: No players available for rematch.")
        end
    end)
end

Players.PlayerRemoving:Connect(function(player)
    local idx = table.find(waitingPlayers, player.UserId)
    if idx then
        table.remove(waitingPlayers, idx)
    end
end)

-- Handle launch requests from clients
Remotes.RequestLaunch.OnServerEvent:Connect(function(player, sequenceId, launchData)
    LaunchValidator.ValidateAndQueue(player, sequenceId, launchData)
end)

-- Handle battle command requests from clients
Remotes.RequestCommand.OnServerEvent:Connect(function(player, sequenceId, command)
    CommandValidator.ValidateAndQueue(player, sequenceId, command)
end)
