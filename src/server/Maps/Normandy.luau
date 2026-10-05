--[[
	Normandy — "Saint-Laurent" (≈1400 x 1400 studs). Map team.

	A Norman village in bocage country. Allies attack from the south, the Axis holds the river line
	and the ridge battery to the north.

	   z=+700 ┌───────────────────────────────────────────────────────────────┐
	          │                     [AXIS HQ] (0,615)                         │
	          │   forest            ridge crest  ─ wire ─ E Batterie (205,415)│
	          │        D Pont de Pierre (-240,300)    bunkers/trench/AT gun   │
	          │~~~~~~~~~~~~~~~ river ~~~~~~~=bridge=~~~~~~~~~ ford ~~~~~ foot~│
	          │  bocage   ╔═church═╗                                          │
	          │  ════W════╣C square╠════E════════════════════════════════     │
	          │  fields   ╚════════╝   houses        ┼ B Ferme Dupont(235,-225)│
	          │  A Le Verger (-250,-345) orchards     bocage lanes             │
	          │              ridge  [ALLIED HQ] (0,-610)                       │
	   z=-700 └───────────────────────────────────────────────────────────────┘
	           x=-700                                                 x=+700

	Objectives (order 1 = Allied end): A Le Verger (orchard farm), B Ferme Dupont (crossroads farm),
	C Place de l'Église (church square, centre, church tower sniper perch), D Pont de Pierre
	(stone bridge, north bank houses), E Batterie (bunkers & trenches on the ridge).
	Routes: main road (C <-> D via the stone bridge), the ford road (B/C <-> E), a footbridge east,
	bocage lanes on both flanks. HQs sit behind earth berms on reverse slopes (no spawn sightlines).
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
local V = function(x: number, z: number): Vector3
	return Vector3.new(x, 0, z)
end

local Normandy = {}

local SIZE = 1400
local SEED = 1944

-- Layout data -------------------------------------------------------------------------------------

local RIVER = {
	V(-780, 255),
	V(-520, 232),
	V(-330, 246),
	V(-240, 247),
	V(-120, 226),
	V(30, 205),
	V(150, 190),
	V(300, 176),
	V(480, 190),
	V(780, 168),
}

local ROADS = {
	mainSouth = { V(0, -760), V(0, -600), V(15, -470), V(20, -380), V(8, -250), V(0, -140), V(0, -15) },
	west = { V(-760, -30), V(-450, -25), V(-260, -12), V(-160, -4), V(-35, 0) },
	east = { V(35, 0), V(150, 0), V(320, -8), V(500, -25), V(760, -40) },
	bridgeSouth = { V(-160, -4), V(-185, 90), V(-225, 190), V(-240, 222) },
	bridgeNorth = { V(-240, 272), V(-228, 330), V(-150, 430), V(-60, 540), V(0, 640), V(0, 760) },
	ford = { V(150, 0), V(150, 120), V(150, 190), V(165, 300), V(195, 380), V(192, 470), V(110, 570), V(30, 620) },
	laneB = { V(40, -575), V(120, -430), V(200, -300), V(230, -220), V(225, -120), V(180, -50), V(150, 0) },
	trackB = { V(230, -220), V(400, -232), V(650, -262), V(760, -270) },
	laneA = { V(12, -300), V(-150, -330), V(-260, -360), V(-500, -385), V(-760, -395) },
	laneNorth = { V(480, 190), V(500, 320), V(420, 480), V(150, 560) },
}

local VILLAGE = { cx = 0, cz = 10, sx = 420, sz = 270 }
local HQ_ALLIES = CFrame.new(0, 0, -615) * CFrame.Angles(0, math.pi, 0) -- faces north (+Z)
local HQ_AXIS = CFrame.new(0, 0, 620) -- faces south (-Z)

local OBJECTIVES = {
	{ id = "A", name = "Le Verger", pos = V(-250, -348), radius = 30, owner = "Allies" },
	{ id = "B", name = "Ferme Dupont", pos = V(240, -228), radius = 30, owner = "Neutral", flag = V(246, -236) },
	{ id = "C", name = "Place de l'Église", pos = V(0, 10), radius = 32, owner = "Neutral" },
	{ id = "D", name = "Pont de Pierre", pos = V(-238, 302), radius = 28, owner = "Neutral", flag = V(-250, 300) },
	{ id = "E", name = "Batterie", pos = V(205, 418), radius = 34, owner = "Axis", flag = V(214, 445) },
}

-- Helpers -----------------------------------------------------------------------------------------

local preparedRoads: { any } = {}
local preparedRiver = Geo.path(RIVER)

local function nearRoad(x: number, z: number, margin: number): boolean
	for _, p in preparedRoads do
		if (Geo.distToPath(p, x, z)) < margin then
			return true
		end
	end
	return false
end

local function inVillage(x: number, z: number, pad: number?): boolean
	return Geo.inRect(x, z, VILLAGE.cx, VILLAGE.cz, VILLAGE.sx + (pad or 0), VILLAGE.sz + (pad or 0), 0)
end

local EXCLUDE = {
	{ -255, -320, 95 }, -- A farm
	{ 245, -225, 85 }, -- B farm
	{ 205, 430, 120 }, -- E battery
	{ -240, 290, 70 }, -- D bridgehead
	{ 0, -615, 130 }, -- HQs
	{ 0, 620, 130 },
}

local function excluded(x: number, z: number): boolean
	for _, e in EXCLUDE do
		if (x - e[1]) ^ 2 + (z - e[2]) ^ 2 < e[3] * e[3] then
			return true
		end
	end
	return inVillage(x, z, 40) or (Geo.distToPath(preparedRiver, x, z)) < 40
end

-- Builder -----------------------------------------------------------------------------------------

function Normandy.Build(parent: Folder, _def: any)
	local ctx = MapKit.new(parent, { seed = SEED })
	local rng = ctx.rng
	table.clear(preparedRoads)
	for _, r in ROADS do
		table.insert(preparedRoads, Geo.path(r))
	end

	Terrain.ApplyPalette({
		Grass = Color3.fromRGB(88, 110, 58),
		LeafyGrass = Color3.fromRGB(78, 98, 52),
		Ground = Color3.fromRGB(98, 84, 62),
		Mud = Color3.fromRGB(72, 60, 46),
	}, { color = Color3.fromRGB(56, 74, 66), decoration = true })

	-------------------------------------------------------------------------------------------
	-- 1. Terrain model
	-------------------------------------------------------------------------------------------
	local hm = Terrain.HeightModel({ baseY = 2, seed = SEED })
	hm:Noise(6, 260, 3)
	hm:Noise(2, 70, 2)
	-- Frame the map with higher ground beyond the bounds
	hm:Custom(function(x, z, h)
		local e = math.max(math.abs(x), math.abs(z))
		return h + Geo.smoothstep(690, 880, e) * 45
	end)
	hm:Ridge({ V(-800, 440), V(-300, 412), V(150, 425), V(800, 432) }, 300, 20) -- Axis ridge
	hm:Ridge({ V(-800, -505), V(-200, -522), V(200, -512), V(800, -500) }, 150, 9) -- Allied reverse slope
	hm:Hill(-520, -120, 120, 10)
	hm:Hill(520, 60, 140, 12)
	-- keep the river valley above water level outside the channel
	hm:Custom(function(x, z, h)
		local d = Geo.distToPath(preparedRiver, x, z)
		if d > 90 then
			return h
		end
		return math.max(h, Geo.lerp(1.5, h, Geo.smoothstep(40, 90, d)))
	end)
	hm:River(RIVER, { width = 26, bank = 18, bedY = -8, waterY = -3.5 })
	hm:FlattenRect(VILLAGE.cx, VILLAGE.cz, VILLAGE.sx, VILLAGE.sz, 0, 2.5, 45)
	hm:Flatten(255, -225, 70, nil, 30)
	hm:Flatten(-255, -330, 70, nil, 30)
	hm:Flatten(205, 425, 80, nil, 40)
	Layout.PrepareHQ(hm, HQ_ALLIES)
	Layout.PrepareHQ(hm, HQ_AXIS)
	for name, r in ROADS do
		hm:Road(r, if name:sub(1, 4) == "lane" or name == "trackB" then 9 else 13, 8)
	end
	hm:Flatten(150, 190, 14, -4.6, 12) -- the ford: knee-deep crossing

	local mm = Terrain.MaterialModel({ base = M.Grass, subsurface = M.Ground, seed = SEED })
	mm:Patches(M.LeafyGrass, 90, 0.05)
	mm:Patches(M.Ground, 35, 0.62)

	-- Bocage grid (planned now so the fields can be painted into the terrain)
	local cell = { w = 128, d = 104 }
	local corners = {}
	local x0, z0 = -640, -580
	local nx, nz = 10, 8
	for i = 0, nx do
		corners[i] = {}
		for j = 0, nz do
			corners[i][j] = V(x0 + i * cell.w + rng:NextNumber(-18, 18), z0 + j * cell.d + rng:NextNumber(-16, 16))
		end
	end
	local function cornerOk(p: Vector3): boolean
		return not excluded(p.X, p.Z) and math.abs(p.X) < 680 and math.abs(p.Z) < 680
	end
	local fieldMats = { M.Grass, M.LeafyGrass, M.Ground, M.Grass, M.LeafyGrass }
	local fieldCells = {}
	for i = 0, nx - 1 do
		for j = 0, nz - 1 do
			local c = (corners[i][j] + corners[i + 1][j + 1]) / 2
			if not excluded(c.X, c.Z) and not inVillage(c.X, c.Z, 80) then
				local mat = fieldMats[rng:NextInteger(1, #fieldMats)]
				mm:Rect(c.X, c.Z, cell.w - 14, cell.d - 14, rng:NextNumber(-6, 6), mat, 4)
				table.insert(fieldCells, { c = c, mat = mat })
			end
		end
	end

	mm:Below(-1.2, M.Mud)
	mm:Slope(M.Rock, 1.0)
	for name, r in ROADS do
		local lane = name:sub(1, 4) == "lane" or name == "trackB"
		mm:Path(r, if lane then 7 else 10, M.Ground, 1.5)
	end
	-- Cobbled village streets and square
	mm:Path({ V(0, -150), V(0, -15) }, 12, M.Cobblestone)
	mm:Path({ V(-205, -8), V(-35, 0) }, 12, M.Cobblestone)
	mm:Path({ V(35, 0), V(170, 0) }, 12, M.Cobblestone)
	mm:Rect(0, 10, 72, 52, 0, M.Cobblestone)
	mm:Rect(0, 72, 60, 76, 0, M.LeafyGrass) -- churchyard
	mm:Rect(HQ_ALLIES.Position.X, HQ_ALLIES.Position.Z, 140, 100, 0, M.Ground, 6)
	mm:Rect(HQ_AXIS.Position.X, HQ_AXIS.Position.Z, 140, 100, 0, M.Ground, 6)
	mm:Circle(255, -225, 40, M.Mud, 6)
	mm:Circle(-255, -330, 32, M.Ground, 6)

	Terrain.Generate(ctx, hm, mm, { center = Vector3.zero, size = Vector2.new(1840, 1840) })

	for _, r in ROADS do
		ctx:AddMinimapPath("road", r, 10)
	end
	ctx:AddMinimapPath("water", RIVER, 30)

	-------------------------------------------------------------------------------------------
	-- 2. Village of Saint-Laurent (objective C)
	-------------------------------------------------------------------------------------------
	local function house(x: number, z: number, yaw: number, opts: { [string]: any })
		return Buildings.House(ctx, ctx:GroundCF(x, z, yaw), opts)
	end
	local styles = { "Norman", "Norman", "NormanStone", "Brick" }
	local function vopts(enterable: boolean, ruin: number, extra: { [string]: any }?)
		local o = {
			style = styles[rng:NextInteger(1, #styles)],
			enterable = enterable,
			ruin = ruin,
			floors = if rng:NextNumber() < 0.6 then 2 else 3,
			width = rng:NextNumber(18, 22),
			depth = rng:NextNumber(13, 15),
		}
		if extra then
			for k, v in extra do
				o[k] = v
			end
		end
		return o
	end

	-- Church on the north side of the square (tower = sniper perch)
	Buildings.Church(ctx, ctx:GroundCF(0, 70, 0), { width = 24, length = 52, towerH = 48, ruin = 0.3 })
	Props.StoneWall(ctx, { V(-11, 34), V(-30, 34), V(-30, 112), V(30, 112), V(30, 34), V(11, 34) }, { height = 3.2 })
	for _ = 1, 8 do -- gravestones
		local gx, gz = rng:NextNumber(-26, -16) * (if rng:NextNumber() < 0.5 then 1 else -1), rng:NextNumber(48, 104)
		ctx:Part({
			Name = "Gravestone",
			Parent = ctx:Folder("Props"),
			Size = Vector3.new(1.8, 2.6, 0.5),
			CFrame = ctx:GroundCF(gx, gz, rng:NextNumber(-10, 10)) * CFrame.new(0, 1.1, 0),
			Material = M.Limestone,
			Color = Color3.fromRGB(150, 146, 138),
			Destructible = true,
		})
	end

	-- South street (main road)
	house(-19, -95, -90, vopts(true, 0))
	house(-19, -70, -90, vopts(false, 0.2))
	house(-19, -45, -90, vopts(true, 0.75))
	house(19, -100, 90, vopts(false, 0))
	house(19, -75, 90, vopts(true, 0.35))
	house(19, -48, 90, vopts(true, 0))
	-- West street
	house(-62, 19, 0, vopts(true, 0.2))
	house(-88, 19, 0, vopts(false, 0.85))
	house(-116, 19, 0, vopts(true, 0))
	house(-142, 19, 0, vopts(false, 0.4))
	house(-60, -19, 180, vopts(true, 0))
	house(-85, -19, 180, vopts(false, 0))
	house(-110, -19, 180, vopts(true, 0.6))
	house(-135, -19, 180, vopts(false, 0))
	-- East street
	house(58, 19, 0, vopts(true, 0))
	house(84, 19, 0, vopts(true, 0.9))
	house(110, 19, 0, vopts(false, 0.2))
	house(60, -19, 180, vopts(false, 0))
	house(86, -19, 180, vopts(true, 0.5))
	house(112, -19, 180, vopts(false, 0))
	-- Café and Mairie flanking the church
	house(-52, 52, 0, vopts(true, 0.15, { width = 20, depth = 14, floors = 2, name = "Cafe" }))
	house(55, 52, 0, vopts(true, 0, { style = "Brick", floors = 3, width = 22, depth = 15, name = "Mairie" }))
	-- Gardens & sheds behind the houses
	for _, s in { { -40, -70, 90 }, { 40, -90, -90 }, { -88, -42, 0 }, { 84, 42, 180 }, { -130, 44, 180 } } do
		Buildings.Shed(ctx, ctx:GroundCF(s[1], s[2], s[3]), { ruin = rng:NextNumber(0, 0.6) })
	end
	Props.StoneWall(ctx, { V(-34, -110), V(-34, -30) }, { height = 2.6 })
	Props.StoneWall(ctx, { V(34, -112), V(34, -30) }, { height = 2.6 })
	Props.StoneWall(ctx, { V(-150, -34), V(-50, -34) }, { height = 2.6, gapChance = 0.15 })
	Props.StoneWall(ctx, { V(48, 34), V(125, 34) }, { height = 2.6, gapChance = 0.15 })

	-- Square dressing: barricades, wreck, sandbags, lamp posts
	local props = ctx:Folder("Props")
	Props.Wreck(ctx, ctx:GroundCF(18, 26, 160), { kind = "truck", burning = true })
	Fort.Barricade(ctx, ctx:GroundCF(-26, -2, 90), { kind = "debris", length = 9 })
	Fort.Barricade(ctx, ctx:GroundCF(26, -6, -90), { kind = "wood", length = 8 })
	Fort.Sandbags(ctx, ctx:GroundCF(-12, -10, 180), { length = 9, arc = 60 })
	Fort.Sandbags(ctx, ctx:GroundCF(12, 22, 0), { length = 9, arc = 60 })
	Props.CrateStack(ctx, ctx:GroundCF(-20, 24, 0))
	Props.Cart(ctx, ctx:GroundCF(24, -12, 30), { broken = true })
	for _, l in
		{ { -32, -14 }, { 32, -14 }, { -32, 32 }, { 32, 32 }, { -8, -60 }, { 8, -120 }, { -100, -8 }, { 100, 8 } }
	do
		Props.LampPost(ctx, ctx:GroundCF(l[1], l[2], 0), { parent = props })
	end
	Props.Bench(ctx, ctx:GroundCF(-28, 10, -90))
	Props.Fire(ctx, V(-88, 14), { size = 5 })
	Props.RubblePile(ctx, V(-24, -48), { radius = 6, height = 3 })
	Props.RubblePile(ctx, V(86, 12), { radius = 7, height = 3.5 })
	Props.Signpost(ctx, ctx:GroundCF(-6, -150, 0))
	Props.TelegraphLine(ctx, Layout.Offset(ROADS.mainSouth, 11), { leanChance = 0.3, downChance = 0.08 })
	Props.TelegraphLine(ctx, Layout.Offset({ V(40, 8), V(320, 0), V(700, -32) }, 11), { leanChance = 0.3 })

	-------------------------------------------------------------------------------------------
	-- 3. Farms: A Le Verger (orchard farm) and B Ferme Dupont (crossroads)
	-------------------------------------------------------------------------------------------
	-- A
	Buildings.Farmhouse(ctx, ctx:GroundCF(-280, -335, 0), { ruin = 0.25, enterable = true })
	Buildings.Barn(ctx, ctx:GroundCF(-225, -320, 90), { ruin = 0.15 })
	Nature.Orchard(ctx, ctx:GroundCF(-270, -268, 3), { rows = 4, cols = 7, spacing = 14 })
	Nature.Orchard(ctx, ctx:GroundCF(-345, -425, -4), { rows = 3, cols = 6, spacing = 15 })
	Props.Well(ctx, ctx:GroundCF(-248, -335, 0))
	Props.Cart(ctx, ctx:GroundCF(-262, -312, 70))
	Props.Haystack(ctx, V(-200, -290))
	Props.Haystack(ctx, V(-188, -300))
	Props.HayBales(ctx, ctx:GroundCF(-215, -350, 20))
	Props.StoneWall(ctx, { V(-310, -352), V(-310, -305), V(-200, -300), V(-196, -345) }, { height = 3 })
	Fort.Sandbags(ctx, ctx:GroundCF(-245, -300, 180), { length = 10, arc = 50 })
	Fort.Foxhole(ctx, ctx:GroundCF(-300, -296, 180))
	Fort.Foxhole(ctx, ctx:GroundCF(-212, -282, 180))
	Props.AmmoCache(ctx, ctx:GroundCF(-238, -350, 0))

	-- B
	Buildings.Farmhouse(ctx, ctx:GroundCF(262, -195, 90), { ruin = 0.45, enterable = true })
	Buildings.Barn(ctx, ctx:GroundCF(280, -262, 0), { ruin = 0.35 })
	Buildings.Shed(ctx, ctx:GroundCF(205, -250, -90), {})
	Buildings.Hut(ctx, ctx:GroundCF(205, -180, -90), { style = "Farm", width = 12, depth = 9, ruin = 0.3 })
	Nature.Orchard(ctx, ctx:GroundCF(150, -255, 0), { rows = 3, cols = 4, spacing = 14 })
	Props.Well(ctx, ctx:GroundCF(250, -238, 0))
	Props.Cart(ctx, ctx:GroundCF(268, -228, 120), { broken = true })
	Props.HayBales(ctx, ctx:GroundCF(300, -215, 90))
	Props.Haystack(ctx, V(318, -290))
	Props.Haystack(ctx, V(305, -305))
	Props.StoneWall(ctx, { V(242, -170), V(300, -168), V(304, -290), V(250, -292) }, { height = 3, gapChance = 0.12 })
	Fort.Sandbags(ctx, ctx:GroundCF(232, -205, 0), { length = 8, arc = 40 })
	Fort.MGNest(ctx, ctx:GroundCF(222, -168, 0), {})
	Props.Wreck(ctx, ctx:GroundCF(212, -300, 25), { kind = "halftrack" })
	Props.Fire(ctx, V(270, -255), { size = 5 })

	-------------------------------------------------------------------------------------------
	-- 4. River line: stone bridge (D), mill, ford, footbridge, German bank positions
	-------------------------------------------------------------------------------------------
	Props.StoneBridge(ctx, V(-240, 222), V(-240, 272), { width = 15, arches = 2, damaged = true })
	Buildings.Farmhouse(ctx, ctx:GroundCF(-292, 204, 180), { name = "Moulin", ruin = 0.2, width = 22 })
	house(-205, 300, 90, vopts(true, 0.3, { floors = 2 }))
	house(-262, 305, -90, vopts(true, 0.1, { floors = 2 }))
	house(-268, 342, -90, vopts(false, 0.7))
	Buildings.Barn(ctx, ctx:GroundCF(-195, 350, 0), { ruin = 0.5 })
	Fort.MGNest(ctx, ctx:GroundCF(-254, 280, 0), {})
	Fort.Sandbags(ctx, ctx:GroundCF(-228, 282, 0), { length = 7, courses = 2 })
	Fort.ATGun(ctx, ctx:GroundCF(-192, 328, 10), {})
	Props.Wreck(ctx, ctx:GroundCF(-226, 318, 200), { kind = "halftrack", burning = true })
	Fort.Trench(
		ctx,
		Layout.Zigzag({ V(-160, 302), V(-60, 285), V(60, 262) }, 3.5, 14),
		{ parapet = "left", sandbags = 0.3 }
	)
	Fort.Trench(ctx, Layout.Zigzag({ V(-430, 300), V(-300, 298) }, 3, 14), { parapet = "left" })
	Fort.TankTraps(ctx, { V(120, 232), V(185, 226) }, { kind = "hedgehog", spacing = 10 })
	Fort.BarbedWire(ctx, { V(-120, 270), V(0, 252), V(110, 232) }, {})
	Props.WoodBridge(ctx, V(380, 162), V(380, 214), { width = 6 })
	Fort.Foxhole(ctx, ctx:GroundCF(360, 240, 0))
	Fort.Foxhole(ctx, ctx:GroundCF(405, 236, 0))
	-- poplar rows along the south bank
	Layout.AlongPath(ctx, Layout.Offset(RIVER, -46), 26, function(cf)
		local p = cf.Position
		if not inVillage(p.X, p.Z, 20) and not nearRoad(p.X, p.Z, 12) and rng:NextNumber() < 0.55 then
			Nature.Tree(ctx, p, if rng:NextNumber() < 0.6 then "Poplar" else "Oak", 1)
		end
	end, { jitter = 6 })

	-------------------------------------------------------------------------------------------
	-- 5. E Batterie: German strongpoint on the ridge
	-------------------------------------------------------------------------------------------
	Fort.Bunker(ctx, ctx:GroundCF(148, 398, 0), { width = 16, depth = 12, slits = 3 })
	Fort.Bunker(ctx, ctx:GroundCF(262, 408, -8), { width = 14, depth = 12, slits = 2 })
	Fort.Trench(ctx, Layout.Zigzag({ V(40, 428), V(178, 434) }, 3.5, 13), { parapet = "left", sandbags = 0.25 })
	Fort.Trench(ctx, Layout.Zigzag({ V(208, 436), V(362, 442) }, 3.5, 13), { parapet = "left", sandbags = 0.25 })
	Fort.MGNest(ctx, ctx:GroundCF(100, 384, 0), {})
	Fort.MGNest(ctx, ctx:GroundCF(322, 390, 0), {})
	Fort.ATGun(ctx, ctx:GroundCF(226, 384, 0), {})
	Fort.BarbedWire(ctx, { V(40, 345), V(170, 348) }, {})
	Fort.BarbedWire(ctx, { V(206, 349), V(380, 354) }, {})
	Fort.TankTraps(ctx, { V(60, 360), V(160, 362) }, { kind = "teeth", spacing = 9 })
	Fort.TankTraps(ctx, { V(225, 364), V(340, 368) }, { kind = "teeth", spacing = 9 })
	Fort.Watchtower(ctx, ctx:GroundCF(232, 468, 0), { height = 14 })
	Buildings.Farmhouse(ctx, ctx:GroundCF(150, 472, 0), { ruin = 0.55, name = "BatteryFarm" })
	Props.Tent(ctx, ctx:GroundCF(270, 470, 0))
	Props.AmmoCache(ctx, ctx:GroundCF(205, 452, 0))
	Props.CrateStack(ctx, ctx:GroundCF(250, 448, 0))
	Props.BarrelGroup(ctx, ctx:GroundCF(120, 450, 0))
	Props.Fire(ctx, V(150, 465), { size = 4 })

	-------------------------------------------------------------------------------------------
	-- 6. Bocage hedgerows, fields, woods
	-------------------------------------------------------------------------------------------
	local function skipHedge(x: number, z: number): boolean
		return nearRoad(x, z, 11) or excluded(x, z)
	end
	for i = 0, nx do
		for j = 0, nz do
			local a = corners[i][j]
			if i < nx and rng:NextNumber() < 0.72 and cornerOk(a) and cornerOk(corners[i + 1][j]) then
				Nature.Hedgerow(ctx, { a, corners[i + 1][j] }, { skip = skipHedge, treeChance = 0.1 })
			end
			if j < nz and rng:NextNumber() < 0.72 and cornerOk(a) and cornerOk(corners[i][j + 1]) then
				Nature.Hedgerow(ctx, { a, corners[i][j + 1] }, { skip = skipHedge, treeChance = 0.1 })
			end
		end
	end
	local wheat = 0
	for _, f in fieldCells do
		local c = f.c
		ctx:AddMinimap("field", c.X, c.Z, cell.w - 14, cell.d - 14, 0)
		local roll = rng:NextNumber()
		if f.mat == M.Ground and wheat < 4 and not nearRoad(c.X, c.Z, 50) then
			wheat += 1
			Nature.WheatField(
				ctx,
				ctx:GroundCF(c.X, c.Z, rng:NextNumber(-5, 5)),
				cell.w - 34,
				cell.d - 34,
				{ minimap = false }
			)
		elseif roll < 0.3 then
			for _ = 1, rng:NextInteger(2, 4) do
				Props.Haystack(ctx, c + V(rng:NextNumber(-35, 35), rng:NextNumber(-25, 25)))
			end
		elseif roll < 0.45 then
			Props.HayBales(ctx, ctx:GroundCF(c.X + rng:NextNumber(-20, 20), c.Z, rng:NextNumber(0, 180)))
		end
	end
	Nature.Forest(ctx, { center = V(-560, 130), size = Vector2.new(210, 170) }, {
		kinds = { "Oak", "Oak", "Birch", "Poplar" },
		spacing = 19,
		filter = function(x, z)
			return not nearRoad(x, z, 12)
		end,
	})
	Nature.Forest(ctx, { center = V(560, 330), size = Vector2.new(220, 150), rot = 8 }, {
		kinds = { "Oak", "Pine", "Birch" },
		spacing = 19,
	})
	Nature.Forest(
		ctx,
		{ center = V(-470, 470), size = Vector2.new(200, 120) },
		{ kinds = { "Pine", "Fir", "Oak" }, spacing = 20 }
	)
	Nature.Orchard(ctx, ctx:GroundCF(-150, -95, 0), { rows = 3, cols = 5, spacing = 14 })
	Nature.Orchard(ctx, ctx:GroundCF(165, 95, 5), { rows = 3, cols = 4, spacing = 14 })
	for _ = 1, 30 do
		local x, z = rng:NextNumber(-660, 660), rng:NextNumber(-560, 560)
		if not excluded(x, z) and not nearRoad(x, z, 10) and not inVillage(x, z, 30) then
			Nature.Bush(ctx, V(x, z))
		end
	end

	-------------------------------------------------------------------------------------------
	-- 7. Battle damage: craters and wrecks in the fields
	-------------------------------------------------------------------------------------------
	local craters = 0
	for _ = 1, 120 do
		if craters >= 34 then
			break
		end
		local x, z = rng:NextNumber(-600, 600), rng:NextNumber(-470, 380)
		if not excluded(x, z) and not nearRoad(x, z, 14) and not inVillage(x, z, -40) then
			craters += 1
			Terrain.Crater(ctx, V(x, z), rng:NextNumber(4, 8), {})
		end
	end
	Props.Wreck(ctx, ctx:GroundCF(-40, -205, 35), { kind = "tank" })
	Props.Wreck(ctx, ctx:GroundCF(95, -330, -60), { kind = "tank", noTurret = true })
	Props.Wreck(ctx, ctx:GroundCF(-120, 120, 80), { kind = "truck" })
	Props.Wreck(ctx, ctx:GroundCF(340, 80, 10), { kind = "car" })

	-------------------------------------------------------------------------------------------
	-- 8. HQs, objectives, MapInfo
	-------------------------------------------------------------------------------------------
	local alliesHQ = Layout.SpawnArea(ctx, HQ_ALLIES, "Allies", { spawnCount = 10, vehicleCount = 6 })
	local axisHQ = Layout.SpawnArea(ctx, HQ_AXIS, "Axis", { spawnCount = 10, vehicleCount = 6 })
	-- extra cover between the HQ berms and the battlefield
	Nature.Hedgerow(ctx, { V(-150, -540), V(-40, -548) }, {})
	Nature.Hedgerow(ctx, { V(40, -548), V(150, -540) }, {})
	Nature.Hedgerow(ctx, { V(-150, 548), V(-40, 556) }, {})
	Nature.Hedgerow(ctx, { V(40, 556), V(150, 548) }, {})

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

	local classes = { "Tank", "Jeep", "Transport", "Light", "Tank", "Jeep" }
	local function vehicles(list: { CFrame })
		local out = {}
		for i, cf in list do
			table.insert(out, { cframe = cf, class = classes[i] or "Jeep" })
		end
		return out
	end

	return MapKit.Finish(ctx, {
		id = "Normandy",
		bounds = { center = Vector3.new(0, 60, 0), size = Vector3.new(SIZE, 700, SIZE) },
		hq = { Allies = alliesHQ.spawns, Axis = axisHQ.spawns },
		objectives = objectives,
		vehicleSpawns = { Allies = vehicles(alliesHQ.vehicles), Axis = vehicles(axisHQ.vehicles) },
		outOfBounds = 10,
	})
end

return Normandy
