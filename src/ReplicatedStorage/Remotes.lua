--[=[
	Remotes.lua
	A centralized definitions module for RemoteEvents.
	Server creates, Client waits — prevents RemoteEvent instance mismatch.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local FOLDER_NAME = "BeyRemotes" -- Distinct name to avoid collision with this ModuleScript

local function getRemotesFolder()
	if IS_SERVER then
		local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
		return folder
	else
		return ReplicatedStorage:WaitForChild(FOLDER_NAME, 10)
	end
end

local function getOrCreateRemote(name: string): RemoteEvent
	local folder = getRemotesFolder()
	if not folder then
		warn("[Remotes] Could not find remotes folder on client!")
		return nil
	end

	if IS_SERVER then
		local remote = folder:FindFirstChild(name)
		if not remote then
			remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
		return remote
	else
		return folder:WaitForChild(name, 10)
	end
end

local Remotes = {
	-- Client to Server
	RequestLaunch   = getOrCreateRemote("RequestLaunch"),
	InputUpdate     = getOrCreateRemote("InputUpdate"),     -- C→S: continuous analog battle input
	RequestQueue    = getOrCreateRemote("RequestQueue"),
	RequestEquip    = getOrCreateRemote("RequestEquip"),
	RequestReady    = getOrCreateRemote("RequestReady"),
	ChallengeResponse = getOrCreateRemote("ChallengeResponse"), -- C→S: accept/decline an invite
	RequestSaveBuild  = getOrCreateRemote("RequestSaveBuild"),  -- C→S: persist a crafted build

	-- Server to Client
	MatchStateChanged   = getOrCreateRemote("MatchStateChanged"),
	StateSnapshot       = getOrCreateRemote("StateSnapshot"),
	CollisionEvent      = getOrCreateRemote("CollisionEvent"),
	UpdateDebugOverlay  = getOrCreateRemote("UpdateDebugOverlay"),
	QueueStatus         = getOrCreateRemote("QueueStatus"),
	ProfileSummary      = getOrCreateRemote("ProfileSummary"),
	MmrUpdated          = getOrCreateRemote("MmrUpdated"),
	ChallengeInvite     = getOrCreateRemote("ChallengeInvite"),  -- S→C: "X challenges you"
	ChallengeStatus     = getOrCreateRemote("ChallengeStatus"),  -- S→C: sent/declined/expired/cancelled
	OpenCustomizer      = getOrCreateRemote("OpenCustomizer"),   -- S→C: open the editor (with current build)
	BuildData           = getOrCreateRemote("BuildData"),        -- S→C: the player's saved build
}

return Remotes
