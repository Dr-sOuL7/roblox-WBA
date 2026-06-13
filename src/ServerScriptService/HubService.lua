--[=[
	HubService.lua
	The social hub: a walk-around lobby where player characters spawn, approach
	each other, and challenge to a Beyblade battle (director feature).

	Flow: spawn in hub → walk near a player (or the bot dummy) → a "Challenge"
	ProximityPrompt appears → trigger it → ChallengeService takes over. On
	accept, characters despawn (in MatchManager.StartNewMatch) and the validated
	Bey battle begins. On match end, players respawn here.

	This layer is pure Roblox runtime (characters, ProximityPrompts, cameras)
	and is NOT covered by the headless harness — it needs live Studio
	verification. It never touches the simulation.

	Dependency note: HubService EXPOSES challenge callbacks that ChallengeService
	registers (one-directional: ChallengeService → HubService), so there is no
	require cycle.
]=]
local Players = game:GetService("Players")

local HubService = {}

-- Registered by ChallengeService at init (avoids a require cycle)
HubService.onPlayerChallenge = nil -- function(fromPlayer, toPlayer)
HubService.onBotChallenge = nil    -- function(fromPlayer)

-- Hub geometry: a platform centred in front of the arena slots (which sit at
-- x = 0, 200, 400, 600 on z ≈ 0). Players spawn here and can see the arenas.
local HUB_CENTER = Vector3.new(300, 0, 170)
local HUB_SIZE = Vector3.new(260, 2, 100)
local CHALLENGE_DISTANCE = 14

local _hubFolder = nil
local _built = false

local function getHubFolder()
	if not _hubFolder or not _hubFolder.Parent then
		_hubFolder = workspace:FindFirstChild("Hub")
		if not _hubFolder then
			_hubFolder = Instance.new("Folder")
			_hubFolder.Name = "Hub"
			_hubFolder.Parent = workspace
		end
	end
	return _hubFolder
end

-- ── Build the hub once ────────────────────────────────────────────────────────

function HubService.BuildHub()
	if _built then return end
	_built = true
	local folder = getHubFolder()

	local platform = Instance.new("Part")
	platform.Name = "HubPlatform"
	platform.Anchored = true
	platform.Size = HUB_SIZE
	platform.Position = HUB_CENTER
	platform.Material = Enum.Material.WoodPlanks
	platform.Color = Color3.fromRGB(90, 75, 60)
	platform.TopSurface = Enum.SurfaceType.Smooth
	platform.Parent = folder

	-- Low decorative rail so players read the platform edge
	for _, sx in ipairs({ -1, 1 }) do
		local rail = Instance.new("Part")
		rail.Name = "Rail"
		rail.Anchored = true
		rail.CanCollide = true
		rail.Size = Vector3.new(HUB_SIZE.X, 3, 1)
		rail.Position = HUB_CENTER + Vector3.new(0, 2.5, sx * HUB_SIZE.Z / 2)
		rail.Color = Color3.fromRGB(60, 50, 40)
		rail.Parent = folder
	end

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "HubSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.Position = HUB_CENTER + Vector3.new(0, 1.5, 25)
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Color = Color3.fromRGB(120, 170, 255)
	spawn.Parent = folder

	local sign = Instance.new("Part")
	sign.Name = "HubSign"
	sign.Anchored = true
	sign.CanCollide = false
	sign.Size = Vector3.new(0.5, 0.5, 0.5)
	sign.Transparency = 1
	sign.Position = HUB_CENTER + Vector3.new(0, 12, 0)
	sign.Parent = folder
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(420, 60)
	billboard.AlwaysOnTop = true
	billboard.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 220, 130)
	label.TextStrokeTransparency = 0
	label.Text = "BEY ARENA — walk up to a player and Challenge!"
	label.Parent = billboard

	HubService.SpawnBotDummy()
end

-- ── Bot challenge dummy ───────────────────────────────────────────────────────

function HubService.SpawnBotDummy()
	local folder = getHubFolder()
	if folder:FindFirstChild("ChallengeBot") then return end

	local model = Instance.new("Model")
	model.Name = "ChallengeBot"

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Anchored = true
	root.Size = Vector3.new(2, 2, 1)
	root.Position = HUB_CENTER + Vector3.new(0, 3, -10)
	root.Color = Color3.fromRGB(80, 80, 95)
	root.Parent = model
	model.PrimaryPart = root

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Anchored = true
	head.Size = Vector3.new(1.6, 1.6, 1.6)
	head.Position = root.Position + Vector3.new(0, 1.8, 0)
	head.Color = Color3.fromRGB(120, 200, 255)
	head.Material = Enum.Material.Neon
	head.Parent = model

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(200, 50)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(120, 200, 255)
	label.TextStrokeTransparency = 0
	label.Text = "PRACTICE BOT"
	label.Parent = billboard

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ChallengePrompt"
	prompt.ActionText = "Challenge"
	prompt.ObjectText = "Practice Bot"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = CHALLENGE_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	prompt.Triggered:Connect(function(triggerer)
		if HubService.onBotChallenge then
			HubService.onBotChallenge(triggerer)
		end
	end)

	model.Parent = folder
end

-- ── Character lifecycle ───────────────────────────────────────────────────────

local function attachChallengePrompt(owner: Player, character)
	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not hrp then return end
	if hrp:FindFirstChild("ChallengePrompt") then return end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ChallengePrompt"
	prompt.ActionText = "Challenge"
	prompt.ObjectText = owner.Name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = CHALLENGE_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Parent = hrp
	prompt.Triggered:Connect(function(triggerer)
		if triggerer ~= owner and HubService.onPlayerChallenge then
			HubService.onPlayerChallenge(triggerer, owner)
		end
	end)
end

-- Connect prompt-attachment for a player's (re)spawns. Idempotent per player.
local _wired = {}
local function wirePlayer(player: Player)
	if _wired[player] then return end
	_wired[player] = true
	player.CharacterAdded:Connect(function(character)
		attachChallengePrompt(player, character)
	end)
	if player.Character then
		attachChallengePrompt(player, player.Character)
	end
end

-- Spawn (or respawn) a player into the hub as a walking character.
function HubService.SpawnInHub(player: Player)
	wirePlayer(player)
	-- Default replication focus follows the character (we only pin an explicit
	-- focus during a battle, when no character exists).
	player.ReplicationFocus = nil
	player:LoadCharacter()
end

Players.PlayerRemoving:Connect(function(player)
	_wired[player] = nil
end)

return HubService
