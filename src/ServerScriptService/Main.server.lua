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
    -- Party formation happens at wake time, from the live waiting list.
    -- Scheduling per-join instead (the old approach) let the first joiner's
    -- coroutine start a SOLO match even when a second player had arrived
    -- during the 2-second delay, stranding them for the whole match.
    local startScheduled = false

    local function scheduleMatchStart()
        if startScheduled or matchInProgress then return end
        startScheduled = true
        print("Server: Match start scheduled in 2 seconds...")

        task.delay(2, function()
            startScheduled = false
            if matchInProgress then return end

            local party = {}
            for _ = 1, math.min(2, #waitingPlayers) do
                table.insert(party, table.remove(waitingPlayers, 1))
            end

            if #party == 0 then
                print("Server: All waiting players left before match start.")
                return
            end

            print(string.format("Server: Starting match with %d player(s).", #party))
            matchInProgress = true
            MatchManager.StartNewMatch(party)
        end)
    end

    Players.PlayerAdded:Connect(function(player)
        print("Server: Player joined: " .. player.Name)
        table.insert(waitingPlayers, player.UserId)
        scheduleMatchStart()
    end)

    MatchManager.OnMatchCleanedUp(function()
        matchInProgress = false
    end)

    -- After each match, merge returning players with anyone who joined mid-match.
    -- Returning players get priority; the match is capped at 2 (this is a 1v1 —
    -- spawn positions and steering assume at most two Beys). Overflow stays queued.
    MatchManager.OnReadyForRematch(function(returningPlayers)
        local seen = {}
        local pool = {}
        for _, pid in ipairs(returningPlayers) do
            if not seen[pid] then
                seen[pid] = true
                table.insert(pool, pid)
            end
        end
        for _, pid in ipairs(waitingPlayers) do
            if not seen[pid] then
                seen[pid] = true
                table.insert(pool, pid)
            end
        end

        if matchInProgress then
            -- A scheduled lobby start won the race; requeue everyone for the next round
            table.clear(waitingPlayers)
            for _, pid in ipairs(pool) do
                table.insert(waitingPlayers, pid)
            end
            return
        end

        local party = {}
        for _ = 1, math.min(2, #pool) do
            table.insert(party, table.remove(pool, 1))
        end
        table.clear(waitingPlayers)
        for _, pid in ipairs(pool) do
            table.insert(waitingPlayers, pid)
        end

        if #party > 0 then
            matchInProgress = true
            MatchManager.StartNewMatch(party)
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
