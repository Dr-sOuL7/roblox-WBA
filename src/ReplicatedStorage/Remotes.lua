--[=[
    Remotes.lua
    A centralized definitions module for RemoteEvents.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function getOrCreateRemote(name: string): RemoteEvent
    local folder = ReplicatedStorage:FindFirstChild("Remotes")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "Remotes"
        folder.Parent = ReplicatedStorage
    end

    local remote = folder:FindFirstChild(name)
    if not remote then
        remote = Instance.new("RemoteEvent")
        remote.Name = name
        remote.Parent = folder
    end

    return remote
end

local Remotes = {
    -- Client to Server
    RequestLaunch = getOrCreateRemote("RequestLaunch"),

    -- Server to Client
    MatchStateChanged = getOrCreateRemote("MatchStateChanged"),
    StateSnapshot = getOrCreateRemote("StateSnapshot"),
    CollisionEvent = getOrCreateRemote("CollisionEvent"),
    UpdateDebugOverlay = getOrCreateRemote("UpdateDebugOverlay"),
}

return Remotes
