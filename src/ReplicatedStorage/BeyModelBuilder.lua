--[=[
	BeyModelBuilder.lua
	Builds the 3D Bey model from a craft build (ADR-003), so a crafted Bey
	actually LOOKS like its parts — used by both the battle (server-built model,
	replicated) and the editor live preview (client). Shared, so the preview and
	the real thing can never diverge.

	Layout, bottom→top: Tip (contact point) · Disc (flywheel) · Blade
	(surrounding ring) · Core (top centre). Each part's vertical size scales with
	its build height; colour is the part's chosen colour. Shapes come from the
	BeyParts render hints, grouped into a few visual families (discs/rings, balls,
	points, radial-spikes/stars/wings) — enough that the build reads at a glance.

	Pure construction (only Instance/Vector3/CFrame/Color3). The caller anchors
	and positions via Model:PivotTo; PrimaryPart is a transparent base pivot.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local BeyParts = require(ReplicatedStorage:WaitForChild("BeyParts"))

local BeyModelBuilder = {}

local function color3(rgb)
	if typeof(rgb) == "Color3" then return rgb end
	if type(rgb) == "table" then
		return Color3.fromRGB(rgb[1] or 170, rgb[2] or 175, rgb[3] or 185)
	end
	return Color3.fromRGB(170, 175, 185)
end

local function newPart(parent, size, cframe, color, material, shape)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then p.Shape = shape end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- A horizontal disc (Roblox cylinder lies along its X axis → rotate flat)
local function disc(parent, baseCFrame, y, radius, thickness, color, material)
	newPart(parent, Vector3.new(thickness, radius * 2, radius * 2),
		baseCFrame * CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90)),
		color, material, Enum.PartType.Cylinder)
end

local function ball(parent, baseCFrame, y, radius, color, material)
	newPart(parent, Vector3.new(radius * 2, radius * 2, radius * 2),
		baseCFrame * CFrame.new(0, y, 0), color, material, Enum.PartType.Ball)
end

-- Radial blades/spikes/teeth around a ring (count, reach, how pointy via size)
local function radial(parent, baseCFrame, y, count, innerR, reach, bladeW, height, color, material)
	count = math.max(2, math.floor(count))
	for i = 1, count do
		local ang = (i / count) * math.pi * 2
		local dir = Vector3.new(math.cos(ang), 0, math.sin(ang))
		local pos = dir * (innerR + reach / 2)
		newPart(parent, Vector3.new(reach, height, bladeW),
			baseCFrame * CFrame.new(pos.X, y, pos.Z) * CFrame.Angles(0, -ang, 0),
			color, material)
	end
end

-- Build one part family at vertical band [y .. y+bandHeight]
local function buildPartVisual(parent, baseCFrame, slot, partDef, y, color)
	local render = BeyParts.getShape(slot, partDef.shape).render or {}
	local kind = render.kind or "disc"
	local h = partDef.height
	local r = render.radius or 1
	local metal = Enum.Material.Metal
	local mid = y + h / 2

	if kind == "ball" or kind == "gem" then
		ball(parent, baseCFrame, mid, math.max(0.3, r), color, kind == "gem" and Enum.Material.Glass or Enum.Material.SmoothPlastic)
	elseif kind == "point" or kind == "cone" or kind == "spire" then
		-- tapering spike: a thin tall cylinder + tip ball
		disc(parent, baseCFrame, mid, math.max(0.12, r * 0.5), h, color, metal)
		ball(parent, baseCFrame, y + h, math.max(0.1, r * 0.35), color, metal)
	elseif kind == "needle" or kind == "claw" or kind == "twin" then
		disc(parent, baseCFrame, mid, math.max(0.1, r), h, color, metal)
	elseif kind == "cylinder" or kind == "oval" or kind == "plate" or kind == "rubber" then
		disc(parent, baseCFrame, mid, r, h, color, kind == "rubber" and Enum.Material.SmoothPlastic or metal)
	elseif kind == "disc" or kind == "dome" or kind == "hollow" then
		disc(parent, baseCFrame, mid, r, h, color, metal)
	elseif kind == "ring" then
		disc(parent, baseCFrame, mid, r, h, color, Enum.Material.SmoothPlastic)
	elseif kind == "crown" then
		disc(parent, baseCFrame, mid, r * 0.7, h * 0.6, color, metal)
		radial(parent, baseCFrame, mid, render.sides or 6, r * 0.5, r * 0.4, 0.3, h, color, metal)
	elseif kind == "gear" or kind == "bumper" then
		disc(parent, baseCFrame, mid, r, h, color, metal)
		radial(parent, baseCFrame, mid, render.sides or render.bumps or 10, r, 0.4, 0.5, h * 0.8, color, metal)
	elseif kind == "spikes" or kind == "star" or kind == "shuriken" or kind == "sawblade"
		or kind == "cross" or kind == "eccentric" then
		disc(parent, baseCFrame, mid, r * 0.7, h, color, metal)
		local count = render.spikes or render.points or (kind == "cross" and 4) or 6
		radial(parent, baseCFrame, mid, count, r * 0.65, r * 0.6, 0.45, h, color, metal)
	elseif kind == "wing" or kind == "turbine" then
		disc(parent, baseCFrame, mid, r * 0.7, h, color, metal)
		radial(parent, baseCFrame, mid, render.wings or render.blades or 3, r * 0.6, r * 0.7, 0.7, h * 0.7, color, metal)
	else
		disc(parent, baseCFrame, mid, r, h, color, metal)
	end
end

--[=[
	build(buildSpec, basePosition, options) -> Model
	options:
	  name        : model name (default "Bey")
	  teamColor   : Color3 — adds a base identity ring (P1 red / P2 blue)
	  bladeColorFallback : Color3 when a part has no colour
]=]
function BeyModelBuilder.build(buildSpec, basePosition, options)
	options = options or {}
	local clean = BeyParts.clampBuild(buildSpec)
	basePosition = basePosition or Vector3.new(0, 0, 0)

	local model = Instance.new("Model")
	model.Name = options.name or "Bey"

	local pivot = Instance.new("Part")
	pivot.Name = "Pivot"
	pivot.Size = Vector3.new(0.2, 0.2, 0.2)
	pivot.Transparency = 1
	pivot.Anchored = true
	pivot.CanCollide = false
	pivot.CanQuery = false
	pivot.CFrame = CFrame.new(basePosition)
	pivot.Parent = model
	model.PrimaryPart = pivot

	local base = pivot.CFrame

	-- Team identity ring at the base (separate channel from part colours)
	if options.teamColor then
		newPart(model, Vector3.new(0.25, 5.2, 5.2),
			base * CFrame.new(0, 0.15, 0) * CFrame.Angles(0, 0, math.rad(90)),
			options.teamColor, Enum.Material.Neon, Enum.PartType.Cylinder)
	end

	-- Vertical stack. Tips sit lowest; the blade surrounds the disc band.
	local tip = clean.Tip
	local disc_ = clean.Disc
	local blade = clean.Blade
	local core = clean.Core

	local yTip = 0.2
	local yDisc = yTip + tip.height
	local yBlade = yDisc + disc_.height * 0.4 -- blade overlaps/surrounds the disc band
	local yCore = yDisc + disc_.height + 0.05

	buildPartVisual(model, base, "Tip", tip, yTip, color3(tip.color))
	buildPartVisual(model, base, "Disc", disc_, yDisc, color3(disc_.color))
	buildPartVisual(model, base, "Blade", blade, yBlade, color3(blade.color))
	buildPartVisual(model, base, "Core", core, yCore, color3(core.color))

	return model
end

return BeyModelBuilder
