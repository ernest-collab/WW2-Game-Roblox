--[[
	Ardennes — "Ardennes Forest" (≈1500 x 1500 studs). Map team (B).

	Winter 1944. Snow-covered pine forest cut by muddy logging tracks and a frozen creek. The
	Allies hold the shattered woods in the south; the Axis holds a log-bunker line on the northern
	ridge. Between them: a foxhole ridge, a forest crossroads village and a logging camp.

	   z=+750 ┌───────────────────────────────────────────────────────────┐
	          │  pines     [AXIS HQ] (-200,660)  reverse slope    pines    │
	          │ ═══ E Bunkerlinie (0,440) log bunkers, trench, wire ═══════ │
	          │   pines (clusters)          ║            hero firs          │
	          │                             ║     D Sägewerk (240,250)      │
	          │~~~~ frozen creek ~~~ log bridge ~=road bridge=~~ mill pond ~~│
	          │  meadow   C Crossroads (-40,30)  chapel, houses ═══════════ │
	          │ ═════════════════╬══════════════════════════════════════════│
	          │   pines     B Foxhole Ridge (130,-230) firebreak, stumps    │
	          │ A Shattered Woods (-160,-410) craters, stumps, foxholes     │
	          │            [ALLIED HQ] (80,-630) behind a rise              │
	   z=-750 └───────────────────────────────────────────────────────────┘
	           x=-750                                                 x=+750

	Objectives (order 1 = Allied end): A Shattered Woods, B Foxhole Ridge, C Crossroads (village and
	chapel), D Sägewerk (logging camp and sawmill on the creek), E Bunkerlinie (log bunkers on the
	ridge). Routes: the main N-S forest road (bridge north of C), the sawmill track (ford east of D),
	western logging trails with a log footbridge. Dense pine clusters with glades give cover
	everywhere; tanks are confined to the tracks.

	Tree budget: pines are 2-3 parts each (cylinder trunk + 1-2 crown ellipsoids), stumps 1-2 parts,
	and only a few MapKit "hero" firs. Density follows a cluster noise mask, not a uniform scatter.
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

local Ardennes = {}

local SIZE = 1500
local SEED = 1216

-- Layout data -----------------------------------------------------------------------------------------

local HQ_ALLIES = CFrame.new(80, 0, -630) * CFrame.Angles(0, math.pi, 0) -- faces north (+Z)
local HQ_AXIS = CFrame.new(-200, 0, 660) -- faces south (-Z)

local CREEK = {
	V(-800, 150),
	V(-560, 120),
	V(-380, 110),
	V(-220, 140),
	V(-40, 150),
	V(110, 175),
	V(230, 190),
	V(330, 175),
	V(470, 150),
	V(620, 180),
	V(800, 210),
}

local ROADS = {
	main = {
		V(80, -800),
		V(80, -600),
		V(50, -470),
		V(110, -330),
		V(100, -160),
		V(10, -40),
		V(-40, 30),
		V(-40, 150),
		V(-20, 290),
		V(10, 400),
		V(-60, 520),
		V(-180, 610),
		V(-180, 800),
	},
	lateral = { V(-800, -10), V(-480, 0), V(-300, 20), V(-40, 30), V(140, 10), V(260, 0), V(520, -40), V(800, -30) },
	sawmill = { V(260, 0), V(270, 110), V(250, 190), V(250, 260), V(330, 380), V(380, 520), V(300, 640), V(160, 700) },
	westTrail = { V(-300, 20), V(-360, -160), V(-260, -330), V(-160, -410), V(-20, -520), V(80, -600) },
	northTrail = { V(-380, 110), V(-420, 300), V(-330, 470), V(-180, 610) },
}
local MAIN_TRACKS = { main = true, lateral = true, sawmill = true }

local OBJECTIVES = {
	{ id = "A", name = "Shattered Woods", pos = V(-160, -410), radius = 34, owner = "Allies" },
	{ id = "B", name = "Foxhole Ridge", pos = V(130, -232), radius = 32, owner = "Neutral" },
	{ id = "C", name = "Crossroads", pos = V(-40, 30), radius = 32, owner = "Neutral", flag = V(-30, 40) },
	{ id = "D", name = "Sägewerk", pos = V(240, 250), radius = 32, owner = "Neutral", flag = V(232, 262) },
	{ id = "E", name = "Bunkerlinie", pos = V(0, 440), radius = 34, owner = "Axis", flag = V(10, 452) },
}

-- clearings: { x, z, radius } — no forest inside (objective areas get their own sparse trees)
local CLEARINGS = {
	{ 80, -630, 140 }, -- Allied HQ
	{ -200, 660, 140 }, -- Axis HQ
	{ -40, 30, 115 }, -- village
	{ 240, 245, 85 }, -- logging camp
	{ 130, -232, 70 }, -- B
	{ 0, 440, 70 }, -- E
	{ -160, -410, 60 }, -- A
	{ -260, 60, 70 }, -- meadow west of the village
	{ 130, 80, 55 }, -- meadow east
}

-- Snow-roofed building styles
local function snowStyle(baseName: string, wallColors: { Color3 }?): any
	local s = table.clone(Buildings.Styles[baseName])
	s.roof = M.Snow
	s.roofColors = { rgb(226, 232, 238), rgb(214, 222, 230) }
	if wallColors then
		s.wallColors = wallColors
	end
	return s
end

-- Helpers ---------------------------------------------------------------------------------------------

local preparedRoads: { [string]: any } = {}
local creekPath = Geo.path(CREEK)

local function nearRoad(x: number, z: number, margin: number): boolean
	for _, p in preparedRoads do
		if (Geo.distToPath(p, x, z)) < margin then
			return true
		end
	end
	return false
end

local function inClearing(x: number, z: number, pad: number?): boolean
	local extra = pad or 0
	for _, c in CLEARINGS do
		local r = c[3] + extra
		if (x - c[1]) ^ 2 + (z - c[2]) ^ 2 < r * r then
			return true
		end
	end
	return false
end

local PINE_GREENS = { rgb(36, 54, 42), rgb(42, 60, 46), rgb(32, 48, 40), rgb(46, 64, 50), rgb(40, 56, 48) }
local SNOW = rgb(214, 222, 228)
local BARK = rgb(74, 60, 48)

-- Cheap pine: trunk cylinder + one (tier 1) or two (tier 2) crown ellipsoids, snow-dusted top.
local function pine(ctx: any, x: number, z: number, s: number, tier: number, parent: Instance)
	local y = ctx:GroundY(x, z)
	local h = 26 * s
	local model = ctx:Model("Pine", parent)
	ctx:Part({
		Name = "Trunk",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(h, 1.3 * s, 1.3 * s),
		CFrame = CFrame.new(x, y + h / 2 - 1, z) * CFrame.Angles(0, ctx:Range(0, 6.28), math.pi / 2),
		Material = M.Wood,
		Color = BARK,
		Jitter = 0.08,
		CastShadow = true,
	})
	local col = ctx:Pick(PINE_GREENS)
	if tier <= 1 then
		ctx:Part({
			Name = "Leaves",
			Parent = model,
			Mesh = "Sphere",
			Size = Vector3.new(9 * s, 21 * s, 9 * s),
			CFrame = CFrame.new(x, y + h * 0.64, z),
			Material = M.Grass,
			Color = ctx:Jitter(col:Lerp(SNOW, ctx:Range(0.05, 0.2)), 0.05),
			CanCollide = false,
			CanQuery = false,
			CastShadow = true,
		})
	else
		ctx:Part({
			Name = "Leaves",
			Parent = model,
			Mesh = "Sphere",
			Size = Vector3.new(13 * s, 13 * s, 13 * s),
			CFrame = CFrame.new(x, y + h * 0.42, z),
			Material = M.Grass,
			Color = ctx:Jitter(col, 0.05),
			CanCollide = false,
			CanQuery = false,
			CastShadow = true,
		})
		ctx:Part({
			Name = "Leaves",
			Parent = model,
			Mesh = "Sphere",
			Size = Vector3.new(8 * s, 15 * s, 8 * s),
			CFrame = CFrame.new(x, y + h * 0.78, z),
			Material = M.Snow,
			Color = ctx:Jitter(col:Lerp(SNOW, ctx:Range(0.25, 0.45)), 0.04),
			CanCollide = false,
			CanQuery = false,
			CastShadow = true,
		})
	end
	return model
end

-- Artillery-shattered stump: short jagged trunk with a splinter; sometimes a felled top nearby.
local function stump(ctx: any, x: number, z: number, parent: Instance, tall: boolean?)
	local y = ctx:GroundY(x, z)
	local h = if tall then ctx:Range(7, 14) else ctx:Range(1.5, 5)
	local r = ctx:Range(1.1, 1.6)
	local model = ctx:Model("Stump", parent)
	local lean = CFrame.Angles(ctx:Range(-0.08, 0.08), ctx:Range(0, 6.28), ctx:Range(-0.08, 0.08))
	local base = CFrame.new(x, y - 0.6, z) * lean
	ctx:Part({
		Name = "Trunk",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(h + 0.6, r * 2, r * 2),
		CFrame = base * CFrame.new(0, h / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = M.Wood,
		Color = ctx:Jitter(rgb(70, 58, 46), 0.1),
	})
	ctx:Part({
		Name = "Splinter",
		Parent = model,
		Size = Vector3.new(r * 0.8, h * 0.5 + 1.5, r * 0.5),
		CFrame = base
			* CFrame.new(r * 0.3, h + (h * 0.5 + 1.5) / 2 - 0.4, 0)
			* CFrame.Angles(0, 0, ctx:Range(-0.25, 0.25)),
		Material = M.Wood,
		Color = rgb(150, 128, 98),
		CastShadow = false,
	})
	if tall and ctx:Chance(0.5) then
		local a = ctx:Range(0, math.pi * 2)
		local len = ctx:Range(10, 18)
		local fx, fz = x + math.cos(a) * (len / 2 + 2), z + math.sin(a) * (len / 2 + 2)
		ctx:Part({
			Name = "FelledTop",
			Parent = model,
			Shape = "Cylinder",
			Size = Vector3.new(len, r * 1.5, r * 1.5),
			CFrame = CFrame.new(fx, ctx:GroundY(fx, fz) + r * 0.6, fz)
				* CFrame.Angles(0, -a, 0)
				* CFrame.Angles(0, 0, ctx:Range(-0.1, 0.1)),
			Material = M.Wood,
			Color = BARK,
		})
	end
	return model
end

-- Triangular stack of cut logs along cf local X.
local function logPile(ctx: any, cf: CFrame, len: number, rows: number, parent: Instance)
	local model = ctx:Model("LogPile", parent)
	local d = 1.9
	for r = 0, rows - 1 do
		local n = rows - r
		for i = 0, n - 1 do
			local off = (i - (n - 1) / 2) * d
			ctx:Part({
				Name = "Log",
				Parent = model,
				Shape = "Cylinder",
				Size = Vector3.new(len + ctx:Range(-0.8, 0.8), d, d),
				CFrame = cf * CFrame.new(ctx:Range(-0.4, 0.4), d / 2 + r * d * 0.85, off),
				Material = M.Wood,
				Color = ctx:Jitter(rgb(118, 92, 64), 0.1),
				Jitter = 0,
			})
		end
	end
	-- snow on top
	ctx:Part({
		Name = "Snow",
		Parent = model,
		Size = Vector3.new(len, 0.4, d * 1.2),
		CFrame = cf * CFrame.new(0, d / 2 + (rows - 1) * d * 0.85 + d / 2, 0),
		Material = M.Snow,
		Color = SNOW,
		CanCollide = false,
	})
	return model
end

-- Open-sided saw shed with a circular saw bench and a log carriage. cf = centre, long axis = X.
local function sawShed(ctx: any, cf: CFrame, parent: Instance)
	local model = ctx:Model("SawShed", parent)
	local W, D, H = 26, 12, 8
	for _, px in { -W / 2, 0, W / 2 } do
		for _, pz in { -D / 2, D / 2 } do
			ctx:Part({
				Name = "Post",
				Parent = model,
				Size = Vector3.new(0.9, H, 0.9),
				CFrame = cf * CFrame.new(px, H / 2, pz),
				Material = M.Wood,
				Color = rgb(84, 64, 46),
			})
		end
	end
	for _, side in { -1, 1 } do
		ctx:Part({
			Name = "Roof",
			Parent = model,
			Size = Vector3.new(W + 2, 0.5, D / 2 + 2),
			CFrame = cf * CFrame.new(0, H + 1.4, side * (D / 4 + 0.6)) * CFrame.Angles(math.rad(-22 * side), 0, 0),
			Material = M.Snow,
			Color = SNOW,
			Destructible = true,
		})
	end
	ctx:Part({
		Name = "SawBench",
		Parent = model,
		Size = Vector3.new(W - 4, 2.8, 3),
		CFrame = cf * CFrame.new(0, 1.4, 0),
		Material = M.WoodPlanks,
		Color = rgb(110, 86, 60),
	})
	ctx:Part({
		Name = "Blade",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(0.2, 4.5, 4.5),
		CFrame = cf * CFrame.new(-3, 3, 0),
		Material = M.Metal,
		Color = rgb(150, 150, 150),
	})
	ctx:Part({
		Name = "Log",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(14, 2.2, 2.2),
		CFrame = cf * CFrame.new(5, 3.9, 0),
		Material = M.Wood,
		Color = rgb(118, 92, 64),
	})
	ctx:Part({
		Name = "Engine",
		Parent = model,
		Size = Vector3.new(4, 4, 4),
		CFrame = cf * CFrame.new(-W / 2 + 3, 2, -D / 2 + 3),
		Material = M.Metal,
		Color = rgb(60, 66, 58),
	})
	ctx:AddMinimapCF("building", cf, W, D)
	return model
end

-- Water wheel against a building wall over the millrace. cf = hub on the ground, axis = local X.
local function waterWheel(ctx: any, cf: CFrame, parent: Instance)
	local model = ctx:Model("WaterWheel", parent)
	ctx:Part({
		Name = "Wheel",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(3, 14, 14),
		CFrame = cf * CFrame.new(0, 6, 0),
		Material = M.WoodPlanks,
		Color = rgb(88, 68, 48),
	})
	ctx:Part({
		Name = "Ice",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(3.2, 9, 9),
		CFrame = cf * CFrame.new(0, 6, 0),
		Material = M.Ice,
		Color = rgb(200, 220, 230),
		Transparency = 0.3,
	})
	ctx:Part({
		Name = "Axle",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(7, 1.2, 1.2),
		CFrame = cf * CFrame.new(-2, 6, 0),
		Material = M.Metal,
		Color = rgb(60, 60, 60),
	})
	return model
end

-- Builder ---------------------------------------------------------------------------------------------

function Ardennes.Build(parent: Folder, _def: any)
	local ctx = MapKit.new(parent, { seed = SEED })
	local rng = ctx.rng
	table.clear(preparedRoads)
	for name, r in ROADS do
		preparedRoads[name] = Geo.path(r)
	end

	Terrain.ApplyPalette({
		Snow = rgb(222, 228, 234),
		Ground = rgb(92, 80, 66),
		Mud = rgb(70, 58, 48),
		Rock = rgb(104, 104, 108),
		Grass = rgb(150, 156, 140),
		Glacier = rgb(196, 214, 226),
	}, { color = rgb(60, 78, 84), decoration = false })

	-------------------------------------------------------------------------------------------
	-- 1. Terrain model
	-------------------------------------------------------------------------------------------
	local hm = Terrain.HeightModel({ baseY = 12, seed = SEED })
	hm:Noise(10, 320, 3)
	hm:Noise(3, 80, 2)
	hm:Custom(function(x, z, h)
		local e = math.max(math.abs(x), math.abs(z))
		return h + Geo.smoothstep(700, 880, e) * 45
	end)
	hm:Ridge({ V(-450, 440), V(-200, 455), V(0, 440), V(250, 455), V(520, 470) }, 220, 20) -- E ridge
	hm:Ridge({ V(-320, -250), V(-60, -240), V(130, -235), V(500, -205) }, 130, 10) -- B ridge
	hm:Ridge({ V(-200, -540), V(80, -548), V(320, -530) }, 80, 12) -- rise screening the Allied HQ
	hm:Ridge({ V(-70, -760), V(-60, -620), V(-110, -545) }, 60, 15) -- and its western flank
	hm:Ridge({ V(230, -760), V(225, -620), V(270, -545) }, 60, 10) -- eastern flank
	hm:Ridge({ V(-350, 760), V(-345, 620), V(-310, 530), V(-270, 490) }, 60, 13) -- Axis HQ western flank
	hm:Ridge({ V(-10, 760), V(-20, 640), V(-60, 565), V(-100, 530) }, 60, 13) -- Axis HQ eastern flank
	hm:Hill(-500, -300, 160, 12)
	hm:Hill(520, -420, 170, 14)
	hm:Hill(560, 330, 150, 10)
	-- creek valley: pull the ground down to a valley floor near the creek
	hm:Custom(function(x, z, h)
		local d = Geo.distToPath(creekPath, x, z)
		if d > 160 then
			return h
		end
		return Geo.lerp(5, h, Geo.smoothstep(22, 160, d))
	end)
	hm:River(CREEK, { width = 18, bank = 10, bedY = -1.5, waterY = 2.6, frozen = true })
	hm:Pond(150, 226, 28, -1.5, 2.6, true) -- frozen log pond west of the sawmill
	hm:Flatten(-40, 30, 95, nil, 40)
	hm:Flatten(250, 262, 55, nil, 25)
	hm:Flatten(0, 450, 70, nil, 30)
	hm:Flatten(130, -232, 55, nil, 25)
	Layout.PrepareHQ(hm, HQ_ALLIES, { y = 13 })
	Layout.PrepareHQ(hm, HQ_AXIS)
	hm:Ridge({ V(-380, 562), V(-200, 568), V(-30, 560) }, 64, 14) -- reverse-slope rise in front of the Axis HQ
	for name, r in ROADS do
		hm:Road(r, if MAIN_TRACKS[name] then 12 else 7, 8)
	end
	hm:Flatten(420, 158, 12, 1.4, 10) -- the ford on the eastern track

	local mm = Terrain.MaterialModel({ base = M.Snow, subsurface = M.Ground, seed = SEED })
	mm:Patches(M.Glacier, 70, 0.55)
	mm:Slope(M.Rock, 0.9)
	for name, r in ROADS do
		if MAIN_TRACKS[name] then
			mm:Path(r, 9, M.Mud, 1.5)
			mm:Path(r, 4, M.Ground, 1)
		else
			mm:Path(r, 5, M.Ground, 1.5)
		end
	end
	mm:Circle(-40, 30, 40, M.Ground, 6)
	mm:Circle(245, 255, 40, M.Mud, 8)
	mm:Rect(HQ_ALLIES.Position.X, HQ_ALLIES.Position.Z, 140, 100, 0, M.Mud, 6)
	mm:Rect(HQ_AXIS.Position.X, HQ_AXIS.Position.Z, 140, 100, 0, M.Mud, 6)
	mm:Circle(-160, -410, 70, M.Ground, 18) -- churned earth in the shattered woods

	Terrain.Generate(ctx, hm, mm, { center = Vector3.zero, size = Vector2.new(1900, 1900) })

	for name, r in ROADS do
		ctx:AddMinimapPath("road", r, if MAIN_TRACKS[name] then 10 else 6)
	end
	ctx:AddMinimapPath("water", CREEK, 20)
	ctx:AddMinimap("water", 150, 226, 60, 60, 0)

	local props = ctx:Folder("Props")
	local nature = ctx:Folder("Nature")

	-------------------------------------------------------------------------------------------
	-- 2. C: forest crossroads village with its chapel
	-------------------------------------------------------------------------------------------
	local stone = snowStyle("NormanStone", { rgb(150, 144, 132), rgb(138, 132, 122), rgb(160, 152, 140) })
	local timber = snowStyle("Timber")
	local village = ctx:Model("Village", ctx:Folder("Buildings"))
	local function house(hx: number, hz: number, yaw: number, opts: { [string]: any })
		opts.parent = village
		opts.style = opts.style or (if rng:NextNumber() < 0.6 then stone else timber)
		opts.width = opts.width or rng:NextNumber(16, 19)
		opts.depth = opts.depth or rng:NextNumber(12, 14)
		return Buildings.House(ctx, ctx:GroundCF(hx, hz, yaw), opts)
	end
	Buildings.Church(
		ctx,
		ctx:GroundCF(-90, 82, 180),
		{ width = 16, length = 30, towerH = 28, naveH = 13, towerSize = 9, style = stone, ruin = 0.2 }
	)
	house(-90, -12, 180, { enterable = true, floors = 2, ruin = 0.3 })
	house(-118, 54, -90, { enterable = false, floors = 2 })
	house(14, 60, 0, { enterable = true, floors = 2, ruin = 0.15, name = "Cafe" })
	house(40, 56, 0, { enterable = false, floors = 1, ruin = 0.5 })
	house(14, -2, 180, { enterable = true, floors = 2, ruin = 0.6 })
	house(-14, -80, -90, { enterable = true, floors = 2 })
	house(-70, -64, 90, { enterable = false, floors = 2, ruin = 0.4 })
	Buildings.Barn(ctx, ctx:GroundCF(60, -60, 90), { style = timber, ruin = 0.3 })
	Buildings.Shed(ctx, ctx:GroundCF(-120, 10, 90), { style = timber })
	Props.StoneWall(ctx, { V(-108, 60), V(-108, 108), V(-72, 108), V(-72, 60) }, { height = 2.8, gapChance = 0.1 })
	Props.Signpost(ctx, ctx:GroundCF(-52, 40, 45))
	Props.Wreck(ctx, ctx:GroundCF(-4, 10, 70), { kind = "tank", burning = true })
	Props.Wreck(ctx, ctx:GroundCF(-104, 44, 100), { kind = "car" })
	Fort.Sandbags(ctx, ctx:GroundCF(-58, 50, 0), { length = 9, arc = 50 })
	Fort.Sandbags(ctx, ctx:GroundCF(-4, -4, 180), { length = 8, arc = 50 })
	Fort.ATGun(ctx, ctx:GroundCF(-70, 6, 180), {})
	Fort.MGNest(ctx, ctx:GroundCF(22, 44, 0), {})
	Fort.Barricade(ctx, ctx:GroundCF(-40, 96, 0), { kind = "wood", length = 8 })
	Fort.Barricade(ctx, ctx:GroundCF(8, -38, 180), { kind = "debris", length = 8 })
	Props.CrateStack(ctx, ctx:GroundCF(-62, 18, 0))
	Props.Cart(ctx, ctx:GroundCF(26, -24, 40), { broken = true })
	Props.Well(ctx, ctx:GroundCF(-62, -20, 0))
	Props.HayBales(ctx, ctx:GroundCF(70, -30, 0))
	Props.TelegraphLine(ctx, Layout.Offset(ROADS.lateral, 10), { leanChance = 0.35, downChance = 0.1 })
	Props.Fence(ctx, { V(-200, 0), V(-200, 110), V(-320, 120) }, { kind = "rail", gapChance = 0.25 })
	Props.Fence(ctx, { V(100, 40), V(170, 40), V(175, 120) }, { kind = "rail", gapChance = 0.25 })
	Props.RubblePile(ctx, V(26, 10), { radius = 5, height = 2.5 })
	Props.Fire(ctx, V(16, -6), { size = 4 })
	for _, l in { { -52, -6 }, { -26, 66 }, { -60, 70 } } do
		Props.LampPost(ctx, ctx:GroundCF(l[1], l[2], 0), { parent = props })
	end

	-------------------------------------------------------------------------------------------
	-- 3. D: Sägewerk — logging camp and sawmill on the creek
	-------------------------------------------------------------------------------------------
	local camp = ctx:Model("LoggingCamp", ctx:Folder("Buildings"))
	Buildings.Barn(
		ctx,
		ctx:GroundCF(210, 232, 90),
		{ style = timber, width = 16, depth = 28, height = 12, ruin = 0.15, name = "Sawmill" }
	)
	waterWheel(ctx, ctx:GroundCF(206, 214, 0), camp)
	sawShed(ctx, ctx:GroundCF(205, 292, 0), camp)
	Buildings.Hut(ctx, ctx:GroundCF(300, 236, -90), { style = timber, width = 12, depth = 9, parent = camp })
	Buildings.Hut(ctx, ctx:GroundCF(332, 300, -90), { style = "Log", width = 13, depth = 9, parent = camp })
	Buildings.Hut(ctx, ctx:GroundCF(170, 302, 90), { style = "Log", width = 12, depth = 9, ruin = 0.4, parent = camp })
	for _, l in
		{
			{ 230, 320, 0, 10, 4 },
			{ 190, 326, 0, 9, 3 },
			{ 290, 270, -80, 9, 4 },
			{ 312, 258, -70, 10, 3 },
			{ 274, 212, 5, 10, 3 },
			{ 196, 266, 95, 9, 3 },
		}
	do
		logPile(ctx, ctx:GroundCF(l[1], l[2], l[3]), l[4], l[5], camp)
	end
	Props.Wreck(ctx, ctx:GroundCF(270, 250, 160), { kind = "truck" })
	Props.Cart(ctx, ctx:GroundCF(222, 258, 30), {})
	Props.CrateStack(ctx, ctx:GroundCF(234, 250, 0))
	Props.BarrelGroup(ctx, ctx:GroundCF(304, 254, 0))
	Fort.Sandbags(ctx, ctx:GroundCF(232, 208, 0), { length = 9, arc = 40 })
	Fort.MGNest(ctx, ctx:GroundCF(320, 222, 10), {})
	Fort.Foxhole(ctx, ctx:GroundCF(196, 200, 0))
	-- loose logs in the pond and felled timber around the camp
	for _ = 1, 14 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(40, 85)
		local lx, lz = 240 + math.cos(a) * d, 255 + math.sin(a) * d
		if not nearRoad(lx, lz, 8) then
			local len = rng:NextNumber(10, 16)
			ctx:Part({
				Name = "Log",
				Parent = camp,
				Shape = "Cylinder",
				Size = Vector3.new(len, 1.8, 1.8),
				CFrame = CFrame.new(lx, ctx:GroundY(lx, lz) + 0.8, lz) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0),
				Material = M.Wood,
				Color = rgb(110, 86, 60),
			})
		end
	end
	Props.WoodBridge(ctx, V(-40, 128), V(-40, 172), { width = 12 })
	Props.WoodBridge(ctx, V(-380, 92), V(-380, 128), { width = 4 })
	Props.Signpost(ctx, ctx:GroundCF(268, 120, 0))

	-------------------------------------------------------------------------------------------
	-- 4. Front lines: A shattered woods, B foxhole ridge, E bunker line
	-------------------------------------------------------------------------------------------
	local front = ctx:Model("Battlefield", nature)
	-- A: shattered woods (Allied foxholes facing north, craters, stumps)
	for _, f in { { -220, -380 }, { -190, -372 }, { -150, -368 }, { -110, -376 }, { -80, -390 }, { -250, -400 } } do
		Fort.Foxhole(ctx, ctx:GroundCF(f[1] + rng:NextNumber(-3, 3), f[2], 180))
	end
	Fort.LogBunker(ctx, ctx:GroundCF(-170, -440, 180), {})
	Fort.MGNest(ctx, ctx:GroundCF(-130, -360, 180), {})
	Fort.Sandbags(ctx, ctx:GroundCF(-190, -420, 180), { length = 8, arc = 50 })
	Props.AmmoCache(ctx, ctx:GroundCF(-150, -430, 0))
	Props.Wreck(ctx, ctx:GroundCF(-90, -440, 30), { kind = "car" })
	Props.Tent(ctx, ctx:GroundCF(-210, -450, 20))
	for _ = 1, 26 do
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(10, 120)
		local sx, sz = -160 + math.cos(a) * d * 1.3, -410 + math.sin(a) * d
		if not nearRoad(sx, sz, 8) then
			stump(ctx, sx, sz, front, rng:NextNumber() < 0.35)
		end
	end
	for _ = 1, 8 do
		local tx, tz = -160 + rng:NextNumber(-150, 150), -410 + rng:NextNumber(-90, 90)
		if not nearRoad(tx, tz, 10) then
			Nature.Tree(ctx, V(tx, tz), "Burnt", 1.1, front)
		end
	end
	-- B: foxhole ridge with a cut firebreak; positions face both ways
	for i = 0, 11 do
		local fx = -40 + i * 30 + rng:NextNumber(-6, 6)
		local fz = -250 + rng:NextNumber(-8, 8)
		if not nearRoad(fx, fz, 8) then
			Fort.Foxhole(ctx, ctx:GroundCF(fx, fz, if i % 2 == 0 then 0 else 180))
		end
	end
	Fort.LogBunker(ctx, ctx:GroundCF(150, -214, 0), {})
	Fort.LogBunker(ctx, ctx:GroundCF(50, -252, 180), {})
	Fort.MGNest(ctx, ctx:GroundCF(200, -240, 0), {})
	Fort.Sandbags(ctx, ctx:GroundCF(126, -220, 0), { length = 10, arc = 60 })
	Fort.Sandbags(ctx, ctx:GroundCF(150, -250, 180), { length = 8, arc = 40 })
	Props.CrateStack(ctx, ctx:GroundCF(126, -244, 0))
	Props.Wreck(ctx, ctx:GroundCF(80, -200, 60), { kind = "halftrack" })
	for _ = 1, 30 do
		local sx, sz = rng:NextNumber(-260, 480), -232 + rng:NextNumber(-34, 34)
		if not nearRoad(sx, sz, 8) then
			stump(ctx, sx, sz, front, rng:NextNumber() < 0.15)
		end
	end
	for _, l in { { -60, -210, 80 }, { 330, -200, 95 }, { 240, -262, 70 } } do
		logPile(ctx, ctx:GroundCF(l[1], l[2], l[3]), 10, 3, front)
	end
	-- E: German log-bunker line on the ridge, linked by a trench, wire in front
	for i, bx in { -210, -100, 30, 140, 260 } do
		local bz = 425 + (if i % 2 == 0 then -8 else 6)
		Fort.LogBunker(ctx, ctx:GroundCF(bx, bz, rng:NextNumber(-8, 8)), { width = 13 })
	end
	Fort.Trench(
		ctx,
		Layout.Zigzag({ V(-250, 452), V(-120, 450), V(-42, 458) }, 3.2, 12),
		{ parapet = "right", sandbags = 0.2, revetment = 0.6 }
	)
	Fort.Trench(
		ctx,
		Layout.Zigzag({ V(50, 460), V(170, 452), V(300, 456) }, 3.2, 12),
		{ parapet = "right", sandbags = 0.2, revetment = 0.6 }
	)
	Fort.MGNest(ctx, ctx:GroundCF(-40, 420, 10), {})
	Fort.MGNest(ctx, ctx:GroundCF(80, 410, -10), {})
	Fort.ATGun(ctx, ctx:GroundCF(40, 432, -5), {})
	Fort.Watchtower(ctx, ctx:GroundCF(-20, 480, 0), { height = 14 })
	Fort.BarbedWire(ctx, { V(-260, 388), V(-120, 380), V(-30, 384) }, { spacing = 12 })
	Fort.BarbedWire(ctx, { V(40, 382), V(170, 378), V(300, 390) }, { spacing = 12 })
	Props.AmmoCache(ctx, ctx:GroundCF(10, 468, 0))
	Props.Tent(ctx, ctx:GroundCF(60, 490, 0))
	Props.CrateStack(ctx, ctx:GroundCF(-50, 470, 30))
	Props.Fire(ctx, V(-28, 494), { size = 3 })
	for _, f in { { -330, 420 }, { 360, 440 }, { -170, 400 }, { 200, 400 } } do
		Fort.Foxhole(ctx, ctx:GroundCF(f[1], f[2], 0))
	end

	-------------------------------------------------------------------------------------------
	-- 5. Forest: clustered pines, glades, hero firs, deadfall
	-------------------------------------------------------------------------------------------
	local forestModels = {}
	local function forestModel(x: number, z: number): Instance
		local key = math.floor((x + 1000) / 250) * 10 + math.floor((z + 1000) / 250)
		local m = forestModels[key]
		if not m then
			m = ctx:Model("Forest", nature)
			forestModels[key] = m
		end
		return m
	end
	local trees, heroes = 0, 0
	local SP = 24
	for gx = -760, 760, SP do
		for gz = -760, 760, SP do
			local x = gx + rng:NextNumber(-0.45, 0.45) * SP
			local z = gz + rng:NextNumber(-0.45, 0.45) * SP
			local dens = Geo.fbm(x, z, 150, 2, 31)
			if dens < -0.2 then
				continue
			end
			if inClearing(x, z) or nearRoad(x, z, 10) or (Geo.distToPath(creekPath, x, z)) < 18 then
				continue
			end
			if dens < 0.1 and rng:NextNumber() < 0.5 then
				continue
			end
			local parentModel = forestModel(x, z)
			if rng:NextNumber() < 0.015 then
				heroes += 1
				Nature.Tree(
					ctx,
					V(x, z),
					if rng:NextNumber() < 0.6 then "Fir" else "Pine",
					rng:NextNumber(1.3, 1.6),
					parentModel
				)
			else
				pine(
					ctx,
					x,
					z,
					rng:NextNumber(0.8, 1.25),
					if dens > 0.4 or rng:NextNumber() < 0.2 then 2 else 1,
					parentModel
				)
			end
			trees += 1
			-- second trunk in the densest clusters
			if dens > 0.45 and rng:NextNumber() < 0.45 then
				local x2, z2 = x + rng:NextNumber(-9, 9), z + rng:NextNumber(-9, 9)
				if not nearRoad(x2, z2, 10) then
					pine(ctx, x2, z2, rng:NextNumber(0.7, 1.0), 1, parentModel)
					trees += 1
				end
			end
		end
	end
	-- sparse trees inside the objective/village clearings (cover without blocking the fight)
	for _, c in CLEARINGS do
		for _ = 1, 5 do
			local a = rng:NextNumber(0, math.pi * 2)
			local d = c[3] * rng:NextNumber(0.6, 0.95)
			local x, z = c[1] + math.cos(a) * d, c[2] + math.sin(a) * d
			if not nearRoad(x, z, 12) and not inClearing(x, z, -c[3] * 0.5) then
				pine(ctx, x, z, rng:NextNumber(0.8, 1.1), 2, nature)
			end
		end
	end
	-- deadfall and snowy undergrowth
	for _ = 1, 50 do
		local x, z = rng:NextNumber(-720, 720), rng:NextNumber(-720, 720)
		if not inClearing(x, z, 10) and not nearRoad(x, z, 10) then
			if rng:NextNumber() < 0.5 then
				stump(ctx, x, z, front, true)
			else
				Nature.Bush(ctx, V(x, z), rng:NextNumber(4, 6), nature)
			end
		end
	end
	ctx:AddMinimap("forest", -480, -520, 520, 420, 0)
	ctx:AddMinimap("forest", 460, -460, 520, 520, 0)
	ctx:AddMinimap("forest", -470, 320, 540, 360, 0)
	ctx:AddMinimap("forest", 520, 340, 420, 420, 0)
	ctx:AddMinimap("forest", 30, 600, 300, 260, 0)
	ctx:AddMinimap("forest", -420, -150, 300, 200, 0)
	ctx:AddMinimap("field", -260, 60, 140, 120, 0)
	ctx:AddMinimap("field", 130, 80, 110, 100, 0)

	-------------------------------------------------------------------------------------------
	-- 6. Battle damage: craters, wrecks
	-------------------------------------------------------------------------------------------
	local craters = 0
	for _ = 1, 140 do
		if craters >= 36 then
			break
		end
		local cx, cz = rng:NextNumber(-650, 650), rng:NextNumber(-560, 520)
		local nearA = (cx + 160) ^ 2 + (cz + 410) ^ 2 < 160 ^ 2
		if
			(nearA or rng:NextNumber() < 0.35)
			and not nearRoad(cx, cz, 12)
			and not inClearing(cx, cz, -30)
			and (Geo.distToPath(creekPath, cx, cz)) > 30
			and (cx - 80) ^ 2 + (cz + 630) ^ 2 > 150 ^ 2
			and (cx + 200) ^ 2 + (cz - 660) ^ 2 > 150 ^ 2
		then
			craters += 1
			Terrain.Crater(ctx, V(cx, cz), rng:NextNumber(4, 8), { material = M.Ground, outerMaterial = M.Snow })
		end
	end
	Props.Wreck(ctx, ctx:GroundCF(96, -110, 20), { kind = "tank" })
	Props.Wreck(ctx, ctx:GroundCF(-14, 300, -10), { kind = "halftrack", burning = true })
	Props.Wreck(ctx, ctx:GroundCF(-280, -320, 80), { kind = "truck" })
	Props.Wreck(ctx, ctx:GroundCF(360, 420, 40), { kind = "tank", noTurret = true })

	-------------------------------------------------------------------------------------------
	-- 7. HQs, objectives, MapInfo
	-------------------------------------------------------------------------------------------
	local alliesHQ = Layout.SpawnArea(ctx, HQ_ALLIES, "Allies", { spawnCount = 10, vehicleCount = 4 })
	local axisHQ = Layout.SpawnArea(ctx, HQ_AXIS, "Axis", { spawnCount = 10, vehicleCount = 4 })

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
		id = "Ardennes",
		bounds = { center = Vector3.new(0, 60, 0), size = Vector3.new(SIZE, 700, SIZE) },
		hq = { Allies = alliesHQ.spawns, Axis = axisHQ.spawns },
		objectives = objectives,
		vehicleSpawns = {
			Allies = vehicles(alliesHQ.vehicles, { "Tank", "Jeep", "Transport", "Light" }),
			Axis = vehicles(axisHQ.vehicles, { "Tank", "Jeep", "Transport", "Light" }),
		},
		outOfBounds = 10,
	})
end

return Ardennes
