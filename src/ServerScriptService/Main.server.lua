-- src/ServerScriptService/Main.server.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Players pilot Beys, not avatars. Without this, characters spawn at the
-- default origin spawn — inside the stadium bowl the camera frames.
Players.CharacterAutoLoads = false

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
_G.RunSimulation = function(count, options)
    task.spawn(function()
        SimulationHarness.RunBatch(count, options)
    end)
end

-- Full Phase 1 harness gate: baselines + policy matrix + GO/NO-GO report
_G.RunValidationSuite = function(options)
    task.spawn(function()
        SimulationHarness.RunValidationSuite(options)
    end)
end

local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Remotes"))
local LaunchValidator = require(script.Parent:WaitForChild("LaunchValidator"))
local CommandValidator = require(script.Parent:WaitForChild("CommandValidator"))

-- Persistence layer (Phase 2): profile load/release lifecycle + stats recording
local PersistenceFolder = script.Parent:WaitForChild("Persistence")
local ProfileStore = require(PersistenceFolder:WaitForChild("ProfileStore"))
require(PersistenceFolder:WaitForChild("StatsRecorder"))

-- Matchmaking (Phase 2): ranked/casual queues + MMR updates
local MatchmakingFolder = script.Parent:WaitForChild("Matchmaking")
local MatchmakingService = require(MatchmakingFolder:WaitForChild("MatchmakingService"))

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

        -- Profile loads in parallel — never blocks the lobby. If the load
        -- fails in a way that risks data loss (live lock elsewhere, newer
        -- schema), the player is kicked rather than played without saves.
        -- On success: push their rank summary and drop them into the casual
        -- queue (the familiar join-and-play flow; ranked is opt-in via UI).
        -- Reconnect first: a player returning within the disconnect grace
        -- resumes their live match seat instead of re-entering the queue.
        local resumedMatch = MatchManager.HandlePlayerReturned(player.UserId)

        task.spawn(function()
            local profile, failReason = ProfileStore.LoadProfile(player.UserId)
            if not profile then
                warn(string.format("Server: Profile load failed for %s (%s)", player.Name, tostring(failReason)))
                ProfileStore.KickForFailure(player.UserId, failReason)
                return
            end
            MatchmakingService.PushProfileSummary(player.UserId)
            if not resumedMatch then
                MatchmakingService.JoinQueue(player.UserId, "Casual")
            end
        end)
    end)

    -- After each match, returning players rejoin their queue mode; the
    -- matchmaking loop pairs them again (their freed slot is available).
    MatchManager.OnReadyForRematch(function(returningPlayers, finishedState)
        local mode = finishedState and finishedState.queueMode or "Casual"
        for _, pid in ipairs(returningPlayers) do
            MatchmakingService.JoinQueue(pid, mode)
        end
    end)
end

Players.PlayerRemoving:Connect(function(player)
    -- Queue removal is handled inside MatchmakingService.
    -- Mid-match leave: disconnect grace (resume on return, forfeit on expiry).
    MatchManager.HandlePlayerLeft(player.UserId)
    -- Save + release the session lock so the player's next server can load.
    task.spawn(function()
        ProfileStore.ReleaseProfile(player.UserId)
    end)
end)

-- Handle launch requests from clients
Remotes.RequestLaunch.OnServerEvent:Connect(function(player, sequenceId, launchData)
    LaunchValidator.ValidateAndQueue(player, sequenceId, launchData)
end)

-- Handle battle command requests from clients
Remotes.RequestCommand.OnServerEvent:Connect(function(player, sequenceId, command)
    CommandValidator.ValidateAndQueue(player, sequenceId, command)
end)
