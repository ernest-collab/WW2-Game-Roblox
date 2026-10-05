--[[
	MapKit.Terrain — smooth-voxel ground generation and terrain sculpting.

	Workflow (see docs/MAPKIT.md):
	  1. Describe the landscape analytically:
	       local hm = Terrain.HeightModel({ baseY = 0, seed = 7 })
	       hm:Noise(8, 260, 3)                          -- rolling ground
	       hm:Hill(300, -200, 180, 30)                   -- a hill
	       hm:River(points, { width = 34, bank = 22, bedY = -9, waterY = -4 })
	       hm:FlattenRect(0, 0, 220, 220, 0, nil, 40)    -- village plateau
	       hm:Road(roadPoints, 18, 10)                   -- level the road cross-section
	       local mm = Terrain.MaterialModel({ base = Enum.Material.Grass })
	       mm:Patches(Enum.Material.LeafyGrass, 90, 0.1)
	       mm:Path(roadPoints, 14, Enum.Material.Ground, 2)
	  2. Write it into workspace.Terrain in chunks (yields between chunks):
	       Terrain.Generate(ctx, hm, mm, { center = Vector3.zero, size = Vector2.new(1600, 1600) })
	     This also registers `hm` on the context so ctx:GroundY(x, z) is analytic and fast.
	  3. Post-process: Terrain.Crater, Terrain.Mound/RubbleMound, Terrain.Berm, Terrain.Carve...

	Coordinates: all functions use world studs. Paths are lists of Vector3 (Y ignored) or Vector2.
]]

local Workspace = game:GetService("Workspace")

local Geo = require(script.Parent.Geo)

local Terrain = {}

local M = Enum.Material
local VOXEL = 4

-- Surface materials a crater/scorch will repaint.
local NATURAL_SURFACES =
	{ M.Grass, M.LeafyGrass, M.Ground, M.Sand, M.Snow, M.Mud, M.Pavement, M.Asphalt, M.Concrete, M.Slate }

---------------------------------------------------------------------------------------------------
-- HeightModel: ordered list of height operations evaluated per (x, z)
---------------------------------------------------------------------------------------------------

type Op = {
	fn: (x: number, z: number, h: number) -> number,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

type Water = {
	test: (x: number, z: number) -> boolean,
	level: number,
	frozen: boolean,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

local HeightModel = {}
HeightModel.__index = HeightModel

export type HeightModel = typeof(setmetatable(
	{} :: { baseY: number, seed: number, ops: { Op }, water: { Water }, seaLevel: number? },
	HeightModel
))

function Terrain.HeightModel(opts: { baseY: number?, seed: number? }?): HeightModel
	local o = opts or {}
	return setmetatable({ baseY = o.baseY or 0, seed = o.seed or 1, ops = {}, water = {}, seaLevel = nil }, HeightModel)
end

local INF = math.huge

function HeightModel:_add(fn, minX, maxX, minZ, maxZ)
	table.insert(self.ops, { fn = fn, minX = minX or -INF, maxX = maxX or INF, minZ = minZ or -INF, maxZ = maxZ or INF })
end

-- Evaluate the first `count` operations (used by ops that need the terrain "so far").
function HeightModel:_evalUpTo(count: number, x: number, z: number): number
	local h = self.baseY
	local ops = self.ops
	for i = 1, count do
		local op = ops[i]
		if x >= op.minX and x <= op.maxX and z >= op.minZ and z <= op.maxZ then
			h = op.fn(x, z, h)
		end
	end
	return h
end

-- Ground height at (x, z).
function HeightModel:Get(x: number, z: number): number
	return self:_evalUpTo(#self.ops, x, z)
end

-- Water surface at (x, z) if any: returns level, frozen.
function HeightModel:WaterAt(x: number, z: number): (number?, boolean)
	for _, w in self.water do
		if x >= w.minX and x <= w.maxX and z >= w.minZ and z <= w.maxZ and w.test(x, z) then
			return w.level, w.frozen
		end
	end
	if self.seaLevel then
		return self.seaLevel, false
	end
	return nil, false
end

-- Fractal noise hills over the whole map. amplitude in studs (peak ~ +/- amplitude), scale = feature size.
function HeightModel:Noise(amplitude: number, scale: number, octaves: number?, seedOffset: number?)
	local seed = self.seed + (seedOffset or #self.ops)
	self:_add(function(x, z, h)
		return h + Geo.fbm(x, z, scale, octaves or 3, seed) * amplitude
	end)
	return self
end

-- Smooth radial bump (height > 0) or bowl (height < 0). sharpness > 1 = steeper sides.
function HeightModel:Hill(cx: number, cz: number, radius: number, height: number, sharpness: number?)
	local k = sharpness or 1
	self:_add(function(x, z, h)
		local d = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2) / radius
		if d >= 1 then
			return h
		end
		local f = (math.cos(d * math.pi) + 1) / 2
		return h + height * f ^ k
	end, cx - radius, cx + radius, cz - radius, cz + radius)
	return self
end

-- Elongated hill/ridge following a path. Profile falls off smoothly over `width / 2`.
function HeightModel:Ridge(points: { any }, width: number, height: number)
	local p = Geo.path(points)
	local r = width / 2
	self:_add(function(x, z, h)
		local d = Geo.distToPath(p, x, z)
		if d >= r then
			return h
		end
		return h + height * (math.cos(d / r * math.pi) + 1) / 2
	end, p.minX - r, p.maxX + r, p.minZ - r, p.maxZ + r)
	return self
end

--[[
	Channel carved along a path, RELATIVE to the current terrain (gullies, anti-tank ditches, sunken lanes).
	opts.shape "U" (flat floor, default) or "V" (ditch). bank = width of the sloped side.
]]
function HeightModel:Channel(points: { any }, width: number, depth: number, bank: number?, shape: string?)
	local p = Geo.path(points)
	local half = width / 2
	local b = bank or width / 2
	local reach = half + b
	local isV = shape == "V"
	self:_add(function(x, z, h)
		local d = Geo.distToPath(p, x, z)
		if d >= reach then
			return h
		end
		local f
		if isV then
			f = 1 - Geo.smoothstep(0, reach, d)
		else
			f = 1 - Geo.smoothstep(half, reach, d)
		end
		return h - depth * f
	end, p.minX - reach, p.maxX + reach, p.minZ - reach, p.maxZ + reach)
	return self
end

--[[
	River: carves a channel down to an ABSOLUTE bed level and registers a water surface.
	opts = { width = 30, bank = 20, bedY = baseY - 10, waterY = bedY + 5, frozen = false }
	Water fills where the carved ground is below waterY within width/2 + bank of the path.
]]
function HeightModel:River(points: { any }, opts: { [string]: any }?)
	local o = opts or {}
	local p = Geo.path(points)
	local half = (o.width or 30) / 2
	local bank = o.bank or 20
	local bedY = o.bedY or (self.baseY - 10)
	local waterY = o.waterY or (bedY + 5)
	local reach = half + bank
	self:_add(function(x, z, h)
		local d = Geo.distToPath(p, x, z)
		if d >= reach then
			return h
		end
		local t = Geo.smoothstep(half * 0.6, reach, d)
		return math.min(h, Geo.lerp(bedY, h, t))
	end, p.minX - reach, p.maxX + reach, p.minZ - reach, p.maxZ + reach)
	table.insert(self.water, {
		test = function(x, z)
			return (Geo.distToPath(p, x, z)) < reach
		end,
		level = waterY,
		frozen = o.frozen == true,
		minX = p.minX - reach,
		maxX = p.maxX + reach,
		minZ = p.minZ - reach,
		maxZ = p.maxZ + reach,
	})
	return self
end

-- Circular pond/lake: bowl to bedY with water at waterY.
function HeightModel:Pond(cx: number, cz: number, radius: number, bedY: number, waterY: number, frozen: boolean?)
	local reach = radius * 1.4
	self:_add(function(x, z, h)
		local d = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2)
		if d >= reach then
			return h
		end
		return math.min(h, Geo.lerp(bedY, h, Geo.smoothstep(radius * 0.5, reach, d)))
	end, cx - reach, cx + reach, cz - reach, cz + reach)
	table.insert(self.water, {
		test = function(x, z)
			return (x - cx) ^ 2 + (z - cz) ^ 2 < reach * reach
		end,
		level = waterY,
		frozen = frozen == true,
		minX = cx - reach,
		maxX = cx + reach,
		minZ = cz - reach,
		maxZ = cz + reach,
	})
	return self
end

-- Global sea: water wherever ground is below `level` (beach maps).
function HeightModel:Sea(level: number)
	self.seaLevel = level
	return self
end

-- Flatten a disc to height y (nil = current height at the centre), blending over `blend` studs.
function HeightModel:Flatten(cx: number, cz: number, radius: number, y: number?, blend: number?)
	local b = blend or 20
	local target = y or self:Get(cx, cz)
	local reach = radius + b
	self:_add(function(x, z, h)
		local d = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2)
		if d >= reach then
			return h
		end
		return Geo.lerp(target, h, Geo.smoothstep(radius, reach, d))
	end, cx - reach, cx + reach, cz - reach, cz + reach)
	return self
end

-- Flatten a rotated rectangle (rot = yaw degrees) to height y (nil = current centre height).
function HeightModel:FlattenRect(cx: number, cz: number, sx: number, sz: number, rot: number?, y: number?, blend: number?)
	local b = blend or 20
	local target = y or self:Get(cx, cz)
	local reach = math.sqrt(sx * sx + sz * sz) / 2 + b
	self:_add(function(x, z, h)
		local d = Geo.rectDist(x, z, cx, cz, sx, sz, rot)
		if d >= b then
			return h
		end
		return Geo.lerp(target, h, Geo.smoothstep(0, b, d))
	end, cx - reach, cx + reach, cz - reach, cz + reach)
	return self
end

--[[
	Road: levels the terrain across the road (no camber/tilt sideways) while following the
	terrain lengthwise. `width` = level strip, `blend` = shoulder.
]]
function HeightModel:Road(points: { any }, width: number, blend: number?)
	local p = Geo.path(points)
	local half = width / 2
	local reach = half + (blend or 10)
	local index = #self.ops
	self:_add(function(x, z, h)
		local d, px, pz = Geo.distToPath(p, x, z)
		if d >= reach then
			return h
		end
		local centre = self:_evalUpTo(index, px, pz)
		return Geo.lerp(centre, h, Geo.smoothstep(half, reach, d))
	end, p.minX - reach, p.maxX + reach, p.minZ - reach, p.maxZ + reach)
	return self
end

-- Raised embankment (railways, dykes): top `height` above the terrain at the path centre.
function HeightModel:Embankment(points: { any }, topWidth: number, height: number, slope: number?)
	local p = Geo.path(points)
	local half = topWidth / 2
	local reach = half + (slope or height * 2)
	local index = #self.ops
	self:_add(function(x, z, h)
		local d, px, pz = Geo.distToPath(p, x, z)
		if d >= reach then
			return h
		end
		local top = self:_evalUpTo(index, px, pz) + height
		local f = 1 - Geo.smoothstep(half, reach, d)
		return math.max(h, Geo.lerp(h, top, f))
	end, p.minX - reach, p.maxX + reach, p.minZ - reach, p.maxZ + reach)
	return self
end

-- Escape hatch: fn(x, z, h) -> newH, optionally limited to a bounding box {minX, maxX, minZ, maxZ}.
function HeightModel:Custom(fn: (number, number, number) -> number, box: { number }?)
	if box then
		self:_add(fn, box[1], box[2], box[3], box[4])
	else
		self:_add(fn)
	end
	return self
end

---------------------------------------------------------------------------------------------------
-- MaterialModel: ordered material rules; the LAST matching rule wins.
---------------------------------------------------------------------------------------------------

type Rule = {
	test: (x: number, z: number, y: number, slope: number) -> boolean,
	material: Enum.Material,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

local MaterialModel = {}
MaterialModel.__index = MaterialModel

export type MaterialModel = typeof(setmetatable(
	{} :: { base: Enum.Material, subsurface: Enum.Material, seed: number, rules: { Rule } },
	MaterialModel
))

--[[
	opts.base       surface material where no rule matches (default Grass)
	opts.subsurface material deeper than ~5 studs below the surface (default Ground) — exposed by trenches/craters
]]
function Terrain.MaterialModel(opts: { base: Enum.Material?, subsurface: Enum.Material?, seed: number? }?): MaterialModel
	local o = opts or {}
	return setmetatable({
		base = o.base or M.Grass,
		subsurface = o.subsurface or M.Ground,
		seed = o.seed or 3,
		rules = {},
	}, MaterialModel)
end

function MaterialModel:_add(material, test, minX, maxX, minZ, maxZ)
	table.insert(self.rules, {
		material = material,
		test = test,
		minX = minX or -INF,
		maxX = maxX or INF,
		minZ = minZ or -INF,
		maxZ = maxZ or INF,
	})
	return self
end

-- Organic noise patches: material where noise(scale) > threshold (-1..1; 0.3 = ~30% cover).
function MaterialModel:Patches(material: Enum.Material, scale: number, threshold: number, box: { number }?)
	local seed = self.seed + #self.rules * 3
	local b = box or {}
	return self:_add(material, function(x, z)
		return Geo.fbm(x, z, scale, 2, seed) > threshold
	end, b[1], b[2], b[3], b[4])
end

-- Rotated rectangle. `edge` adds noisy, natural borders of that many studs.
function MaterialModel:Rect(cx: number, cz: number, sx: number, sz: number, rot: number?, material: Enum.Material, edge: number?)
	local e = edge or 0
	local seed = self.seed + #self.rules
	local reach = math.sqrt(sx * sx + sz * sz) / 2 + e
	return self:_add(material, function(x, z)
		local d = Geo.rectDist(x, z, cx, cz, sx, sz, rot)
		if e > 0 then
			d += Geo.fbm(x, z, 12, 1, seed) * e
		end
		return d <= 0
	end, cx - reach, cx + reach, cz - reach, cz + reach)
end

function MaterialModel:Circle(cx: number, cz: number, radius: number, material: Enum.Material, edge: number?)
	local e = edge or 0
	local seed = self.seed + #self.rules
	local reach = radius + e
	return self:_add(material, function(x, z)
		local d = math.sqrt((x - cx) ^ 2 + (z - cz) ^ 2) - radius
		if e > 0 then
			d += Geo.fbm(x, z, 10, 1, seed) * e
		end
		return d <= 0
	end, cx - reach, cx + reach, cz - reach, cz + reach)
end

-- Strip along a path (roads, tracks, river banks). `edge` = ragged border amount.
function MaterialModel:Path(points: { any }, width: number, material: Enum.Material, edge: number?)
	local p = Geo.path(points)
	local e = edge or 0
	local half = width / 2
	local seed = self.seed + #self.rules
	local reach = half + e
	return self:_add(material, function(x, z)
		local d = Geo.distToPath(p, x, z)
		if e > 0 then
			d += Geo.fbm(x, z, 9, 1, seed) * e
		end
		return d <= half
	end, p.minX - reach, p.maxX + reach, p.minZ - reach, p.maxZ + reach)
end

-- Polygon area (list of points).
function MaterialModel:Polygon(points: { any }, material: Enum.Material)
	local p = Geo.path(points)
	return self:_add(material, function(x, z)
		return Geo.pointInPolygon(x, z, points)
	end, p.minX, p.maxX, p.minZ, p.maxZ)
end

-- Steep ground (slope = rise/run, 1.0 = 45 degrees).
function MaterialModel:Slope(material: Enum.Material, minSlope: number)
	return self:_add(material, function(_, _, _, slope)
		return slope >= minSlope
	end)
end

function MaterialModel:Below(y: number, material: Enum.Material)
	return self:_add(material, function(_, _, h)
		return h < y
	end)
end

function MaterialModel:Above(y: number, material: Enum.Material)
	return self:_add(material, function(_, _, h)
		return h > y
	end)
end

function MaterialModel:Custom(material: Enum.Material, test: (number, number, number, number) -> boolean, box: { number }?)
	local b = box or {}
	return self:_add(material, test, b[1], b[2], b[3], b[4])
end

function MaterialModel:Get(x: number, z: number, y: number, slope: number): Enum.Material
	local rules = self.rules
	for i = #rules, 1, -1 do
		local r = rules[i]
		if x >= r.minX and x <= r.maxX and z >= r.minZ and z <= r.maxZ and r.test(x, z, y, slope) then
			return r.material
		end
	end
	return self.base
end

---------------------------------------------------------------------------------------------------
-- Generation
---------------------------------------------------------------------------------------------------

--[[
	Terrain.Generate(ctx, hm, mm, opts)
	  opts.center     Vector3 (Y ignored), opts.size Vector2 (X, Z) — area to fill (make it larger
	                  than the playable bounds so the horizon is not a cliff)
	  opts.floorDepth studs of solid ground below the lowest surface point of each chunk (default 16)
	  opts.chunk      columns per chunk side (default 32 => 128 studs)
	Registers `hm` on the context (ctx.heightModel) so ctx:GroundY is analytic.
]]
function Terrain.Generate(ctx: any, hm: HeightModel, mm: MaterialModel, opts: { [string]: any })
	local terrain = Workspace.Terrain
	ctx.heightModel = hm
	local center: Vector3 = opts.center or Vector3.zero
	local size: Vector2 = opts.size
	local floorDepth = opts.floorDepth or 16
	local chunk = opts.chunk or 32
	local x0 = math.floor((center.X - size.X / 2) / VOXEL) * VOXEL
	local z0 = math.floor((center.Z - size.Y / 2) / VOXEL) * VOXEL
	local nxTotal = math.ceil(size.X / VOXEL)
	local nzTotal = math.ceil(size.Y / VOXEL)
	local subsurface = mm.subsurface

	for cxi = 0, nxTotal - 1, chunk do
		for czi = 0, nzTotal - 1, chunk do
			local nx = math.min(chunk, nxTotal - cxi)
			local nz = math.min(chunk, nzTotal - czi)
			local bx = x0 + cxi * VOXEL
			local bz = z0 + czi * VOXEL

			-- Heights at column centres, with a 1-column border for slopes.
			local H = table.create(nx + 2)
			local lo, hi = INF, -INF
			for i = 0, nx + 1 do
				local col = table.create(nz + 2)
				H[i] = col
				local wx = bx + (i - 0.5) * VOXEL
				for k = 0, nz + 1 do
					local h = hm:Get(wx, bz + (k - 0.5) * VOXEL)
					col[k] = h
					if i >= 1 and i <= nx and k >= 1 and k <= nz then
						lo = math.min(lo, h)
						hi = math.max(hi, h)
					end
				end
			end

			-- Water per column
			local Wl = table.create(nx)
			local Wf = table.create(nx)
			local waterHi = -INF
			for i = 1, nx do
				local wl, wf = {}, {}
				Wl[i], Wf[i] = wl, wf
				local wx = bx + (i - 0.5) * VOXEL
				for k = 1, nz do
					local level, frozen = hm:WaterAt(wx, bz + (k - 0.5) * VOXEL)
					if level and level > H[i][k] then
						wl[k] = level
						wf[k] = frozen
						waterHi = math.max(waterHi, level)
					end
				end
			end

			local y0 = math.floor((lo - floorDepth) / VOXEL) * VOXEL
			local y1 = math.ceil((math.max(hi, waterHi) + VOXEL) / VOXEL) * VOXEL
			local ny = (y1 - y0) / VOXEL

			local mats = table.create(nx)
			local occ = table.create(nx)
			for i = 1, nx do
				local mi, oi = table.create(ny), table.create(ny)
				mats[i], occ[i] = mi, oi
				for j = 1, ny do
					mi[j] = table.create(nz, M.Air)
					oi[j] = table.create(nz, 0)
				end
				local wx = bx + (i - 0.5) * VOXEL
				local Hi, Hm, Hp = H[i], H[i - 1], H[i + 1]
				for k = 1, nz do
					local h = Hi[k]
					local wz = bz + (k - 0.5) * VOXEL
					local slope = math.sqrt((Hp[k] - Hm[k]) ^ 2 + (Hi[k + 1] - Hi[k - 1]) ^ 2) / (2 * VOXEL)
					local surf = mm:Get(wx, wz, h, slope)
					local wlevel = Wl[i][k]
					local waterMat = if Wf[i][k] then M.Ice else M.Water
					for j = 1, ny do
						local yb = y0 + (j - 1) * VOXEL
						local o = (h - yb) / VOXEL
						if o >= 1 then
							mi[j][k] = if h - (yb + VOXEL) < 5 then surf else subsurface
							oi[j][k] = 1
						elseif o > 0.02 then
							mi[j][k] = surf
							oi[j][k] = o
						elseif wlevel and yb < wlevel then
							mi[j][k] = waterMat
							oi[j][k] = math.clamp((wlevel - yb) / VOXEL, 0.1, 1)
						else
							break
						end
					end
				end
			end

			local region = Region3.new(Vector3.new(bx, y0, bz), Vector3.new(bx + nx * VOXEL, y1, bz + nz * VOXEL))
			terrain:WriteVoxels(region, VOXEL, mats, occ)
			ctx:Yield()
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Palette (global terrain material colours). Maps call this once; it resets unspecified
-- materials to MapKit's muted WWII defaults so a previous map's palette never leaks.
---------------------------------------------------------------------------------------------------

Terrain.DEFAULT_COLORS = {
	Grass = Color3.fromRGB(96, 112, 62),
	LeafyGrass = Color3.fromRGB(88, 104, 58),
	Ground = Color3.fromRGB(94, 82, 62),
	Mud = Color3.fromRGB(70, 58, 46),
	Sand = Color3.fromRGB(170, 152, 116),
	Snow = Color3.fromRGB(214, 220, 226),
	Rock = Color3.fromRGB(104, 104, 100),
	Slate = Color3.fromRGB(88, 90, 88),
	Cobblestone = Color3.fromRGB(116, 110, 100),
	Pavement = Color3.fromRGB(124, 122, 116),
	Asphalt = Color3.fromRGB(74, 74, 72),
	Concrete = Color3.fromRGB(128, 126, 120),
	Brick = Color3.fromRGB(122, 78, 62),
	WoodPlanks = Color3.fromRGB(110, 86, 60),
	Basalt = Color3.fromRGB(56, 54, 52),
	Limestone = Color3.fromRGB(176, 168, 146),
	Sandstone = Color3.fromRGB(160, 130, 96),
	Ice = Color3.fromRGB(176, 196, 210),
	Glacier = Color3.fromRGB(190, 210, 222),
}

function Terrain.ApplyPalette(overrides: { [string]: Color3 }?, water: { [string]: any }?)
	local terrain = Workspace.Terrain
	for name, color in Terrain.DEFAULT_COLORS do
		local c = if overrides and overrides[name] then overrides[name] else color
		pcall(terrain.SetMaterialColor, terrain, (M :: any)[name], c)
	end
	local w = water or {}
	terrain.WaterColor = w.color or Color3.fromRGB(52, 70, 62)
	terrain.WaterTransparency = w.transparency or 0.6
	terrain.WaterReflectance = w.reflectance or 0.4
	terrain.WaterWaveSize = w.waveSize or 0.08
	terrain.WaterWaveSpeed = w.waveSpeed or 6
	if w.decoration ~= nil then
		pcall(function()
			(terrain :: any).Decoration = w.decoration
		end)
	end
end

---------------------------------------------------------------------------------------------------
-- Painting & sculpting tools (post-generation)
---------------------------------------------------------------------------------------------------

-- Repaint surface materials inside an oriented box.
function Terrain.Paint(cf: CFrame, size: Vector3, material: Enum.Material, from: { Enum.Material }?)
	local terrain = Workspace.Terrain
	for _, src in from or NATURAL_SURFACES do
		if src ~= material then
			terrain:ReplaceMaterialInTransform(cf, size, src, material)
		end
	end
end

-- Repaint along a path (oriented boxes per segment).
function Terrain.PaintPath(ctx: any, points: { any }, width: number, material: Enum.Material, from: { Enum.Material }?)
	for i = 1, #points - 1 do
		local ax, az = Geo.xz(points[i])
		local bx, bz = Geo.xz(points[i + 1])
		local a = Vector3.new(ax, ctx:GroundY(ax, az), az)
		local b = Vector3.new(bx, ctx:GroundY(bx, bz), bz)
		local flat = CFrame.lookAt(Vector3.new((ax + bx) / 2, (a.Y + b.Y) / 2, (az + bz) / 2), Vector3.new(bx, (a.Y + b.Y) / 2, bz))
		local len = Vector3.new(bx - ax, 0, bz - az).Magnitude
		Terrain.Paint(flat, Vector3.new(width, math.abs(a.Y - b.Y) + 16, len + width * 0.5), material, from)
		ctx:Step(2)
	end
end

-- Remove terrain inside an oriented box.
function Terrain.Carve(cf: CFrame, size: Vector3)
	Workspace.Terrain:FillBlock(cf, size, M.Air)
end

function Terrain.Fill(cf: CFrame, size: Vector3, material: Enum.Material)
	Workspace.Terrain:FillBlock(cf, size, material)
end

--[[
	Shell/bomb crater: bowl carved below ground with a raised, broken rim and scorched interior.
	pos may be Vector3 (Y ignored) — the bowl is centred on the terrain surface.
	opts = { depth = radius * 0.45, rim = true, scorch = true, material = Mud, rimMaterial = Ground, water = false }
]]
function Terrain.Crater(ctx: any, pos: Vector3, radius: number, opts: { [string]: any }?)
	local o = opts or {}
	local terrain = Workspace.Terrain
	local gy = ctx:SurfaceY(pos.X, pos.Z)
	local depth = o.depth or radius * 0.45
	-- Sphere of radius R whose cap below the ground has horizontal radius `radius` and depth `depth`
	local R = (radius * radius + depth * depth) / (2 * depth)
	local c = Vector3.new(pos.X, gy - depth + R, pos.Z)

	if o.rim ~= false then
		local n = math.max(6, math.floor(radius * 0.9))
		local rimMat = o.rimMaterial or M.Ground
		for i = 1, n do
			local a = (i / n) * math.pi * 2 + ctx:Range(-0.2, 0.2)
			local rr = radius * ctx:Range(0.95, 1.15)
			local br = radius * ctx:Range(0.22, 0.34)
			local px, pz = pos.X + math.cos(a) * rr, pos.Z + math.sin(a) * rr
			terrain:FillBall(Vector3.new(px, gy - br * 0.45, pz), br, rimMat)
		end
	end
	terrain:FillBall(c, R, M.Air)

	if o.scorch ~= false then
		local inner = o.material or M.Mud
		local outerMat = o.outerMaterial or M.Ground
		local h = depth + 8
		for _, yaw in { 0, 45 } do
			local rot = CFrame.new(pos.X, gy - depth / 2, pos.Z) * CFrame.Angles(0, math.rad(yaw), 0)
			Terrain.Paint(rot, Vector3.new(radius * 2.6, h, radius * 2.6), outerMat)
			Terrain.Paint(rot, Vector3.new(radius * 1.5, h, radius * 1.5), inner)
		end
	end
	if o.water then
		terrain:FillCylinder(CFrame.new(pos.X, gy - depth + depth * 0.25, pos.Z), depth * 0.5, radius * 0.5, M.Water)
	end
	ctx:Step(6)
end

-- Natural mound of `material` made of overlapping balls (heaps, spoil, earth on bunkers).
function Terrain.Mound(ctx: any, pos: Vector3, radius: number, height: number, material: Enum.Material?)
	local terrain = Workspace.Terrain
	local gy = ctx:SurfaceY(pos.X, pos.Z)
	local mat = material or M.Ground
	local n = math.max(3, math.floor(radius / 3))
	for _ = 1, n do
		local a = ctx:Range(0, math.pi * 2)
		local d = ctx:Range(0, radius * 0.55)
		local r = ctx:Range(radius * 0.35, radius * 0.6)
		local top = height * (1 - d / radius)
		terrain:FillBall(Vector3.new(pos.X + math.cos(a) * d, gy + top - r, pos.Z + math.sin(a) * d), r, mat)
	end
	ctx:Step(n)
end

-- Collapsed-building rubble heap mixing several materials (Brick/Concrete/Rock/Slate...).
function Terrain.RubbleMound(ctx: any, pos: Vector3, radius: number, height: number, materials: { Enum.Material }?)
	local terrain = Workspace.Terrain
	local mats = materials or { M.Brick, M.Concrete, M.Rock, M.Slate }
	local gy = ctx:SurfaceY(pos.X, pos.Z)
	local n = math.max(4, math.floor(radius / 2.2))
	for i = 1, n do
		local a = ctx:Range(0, math.pi * 2)
		local d = if i == 1 then 0 else ctx:Range(0, radius * 0.7)
		local r = ctx:Range(radius * 0.25, radius * 0.45)
		local top = height * (1 - (d / radius) ^ 1.5)
		terrain:FillBall(
			Vector3.new(pos.X + math.cos(a) * d, gy + top - r * 0.9, pos.Z + math.sin(a) * d),
			r,
			mats[ctx:Int(1, #mats)]
		)
	end
	ctx:Step(n)
end

--[[
	Earth berm/parapet along a path: a rounded ridge `height` tall and `width` wide.
	Used for HQ protection, gun pits and hedgerow banks.
]]
function Terrain.Berm(ctx: any, points: { any }, width: number, height: number, material: Enum.Material?)
	local terrain = Workspace.Terrain
	local mat = material or M.Ground
	local R = (width * width / 4 + height * height) / (2 * height)
	for i = 1, #points - 1 do
		local ax, az = Geo.xz(points[i])
		local bx, bz = Geo.xz(points[i + 1])
		local len = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
		local steps = math.max(1, math.ceil(len / 12))
		for s = 0, steps - 1 do
			local t0, t1 = s / steps, (s + 1) / steps
			local px0, pz0 = Geo.lerp(ax, bx, t0), Geo.lerp(az, bz, t0)
			local px1, pz1 = Geo.lerp(ax, bx, t1), Geo.lerp(az, bz, t1)
			local mx, mz = (px0 + px1) / 2, (pz0 + pz1) / 2
			local gy = ctx:GroundY(mx, mz)
			local centre = Vector3.new(mx, gy + height - R, mz)
			-- FillCylinder axis = CFrame UpVector, so tip the cylinder to lie along the segment.
			local dir = Vector3.new(px1 - px0, 0, pz1 - pz0)
			if dir.Magnitude > 0.01 then
				local cf = CFrame.lookAt(centre, centre + dir) * CFrame.Angles(math.pi / 2, 0, 0)
				terrain:FillCylinder(cf, len / steps + width * 0.3, R, mat)
			end
		end
		ctx:Step(steps)
	end
end

-- Carve a vertical-walled cut along a path (trenches use this; depth below analytic ground).
function Terrain.CarvePath(ctx: any, points: { any }, width: number, depth: number, pieceLength: number?)
	local terrain = Workspace.Terrain
	local piece = pieceLength or 6
	for i = 1, #points - 1 do
		local ax, az = Geo.xz(points[i])
		local bx, bz = Geo.xz(points[i + 1])
		local len = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
		local steps = math.max(1, math.ceil(len / piece))
		for s = 0, steps - 1 do
			local t = (s + 0.5) / steps
			local mx, mz = Geo.lerp(ax, bx, t), Geo.lerp(az, bz, t)
			local gy = ctx:GroundY(mx, mz)
			local cf = CFrame.lookAt(Vector3.new(mx, gy - depth + 10, mz), Vector3.new(bx, gy - depth + 10, bz))
			terrain:FillBlock(cf, Vector3.new(width, 20, len / steps + width), M.Air)
		end
		ctx:Step(steps)
	end
end

-- Water volume in an oriented box (fountains, ponds in craters, flooded cellars).
function Terrain.WaterBox(cf: CFrame, size: Vector3)
	Workspace.Terrain:FillBlock(cf, size, M.Water)
end

return Terrain
