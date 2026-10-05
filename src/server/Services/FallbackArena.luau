--[[
	FallbackArena (Gameplay team)

	A small, flat, procedurally built test arena used by RoundService ONLY when MapService is missing
	or fails to load a map, so the core loop is always playable (e.g. a solo tester in Studio before
	the Map team's builders exist).

	It lives in Services/ but is not a service (no Init/Start); the bootstrap simply loads it.

	FallbackArena.Build() -> MapInfo    (builds workspace.Map, returns the MapInfo contract table)
	FallbackArena.Destroy()
	FallbackArena.ID = "FallbackArena"
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)

local FallbackArena = {}

FallbackArena.ID = "FallbackArena"
FallbackArena.NAME = "Training Grounds"

local SIZE_X, SIZE_Z = 520, 300
local GROUND_Y = 0

local root: Folder? = nil

local function part(parent: Instance, props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	CollectionService:AddTag(p, Constants.TAGS.MapGeometry)
	return p
end

-- Deterministic pseudo-random cover layout so the arena is identical every time.
local function buildCover(parent: Folder)
	local rng = Random.new(1944)
	for _ = 1, 46 do
		local x = rng:NextNumber(-SIZE_X / 2 + 70, SIZE_X / 2 - 70)
		local z = rng:NextNumber(-SIZE_Z / 2 + 15, SIZE_Z / 2 - 15)
		local kind = rng:NextInteger(1, 3)
		if kind == 1 then
			-- sandbag wall
			part(parent, {
				Name = "Sandbags",
				Size = Vector3.new(rng:NextNumber(8, 16), 3.5, 3),
				CFrame = CFrame.new(x, GROUND_Y + 1.75, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
				Color = Color3.fromRGB(150, 135, 100),
				Material = Enum.Material.Fabric,
			})
		elseif kind == 2 then
			-- crate stack
			local s = rng:NextNumber(4, 6)
			part(parent, {
				Name = "Crate",
				Size = Vector3.new(s, s, s),
				CFrame = CFrame.new(x, GROUND_Y + s / 2, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
				Color = Color3.fromRGB(110, 84, 52),
				Material = Enum.Material.WoodPlanks,
			})
		else
			-- ruined wall segment
			local h = rng:NextNumber(7, 12)
			part(parent, {
				Name = "Wall",
				Size = Vector3.new(rng:NextNumber(12, 24), h, 2),
				CFrame = CFrame.new(x, GROUND_Y + h / 2, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
				Color = Color3.fromRGB(140, 132, 120),
				Material = Enum.Material.Brick,
			})
		end
	end
end

local function buildFlag(parent: Folder, id: string, position: Vector3)
	local model = Instance.new("Model")
	model.Name = id
	local pole = part(model, {
		Name = "Pole",
		Size = Vector3.new(0.6, 22, 0.6),
		CFrame = CFrame.new(position + Vector3.new(0, 11, 0)),
		Color = Color3.fromRGB(80, 80, 80),
		Material = Enum.Material.Metal,
		CanCollide = false,
	})
	part(model, {
		Name = "Flag",
		Size = Vector3.new(6, 4, 0.2),
		CFrame = CFrame.new(position + Vector3.new(3.3, 19.5, 0)),
		Color = Constants.SIDE_COLORS.Neutral,
		Material = Enum.Material.Fabric,
		CanCollide = false,
	})
	part(model, {
		Name = "Base",
		Size = Vector3.new(4, 1, 4),
		CFrame = CFrame.new(position + Vector3.new(0, 0.5, 0)),
		Color = Color3.fromRGB(90, 90, 90),
		Material = Enum.Material.Concrete,
	})
	model.PrimaryPart = pole
	model.Parent = parent
end

local function hqSpawns(x: number, facing: number): { CFrame }
	local list = {}
	for i = -3, 3 do
		local pos = Vector3.new(x, GROUND_Y + 3, i * 9)
		table.insert(list, CFrame.lookAlong(pos, Vector3.new(facing, 0, 0)))
	end
	return list
end

local function ringSpawns(center: Vector3, radius: number): { CFrame }
	local list = {}
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		local pos = center + Vector3.new(math.cos(a) * radius, 3, math.sin(a) * radius)
		table.insert(list, CFrame.lookAt(pos, Vector3.new(center.X, pos.Y, center.Z)))
	end
	return list
end

function FallbackArena.Destroy()
	if root then
		root:Destroy()
		root = nil
	end
end

function FallbackArena.Build()
	FallbackArena.Destroy()
	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy() -- a half-built map left behind by a failed MapService load
	end

	local map = Instance.new("Folder")
	map.Name = "Map"
	local geometry = Instance.new("Folder")
	geometry.Name = "Geometry"
	geometry.Parent = map
	local objectivesFolder = Instance.new("Folder")
	objectivesFolder.Name = "Objectives"
	objectivesFolder.Parent = map

	-- Ground and perimeter walls.
	part(geometry, {
		Name = "Ground",
		Size = Vector3.new(SIZE_X + 80, 4, SIZE_Z + 80),
		CFrame = CFrame.new(0, GROUND_Y - 2, 0),
		Color = Color3.fromRGB(96, 110, 70),
		Material = Enum.Material.Grass,
	})
	for _, side in { -1, 1 } do
		part(geometry, {
			Name = "Perimeter",
			Size = Vector3.new(SIZE_X + 80, 20, 4),
			CFrame = CFrame.new(0, GROUND_Y + 10, side * (SIZE_Z / 2 + 40)),
			Transparency = 0.6,
			Color = Color3.fromRGB(120, 120, 120),
		})
		part(geometry, {
			Name = "Perimeter",
			Size = Vector3.new(4, 20, SIZE_Z + 80),
			CFrame = CFrame.new(side * (SIZE_X / 2 + 40), GROUND_Y + 10, 0),
			Transparency = 0.6,
			Color = Color3.fromRGB(120, 120, 120),
		})
	end
	-- HQ pads
	for _, x in { -SIZE_X / 2 + 20, SIZE_X / 2 - 20 } do
		part(geometry, {
			Name = "HQ",
			Size = Vector3.new(24, 0.4, 70),
			CFrame = CFrame.new(x, GROUND_Y + 0.2, 0),
			Color = if x < 0 then Constants.SIDE_COLORS.Allies else Constants.SIDE_COLORS.Axis,
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
		})
	end
	buildCover(geometry)

	local objectiveDefs = {
		{ id = "A", name = "Crossroads", x = -150 },
		{ id = "B", name = "Farmhouse", x = 0 },
		{ id = "C", name = "Supply Depot", x = 150 },
	}
	local objectives = {}
	for i, def in objectiveDefs do
		local position = Vector3.new(def.x, GROUND_Y, 0)
		buildFlag(objectivesFolder, def.id, position)
		table.insert(objectives, {
			id = def.id,
			name = def.name,
			position = position,
			radius = 22,
			order = i,
			initialOwner = "Neutral",
			spawns = ringSpawns(position, 30),
		})
	end

	map.Parent = workspace
	root = map

	return {
		id = FallbackArena.ID,
		bounds = {
			center = Vector3.new(0, GROUND_Y + 60, 0),
			size = Vector3.new(SIZE_X + 60, 200, SIZE_Z + 60),
		},
		hq = {
			Allies = hqSpawns(-SIZE_X / 2 + 20, 1),
			Axis = hqSpawns(SIZE_X / 2 - 20, -1),
		},
		objectives = objectives,
		vehicleSpawns = { Allies = {}, Axis = {} },
		minimap = {
			{ kind = "field", cx = 0, cz = 0, sx = SIZE_X, sz = SIZE_Z, rot = 0 },
		},
		outOfBounds = 8,
	}
end

return FallbackArena
