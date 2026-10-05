--[[
	MapKit.Layout — placement helpers and gameplay structures.

	  Scatter(ctx, area, opts) -> {Vector3}           Poisson-like scatter with min spacing & avoid circles
	  AlongPath(ctx, points, spacing, fn, opts)        calls fn(groundCFrame, index) along a polyline
	  Zigzag / Offset / Smooth                         polyline helpers (re-exported from Geo)
	  PlanGrid(origin, opts) -> {streets, lots}        street grid plan (paint streets, then build lots)
	  PrepareHQ(hm, cf, opts)                          flattens terrain for an HQ (call before Generate)
	  SpawnArea(ctx, cf, side, opts) -> {spawns, vehicles}  builds an HQ with cover berms + tents + flag
	  CapturePoint(ctx, def) -> objective table        flag pole in workspace.Map.Objectives.<id>
	  ObjectiveSpawns(ctx, pos, radius, count) -> {CFrame}

	area = { center = Vector3, size = Vector2, rot = degrees? } or { polygon = { points } }
]]

local Workspace = game:GetService("Workspace")

local Core = require(script.Parent.Core)
local Geo = require(script.Parent.Geo)
local Terrain = require(script.Parent.Terrain)
local Props = require(script.Parent.Props)

local M = Enum.Material

local Layout = {}

Layout.Zigzag = Geo.zigzag
Layout.Offset = Geo.offsetPath
Layout.Smooth = Geo.smooth

---------------------------------------------------------------------------------------------------
-- Scatter
---------------------------------------------------------------------------------------------------

local function areaBox(area: { [string]: any }): (number, number, number, number)
	if area.polygon then
		local p = Geo.path(area.polygon)
		return p.minX, p.maxX, p.minZ, p.maxZ
	end
	local c: Vector3, s: Vector2 = area.center, area.size
	local r = math.sqrt(s.X * s.X + s.Y * s.Y) / 2
	if not area.rot or area.rot == 0 then
		return c.X - s.X / 2, c.X + s.X / 2, c.Z - s.Y / 2, c.Z + s.Y / 2
	end
	return c.X - r, c.X + r, c.Z - r, c.Z + r
end

function Layout.InArea(area: { [string]: any }, x: number, z: number): boolean
	if area.polygon then
		return Geo.pointInPolygon(x, z, area.polygon)
	end
	return Geo.inRect(x, z, area.center.X, area.center.Z, area.size.X, area.size.Y, area.rot)
end

--[[
	Layout.Scatter(ctx, area, opts) -> { Vector3 } (Y = analytic ground height)
	opts: spacing (min distance, default 10), count (default area / spacing^2 * 0.6),
	      avoid = { {x, z, r} }, maxTries (count * 8), filter(x, z) -> boolean
]]
function Layout.Scatter(ctx: any, area: { [string]: any }, opts: { [string]: any }?): { Vector3 }
	local o = opts or {}
	local spacing = o.spacing or 10
	local minX, maxX, minZ, maxZ = areaBox(area)
	local approxArea = if area.polygon then (maxX - minX) * (maxZ - minZ) * 0.6 else area.size.X * area.size.Y
	local count = o.count or math.floor(approxArea / (spacing * spacing) * 0.6)
	local tries = o.maxTries or count * 8
	local cell = spacing
	local grid: { [number]: { Vector3 } } = {}
	local out = {}
	local avoid = o.avoid or {}
	local function key(ix, iz)
		return ix * 100003 + iz
	end
	while #out < count and tries > 0 do
		tries -= 1
		local x, z = ctx:Range(minX, maxX), ctx:Range(minZ, maxZ)
		if not Layout.InArea(area, x, z) then
			continue
		end
		local ok = true
		for _, a in avoid do
			if (x - a[1]) ^ 2 + (z - a[2]) ^ 2 < a[3] * a[3] then
				ok = false
				break
			end
		end
		if ok and o.filter and not o.filter(x, z) then
			ok = false
		end
		if not ok then
			continue
		end
		local ix, iz = math.floor(x / cell), math.floor(z / cell)
		for gx = ix - 1, ix + 1 do
			for gz = iz - 1, iz + 1 do
				local bucket = grid[key(gx, gz)]
				if bucket then
					for _, p in bucket do
						if (p.X - x) ^ 2 + (p.Z - z) ^ 2 < spacing * spacing then
							ok = false
							break
						end
					end
				end
				if not ok then
					break
				end
			end
			if not ok then
				break
			end
		end
		if ok then
			local p = Vector3.new(x, ctx:GroundY(x, z), z)
			table.insert(out, p)
			local k = key(ix, iz)
			grid[k] = grid[k] or {}
			table.insert(grid[k], p)
		end
	end
	return out
end

--[[
	Layout.AlongPath(ctx, points, spacing, fn, opts)
	Calls fn(cf, index) every `spacing` studs; cf sits on the ground facing along the path.
	opts: offset (sideways studs, + = right), jitter (random sideways/along studs), startAt, endAt
]]
function Layout.AlongPath(
	ctx: any,
	points: { any },
	spacing: number,
	fn: (CFrame, number) -> (),
	opts: { [string]: any }?
)
	local o = opts or {}
	local p = Geo.path(points)
	local d = o.startAt or spacing / 2
	local stop = p.length - (o.endAt or 0)
	local i = 0
	while d <= stop do
		i += 1
		local x, z, dx, dz = Geo.sample(p, d)
		local off = (o.offset or 0) + (if o.jitter then ctx:Range(-o.jitter, o.jitter) else 0)
		x, z = x - dz * off, z + dx * off
		local y = ctx:GroundY(x, z)
		fn(CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x + dx, y, z + dz)), i)
		d += spacing + (if o.jitter then ctx:Range(-o.jitter, o.jitter) * 0.5 else 0)
	end
end

---------------------------------------------------------------------------------------------------
-- Street grid planning
---------------------------------------------------------------------------------------------------

--[[
	Layout.PlanGrid(origin, opts) -> { streets = {{cx, cz, sx, sz, rot}}, lots = {{cf, w, d}}, blocks = {...} }
	origin: CFrame (centre of the grid; Y ignored). opts: blocksX (3), blocksZ (2),
	        blockW (60), blockD (50), street (16), lotsPerSide (3), lotDepth (16)
	Lots face their street (lot cf LookVector points at the street). Pure planning: nothing is built,
	so streets can be painted into the MaterialModel / flattened before Terrain.Generate.
]]
function Layout.PlanGrid(origin: CFrame, opts: { [string]: any }?)
	local o = opts or {}
	local bx, bz = o.blocksX or 3, o.blocksZ or 2
	local bw, bd = o.blockW or 60, o.blockD or 50
	local st = o.street or 16
	local per = o.lotsPerSide or 3
	local lotD = o.lotDepth or 16
	local totalW = bx * bw + (bx + 1) * st
	local totalD = bz * bd + (bz + 1) * st
	local yaw = Core.Yaw(origin)
	local plan = { streets = {}, lots = {}, blocks = {} }
	local flat = CFrame.new(origin.Position.X, 0, origin.Position.Z) * CFrame.Angles(0, math.rad(yaw), 0)
	-- streets along X (between block rows) and along Z (between block columns)
	for j = 0, bz do
		local z = -totalD / 2 + st / 2 + j * (bd + st)
		local c = flat * Vector3.new(0, 0, z)
		table.insert(plan.streets, { c.X, c.Z, totalW, st, yaw })
	end
	for i = 0, bx do
		local x = -totalW / 2 + st / 2 + i * (bw + st)
		local c = flat * Vector3.new(x, 0, 0)
		table.insert(plan.streets, { c.X, c.Z, st, totalD, yaw })
	end
	for i = 0, bx - 1 do
		for j = 0, bz - 1 do
			local cx = -totalW / 2 + st + bw / 2 + i * (bw + st)
			local cz = -totalD / 2 + st + bd / 2 + j * (bd + st)
			table.insert(plan.blocks, { cf = flat * CFrame.new(cx, 0, cz), w = bw, d = bd })
			local lotW = bw / per
			for k = 0, per - 1 do
				local lx = cx - bw / 2 + (k + 0.5) * lotW
				-- front side (faces -Z street)
				table.insert(plan.lots, { cf = flat * CFrame.new(lx, 0, cz - bd / 2 + lotD / 2), w = lotW, d = lotD })
				-- back side (faces +Z street)
				table.insert(plan.lots, {
					cf = flat * CFrame.new(lx, 0, cz + bd / 2 - lotD / 2) * CFrame.Angles(0, math.pi, 0),
					w = lotW,
					d = lotD,
				})
			end
		end
	end
	return plan
end

---------------------------------------------------------------------------------------------------
-- HQ / spawn areas
---------------------------------------------------------------------------------------------------

-- Flatten the HQ pad in the HeightModel (call before Terrain.Generate). cf faces the enemy.
function Layout.PrepareHQ(hm: any, cf: CFrame, opts: { [string]: any }?)
	local o = opts or {}
	local p = cf.Position
	hm:FlattenRect(p.X, p.Z, o.width or 150, o.depth or 110, Core.Yaw(cf), o.y, o.blend or 40)
end

--[[
	Layout.SpawnArea(ctx, cf, side, opts) -> { spawns = {CFrame}, vehicles = {CFrame}, model = Model }
	cf: HQ centre on the ground, LookVector toward the enemy / front line.
	Builds: two earth berms with sandbag tops in front (vehicle gap in the middle), side berms,
	tents, ammo cache (ResupplyPoint), medical crate (MedicalPoint), HQ flag, crates.
	opts: spawnCount (10), vehicleCount (6), width (120), bermDistance (42), color (flag colour override)
]]
function Layout.SpawnArea(ctx: any, cf: CFrame, side: string, opts: { [string]: any }?)
	local o = opts or {}
	local Fort = require(script.Parent.Fortifications) :: any
	local model = ctx:Model("HQ_" .. side, ctx:Folder("HQ"))
	local width = o.width or 120
	local bermD = o.bermDistance or 42
	local p = cf.Position
	local base = CFrame.new(p.X, ctx:GroundY(p.X, p.Z), p.Z) * (cf - p)

	-- Front berms (gap for vehicles in the middle), angled wings on the flanks
	local gap = o.gap or 22
	local function local2(x, z)
		local w = base * Vector3.new(x, 0, z)
		return Vector3.new(w.X, 0, w.Z)
	end
	local frontL = { local2(-width / 2, -bermD + 10), local2(-width / 4, -bermD), local2(-gap / 2, -bermD) }
	local frontR = { local2(gap / 2, -bermD), local2(width / 4, -bermD), local2(width / 2, -bermD + 10) }
	local bermH = o.bermHeight or 7
	Terrain.Berm(ctx, frontL, 12, bermH, M.Ground)
	Terrain.Berm(ctx, frontR, 12, bermH, M.Ground)
	-- Inner baffle berm behind the gap so there is no straight sightline into the HQ
	Terrain.Berm(ctx, { local2(-gap * 0.9, -bermD + 20), local2(gap * 0.9, -bermD + 20) }, 10, bermH * 0.8, M.Ground)
	Terrain.Berm(ctx, { local2(-width / 2 - 4, -bermD + 14), local2(-width / 2 - 4, 30) }, 10, bermH * 0.75, M.Ground)
	Terrain.Berm(ctx, { local2(width / 2 + 4, -bermD + 14), local2(width / 2 + 4, 30) }, 10, bermH * 0.75, M.Ground)

	-- Sandbag tops on the front berms
	for _, x in { -width / 3, -width / 6, width / 6, width / 3 } do
		local w = base * Vector3.new(x, 0, -bermD + 1)
		local y = ctx:SurfaceY(w.X, w.Z)
		Fort.Sandbags(
			ctx,
			CFrame.new(w.X, y - 0.6, w.Z) * (base - base.Position),
			{ length = 12, courses = 2, parent = model, snap = false }
		)
	end

	-- Tents and supplies
	local tentSpots = { { -30, 18 }, { 0, 30 }, { 30, 18 } }
	for i, t in tentSpots do
		Props.Tent(
			ctx,
			base
				* CFrame.new(t[1], 0, t[2])
				* CFrame.Angles(0, if i == 2 then 0 else math.rad(t[1] > 0 and -20 or 20), 0),
			{
				parent = model,
				size = Vector3.new(10, 7, 14),
			}
		)
	end
	Props.AmmoCache(ctx, base * CFrame.new(-16, 0, -18), { parent = model })
	Props.AmmoCache(ctx, base * CFrame.new(16, 0, -18), { parent = model })
	Props.Crate(ctx, base * CFrame.new(0, 0, 20), { kind = "medical", parent = model, size = Vector3.new(3, 2, 2) })
	Props.CrateStack(ctx, base * CFrame.new(-34, 0, -2), { parent = model })
	Props.CrateStack(ctx, base * CFrame.new(34, 0, -2), { parent = model })
	Props.BarrelGroup(ctx, base * CFrame.new(40, 0, 6), { parent = model })
	Props.FlagPole(ctx, base * CFrame.new(0, 0, 14), { parent = model, name = "HQFlag", owner = side, height = 18 })
	ctx:AddMinimapCF("building", base * CFrame.new(0, 0, 22), 70, 20)

	-- Infantry spawns: rows behind the berms, facing the front
	local spawns = {}
	local n = o.spawnCount or 10
	local cols = 5
	for i = 0, n - 1 do
		local cx = (i % cols - (cols - 1) / 2) * 9 + ctx:Range(-1.5, 1.5)
		local cz = -4 + math.floor(i / cols) * 9 + ctx:Range(-1.5, 1.5)
		local w = base * Vector3.new(cx, 0, cz)
		local y = ctx:SurfaceY(w.X, w.Z)
		table.insert(
			spawns,
			CFrame.lookAt(Vector3.new(w.X, y + 3, w.Z), Vector3.new(w.X, y + 3, w.Z) + base.LookVector)
		)
	end

	-- Vehicle parking on the flanks behind the berm gap
	local vehicles = {}
	local vc = o.vehicleCount or 6
	for i = 0, vc - 1 do
		local sideSign = if i % 2 == 0 then -1 else 1
		local row = math.floor(i / 2)
		local w = base * Vector3.new(sideSign * (52 + row * 4), 0, -6 + row * 18)
		local y = ctx:GroundY(w.X, w.Z)
		table.insert(
			vehicles,
			CFrame.lookAt(Vector3.new(w.X, y + 2, w.Z), Vector3.new(w.X, y + 2, w.Z) + base.LookVector)
		)
	end
	return { spawns = spawns, vehicles = vehicles, model = model }
end

---------------------------------------------------------------------------------------------------
-- Capture points
---------------------------------------------------------------------------------------------------

local spawnRay = RaycastParams.new()
spawnRay.FilterType = Enum.RaycastFilterType.Include
spawnRay.IgnoreWater = true

--[[
	Layout.ObjectiveSpawns(ctx, pos, radius, count, opts) -> { CFrame }
	Finds open ground around an objective (rejects roofs, walls, water); spawns face `pos`.
	Call AFTER buildings/props are placed.
]]
function Layout.ObjectiveSpawns(
	ctx: any,
	pos: Vector3,
	radius: number,
	count: number?,
	opts: { [string]: any }?
): { CFrame }
	local o = opts or {}
	local want = count or 6
	local out = {}
	spawnRay.FilterDescendantsInstances = { ctx.root, Workspace.Terrain }
	local minR, maxR = o.minRadius or radius + 6, o.maxRadius or radius + 30
	local tries = 0
	while #out < want and tries < want * 30 do
		tries += 1
		local a = ctx:Range(0, math.pi * 2)
		local d = ctx:Range(minR, maxR)
		local x, z = pos.X + math.cos(a) * d, pos.Z + math.sin(a) * d
		local hit = Workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), spawnRay)
		if not hit or hit.Instance ~= Workspace.Terrain then
			continue -- landed on a part (roof, wall, prop): skip
		end
		if hit.Material == M.Water then
			continue
		end
		local ground = hit.Position
		-- headroom & clearance check: nothing solid within 2.5 studs around head height
		local clear = Workspace:GetPartBoundsInRadius(ground + Vector3.new(0, 3, 0), 2.5)
		local blocked = false
		for _, part in clear do
			if part.CanCollide and part:IsDescendantOf(ctx.root) then
				blocked = true
				break
			end
		end
		if blocked then
			continue
		end
		local at = ground + Vector3.new(0, 3, 0)
		table.insert(out, CFrame.lookAt(at, Vector3.new(pos.X, at.Y, pos.Z)))
	end
	-- Guarantee at least one spawn
	if #out == 0 then
		table.insert(out, CFrame.new(pos + Vector3.new(radius + 8, 6, 0)))
	end
	return out
end

--[[
	Layout.CapturePoint(ctx, def) -> objective table (MapInfo.objectives entry)
	def: { id = "A", name = "Church", position = Vector3 (Y ignored), radius = 25, order = 1,
	       initialOwner = "Neutral", spawns = {CFrame}? (auto when omitted), spawnCount = 6 }
	Creates workspace.Map.Objectives.<id> (a FlagPole Model containing a BasePart named "Flag").
]]
function Layout.CapturePoint(ctx: any, def: { [string]: any })
	local p: Vector3 = def.position
	local y = ctx:GroundY(p.X, p.Z)
	local flagAt = def.flagPosition or p
	local flagModel = Props.FlagPole(ctx, Vector3.new(flagAt.X, 0, flagAt.Z), {
		parent = ctx.objectives,
		name = def.id,
		owner = def.initialOwner or "Neutral",
		height = def.flagHeight or 22,
	})
	flagModel:SetAttribute("ObjectiveId", def.id)
	flagModel:SetAttribute("Radius", def.radius or 25)
	return {
		id = def.id,
		name = def.name or def.id,
		position = Vector3.new(p.X, y, p.Z),
		radius = def.radius or 25,
		order = def.order or 1,
		initialOwner = def.initialOwner or "Neutral",
		spawns = def.spawns
			or Layout.ObjectiveSpawns(ctx, Vector3.new(p.X, y, p.Z), def.radius or 25, def.spawnCount or 6),
	}
end

return Layout
