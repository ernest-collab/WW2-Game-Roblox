--[[
	Kit: tiny part factory used by the procedural vehicle builders.

	Vehicles are built around the origin: the Chassis sits at CFrame.identity facing -Z, so every
	CFrame passed to the kit is simultaneously "model space" and "world space". Every part is
	welded (Weld with explicit C0) to `kit.base` (Chassis by default; builders temporarily switch
	the base to Turret / Gun so those parts follow the Motor6D-driven pivots).

	Defaults: Anchored=false, Massless=true, CanCollide=false, CanTouch=false, CanQuery=true,
	CollisionGroup "Vehicles". Shapes: Cylinder axis is the part's local X axis.
]]

local Kit = {}
Kit.__index = Kit

export type Palette = {
	base: Color3,
	dark: Color3,
	patches: { Color3 },
	track: Color3,
	wheel: Color3,
	metal: Color3,
	rubber: Color3,
	wood: Color3,
	canvas: Color3,
	glass: Color3,
	seat: Color3,
	insignia: string,
}

export type PartOpts = {
	material: Enum.Material?,
	collide: boolean?,
	query: boolean?,
	transparency: number?,
	noWeld: boolean?,
	base: BasePart?,
	shadow: boolean?,
	reflectance: number?,
}

export type Kit = typeof(setmetatable(
	{} :: {
		model: Model,
		palette: Palette,
		base: BasePart,
		count: number,
		collisionGroup: string,
	},
	Kit
))

-- Commonly used rotations.
Kit.VERTICAL = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis X -> Y
Kit.ALONG_Z = CFrame.Angles(0, math.pi / 2, 0) -- cylinder axis X -> Z
Kit.FLIP_DOWN = CFrame.Angles(0, 0, math.pi) -- wedge slope faces forward-down
Kit.FACE_BACK = CFrame.Angles(0, math.pi, 0) -- wedge slope faces backward-up
Kit.FACE_RIGHT = CFrame.Angles(0, -math.pi / 2, 0) -- wedge slope faces +X (size.X runs along Z)
Kit.FACE_LEFT = CFrame.Angles(0, math.pi / 2, 0) -- wedge slope faces -X

function Kit.new(model: Model, palette: Palette, collisionGroup: string): Kit
	local self = setmetatable({
		model = model,
		palette = palette,
		base = nil :: any,
		count = 0,
		collisionGroup = collisionGroup,
	}, Kit)
	return self
end

function Kit:weld(part: BasePart, base: BasePart)
	local w = Instance.new("Weld")
	w.Name = "Weld"
	w.Part0 = base
	w.Part1 = part
	w.C0 = base.CFrame:Inverse() * part.CFrame
	w.C1 = CFrame.identity
	w.Parent = part
end

-- Motor6D whose pivot is part1's current centre; Transform rotates part1 about that point.
function Kit:motor(name: string, part0: BasePart, part1: BasePart): Motor6D
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = part0
	m.Part1 = part1
	m.C0 = part0.CFrame:Inverse() * part1.CFrame
	m.C1 = CFrame.identity
	m.Parent = part1
	return m
end

local SHADOW_MIN_VOLUME = 0.5 -- studs^3

local function apply(self: Kit, p: BasePart, name: string, size: Vector3, cf: CFrame, color: Color3, opts: PartOpts?)
	local o: PartOpts = opts or {}
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = o.material or Enum.Material.Metal
	p.Anchored = false
	p.Massless = true
	p.CanCollide = o.collide == true
	p.CanTouch = false
	p.CanQuery = o.query ~= false
	-- Tiny details (bolts, handles, hinges, periscopes) cast sub-texel shadows: skip them unless a
	-- builder explicitly asks (saves shadow-map draw calls per vehicle).
	p.CastShadow = o.shadow == true or (o.shadow == nil and size.X * size.Y * size.Z >= SHADOW_MIN_VOLUME)
	p.Transparency = o.transparency or 0
	p.Reflectance = o.reflectance or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CollisionGroup = self.collisionGroup
	p.Parent = self.model
	if not o.noWeld then
		self:weld(p, o.base or self.base)
	end
	self.count += 1
	return p
end

function Kit:box(name: string, size: Vector3, cf: CFrame, color: Color3, opts: PartOpts?): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Block
	return apply(self, p, name, size, cf, color, opts) :: Part
end

function Kit:wedge(name: string, size: Vector3, cf: CFrame, color: Color3, opts: PartOpts?): WedgePart
	local p = Instance.new("WedgePart")
	return apply(self, p, name, size, cf, color, opts) :: WedgePart
end

-- Cylinder: `length` along the CFrame's X axis.
function Kit:cyl(name: string, length: number, diameter: number, cf: CFrame, color: Color3, opts: PartOpts?): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Cylinder
	return apply(self, p, name, Vector3.new(length, diameter, diameter), cf, color, opts) :: Part
end

function Kit:ball(name: string, diameter: number, cf: CFrame, color: Color3, opts: PartOpts?): Part
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	return apply(self, p, name, Vector3.new(diameter, diameter, diameter), cf, color, opts) :: Part
end

-- Box stretched between two points (cross-section width along world X when the beam is not vertical).
function Kit:beam(
	name: string,
	a: Vector3,
	b: Vector3,
	width: number,
	thick: number,
	color: Color3,
	opts: PartOpts?
): Part
	local mid = (a + b) * 0.5
	local len = (b - a).Magnitude
	local cf = CFrame.lookAt(mid, b)
	return self:box(name, Vector3.new(width, thick, len), cf, color, opts)
end

function Kit:attachment(name: string, parent: BasePart, worldCf: CFrame): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = parent.CFrame:Inverse() * worldCf
	a.Parent = parent
	return a
end

-- Seat (Seat instance, never a VehicleSeat: VehicleController owns the input).
-- CanTouch=false so nobody can sit by walking into it; VehicleService seats players with Seat:Sit().
function Kit:seat(name: string, cf: CFrame, visible: boolean, base: BasePart?): Seat
	local s = Instance.new("Seat")
	s.Name = name
	s.Size = Vector3.new(1.6, 0.35, 1.6)
	s.CFrame = cf
	s.Color = self.palette.seat
	s.Material = Enum.Material.Fabric
	s.Transparency = if visible then 0 else 1
	s.Anchored = false
	s.Massless = true
	s.CanCollide = false
	s.CanTouch = false
	s.CanQuery = false
	s.CastShadow = visible
	s.TopSurface = Enum.SurfaceType.Smooth
	s.BottomSurface = Enum.SurfaceType.Smooth
	s.CollisionGroup = self.collisionGroup
	s.Parent = self.model
	self:weld(s, base or self.base)
	self.count += 1
	return s
end

return Kit
