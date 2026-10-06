--[[
	AtlanticWall — "Atlantic Wall" (≈1600 x 1200 studs). Map team (B).

	A defended Normandy beach. The Allies land from the sea in the south and must cross the
	beach obstacles, the shingle bank and the sea wall, then climb the bluffs (or push vehicles up
	the draw) to reach the trench line, the ruined village and the coastal battery in the north.

	   z=+600 ┌─────────────────────────────────────────────────────────────────┐
	          │ forest        hedgerows      [AXIS HQ] (200,525)      forest    │
	          │       E Batterie de Longues (-130,390)  4 casemates, flak, wire  │
	          │   orchard          ════ road ════╗                               │
	          │ ═══════════ lateral road ════ D Colleville (100,150) ═══════════ │
	          │                   (ruined village, church)                       │
	          │   C Widerstandsnest (-120,-100)  trench net, bunkers, MGs         │
	          │ ═══ crest trench ═══ MG ══ bunker ══╗ draw ╔══ bunker ══ trench ═ │
	          │ /// bluff face ///// gully ////////  B Draw E-1 (170,-190) /////  │
	          │ villas ▀▀ sea wall ▀▀▀ breach ▀▀▀▀▀▀▀ gap ▀▀▀▀▀ breach ▀▀ villas  │
	          │ ~~ shingle ~~ dune [ALLIED HQ] dune ~~~ shingle ~~~~~~~~~~~~~~~~ │
	          │     x  x  hedgehogs  ▭ LST   x  A Dog Green (-40,-380) x  x     │
	          │≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈ sea, landing craft wrecks in the shallows ≈≈≈≈≈≈≈≈│
	   z=-600 └─────────────────────────────────────────────────────────────────┘
	           x=-800                                                      x=+800

	Objectives (order 1 = Allied end): A Dog Green (beach), B Draw E-1 (the ravine road up the
	bluffs, pillboxes on both shoulders), C Widerstandsnest (trench network on the bluff top),
	D Colleville (ruined village), E Batterie de Longues (casemates on the battery hill).
	Routes: the draw (only vehicle route off the beach), a western infantry gully, an eastern
	switchback path, and the bluff face itself. The Allied HQ sits on the sand behind a beached
	LST with tall dunes on both flanks, so the bluffs have no sightline into the spawn.
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

local AtlanticWall = {}

local SIZE_X, SIZE_Z = 1600, 1200
local SEED = 1406

-- Coastline profile ---------------------------------------------------------------------------------

local SEA_LEVEL = 0
local PLATEAU_Y = 34

local function waterZ(x: number): number
	return -470 + 16 * math.sin(x / 210 + 0.7)
end
local function wallZ(x: number): number
	return -288 + 6 * math.sin(x / 300)
end
-- middle of the bluff face (toe ~45 studs seaward, crest ~35 studs inland)
local function bluffZ(x: number): number
	return -192 + 16 * math.sin(x / 190 + 1.3) + 7 * math.sin(x / 77)
end
local function crestZ(x: number): number
	return bluffZ(x) + 38
end

local function profile(x: number, z: number): number
	local wz, sw, bz = waterZ(x), wallZ(x), bluffZ(x)
	if z < wz then
		return math.max(-18, SEA_LEVEL - (wz - z) * 0.07)
	end
	local beach = 0.4 + 2.8 * math.clamp((z - wz) / (sw - wz), 0, 1)
	local strip = Geo.lerp(beach, 5.5, Geo.smoothstep(sw - 2, sw + 6, z))
	local s = Geo.smoothstep(bz - 45, bz + 35, z)
	local y = Geo.lerp(strip, PLATEAU_Y, s)
	-- rolling fields on the plateau only
	local inland = Geo.smoothstep(bz + 25, bz + 110, z)
	return y + Geo.fbm(x, z, 240, 3, 7) * 6 * inland + Geo.fbm(x, z, 60, 2, 9) * 1.2 * inland
end

-- Layout data -----------------------------------------------------------------------------------------

local HQ_ALLIES = CFrame.new(-300, 0, -430) * CFrame.Angles(0, math.pi, 0) -- faces north (+Z)
local HQ_AXIS = CFrame.new(200, 0, 525) -- faces south (-Z)

-- The draw: ravine road from the beach exit up to the plateau
local DRAW = { V(186, -300), V(180, -245), V(166, -185), V(150, -125), V(138, -60) }
local GULLY = { V(-468, -275), V(-478, -215), V(-496, -160), V(-505, -120) }
local SWITCHBACK = { V(520, -266), V(600, -244), V(545, -214), V(615, -186), V(575, -150), V(560, -110) }

local ROADS = {
	coast = { V(-790, -276), V(-400, -278), V(0, -272), V(400, -278), V(790, -270) },
	draw = DRAW,
	north = { V(138, -60), V(110, 40), V(100, 100), V(100, 240), V(100, 300), V(150, 420), V(200, 470), V(200, 620) },
	lateral = { V(-790, 170), V(-400, 150), V(-100, 160), V(30, 155), V(170, 150), V(450, 175), V(790, 160) },
	battery = { V(110, 330), V(60, 385), V(-130, 390), V(-330, 394) },
	crestWest = { V(110, 40), V(-40, -20), V(-200, -60), V(-420, -70), V(-505, -120) },
}

local OBJECTIVES = {
	{ id = "A", name = "Dog Green", pos = V(-40, -380), radius = 34, owner = "Allies" },
	{ id = "B", name = "Draw E-1", pos = V(170, -190), radius = 28, owner = "Neutral", flag = V(170, -196) },
	{ id = "C", name = "Widerstandsnest", pos = V(-120, -100), radius = 32, owner = "Neutral" },
	{ id = "D", name = "Colleville", pos = V(100, 150), radius = 32, owner = "Neutral", flag = V(92, 160) },
	{ id = "E", name = "Batterie de Longues", pos = V(-130, 390), radius = 36, owner = "Axis", flag = V(-130, 372) },
}

local VILLAGE = { cx = 100, cz = 150, sx = 300, sz = 230 }
local PROMENADE_WIRE = { { -440, -340 }, { -60, 120 }, { 400, 500 } }

local EXCLUDE = {
	{ -300, -430, 150 }, -- Allied HQ
	{ 200, 525, 130 }, -- Axis HQ
	{ -130, 380, 170 }, -- battery
	{ -120, -100, 90 }, -- C
	{ 170, -190, 60 }, -- B
}

-- Helpers ---------------------------------------------------------------------------------------------

local preparedRoads: { any } = {}
local drawPath = Geo.path(DRAW)
local gullyPath = Geo.path(GULLY)

local function nearRoad(x: number, z: number, margin: number): boolean
	for _, p in preparedRoads do
		if (Geo.distToPath(p, x, z)) < margin then
			return true
		end
	end
	return false
end

local function excluded(x: number, z: number, pad: number?): boolean
	local extra = pad or 0
	for _, e in EXCLUDE do
		local r = e[3] + extra
		if (x - e[1]) ^ 2 + (z - e[2]) ^ 2 < r * r then
			return true
		end
	end
	return false
end

local function inVillage(x: number, z: number, pad: number?): boolean
	local p = pad or 0
	return Geo.inRect(x, z, VILLAGE.cx, VILLAGE.cz, VILLAGE.sx + p, VILLAGE.sz + p, 0)
end

-- Ravine carve: floor rises linearly from y0 to y1 along the path, banks blend back to h.
local function ravine(hm: any, path: any, half: number, bank: number, y0: number, y1: number)
	local reach = half + bank
	hm:Custom(function(x, z, h)
		local d, _, _, a = Geo.distToPath(path, x, z)
		if d >= reach then
			return h
		end
		local floor = Geo.lerp(y0, y1, math.clamp(a / path.length, 0, 1))
		return math.min(h, Geo.lerp(floor, h, Geo.smoothstep(half, reach, d)))
	end, { path.minX - reach, path.maxX + reach, path.minZ - reach, path.maxZ + reach })
end

-- Remove objective spawns that ended up in the sea; top up from dry ground around the point.
local function drySpawns(ctx: any, hm: any, obj: { [string]: any }, minCount: number)
	local function wet(x: number, z: number): boolean
		local w = hm:WaterAt(x, z)
		return w ~= nil and w > hm:Get(x, z) + 0.3
	end
	local out = {}
	for _, cf in obj.spawns do
		if not wet(cf.Position.X, cf.Position.Z) then
			table.insert(out, cf)
		end
	end
	local tries = 0
	while #out < minCount and tries < 300 do
		tries += 1
		local a = ctx:Range(0, math.pi * 2)
		local d = ctx:Range(obj.radius + 6, obj.radius + 30)
		local x, z = obj.position.X + math.cos(a) * d, obj.position.Z + math.sin(a) * d
		if not wet(x, z) then
			local at = Vector3.new(x, hm:Get(x, z) + 3, z)
			table.insert(out, CFrame.lookAt(at, Vector3.new(obj.position.X, at.Y, obj.position.Z)))
		end
	end
	obj.spawns = out
end

-- Higgins-boat (LCVP) wreck: flat hull, slab sides, stern, bow ramp up / down / gone.
local function landingCraft(ctx: any, cf: CFrame, ramp: string)
	local model = ctx:Model("LandingCraftWreck", ctx:Folder("Props"))
	local col = ctx:Jitter(rgb(92, 104, 106), 0.08)
	local L, W, H = 34, 10.5, 5.5
	local function p(name: string, size: Vector3, lcf: CFrame)
		ctx:Part({
			Name = name,
			Parent = model,
			Size = size,
			CFrame = cf * lcf,
			Material = M.CorrodedMetal,
			Color = col,
			NoPenetration = true,
		})
	end
	p("Hull", Vector3.new(W, 1, L), CFrame.new(0, 0.5, 0))
	p("Side", Vector3.new(0.8, H, L), CFrame.new(-W / 2 + 0.4, H / 2, 0))
	p("Side", Vector3.new(0.8, H, L), CFrame.new(W / 2 - 0.4, H / 2, 0))
	p("Stern", Vector3.new(W, H + 0.8, 1.2), CFrame.new(0, (H + 0.8) / 2, L / 2 - 0.6))
	p("Coxswain", Vector3.new(3, 2.4, 3.2), CFrame.new(W / 2 - 2.2, H + 1.2, L / 2 - 3))
	if ramp == "down" then
		p(
			"Ramp",
			Vector3.new(W - 1.6, 0.6, 9),
			CFrame.new(0, 0.6, -L / 2) * CFrame.Angles(math.rad(-16), 0, 0) * CFrame.new(0, 0, -4.5)
		)
	elseif ramp == "up" then
		p("Ramp", Vector3.new(W - 1, H, 0.8), CFrame.new(0, H / 2, -L / 2 + 0.4))
	end
	return model
end

-- Beached tank landing ship (LST): a long steel wall of a hull with a stern superstructure.
-- cf = keel centre on the sand, LookVector = bow.
local function beachedShip(ctx: any, cf: CFrame, length: number)
	local model = ctx:Model("BeachedLST", ctx:Folder("Props"))
	local W, H = 30, 22
	local hull = rgb(88, 96, 100)
	local function p(name: string, size: Vector3, lcf: CFrame, opts: { [string]: any }?)
		local o = opts or {}
		ctx:Part({
			Name = name,
			Parent = model,
			Size = size,
			CFrame = cf * lcf,
			Material = o.material or M.Metal,
			Color = o.color or hull,
			Shape = o.shape,
			NoPenetration = true,
			Jitter = 0.03,
		})
	end
	p("Keel", Vector3.new(W, 2, length), CFrame.new(0, 1, 0))
	p("SidePort", Vector3.new(2, H, length), CFrame.new(-W / 2 + 1, H / 2, 0))
	p("SideStarboard", Vector3.new(2, H, length), CFrame.new(W / 2 - 1, H / 2, 0))
	p(
		"Deck",
		Vector3.new(W, 1.2, length),
		CFrame.new(0, H - 0.6, 0),
		{ material = M.DiamondPlate, color = rgb(76, 80, 82) }
	)
	p("Stern", Vector3.new(W, H, 2), CFrame.new(0, H / 2, length / 2 - 1))
	p(
		"BowDoorL",
		Vector3.new(W / 2, H - 4, 1.5),
		CFrame.new(-W / 4, (H - 4) / 2 + 2, -length / 2) * CFrame.Angles(0, math.rad(-12), 0)
	)
	p(
		"BowDoorR",
		Vector3.new(W / 2, H - 4, 1.5),
		CFrame.new(W / 4, (H - 4) / 2 + 2, -length / 2) * CFrame.Angles(0, math.rad(12), 0)
	)
	p(
		"Waterline",
		Vector3.new(W + 0.4, 3, length - 4),
		CFrame.new(0, 3.5, 0),
		{ color = rgb(60, 52, 48), material = M.CorrodedMetal }
	)
	-- stern superstructure, bridge and funnel
	p("Deckhouse", Vector3.new(W - 6, 11, 22), CFrame.new(0, H + 5.5, length / 2 - 14))
	p("Bridge", Vector3.new(W - 12, 5, 10), CFrame.new(0, H + 13.5, length / 2 - 18), { color = rgb(100, 106, 110) })
	p(
		"Funnel",
		Vector3.new(9, 4.5, 4.5),
		CFrame.new(0, H + 15.5, length / 2 - 8) * CFrame.Angles(0, 0, math.pi / 2),
		{ shape = "Cylinder", color = rgb(70, 72, 74) }
	)
	p("Mast", Vector3.new(0.6, 14, 0.6), CFrame.new(0, H + 23, length / 2 - 18), { color = rgb(60, 60, 60) })
	-- bow gun tub and deck cargo (crates for cover on the deck are not reachable — visual only)
	p(
		"GunTub",
		Vector3.new(3, 7, 7),
		CFrame.new(0, H + 1.5, -length / 2 + 10) * CFrame.Angles(0, 0, math.pi / 2),
		{ shape = "Cylinder" }
	)
	p(
		"Gun",
		Vector3.new(7, 0.6, 0.6),
		CFrame.new(0, H + 3.5, -length / 2 + 6) * CFrame.Angles(0, math.pi / 2, math.rad(18)),
		{ color = rgb(50, 50, 50) }
	)
	ctx:AddMinimapCF("building", cf, W, length)
	return model
end

-- Concrete sea wall along `points` with a fixed crest height above the beach; `gaps` = {{x, halfWidth}}.
local function seaWall(ctx: any, points: { Vector3 }, gaps: { { number } })
	local model = ctx:Model("SeaWall", ctx:Folder("Fortifications"))
	local concrete = rgb(150, 146, 136)
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local len = (b - a).Magnitude
		local n = math.max(1, math.floor(len / 8 + 0.5))
		for s = 0, n - 1 do
			local t = (s + 0.5) / n
			local x = Geo.lerp(a.X, b.X, t)
			local z = Geo.lerp(a.Z, b.Z, t)
			local gapped = false
			for _, g in gaps do
				if math.abs(x - g[1]) < g[2] then
					gapped = true
					break
				end
			end
			if gapped then
				continue
			end
			local foot = ctx:GroundY(x, z - 4) - 2
			local top = ctx:GroundY(x, z - 4) + 2 + 6
			local damaged = ctx:Chance(0.1)
			if damaged then
				top -= ctx:Range(2, 4)
			end
			local h = top - foot
			local dir = (b - a).Unit
			local cf = CFrame.lookAt(
				Vector3.new(x, foot + h / 2, z),
				Vector3.new(x, foot + h / 2, z) + Vector3.new(-dir.Z, 0, dir.X)
			)
			ctx:Part({
				Name = "SeaWall",
				Parent = model,
				Size = Vector3.new(len / n + 0.2, h, 3),
				CFrame = cf * (if damaged
					then CFrame.Angles(math.rad(ctx:Range(-4, 4)), 0, math.rad(ctx:Range(-3, 3)))
					else CFrame.identity),
				Material = M.Concrete,
				Color = concrete,
				NoPenetration = true,
				Jitter = 0.04,
			})
		end
	end
	ctx:AddMinimapPath("building", points, 4)
	return model
end

-- "Rommel's asparagus": an angled log ramp on a post, pointing out to sea.
local function stakeRamp(ctx: any, x: number, z: number)
	local y = ctx:GroundY(x, z)
	local model = ctx:Model("StakeRamp", ctx:Folder("Fortifications"))
	local base = CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(ctx:Range(-15, 15)), 0)
	ctx:Part({
		Name = "Log",
		Parent = model,
		Size = Vector3.new(0.9, 0.9, 14),
		CFrame = base * CFrame.new(0, 2.6, 0) * CFrame.Angles(math.rad(-20), 0, 0),
		Material = M.Wood,
		Color = rgb(80, 66, 50),
	})
	ctx:Part({
		Name = "Post",
		Parent = model,
		Size = Vector3.new(0.8, 5.5, 0.8),
		CFrame = base * CFrame.new(0, 2.2, 4.5),
		Material = M.Wood,
		Color = rgb(74, 60, 46),
	})
end

-- Small "Achtung Minen" sign.
local function mineSign(ctx: any, x: number, z: number, yaw: number)
	local cf = ctx:GroundCF(x, z, yaw)
	local model = ctx:Model("MineSign", ctx:Folder("Props"))
	ctx:Part({
		Name = "Post",
		Parent = model,
		Size = Vector3.new(0.3, 3.2, 0.3),
		CFrame = cf * CFrame.new(0, 1.6, 0),
		Material = M.Wood,
		Color = rgb(90, 70, 50),
	})
	ctx:Part({
		Name = "Sign",
		Parent = model,
		Size = Vector3.new(2.2, 1.6, 0.15),
		CFrame = cf * CFrame.new(0, 3, 0) * CFrame.Angles(0, 0, math.rad(45)),
		Material = M.SmoothPlastic,
		Color = rgb(200, 190, 150),
	})
end

-- Coastal-battery casemate: big bunker with a heavy gun barrel through the embrasure.
local function casemate(ctx: any, cf: CFrame)
	local w, d = 22, 18
	Fort.Bunker(ctx, cf, { width = w, depth = d, height = 9.5, slits = 1, sunk = 2 })
	local lo = select(1, ctx:FootprintMinY(cf, w, d))
	local base = CFrame.new(cf.Position.X, lo - 2, cf.Position.Z) * (cf - cf.Position)
	local model = ctx:Model("CasemateGun", ctx:Folder("Fortifications"))
	ctx:Part({
		Name = "Barrel",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(18, 1.6, 1.6),
		CFrame = base * CFrame.new(0, 5.4, -d / 2 - 2) * CFrame.Angles(0, math.pi / 2, 0),
		Material = M.Metal,
		Color = rgb(70, 74, 66),
		NoPenetration = true,
	})
	ctx:Part({
		Name = "Mantlet",
		Parent = model,
		Size = Vector3.new(4, 3.4, 3),
		CFrame = base * CFrame.new(0, 5.4, -d / 2 + 4),
		Material = M.Metal,
		Color = rgb(78, 82, 72),
		NoPenetration = true,
	})
end

-- Builder ---------------------------------------------------------------------------------------------

function AtlanticWall.Build(parent: Folder, _def: any)
	local ctx = MapKit.new(parent, { seed = SEED })
	local rng = ctx.rng
	table.clear(preparedRoads)
	for _, r in ROADS do
		table.insert(preparedRoads, Geo.path(r))
	end

	Terrain.ApplyPalette({
		Sand = rgb(196, 182, 146),
		Mud = rgb(124, 112, 88),
		Grass = rgb(98, 112, 66),
		LeafyGrass = rgb(86, 102, 58),
		Ground = rgb(104, 92, 70),
		Pebble = rgb(130, 126, 118),
		Rock = rgb(112, 108, 98),
	}, { color = rgb(48, 66, 70), transparency = 0.5, waveSize = 0.18, waveSpeed = 10, decoration = true })

	-------------------------------------------------------------------------------------------
	-- 1. Terrain model
	-------------------------------------------------------------------------------------------
	local hm = Terrain.HeightModel({ baseY = 0, seed = SEED })
	hm:Custom(function(x, z, _h)
		return profile(x, z)
	end)
	-- frame the plateau with higher ground beyond the bounds (inland only)
	hm:Custom(function(x, z, h)
		if z < crestZ(x) then
			return h
		end
		return h + Geo.smoothstep(740, 900, math.abs(x)) * 30 + Geo.smoothstep(560, 760, z) * 35
	end)
	hm:Hill(-130, 400, 220, 10) -- battery hill
	hm:Hill(-560, 240, 160, 7)
	hm:Hill(520, 330, 180, 8)
	-- headlands closing the beach at both ends of the map
	hm:Ridge({ V(-900, -300), V(-840, -480), V(-820, -640) }, 160, 26)
	hm:Ridge({ V(900, -300), V(850, -470), V(830, -640) }, 160, 26)
	-- shingle bank (left open in front of the HQ)
	local SHINGLE_W, SHINGLE_E = {}, {}
	for x = -790, -460, 30 do
		table.insert(SHINGLE_W, V(x, wallZ(x) - 22))
	end
	for x = -150, 790, 30 do
		table.insert(SHINGLE_E, V(x, wallZ(x) - 22))
	end
	hm:Ridge(SHINGLE_W, 16, 2.4)
	hm:Ridge(SHINGLE_E, 16, 2.4)
	-- the draw, a western gully and pads for bluff bunkers
	ravine(hm, drawPath, 13, 30, 5.6, PLATEAU_Y - 2)
	ravine(hm, gullyPath, 3, 14, 5.6, PLATEAU_Y - 3)
	local BLUFF_BUNKERS = { -640, -560, -300, 20, 420, 660 }
	for _, x in BLUFF_BUNKERS do
		hm:FlattenRect(x, bluffZ(x) + 12, 24, 20, 0, nil, 10)
	end
	hm:FlattenRect(96, -146, 20, 18, 0, nil, 10) -- draw shoulder pillboxes
	hm:FlattenRect(246, -146, 20, 18, 0, nil, 10)
	-- plateau sites
	hm:FlattenRect(VILLAGE.cx, VILLAGE.cz, VILLAGE.sx - 60, VILLAGE.sz - 60, 0, nil, 50)
	hm:Flatten(-130, 380, 110, nil, 45)
	-- Allied HQ on the sand with tall dunes on both flanks
	Layout.PrepareHQ(hm, HQ_ALLIES, { y = 2.6 })
	hm:Ridge({ V(-428, -500), V(-430, -400), V(-408, -348), V(-384, -326) }, 36, 17)
	hm:Ridge({ V(-172, -500), V(-172, -400), V(-188, -346) }, 36, 17)
	Layout.PrepareHQ(hm, HQ_AXIS)
	-- earth banks on the Axis HQ flanks (screens it from the battery hill once E falls)
	hm:Ridge({ V(66, 640), V(62, 500), V(110, 440) }, 40, 13)
	hm:Ridge({ V(334, 640), V(338, 500), V(290, 440) }, 40, 13)
	for name, r in ROADS do
		if name ~= "draw" then
			hm:Road(r, if name == "coast" then 12 else 11, 8)
		end
	end
	hm:Road(DRAW, 12, 6)
	hm:Road(SWITCHBACK, 6, 4)
	hm:Sea(SEA_LEVEL)

	local mm = Terrain.MaterialModel({ base = M.Grass, subsurface = M.Ground, seed = SEED })
	mm:Patches(M.LeafyGrass, 90, 0.1)
	mm:Patches(M.Ground, 40, 0.6)
	mm:Slope(M.Ground, 0.38)
	mm:Custom(M.Rock, function(x, z, _y, slope)
		return slope > 0.5 and Geo.fbm(x, z, 25, 2, 4) > -0.2
	end)
	mm:Custom(M.Sand, function(x, z, _y, _s)
		return z < wallZ(x) + 2
	end)
	mm:Custom(M.Mud, function(x, z, y, _s)
		return y < 0.9 and z < wallZ(x) - 40 and Geo.fbm(x, z, 30, 2, 5) > -0.3
	end)
	mm:Path(SHINGLE_W, 12, M.Pebble, 2)
	mm:Path(SHINGLE_E, 12, M.Pebble, 2)
	mm:Custom(M.Sand, function(x, z, _y, _s)
		return (math.abs(x + 428) < 26 or math.abs(x + 172) < 26) and z < -340 and z > -520
	end)
	mm:Rect(HQ_ALLIES.Position.X, HQ_ALLIES.Position.Z, 140, 100, 0, M.Sand, 4)
	mm:Rect(HQ_AXIS.Position.X, HQ_AXIS.Position.Z, 140, 100, 0, M.Ground, 6)
	mm:Path(ROADS.coast, 10, M.Cobblestone, 1)
	for name, r in ROADS do
		if name ~= "coast" then
			mm:Path(r, 9, M.Ground, 1.5)
		end
	end
	mm:Path(SWITCHBACK, 5, M.Ground, 1)
	mm:Path(GULLY, 6, M.Ground, 2)
	mm:Rect(VILLAGE.cx, VILLAGE.cz - 5, 60, 44, 0, M.Cobblestone, 2)
	mm:Circle(-130, 380, 120, M.Ground, 10)

	Terrain.Generate(ctx, hm, mm, { center = V(0, -60), size = Vector2.new(2000, 1640) })

	for name, r in ROADS do
		if name ~= "coast" then
			ctx:AddMinimapPath("road", r, 10)
		end
	end
	ctx:AddMinimapPath("road", ROADS.coast, 10)
	ctx:AddMinimap("water", 0, -560, 2000, 170, 0)

	local props = ctx:Folder("Props")
	local fortFolder = ctx:Folder("Fortifications")

	-------------------------------------------------------------------------------------------
	-- 2. The beach: wrecks, obstacles, shingle, sea wall
	-------------------------------------------------------------------------------------------
	-- Beached LST shielding the Allied HQ (hull lies along X, 68 studs in front of the spawns)
	beachedShip(
		ctx,
		CFrame.new(-298, ctx:GroundY(-298, -345) - 1.5, -345) * CFrame.Angles(0, math.rad(-90), math.rad(3)),
		170
	)

	-- Landing craft wrecks in the shallows and on the sand
	local craftSpots = {
		{ -540, -18, "down" },
		{ -470, 6, "gone" },
		{ -150, -4, "down" },
		{ -60, 30, "up" },
		{ 40, -26, "gone" },
		{ 130, 14, "down" },
		{ 250, -10, "up" },
		{ 330, 40, "down" },
		{ 470, -20, "gone" },
		{ 600, 10, "down" },
		{ 700, -30, "up" },
		{ -690, 22, "down" },
	}
	for _, c in craftSpots do
		local x = c[1] + rng:NextNumber(-12, 12)
		local z = waterZ(x) + c[2]
		local y = math.max(ctx:GroundY(x, z), SEA_LEVEL - 2.5) - rng:NextNumber(0.6, 1.6)
		local yaw = rng:NextNumber(-35, 35) + (if rng:NextNumber() < 0.15 then 180 else 0)
		local cf = CFrame.new(x, y, z)
			* CFrame.Angles(0, math.rad(180 + yaw), 0)
			* CFrame.Angles(math.rad(rng:NextNumber(-4, 4)), 0, math.rad(rng:NextNumber(-12, 12)))
		landingCraft(ctx, cf, c[3])
	end

	-- Obstacle belts: hedgehogs (two staggered rows), stake ramps nearer the water
	local hedgehogs = 0
	for row = 0, 2 do
		local zOff = 40 + row * 32
		local x = -790 + row * 12
		while x < 790 do
			local z = waterZ(x) + zOff + rng:NextNumber(-6, 6)
			local nearHQ = math.abs(x + 300) < 150
			local lane = math.abs(x - 175) < 14 or math.abs(x + 40) < 10 or math.abs(x - 430) < 10
			if not nearHQ and not lane and rng:NextNumber() < 0.8 then
				Fort.Hedgehog(ctx, V(x, z), rng:NextNumber(4.2, 5.2), fortFolder)
				hedgehogs += 1
			end
			x += rng:NextNumber(24, 34)
		end
	end
	for _ = 1, 26 do
		local x = rng:NextNumber(-780, 780)
		if math.abs(x + 300) > 160 then
			stakeRamp(ctx, x, waterZ(x) + rng:NextNumber(4, 22))
		end
	end
	-- Beach craters (sand), some holding sea water
	for _ = 1, 22 do
		local x = rng:NextNumber(-760, 760)
		local z = rng:NextNumber(waterZ(x) + 25, wallZ(x) - 30)
		if math.abs(x + 300) > 150 then
			Terrain.Crater(ctx, V(x, z), rng:NextNumber(4, 7), {
				material = M.Sand,
				outerMaterial = M.Sand,
				rimMaterial = M.Sand,
				water = rng:NextNumber() < 0.3,
			})
		end
	end
	-- Burnt-out vehicles on the beach
	Props.Wreck(ctx, ctx:GroundCF(-20, -350, 30), { kind = "tank" })
	Props.Wreck(ctx, ctx:GroundCF(88, -410, -70), { kind = "halftrack", burning = true })
	Props.Wreck(ctx, ctx:GroundCF(-120, -330, 110), { kind = "truck" })
	Props.Wreck(ctx, ctx:GroundCF(380, -335, 10), { kind = "tank", noTurret = true })
	Props.Wreck(ctx, ctx:GroundCF(-620, -360, 60), { kind = "truck", burning = true })
	-- Supply dump at A (beach-head)
	Props.CrateStack(ctx, ctx:GroundCF(-62, -398, 10))
	Props.CrateStack(ctx, ctx:GroundCF(-14, -402, -20))
	Props.BarrelGroup(ctx, ctx:GroundCF(-90, -372, 0))
	Fort.Sandbags(ctx, ctx:GroundCF(-40, -352, 0), { length = 12, arc = 40 })
	Fort.Sandbags(ctx, ctx:GroundCF(10, -364, 0), { length = 10, arc = 30 })

	-- Sea wall with the draw gap and shell breaches
	local WALL = {}
	for x = -790, 790, 40 do
		table.insert(WALL, V(x, wallZ(x)))
	end
	seaWall(ctx, WALL, { { 178, 20 }, { -470, 8 }, { -130, 7 }, { 360, 7 }, { 560, 9 }, { -300, 8 } })
	-- Barbed wire on the beach side of the shingle and along the promenade (left open at the lanes)
	for _, seg in { { -640, -500 }, { -100, 100 }, { 230, 390 } } do
		local pts = {}
		for wx = seg[1], seg[2], 40 do
			table.insert(pts, V(wx, wallZ(wx) - 36))
		end
		Fort.BarbedWire(ctx, pts, { spacing = 12 })
	end
	for _, seg in PROMENADE_WIRE do
		local pts = {}
		for wx = seg[1], seg[2], 40 do
			table.insert(pts, V(wx, wallZ(wx) + 22))
		end
		Fort.BarbedWire(ctx, pts, { spacing = 12 })
	end

	-- Promenade: ruined beach villas, lamp posts, beach huts
	local villas = 0
	local x = -770
	while x < 770 do
		local strip = (bluffZ(x) - 45) - (wallZ(x) + 8)
		local busy = math.abs(x - 178) < 60
			or math.abs(x + 300) < 120
			or math.abs(x + 470) < 30
			or math.abs(x - 560) < 50
		for _, seg in PROMENADE_WIRE do
			busy = busy or (x > seg[1] - 20 and x < seg[2] + 20)
		end
		if strip > 30 and not busy and villas < 6 then
			local z = wallZ(x) + 8 + strip / 2 + 2
			Buildings.House(ctx, ctx:GroundCF(x, z, 0), {
				style = if rng:NextNumber() < 0.5 then "NormanStone" else "Brick",
				enterable = villas % 2 == 0,
				ruin = rng:NextNumber(0.45, 0.9),
				floors = 2,
				width = rng:NextNumber(16, 20),
				depth = math.min(14, strip - 8),
				roof = if rng:NextNumber() < 0.4 then "flat" else "gable",
			})
			villas += 1
			x += rng:NextNumber(55, 80)
		else
			x += 20
		end
	end
	for _, lx in { -700, -560, -420, -40, 80, 260, 470, 640 } do
		Props.LampPost(ctx, ctx:GroundCF(lx, wallZ(lx) + 6, 0), { parent = props })
	end
	-- Anti-tank wall across the draw mouth (blown gap in the middle)
	for _, sx in { -1, 1 } do
		local wx = 180 + sx * 13
		local wz = -262
		ctx:Part({
			Name = "ATWall",
			Parent = fortFolder,
			Size = Vector3.new(12, 7, 3.5),
			CFrame = CFrame.new(wx, ctx:GroundY(wx, wz) + 2.5, wz),
			Material = M.Concrete,
			Color = rgb(146, 142, 132),
			NoPenetration = true,
		})
	end
	Props.RubblePile(ctx, V(180, -258), { radius = 4, height = 1.6, materials = { M.Concrete, M.Rock } })
	Fort.TankTraps(ctx, { V(150, -236), V(166, -236) }, { kind = "teeth", spacing = 7 })

	-------------------------------------------------------------------------------------------
	-- 3. The bluffs: pillboxes, MG nests, crest trench, draw defences (B)
	-------------------------------------------------------------------------------------------
	for i, bx in BLUFF_BUNKERS do
		local bz = bluffZ(bx) + 12
		Fort.Bunker(ctx, ctx:GroundCF(bx, bz, rng:NextNumber(-8, 8)), {
			width = if i % 2 == 0 then 16 else 14,
			depth = 12,
			slits = if i % 2 == 0 then 3 else 2,
		})
	end
	-- MG nests on the crest, facing the beach
	for _, mx in { -700, -600, -420, -240, -60, 60, 300, 480, 600, 720 } do
		Fort.MGNest(ctx, ctx:GroundCF(mx, crestZ(mx) - 4, rng:NextNumber(-15, 15)), {})
	end
	-- crest fire trench in segments (cut at the draw and the gully)
	local function crestTrench(x0: number, x1: number)
		local pts = {}
		for tx = x0, x1, 30 do
			table.insert(pts, V(tx, crestZ(tx) + 14))
		end
		Fort.Trench(
			ctx,
			Layout.Zigzag(pts, 3.2, 13),
			{ parapet = "right", sandbags = 0.2, fireSteps = 26, revetment = 0.5 }
		)
	end
	crestTrench(-440, -270)
	crestTrench(10, 80)
	crestTrench(250, 500)
	-- B: the draw. Pillboxes on both shoulders plus an AT gun covering the road
	Fort.Bunker(ctx, ctx:GroundCF(96, -146, -30), { width = 14, depth = 12, slits = 2 })
	Fort.Bunker(ctx, ctx:GroundCF(246, -146, 30), { width = 14, depth = 12, slits = 2 })
	Fort.ATGun(ctx, ctx:GroundCF(124, -102, 10), {})
	Fort.MGNest(ctx, ctx:GroundCF(194, -128, -10), {})
	Fort.Sandbags(ctx, ctx:GroundCF(154, -200, 0), { length = 8, arc = 60 })
	Fort.Sandbags(ctx, ctx:GroundCF(178, -168, 180), { length = 7, arc = 40 })
	Fort.Barricade(ctx, ctx:GroundCF(165, -214, 0), { kind = "wood", length = 7 })
	Props.Wreck(ctx, ctx:GroundCF(192, -226, 160), { kind = "halftrack" })
	Props.CrateStack(ctx, ctx:GroundCF(150, -184, 0))
	Props.Fire(ctx, V(194, -230), { size = 4 })
	for _, s in { { 126, -228 }, { 212, -230 }, { 132, -160 }, { 212, -168 } } do
		Nature.Bush(ctx, V(s[1], s[2]))
	end
	-- mine signs along the bluff face
	for _, sx in { -650, -380, -210, 40, 300, 470, 700 } do
		mineSign(ctx, sx, bluffZ(sx) - 30, 180)
	end
	-- scrub on the bluff face (concealment for the climb)
	for _ = 1, 60 do
		local bx = rng:NextNumber(-780, 780)
		local bz = bluffZ(bx) + rng:NextNumber(-30, 25)
		if math.abs(bx - 172) > 40 and math.abs(bx + 300) > 140 then
			Nature.Bush(ctx, V(bx, bz), rng:NextNumber(4, 7))
		end
	end

	-------------------------------------------------------------------------------------------
	-- 4. C: Widerstandsnest on the bluff top (trench network, bunkers, tobruks)
	-------------------------------------------------------------------------------------------
	Fort.Trench(ctx, Layout.Zigzag({ V(-250, -120), V(-170, -128), V(-90, -122), V(-10, -110) }, 3.5, 12), {
		parapet = "right",
		sandbags = 0.3,
	})
	Fort.Trench(ctx, { V(-130, -126), V(-128, -80), V(-112, -54) }, { parapet = "both", sandbags = 0.1 })
	Fort.Trench(ctx, Layout.Zigzag({ V(-205, -82), V(-150, -74) }, 2.5, 10), { parapet = "right" })
	Fort.Bunker(ctx, ctx:GroundCF(-176, -96, 0), { width = 16, depth = 12, slits = 3 })
	Fort.Bunker(ctx, ctx:GroundCF(-70, -82, 10), { width = 12, depth = 10, slits = 2 })
	Fort.MGNest(ctx, ctx:GroundCF(-210, -132, -10), {})
	Fort.MGNest(ctx, ctx:GroundCF(-40, -118, 10), {})
	Fort.ATGun(ctx, ctx:GroundCF(-110, -138, 0), {})
	Fort.Watchtower(ctx, ctx:GroundCF(-150, -60, 0), { height = 12 })
	Buildings.Hut(ctx, ctx:GroundCF(-90, -55, 90), { style = "Timber", width = 12, depth = 8, ruin = 0.3 })
	Props.AmmoCache(ctx, ctx:GroundCF(-120, -86, 0))
	Props.CrateStack(ctx, ctx:GroundCF(-136, -74, 30))
	Props.BarrelGroup(ctx, ctx:GroundCF(-100, -70, 0))
	Fort.BarbedWire(ctx, { V(-280, -150), V(-200, -158), V(-120, -156), V(-30, -145), V(30, -135) }, { spacing = 12 })
	for _, f in { { -240, -80 }, { -20, -70 }, { -170, -30 } } do
		Fort.Foxhole(ctx, ctx:GroundCF(f[1], f[2], 0))
	end

	-------------------------------------------------------------------------------------------
	-- 5. D: Colleville — ruined village on the plateau
	-------------------------------------------------------------------------------------------
	local styles = { "Norman", "NormanStone", "NormanStone", "Brick" }
	local function vhouse(
		hx: number,
		hz: number,
		yaw: number,
		enterable: boolean,
		ruin: number,
		extra: { [string]: any }?
	)
		local o: { [string]: any } = {
			style = styles[rng:NextInteger(1, #styles)],
			enterable = enterable,
			ruin = ruin,
			floors = if rng:NextNumber() < 0.6 then 2 else 3,
			width = rng:NextNumber(17, 21),
			depth = rng:NextNumber(13, 15),
		}
		if extra then
			for k, v in extra do
				o[k] = v
			end
		end
		return Buildings.House(ctx, ctx:GroundCF(hx, hz, yaw), o)
	end
	Buildings.Church(ctx, ctx:GroundCF(30, 222, 0), { width = 22, length = 48, towerH = 40, ruin = 0.55 })
	-- north road (runs N-S through the square at x~100)
	vhouse(80, 95, -90, true, 0.5)
	vhouse(80, 70, -90, false, 0.8)
	vhouse(124, 100, 90, true, 0.3)
	vhouse(124, 74, 90, false, 0.6)
	-- lateral road west of the square
	vhouse(66, 176, 180, true, 0.4)
	vhouse(-10, 172, 180, false, 0.7)
	vhouse(-36, 174, 180, true, 0.85)
	vhouse(36, 134, 0, true, 0.2)
	vhouse(8, 136, 0, false, 0.6)
	-- lateral road east
	vhouse(166, 128, 0, true, 0.6)
	vhouse(194, 130, 0, false, 0.4)
	vhouse(222, 134, 0, true, 0.75)
	vhouse(168, 172, 180, false, 0.3)
	vhouse(198, 174, 180, true, 0.5)
	Buildings.Farmhouse(ctx, ctx:GroundCF(-60, 236, 180), { ruin = 0.5, enterable = true })
	Buildings.Barn(ctx, ctx:GroundCF(240, 230, 90), { ruin = 0.6 })
	for _, r in { { 140, 192, 6 }, { -30, 140, 5 }, { 60, 122, 5 }, { 228, 196, 6 } } do
		Props.RubblePile(ctx, V(r[1], r[2]), { radius = r[3], height = 3 })
	end
	Fort.Barricade(ctx, ctx:GroundCF(100, 108, 0), { kind = "debris", length = 9 })
	Fort.Barricade(ctx, ctx:GroundCF(150, 152, 90), { kind = "wood", length = 8 })
	Fort.Sandbags(ctx, ctx:GroundCF(84, 140, 180), { length = 9, arc = 50 })
	Fort.MGNest(ctx, ctx:GroundCF(118, 168, 0), {})
	Props.Wreck(ctx, ctx:GroundCF(110, 140, 70), { kind = "truck", burning = true })
	Props.Wreck(ctx, ctx:GroundCF(-70, 186, 95), { kind = "halftrack" })
	Props.Cart(ctx, ctx:GroundCF(62, 160, 20), { broken = true })
	Props.Well(ctx, ctx:GroundCF(84, 196, 0))
	Props.Fountain(ctx, ctx:GroundCF(130, 184, 0), { ruined = true })
	Props.StoneWall(ctx, { V(5, 200), V(5, 256), V(55, 256), V(55, 200) }, { height = 3, gapChance = 0.15 })
	Props.TelegraphLine(ctx, Layout.Offset(ROADS.lateral, 10), { leanChance = 0.4, downChance = 0.15 })
	Props.Signpost(ctx, ctx:GroundCF(124, 30, 0))

	-------------------------------------------------------------------------------------------
	-- 6. E: Batterie de Longues — four casemates on the battery hill
	-------------------------------------------------------------------------------------------
	for i, c in { { -300, 355, 10 }, { -195, 340, 4 }, { -70, 342, -4 }, { 35, 360, -12 } } do
		casemate(ctx, ctx:GroundCF(c[1], c[2], c[3]))
		Fort.Sandbags(
			ctx,
			ctx:GroundCF(c[1] + (if i % 2 == 0 then 16 else -16), c[2] - 12, c[3]),
			{ length = 8, arc = 40 }
		)
	end
	-- fire-control post forward, ammo bunkers behind
	Fort.Bunker(ctx, ctx:GroundCF(-130, 300, 0), { width = 14, depth = 10, slits = 3, height = 8 })
	Fort.Bunker(ctx, ctx:GroundCF(-240, 436, 180), { width = 12, depth = 10, slits = 1 })
	Fort.Bunker(ctx, ctx:GroundCF(-20, 436, 180), { width = 12, depth = 10, slits = 1 })
	Fort.Trench(ctx, Layout.Zigzag({ V(-330, 320), V(-200, 312), V(-130, 318), V(-40, 312), V(60, 326) }, 3.5, 13), {
		parapet = "right",
		sandbags = 0.25,
	})
	Fort.Trench(ctx, { V(-130, 318), V(-126, 345), V(-124, 368) }, { parapet = "both" })
	Fort.ATGun(ctx, ctx:GroundCF(-250, 412, 0), {})
	Fort.ATGun(ctx, ctx:GroundCF(-10, 412, 0), {})
	Fort.MGNest(ctx, ctx:GroundCF(-360, 340, 20), {})
	Fort.MGNest(ctx, ctx:GroundCF(90, 345, -20), {})
	Fort.Watchtower(ctx, ctx:GroundCF(-130, 448, 0), { height = 16 })
	for _, h in { { -330, 450, 90 }, { -300, 470, 90 }, { 40, 460, -90 } } do
		Buildings.Hut(
			ctx,
			ctx:GroundCF(h[1], h[2], h[3]),
			{ style = "Timber", width = 14, depth = 9, ruin = rng:NextNumber(0, 0.4) }
		)
	end
	Props.AmmoCache(ctx, ctx:GroundCF(-152, 372, 0))
	Props.CrateStack(ctx, ctx:GroundCF(-108, 374, 20))
	Props.BarrelGroup(ctx, ctx:GroundCF(-180, 410, 0))
	Props.Tent(ctx, ctx:GroundCF(-60, 450, 0))
	Fort.BarbedWire(ctx, { V(-380, 290), V(-250, 278), V(-130, 270), V(0, 276), V(64, 290) }, { spacing = 12 })
	Fort.TankTraps(ctx, { V(-360, 270), V(-200, 258) }, { kind = "teeth", spacing = 9 })
	Fort.TankTraps(ctx, { V(-60, 258), V(80, 278) }, { kind = "teeth", spacing = 9 })
	Props.Fire(ctx, V(-196, 372), { size = 5 })

	-------------------------------------------------------------------------------------------
	-- 7. Plateau: hedgerows, orchards, woods, craters
	-------------------------------------------------------------------------------------------
	local function skipHedge(hx: number, hz: number): boolean
		return nearRoad(hx, hz, 11) or excluded(hx, hz) or inVillage(hx, hz, 20)
	end
	local HEDGES = {
		{ V(-760, 40), V(-560, 50), V(-400, 30) },
		{ V(-560, 50), V(-570, 250), V(-540, 420) },
		{ V(-400, 30), V(-380, 230) },
		{ V(-760, 300), V(-570, 300) },
		{ V(-300, 60), V(-260, 230), V(-420, 260) },
		{ V(300, -20), V(320, 120), V(300, 260), V(320, 420) },
		{ V(320, 120), V(560, 110), V(760, 120) },
		{ V(450, -60), V(470, 110) },
		{ V(300, 260), V(560, 270) },
		{ V(-40, 260), V(-20, 330) },
		{ V(400, 420), V(600, 440), V(760, 430) },
	}
	for _, h in HEDGES do
		Nature.Hedgerow(ctx, h, { skip = skipHedge, treeChance = 0.12, gapChance = 0.06 })
	end
	Nature.Orchard(ctx, ctx:GroundCF(-280, 120, 4), { rows = 3, cols = 6, spacing = 15 })
	Nature.Orchard(ctx, ctx:GroundCF(420, 30, -3), { rows = 3, cols = 5, spacing = 15 })
	Nature.Forest(ctx, { center = V(-640, 430), size = Vector2.new(230, 200) }, {
		kinds = { "Oak", "Oak", "Pine", "Birch" },
		spacing = 20,
		filter = function(fx, fz)
			return not nearRoad(fx, fz, 12)
		end,
	})
	Nature.Forest(ctx, { center = V(620, 300), size = Vector2.new(240, 170), rot = 6 }, {
		kinds = { "Oak", "Pine", "Poplar" },
		spacing = 20,
		filter = function(fx, fz)
			return not nearRoad(fx, fz, 12)
		end,
	})
	Nature.WheatField(ctx, ctx:GroundCF(-430, 120, 3), 110, 70, {})
	Nature.WheatField(ctx, ctx:GroundCF(440, 200, -2), 100, 60, { harvested = true })
	for _ = 1, 40 do
		local bx, bz = rng:NextNumber(-760, 760), rng:NextNumber(-60, 540)
		if bz > crestZ(bx) + 20 and not excluded(bx, bz) and not nearRoad(bx, bz, 10) and not inVillage(bx, bz, 20) then
			Nature.Bush(ctx, V(bx, bz))
		end
	end
	for _ = 1, 10 do
		local tx, tz = rng:NextNumber(-700, 700), rng:NextNumber(-40, 300)
		if tz > crestZ(tx) + 20 and not excluded(tx, tz) and not nearRoad(tx, tz, 12) and not inVillage(tx, tz, 20) then
			Nature.Tree(ctx, V(tx, tz), if rng:NextNumber() < 0.5 then "Burnt" else "Dead", 1)
		end
	end
	local craters = 0
	for _ = 1, 160 do
		if craters >= 42 then
			break
		end
		local cx, cz = rng:NextNumber(-740, 740), rng:NextNumber(-140, 460)
		if
			cz > crestZ(cx) + 6
			and not excluded(cx, cz, -40)
			and not nearRoad(cx, cz, 12)
			and not inVillage(cx, cz, -30)
		then
			craters += 1
			Terrain.Crater(ctx, V(cx, cz), rng:NextNumber(4, 9), {})
		end
	end
	Props.Wreck(ctx, ctx:GroundCF(-330, -40, 40), { kind = "tank", noTurret = true })
	Props.Wreck(ctx, ctx:GroundCF(260, 40, -20), { kind = "truck" })
	Props.Wreck(ctx, ctx:GroundCF(-20, 300, 80), { kind = "halftrack", burning = true })

	-------------------------------------------------------------------------------------------
	-- 8. HQs, objectives, MapInfo
	-------------------------------------------------------------------------------------------
	local alliesHQ = Layout.SpawnArea(ctx, HQ_ALLIES, "Allies", { spawnCount = 10, vehicleCount = 3 })
	local axisHQ = Layout.SpawnArea(ctx, HQ_AXIS, "Axis", { spawnCount = 10, vehicleCount = 4 })
	-- hedgerows screening the Axis HQ from the battery hill and the flanks
	Nature.Hedgerow(ctx, { V(60, 455), V(160, 448) }, {})
	Nature.Hedgerow(ctx, { V(240, 448), V(340, 455) }, {})

	local objectives = {}
	for i, o in OBJECTIVES do
		local obj = Layout.CapturePoint(ctx, {
			id = o.id,
			name = o.name,
			position = o.pos,
			flagPosition = o.flag,
			radius = o.radius,
			order = i,
			initialOwner = o.owner,
		})
		drySpawns(ctx, hm, obj, 4)
		table.insert(objectives, obj)
	end

	local function vehicles(list: { CFrame }, classes: { string })
		local out = {}
		for i, cf in list do
			table.insert(out, { cframe = cf, class = classes[i] or "Jeep" })
		end
		return out
	end

	return MapKit.Finish(ctx, {
		id = "AtlanticWall",
		bounds = { center = Vector3.new(0, 40, 0), size = Vector3.new(SIZE_X, 600, SIZE_Z) },
		hq = { Allies = alliesHQ.spawns, Axis = axisHQ.spawns },
		objectives = objectives,
		vehicleSpawns = {
			Allies = vehicles(alliesHQ.vehicles, { "Tank", "Transport", "Jeep" }),
			Axis = vehicles(axisHQ.vehicles, { "Tank", "Light", "Transport", "AT" }),
		},
		outOfBounds = 10,
	})
end

return AtlanticWall
