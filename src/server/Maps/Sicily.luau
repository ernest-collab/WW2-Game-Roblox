--[[
	Sicily — "Sicilian Hills" (≈1600 x 1600 studs). Map team (B).

	July 1943. The Allies advance from the vineyards of the southern valley, across the dry
	riverbed, up the switchback road into a sun-baked stone hill town, through the terraced olive
	groves and finally storm the ruined castle on the highest hill.

	   z=+800 ┌──────────────────────────────────────────────────────────────┐
	          │ [AXIS HQ] (-300,660)    ridge    castle hill (y≈90)           │
	          │      ╲ road ╲      E Castello (20,480) curtain walls, towers  │
	          │  pines   ╱╲╱╲ switchbacks ╱╲╱╲                                │
	          │  terraces          D Uliveto (230,290) olive terraces, farm    │
	          │ cypresses   C Piazza (-40,60) hill town, church, fountain      │
	          │      ╱╲╱╲ switchback road ╱╲╱╲   terraces                     │
	          │ ═══ dry riverbed ═══ B Ponte Saraceno (80,-240) ═══ ford ═══   │
	          │ vineyards    A Masseria (-220,-440) farm      vineyards        │
	          │              [ALLIED HQ] (-40,-650)                            │
	   z=-800 └──────────────────────────────────────────────────────────────┘
	           x=-800                                                    x=+800

	Objectives (order 1 = Allied end): A Masseria (fortified farm among the vineyards), B Ponte
	Saraceno (stone bridge over the dry riverbed), C Piazza (hill-town square and church), D Uliveto
	(olive terraces and a farmhouse), E Castello (hilltop castle ruin).
	Tank routes: the switchback road B -> C -> E (grades kept under ~15%), the eastern valley road
	with a riverbed ford, and the western road. The riverbed banks are shallow enough to cross.
]]

local MapKit = require(script.Parent.MapKit)

local Terrain = MapKit.Terrain
local Buildings = MapKit.Buildings
local Fort = MapKit.Fortifications
local Props = MapKit.Props
local Nature = MapKit.Nature
local Layout = MapKit.Layout
local Geo = MapKit.Geo

local M = Enum.Material
local rgb = Color3.fromRGB
local V = function(x: number, z: number): Vector3
	return Vector3.new(x, 0, z)
end

local Sicily = {}

local SIZE = 1600
local SEED = 1710

-- Layout data -----------------------------------------------------------------------------------------

local HQ_ALLIES = CFrame.new(-40, 0, -650) * CFrame.Angles(0, math.pi, 0) -- faces north (+Z)
local HQ_AXIS = CFrame.new(-300, 0, 660) -- faces south (-Z)

local TOWN = { x = -40, z = 70, r = 120 }
local CASTLE = { x = 20, z = 490 }

local RIVERBED = { V(-840, -270), V(-520, -230), V(-220, -275), V(80, -240), V(320, -205), V(560, -260), V(840, -235) }

local ROADS = {
	-- the switchback road: HQ -> bridge -> town -> castle
	main = {
		V(-40, -820),
		V(-40, -640),
		V(-20, -480),
		V(60, -340),
		V(80, -290),
		V(80, -190),
		V(160, -150),
		V(-10, -125),
		V(150, -85),
		V(20, -40),
		V(-40, 0),
		V(-40, 70),
	},
	castle = { V(-40, 70), V(-60, 150), V(-130, 210), V(120, 260), V(-80, 320), V(140, 370), V(60, 418), V(0, 436) },
	axis = { V(0, 436), V(-80, 448), V(-160, 470), V(-250, 495), V(-300, 530), V(-300, 640), V(-300, 820) },
	east = { V(620, -820), V(470, -480), V(380, -300), V(390, -200), V(330, 20), V(230, 290), V(200, 400), V(60, 420) },
	west = { V(-820, -330), V(-500, -380), V(-220, -440), V(-20, -480) },
	westNorth = {
		V(-500, -380),
		V(-430, -240),
		V(-400, -60),
		V(-340, 200),
		V(-360, 420),
		V(-430, 540),
		V(-425, 690),
		V(-300, 745),
	},
	townEast = { V(-40, 70), V(80, 120), V(160, 190), V(230, 290) },
	townWest = { V(-40, 70), V(-170, 60), V(-340, 200) },
}

local OBJECTIVES = {
	{ id = "A", name = "Masseria", pos = V(-220, -440), radius = 32, owner = "Allies", flag = V(-226, -428) },
	{ id = "B", name = "Ponte Saraceno", pos = V(80, -240), radius = 30, owner = "Neutral", flag = V(96, -206) },
	{ id = "C", name = "Piazza", pos = V(-40, 70), radius = 30, owner = "Neutral", flag = V(-32, 76) },
	{ id = "D", name = "Uliveto", pos = V(230, 290), radius = 32, owner = "Neutral", flag = V(244, 300) },
	{ id = "E", name = "Castello", pos = V(20, 490), radius = 32, owner = "Axis", flag = V(20, 500) },
}

-- terraced olive slopes: { cx, cz, sx, sz }
local TERRACES = {
	{ -200, -60, 220, 200 },
	{ 230, 120, 200, 160 },
	{ 330, 330, 180, 200 },
	{ -200, 330, 200, 180 },
}

-- Helpers ---------------------------------------------------------------------------------------------

local preparedRoads: { any } = {}
local riverPath = Geo.path(RIVERBED)

local function nearRoad(x: number, z: number, margin: number): boolean
	for _, p in preparedRoads do
		if (Geo.distToPath(p, x, z)) < margin then
			return true
		end
	end
	return false
end

local function inRiverbed(x: number, z: number): boolean
	return (Geo.distToPath(riverPath, x, z)) < 40
end

local function inTown(x: number, z: number, pad: number?): boolean
	local r = TOWN.r + (pad or 0)
	return (x - TOWN.x) ^ 2 + (z - TOWN.z) ^ 2 < r * r
end

local function inTerraces(x: number, z: number): boolean
	for _, t in TERRACES do
		if Geo.inRect(x, z, t[1], t[2], t[3], t[4], 0) then
			return true
		end
	end
	return false
end

local EXCLUDE = {
	{ -40, -650, 140 },
	{ -300, 660, 140 },
	{ -220, -440, 70 },
	{ 230, 290, 50 },
	{ 20, 490, 80 },
}
local function excluded(x: number, z: number): boolean
	for _, e in EXCLUDE do
		if (x - e[1]) ^ 2 + (z - e[2]) ^ 2 < e[3] * e[3] then
			return true
		end
	end
	return inTown(x, z, 20)
end

local OLIVE = { rgb(120, 132, 92), rgb(110, 124, 86), rgb(132, 140, 100), rgb(104, 118, 84) }

-- Olive tree: gnarled leaning trunk + two silver-green crowns (3 parts).
local function olive(ctx: any, x: number, z: number, s: number, parent: Instance)
	local y = ctx:GroundY(x, z)
	local model = ctx:Model("Olive", parent)
	local h = 5 * s
	local tilt = CFrame.Angles(ctx:Range(-0.25, 0.25), ctx:Range(0, 6.28), ctx:Range(-0.25, 0.25))
	local base = CFrame.new(x, y - 0.4, z) * tilt
	ctx:Part({
		Name = "Trunk",
		Parent = model,
		Size = Vector3.new(1.3 * s, h, 1.1 * s),
		CFrame = base * CFrame.new(0, h / 2, 0),
		Material = M.Wood,
		Color = rgb(96, 84, 70),
		Jitter = 0.1,
	})
	local col = ctx:Pick(OLIVE)
	local top = (base * CFrame.new(0, h, 0)).Position
	ctx:Part({
		Name = "Leaves",
		Parent = model,
		Mesh = "Sphere",
		Size = Vector3.new(9 * s, 5.5 * s, 8 * s),
		CFrame = CFrame.new(top + Vector3.new(0, 1.4 * s, 0)) * CFrame.Angles(0, ctx:Range(0, 6.28), 0),
		Material = M.LeafyGrass,
		Color = ctx:Jitter(col, 0.06),
		CanCollide = false,
		CanQuery = false,
		CastShadow = true,
	})
	ctx:Part({
		Name = "Leaves",
		Parent = model,
		Mesh = "Sphere",
		Size = Vector3.new(6 * s, 4 * s, 6 * s),
		CFrame = CFrame.new(top + Vector3.new(ctx:Range(-2, 2) * s, 3.2 * s, ctx:Range(-2, 2) * s)),
		Material = M.LeafyGrass,
		Color = ctx:Jitter(col, 0.1),
		CanCollide = false,
		CanQuery = false,
		CastShadow = true,
	})
	return model
end

-- Vineyard: parallel rows of low vines (non-colliding: vehicles and players push through, but
-- they hide prone infantry). cf = centre, rows along local X.
local function vineyard(ctx: any, cf: CFrame, sx: number, sz: number, parent: Instance)
	local model = ctx:Model("Vineyard", parent)
	local rows = math.floor(sz / 6)
	for i = 0, rows - 1 do
		local lz = -sz / 2 + 3 + i * 6
		local segs = math.max(1, math.floor(sx / 40))
		for k = 0, segs - 1 do
			local len = sx / segs - 3
			local lx = -sx / 2 + (k + 0.5) * sx / segs
			local w = cf * Vector3.new(lx, 0, lz)
			local y = ctx:GroundY(w.X, w.Z)
			ctx:Part({
				Name = "VineRow",
				Parent = model,
				Size = Vector3.new(len, 2.6, 1.6),
				CFrame = CFrame.new(w.X, y + 1.2, w.Z) * (cf - cf.Position),
				Material = M.LeafyGrass,
				Color = ctx:Jitter(rgb(92, 118, 56), 0.08),
				CanCollide = false,
				CanQuery = false,
				CastShadow = false,
			})
		end
	end
	ctx:AddMinimapCF("field", cf, sx, sz)
	return model
end

--[[
	Road with a smoothed, grade-limited longitudinal profile (cut and fill). hm:Road follows the
	terrain lengthwise, which leaves steep ramps where a road climbs onto a flattened site; this
	samples the terrain along the path, smooths it, clamps the grade to `maxGrade` and levels the
	cross-section to that profile. Water crossings (and points where `skip(x, z)` is true, e.g. a
	dry riverbed under a bridge) are bridged in the profile and left uncut.
]]
local function gradedRoad(
	hm: any,
	points: { Vector3 },
	width: number,
	blend: number,
	maxGrade: number,
	skip: ((number, number) -> boolean)?
)
	local path = Geo.path(points)
	local n = math.max(2, math.floor(path.length / 6) + 1)
	local ds = path.length / (n - 1)
	local hs: { number } = table.create(n, 0)
	local wet: { boolean } = table.create(n, false)
	for i = 1, n do
		local x, z = Geo.sample(path, (i - 1) * ds)
		hs[i] = hm:Get(x, z)
		local w = hm:WaterAt(x, z)
		wet[i] = (w ~= nil and w > hs[i] - 0.5) or (skip ~= nil and skip(x, z))
	end
	-- bridge wet runs at the higher bank level
	local i = 1
	while i <= n do
		if wet[i] then
			local j = i
			while j < n and wet[j + 1] do
				j += 1
			end
			local lo = if i > 1 then hs[i - 1] else hs[math.min(j + 1, n)]
			local hi = if j < n then hs[j + 1] else lo
			for k = i, j do
				hs[k] = math.max(lo, hi)
			end
			i = j + 1
		else
			i += 1
		end
	end
	-- smooth, then clamp the grade both ways
	local sm: { number } = table.create(n, 0)
	for k = 1, n do
		local sum, cnt = 0, 0
		for o = -3, 3 do
			local q = k + o
			if q >= 1 and q <= n then
				sum += hs[q]
				cnt += 1
			end
		end
		sm[k] = sum / cnt
	end
	-- pin ~18 studs at each end so roads meeting at a junction share its height
	for k = 1, math.min(4, n) do
		sm[k] = hs[1]
		sm[n + 1 - k] = hs[n]
	end
	local lim = maxGrade * ds
	for _ = 1, 2 do
		for k = 2, n do
			sm[k] = math.clamp(sm[k], sm[k - 1] - lim, sm[k - 1] + lim)
		end
		for k = n - 1, 1, -1 do
			sm[k] = math.clamp(sm[k], sm[k + 1] - lim, sm[k + 1] + lim)
		end
	end
	local half = width / 2
	local reach = half + blend
	hm:Custom(function(x, z, h)
		local d, _, _, a = Geo.distToPath(path, x, z)
		if d >= reach then
			return h
		end
		local w = hm:WaterAt(x, z)
		if (w ~= nil and w > h) or (skip ~= nil and skip(x, z)) then
			return h
		end
		local f = math.clamp(a / ds + 1, 1, n)
		local i0 = math.min(math.floor(f), n - 1)
		local surface = Geo.lerp(sm[i0], sm[i0 + 1], f - i0)
		return Geo.lerp(surface, h, Geo.smoothstep(half, reach, d))
	end, { path.minX - reach, path.maxX + reach, path.minZ - reach, path.maxZ + reach })
end

-- Builder ---------------------------------------------------------------------------------------------

function Sicily.Build(parent: Folder, _def: any)
	local ctx = MapKit.new(parent, { seed = SEED })
	local rng = ctx.rng
	table.clear(preparedRoads)
	for _, r in ROADS do
		table.insert(preparedRoads, Geo.path(r))
	end

	local castleStyle = table.clone(Buildings.Styles.Mediterranean)
	castleStyle.wall = M.Cobblestone
	castleStyle.wallColors = { rgb(184, 168, 138), rgb(170, 156, 128), rgb(196, 180, 150) }
	castleStyle.rubble = { M.Sandstone, M.Limestone, M.Rock }

	Terrain.ApplyPalette({
		Grass = rgb(156, 150, 88),
		LeafyGrass = rgb(126, 130, 72),
		Ground = rgb(168, 138, 98),
		Mud = rgb(140, 112, 80),
		Sandstone = rgb(196, 166, 124),
		Pebble = rgb(184, 174, 154),
		Limestone = rgb(212, 202, 178),
		Rock = rgb(156, 140, 116),
		Pavement = rgb(178, 168, 150),
		Cobblestone = rgb(160, 148, 128),
	}, { color = rgb(70, 110, 120), decoration = true })

	-------------------------------------------------------------------------------------------
	-- 1. Terrain model
	-------------------------------------------------------------------------------------------
	local hm = Terrain.HeightModel({ baseY = 8, seed = SEED })
	hm:Noise(8, 300, 3)
	hm:Noise(2, 60, 2)
	hm:Custom(function(x, z, h)
		local e = math.max(math.abs(x), math.abs(z))
		return h + Geo.smoothstep(-220, 520, z) * 36 + Geo.smoothstep(730, 900, e) * 34
	end)
	hm:Hill(TOWN.x, TOWN.z + 10, 240, 30, 1.2) -- hill town
	hm:Hill(CASTLE.x, CASTLE.z, 230, 40, 1.0) -- castle hill
	hm:Hill(240, 290, 170, 16)
	hm:Hill(-560, 120, 200, 22)
	hm:Hill(560, 60, 200, 18)
	hm:Hill(-560, -560, 180, 14)
	hm:Hill(520, -560, 160, 12)
	-- valley floor along the riverbed
	hm:Custom(function(x, z, h)
		local d = Geo.distToPath(riverPath, x, z)
		if d > 220 then
			return h
		end
		return Geo.lerp(math.min(h, 6), h, Geo.smoothstep(40, 220, d))
	end)
	-- terraces: quantise the slope into 4-stud steps with steep stone risers
	local STEP = 4
	hm:Custom(function(x, z, h)
		if not inTerraces(x, z) then
			return h
		end
		local q = h / STEP
		local f = q - math.floor(q)
		local terraced = (math.floor(q) + Geo.smoothstep(0.78, 1, f)) * STEP
		local edge = 1
		for _, t in TERRACES do
			if Geo.inRect(x, z, t[1], t[2], t[3], t[4], 0) then
				edge = math.min(edge, Geo.smoothstep(0, 30, -Geo.rectDist(x, z, t[1], t[2], t[3], t[4], 0)))
			end
		end
		return Geo.lerp(h, terraced, edge)
	end)
	hm:Channel(RIVERBED, 44, 9, 18, "U") -- dry riverbed
	hm:Flatten(TOWN.x, TOWN.z, TOWN.r - 20, nil, 40)
	hm:Flatten(CASTLE.x, CASTLE.z + 5, 52, nil, 36)
	hm:Flatten(-220, -440, 60, nil, 25)
	hm:Flatten(240, 300, 50, nil, 25)
	Layout.PrepareHQ(hm, HQ_ALLIES)
	Layout.PrepareHQ(hm, HQ_AXIS)
	hm:Ridge({ V(-160, -560), V(-40, -548), V(80, -560) }, 54, 14) -- rise in front of the Allied HQ
	hm:Ridge({ V(-175, -780), V(-170, -640), V(-150, -572) }, 70, 18) -- and its flanks
	hm:Ridge({ V(95, -780), V(90, -640), V(70, -572) }, 70, 18)
	hm:Ridge({ V(-395, 800), V(-395, 660), V(-380, 575) }, 50, 15) -- Axis HQ western flank
	hm:Ridge({ V(-196, 790), V(-198, 670), V(-200, 600), V(-215, 560) }, 50, 24) -- eastern flank, screens it from the castle hill
	hm:Ridge({ V(-420, 560), V(-300, 556), V(-215, 560) }, 50, 15) -- and front rise
	for name, r in ROADS do
		local minor = name == "townEast" or name == "townWest"
		gradedRoad(hm, r, if minor then 11 else 13, 10, if minor then 0.2 else 0.15, inRiverbed)
	end
	-- fords: short graded crossings that cut ramps down into the dry riverbed
	gradedRoad(hm, { V(394, -310), V(386, -230), V(388, -150) }, 13, 8, 0.2)
	gradedRoad(hm, { V(-452, -310), V(-432, -240), V(-424, -170) }, 12, 8, 0.2)

	local mm = Terrain.MaterialModel({ base = M.Grass, subsurface = M.Ground, seed = SEED })
	mm:Patches(M.Ground, 55, 0.25)
	mm:Patches(M.LeafyGrass, 90, 0.45)
	mm:Custom(M.Ground, function(x, z, _y, _s)
		return inTerraces(x, z)
	end)
	mm:Slope(M.Sandstone, 0.85)
	mm:Custom(M.Limestone, function(x, z, _y, slope)
		return slope > 0.5 and Geo.fbm(x, z, 30, 2, 8) > 0.35
	end)
	mm:Path(RIVERBED, 30, M.Pebble, 4)
	mm:Path(RIVERBED, 12, M.Sand, 3)
	for name, r in ROADS do
		mm:Path(r, if name == "townEast" or name == "townWest" then 8 else 10, M.Ground, 1.5)
	end
	mm:Circle(TOWN.x, TOWN.z, 95, M.Pavement, 4)
	mm:Rect(TOWN.x, TOWN.z, 60, 46, 0, M.Cobblestone, 1)
	mm:Circle(CASTLE.x, CASTLE.z, 60, M.Limestone, 8)
	mm:Rect(HQ_ALLIES.Position.X, HQ_ALLIES.Position.Z, 140, 100, 0, M.Ground, 6)
	mm:Rect(HQ_AXIS.Position.X, HQ_AXIS.Position.Z, 140, 100, 0, M.Ground, 6)

	Terrain.Generate(ctx, hm, mm, { center = Vector3.zero, size = Vector2.new(2000, 2000) })

	for _, r in ROADS do
		ctx:AddMinimapPath("road", r, 10)
	end
	ctx:AddMinimapPath("water", RIVERBED, 40) -- dry riverbed drawn as a watercourse

	local props = ctx:Folder("Props")
	local nature = ctx:Folder("Nature")
	local fortFolder = ctx:Folder("Fortifications")

	-------------------------------------------------------------------------------------------
	-- 2. C: the hill town — piazza, church, stone houses, alleys
	-------------------------------------------------------------------------------------------
	local town = ctx:Model("HillTown", ctx:Folder("Buildings"))
	local function sh(x: number, z: number, yaw: number, enterable: boolean, extra: { [string]: any }?)
		local o: { [string]: any } = {
			parent = town,
			enterable = enterable,
			floors = if rng:NextNumber() < 0.55 then 2 else 3,
			width = rng:NextNumber(14, 18),
			depth = rng:NextNumber(11, 14),
			ruin = if rng:NextNumber() < 0.3 then rng:NextNumber(0.2, 0.6) else 0,
		}
		if extra then
			for k, v in extra do
				o[k] = v
			end
		end
		return Buildings.StoneHouse(ctx, ctx:GroundCF(x, z, yaw), o)
	end
	-- church on the north side of the piazza (bell tower = sniper perch)
	Buildings.Church(
		ctx,
		ctx:GroundCF(-40, 132, 180),
		{ width = 20, length = 40, towerH = 36, style = "Mediterranean", ruin = 0.15 }
	)
	Props.Fountain(ctx, ctx:GroundCF(-40, 70, 0), {})
	-- piazza frontage (west, east, south) with alleys between
	sh(-80, 52, -90, true)
	sh(-80, 84, -90, true, { floors = 3 })
	sh(-82, 112, -90, false)
	sh(0, 48, 90, true)
	sh(0, 82, 90, true, { floors = 3, name = "Municipio" })
	sh(2, 112, 90, false)
	sh(-70, 24, 180, true)
	sh(-10, 24, 180, false)
	-- outer ring down the slopes
	sh(-120, 40, -90, false)
	sh(-124, 90, -90, true)
	sh(-110, 140, 0, false)
	sh(40, 40, 90, false)
	sh(44, 80, 90, true)
	sh(36, 140, 0, true)
	sh(-90, -14, 180, true)
	sh(18, -12, 180, false)
	sh(-140, 10, -90, false, { ruin = 0.5 })
	sh(100, 90, 90, false, { ruin = 0.4 })
	sh(90, 150, 0, true)
	sh(-160, 100, 0, true)
	sh(-170, 30, 180, false, { ruin = 0.3 })
	sh(-62, 160, 0, false)
	-- town dressing
	for _, l in { { -60, 58 }, { -20, 58 }, { -60, 92 }, { -20, 92 }, { -40, 30 } } do
		Props.LampPost(ctx, ctx:GroundCF(l[1], l[2], 0), { parent = props })
	end
	Props.Bench(ctx, ctx:GroundCF(-54, 70, -90))
	Props.Bench(ctx, ctx:GroundCF(-26, 70, 90))
	Props.Cart(ctx, ctx:GroundCF(-62, 40, 30), {})
	Props.Wreck(ctx, ctx:GroundCF(-28, 44, 20), { kind = "car" })
	Fort.Sandbags(ctx, ctx:GroundCF(-40, 32, 180), { length = 10, arc = 60 })
	Fort.Sandbags(ctx, ctx:GroundCF(-16, 100, 0), { length = 8, arc = 40 })
	Fort.Barricade(ctx, ctx:GroundCF(-40, 4, 180), { kind = "debris", length = 9 })
	Fort.Barricade(ctx, ctx:GroundCF(-100, 66, 90), { kind = "wood", length = 7 })
	Fort.MGNest(ctx, ctx:GroundCF(-62, 104, 180), {})
	Props.CrateStack(ctx, ctx:GroundCF(-18, 40, 0))
	Props.Well(ctx, ctx:GroundCF(-110, 64, 0))
	Props.RubblePile(ctx, V(-100, 30), { radius = 5, height = 2.5, materials = { M.Sandstone, M.Limestone } })
	Props.RubblePile(ctx, V(22, 98), { radius = 4, height = 2, materials = { M.Sandstone, M.Limestone } })
	Props.Fire(ctx, V(-140, 14), { size = 4 })
	Props.TelegraphLine(ctx, Layout.Offset(ROADS.townEast, 9), { leanChance = 0.2 })
	-- cypresses by the church and along the town road
	for _, c in { { -66, 150 }, { -14, 150 }, { -70, 128 }, { -10, 128 }, { -28, -26 }, { -52, -26 } } do
		Nature.Tree(ctx, V(c[1], c[2]), "Poplar", 1.1, nature)
	end

	-------------------------------------------------------------------------------------------
	-- 3. B: Ponte Saraceno — stone bridge over the dry riverbed
	-------------------------------------------------------------------------------------------
	Props.StoneBridge(ctx, V(80, -282), V(80, -198), { width = 14, arches = 3 })
	Fort.Bunker(ctx, ctx:GroundCF(48, -190, 180), { width = 12, depth = 10, slits = 2 })
	Fort.MGNest(ctx, ctx:GroundCF(116, -196, 180), {})
	Fort.ATGun(ctx, ctx:GroundCF(130, -176, 200), {})
	Fort.Sandbags(ctx, ctx:GroundCF(62, -296, 0), { length = 9, arc = 50 })
	Fort.Sandbags(ctx, ctx:GroundCF(100, -300, 0), { length = 9, arc = 50 })
	Props.Wreck(ctx, ctx:GroundCF(40, -244, 80), { kind = "truck", burning = true })
	Props.Wreck(ctx, ctx:GroundCF(150, -250, -60), { kind = "tank", noTurret = true })
	Props.Cart(ctx, ctx:GroundCF(14, -228, 40), { broken = true })
	Buildings.StoneHouse(
		ctx,
		ctx:GroundCF(130, -150, 0),
		{ enterable = true, floors = 2, ruin = 0.35, name = "Casello" }
	)
	for _ = 1, 10 do
		local t = rng:NextNumber(0.05, 0.95)
		local x, z = Geo.sample(riverPath, t * riverPath.length)
		if math.abs(x - 80) > 40 then
			Nature.Rock(
				ctx,
				V(x + rng:NextNumber(-12, 12), z + rng:NextNumber(-10, 10)),
				rng:NextNumber(3, 6),
				M.Limestone
			)
		end
	end
	-- oleander scrub along the banks
	Layout.AlongPath(ctx, Layout.Offset(RIVERBED, 28), 34, function(cf)
		local p = cf.Position
		if not nearRoad(p.X, p.Z, 12) and rng:NextNumber() < 0.6 then
			Nature.Bush(ctx, p, rng:NextNumber(4, 7), nature)
		end
	end, { jitter = 8 })
	Layout.AlongPath(ctx, Layout.Offset(RIVERBED, -28), 34, function(cf)
		local p = cf.Position
		if not nearRoad(p.X, p.Z, 12) and rng:NextNumber() < 0.6 then
			Nature.Bush(ctx, p, rng:NextNumber(4, 7), nature)
		end
	end, { jitter = 8 })

	-------------------------------------------------------------------------------------------
	-- 4. A: Masseria — fortified farm among the vineyards
	-------------------------------------------------------------------------------------------
	Buildings.Farmhouse(
		ctx,
		ctx:GroundCF(-240, -420, 180),
		{ style = "Mediterranean", enterable = true, ruin = 0.2, name = "Masseria" }
	)
	Buildings.Barn(
		ctx,
		ctx:GroundCF(-180, -400, 90),
		{ style = "Mediterranean", width = 14, depth = 24, height = 10, ruin = 0.3 }
	)
	Buildings.Shed(ctx, ctx:GroundCF(-276, -460, 90), { style = "Mediterranean" })
	Props.StoneWall(
		ctx,
		{ V(-290, -470), V(-290, -385), V(-150, -380), V(-148, -470), V(-200, -476) },
		{ height = 3, gapChance = 0.12, material = M.Sandstone }
	)
	Props.Well(ctx, ctx:GroundCF(-214, -446, 0))
	Props.Cart(ctx, ctx:GroundCF(-200, -456, 70), {})
	Props.HayBales(ctx, ctx:GroundCF(-262, -400, 0))
	Props.BarrelGroup(ctx, ctx:GroundCF(-170, -440, 0))
	Fort.Sandbags(ctx, ctx:GroundCF(-226, -390, 0), { length = 10, arc = 50 })
	Props.AmmoCache(ctx, ctx:GroundCF(-236, -452, 0))
	Props.Wreck(ctx, ctx:GroundCF(-130, -500, 30), { kind = "halftrack" })
	local vines = ctx:Model("Vineyards", nature)
	for _, v in
		{
			{ -380, -460, 4, 120, 80 },
			{ -380, -340, -3, 110, 70 },
			{ -80, -390, 6, 90, 70 },
			{ 230, -420, -5, 140, 90 },
			{ 250, -560, 2, 140, 70 },
			{ -460, -580, 3, 120, 80 },
			{ 520, -360, 10, 100, 80 },
		}
	do
		if not nearRoad(v[1], v[2], 30) then
			vineyard(ctx, ctx:GroundCF(v[1], v[2], v[3]), v[4], v[5], vines)
		end
	end
	Buildings.Farmhouse(ctx, ctx:GroundCF(330, -480, -90), { style = "Mediterranean", ruin = 0.4 })
	Buildings.StoneHouse(ctx, ctx:GroundCF(-520, -470, 90), { enterable = false, floors = 1 })

	-------------------------------------------------------------------------------------------
	-- 5. D: Uliveto — olive terraces and farmhouse
	-------------------------------------------------------------------------------------------
	Buildings.Farmhouse(ctx, ctx:GroundCF(262, 318, 200), { style = "Mediterranean", enterable = true, ruin = 0.25 })
	Buildings.Barn(
		ctx,
		ctx:GroundCF(200, 330, 110),
		{ style = "Mediterranean", width = 13, depth = 22, height = 9, ruin = 0.5 }
	)
	Props.StoneWall(
		ctx,
		{ V(180, 270), V(200, 360), V(290, 360), V(300, 280) },
		{ height = 2.8, gapChance = 0.2, material = M.Sandstone }
	)
	Props.Well(ctx, ctx:GroundCF(236, 312, 0))
	Props.Cart(ctx, ctx:GroundCF(250, 278, 120), { broken = true })
	Fort.MGNest(ctx, ctx:GroundCF(222, 262, 180), {})
	Fort.Sandbags(ctx, ctx:GroundCF(270, 270, 200), { length = 8, arc = 50 })
	Fort.ATGun(ctx, ctx:GroundCF(286, 250, 210), {})
	Props.CrateStack(ctx, ctx:GroundCF(244, 336, 0))
	Props.Fire(ctx, V(206, 324), { size = 5 })
	local grove = ctx:Model("OliveGroves", nature)
	-- untended groves on the valley slopes (not terraced)
	for _, g in { { 300, -60, 150, 90 }, { -290, -150, 140, 70 }, { 470, 250, 110, 120 } } do
		for gx = g[1] - g[3] / 2, g[1] + g[3] / 2, 17 do
			for gz = g[2] - g[4] / 2, g[2] + g[4] / 2, 16 do
				local x, z = gx + rng:NextNumber(-4, 4), gz + rng:NextNumber(-4, 4)
				if
					rng:NextNumber() < 0.7
					and not nearRoad(x, z, 10)
					and not excluded(x, z)
					and not inRiverbed(x, z)
				then
					olive(ctx, x, z, rng:NextNumber(0.8, 1.15), grove)
				end
			end
		end
		ctx:AddMinimap("field", g[1], g[2], g[3], g[4], 0)
	end
	for _, t in TERRACES do
		local cx, cz, sx, sz = t[1], t[2], t[3], t[4]
		for gx = cx - sx / 2 + 8, cx + sx / 2 - 8, 15 do
			for gz = cz - sz / 2 + 8, cz + sz / 2 - 8, 14 do
				local x, z = gx + rng:NextNumber(-3, 3), gz + rng:NextNumber(-3, 3)
				if rng:NextNumber() < 0.6 and not nearRoad(x, z, 10) and not excluded(x, z) then
					olive(ctx, x, z, rng:NextNumber(0.85, 1.2), grove)
				end
			end
		end
		ctx:AddMinimap("field", cx, cz, sx, sz, 0)
	end

	-------------------------------------------------------------------------------------------
	-- 6. E: Castello — hilltop castle ruin
	-------------------------------------------------------------------------------------------
	local castle = ctx:Model("Castello", ctx:Folder("Buildings"))
	local cx, cz = CASTLE.x, CASTLE.z
	-- curtain wall: an irregular polygon with breaches (one is the gate on the road side)
	local ring = { { -46, -34 }, { 0, -46 }, { 44, -30 }, { 50, 20 }, { 18, 50 }, { -36, 44 }, { -52, 6 } }
	for i = 1, #ring do
		local a, b = ring[i], ring[i % #ring + 1]
		local ax, az, bx, bz = cx + a[1], cz + a[2], cx + b[1], cz + b[2]
		local len = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
		local mx, mz = (ax + bx) / 2, (az + bz) / 2
		local yaw = math.deg(math.atan2(-(bx - ax), -(bz - az))) + 90
		if i == 1 then
			-- gate breach: two stubs either side of a gap
			local ux, uz = (bx - ax) / len, (bz - az) / len
			for _, sgn in { -1, 1 } do
				local px, pz = mx + ux * sgn * (len / 4 + 4), mz + uz * sgn * (len / 4 + 4)
				Buildings.RuinedWall(
					ctx,
					ctx:GroundCF(px, pz, yaw),
					len / 2 - 8,
					11,
					{ style = castleStyle, windows = false, ruin = 0.45, parent = castle, thickness = 2.5 }
				)
			end
		else
			Buildings.RuinedWall(ctx, ctx:GroundCF(mx, mz, yaw), len, rng:NextNumber(9, 14), {
				style = castleStyle,
				windows = false,
				ruin = rng:NextNumber(0.35, 0.7),
				parent = castle,
				thickness = 2.5,
			})
		end
	end
	-- keep: a hollow ruined tower (walls with windows) and two corner tower stumps
	local keep = CFrame.new(cx + 6, 0, cz + 14)
	for k = 0, 3 do
		local rot = CFrame.Angles(0, k * math.pi / 2, 0)
		local wcf = keep * rot * CFrame.new(0, 0, -9)
		local p = wcf.Position
		Buildings.RuinedWall(
			ctx,
			ctx:GroundCF(p.X, p.Z, math.deg(k * math.pi / 2)),
			18,
			if k == 2 then 12 else 26,
			{ style = castleStyle, ruin = 0.35, parent = castle, thickness = 2 }
		)
	end
	for _, t in { { -46, -34 }, { 50, 20 } } do
		local tx, tz = cx + t[1], cz + t[2]
		local ty = ctx:GroundY(tx, tz)
		ctx:Part({
			Name = "TowerStump",
			Parent = castle,
			Shape = "Cylinder",
			Size = Vector3.new(rng:NextNumber(12, 18), 12, 12),
			CFrame = CFrame.new(tx, ty + 6, tz) * CFrame.Angles(0, 0, math.pi / 2),
			Material = M.Cobblestone,
			Color = rgb(178, 162, 134),
			Destructible = true,
			Health = 1500,
		})
	end
	ctx:AddMinimap("building", cx, cz, 100, 96, 0)
	Props.RubblePile(ctx, V(cx - 20, cz - 10), { radius = 6, height = 3, materials = { M.Sandstone, M.Limestone } })
	Props.RubblePile(ctx, V(cx + 30, cz - 6), { radius = 5, height = 2.5, materials = { M.Sandstone, M.Limestone } })
	Fort.Sandbags(ctx, ctx:GroundCF(cx - 8, cz - 28, 0), { length = 10, arc = 60 })
	Fort.MGNest(ctx, ctx:GroundCF(cx + 30, cz - 20, -20), {})
	Fort.MGNest(ctx, ctx:GroundCF(cx - 34, cz - 18, 20), {})
	Props.AmmoCache(ctx, ctx:GroundCF(cx - 12, cz + 30, 0))
	Props.CrateStack(ctx, ctx:GroundCF(cx + 24, cz + 30, 0))
	-- outer defences on the castle hill
	Fort.Trench(
		ctx,
		Layout.Zigzag({ V(-140, 420), V(-90, 405), V(-40, 412) }, 3, 12),
		{ parapet = "left", sandbags = 0.2 }
	)
	Fort.Trench(
		ctx,
		Layout.Zigzag({ V(90, 420), V(150, 412), V(200, 425) }, 3, 12),
		{ parapet = "left", sandbags = 0.2 }
	)
	Fort.Bunker(ctx, ctx:GroundCF(-120, 440, -15), { width = 12, depth = 10, slits = 2 })
	Fort.Bunker(ctx, ctx:GroundCF(170, 450, 20), { width = 12, depth = 10, slits = 2 })
	Fort.BarbedWire(ctx, { V(-170, 380), V(-90, 372), V(-20, 380) }, { spacing = 12 })
	Fort.BarbedWire(ctx, { V(100, 386), V(170, 378), V(230, 392) }, { spacing = 12 })
	Props.Wreck(ctx, ctx:GroundCF(-20, 380, 40), { kind = "halftrack", burning = true })
	-- umbrella pines on the castle hill and around the map
	for _, p in { { -90, 520 }, { 110, 540 }, { -160, 470 }, { 150, 500 }, { 60, 580 }, { -40, 590 } } do
		Nature.Tree(ctx, V(p[1], p[2]), "Pine", 1.1, nature)
	end

	-------------------------------------------------------------------------------------------
	-- 7. Countryside: farms, stone walls, cypress rows, scrub, craters
	-------------------------------------------------------------------------------------------
	Buildings.Farmhouse(ctx, ctx:GroundCF(-470, 230, 90), { style = "Mediterranean", ruin = 0.3 })
	Buildings.Farmhouse(ctx, ctx:GroundCF(520, 130, -90), { style = "Mediterranean", enterable = true })
	Buildings.StoneHouse(ctx, ctx:GroundCF(470, 420, 180), { enterable = false })
	-- Borgo San Vito: a roadside hamlet on the western route
	local borgo = ctx:Model("Borgo", ctx:Folder("Buildings"))
	for _, h in
		{
			{ -432, -120, 90, true },
			{ -450, -158, 90, false },
			{ -452, -84, 90, true },
			{ -380, -146, -90, true },
			{ -374, -92, -90, false },
			{ -470, -40, 0, false },
		}
	do
		Buildings.StoneHouse(
			ctx,
			ctx:GroundCF(h[1], h[2], h[3]),
			{ enterable = h[4], floors = if h[4] then 2 else 1, parent = borgo, ruin = rng:NextNumber(0, 0.4) }
		)
	end
	Props.Well(ctx, ctx:GroundCF(-396, -118, 0))
	Props.Cart(ctx, ctx:GroundCF(-392, -60, 20), {})
	Fort.Sandbags(ctx, ctx:GroundCF(-410, -180, 180), { length = 9, arc = 50 })
	Fort.MGNest(ctx, ctx:GroundCF(-440, -196, 180), {})
	Props.Signpost(ctx, ctx:GroundCF(-396, -190, 0))
	Buildings.Barn(ctx, ctx:GroundCF(-500, 260, 0), { style = "Mediterranean", width = 12, depth = 20, height = 9 })
	Props.StoneWall(
		ctx,
		{ V(-560, 180), V(-400, 190), V(-390, 300) },
		{ height = 2.6, gapChance = 0.15, material = M.Sandstone }
	)
	Props.StoneWall(
		ctx,
		{ V(440, 60), V(600, 70), V(610, 200) },
		{ height = 2.6, gapChance = 0.15, material = M.Sandstone }
	)
	Props.StoneWall(ctx, { V(30, -360), V(200, -350) }, { height = 2.6, gapChance = 0.2, material = M.Sandstone })
	Props.StoneWall(ctx, { V(-150, -320), V(-20, -330) }, { height = 2.6, gapChance = 0.2, material = M.Sandstone })
	-- cypress rows along the main road below the town and the castle road
	Layout.AlongPath(ctx, ROADS.main, 22, function(cf, i)
		local p = cf.Position
		if p.Z > -470 and p.Z < -200 and i % 2 == 0 and not excluded(p.X, p.Z) then
			Nature.Tree(ctx, p, "Poplar", rng:NextNumber(1, 1.2), nature)
		end
	end, { offset = 12 })
	Layout.AlongPath(ctx, ROADS.westNorth, 26, function(cf, i)
		local p = cf.Position
		if i % 3 ~= 0 and not excluded(p.X, p.Z) then
			Nature.Tree(ctx, p, "Poplar", rng:NextNumber(0.9, 1.2), nature)
		end
	end, { offset = -11 })
	-- pine stands on the flanks
	Nature.Forest(ctx, { center = V(-600, 480), size = Vector2.new(220, 200) }, {
		kinds = { "Pine", "Pine", "Oak" },
		spacing = 22,
		bushes = 0.3,
		filter = function(x, z)
			return not nearRoad(x, z, 12) and not excluded(x, z)
		end,
	})
	Nature.Forest(ctx, { center = V(600, 520), size = Vector2.new(220, 220) }, {
		kinds = { "Pine", "Oak" },
		spacing = 22,
		bushes = 0.3,
		filter = function(x, z)
			return not nearRoad(x, z, 12) and not excluded(x, z)
		end,
	})
	Nature.Forest(ctx, { center = V(620, -120), size = Vector2.new(180, 200) }, {
		kinds = { "Oak", "Pine" },
		spacing = 24,
		bushes = 0.3,
		filter = function(x, z)
			return not nearRoad(x, z, 12)
		end,
	})
	for _ = 1, 70 do
		local x, z = rng:NextNumber(-740, 740), rng:NextNumber(-720, 720)
		if
			not excluded(x, z)
			and not nearRoad(x, z, 10)
			and not inTerraces(x, z)
			and (Geo.distToPath(riverPath, x, z)) > 30
		then
			if rng:NextNumber() < 0.75 then
				Nature.Bush(ctx, V(x, z), rng:NextNumber(4, 7), nature)
			else
				Nature.Rock(ctx, V(x, z), rng:NextNumber(3, 6), M.Limestone)
			end
		end
	end
	local craters = 0
	for _ = 1, 120 do
		if craters >= 28 then
			break
		end
		local x, z = rng:NextNumber(-620, 620), rng:NextNumber(-560, 460)
		if
			not excluded(x, z)
			and not nearRoad(x, z, 12)
			and not inTerraces(x, z)
			and (Geo.distToPath(riverPath, x, z)) > 36
		then
			craters += 1
			Terrain.Crater(ctx, V(x, z), rng:NextNumber(4, 8), { material = M.Ground, outerMaterial = M.Ground })
		end
	end
	Props.Wreck(ctx, ctx:GroundCF(190, -100, 30), { kind = "tank" })
	-- Italian pillboxes covering the switchbacks
	Fort.Bunker(ctx, ctx:GroundCF(196, -110, 200), { width = 10, depth = 9, slits = 2 })
	Fort.Bunker(ctx, ctx:GroundCF(-70, -150, 160), { width = 10, depth = 9, slits = 2 })
	Fort.Barricade(ctx, ctx:GroundCF(90, -118, 80), { kind = "wood", length = 7 })
	Fort.Sandbags(ctx, ctx:GroundCF(40, -70, 180), { length = 9, arc = 50 })
	Props.Wreck(ctx, ctx:GroundCF(-120, 250, -40), { kind = "truck" })
	Props.Wreck(ctx, ctx:GroundCF(360, -120, 80), { kind = "tank", noTurret = true })
	Props.Wreck(ctx, ctx:GroundCF(-380, -300, 10), { kind = "car" })
	Props.TelegraphLine(ctx, Layout.Offset(ROADS.east, 10), { leanChance = 0.25, downChance = 0.08 })

	-------------------------------------------------------------------------------------------
	-- 8. HQs, objectives, MapInfo
	-------------------------------------------------------------------------------------------
	local alliesHQ = Layout.SpawnArea(ctx, HQ_ALLIES, "Allies", { spawnCount = 10, vehicleCount = 6 })
	local axisHQ = Layout.SpawnArea(ctx, HQ_AXIS, "Axis", { spawnCount = 10, vehicleCount = 6 })

	local objectives = {}
	for i, o in OBJECTIVES do
		table.insert(
			objectives,
			Layout.CapturePoint(ctx, {
				id = o.id,
				name = o.name,
				position = o.pos,
				flagPosition = o.flag,
				radius = o.radius,
				order = i,
				initialOwner = o.owner,
			})
		)
	end

	local function vehicles(list: { CFrame }, classes: { string })
		local out = {}
		for i, cf in list do
			table.insert(out, { cframe = cf, class = classes[i] or "Jeep" })
		end
		return out
	end

	return MapKit.Finish(ctx, {
		id = "Sicily",
		bounds = { center = Vector3.new(0, 70, 0), size = Vector3.new(SIZE, 700, SIZE) },
		hq = { Allies = alliesHQ.spawns, Axis = axisHQ.spawns },
		objectives = objectives,
		vehicleSpawns = {
			Allies = vehicles(alliesHQ.vehicles, { "Tank", "Tank", "Light", "Transport", "Jeep", "Jeep" }),
			Axis = vehicles(axisHQ.vehicles, { "Tank", "Tank", "Light", "Transport", "Jeep", "AT" }),
		},
		outOfBounds = 10,
	})
end

return Sicily
