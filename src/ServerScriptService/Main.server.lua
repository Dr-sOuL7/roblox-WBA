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

local waitingPlayers = {}

-- HEADLESS MODE: only runs in Studio when explicitly set to true.
-- NEVER ship with this enabled — live players will never get a match.
local HEADLESS_MODE = false and RunService:IsStudio()
local HEADLESS_MATCH_COUNT = 100

if HEADLESS_MODE then
    print("Server: Headless simulation mode active. Running " .. HEADLESS_MATCH_COUNT .. " matches...")
    task.wait(1)
    SimulationHarness.RunBatch(HEADLESS_MATCH_COUNT)
else
    -- Party formation happens at wake time, from the live waiting list.
    -- Multi-stadium server (ADR-001): pairs fill free arena slots until either
    -- runs out; the queue holds the overflow.
    local startScheduled = false

    local function tryStartMatches()
        while #waitingPlayers >= 2 and MatchManager.HasFreeSlot() do
            local party = { table.remove(waitingPlayers, 1), table.remove(waitingPlayers, 1) }
            if not MatchManager.StartNewMatch(party) then
                -- Slot race lost; requeue at the front and stop
                table.insert(waitingPlayers, 1, party[2])
                table.insert(waitingPlayers, 1, party[1])
                break
            end
        end

        -- Solo debug convenience: a lone player on an otherwise idle server
        -- gets a practice match rather than an empty lobby
        if #waitingPlayers == 1 and MatchManager.GetActiveMatchCount() == 0 then
            local party = { table.remove(waitingPlayers, 1) }
            print("Server: Starting solo practice match.")
            MatchManager.StartNewMatch(party)
        end
    end

    local function scheduleMatchStart()
        if startScheduled then return end
        startScheduled = true
        print("Server: Match start scheduled in 2 seconds...")

        task.delay(2, function()
            startScheduled = false
            tryStartMatches()
        end)
    end

    Players.PlayerAdded:Connect(function(player)
        print("Server: Player joined: " .. player.Name)

        -- Profile loads in parallel — never blocks the lobby. If the load
        -- fails in a way that risks data loss (live lock elsewhere, newer
        -- schema), the player is kicked rather than played without saves.
        task.spawn(function()
            local profile, failReason = ProfileStore.LoadProfile(player.UserId)
            if not profile then
                warn(string.format("Server: Profile load failed for %s (%s)", player.Name, tostring(failReason)))
                ProfileStore.KickForFailure(player.UserId, failReason)
            end
        end)

        table.insert(waitingPlayers, player.UserId)
        scheduleMatchStart()
    end)

    MatchManager.OnMatchCleanedUp(function(_instance)
        -- A slot just freed; queued players may now fit
        tryStartMatches()
    end)

    -- After each match, returning players rejoin the queue with priority
    -- (front of the line) and matches fill from there — same path as joins.
    MatchManager.OnReadyForRematch(function(returningPlayers)
        for i = #returningPlayers, 1, -1 do
            local pid = returningPlayers[i]
            if not table.find(waitingPlayers, pid) then
                table.insert(waitingPlayers, 1, pid)
            end
        end
        tryStartMatches()
    end)
end

Players.PlayerRemoving:Connect(function(player)
    local idx = table.find(waitingPlayers, player.UserId)
    if idx then
        table.remove(waitingPlayers, idx)
    end
    -- Save + release the session lock so the player's next server can load
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
