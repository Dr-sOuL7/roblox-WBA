-- src/ServerScriptService/Main.server.lua
local Players = game:GetService("Players")

local MatchManager = require(script.Parent:WaitForChild("MatchManager"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))

-- Require all controllers to register their TickManager phases
require(script.Parent:WaitForChild("BeyController"))
require(script.Parent:WaitForChild("PhysicsController"))
require(script.Parent:WaitForChild("CollisionClassifier"))
require(script.Parent:WaitForChild("SpinEvaluator"))
require(script.Parent:WaitForChild("ReplayRecorder"))
require(script.Parent:WaitForChild("TelemetryLogger"))
require(script.Parent:WaitForChild("DebugStatePublisher"))

local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Remotes"))
local LaunchValidator = require(script.Parent:WaitForChild("LaunchValidator"))

local waitingPlayers = {}

Players.PlayerAdded:Connect(function(player)
    print("Server: Player joined: " .. player.Name)
    table.insert(waitingPlayers, player.UserId)
    
    -- For Prototype 1 testing, we start immediately when 1 or 2 players join
    if #waitingPlayers == 1 then
        print("Server: 1 Player joined. Starting solo test match in 2 seconds...")
        task.wait(2)
        MatchManager.StartNewMatch({waitingPlayers[1]})
    elseif #waitingPlayers == 2 then
        print("Server: 2 Players joined. Starting multiplayer match in 2 seconds...")
        task.wait(2)
        MatchManager.StartNewMatch({waitingPlayers[1], waitingPlayers[2]})
    end
end)

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
