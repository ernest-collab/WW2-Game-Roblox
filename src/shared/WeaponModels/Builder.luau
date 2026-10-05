--[[
	Builder: small helper used by the WeaponModels archetype modules to assemble a weapon from
	Parts in "handle space".

	Conventions (see docs/ARCHITECTURE.md §7):
	  * The Handle sits at the origin with an identity rotation while building.
	  * -Z is the barrel direction (Handle.CFrame.LookVector), +Y up, +X to the right.
	  * Every part is welded to the Handle with a `Weld` whose C0 is the part's handle-space CFrame,
	    so animated sub-parts (Mag, Bolt, Slide, Pump, Lid) can be moved by editing their Weld.C0.
	    Parts can instead be welded to another part (`weldTo`) so they follow it (e.g. a bolt knob).
	  * All parts: Anchored=false, CanCollide/CanQuery/CanTouch=false, Massless, CastShadow off for
	    small detail parts.

	Each archetype builder receives a Builder and a resolved params table:
	  { id, archetype, variant, magazine, length, scale, wood, metal, dark, accent, scope, bayonet }
]]

local Builder = {}
Builder.__index = Builder

export type Params = {
	id: string,
	archetype: string,
	variant: string,
	magazine: string,
	length: number,
	scale: number, -- length / archetype default length
	wood: Color3,
	metal: Color3,
	dark: Color3,
	accent: Color3,
	scope: boolean,
	bayonet: boolean,
}

export type Builder = typeof(setmetatable(
	{} :: {
		model: Model,
		handle: Part,
		p: Params,
		count: number,
	},
	Builder
))

local CYL_ROT = CFrame.Angles(0, math.pi / 2, 0) -- cylinder X axis -> Z axis
local CYL_ROT_Y = CFrame.Angles(0, 0, math.pi / 2) -- cylinder X axis -> Y axis
local CYL_ROT_X = CFrame.identity

Builder.Mat = {
	Wood = Enum.Material.Wood,
	Metal = Enum.Material.Metal,
	Dark = Enum.Material.SmoothPlastic,
	Fabric = Enum.Material.Fabric,
	Plastic = Enum.Material.SmoothPlastic,
	Leather = Enum.Material.Leather,
}

function Builder.new(name: string, params: Params): Builder
	local model = Instance.new("Model")
	model.Name = name

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.12, 0.12, 0.12)
	handle.Transparency = 1
	handle.CFrame = CFrame.identity
	handle.Anchored = false
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.CastShadow = false
	handle.Parent = model
	model.PrimaryPart = handle

	return setmetatable({ model = model, handle = handle, p = params, count = 0 }, Builder)
end

-- Generic part creator. `cf` is handle-space (or world-space while building, identical).
function Builder.part(
	self: Builder,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?,
	weldTo: BasePart?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	if shape then
		part.Shape = shape
	end
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = size.Magnitude > 0.6
	part.CFrame = cf

	local root: BasePart = weldTo or self.handle
	local weld = Instance.new("Weld")
	weld.Name = "Weld"
	weld.Part0 = root
	weld.Part1 = part
	weld.C0 = root.CFrame:ToObjectSpace(cf)
	weld.Parent = part

	part.Parent = self.model
	self.count += 1
	return part
end

function Builder.box(
	self: Builder,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	weldTo: BasePart?
): Part
	return self:part(name, size, cf, color, material, nil, weldTo)
end

-- Wedge: slope faces +Z/-Y by default (Roblox wedge). Rotate `cf` to orient.
function Builder.wedge(
	self: Builder,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	weldTo: BasePart?
): Part
	return self:part(name, size, cf, color, material, Enum.PartType.Wedge, weldTo)
end

-- Cylinder whose axis runs along handle Z. `cf` is the centre (rotation applied on top).
function Builder.cylZ(
	self: Builder,
	name: string,
	length: number,
	diameter: number,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	weldTo: BasePart?
): Part
	return self:part(
		name,
		Vector3.new(length, diameter, diameter),
		cf * CYL_ROT,
		color,
		material,
		Enum.PartType.Cylinder,
		weldTo
	)
end

-- Cylinder whose axis runs along handle Y (vertical: drums, pans, grenade bodies).
function Builder.cylY(
	self: Builder,
	name: string,
	length: number,
	diameter: number,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	weldTo: BasePart?
): Part
	return self:part(
		name,
		Vector3.new(length, diameter, diameter),
		cf * CYL_ROT_Y,
		color,
		material,
		Enum.PartType.Cylinder,
		weldTo
	)
end

-- Cylinder whose axis runs along handle X (sideways: bolt knobs, binocular hinges).
function Builder.cylX(
	self: Builder,
	name: string,
	length: number,
	diameter: number,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	weldTo: BasePart?
): Part
	return self:part(
		name,
		Vector3.new(length, diameter, diameter),
		cf * CYL_ROT_X,
		color,
		material,
		Enum.PartType.Cylinder,
		weldTo
	)
end

function Builder.ball(
	self: Builder,
	name: string,
	diameter: number,
	cf: CFrame,
	color: Color3,
	material: Enum.Material?,
	weldTo: BasePart?
): Part
	return self:part(name, Vector3.one * diameter, cf, color, material, Enum.PartType.Ball, weldTo)
end

function Builder.attach(self: Builder, name: string, cf: CFrame): Attachment
	local existing = self.handle:FindFirstChild(name)
	if existing and existing:IsA("Attachment") then
		existing.CFrame = cf
		return existing
	end
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = cf
	a.Parent = self.handle
	return a
end

-- Sets the standard attachments in one call. Positions are handle-space Vector3s.
-- Sight looks down -Z (barrel direction).
function Builder.standard(
	self: Builder,
	muzzle: Vector3,
	grip: Vector3,
	support: Vector3,
	sight: Vector3,
	eject: Vector3?
)
	self:attach("Muzzle", CFrame.new(muzzle))
	self:attach("Grip", CFrame.new(grip))
	self:attach("Support", CFrame.new(support))
	self:attach("Sight", CFrame.new(sight))
	self:attach("Eject", CFrame.new(eject or Vector3.new(0.1, 0.08, -0.05)) * CFrame.Angles(0, -math.pi / 2, 0))
end

--[[
	Presentation metadata read by the ViewmodelController / CharacterAnimController:
	  Hold       "Rifle" | "Pistol" | "MG" | "Launcher" | "Throwable" | "Melee" | "Gadget" | "Binoculars"
	  EyeRelief  studs between the eye and the Sight attachment when aiming
	  MagOut     handle-space direction the magazine leaves the gun during a reload
	  Action     "bolt" | "slide" | "pump" | "none" (how PlayBolt / empty-reload charging looks)
]]
function Builder.meta(self: Builder, hold: string, eyeRelief: number, magOut: Vector3?, action: string?)
	self.model:SetAttribute("Hold", hold)
	self.model:SetAttribute("EyeRelief", eyeRelief)
	self.model:SetAttribute("MagOut", magOut or Vector3.new(0, -1, 0))
	self.model:SetAttribute("Action", action or "slide")
end

function Builder.finish(self: Builder): Model
	local m = self.model
	m:SetAttribute("WeaponId", self.p.id)
	m:SetAttribute("Archetype", self.p.archetype)
	m:SetAttribute("Variant", self.p.variant)
	m:SetAttribute("PartCount", self.count)
	if m:GetAttribute("Hold") == nil then
		self:meta("Rifle", 0.7)
	end
	-- Guarantee the contract attachments exist even if a builder forgot one.
	for _, name in { "Muzzle", "Grip", "Support", "Sight", "Eject" } do
		if not self.handle:FindFirstChild(name) then
			self:attach(name, CFrame.identity)
		end
	end
	return m
end

-- Colour helpers -------------------------------------------------------------------------------

function Builder.shade(c: Color3, k: number): Color3
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

return Builder
