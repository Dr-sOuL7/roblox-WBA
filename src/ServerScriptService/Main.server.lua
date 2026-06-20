-- src/ServerScriptService/Main.server.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

-- Players pilot Beys in the hub, not during battle. Without this, characters
-- spawn at the default origin spawn instead of the hub lobby.
Players.CharacterAutoLoads = false

local MatchManager = require(script.Parent:WaitForChild("MatchManager"))

-- Require all controllers to register their TickManager phases. BotController is
-- required BEFORE BeyController so its Input handler runs first and the bot's
-- analog buffer is fresh when BeyController applies it the same tick.
require(script.Parent:WaitForChild("BotController"))
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

-- Per-stadium ship gate (Phase 3): _G.RunStadiumGate("Compact")
_G.RunStadiumGate = function(stadiumId, options)
    task.spawn(function()
        SimulationHarness.RunStadiumGate(stadiumId, options)
    end)
end

local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Remotes"))
local LaunchValidator = require(script.Parent:WaitForChild("LaunchValidator"))
local InputValidator = require(script.Parent:WaitForChild("InputValidator"))

-- Persistence layer (Phase 2): profile load/release lifecycle + stats recording
local PersistenceFolder = script.Parent:WaitForChild("Persistence")
local ProfileStore = require(PersistenceFolder:WaitForChild("ProfileStore"))
require(PersistenceFolder:WaitForChild("StatsRecorder"))

-- Matchmaking (Phase 2): ranked/casual queues + MMR updates
local MatchmakingFolder = script.Parent:WaitForChild("Matchmaking")
local MatchmakingService = require(MatchmakingFolder:WaitForChild("MatchmakingService"))

-- Cosmetics (Phase 3): equip validation + win-rate-neutrality audit
require(script.Parent:WaitForChild("CosmeticsService"))

-- Hub + challenge flow: characters walk a lobby and challenge each other into
-- a battle (director feature). ChallengeService wires HubService's prompts.
local HubService = require(script.Parent:WaitForChild("HubService"))
require(script.Parent:WaitForChild("ChallengeService"))
-- Customization venue (ADR-003): workshop prompt + build save/validate
local CustomizerService = require(script.Parent:WaitForChild("CustomizerService"))
HubService.BuildHub()

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

        -- Reconnect first: a player returning within the disconnect grace
        -- resumes their live match seat instead of respawning in the hub.
        local resumedMatch = MatchManager.HandlePlayerReturned(player.UserId)

        task.spawn(function()
            local profile, failReason = ProfileStore.LoadProfile(player.UserId)
            if not profile then
                warn(string.format("Server: Profile load failed for %s (%s)", player.Name, tostring(failReason)))
                ProfileStore.KickForFailure(player.UserId, failReason)
                return
            end
            MatchmakingService.PushProfileSummary(player.UserId)
            CustomizerService.PushBuild(player.UserId) -- preload the editor's build
            if not resumedMatch then
                -- Spawn as a walking character in the hub; the player starts a
                -- battle by challenging someone (or the bot dummy). Ranked
                -- matchmaking stays opt-in via the queue UI.
                HubService.SpawnInHub(player)
            end
        end)
    end)

    -- After each match, players return to the hub (no auto-rematch): they
    -- re-challenge from there. Ranked-queue players are NOT auto-requeued —
    -- they choose to queue again.
    MatchManager.OnReadyForRematch(function(returningPlayers, _finishedState)
        for _, pid in ipairs(returningPlayers) do
            local player = Players:GetPlayerByUserId(pid)
            if player then
                HubService.SpawnInHub(player)
            end
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

-- Launch ceremony: READY (with current aim sliders as the auto-launch fallback)
Remotes.RequestReady.OnServerEvent:Connect(function(player, aim)
    MatchManager.HandleReady(player, aim)
end)

-- Handle continuous analog battle input (joystick facing + Dash/Revolve held)
Remotes.InputUpdate.OnServerEvent:Connect(function(player, packet)
    InputValidator.HandleInput(player, packet)
end)
