--[[
	Stalingrad — "Red October Ruins" (≈1100 x 1100 studs). Map team. Infantry focused.

	A shattered factory district on the west bank of the frozen Volga. The Soviets (Allies) cling to
	the riverbank under the bluff (east); the Germans (Axis) push in from the western suburbs.

	   x=-550                                                                    x=+550
	     ┌─────────┬─────────┬───────────────────┬─────────┬──────────┬──bluff──┬~~~~~┐
	z+430│ houses  │ apts    │ houses / park     │ apts    │ houses   │ trench  │ ice │
	     ├────═════┼═════════┼═══════════════════┼═════════┼══════════┤  line   │  V  │
	     │ apts    │D Tram   │ apts              │B Apart- │ apts     │         │  o  │
	     │ [AXIS   │ Depot   │                   │ ment    │          │  [ALLIED│  l  │
	     │  HQ]    ├═════════┼═══ Red October ═══┼═════════┼══════════┤   HQ]   │  g  │
	     │ apts    │ ruins   │  C factory hall   │ apts    │ houses   │ (under  │  a  │
	     ├═════════┼═════════┤  + chimneys       ├═════════┼══════════┤  bluff) │     │
	     │E Square │ apts    │                   │ apts    │A Landing │         │     │
	     ├═════════┼═════════┼═══════════════════┼═════════┼══════════┤         │     │
	z-400│ houses  │ apts    │ apts              │ houses  │ houses   │         │     │
	     └──────── gully (south flank route) ──────────────────────────────────────────┘

	Objectives (order 1 = Allied end): A Volga Landing (riverside warehouse), B Apartment Block
	(courtyard between two enterable blocks), C Red October Hall (centre, huge ruined hall),
	D Tram Depot, E Fountain Square. Every street has rubble, craters, wrecks and barricades;
	courtyards are cut by trenches. Allied HQ is shielded by the bluff, the Axis HQ by berms and ruins.
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

local Stalingrad = {}

local SIZE = 1100
local SEED = 1942
local STREET = 22

local X_LINES = { -420, -280, -130, 130, 280, 390 }
local Z_LINES = { -400, -230, -60, 110, 280, 430 }

local HQ_ALLIES = CFrame.new(472, 0, 30) * CFrame.Angles(0, math.rad(90), 0) -- faces west (-X)
local HQ_AXIS = CFrame.new(-488, 0, 20) * CFrame.Angles(0, math.rad(-90), 0) -- faces east (+X)

local OBJECTIVES = {
	{ id = "A", name = "Volga Landing", pos = V(335, -120), radius = 30, owner = "Allies" },
	{ id = "B", name = "Apartment Block", pos = V(205, 195), radius = 30, owner = "Neutral" },
	{ id = "C", name = "Red October Hall", pos = V(0, -60), radius = 34, owner = "Neutral", flag = V(10, -60) },
	{ id = "D", name = "Tram Depot", pos = V(-205, 195), radius = 32, owner = "Neutral", flag = V(-215, 195) },
	{ id = "E", name = "Fountain Square", pos = V(-350, -145), radius = 32, owner = "Axis", flag = V(-332, -128) },
}

local GULLY = { V(-600, -470), V(-300, -445), V(-100, -472), V(120, -452), V(330, -470), V(520, -455) }

-- Is (x, z) on a street (outside building blocks)?
local function onStreet(x: number, z: number, margin: number?): boolean
	local m = (margin or 0) + STREET / 2
	for _, lx in X_LINES do
		if math.abs(x - lx) < m and z > -420 and z < 450 then
			return true
		end
	end
	for _, lz in Z_LINES do
		if math.abs(z - lz) < m and x > -440 and x < 400 then
			-- no street through the factory compound
			if lz == -60 and x > -130 + STREET / 2 and x < 130 - STREET / 2 then
				continue
			end
			return true
		end
	end
	return false
end

function Stalingrad.Build(parent: Folder, _def: any)
	local ctx = MapKit.new(parent, { seed = SEED })
	local rng = ctx.rng

	Terrain.ApplyPalette({
		Snow = rgb(206, 210, 216),
		Asphalt = rgb(70, 70, 70),
		Ground = rgb(84, 74, 62),
		Mud = rgb(62, 54, 46),
		Concrete = rgb(118, 116, 110),
		Brick = rgb(112, 70, 56),
		Ice = rgb(170, 188, 200),
	}, { color = rgb(60, 70, 74), decoration = false })

	-------------------------------------------------------------------------------------------
	-- 1. Terrain: city plateau, bluff, frozen Volga, southern gully
	-------------------------------------------------------------------------------------------
	local hm = Terrain.HeightModel({ baseY = 6, seed = SEED })
	hm:Noise(1.6, 120, 2)
	hm:Custom(function(x, z, h)
		-- frame: rubble hills beyond the north/south/west bounds
		local e = math.max(-x, math.abs(z))
		return h + Geo.smoothstep(560, 720, e) * 40
	end)
	hm:Custom(function(x, _z, h)
		-- the bluff down to the riverbank
		return Geo.lerp(h, -2, Geo.smoothstep(392, 428, x))
	end)
	hm:River({ V(680, -900), V(680, 900) }, { width = 230, bank = 34, bedY = -12, waterY = -4, frozen = true })
	hm:Channel(GULLY, 18, 9, 18)
	Layout.PrepareHQ(hm, HQ_AXIS)
	hm:FlattenRect(HQ_ALLIES.Position.X, HQ_ALLIES.Position.Z, 160, 96, 90, -1.5, 20)

	local mm = Terrain.MaterialModel({ base = M.Snow, subsurface = M.Ground, seed = SEED })
	mm:Patches(M.Ground, 30, 0.55)
	-- streets
	for _, lx in X_LINES do
		mm:Rect(lx, 15, STREET, 870, 0, M.Asphalt, 2)
	end
	for _, lz in Z_LINES do
		if lz == -60 then
			mm:Rect(-280, lz, 300, STREET, 0, M.Asphalt, 2)
			mm:Rect(260, lz, 260, STREET, 0, M.Asphalt, 2)
		else
			mm:Rect(-20, lz, 860, STREET, 0, M.Asphalt, 2)
		end
	end
	mm:Rect(-350, -145, 112, 140, 0, M.Pavement, 3) -- fountain square
	mm:Rect(0, -60, 230, 310, 0, M.Concrete, 6) -- factory yard
	mm:Patches(M.Snow, 22, 0.35) -- drifts over everything
	mm:Patches(M.Mud, 40, 0.7)
	mm:Custom(M.Sand, function(x, _z, h)
		return x > 430 and h < -1 and h > -5
	end)
	mm:Slope(M.Ground, 0.6)
	mm:Path(GULLY, 14, M.Mud, 3)

	Terrain.Generate(ctx, hm, mm, { center = V(40, 0), size = Vector2.new(1500, 1400) })

	for _, lx in X_LINES do
		ctx:AddMinimap("road", lx, 15, STREET, 870, 0)
	end
	for _, lz in Z_LINES do
		ctx:AddMinimap("road", -20, lz, 860, STREET, 0)
	end
	ctx:AddMinimap("water", 650, 0, 220, 1100, 0)

	-------------------------------------------------------------------------------------------
	-- 2. Generic city blocks
	-------------------------------------------------------------------------------------------
	local wallStyles = { "Soviet", "Soviet", "SovietBrick" }
	local function apartment(x: number, z: number, yaw: number, w: number, opts: { [string]: any }?)
		local o = {
			style = wallStyles[rng:NextInteger(1, #wallStyles)],
			width = w,
			depth = 16,
			floors = rng:NextInteger(3, 5),
			ruin = rng:NextNumber(0.45, 0.9),
			enterable = rng:NextNumber() < 0.35,
			balconies = rng:NextNumber() < 0.5,
		}
		if opts then
			for k, v in opts do
				o[k] = v
			end
		end
		return Buildings.Apartment(ctx, ctx:GroundCF(x, z, yaw), o)
	end

	local function courtyard(cx: number, cz: number, w: number, d: number)
		local r = rng:NextNumber()
		if r < 0.5 and w > 50 and d > 40 then
			local pts = { V(cx - w * 0.38, cz + rng:NextNumber(-d, d) * 0.2), V(cx + w * 0.38, cz + rng:NextNumber(-d, d) * 0.2) }
			Fort.Trench(ctx, Layout.Zigzag(pts, 3, 11), { parapet = "both", revetment = 0.5, sandbags = 0.15, depth = 5.5 })
		elseif r < 0.75 then
			Fort.MGNest(ctx, ctx:GroundCF(cx + rng:NextNumber(-10, 10), cz, rng:NextNumber(0, 360)), {})
		end
		Props.RubblePile(ctx, V(cx + rng:NextNumber(-w, w) * 0.3, cz + rng:NextNumber(-d, d) * 0.3), {
			radius = rng:NextNumber(5, 9),
			height = rng:NextNumber(2.5, 4.5),
			pieces = 4,
		})
		if rng:NextNumber() < 0.5 then
			Nature.Tree(ctx, V(cx + rng:NextNumber(-w, w) * 0.35, cz + rng:NextNumber(-d, d) * 0.35), "Burnt", 1)
		end
	end

	local function apartmentsBlock(x0: number, x1: number, z0: number, z1: number)
		local ix0, ix1, iz0, iz1 = x0 + 13, x1 - 13, z0 + 13, z1 - 13
		local bw, bd = ix1 - ix0, iz1 - iz0
		local cx, cz = (ix0 + ix1) / 2, (iz0 + iz1) / 2
		if bw >= bd then
			local w = math.min(bw - 8, 56)
			for side = -1, 1, 2 do
				local z = if side < 0 then iz0 + 8 else iz1 - 8
				local yaw = if side < 0 then 0 else 180
				if rng:NextNumber() < 0.25 then
					Buildings.RuinedWall(ctx, ctx:GroundCF(cx, z, yaw), w * 0.8, rng:NextNumber(10, 22), { ruin = 0.7 })
					Props.RubblePile(ctx, V(cx, z - side * 6), { radius = 12, height = 5 })
				else
					apartment(cx + rng:NextNumber(-4, 4), z, yaw, w)
				end
			end
			courtyard(cx, cz, bw, bd - 32)
		else
			local w = math.min(bd - 8, 56)
			for side = -1, 1, 2 do
				local x = if side < 0 then ix0 + 8 else ix1 - 8
				local yaw = if side < 0 then 90 else -90
				if rng:NextNumber() < 0.25 then
					Buildings.RuinedWall(ctx, ctx:GroundCF(x, cz, yaw), w * 0.8, rng:NextNumber(10, 22), { ruin = 0.7 })
					Props.RubblePile(ctx, V(x - side * 6, cz), { radius = 12, height = 5 })
				else
					apartment(x, cz + rng:NextNumber(-4, 4), yaw, w)
				end
			end
			courtyard(cx, cz, bw - 32, bd)
		end
	end

	local function housesBlock(x0: number, x1: number, z0: number, z1: number)
		local ix0, ix1, iz0, iz1 = x0 + 13, x1 - 13, z0 + 13, z1 - 13
		-- four corner houses facing the streets, rubble and ruins between
		local spots = {
			{ ix0 + 12, iz0 + 9, 0 },
			{ ix1 - 12, iz0 + 9, 0 },
			{ ix0 + 12, iz1 - 9, 180 },
			{ ix1 - 12, iz1 - 9, 180 },
		}
		for _, s in spots do
			local roll = rng:NextNumber()
			if roll < 0.7 then
				Buildings.House(ctx, ctx:GroundCF(s[1], s[2], s[3]), {
					style = if rng:NextNumber() < 0.5 then "Brick" else "Soviet",
					width = rng:NextNumber(18, 22),
					depth = 14,
					floors = rng:NextInteger(2, 3),
					ruin = rng:NextNumber(0.4, 0.95),
					enterable = rng:NextNumber() < 0.5,
					roof = if rng:NextNumber() < 0.5 then "flat" else "gable",
				})
			else
				Buildings.RuinedWall(ctx, ctx:GroundCF(s[1], s[2], s[3]), 18, rng:NextNumber(7, 14), { style = "Brick" })
			end
		end
		local cx, cz = (ix0 + ix1) / 2, (iz0 + iz1) / 2
		Props.RubblePile(ctx, V(cx, cz), { radius = rng:NextNumber(7, 11), height = 4 })
		if rng:NextNumber() < 0.6 then
			Fort.Foxhole(ctx, ctx:GroundCF(cx + rng:NextNumber(-15, 15), cz + rng:NextNumber(-15, 15), rng:NextNumber(0, 360)))
		end
		if rng:NextNumber() < 0.5 then
			Nature.Tree(ctx, V(cx + rng:NextNumber(-20, 20), cz + rng:NextNumber(-20, 20)), "Dead", 1)
		end
	end

	-- Block plan: [xi][zi] = kind (x intervals between X_LINES, z intervals between Z_LINES)
	local PLAN = {
		{ "houses", "square", "apts", "apts", "houses" }, -- x -420..-280
		{ "apts", "apts", "houses", "depot", "apts" }, -- x -280..-130
		{ "apts", "factory", "factory", "apts", "park" }, -- x -130..130
		{ "houses", "apts", "apts", "blockB", "apts" }, -- x 130..280
		{ "houses", "landing", "houses", "apts", "houses" }, -- x 280..390
	}
	for xi = 1, #X_LINES - 1 do
		for zi = 1, #Z_LINES - 1 do
			local kind = PLAN[xi][zi]
			local x0, x1, z0, z1 = X_LINES[xi], X_LINES[xi + 1], Z_LINES[zi], Z_LINES[zi + 1]
			if kind == "apts" then
				apartmentsBlock(x0, x1, z0, z1)
			elseif kind == "houses" then
				housesBlock(x0, x1, z0, z1)
			end
		end
	end

	-------------------------------------------------------------------------------------------
	-- 3. C: Red October factory compound (centre column, z -230..110)
	-------------------------------------------------------------------------------------------
	Buildings.FactoryHall(ctx, ctx:GroundCF(0, -60, 0), { width = 110, depth = 56, height = 24, ruin = 0.62, name = "RedOctoberHall" })
	Buildings.Chimney(ctx, V(78, 40), { height = 72, radius = 5, ruin = 0.15 })
	Buildings.Chimney(ctx, V(-82, 44), { height = 60, radius = 4.5, ruin = 0.6 })
	Buildings.FactoryHall(ctx, ctx:GroundCF(-35, -180, 0), { width = 64, depth = 30, height = 14, ruin = 0.75, bay = 10, crane = false })
	Buildings.House(ctx, ctx:GroundCF(70, -185, 0), { style = "SovietBrick", width = 26, depth = 16, floors = 2, ruin = 0.5, roof = "flat", name = "Offices" })
	Props.Railway(ctx, { V(-140, 60), V(-60, 62), V(40, 66), V(118, 70) }, { broken = { { -20, 63, 9 } } })
	Props.Wreck(ctx, ctx:GroundCF(-30, 64, 90), { kind = "truck", color = rgb(60, 56, 50) })
	Props.Wreck(ctx, ctx:GroundCF(60, -120, 30), { kind = "tank", burning = true })
	Props.BarrelGroup(ctx, ctx:GroundCF(-70, -120, 0), { count = 5 })
	Props.CrateStack(ctx, ctx:GroundCF(45, -10, 20))
	Props.CrateStack(ctx, ctx:GroundCF(-100, -20, 0))
	Fort.Trench(ctx, Layout.Zigzag({ V(-110, -120), V(-40, -128), V(30, -125), V(110, -118) }, 3, 12), { parapet = "both", sandbags = 0.25 })
	Fort.Barricade(ctx, ctx:GroundCF(-118, -60, 90), { kind = "debris", length = 14 })
	Fort.Barricade(ctx, ctx:GroundCF(118, -40, -90), { kind = "debris", length = 14 })
	Fort.MGNest(ctx, ctx:GroundCF(95, 0, -90), {})
	Fort.MGNest(ctx, ctx:GroundCF(-95, -100, 90), {})
	for _ = 1, 6 do
		Terrain.Crater(ctx, V(rng:NextNumber(-110, 110), rng:NextNumber(-220, -100)), rng:NextNumber(4, 7), {})
	end
	Props.Fire(ctx, V(-12, -40), { size = 7 })
	ctx:AddMinimap("building", 0, 40, 30, 20, 0)

	-------------------------------------------------------------------------------------------
	-- 4. B: two enterable apartment blocks with a fortified courtyard
	-------------------------------------------------------------------------------------------
	apartment(205, 131, 0, 64, { floors = 5, ruin = 0.45, enterable = true, style = "Soviet" })
	apartment(205, 259, 180, 64, { floors = 4, ruin = 0.6, enterable = true, style = "SovietBrick" })
	Fort.Trench(ctx, Layout.Zigzag({ V(150, 190), V(260, 200) }, 3, 11), { parapet = "both", sandbags = 0.3 })
	Fort.MGNest(ctx, ctx:GroundCF(170, 165, 180), {})
	Fort.MGNest(ctx, ctx:GroundCF(245, 228, 0), {})
	Props.RubblePile(ctx, V(150, 230), { radius = 9, height = 4 })
	Props.CrateStack(ctx, ctx:GroundCF(225, 175, 0), { kind = "wood" })
	Nature.Tree(ctx, V(190, 225), "Burnt", 1.1)
	Nature.Tree(ctx, V(232, 158), "Dead", 1)

	-------------------------------------------------------------------------------------------
	-- 5. D: tram depot with tracks
	-------------------------------------------------------------------------------------------
	Buildings.FactoryHall(ctx, ctx:GroundCF(-205, 195, 0), {
		width = 110,
		depth = 50,
		height = 16,
		bay = 11,
		ruin = 0.55,
		crane = false,
		machines = false,
		style = "Brick",
		name = "TramDepot",
	})
	for _, dz in { -10, 10 } do
		Props.Railway(ctx, { V(-440, 195 + dz), V(-300, 195 + dz), V(-180, 195 + dz) }, { gauge = 4, sleeper = 7 })
	end
	local function tram(x: number, z: number, yaw: number, tilt: number)
		local cf = ctx:GroundCF(x, z, yaw) * CFrame.Angles(0, 0, tilt)
		local m = ctx:Model("Tram", ctx:Folder("Props"))
		ctx:Part({ Name = "Body", Parent = m, Size = Vector3.new(7, 5, 24), CFrame = cf * CFrame.new(0, 3.8, 0), Material = M.CorrodedMetal, Color = rgb(120, 86, 52), NoPenetration = true })
		ctx:Part({ Name = "Windows", Parent = m, Size = Vector3.new(7.2, 1.6, 20), CFrame = cf * CFrame.new(0, 4.6, 0), Material = M.Glass, Color = rgb(30, 30, 30), CastShadow = false })
		ctx:Part({ Name = "Roof", Parent = m, Size = Vector3.new(6.4, 0.6, 23), CFrame = cf * CFrame.new(0, 6.6, 0), Material = M.CorrodedMetal, Color = rgb(70, 64, 58) })
		ctx:Part({ Name = "Chassis", Parent = m, Size = Vector3.new(5, 1.4, 20), CFrame = cf * CFrame.new(0, 0.9, 0), Material = M.Metal, Color = rgb(40, 38, 36), CastShadow = false })
	end
	tram(-330, 185, 90, 0)
	tram(-215, 205, 90, 0)
	tram(-110, 300, 20, 1.3) -- on its side in the street
	Fort.Barricade(ctx, ctx:GroundCF(-130, 160, 90), { kind = "wood", length = 12 })
	Fort.Sandbags(ctx, ctx:GroundCF(-150, 230, -90), { length = 10, arc = 60 })
	Fort.Sandbags(ctx, ctx:GroundCF(-262, 160, 90), { length = 10, arc = 60 })
	Props.Fire(ctx, V(-240, 214), { size = 5 })

	-------------------------------------------------------------------------------------------
	-- 6. E: fountain square
	-------------------------------------------------------------------------------------------
	Props.Fountain(ctx, ctx:GroundCF(-350, -145, 0), { radius = 9, ruined = true })
	for _, t in { { -395, -200 }, { -305, -200 }, { -395, -90 }, { -305, -90 }, { -350, -210 }, { -350, -82 } } do
		Nature.Tree(ctx, V(t[1], t[2]), if rng:NextNumber() < 0.5 then "Burnt" else "Dead", 1.1)
	end
	for _, b in { { -380, -145, -90 }, { -320, -145, 90 }, { -350, -175, 180 } } do
		Props.Bench(ctx, ctx:GroundCF(b[1], b[2], b[3]))
	end
	Props.Wreck(ctx, ctx:GroundCF(-330, -195, 120), { kind = "tank", burning = false })
	Props.Wreck(ctx, ctx:GroundCF(-385, -110, 10), { kind = "halftrack" })
	Fort.Sandbags(ctx, ctx:GroundCF(-370, -120, 90), { length = 9, arc = 70 })
	Fort.Sandbags(ctx, ctx:GroundCF(-325, -170, -90), { length = 9, arc = 70 })
	Fort.TankTraps(ctx, { V(-405, -225), V(-295, -225) }, { kind = "hedgehog", spacing = 12 })
	Props.LampPost(ctx, ctx:GroundCF(-400, -150, 0))
	Props.LampPost(ctx, ctx:GroundCF(-300, -140, 0))
	Terrain.Crater(ctx, V(-360, -105), 6, {})
	Terrain.Crater(ctx, V(-318, -182), 5, {})

	-------------------------------------------------------------------------------------------
	-- 7. A: Volga landing — riverside warehouse, bluff-top trench line, jetty on the ice
	-------------------------------------------------------------------------------------------
	Buildings.FactoryHall(ctx, ctx:GroundCF(335, -120, 0), {
		width = 60,
		depth = 34,
		height = 13,
		bay = 10,
		ruin = 0.5,
		crane = false,
		style = "Brick",
		name = "Warehouse",
	})
	Buildings.House(ctx, ctx:GroundCF(320, -200, 0), { style = "SovietBrick", width = 22, depth = 14, floors = 2, ruin = 0.65, roof = "flat" })
	Props.CrateStack(ctx, ctx:GroundCF(305, -78, 0))
	Props.CrateStack(ctx, ctx:GroundCF(365, -80, 0))
	Props.BarrelGroup(ctx, ctx:GroundCF(372, -160, 0))
	Fort.Trench(ctx, Layout.Zigzag({ V(410, -300), V(412, -170), V(410, -45) }, 3, 12), { parapet = "right", sandbags = 0.3 })
	Fort.Trench(ctx, Layout.Zigzag({ V(410, 115), V(412, 230), V(410, 330) }, 3, 12), { parapet = "right", sandbags = 0.3 })
	Fort.MGNest(ctx, ctx:GroundCF(402, -100, 90), {})
	Fort.MGNest(ctx, ctx:GroundCF(402, 170, 90), {})
	Fort.ATGun(ctx, ctx:GroundCF(398, 60, 90), {})
	Props.WoodBridge(ctx, V(520, -150), V(600, -150), { width = 6 }) -- jetty
	Props.Wreck(ctx, ctx:GroundCF(560, -60, 30), { kind = "truck", snap = false } :: any)
	for _, p in { { 450, -250 }, { 440, 210 }, { 455, 300 } } do
		Props.CrateStack(ctx, ctx:GroundCF(p[1], p[2], 0))
	end

	-------------------------------------------------------------------------------------------
	-- 8. Streets: rubble, craters, wrecks, barricades, hedgehogs, fires
	-------------------------------------------------------------------------------------------
	local streetSpots = {}
	for _ = 1, 400 do
		local x, z = rng:NextNumber(-430, 395), rng:NextNumber(-410, 440)
		if onStreet(x, z, -3) then
			table.insert(streetSpots, V(x, z))
		end
		if #streetSpots >= 70 then
			break
		end
	end
	for i, p in streetSpots do
		local roll = i % 7
		if roll == 0 or roll == 3 then
			Terrain.Crater(ctx, p, rng:NextNumber(4, 7.5), { material = M.Mud })
		elseif roll == 1 then
			Props.RubblePile(ctx, p, { radius = rng:NextNumber(5, 9), height = rng:NextNumber(2, 4), pieces = 3 })
		elseif roll == 2 then
			Props.Wreck(ctx, ctx:GroundCF(p.X, p.Z, rng:NextNumber(0, 360)), {
				kind = ({ "truck", "car", "tank", "halftrack" })[rng:NextInteger(1, 4)],
			})
		elseif roll == 4 then
			Fort.Hedgehog(ctx, p)
			Fort.Hedgehog(ctx, p + V(rng:NextNumber(4, 7), rng:NextNumber(-4, 4)))
		elseif roll == 5 then
			Fort.Barricade(ctx, ctx:GroundCF(p.X, p.Z, rng:NextNumber(0, 180)), { kind = if rng:NextNumber() < 0.5 then "debris" else "wood" })
		else
			Props.Debris(ctx, p, { radius = 6, count = 5 })
		end
	end
	for _, f in { V(-130, 0), V(130, 110), V(280, -230), V(-280, 330) } do
		Props.Fire(ctx, f, { size = 5 })
	end
	-- Telegraph poles, many leaning or down
	Props.TelegraphLine(ctx, { V(-410, -400), V(-410, 420) }, { leanChance = 0.5, downChance = 0.25, spacing = 46 })
	Props.TelegraphLine(ctx, { V(-430, 98), V(380, 98) }, { leanChance = 0.5, downChance = 0.25, spacing = 46 })
	-- Park block north of the factory (x -130..130, z 280..430): shattered trees and foxholes
	Nature.Forest(ctx, { center = V(0, 355), size = Vector2.new(220, 120) }, {
		kinds = { "Burnt", "Dead", "Dead" },
		spacing = 22,
		bushes = 0.1,
		minimap = false,
	})
	for _ = 1, 5 do
		Fort.Foxhole(ctx, ctx:GroundCF(rng:NextNumber(-100, 100), rng:NextNumber(300, 410), rng:NextNumber(0, 360)))
	end
	for _ = 1, 6 do
		Terrain.Crater(ctx, V(rng:NextNumber(-100, 100), rng:NextNumber(300, 410)), rng:NextNumber(5, 8), {})
	end
	-- Gully: dead trees and wire along the southern flank
	Layout.AlongPath(ctx, GULLY, 40, function(cf)
		if rng:NextNumber() < 0.5 then
			Nature.Tree(ctx, cf.Position + cf.RightVector * rng:NextNumber(-16, 16), "Dead", 0.9)
		end
	end)
	Fort.BarbedWire(ctx, { V(-200, -425), V(-60, -432) }, {})
	ctx:AddMinimapPath("trench", GULLY, 18)

	-------------------------------------------------------------------------------------------
	-- 9. HQs, objectives, MapInfo
	-------------------------------------------------------------------------------------------
	local alliesHQ = Layout.SpawnArea(ctx, HQ_ALLIES, "Allies", { spawnCount = 10, vehicleCount = 3, width = 130 })
	local axisHQ = Layout.SpawnArea(ctx, HQ_AXIS, "Axis", { spawnCount = 10, vehicleCount = 3, width = 130 })
	-- Ruined facades screening the Axis HQ from the avenue
	Buildings.RuinedWall(ctx, ctx:GroundCF(-436, -40, -90), 30, 16, { style = "SovietBrick", ruin = 0.4 })
	Buildings.RuinedWall(ctx, ctx:GroundCF(-436, 80, -90), 30, 16, { style = "SovietBrick", ruin = 0.4 })

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

	local classes = { "Tank", "Jeep", "Transport" }
	local function vehicles(list: { CFrame })
		local out = {}
		for i, cf in list do
			table.insert(out, { cframe = cf, class = classes[i] or "Jeep" })
		end
		return out
	end

	return MapKit.Finish(ctx, {
		id = "Stalingrad",
		bounds = { center = Vector3.new(0, 40, 0), size = Vector3.new(SIZE, 600, SIZE) },
		hq = { Allies = alliesHQ.spawns, Axis = axisHQ.spawns },
		objectives = objectives,
		vehicleSpawns = { Allies = vehicles(alliesHQ.vehicles), Axis = vehicles(axisHQ.vehicles) },
		outOfBounds = 10,
	})
end

return Stalingrad
