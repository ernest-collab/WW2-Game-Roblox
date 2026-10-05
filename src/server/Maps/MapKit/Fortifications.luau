--[[
	MapKit.Fortifications — field works and defensive structures.

	All builders take (ctx, cf_or_points, opts) and snap to terrain unless opts.snap == false.
	`cf` LookVector = the direction the position FACES (toward the enemy).

	  Sandbags(ctx, cf, opts)           straight or curved sandbag wall (opts.arc degrees)
	  BarbedWire(ctx, points, opts)     knife-rest posts + wire strands + low invisible blocker
	  Hedgehog(ctx, pos, size)          Czech hedgehog anti-tank obstacle
	  DragonTooth(ctx, pos, size)       concrete tank-trap pyramid
	  TankTraps(ctx, points, opts)      line of hedgehogs / teeth
	  Bunker(ctx, cf, opts)             concrete pillbox with firing slits, sunk into the ground
	  LogBunker(ctx, cf, opts)          timber dugout with earth roof
	  MGNest(ctx, cf, opts)             sandbagged machine-gun pit with static MG prop
	  ATGun(ctx, cf, opts)              anti-tank gun (static prop) in a sandbag emplacement
	  Foxhole(ctx, pos, opts)           one/two-man hole with spoil rim
	  Barricade(ctx, cf, opts)          wooden or debris street barricade
	  Trench(ctx, points, opts)         dug trench with revetments, duckboards, fire steps, parapet
	  Watchtower(ctx, cf, opts)         wooden observation tower with ladder
]]

local Workspace = game:GetService("Workspace")

local Core = require(script.Parent.Core)
local Geo = require(script.Parent.Geo)
local Terrain = require(script.Parent.Terrain)
local Props = require(script.Parent.Props)

local M = Enum.Material
local rgb = Color3.fromRGB

local Fort = {}

local SAND = { rgb(150, 136, 104), rgb(138, 126, 96), rgb(160, 146, 112), rgb(128, 118, 92) }
local CONCRETE = rgb(126, 124, 116)
local STEEL = rgb(62, 58, 54)

local function place(ctx: any, at: any, opts: { [string]: any }?): CFrame
	local cf: CFrame = if typeof(at) == "Vector3" then CFrame.new(at) else at
	if opts and opts.snap == false then
		return cf
	end
	local p = cf.Position
	return CFrame.new(p.X, ctx:GroundY(p.X, p.Z), p.Z) * (cf - p)
end

local function folder(ctx: any, opts: { [string]: any }?): Instance
	return (opts and opts.parent) or ctx:Folder("Fortifications")
end

---------------------------------------------------------------------------------------------------
-- Sandbags
---------------------------------------------------------------------------------------------------

--[[
	Fort.Sandbags(ctx, cf, opts) -> Model
	cf = centre of the wall's base (front face toward LookVector). opts: length (10), courses (3),
	arc (0 = straight; e.g. 120 curls the ends back around the defender), parent, snap
]]
function Fort.Sandbags(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("Sandbags", folder(ctx, o))
	local length = o.length or 10
	local courses = o.courses or 3
	local arc = math.rad(o.arc or 0)
	local bagL, bagH, bagD = 2.8, 1.05, 1.7
	local n = math.max(1, math.floor(length / (bagL * 0.95)))
	local R = if arc > 0.01 then length / arc else nil
	for c = 0, courses - 1 do
		local shift = if c % 2 == 1 then 0.5 else 0
		local count = if c % 2 == 1 then n - 1 else n
		for i = 0, count - 1 do
			local t = ((i + 0.5 + shift) / n) - 0.5 -- -0.5..0.5 along the wall
			local lcf
			if R then
				local phi = t * arc
				lcf = CFrame.new(R * math.sin(phi), 0, R - R * math.cos(phi)) * CFrame.Angles(0, -phi, 0)
			else
				lcf = CFrame.new(t * length, 0, 0)
			end
			ctx:Part({
				Name = "Sandbag",
				Parent = model,
				Size = Vector3.new(bagL, bagH, bagD - c * 0.12),
				CFrame = base
					* lcf
					* CFrame.new(0, bagH * (c + 0.5) - 0.15, c * 0.08)
					* CFrame.Angles(ctx:Range(-0.04, 0.04), ctx:Range(-0.06, 0.06), ctx:Range(-0.03, 0.03)),
				Material = M.Fabric,
				Color = ctx:Pick(SAND),
				Jitter = 0.06,
				CastShadow = c == courses - 1,
				Destructible = true,
				Health = 400,
			})
		end
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Barbed wire & tank obstacles
---------------------------------------------------------------------------------------------------

--[[
	Fort.BarbedWire(ctx, points, opts) -> Model
	opts: spacing (8), height (2.6), blocker (true: invisible collision so players must jump/go around)
]]
function Fort.BarbedWire(ctx: any, points: { any }, opts: { [string]: any }?): Model
	local o = opts or {}
	local model = ctx:Model("BarbedWire", folder(ctx, o))
	local spacing = o.spacing or 8
	local h = o.height or 2.6
	local p = Geo.path(points)
	local n = math.max(1, math.floor(p.length / spacing))
	local wire = rgb(58, 50, 44)
	local prev: Vector3? = nil
	for i = 0, n do
		local x, z, dx, dz = Geo.sample(p, p.length * i / n)
		local y = ctx:GroundY(x, z)
		local here = Vector3.new(x, y, z)
		local yaw = math.atan2(-dx, -dz)
		-- knife rest: two crossed stakes
		for _, s in { -1, 1 } do
			ctx:Part({
				Name = "Stake",
				Parent = model,
				Size = Vector3.new(0.25, h * 1.5, 0.25),
				CFrame = CFrame.new(here)
					* CFrame.Angles(0, yaw, 0)
					* CFrame.new(0, h * 0.55, 0)
					* CFrame.Angles(s * 0.55, 0, 0),
				Material = M.Wood,
				Color = rgb(78, 62, 46),
				CastShadow = false,
				CanQuery = false,
			})
		end
		if prev then
			for _, hy in { h * 0.45, h * 0.95 } do
				local cf, len =
					Core.Between(prev + Vector3.new(0, hy, 0), here + Vector3.new(0, hy + ctx:Range(-0.2, 0.2), 0))
				ctx:Part({
					Name = "Wire",
					Parent = model,
					Size = Vector3.new(0.1, 0.1, len),
					CFrame = cf,
					Material = M.Metal,
					Color = wire,
					Jitter = 0,
					CanCollide = false,
					CanQuery = false,
					CastShadow = false,
				})
			end
			-- diagonal tangle
			local dcf, dlen = Core.Between(prev + Vector3.new(0, h, 0), here + Vector3.new(0, 0.3, 0))
			ctx:Part({
				Name = "Wire",
				Parent = model,
				Size = Vector3.new(0.1, 0.1, dlen),
				CFrame = dcf,
				Material = M.Metal,
				Color = wire,
				Jitter = 0,
				CanCollide = false,
				CanQuery = false,
				CastShadow = false,
			})
			if o.blocker ~= false then
				local bcf, blen = Core.Between(prev + Vector3.new(0, h / 2, 0), here + Vector3.new(0, h / 2, 0))
				ctx:Part({
					Name = "WireBlocker",
					Parent = model,
					Size = Vector3.new(1.6, h, blen),
					CFrame = bcf,
					Transparency = 1,
					CanQuery = false,
					CastShadow = false,
					Jitter = 0,
				})
			end
		end
		prev = here
	end
	return model
end

-- Czech hedgehog: three crossed steel beams.
function Fort.Hedgehog(ctx: any, pos: Vector3, size: number?, parent: Instance?): Model
	local s = size or 4.5
	local y = ctx:GroundY(pos.X, pos.Z)
	local model = ctx:Model("Hedgehog", parent or ctx:Folder("Fortifications"))
	local root = CFrame.new(pos.X, y + s * 0.42, pos.Z)
		* CFrame.Angles(0, ctx:Range(0, 6.28), 0)
		* CFrame.Angles(math.rad(35.26), 0, math.rad(45))
	for _, r in { CFrame.new(), CFrame.Angles(0, 0, math.pi / 2), CFrame.Angles(math.pi / 2, 0, 0) } do
		ctx:Part({
			Name = "Beam",
			Parent = model,
			Size = Vector3.new(0.7, s * 1.5, 0.7),
			CFrame = root * r,
			Material = M.CorrodedMetal,
			Color = STEEL,
			Jitter = 0.08,
			NoPenetration = true,
		})
	end
	return model
end

-- Concrete "dragon's tooth".
function Fort.DragonTooth(ctx: any, pos: Vector3, size: number?, parent: Instance?): Model
	local s = size or 3.5
	local y = ctx:GroundY(pos.X, pos.Z)
	local model = ctx:Model("DragonTooth", parent or ctx:Folder("Fortifications"))
	local base = CFrame.new(pos.X, y, pos.Z) * CFrame.Angles(0, ctx:Range(-0.2, 0.2), 0)
	ctx:Part({
		Name = "Tooth",
		Parent = model,
		Size = Vector3.new(s, s * 0.6, s),
		CFrame = base * CFrame.new(0, s * 0.2, 0),
		Material = M.Concrete,
		Color = CONCRETE,
		NoPenetration = true,
	})
	ctx:Part({
		Name = "ToothTop",
		Parent = model,
		Size = Vector3.new(s * 0.55, s * 0.6, s * 0.55),
		CFrame = base * CFrame.new(0, s * 0.75, 0) * CFrame.Angles(0, math.rad(45), 0),
		Material = M.Concrete,
		Color = CONCRETE,
		NoPenetration = true,
	})
	return model
end

-- Line of obstacles. opts: spacing (9), kind ("hedgehog" | "teeth" | "mixed"), rows (1)
function Fort.TankTraps(ctx: any, points: { any }, opts: { [string]: any }?): Model
	local o = opts or {}
	local model = ctx:Model("TankTraps", folder(ctx, o))
	local kind = o.kind or "hedgehog"
	local p = Geo.path(points)
	local spacing = o.spacing or 9
	for row = 0, (o.rows or 1) - 1 do
		local n = math.floor(p.length / spacing)
		for i = 0, n do
			local x, z, dx, dz = Geo.sample(p, i * spacing + (row % 2) * spacing / 2)
			local off = row * 6
			local pos = Vector3.new(x - dz * off + ctx:Range(-1, 1), 0, z + dx * off + ctx:Range(-1, 1))
			local k = if kind == "mixed" then (if ctx:Chance(0.5) then "hedgehog" else "teeth") else kind
			if k == "teeth" then
				Fort.DragonTooth(ctx, pos, nil, model)
			else
				Fort.Hedgehog(ctx, pos, nil, model)
			end
		end
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Bunkers
---------------------------------------------------------------------------------------------------

-- Plain concrete wall with openings (local helper; uses Buildings.Wall lazily to avoid cycles).
local function concreteWall(
	ctx: any,
	parent: Instance,
	cf: CFrame,
	len: number,
	h: number,
	openings: { any },
	t: number
)
	local Buildings = require(script.Parent.Buildings) :: any
	Buildings.Wall(ctx, parent, cf, len, h, {
		thickness = t,
		material = M.Concrete,
		color = CONCRETE,
		openings = openings,
		destructible = false,
		noPenetration = true,
		chunk = 20,
	})
end

--[[
	Fort.Bunker(ctx, cf, opts) -> Model — reinforced concrete pillbox.
	opts: width (16), depth (12), height (7.5), slits (3), sunk (2) studs below ground,
	      embank (true: earth heaped on sides/back), door ("back")
	Thick walls are tagged NoBulletPenetration and are NOT destructible.
]]
function Fort.Bunker(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base0 = place(ctx, at, o)
	local w, d, h = o.width or 16, o.depth or 12, o.height or 7.5
	local sunk = o.sunk or 2
	local t = 2
	local model = ctx:Model("Bunker", folder(ctx, o))
	local lo = select(1, ctx:FootprintMinY(base0, w, d))
	local base = CFrame.new(base0.Position.X, lo - sunk, base0.Position.Z) * (base0 - base0.Position)

	-- clear the interior and the entrance cut
	Terrain.Carve(base * CFrame.new(0, h / 2 + 0.5, 0), Vector3.new(w - 1, h, d - 1))
	Terrain.Carve(base * CFrame.new(0, h / 2 + 0.5, d / 2 + 5), Vector3.new(5, h, 10))
	ctx:Part({
		Name = "Floor",
		Parent = model,
		Size = Vector3.new(w, 1, d),
		CFrame = base * CFrame.new(0, -0.5, 0),
		Material = M.Concrete,
		Color = CONCRETE:Lerp(rgb(70, 70, 70), 0.3),
		NoPenetration = true,
	})
	local slits = o.slits or 3
	local walls = {
		{ "front", CFrame.new(0, 0, -d / 2 + t / 2), w },
		{ "back", CFrame.new(0, 0, d / 2 - t / 2) * CFrame.Angles(0, math.pi, 0), w },
		{ "left", CFrame.new(-w / 2 + t / 2, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), d - 2 * t },
		{ "right", CFrame.new(w / 2 - t / 2, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), d - 2 * t },
	}
	local slitY0 = sunk + 2.2
	for _, wd in walls do
		local name, lcf, len = wd[1], wd[2], wd[3]
		local openings = {}
		if name == "front" then
			for i = 1, slits do
				table.insert(
					openings,
					{ x = -len / 2 + len * (i - 0.5) / slits, w = 3.2, y0 = slitY0, y1 = slitY0 + 1.1 }
				)
			end
		elseif name == "back" then
			table.insert(openings, { x = 0, w = 3.6, y0 = 0, y1 = 6.5 })
		elseif o.sideSlits ~= false then
			table.insert(openings, { x = -len / 4, w = 2.2, y0 = slitY0, y1 = slitY0 + 1 })
		end
		concreteWall(ctx, model, base * lcf, len, h, openings, t)
	end
	ctx:Part({
		Name = "Roof",
		Parent = model,
		Size = Vector3.new(w + 2, 2.2, d + 2),
		CFrame = base * CFrame.new(0, h + 1.1, 0),
		Material = M.Concrete,
		Color = CONCRETE,
		NoPenetration = true,
	})
	-- Chamfered front lip over the slits
	ctx:Part({
		Name = "Visor",
		Parent = model,
		Size = Vector3.new(w + 2, 0.8, 2.2),
		CFrame = base * CFrame.new(0, slitY0 + 1.9, -d / 2 - 1.1),
		Material = M.Concrete,
		Color = CONCRETE,
		NoPenetration = true,
	})
	-- Embankment: earth on the sides and back, leaving the front and the entrance clear
	if o.embank ~= false then
		local function lp(x, z)
			local v = base * Vector3.new(x, 0, z)
			return Vector3.new(v.X, 0, v.Z)
		end
		Terrain.Berm(ctx, { lp(-w / 2 - 3, -d / 2 + 2), lp(-w / 2 - 3, d / 2 + 2) }, 10, h * 0.7, M.Ground)
		Terrain.Berm(ctx, { lp(w / 2 + 3, -d / 2 + 2), lp(w / 2 + 3, d / 2 + 2) }, 10, h * 0.7, M.Ground)
	end
	-- Interior: MG on a table by the centre slit, ammo
	Fort.MGProp(ctx, base * CFrame.new(0, slitY0 - 1.2, -d / 2 + t + 1.2), model)
	Props.Crate(
		ctx,
		base * CFrame.new(w / 2 - 3.5, 0, d / 2 - 3.5),
		{ kind = "ammo", snap = false, parent = model, size = Vector3.new(2.4, 1.4, 1.6) }
	)
	ctx:AddMinimapCF("building", base, w, d)
	return model
end

--[[
	Fort.LogBunker(ctx, cf, opts) -> Model — timber dugout with a firing slit and earth roof.
	opts: width (12), depth (10), height (6), sunk (2.5)
]]
function Fort.LogBunker(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base0 = place(ctx, at, o)
	local w, d, h = o.width or 12, o.depth or 10, o.height or 6
	local sunk = o.sunk or 2.5
	local model = ctx:Model("LogBunker", folder(ctx, o))
	local lo = select(1, ctx:FootprintMinY(base0, w, d))
	local base = CFrame.new(base0.Position.X, lo - sunk, base0.Position.Z) * (base0 - base0.Position)
	Terrain.Carve(base * CFrame.new(0, h / 2 + 0.3, 0), Vector3.new(w - 1, h, d - 1))
	Terrain.Carve(base * CFrame.new(0, h / 2 + 0.3, d / 2 + 4), Vector3.new(4, h, 8))
	local logD = 1.1
	local courses = math.floor(h / logD)
	local slitCourse = math.max(2, math.floor((sunk + 2.6) / logD))
	local logColor = rgb(92, 72, 52)
	local function log(cf: CFrame, len: number)
		ctx:Part({
			Name = "Log",
			Parent = model,
			Shape = "Cylinder",
			Size = Vector3.new(len, logD, logD),
			CFrame = cf,
			Material = M.Wood,
			Color = logColor,
			Jitter = 0.08,
			Destructible = true,
			Health = 900,
			CastShadow = false,
		})
	end
	for c = 0, courses - 1 do
		local y = c * logD + logD / 2
		-- front: slit course has two short logs leaving a gap
		if c == slitCourse then
			for _, sx in { -1, 1 } do
				log(base * CFrame.new(sx * (w / 2 - 1.5), y, -d / 2), 3)
			end
		else
			log(base * CFrame.new(0, y, -d / 2), w + 1)
		end
		-- back: door gap below 5.5 studs
		if y < 5.5 then
			for _, sx in { -1, 1 } do
				log(base * CFrame.new(sx * (w / 4 + 1), y, d / 2), w / 2 - 2)
			end
		else
			log(base * CFrame.new(0, y, d / 2), w + 1)
		end
		for _, sx in { -1, 1 } do
			log(base * CFrame.new(sx * w / 2, y, 0) * CFrame.Angles(0, math.pi / 2, 0), d + 1)
		end
	end
	for i = 0, math.floor(w / logD) do
		log(base * CFrame.new(-w / 2 + i * logD, h + logD / 2, 0) * CFrame.Angles(0, math.pi / 2, 0), d + 2)
	end
	-- earth roof layer
	Terrain.Fill(base * CFrame.new(0, h + logD + 0.8, 0), Vector3.new(w + 3, 1.6, d + 3), M.Ground)
	Fort.MGProp(ctx, base * CFrame.new(0, slitCourse * logD - 1.6, -d / 2 + 1.6), model)
	ctx:AddMinimapCF("building", base, w, d)
	return model
end

---------------------------------------------------------------------------------------------------
-- Weapon emplacements
---------------------------------------------------------------------------------------------------

-- Static machine gun on a tripod. cf = point on the surface the tripod stands on, facing forward.
function Fort.MGProp(ctx: any, cf: CFrame, parent: Instance?): Model
	local model = ctx:Model("MachineGunProp", parent or ctx:Folder("Fortifications"))
	local metal = rgb(40, 40, 38)
	for i = 0, 2 do
		local a = i * math.pi * 2 / 3 + math.pi / 3
		ctx:Part({
			Name = "TripodLeg",
			Parent = model,
			Size = Vector3.new(0.18, 2.4, 0.18),
			CFrame = cf * CFrame.Angles(0, a, 0) * CFrame.new(0, 1, 0.6) * CFrame.Angles(math.rad(30), 0, 0),
			Material = M.Metal,
			Color = metal,
			Jitter = 0,
			CastShadow = false,
			CanCollide = false,
		})
	end
	ctx:Part({
		Name = "Receiver",
		Parent = model,
		Size = Vector3.new(0.5, 0.6, 2.4),
		CFrame = cf * CFrame.new(0, 2.3, 0),
		Material = M.Metal,
		Color = metal,
		Jitter = 0,
		CastShadow = false,
		CanCollide = false,
	})
	ctx:Part({
		Name = "Barrel",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(2.6, 0.32, 0.32),
		CFrame = cf * CFrame.new(0, 2.35, -2.4) * CFrame.Angles(0, math.pi / 2, 0),
		Material = M.Metal,
		Color = metal,
		Jitter = 0,
		CastShadow = false,
		CanCollide = false,
	})
	return model
end

--[[
	Fort.MGNest(ctx, cf, opts) -> Model — curved sandbag nest (arc 200 degrees) around a shallow pit
	with an MG and ammo boxes. opts: radius (5), courses (3), pit (true)
]]
function Fort.MGNest(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local r = o.radius or 5
	local model = ctx:Model("MGNest", folder(ctx, o))
	if o.pit ~= false then
		local c = base.Position
		Workspace.Terrain:FillCylinder(CFrame.new(c.X, c.Y, c.Z), 3, r - 0.6, M.Air)
		base = base * CFrame.new(0, -1.4, 0)
	end
	local arcDeg = o.arc or 200
	local arcLen = math.rad(arcDeg) * r
	-- Sandbags arc: start in front of the gunner (at -Z) curving back
	Fort.Sandbags(ctx, base * CFrame.new(0, 0, -r), {
		length = arcLen,
		arc = arcDeg,
		courses = o.courses or 3,
		parent = model,
		snap = false,
	})
	Fort.MGProp(ctx, base * CFrame.new(0, 1.2, -r + 1.6), model)
	Props.Crate(
		ctx,
		base * CFrame.new(1.6, 0, 0.5),
		{ kind = "wood", snap = false, parent = model, size = Vector3.new(1.6, 1, 1) }
	)
	return model
end

--[[
	Fort.ATGun(ctx, cf, opts) -> Model — static anti-tank gun (Pak 40 / ZiS-3 like silhouette).
	opts: emplacement (true: sandbag arc in front), color, barrel (12)
]]
function Fort.ATGun(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("ATGun", folder(ctx, o))
	local paint = o.color or rgb(84, 88, 70)
	local metal = rgb(46, 46, 44)
	local barrel = o.barrel or 12
	local function part(name, size, cf, color, mat, shape)
		return ctx:Part({
			Name = name,
			Parent = model,
			Size = size,
			CFrame = base * cf,
			Material = mat or M.Metal,
			Color = color or paint,
			Shape = shape,
			NoPenetration = true,
		})
	end
	part("Axle", Vector3.new(5, 0.5, 0.5), CFrame.new(0, 1.8, 0), metal)
	for _, sx in { -1, 1 } do
		part("Wheel", Vector3.new(0.7, 3.4, 3.4), CFrame.new(sx * 2.6, 1.7, 0), rgb(36, 36, 36), M.Rubber, "Cylinder")
		part(
			"Trail",
			Vector3.new(0.5, 0.5, 7),
			CFrame.new(sx * 1.4, 1, 3.6) * CFrame.Angles(math.rad(10), sx * math.rad(-14), 0)
		)
	end
	part("Cradle", Vector3.new(1.4, 1.2, 3.4), CFrame.new(0, 2.6, -0.4))
	part(
		"Barrel",
		Vector3.new(barrel, 0.55, 0.55),
		CFrame.new(0, 2.9, -barrel / 2 - 0.6) * CFrame.Angles(0, math.pi / 2, 0),
		paint,
		M.Metal,
		"Cylinder"
	)
	part("MuzzleBrake", Vector3.new(0.9, 0.8, 0.8), CFrame.new(0, 2.9, -barrel - 0.8), metal)
	-- Two-piece angled gun shield with a gap for the barrel
	for _, sx in { -1, 1 } do
		part(
			"Shield",
			Vector3.new(2.4, 3.6, 0.25),
			CFrame.new(sx * 1.6, 3.2, -1.5) * CFrame.Angles(math.rad(-8), sx * math.rad(12), 0)
		)
	end
	if o.emplacement ~= false then
		Fort.Sandbags(
			ctx,
			base * CFrame.new(0, 0, -6.5),
			{ length = 16, arc = 110, courses = 2, parent = model, snap = false }
		)
		Props.Crate(
			ctx,
			base * CFrame.new(3.5, 0, 4),
			{ kind = "wood", snap = false, parent = model, size = Vector3.new(2.6, 1.2, 1.4) }
		)
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Foxholes & barricades
---------------------------------------------------------------------------------------------------

-- Foxhole: a round hole with a spoil rim and a few sandbags on the forward lip.
function Fort.Foxhole(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local r = o.radius or 3
	local depth = o.depth or 3.5
	local terrain = Workspace.Terrain
	local c = base.Position
	for i = 0, 6 do
		local a = i * math.pi * 2 / 7
		terrain:FillBall(
			Vector3.new(c.X + math.cos(a) * (r + 1.2), c.Y - 0.8, c.Z + math.sin(a) * (r + 1.2)),
			1.8,
			M.Ground
		)
	end
	terrain:FillCylinder(CFrame.new(c.X, c.Y - depth / 2 + 1, c.Z), depth + 2, r, M.Air)
	local model = ctx:Model("Foxhole", folder(ctx, o))
	if o.sandbags ~= false then
		Fort.Sandbags(
			ctx,
			base * CFrame.new(0, 0.6, -r - 0.6),
			{ length = r * 2.2, arc = 70, courses = 1, parent = model, snap = false }
		)
	end
	ctx:Step(4)
	return model
end

--[[
	Fort.Barricade(ctx, cf, opts) -> Model — street barricade blocking a lane.
	opts.kind: "wood" (planks, braces, barrels) | "debris" (furniture, beams, cart, crates); length (10)
]]
function Fort.Barricade(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("Barricade", folder(ctx, o))
	local len = o.length or 10
	if (o.kind or "wood") == "wood" then
		for i = 0, 3 do
			ctx:Part({
				Name = "Plank",
				Parent = model,
				Size = Vector3.new(len, 0.9, 0.35),
				CFrame = base
					* CFrame.new(ctx:Range(-0.4, 0.4), 0.7 + i * 1.05, 0)
					* CFrame.Angles(0, 0, ctx:Range(-0.06, 0.06)),
				Material = M.WoodPlanks,
				Color = ctx:Pick({ rgb(110, 88, 62), rgb(96, 76, 54), rgb(124, 100, 70) }),
				Destructible = true,
			})
		end
		for _, sx in { -1, 1 } do
			ctx:Part({
				Name = "Brace",
				Parent = model,
				Size = Vector3.new(0.5, 5, 0.5),
				CFrame = base * CFrame.new(sx * len * 0.35, 2, 1.2) * CFrame.Angles(math.rad(-30), 0, 0),
				Material = M.Wood,
				Color = rgb(78, 62, 46),
				Destructible = true,
				CastShadow = false,
			})
		end
		Props.Barrel(ctx, base * CFrame.new(len / 2 + 1.5, 0, 0.5), { parent = model, snap = false })
	else
		for _ = 1, 5 do
			local kind = ctx.rng:NextNumber()
			local p = base * CFrame.new(ctx:Range(-len / 2, len / 2), 0, ctx:Range(-1, 1))
			if kind < 0.35 then
				Props.Crate(
					ctx,
					p * CFrame.Angles(0, ctx:Range(0, 3), ctx:Range(-0.3, 0.3)),
					{ parent = model, snap = false }
				)
			elseif kind < 0.6 then
				ctx:Part({
					Name = "Furniture",
					Parent = model,
					Size = Vector3.new(ctx:Range(3, 5), ctx:Range(2.5, 5), ctx:Range(1.2, 2)),
					CFrame = p
						* CFrame.new(0, 1.6, 0)
						* CFrame.Angles(ctx:Range(-0.4, 0.4), ctx:Range(0, 3), ctx:Range(-0.6, 0.6)),
					Material = M.Wood,
					Color = rgb(84, 62, 44),
					Destructible = true,
				})
			else
				ctx:Part({
					Name = "Beam",
					Parent = model,
					Size = Vector3.new(0.9, 0.9, ctx:Range(7, 11)),
					CFrame = p * CFrame.new(0, 1.4, 0) * CFrame.Angles(ctx:Range(-0.5, 0.5), ctx:Range(0, 3.1), 0),
					Material = M.Wood,
					Color = rgb(60, 48, 36),
					Destructible = true,
				})
			end
		end
		Terrain.RubbleMound(ctx, base.Position, len * 0.5, 2.2, { M.Brick, M.Concrete, M.Ground })
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Trenches
---------------------------------------------------------------------------------------------------

--[[
	Fort.Trench(ctx, points, opts) -> Model
	Carves a trench along `points` (Vector3/Vector2, Y ignored) and dresses it.
	Use Layout.Zigzag(points, 4, 12) for a traversed fire trench.
	opts:
	  width (5), depth (6)
	  revetment (0.8)   fraction of pieces with plank walls on both sides
	  duckboards (true)
	  fireSteps (40)    a fire step (2.4 high, front side) every N studs — lets players shoot out & climb out
	  parapet ("left" | "right" | "both" | "none", default "left") earth berm on the front lip
	                    (left/right relative to the direction of travel along points)
	  sandbags (0.2)    chance per piece of a sandbag course on the front lip
	  ramps (true)      sloped exits at both ends
	  minimap (true)
]]
function Fort.Trench(ctx: any, points: { any }, opts: { [string]: any }?): Model
	local o = opts or {}
	local width = o.width or 5
	local depth = o.depth or 6
	local model = ctx:Model("Trench", folder(ctx, o))
	local piece = 6
	local plankColor = rgb(96, 78, 56)
	local terrain = Workspace.Terrain

	Terrain.CarvePath(ctx, points, width, depth, piece)

	-- Parapet berms (must come after carving: berms sit beside the cut)
	local parapet = o.parapet or "left"
	local half = width / 2
	if parapet == "left" or parapet == "both" then
		Terrain.Berm(ctx, Geo.offsetPath(points, -(half + 2.8)), 6, 2.2, o.parapetMaterial or M.Ground)
	end
	if parapet == "right" or parapet == "both" then
		Terrain.Berm(ctx, Geo.offsetPath(points, half + 2.8), 6, 2.2, o.parapetMaterial or M.Ground)
	end
	local frontSign = if parapet == "right" then 1 else -1

	local p = Geo.path(points)
	local n = math.max(1, math.ceil(p.length / piece))
	local pl = p.length / n
	local fireEvery = o.fireSteps or 40
	local nextFire = fireEvery * 0.5
	for i = 0, n - 1 do
		local dMid = (i + 0.5) * pl
		local x, z, dx, dz = Geo.sample(p, dMid)
		local gy = ctx:GroundY(x, z)
		local floorY = gy - depth
		local nearEnd = (o.ramps ~= false) and (dMid < 8 or dMid > p.length - 8)
		local cf = CFrame.lookAt(Vector3.new(x, floorY, z), Vector3.new(x + dx, floorY, z + dz))
		if not nearEnd then
			if ctx:Chance(o.revetment or 0.8) then
				for _, sx in { -1, 1 } do
					ctx:Part({
						Name = "Revetment",
						Parent = model,
						Size = Vector3.new(0.35, depth + 0.2, pl + 0.2),
						CFrame = cf * CFrame.new(sx * (half - 0.2), depth / 2, 0),
						Material = M.WoodPlanks,
						Color = plankColor,
						Jitter = 0.08,
						Destructible = true,
						Health = 600,
						CastShadow = false,
					})
				end
				if i % 2 == 0 then
					for _, sx in { -1, 1 } do
						ctx:Part({
							Name = "Post",
							Parent = model,
							Size = Vector3.new(0.5, depth + 1, 0.5),
							CFrame = cf * CFrame.new(sx * (half - 0.45), depth / 2 + 0.3, -pl / 2),
							Material = M.Wood,
							Color = rgb(70, 56, 42),
							CastShadow = false,
						})
					end
				end
			end
			if o.duckboards ~= false then
				ctx:Part({
					Name = "Duckboard",
					Parent = model,
					Size = Vector3.new(width * 0.55, 0.3, pl - 0.3),
					CFrame = cf * CFrame.new(0, 0.15, 0),
					Material = M.WoodPlanks,
					Color = rgb(88, 72, 52),
					Jitter = 0.08,
					CastShadow = false,
				})
			end
			if dMid >= nextFire then
				nextFire += fireEvery
				ctx:Part({
					Name = "FireStep",
					Parent = model,
					Size = Vector3.new(1.8, 2.4, pl * 1.6),
					CFrame = cf * CFrame.new(frontSign * (half - 1.1), 1.2, 0),
					Material = M.WoodPlanks,
					Color = plankColor,
					Destructible = true,
				})
			end
			if ctx:Chance(o.sandbags or 0.2) then
				Fort.Sandbags(
					ctx,
					cf
						* CFrame.new(frontSign * (half + 1.2), depth - 0.2, 0)
						* CFrame.Angles(0, -frontSign * math.pi / 2, 0),
					{
						length = pl,
						courses = 1,
						parent = model,
						snap = false,
					}
				)
			end
		end
	end

	-- Exit ramps: terrain wedges filling the last 10 studs of each end into a slope
	if o.ramps ~= false then
		for _, e in { { 0, 1 }, { p.length, -1 } } do
			local d0, dir = e[1], e[2]
			local x0, z0, dx, dz = Geo.sample(p, d0)
			local gy = ctx:GroundY(x0, z0)
			local centreD = d0 + dir * 5
			local cx, cz = Geo.sample(p, centreD)
			-- rise toward the trench end (opposite of travel into the trench)
			local riseDir = Vector3.new(-dx * dir, 0, -dz * dir)
			local cf = Core.WedgeCF(Vector3.new(cx, gy - depth / 2, cz), riseDir)
			terrain:FillWedge(cf, Vector3.new(width + 0.5, depth, 10), M.Ground)
		end
	end
	if o.minimap ~= false then
		ctx:AddMinimapPath("trench", points, width + 2)
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Watchtower
---------------------------------------------------------------------------------------------------

-- Wooden observation tower with a ladder and a sandbagged platform. opts.height (14)
function Fort.Watchtower(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local h = o.height or 14
	local s = 7
	local model = ctx:Model("Watchtower", folder(ctx, o))
	local wood = rgb(88, 70, 50)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			ctx:Part({
				Name = "Leg",
				Parent = model,
				Size = Vector3.new(0.8, h + 6, 0.8),
				CFrame = base * CFrame.new(sx * s / 2, (h + 6) / 2 - 1, sz * s / 2),
				Material = M.Wood,
				Color = wood,
			})
		end
	end
	for _, sz in { -1, 1 } do
		local a, b = base * Vector3.new(-s / 2, 1, sz * s / 2), base * Vector3.new(s / 2, h - 1, sz * s / 2)
		local cf, l = Core.Between(a, b)
		ctx:Part({
			Name = "Brace",
			Parent = model,
			Size = Vector3.new(0.4, 0.4, l),
			CFrame = cf,
			Material = M.Wood,
			Color = wood,
			CastShadow = false,
		})
	end
	ctx:Part({
		Name = "Platform",
		Parent = model,
		Size = Vector3.new(s + 1.2, 0.6, s + 1.2),
		CFrame = base * CFrame.new(0, h, 0),
		Material = M.WoodPlanks,
		Color = wood,
	})
	for _, e in { { 0, -1, 0 }, { -1, 0, math.pi / 2 }, { 1, 0, -math.pi / 2 } } do -- ladder side (+Z) open
		ctx:Part({
			Name = "Parapet",
			Parent = model,
			Size = Vector3.new(s + 1.2, 2.8, 0.4),
			CFrame = base * CFrame.new(e[1] * (s / 2 + 0.4), h + 1.7, e[2] * (s / 2 + 0.4)) * CFrame.Angles(0, e[3], 0),
			Material = M.WoodPlanks,
			Color = wood,
			Destructible = true,
		})
	end
	ctx:Part({
		Name = "Roof",
		Parent = model,
		Size = Vector3.new(s + 2, 0.4, s + 2),
		CFrame = base * CFrame.new(0, h + 6, 0),
		Material = M.WoodPlanks,
		Color = rgb(70, 58, 46),
	})
	ctx:Part({
		Name = "Ladder",
		Parent = model,
		Shape = "Truss",
		Size = Vector3.new(2, h + 2, 2),
		CFrame = base * CFrame.new(0, (h + 2) / 2, s / 2 + 1.2),
		Color = wood,
	})
	ctx:AddMinimapCF("building", base, s, s)
	return model
end

return Fort
