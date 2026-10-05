--[[
	MapKit.Core — the build Context shared by every MapKit primitive.

	A Context bundles everything a procedural map builder needs:
	  * a seeded Random (`ctx.rng`) so a map is identical on every load,
	  * the root Folder the map is built into (`ctx.root`, normally workspace.Map),
	  * a part factory (`ctx:Part{...}`) with sane performance defaults
	    (Anchored, CanTouch=false, CastShadow only on big parts, colour jitter),
	  * cooperative yielding (`ctx:Step()`), so building thousands of parts never hitches the server,
	  * ground queries (`ctx:GroundY`, `ctx:SurfaceY`) backed by the HeightModel used to
	    generate the terrain (analytic, fast) or by raycasts against Terrain,
	  * the minimap shape list (`ctx:AddMinimap`) that ends up in MapInfo.minimap.

	Every MapKit function takes the Context as its first argument:

		local ctx = MapKit.new(parentFolder, { seed = 1944 })
		MapKit.Buildings.House(ctx, CFrame.new(0, 0, 0), { floors = 2 })
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Constants"))

local Core = {}

Core.TAG_DESTRUCTIBLE = Constants.TAGS.Destructible
Core.TAG_MAP = Constants.TAGS.MapGeometry
Core.TAG_NO_PEN = Constants.TAGS.NoBulletPenetration

export type MinimapEntry = {
	kind: string,
	cx: number,
	cz: number,
	sx: number,
	sz: number,
	rot: number,
}

-- Specification accepted by ctx:Part. Only Size and CFrame are required.
export type PartSpec = {
	Name: string?,
	Size: Vector3,
	CFrame: CFrame,
	Parent: Instance?,
	Material: Enum.Material?,
	Color: Color3?,
	Jitter: number?, -- colour variation 0..1 (default 0.05); 0 disables
	Shape: string?, -- "Block" (default) | "Ball" | "Cylinder" | "Wedge" | "CornerWedge" | "Truss"
	Mesh: string?, -- "Sphere" -> ellipsoid via SpecialMesh (non-uniform Ball)
	Transparency: number?,
	Reflectance: number?,
	CanCollide: boolean?,
	CanQuery: boolean?,
	CastShadow: boolean?, -- default: true only for parts with volume > 60 studs^3
	Destructible: boolean?, -- tag for DestructionService
	Health: number?, -- optional destructible health override (attribute "Health")
	NoPenetration: boolean?, -- tag NoBulletPenetration (bunkers, thick concrete)
	Tags: { string }?,
}

local Context = {}
Context.__index = Context

export type Context = typeof(setmetatable(
	{} :: {
		root: Instance,
		rng: Random,
		seed: number,
		partCount: number,
		minimap: { MinimapEntry },
		heightModel: any,
		yieldEvery: number,
		_sinceYield: number,
		_folders: { [string]: Folder },
		_rayParams: RaycastParams,
		objectives: Folder,
	},
	Context
))

--[[
	Core.new(parent, opts) -> Context
	  parent : Instance the map is built into (MapService passes workspace.Map)
	  opts.seed       : number   deterministic seed (default 1)
	  opts.yieldEvery : number   parts created between task.wait() yields (default 220)
]]
function Core.new(parent: Instance, opts: { seed: number?, yieldEvery: number? }?): Context
	local o = opts or {}
	local seed = o.seed or 1
	local self = setmetatable({
		root = parent,
		rng = Random.new(seed),
		seed = seed,
		partCount = 0,
		minimap = {},
		heightModel = nil,
		yieldEvery = o.yieldEvery or 220,
		_sinceYield = 0,
		_folders = {},
		_rayParams = RaycastParams.new(),
		objectives = nil :: any,
	}, Context)

	self._rayParams.FilterType = Enum.RaycastFilterType.Include
	self._rayParams.FilterDescendantsInstances = { Workspace.Terrain }
	self._rayParams.IgnoreWater = true

	-- Objectives folder: ObjectiveService finds workspace.Map.Objectives.<id>.Flag
	local objectives = parent:FindFirstChild("Objectives")
	if not objectives then
		objectives = Instance.new("Folder")
		objectives.Name = "Objectives"
		objectives.Parent = parent
	end
	self.objectives = objectives :: Folder
	return self
end

---------------------------------------------------------------------------------------------------
-- Randomness helpers (all deterministic through ctx.rng)
---------------------------------------------------------------------------------------------------

function Context:Range(a: number, b: number): number
	return self.rng:NextNumber(a, b)
end

function Context:Int(a: number, b: number): number
	return self.rng:NextInteger(a, b)
end

function Context:Chance(p: number): boolean
	return self.rng:NextNumber() < p
end

function Context:Pick<T>(list: { T }): T
	return list[self.rng:NextInteger(1, #list)]
end

-- Returns a slightly varied copy of `color` (value and saturation wobble). amount ~0.02..0.15
function Context:Jitter(color: Color3, amount: number?): Color3
	local a = amount or 0.05
	if a <= 0 then
		return color
	end
	local h, s, v = color:ToHSV()
	h = (h + self.rng:NextNumber(-a, a) * 0.08) % 1
	s = math.clamp(s * (1 + self.rng:NextNumber(-a, a) * 1.5), 0, 1)
	v = math.clamp(v * (1 + self.rng:NextNumber(-a, a) * 2), 0, 1)
	return Color3.fromHSV(h, s, v)
end

---------------------------------------------------------------------------------------------------
-- Hierarchy helpers
---------------------------------------------------------------------------------------------------

-- Returns (creating once) a Folder named `name` directly under the map root (or `parent`).
function Context:Folder(name: string, parent: Instance?): Folder
	local p = parent or self.root
	if p == self.root then
		local cached = self._folders[name]
		if cached and cached.Parent then
			return cached
		end
	end
	local f = p:FindFirstChild(name)
	if not (f and f:IsA("Folder")) then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = p
	end
	if p == self.root then
		self._folders[name] = f :: Folder
	end
	return f :: Folder
end

function Context:Model(name: string, parent: Instance?): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent or self.root
	return m
end

---------------------------------------------------------------------------------------------------
-- Cooperative yielding
---------------------------------------------------------------------------------------------------

-- Counts `units` of work and yields (task.wait) once the budget is exceeded.
function Context:Step(units: number?)
	self._sinceYield += units or 1
	if self._sinceYield >= self.yieldEvery then
		self._sinceYield = 0
		task.wait()
	end
end

function Context:Yield()
	self._sinceYield = 0
	task.wait()
end

---------------------------------------------------------------------------------------------------
-- Part factory
---------------------------------------------------------------------------------------------------

local SHAPE_CLASS = {
	Wedge = "WedgePart",
	CornerWedge = "CornerWedgePart",
	Truss = "TrussPart",
}

function Context:Part(spec: PartSpec): BasePart
	local className = SHAPE_CLASS[spec.Shape or "Block"] or "Part"
	local part = Instance.new(className) :: any
	if className == "Part" then
		if spec.Shape == "Ball" then
			part.Shape = Enum.PartType.Ball
		elseif spec.Shape == "Cylinder" then
			part.Shape = Enum.PartType.Cylinder
		end
	end
	part.Name = spec.Name or "Part"
	part.Anchored = true
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Size = spec.Size
	part.CFrame = spec.CFrame
	if className ~= "TrussPart" then
		part.Material = spec.Material or Enum.Material.SmoothPlastic
		local color = spec.Color or Color3.fromRGB(150, 150, 150)
		part.Color = self:Jitter(color, spec.Jitter == nil and 0.05 or spec.Jitter)
	else
		part.Color = spec.Color or Color3.fromRGB(90, 70, 50)
	end
	if spec.Transparency then
		part.Transparency = spec.Transparency
	end
	if spec.Reflectance then
		part.Reflectance = spec.Reflectance
	end
	if spec.CanCollide == false then
		part.CanCollide = false
	end
	if spec.CanQuery == false then
		part.CanQuery = false
	end
	if spec.CastShadow ~= nil then
		part.CastShadow = spec.CastShadow
	else
		local s = spec.Size
		part.CastShadow = s.X * s.Y * s.Z > 60
	end
	if spec.Mesh == "Sphere" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	end
	if spec.Destructible then
		CollectionService:AddTag(part, Core.TAG_DESTRUCTIBLE)
		if spec.Health then
			part:SetAttribute("Health", spec.Health)
		end
	end
	if spec.NoPenetration then
		CollectionService:AddTag(part, Core.TAG_NO_PEN)
	end
	if spec.Tags then
		for _, t in spec.Tags do
			CollectionService:AddTag(part, t)
		end
	end
	part.Parent = spec.Parent or self.root
	self.partCount += 1
	self:Step(1)
	return part
end

function Context:Tag(inst: Instance, tag: string)
	CollectionService:AddTag(inst, tag)
end

---------------------------------------------------------------------------------------------------
-- Geometry helpers
---------------------------------------------------------------------------------------------------

--[[
	CFrame for a WedgePart whose slope RISES toward `riseDir` (horizontal unit vector, world space).
	Roblox wedges are tallest at their back (+Z) face, so the part looks opposite to riseDir.
	Size passed with the wedge should be (width across, rise height, run length).
]]
function Core.WedgeCF(center: Vector3, riseDir: Vector3): CFrame
	local d = Vector3.new(riseDir.X, 0, riseDir.Z)
	if d.Magnitude < 1e-4 then
		d = Vector3.zAxis
	end
	return CFrame.lookAt(center, center - d.Unit)
end

-- CFrame whose -Z axis (LookVector) runs from a to b, positioned at the midpoint, Y up-ish.
function Core.Between(a: Vector3, b: Vector3): (CFrame, number)
	local mid = (a + b) / 2
	local len = (b - a).Magnitude
	if len < 1e-4 then
		return CFrame.new(mid), 0
	end
	local dir = (b - a) / len
	local up = if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(mid, b, up), len
end

-- Yaw (degrees) of a CFrame around Y, consistent with CFrame.Angles(0, math.rad(yaw), 0).
function Core.Yaw(cf: CFrame): number
	local look = cf.LookVector
	return math.deg(math.atan2(-look.X, -look.Z))
end

-- CFrame at (x, y, z) rotated `yawDeg` about Y.
function Core.At(x: number, y: number, z: number, yawDeg: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0)
end

---------------------------------------------------------------------------------------------------
-- Ground queries
---------------------------------------------------------------------------------------------------

-- Analytic ground height from the HeightModel used to generate the terrain (ignores later carving).
-- Falls back to a terrain raycast when no HeightModel was registered.
function Context:GroundY(x: number, z: number): number
	local hm = self.heightModel
	if hm then
		return hm:Get(x, z)
	end
	return self:SurfaceY(x, z)
end

-- Actual Terrain surface (raycast, includes craters/trenches/mounds, ignores water and parts).
function Context:SurfaceY(x: number, z: number, fromY: number?): number
	local top = fromY or 600
	local hit = Workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -(top + 600), 0), self._rayParams)
	if hit then
		return hit.Position.Y
	end
	local hm = self.heightModel
	return if hm then hm:Get(x, z) else 0
end

-- Ground-snapped CFrame facing yaw (degrees). `useSurface` raycasts the real terrain.
function Context:GroundCF(x: number, z: number, yawDeg: number?, useSurface: boolean?): CFrame
	local y = if useSurface then self:SurfaceY(x, z) else self:GroundY(x, z)
	return Core.At(x, y, z, yawDeg)
end

-- Lowest ground height under a rotated rectangle footprint (corners + centre).
function Context:FootprintMinY(cf: CFrame, sx: number, sz: number): (number, number)
	local lo, hi = math.huge, -math.huge
	for _, o in { { 0, 0 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 }, { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
		local p = cf * Vector3.new(o[1] * sx / 2, 0, o[2] * sz / 2)
		local y = self:GroundY(p.X, p.Z)
		lo = math.min(lo, y)
		hi = math.max(hi, y)
	end
	return lo, hi
end

---------------------------------------------------------------------------------------------------
-- Minimap
---------------------------------------------------------------------------------------------------

--[[
	Adds a minimap shape. kind: "building" | "road" | "water" | "trench" | "forest" | "field"
	(cx, cz) centre, (sx, sz) size in studs before rotation, rot = yaw in degrees
	(same convention as CFrame.Angles(0, math.rad(rot), 0)).
]]
function Context:AddMinimap(kind: string, cx: number, cz: number, sx: number, sz: number, rot: number?)
	table.insert(self.minimap, {
		kind = kind,
		cx = math.floor(cx * 10 + 0.5) / 10,
		cz = math.floor(cz * 10 + 0.5) / 10,
		sx = math.floor(sx * 10 + 0.5) / 10,
		sz = math.floor(sz * 10 + 0.5) / 10,
		rot = math.floor((rot or 0) * 10 + 0.5) / 10,
	})
end

function Context:AddMinimapCF(kind: string, cf: CFrame, sx: number, sz: number)
	self:AddMinimap(kind, cf.Position.X, cf.Position.Z, sx, sz, Core.Yaw(cf))
end

-- Adds one rectangle per polyline segment (roads, rivers, trenches).
function Context:AddMinimapPath(kind: string, points: { Vector3 }, width: number)
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local flatA, flatB = Vector3.new(a.X, 0, a.Z), Vector3.new(b.X, 0, b.Z)
		local len = (flatB - flatA).Magnitude
		if len > 0.5 then
			local cf = CFrame.lookAt((flatA + flatB) / 2, flatB)
			self:AddMinimap(kind, cf.Position.X, cf.Position.Z, width, len + width * 0.5, Core.Yaw(cf))
		end
	end
end

function Context:Stats(label: string?)
	print(`[MapKit] {label or "map"}: {self.partCount} parts, {#self.minimap} minimap shapes`)
end

return Core
