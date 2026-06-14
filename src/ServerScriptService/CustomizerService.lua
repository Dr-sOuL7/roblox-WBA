--[=[
	CustomizerService.lua
	Server side of the customization venue (ADR-003). Opens the editor when a
	player triggers the workshop prompt, and validates + persists saved builds.

	Server-authoritative: the client sends a build (shape ids + numbers + colour);
	the server CLAMPS every value (BeyParts.clampBuild — unknown shapes → Standard,
	out-of-range clamped) before it ever touches the profile. The next match reads
	the saved build at start (MatchManager), so equips are naturally match-safe.

	No mid-match editing: a player in a match has no character at the workshop, so
	the prompt is unreachable; we also reject saves from players currently in a
	match as defence in depth.
]=]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local BeyParts = require(ReplicatedStorage:WaitForChild("BeyParts"))
local HubService = require(script.Parent:WaitForChild("HubService"))
local TickManager = require(script.Parent:WaitForChild("TickManager"))
local ProfileStore = require(script.Parent:WaitForChild("Persistence"):WaitForChild("ProfileStore"))

local CustomizerService = {}

local function currentBuild(userId)
	local profile = ProfileStore.GetProfile(userId)
	if profile and profile.build then
		return BeyParts.clampBuild(profile.build)
	end
	return BeyParts.defaultBuild()
end

-- Push the player's saved build (e.g. on join, so the editor preloads it)
function CustomizerService.PushBuild(userId)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		Remotes.BuildData:FireClient(player, currentBuild(userId))
	end
end

-- Workshop prompt → open the editor with the current build
function CustomizerService.OpenEditor(player)
	if TickManager.GetInstanceForPlayer(player.UserId) then
		return -- in a match; ignore
	end
	Remotes.OpenCustomizer:FireClient(player, currentBuild(player.UserId))
end

Remotes.RequestSaveBuild.OnServerEvent:Connect(function(player, build)
	if TickManager.GetInstanceForPlayer(player.UserId) then
		return -- no mid-match saves
	end
	local clean = BeyParts.clampBuild(build) -- never trust client geometry
	local ok = ProfileStore.UpdateProfile(player.UserId, function(data)
		data.build = clean
	end)
	if ok then
		Remotes.BuildData:FireClient(player, clean) -- confirm the stored version
		print(string.format("[Customizer] Saved build for %s", player.Name))
	end
end)

HubService.onCustomize = CustomizerService.OpenEditor

return CustomizerService
