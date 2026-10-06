--[[
	Kursk — "Prokhorovka Fields" (≈2000 x 2000 studs). Map team. Tank country.

	Rolling wheat steppe. The Soviets (Allies) hold the northern ridge behind trench lines and an
	anti-tank ditch; the Germans (Axis) attack from the south. Long sightlines for armour, while
	infantry move through the trenches, the two balkas (gullies) and along the railway embankment.

	   z=+1000 ┌───────────────────────────────────────────────────────────────────┐
	           │                       [ALLIED HQ] (0,880)                    rail │
	           │  balka   A Kolkhoz Trenches (-260,540)  bunkers               /   │
	           │   |      ~~~~~ Soviet fire trench + wire (z≈420) ~~~~~       /    │
	           │   |  ═══AT ditch═══ gap ═════════ gap ═══════════ gap ══/═══     │
	           │   |                                       B Railway Halt (430,255)│
	           │   |  wheat           C Hill 252.2 (0,-20)          /     balka   │
	           │   |               (ruined windmill, craters)      /        |     │
	           │   |  D Burning Kolkhoz (-420,-280)               /         |     │
	           │   |                                             /   E Sovkhoz Gully│
	           │                                                    (280,-560)      │
	           │                       [AXIS HQ] (0,-880)                          │
	   z=-1000 └───────────────────────────────────────────────────────────────────┘

	Objectives (order 1 = Allied end): A Kolkhoz Trenches, B Railway Halt, C Hill 252.2 (centre,
	dominant height), D Burning Kolkhoz (village), E Sovkhoz Gully (German forward base).
	Three roads cross the AT ditch through gaps; the railway embankment is a long cover line.
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

local Kursk = {}

local SIZE = 2000
local SEED = 1943

local HQ_ALLIES = CFrame.new(0, 0, 885) -- faces south (-Z)
local HQ_AXIS = CFrame.new(0, 0, -885) * CFrame.Angles(0, math.pi, 0) -- faces north (+Z)

local RAILWAY = { V(1100, 760), V(700, 470), V(420, 268), V(220, 80), V(80, -240), V(-40, -620), V(-130, -1100) }
local ROADS = {
	west = {
		V(0, 960),
		V(-80, 700),
		V(-220, 590),
		V(-430, 460),
		V(-560, 340),
		V(-520, 100),
		V(-450, -150),
		V(-430, -280),
		V(-300, -500),
		V(-120, -760),
		V(0, -960),
	},
	central = {
		V(0, 960),
		V(40, 600),
		V(60, 340),
		V(40, 150),
		V(170, -60),
		V(210, -300),
		V(270, -545),
		V(150, -760),
		V(0, -960),
	},
	east = { V(40, 600), V(300, 450), V(415, 290), V(560, 40), V(600, -300), V(420, -520), V(290, -555) },
	village = { V(-580, -280), V(-280, -282) },
}
local BALKA_W = { V(-1000, 470), V(-820, 260), V(-740, 0), V(-700, -260), V(-650, -460), V(-720, -760), V(-760, -1000) }
local BALKA_E = { V(1000, 300), V(800, 120), V(740, -180), V(600, -420), V(420, -540), V(260, -585) }
local DITCH = {
	{ V(-1000, 328), V(-600, 345) },
	{ V(-520, 345), V(20, 336) },
	{ V(100, 336), V(470, 340) },
	{ V(565, 342), V(1000, 330) },
}

local OBJECTIVES = {
	{ id = "A", name = "Kolkhoz Trenches", pos = V(-260, 540), radius = 34, owner = "Allies", flag = V(-262, 520) },
	{ id = "B", name = "Railway Halt", pos = V(445, 250), radius = 32, owner = "Neutral", flag = V(452, 236) },
	{ id = "C", name = "Hill 252.2", pos = V(0, -20), radius = 36, owner = "Neutral", flag = V(-8, -6) },
	{ id = "D", name = "Burning Kolkhoz", pos = V(-430, -282), radius = 36, owner = "Neutral" },
	{ id = "E", name = "Sovkhoz Gully", pos = V(285, -560), radius = 34, owner = "Axis", flag = V(300, -530) },
}

local prepared: { any } = {}
local function nearRoad(x: number, z: number, margin: number): boolean
	for _, p in prepared do
		if (Geo.distToPath(p, x, z)) < margin then
			return true
		end
	end
	return false
end

local KEEP_OUT = {
	{ -260, 540, 110 },
	{ 445, 250, 90 },
	{ 0, -20, 90 },
	{ -430, -282, 170 },
	{ 285, -560, 110 },
	{ 0, 885, 150 },
	{ 0, -885, 150 },
}
local function keepOut(x: number, z: number): boolean
	for _, k in KEEP_OUT do
		if (x - k[1]) ^ 2 + (z - k[2]) ^ 2 < k[3] * k[3] then
			return true
		end
	end
	return false
end

function Kursk.Build(parent: Folder, _def: any)
	local ctx = MapKit.new(parent, { seed = SEED })
	local rng = ctx.rng
	table.clear(prepared)
	for _, r in ROADS do
		table.insert(prepared, Geo.path(r))
	end
	table.insert(prepared, Geo.path(RAILWAY))

	-- Golden steppe: Grass is tinted like ripe wheat and decorated (waving blades).
	Terrain.ApplyPalette({
		Grass = rgb(176, 156, 92),
		LeafyGrass = rgb(112, 120, 64),
		Ground = rgb(104, 86, 60),
		Mud = rgb(80, 64, 48),
		Slate = rgb(84, 82, 80),
	}, { decoration = true })

	-------------------------------------------------------------------------------------------
	-- 1. Terrain
	-------------------------------------------------------------------------------------------
	local hm = Terrain.HeightModel({ baseY = 0, seed = SEED })
	hm:Noise(10, 460, 3)
	hm:Noise(3, 130, 2)
	hm:Custom(function(x, z, h)
		local e = math.max(math.abs(x), math.abs(z))
		return h + Geo.smoothstep(990, 1200, e) * 60
	end)
	hm:Ridge({ V(-1200, 520), V(0, 560), V(1200, 500) }, 340, 14) -- Soviet ridge
	hm:Ridge({ V(-1200, -700), V(1200, -720) }, 260, 8) -- German start rise
	hm:Hill(0, -20, 300, 44, 1.2) -- Hill 252.2
	hm:Hill(-560, 120, 160, 14)
	hm:Hill(620, -120, 180, 16)
	hm:Channel(BALKA_W, 26, 13, 28)
	hm:Channel(BALKA_E, 26, 12, 28)
	for _, d in DITCH do
		hm:Channel(d, 6, 7, 7, "V")
	end
	Layout.PrepareHQ(hm, HQ_ALLIES)
	Layout.PrepareHQ(hm, HQ_AXIS)
	hm:FlattenRect(-430, -290, 320, 150, 0, nil, 40)
	hm:Flatten(445, 250, 55, nil, 25)
	hm:Flatten(285, -530, 50, nil, 25)
	for _, r in ROADS do
		hm:Road(r, 10, 8)
	end
	hm:Embankment(RAILWAY, 12, 5, 12)

	local mm = Terrain.MaterialModel({ base = M.Grass, subsurface = M.Ground, seed = SEED })
	mm:Patches(M.LeafyGrass, 220, 0.2)
	mm:Patches(M.Ground, 170, 0.5)
	mm:Patches(M.LeafyGrass, 40, 0.6)
	mm:Path(BALKA_W, 40, M.LeafyGrass, 8)
	mm:Path(BALKA_E, 40, M.LeafyGrass, 8)
	mm:Path(BALKA_W, 12, M.Mud, 4)
	mm:Path(BALKA_E, 12, M.Mud, 4)
	for _, d in DITCH do
		mm:Path(d, 16, M.Ground, 2)
	end
	mm:Slope(M.Ground, 0.65)
	for _, r in ROADS do
		mm:Path(r, 8, M.Ground, 1.5)
	end
	mm:Path(RAILWAY, 9, M.Slate, 0.5)
	mm:Circle(-430, -285, 120, M.Ground, 20)
	mm:Patches(M.Mud, 18, 0.72, { -600, -260, -400, -160 })
	mm:Circle(0, -20, 60, M.Ground, 12)
	mm:Rect(0, 885, 140, 100, 0, M.Ground, 6)
	mm:Rect(0, -885, 140, 100, 0, M.Ground, 6)

	Terrain.Generate(ctx, hm, mm, { center = Vector3.zero, size = Vector2.new(2400, 2400) })

	for _, r in ROADS do
		ctx:AddMinimapPath("road", r, 9)
	end
	ctx:AddMinimapPath("forest", BALKA_W, 34)
	ctx:AddMinimapPath("forest", BALKA_E, 34)
	for _, d in DITCH do
		ctx:AddMinimapPath("trench", d, 10)
	end

	-------------------------------------------------------------------------------------------
	-- 2. Railway (B) and its halt
	-------------------------------------------------------------------------------------------
	Props.Railway(ctx, RAILWAY, { sleeper = 8, broken = { { 220, 80, 14 }, { -10, -500, 12 } } })
	Props.TelegraphLine(ctx, Layout.Offset(RAILWAY, 14), { spacing = 52, leanChance = 0.25, downChance = 0.1 })
	-- Station halt next to the line
	Buildings.House(ctx, ctx:GroundCF(470, 238, -54), {
		style = "Brick",
		width = 20,
		depth = 12,
		floors = 2,
		ruin = 0.45,
		name = "StationHalt",
	})
	ctx:Part({
		Name = "Platform",
		Parent = ctx:Folder("Props"),
		Size = Vector3.new(6, 1.4, 60),
		CFrame = CFrame.lookAt(
			Vector3.new(436, ctx:GroundY(436, 270) + 0.2, 270),
			Vector3.new(436 + 0.81, ctx:GroundY(436, 270) + 0.2, 270 + 0.59)
		),
		Material = M.Concrete,
		Color = rgb(120, 116, 108),
	})
	-- Water tower
	do
		local base = ctx:GroundCF(488, 290, 0)
		local m = ctx:Model("WaterTower", ctx:Folder("Buildings"))
		for _, o in { { -3, -3 }, { 3, -3 }, { -3, 3 }, { 3, 3 } } do
			ctx:Part({
				Name = "Leg",
				Parent = m,
				Size = Vector3.new(1, 18, 1),
				CFrame = base * CFrame.new(o[1], 9, o[2]),
				Material = M.Wood,
				Color = rgb(80, 64, 48),
			})
		end
		ctx:Part({
			Name = "Tank",
			Parent = m,
			Shape = "Cylinder",
			Size = Vector3.new(9, 10, 10),
			CFrame = base * CFrame.new(0, 22.5, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Material = M.WoodPlanks,
			Color = rgb(92, 74, 54),
			Destructible = true,
		})
		ctx:AddMinimapCF("building", base, 9, 9)
	end
	-- Box cars on the track (cover on the embankment)
	local function boxcar(dist: number, derailed: boolean)
		local p = Geo.path(RAILWAY)
		local x, z, dx, dz = Geo.sample(p, dist)
		local y = ctx:GroundY(x, z) + 1
		local cf = CFrame.lookAt(Vector3.new(x, y, z), Vector3.new(x + dx, y, z + dz))
		if derailed then
			cf = cf * CFrame.new(6, -1.5, 0) * CFrame.Angles(0, 0.3, 1.2)
		end
		local m = ctx:Model("BoxCar", ctx:Folder("Props"))
		ctx:Part({
			Name = "Body",
			Parent = m,
			Size = Vector3.new(7.5, 8, 26),
			CFrame = cf * CFrame.new(0, 5.2, 0),
			Material = M.WoodPlanks,
			Color = rgb(108, 60, 44),
			NoPenetration = true,
		})
		ctx:Part({
			Name = "Roof",
			Parent = m,
			Size = Vector3.new(8, 0.5, 26.4),
			CFrame = cf * CFrame.new(0, 9.4, 0),
			Material = M.CorrodedMetal,
			Color = rgb(64, 58, 52),
		})
		ctx:Part({
			Name = "Chassis",
			Parent = m,
			Size = Vector3.new(6, 1.5, 24),
			CFrame = cf * CFrame.new(0, 0.6, 0),
			Material = M.Metal,
			Color = rgb(36, 34, 32),
			CastShadow = false,
		})
	end
	local halt = Geo.path(RAILWAY)
	local _, _, _, along = Geo.distToPath(halt, 430, 262)
	boxcar(along - 40, false)
	boxcar(along - 70, false)
	boxcar(along + 45, true)
	Fort.Sandbags(ctx, ctx:GroundCF(420, 230, 140), { length = 10, arc = 70 })
	Fort.MGNest(ctx, ctx:GroundCF(470, 210, 180), {})
	Props.CrateStack(ctx, ctx:GroundCF(455, 262, 30))
	Props.BarrelGroup(ctx, ctx:GroundCF(480, 255, 0))

	-------------------------------------------------------------------------------------------
	-- 3. Soviet defence: AT ditch, fire trench, wire, A trench network & bunkers
	-------------------------------------------------------------------------------------------
	local frontLine = Layout.Zigzag({ V(-820, 432), V(-560, 418), V(-300, 425), V(-60, 418), V(320, 426) }, 4, 14)
	-- travel is west -> east, so "left" (-cf.RightVector = south) faces the Germans
	Fort.Trench(ctx, frontLine, { parapet = "left", revetment = 0.55, sandbags = 0.12, fireSteps = 36 })
	Fort.Trench(
		ctx,
		Layout.Zigzag({ V(-430, 565), V(-300, 572), V(-120, 552) }, 3.5, 13),
		{ parapet = "left", revetment = 0.7 }
	)
	Fort.Trench(ctx, { V(-350, 568), V(-342, 500), V(-332, 428) }, { parapet = "none", revetment = 0.5, ramps = false })
	Fort.Trench(ctx, { V(-150, 552), V(-170, 490), V(-185, 425) }, { parapet = "none", revetment = 0.5, ramps = false })
	Fort.LogBunker(ctx, ctx:GroundCF(-300, 600, 0), {})
	Fort.LogBunker(ctx, ctx:GroundCF(-200, 590, 0), {})
	Fort.LogBunker(ctx, ctx:GroundCF(-470, 450, 0), {})
	Fort.LogBunker(ctx, ctx:GroundCF(120, 445, 0), {})
	Fort.MGNest(ctx, ctx:GroundCF(-245, 470, 0), {})
	Fort.MGNest(ctx, ctx:GroundCF(-640, 445, 0), {})
	Fort.MGNest(ctx, ctx:GroundCF(220, 440, 0), {})
	Fort.ATGun(ctx, ctx:GroundCF(-90, 470, 10), {})
	Fort.ATGun(ctx, ctx:GroundCF(-400, 480, -10), {})
	Fort.ATGun(ctx, ctx:GroundCF(70, 410, 0), {})
	Fort.BarbedWire(ctx, { V(-820, 392), V(-580, 385) }, {})
	Fort.BarbedWire(ctx, { V(-540, 388), V(20, 382) }, {})
	Fort.BarbedWire(ctx, { V(100, 382), V(330, 386) }, {})
	Fort.TankTraps(ctx, { V(-600, 362), V(-520, 362) }, { kind = "hedgehog", spacing = 11 })
	Fort.TankTraps(ctx, { V(20, 356), V(100, 356) }, { kind = "hedgehog", spacing = 11 })
	-- Kolkhoz field camp at A
	Buildings.Hut(ctx, ctx:GroundCF(-240, 620, 180), { style = "Log", ruin = 0.2 })
	Buildings.Barn(ctx, ctx:GroundCF(-360, 640, 90), { ruin = 0.3, style = "Timber" })
	Props.Tent(ctx, ctx:GroundCF(-180, 630, 10))
	Props.AmmoCache(ctx, ctx:GroundCF(-262, 585, 0))
	Props.HayBales(ctx, ctx:GroundCF(-320, 610, 20))
	Props.Cart(ctx, ctx:GroundCF(-215, 600, 60))
	for _ = 1, 6 do
		Fort.Foxhole(ctx, ctx:GroundCF(rng:NextNumber(-500, 200), rng:NextNumber(450, 520), 0))
	end

	-------------------------------------------------------------------------------------------
	-- 4. C: Hill 252.2 with the ruined windmill
	-------------------------------------------------------------------------------------------
	Buildings.Windmill(ctx, ctx:GroundCF(10, -35, 20), { ruin = 0.65 })
	Fort.Trench(
		ctx,
		Layout.Zigzag({ V(-70, 20), V(-20, 45), V(50, 30) }, 3, 11),
		{ parapet = "right", revetment = 0.5 }
	)
	Fort.Trench(
		ctx,
		Layout.Zigzag({ V(-60, -70), V(0, -90), V(60, -75) }, 3, 11),
		{ parapet = "left", revetment = 0.5 }
	)
	Fort.MGNest(ctx, ctx:GroundCF(-35, -10, 90), {})
	Fort.Sandbags(ctx, ctx:GroundCF(40, -5, -90), { length = 12, arc = 80 })
	Props.RubblePile(ctx, V(25, -18), { radius = 6, height = 2.5, materials = { M.WoodPlanks, M.Rock } })
	Props.Wreck(ctx, ctx:GroundCF(-90, 80, 200), { kind = "tank", burning = true })
	Props.Wreck(ctx, ctx:GroundCF(120, -120, 40), { kind = "tank" })
	Props.Wreck(ctx, ctx:GroundCF(-150, -140, -30), { kind = "tank", noTurret = true })
	Props.Wreck(ctx, ctx:GroundCF(170, 110, 160), { kind = "halftrack" })
	for _ = 1, 22 do
		local a, d = rng:NextNumber(0, math.pi * 2), rng:NextNumber(40, 260)
		Terrain.Crater(ctx, V(math.cos(a) * d, -20 + math.sin(a) * d), rng:NextNumber(4, 9), {})
	end
	for _ = 1, 10 do
		local a, d = rng:NextNumber(0, math.pi * 2), rng:NextNumber(60, 200)
		Nature.Tree(
			ctx,
			V(math.cos(a) * d, -20 + math.sin(a) * d),
			if rng:NextNumber() < 0.6 then "Burnt" else "Dead",
			1
		)
	end

	-------------------------------------------------------------------------------------------
	-- 5. D: burning kolkhoz village
	-------------------------------------------------------------------------------------------
	local hutXs = { -545, -510, -475, -440, -405, -370, -335 }
	for i, x in hutXs do
		for _, side in { -1, 1 } do
			if (i + (if side > 0 then 1 else 0)) % 5 == 0 then
				continue -- empty plot
			end
			local z = -282 + side * 22
			local yaw = if side > 0 then 0 else 180
			Buildings.Hut(ctx, ctx:GroundCF(x + rng:NextNumber(-3, 3), z, yaw), {
				style = "Log",
				width = rng:NextNumber(11, 14),
				depth = rng:NextNumber(8.5, 10),
				ruin = rng:NextNumber(0.1, 0.85),
			})
			-- garden fence behind each hut
			local fz = z + side * 16
			Props.Fence(ctx, { V(x - 12, fz), V(x + 12, fz) }, { kind = "picket", gapChance = 0.25 })
		end
	end
	Buildings.Barn(ctx, ctx:GroundCF(-380, -350, 90), { width = 18, depth = 40, ruin = 0.55, name = "KolkhozBarn" })
	Buildings.Barn(ctx, ctx:GroundCF(-500, -352, 90), { width = 16, depth = 32, ruin = 0.3 })
	Buildings.House(
		ctx,
		ctx:GroundCF(-440, -215, 180),
		{ style = "Brick", width = 22, depth = 14, floors = 2, ruin = 0.4, name = "KolkhozOffice" }
	)
	Props.Well(ctx, ctx:GroundCF(-455, -282, 0))
	Props.Cart(ctx, ctx:GroundCF(-420, -275, 80), { broken = true })
	Props.Cart(ctx, ctx:GroundCF(-350, -330, 10))
	for _ = 1, 8 do
		Props.Haystack(ctx, V(rng:NextNumber(-560, -320), rng:NextNumber(-400, -380)))
	end
	for _, f in { V(-475, -262), V(-370, -304), V(-380, -350), V(-510, -300), V(-405, -262) } do
		Props.Fire(ctx, f, { size = rng:NextNumber(6, 9) })
	end
	Props.Wreck(ctx, ctx:GroundCF(-600, -290, 80), { kind = "tank", burning = true })
	Props.Wreck(ctx, ctx:GroundCF(-300, -240, 110), { kind = "truck" })
	Fort.Sandbags(ctx, ctx:GroundCF(-430, -240, 0), { length = 10, arc = 70 })
	Fort.MGNest(ctx, ctx:GroundCF(-330, -270, -90), {})
	Nature.Forest(
		ctx,
		{ center = V(-430, -170), size = Vector2.new(260, 50) },
		{ kinds = { "Birch", "Oak", "Birch" }, spacing = 16, minimap = true }
	)

	-------------------------------------------------------------------------------------------
	-- 6. E: German forward base in the Sovkhoz gully
	-------------------------------------------------------------------------------------------
	Fort.Trench(
		ctx,
		Layout.Zigzag({ V(180, -500), V(290, -490), V(400, -500) }, 3.5, 12),
		{ parapet = "right", sandbags = 0.3 }
	)
	Fort.ATGun(ctx, ctx:GroundCF(230, -478, 180), {})
	Fort.ATGun(ctx, ctx:GroundCF(360, -480, 180), {})
	Fort.MGNest(ctx, ctx:GroundCF(300, -470, 180), {})
	Fort.Bunker(ctx, ctx:GroundCF(120, -520, 200), { width = 14, depth = 10, slits = 2 })
	Props.Tent(ctx, ctx:GroundCF(270, -600, 0))
	Props.Tent(ctx, ctx:GroundCF(320, -610, 10))
	Props.Wreck(ctx, ctx:GroundCF(300, -580, 90), { kind = "truck" })
	Props.AmmoCache(ctx, ctx:GroundCF(290, -540, 0))
	Props.BarrelGroup(ctx, ctx:GroundCF(340, -560, 0))
	Props.CrateStack(ctx, ctx:GroundCF(250, -560, 0))
	Buildings.Hut(ctx, ctx:GroundCF(220, -620, 0), { style = "Timber", ruin = 0.35, name = "SovkhozShed" })
	Fort.TankTraps(ctx, { V(160, -440), V(420, -445) }, { kind = "mixed", spacing = 18 })

	-------------------------------------------------------------------------------------------
	-- 7. Steppe: balka vegetation, shelterbelts, wheat, haystacks, wrecks, craters
	-------------------------------------------------------------------------------------------
	for _, balka in { BALKA_W, BALKA_E } do
		Layout.AlongPath(ctx, balka, 22, function(cf)
			local p = cf.Position + cf.RightVector * rng:NextNumber(-22, 22)
			if keepOut(p.X, p.Z) then
				return
			end
			if rng:NextNumber() < 0.55 then
				Nature.Bush(ctx, p, rng:NextNumber(5, 9))
			else
				Nature.Tree(ctx, p, ({ "Birch", "Oak", "Dead" })[rng:NextInteger(1, 3)], 0.9)
			end
		end)
	end
	-- Shelterbelts (tree lines) — classic steppe windbreaks
	for _, belt in
		{
			{ V(-900, 150), V(-620, 160) },
			{ V(250, 700), V(700, 690) },
			{ V(-300, -650), V(-80, -640) },
			{ V(600, -760), V(900, -700) },
			{ V(-900, -560), V(-760, -500) },
		}
	do
		Layout.AlongPath(ctx, belt, 15, function(cf)
			if rng:NextNumber() < 0.85 then
				Nature.Tree(ctx, cf.Position, if rng:NextNumber() < 0.6 then "Poplar" else "Birch", 1)
			end
		end, { jitter = 2 })
		ctx:AddMinimapPath("forest", belt, 10)
	end
	-- Wheat strip fields (tall cover) and harvested plots
	for _, f in
		{
			{ -620, 640, 180, 130, 4 },
			{ 360, 640, 200, 130, -6 },
			{ -680, -60, 160, 200, 2 },
			{ 400, -120, 180, 160, 8 },
			{ -170, -560, 180, 120, -3 },
			{ 700, -640, 170, 140, 5 },
			{ -200, 230, 200, 110, 0 },
		}
	do
		if not nearRoad(f[1], f[2], 70) then
			Nature.WheatField(ctx, ctx:GroundCF(f[1], f[2], f[5]), f[3], f[4], { rowSpacing = 6 })
		else
			Nature.WheatField(ctx, ctx:GroundCF(f[1], f[2], f[5]), f[3], f[4], { rowSpacing = 6, harvested = true })
		end
	end
	local stacks = 0
	for _ = 1, 200 do
		if stacks >= 24 then
			break
		end
		local x, z = rng:NextNumber(-900, 900), rng:NextNumber(-780, 780)
		if not keepOut(x, z) and not nearRoad(x, z, 16) then
			stacks += 1
			Props.Haystack(ctx, V(x, z), { size = rng:NextNumber(7, 10) })
		end
	end
	-- The tank graveyard: wrecks scattered between the lines
	local wrecks = 0
	for _ = 1, 100 do
		if wrecks >= 9 then
			break
		end
		local x, z = rng:NextNumber(-700, 700), rng:NextNumber(-500, 300)
		if not keepOut(x, z) and not nearRoad(x, z, 14) then
			wrecks += 1
			Props.Wreck(ctx, ctx:GroundCF(x, z, rng:NextNumber(0, 360)), {
				kind = if rng:NextNumber() < 0.75 then "tank" else "halftrack",
				noTurret = rng:NextNumber() < 0.2,
				burning = wrecks <= 2,
			})
		end
	end
	local craters = 0
	for _ = 1, 400 do
		if craters >= 60 then
			break
		end
		local x, z = rng:NextNumber(-900, 900), rng:NextNumber(-700, 520)
		if not keepOut(x, z) and not nearRoad(x, z, 14) then
			craters += 1
			Terrain.Crater(ctx, V(x, z), rng:NextNumber(4, 10), {})
		end
	end
	for _ = 1, 30 do
		local x, z = rng:NextNumber(-950, 950), rng:NextNumber(-800, 800)
		if not keepOut(x, z) and not nearRoad(x, z, 12) then
			Nature.Bush(ctx, V(x, z), rng:NextNumber(4, 7))
		end
	end
	Props.TelegraphLine(ctx, Layout.Offset(ROADS.central, 10), { spacing = 55, leanChance = 0.3, downChance = 0.12 })

	-------------------------------------------------------------------------------------------
	-- 8. HQs, objectives, MapInfo
	-------------------------------------------------------------------------------------------
	local alliesHQ = Layout.SpawnArea(ctx, HQ_ALLIES, "Allies", { spawnCount = 10, vehicleCount = 8, width = 140 })
	local axisHQ = Layout.SpawnArea(ctx, HQ_AXIS, "Axis", { spawnCount = 10, vehicleCount = 8, width = 140 })
	-- Tree screens in front of both HQs block long-range sightlines into the spawns
	for _, belt in { { V(-160, 800), V(160, 800) }, { V(-160, -800), V(160, -800) } } do
		Layout.AlongPath(ctx, belt, 12, function(cf)
			if not nearRoad(cf.Position.X, cf.Position.Z, 12) then
				Nature.Tree(ctx, cf.Position, "Oak", 1.1)
				Nature.Bush(ctx, cf.Position + Vector3.new(0, 0, 4), 7)
			end
		end)
	end

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

	local classes = { "Tank", "Tank", "Light", "Transport", "Tank", "Jeep", "Light", "Jeep" }
	local function vehicles(list: { CFrame })
		local out = {}
		for i, cf in list do
			table.insert(out, { cframe = cf, class = classes[i] or "Jeep" })
		end
		return out
	end

	return MapKit.Finish(ctx, {
		id = "Kursk",
		bounds = { center = Vector3.new(0, 60, 0), size = Vector3.new(SIZE, 800, SIZE) },
		hq = { Allies = alliesHQ.spawns, Axis = axisHQ.spawns },
		objectives = objectives,
		vehicleSpawns = { Allies = vehicles(alliesHQ.vehicles), Axis = vehicles(axisHQ.vehicles) },
		outOfBounds = 12,
	})
end

return Kursk
