--[=[
    CustomizerUI.client.lua
    The crafting editor (ADR-003). Opens at the hub workshop (OpenCustomizer).
    Per part (Tip/Disc/Blade/Core): pick a preset shape, set height/weight via
    sliders, set any colour via RGB sliders. A live stat readout shows the
    sidegrade tradeoff (Attack/Defense/Stamina/Agility, summing to a fixed
    budget), and a spinning 3D preview is built from the SAME BeyModelBuilder the
    battle uses — so what you craft is what you fight with. Save persists
    server-side (which re-clamps everything).
]=]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage:WaitForChild("Remotes"))
local BeyParts = require(ReplicatedStorage:WaitForChild("BeyParts"))
local BeyModelBuilder = require(ReplicatedStorage:WaitForChild("BeyModelBuilder"))

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local workingBuild = BeyParts.defaultBuild()
local selectedSlot = "Tip"

-- ── Root (modal, hidden until opened) ─────────────────────────────────────────

local gui = Instance.new("ScreenGui")
gui.Name = "CustomizerGui"
gui.ResetOnSpawn = false
gui.Enabled = false
gui.DisplayOrder = 10
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local dim = Instance.new("Frame")
dim.Size = UDim2.fromScale(1, 1)
dim.BackgroundColor3 = Color3.new(0, 0, 0)
dim.BackgroundTransparency = 0.4
dim.Parent = gui

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(820, 470)
panel.Position = UDim2.new(0.5, -410, 0.5, -235)
panel.BackgroundColor3 = Color3.fromRGB(22, 22, 30)
panel.BorderSizePixel = 0
panel.Parent = dim
local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 14)
panelCorner.Parent = panel

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 36)
title.Position = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack
title.TextSize = 24
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(200, 170, 255)
title.Text = "BEY WORKSHOP"
title.Parent = panel

-- ── 3D preview (left) ─────────────────────────────────────────────────────────

local viewport = Instance.new("ViewportFrame")
viewport.Size = UDim2.fromOffset(260, 300)
viewport.Position = UDim2.new(0, 16, 0, 50)
viewport.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
viewport.BorderSizePixel = 0
viewport.Parent = panel
local vpCorner = Instance.new("UICorner")
vpCorner.CornerRadius = UDim.new(0, 10)
vpCorner.Parent = viewport

local vpCamera = Instance.new("Camera")
vpCamera.FieldOfView = 50
viewport.CurrentCamera = vpCamera
vpCamera.Parent = viewport

local previewModel = nil
local spinAngle = 0

-- ── Stat bars (under preview) ─────────────────────────────────────────────────

local statPanel = Instance.new("Frame")
statPanel.Size = UDim2.fromOffset(260, 92)
statPanel.Position = UDim2.new(0, 16, 0, 360)
statPanel.BackgroundTransparency = 1
statPanel.Parent = panel

local STAT_COLORS = {
	Attack = Color3.fromRGB(230, 80, 70),
	Defense = Color3.fromRGB(80, 140, 240),
	Stamina = Color3.fromRGB(90, 210, 120),
	Agility = Color3.fromRGB(235, 200, 90),
}
local statBars = {}
for i, stat in ipairs(BeyParts.STATS) do
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 20)
	row.Position = UDim2.new(0, 0, 0, (i - 1) * 23)
	row.BackgroundTransparency = 1
	row.Parent = statPanel
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromOffset(64, 20)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 12
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = STAT_COLORS[stat]
	lbl.Text = stat
	lbl.Parent = row
	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -70, 0, 12)
	track.Position = UDim2.new(0, 66, 0.5, -6)
	track.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	track.BorderSizePixel = 0
	track.Parent = row
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0.25, 1)
	fill.BackgroundColor3 = STAT_COLORS[stat]
	fill.BorderSizePixel = 0
	fill.Parent = track
	statBars[stat] = fill
end

-- ── Right column: tabs + controls ─────────────────────────────────────────────

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.fromOffset(510, 34)
tabBar.Position = UDim2.new(0, 292, 0, 50)
tabBar.BackgroundTransparency = 1
tabBar.Parent = panel
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.Parent = tabBar

local tabButtons = {}
local function makeTab(slot)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(120, 34)
	btn.BackgroundColor3 = Color3.fromRGB(40, 40, 52)
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 15
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Text = slot:upper()
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = btn
	btn.Parent = tabBar
	tabButtons[slot] = btn
end
for _, slot in ipairs(BeyParts.SLOTS) do makeTab(slot) end

-- Shape grid
local shapeScroll = Instance.new("ScrollingFrame")
shapeScroll.Size = UDim2.fromOffset(510, 150)
shapeScroll.Position = UDim2.new(0, 292, 0, 92)
shapeScroll.BackgroundColor3 = Color3.fromRGB(16, 16, 24)
shapeScroll.BorderSizePixel = 0
shapeScroll.ScrollBarThickness = 6
shapeScroll.CanvasSize = UDim2.new()
shapeScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
shapeScroll.Parent = panel
local shapeGrid = Instance.new("UIGridLayout")
shapeGrid.CellSize = UDim2.fromOffset(120, 30)
shapeGrid.CellPadding = UDim2.fromOffset(6, 6)
shapeGrid.Parent = shapeScroll
local shapePad = Instance.new("UIPadding")
shapePad.PaddingLeft = UDim.new(0, 6); shapePad.PaddingTop = UDim.new(0, 6)
shapePad.Parent = shapeScroll

-- Slider helper (returns { set=function(v) })
local function makeSlider(parent, y, label, minV, maxV, getV, onChange)
	local row = Instance.new("Frame")
	row.Size = UDim2.fromOffset(510, 26)
	row.Position = UDim2.new(0, 292, 0, y)
	row.BackgroundTransparency = 1
	row.Parent = panel
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromOffset(120, 26)
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.Gotham
	lbl.TextSize = 13
	lbl.TextXAlignment = Enum.TextXAlignment.Left
	lbl.TextColor3 = Color3.fromRGB(210, 210, 220)
	lbl.Text = label
	lbl.Parent = row
	local valLbl = Instance.new("TextLabel")
	valLbl.Size = UDim2.fromOffset(48, 26)
	valLbl.Position = UDim2.new(1, -48, 0, 0)
	valLbl.BackgroundTransparency = 1
	valLbl.Font = Enum.Font.GothamBold
	valLbl.TextSize = 13
	valLbl.TextColor3 = Color3.fromRGB(255, 220, 130)
	valLbl.Parent = row
	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -180, 0, 8)
	track.Position = UDim2.new(0, 124, 0.5, -4)
	track.BackgroundColor3 = Color3.fromRGB(50, 50, 62)
	track.BorderSizePixel = 0
	track.Parent = row
	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(14, 14)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.BackgroundColor3 = Color3.new(1, 1, 1)
	knob.BorderSizePixel = 0
	knob.Parent = track
	local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(1, 0); kc.Parent = knob

	local function render()
		local v = getV()
		local frac = math.clamp((v - minV) / (maxV - minV), 0, 1)
		knob.Position = UDim2.new(frac, 0, 0.5, 0)
		valLbl.Text = string.format("%.1f", v)
	end
	local dragging = false
	local function apply(x)
		local frac = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		onChange(minV + frac * (maxV - minV))
		render()
	end
	track.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true; apply(i.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			apply(i.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	return { render = render }
end

-- ── Forward decls + refresh ───────────────────────────────────────────────────

local rebuildPreview, refreshStats, refreshShapeGrid, refreshSliders, selectSlot

local heightSlider, weightSlider, rSlider, gSlider, bSlider

local function part() return workingBuild[selectedSlot] end

function refreshStats()
	local derived = BeyParts.deriveStats(workingBuild)
	for _, stat in ipairs(BeyParts.STATS) do
		-- fraction 0.25 = neutral; scale 0..0.5 → 0..1 bar for readability
		local frac = derived.fractions[stat]
		statBars[stat].Size = UDim2.fromScale(math.clamp(frac / 0.5, 0.04, 1), 1)
	end
end

function rebuildPreview()
	if previewModel then previewModel:Destroy() end
	previewModel = BeyModelBuilder.build(workingBuild, Vector3.new(0, 0, 0))
	previewModel.Parent = viewport
	-- Frame the model
	local cf, size = previewModel:GetBoundingBox()
	local _ = cf
	local dist = (size.Magnitude) + 6
	vpCamera.CFrame = CFrame.lookAt(Vector3.new(0, size.Y * 0.5 + 1, dist), Vector3.new(0, size.Y * 0.4, 0))
end

function refreshShapeGrid()
	for _, child in ipairs(shapeScroll:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	for _, def in ipairs(BeyParts.SHAPES[selectedSlot]) do
		local btn = Instance.new("TextButton")
		btn.BackgroundColor3 = (def.id == part().shape) and Color3.fromRGB(120, 90, 200) or Color3.fromRGB(40, 40, 52)
		btn.BorderSizePixel = 0
		btn.Font = Enum.Font.Gotham
		btn.TextSize = 12
		btn.TextColor3 = Color3.new(1, 1, 1)
		btn.Text = def.name .. (def.render and def.render.wild and " ★" or "")
		local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 6); c.Parent = btn
		btn.Parent = shapeScroll
		btn.MouseButton1Click:Connect(function()
			part().shape = def.id
			refreshShapeGrid(); refreshStats(); rebuildPreview()
		end)
	end
end

function refreshSliders()
	local limits = BeyParts.LIMITS[selectedSlot]
	heightSlider.render()
	weightSlider.render()
	rSlider.render(); gSlider.render(); bSlider.render()
	local _ = limits
end

function selectSlot(slot)
	selectedSlot = slot
	for s, btn in pairs(tabButtons) do
		btn.BackgroundColor3 = (s == slot) and Color3.fromRGB(120, 90, 200) or Color3.fromRGB(40, 40, 52)
	end
	-- Rebuild sliders against this slot's limits
	refreshShapeGrid()
	refreshSliders()
end
for _, slot in ipairs(BeyParts.SLOTS) do
	tabButtons[slot].MouseButton1Click:Connect(function() selectSlot(slot) end)
end

-- Sliders (height/weight read the SELECTED slot's limits dynamically)
heightSlider = makeSlider(panel, 250, "Height", 0, 1,
	function()
		local lim = BeyParts.LIMITS[selectedSlot].height
		return (part().height - lim.min) / (lim.max - lim.min)
	end,
	function(frac)
		local lim = BeyParts.LIMITS[selectedSlot].height
		part().height = lim.min + frac * (lim.max - lim.min)
		refreshStats(); rebuildPreview()
	end)
weightSlider = makeSlider(panel, 280, "Weight", 0, 1,
	function()
		local lim = BeyParts.LIMITS[selectedSlot].weight
		return (part().weight - lim.min) / (lim.max - lim.min)
	end,
	function(frac)
		local lim = BeyParts.LIMITS[selectedSlot].weight
		part().weight = lim.min + frac * (lim.max - lim.min)
		refreshStats() -- weight affects stats but not the silhouette
	end)
local function colorSlider(y, label, idx)
	return makeSlider(panel, y, label, 0, 255,
		function() return part().color[idx] end,
		function(v)
			part().color[idx] = math.floor(v)
			rebuildPreview()
		end)
end
rSlider = colorSlider(312, "Colour R", 1)
gSlider = colorSlider(340, "Colour G", 2)
bSlider = colorSlider(368, "Colour B", 3)

-- ── Save / Close ──────────────────────────────────────────────────────────────

local function makeActionButton(text, xOffset, color)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(150, 40)
	btn.Position = UDim2.new(0, xOffset, 1, -50)
	btn.BackgroundColor3 = color
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBlack
	btn.TextSize = 16
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.Text = text
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = btn
	btn.Parent = panel
	return btn
end

local function closeEditor()
	gui.Enabled = false
	if previewModel then previewModel:Destroy(); previewModel = nil end
end

local saveBtn = makeActionButton("SAVE", 500, Color3.fromRGB(70, 160, 90))
local closeBtn = makeActionButton("CLOSE", 656, Color3.fromRGB(120, 60, 60))
saveBtn.MouseButton1Click:Connect(function()
	Remotes.RequestSaveBuild:FireServer(workingBuild)
	closeEditor()
end)
closeBtn.MouseButton1Click:Connect(closeEditor)

-- ── Wire-up ───────────────────────────────────────────────────────────────────

local function deepCopyBuild(b)
	local copy = {}
	for _, slot in ipairs(BeyParts.SLOTS) do
		local p = b[slot] or {}
		copy[slot] = {
			shape = p.shape or "Standard",
			height = p.height,
			weight = p.weight,
			color = { (p.color or {})[1] or 170, (p.color or {})[2] or 175, (p.color or {})[3] or 185 },
		}
	end
	return BeyParts.clampBuild(copy)
end

-- BuildData preloads the saved build (join + save confirms)
Remotes.BuildData.OnClientEvent:Connect(function(build)
	workingBuild = deepCopyBuild(build)
	if gui.Enabled then
		selectSlot(selectedSlot); refreshStats(); rebuildPreview()
	end
end)

Remotes.OpenCustomizer.OnClientEvent:Connect(function(build)
	workingBuild = deepCopyBuild(build)
	gui.Enabled = true
	selectSlot("Tip")
	refreshStats()
	rebuildPreview()
end)

-- Spin the preview
RunService.RenderStepped:Connect(function(dt)
	if gui.Enabled and previewModel and previewModel.PrimaryPart then
		spinAngle += dt * 2
		previewModel:PivotTo(CFrame.new(previewModel.PrimaryPart.Position) * CFrame.Angles(0, spinAngle, 0))
	end
end)
