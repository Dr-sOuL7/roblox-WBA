--[=[
    InterpolationRenderer.client.lua
    Buffers server snapshots to smoothly Lerp authoritative CFrame states.
    Preserves arcs, visualizes hitstop, and dynamically renders RPM spin.
]=]
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))

local snapshotBuffer = {}
local RENDER_DELAY = 0.1 -- 100ms interpolation buffer

local beyVisuals = {} -- { [pid] = { rotation = 0, hitstop = 0 } }

local function getBeyModel(playerId)
    return workspace:FindFirstChild("Bey_" .. tostring(playerId))
end

Remotes.StateSnapshot.OnClientEvent:Connect(function(snapshot)
    table.insert(snapshotBuffer, snapshot)
    
    if #snapshotBuffer > 20 then
        table.remove(snapshotBuffer, 1)
    end
    
    -- Process events for hitstop and audio
    for _, ev in ipairs(snapshot.events) do
        if ev.eventType == "Collision" then
            local class = ev.eventData.collisionClass
            local hitstopDuration = 0
            local soundPitch = 1.0
            
            if class == "Smash" then 
                hitstopDuration = 0.08
                soundPitch = 0.8
            elseif class == "Heavy" then 
                hitstopDuration = 0.04 
                soundPitch = 1.0
            else
                soundPitch = 1.2
            end
            
            -- Apply hitstop to involved beys
            for _, pid in ipairs(ev.eventData.involvedBeys) do
                if not beyVisuals[pid] then beyVisuals[pid] = {rotation=0, hitstop=0} end
                if hitstopDuration > 0 then
                    beyVisuals[pid].hitstop = hitstopDuration
                end
            end
            
            -- Placeholder Audio
            local sound = Instance.new("Sound")
            sound.SoundId = "rbxassetid://131154564" -- Placeholder metallic clang
            sound.PlaybackSpeed = soundPitch
            sound.Volume = (class == "Light") and 0.3 or 0.8
            sound.Parent = workspace
            sound:Play()
            game.Debris:AddItem(sound, 2)
        end
    end
end)

RunService.RenderStepped:Connect(function(dt)
    local renderTime = os.clock() - RENDER_DELAY
    
    local snap0, snap1 = nil, nil
    for i = #snapshotBuffer, 1, -1 do
        if snapshotBuffer[i].serverTimestamp <= renderTime then
            snap0 = snapshotBuffer[i]
            snap1 = snapshotBuffer[i+1]
            break
        end
    end
    
    if snap0 and snap1 then
        -- Epsilon denominator protection against NaN
        local timeDiff = math.max(0.0001, snap1.serverTimestamp - snap0.serverTimestamp)
        local alpha = math.clamp((renderTime - snap0.serverTimestamp) / timeDiff, 0, 1)
        
        for pid, bState0 in pairs(snap0.beyStates) do
            local bState1 = snap1.beyStates[pid]
            if bState1 then
                if not beyVisuals[pid] then beyVisuals[pid] = {rotation=0, hitstop=0} end
                local vis = beyVisuals[pid]
                
                -- Process visual hitstop freeze
                if vis.hitstop > 0 then
                    vis.hitstop -= dt
                    continue 
                end
                
                -- Accumulate spin derived from actual physical RPM
                vis.rotation += bState0.angularVelocity.Magnitude * dt
                
                local model = getBeyModel(pid)
                if model then
                    local interpPos = bState0.position:Lerp(bState1.position, alpha)
                    local tiltAngle = math.rad(bState0.tilt)
                    
                    model.CFrame = CFrame.new(interpPos) 
                                 * CFrame.Angles(tiltAngle, vis.rotation, 0)
                end
            end
        end
    elseif snap0 then
        for pid, bState0 in pairs(snap0.beyStates) do
            if not beyVisuals[pid] then beyVisuals[pid] = {rotation=0, hitstop=0} end
            local vis = beyVisuals[pid]
            
            if vis.hitstop > 0 then
                vis.hitstop -= dt
                continue
            end
            
            vis.rotation += bState0.angularVelocity.Magnitude * dt
            
            local model = getBeyModel(pid)
            if model then
                model.CFrame = CFrame.new(bState0.position)
                             * CFrame.Angles(math.rad(bState0.tilt), vis.rotation, 0)
            end
        end
    end
end)
