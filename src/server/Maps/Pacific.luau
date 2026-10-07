--[[
	Pacific — "Coral Atoll" (≈1600 x 1600 studs). Map team (B).

	A low coral island ringed by reef flats. The Allies have a foothold on the southern beach and
	push north through a coconut plantation, across the Japanese airfield and the lagoon pier to the
	radio station on the island's only hill.

	   z=+800 ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈
	          ≈   palms  [AXIS HQ] (-180,560)   jungle ridge               ≈
	          ≈  jungle         E Radio Hill (100,440) mast, bunkers        ≈
	          ≈ (dense       trench rings             ╔══ lagoon ══╗ atoll ≈
	          ≈  clusters)            D Lagoon Pier (230,210) ═pier═   rim  ≈≈ channel
	          ≈      ════════ hangar ═ C Airfield (20,40) ════            ╝ ≈
	          ≈ ══════════════ airstrip (coral) ═════════                    ≈
	          ≈      jungle     B Coconut Grove (-140,-260) log bunkers      ≈
	          ≈   palms         trench line          A Red Beach (80,-520)   ≈
	          ≈      [ALLIED HQ] (-150,-600)   log seawall, pillboxes        ≈
	          ≈≈≈≈≈≈≈≈≈≈≈ reef flats (knee-deep), wrecked amtracs ≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈≈
	   z=-800 └──────────────────────────────────────────────────────────────────┘
	           x=-800                                                      x=+800

	Objectives (order 1 = Allied end): A Red Beach, B Coconut Grove (plantation with coconut-log
	bunkers and a trench line), C Airfield (hangar, wrecked planes, revetments), D Lagoon Pier
	(warehouses on stilts, fuel dump), E Radio Hill (radio mast, pillboxes, trench rings).
	Routes: the central coral road, the beach road, the west jungle track along the airstrip and
	the east lagoon road. Jungle is clusters of cheap 3-part trees and 1-part undergrowth.
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

local Pacific = {}

local SIZE = 1600
local SEED = 1943

-- Island shape ----------------------------------------------------------------------------------------

local ISLAND_CX, ISLAND_CZ = 0, 30
local LAGOON = { x = 400, z = 190, r = 150 }

local function coastR(theta: number): number
	return 650 + 55 * math.sin(3 * theta + 0.6) + 35 * math.sin(5 * theta + 2.1) + 20 * math.sin(9 * theta)
end

-- signed distance inland from the coastline (negative = offshore)
local function inland(x: number, z: number): number
	local dx, dz = x - ISLAND_CX, z - ISLAND_CZ
	return coastR(math.atan2(dz, dx)) - math.sqrt(dx * dx + dz * dz)
end

local function coastPoint(theta: number, offset: number): Vector3
	local r = coastR(theta) - offset
	return V(ISLAND_CX + math.cos(theta) * r, ISLAND_CZ + math.sin(theta) * r)
end

local function profile(x: number, z: number): number
	local t = inland(x, z)
	if t < -130 then
		return math.max(-16, -2 + (t + 130) * 0.12)
	elseif t < 0 then
		return -1.8 + Geo.fbm(x, z, 40, 2, 3) * 0.6 -- reef flats: knee-deep water
	elseif t < 50 then
		return Geo.lerp(0.4, 3, t / 50)
	end
	return 3 + Geo.smoothstep(50, 160, t) * 3 + Geo.fbm(x, z, 180, 3, 5) * 3 * Geo.smoothstep(50, 200, t)
end

-- Layout data -----------------------------------------------------------------------------------------

local HQ_ALLIES = CFrame.new(-150, 0, -600) * CFrame.Angles(0, math.pi, 0) -- faces north (+Z)
local HQ_AXIS = CFrame.new(-180, 0, 560) -- faces south (-Z)

local AIRSTRIP = { a = V(-480, -60), b = V(220, 10), width = 44 }

local ROADS = {
	main = { V(-150, -560), V(-120, -450), V(-140, -260), V(-60, -100), V(20, 10), V(70, 40), V(90, 130), V(90, 300), V(100, 440), V(-40, 500), V(-180, 520) },
	beach = { V(-520, -520), V(-300, -555), V(-150, -560), V(80, -520), V(320, -470), V(480, -400) },
	lagoon = { V(90, 130), V(150, 140), V(230, 210), V(260, 360), V(100, 440) },
	west = { V(-140, -260), V(-380, -140), V(-500, -60), V(-470, 160), V(-330, 400), V(-180, 520) },
}

local OBJECTIVES = {
	{ id = "A", name = "Red Beach", pos = V(80, -520), radius = 34, owner = "Allies" },
	{ id = "B", name = "Coconut Grove", pos = V(-140, -260), radius = 32, owner = "Neutral" },
	{ id = "C", name = "Airfield", pos = V(20, 40), radius = 34, owner = "Neutral", flag = V(30, 46) },
	{ id = "D", name = "Lagoon Pier", pos = V(230, 210), radius = 30, owner = "Neutral", flag = V(222, 204) },
	{ id = "E", name = "Radio Hill", pos = V(100, 440), radius = 32, owner = "Axis", flag = V(92, 446) },
}

-- areas kept clear of jungle: { x, z, r }
local CLEARINGS = {
	{ -150, -600, 130 },
	{ -180, 560, 130 },
	{ 80, -520, 70 },
	{ -140, -260, 50 },
	{ 20, 60, 80 },
	{ 200, 205, 70 },
	{ 110, 460, 170 }, -- Radio Hill: cleared fields of fire
}

local PACIFIC_STYLE: any = nil

-- Helpers ---------------------------------------------------------------------------------------------

local preparedRoads: { any } = {}
local stripPath = Geo.path({ AIRSTRIP.a, AIRSTRIP.b })

local function nearRoad(x: number, z: number, margin: number): boolean
	for _, p in preparedRoads do
		if (Geo.distToPath(p, x, z)) < margin then
			return true
		end
	end
	return false
end

local function onStrip(x: number, z: number, pad: number): boolean
	return (Geo.distToPath(stripPath, x, z)) < AIRSTRIP.width / 2 + pad
end

local function inLagoon(x: number, z: number, pad: number): boolean
	return (x - LAGOON.x) ^ 2 + (z - LAGOON.z) ^ 2 < (LAGOON.r + pad) ^ 2
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

-- Footprints of placed structures (the jungle pass keeps trees out of them)
local RESERVED: { { number } } = {}
local function reserve(x: number, z: number, r: number)
	table.insert(RESERVED, { x, z, r })
end
local function reserved(x: number, z: number): boolean
	for _, c in RESERVED do
		if (x - c[1]) ^ 2 + (z - c[2]) ^ 2 < c[3] * c[3] then
			return true
		end
	end
	return false
end

-- Split a polyline where it crosses a road (trenches must not cut the tracks).
local function cutAtRoads(points: { Vector3 }, margin: number): { { Vector3 } }
	local out, cur = {}, {}
	for _, p in points do
		if nearRoad(p.X, p.Z, margin) then
			if #cur >= 2 then
				table.insert(out, cur)
			end
			cur = {}
		else
			table.insert(cur, p)
		end
	end
	if #cur >= 2 then
		table.insert(out, cur)
	end
	return out
end

-- Remove objective spawns in the sea/lagoon; top up from dry ground around the point.
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

local FROND = { rgb(78, 120, 46), rgb(90, 130, 52), rgb(70, 108, 44), rgb(96, 124, 56) }
local JUNGLE = { rgb(46, 92, 40), rgb(56, 104, 44), rgb(40, 84, 38), rgb(62, 110, 48), rgb(50, 98, 50) }

-- Cheap palm: one leaning trunk + five fronds (6 parts).
local function palm(ctx: any, x: number, z: number, s: number, parent: Instance)
	local y = ctx:GroundY(x, z)
	local h = 22 * s
	local model = ctx:Model("Palm", parent)
	local lean = ctx:Range(0.12, 0.32)
	local base = CFrame.new(x, y - 0.5, z) * CFrame.Angles(0, ctx:Range(0, 6.28), 0) * CFrame.Angles(lean, 0, 0)
	ctx:Part({
		Name = "Trunk",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(h, 1.2 * s, 1.2 * s),
		CFrame = base * CFrame.new(0, h / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = M.Wood,
		Color = rgb(124, 104, 78),
		Jitter = 0.06,
		CastShadow = true,
	})
	local top = base * CFrame.new(0, h, 0) * CFrame.Angles(-lean, 0, 0)
	local col = ctx:Pick(FROND)
	for i = 0, 4 do
		local a = i * math.pi * 2 / 5 + ctx:Range(-0.25, 0.25)
		ctx:Part({
			Name = "Frond",
			Parent = model,
			Size = Vector3.new(2.8 * s, 0.25, 11 * s),
			CFrame = top * CFrame.Angles(0, a, 0) * CFrame.Angles(math.rad(ctx:Range(18, 34)), 0, 0) * CFrame.new(0, 0, -5 * s),
			Material = M.Grass,
			Color = ctx:Jitter(col, 0.08),
			CanCollide = false,
			CanQuery = false,
			CastShadow = true,
		})
	end
	return model
end

-- Shell-snapped palm: a bare, splintered trunk (1-2 parts).
local function stumpPalm(ctx: any, x: number, z: number, parent: Instance)
	local y = ctx:GroundY(x, z)
	local h = ctx:Range(5, 13)
	local model = ctx:Model("BrokenPalm", parent)
	local cf = CFrame.new(x, y - 0.5, z) * CFrame.Angles(ctx:Range(-0.15, 0.15), ctx:Range(0, 6.28), ctx:Range(-0.15, 0.15))
	ctx:Part({
		Name = "Trunk",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(h, 1.2, 1.2),
		CFrame = cf * CFrame.new(0, h / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = M.Wood,
		Color = rgb(96, 82, 64),
	})
	if ctx:Chance(0.5) then
		local len = ctx:Range(8, 14)
		local a = ctx:Range(0, math.pi * 2)
		local fx, fz = x + math.cos(a) * (len / 2 + 1), z + math.sin(a) * (len / 2 + 1)
		ctx:Part({
			Name = "Fallen",
			Parent = model,
			Shape = "Cylinder",
			Size = Vector3.new(len, 1.1, 1.1),
			CFrame = CFrame.new(fx, ctx:GroundY(fx, fz) + 0.5, fz) * CFrame.Angles(0, -a, 0),
			Material = M.Wood,
			Color = rgb(110, 92, 70),
		})
	end
	return model
end

-- Broad-leaf jungle tree: trunk + two flattened crowns (3 parts).
local function jungleTree(ctx: any, x: number, z: number, s: number, parent: Instance)
	local y = ctx:GroundY(x, z)
	local h = ctx:Range(14, 22) * s
	local model = ctx:Model("JungleTree", parent)
	ctx:Part({
		Name = "Trunk",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(h, 1.5 * s, 1.5 * s),
		CFrame = CFrame.new(x, y + h / 2 - 1, z) * CFrame.Angles(0, ctx:Range(0, 6.28), math.pi / 2),
		Material = M.Wood,
		Color = rgb(98, 84, 66),
		Jitter = 0.08,
		CastShadow = true,
	})
	local col = ctx:Pick(JUNGLE)
	local w = ctx:Range(16, 22) * s
	ctx:Part({
		Name = "Leaves",
		Parent = model,
		Mesh = "Sphere",
		Size = Vector3.new(w, w * 0.45, w * 0.9),
		CFrame = CFrame.new(x, y + h, z) * CFrame.Angles(0, ctx:Range(0, 6.28), 0),
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
		Size = Vector3.new(w * 0.65, w * 0.4, w * 0.65),
		CFrame = CFrame.new(x + ctx:Range(-3, 3), y + h * 0.72, z + ctx:Range(-3, 3)),
		Material = M.LeafyGrass,
		Color = ctx:Jitter(col, 0.1),
		CanCollide = false,
		CanQuery = false,
		CastShadow = true,
	})
	return model
end

-- Dense undergrowth: one non-colliding leafy ellipsoid (ferns, vines, banana plants).
local function shrub(ctx: any, x: number, z: number, s: number, parent: Instance)
	local y = ctx:GroundY(x, z)
	ctx:Part({
		Name = "Undergrowth",
		Parent = parent,
		Mesh = "Sphere",
		Size = Vector3.new(9 * s, 5.5 * s, 8 * s),
		CFrame = CFrame.new(x, y + 1.6 * s, z) * CFrame.Angles(0, ctx:Range(0, 6.28), 0),
		Material = M.LeafyGrass,
		Color = ctx:Jitter(ctx:Pick(JUNGLE), 0.1),
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
end

-- Coconut-log wall (two courses) along points, facing the sea.
local function logWall(ctx: any, points: { Vector3 })
	local model = ctx:Model("LogWall", ctx:Folder("Fortifications"))
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local len = (b - a).Magnitude
		local n = math.max(1, math.floor(len / 9 + 0.5))
		for k = 0, n - 1 do
			if ctx:Chance(0.12) then
				continue -- shell gap
			end
			local t = (k + 0.5) / n
			local x, z = Geo.lerp(a.X, b.X, t), Geo.lerp(a.Z, b.Z, t)
			local y = ctx:GroundY(x, z)
			local yaw = math.atan2(b.X - a.X, b.Z - a.Z)
			for course = 0, 1 do
				ctx:Part({
					Name = "Log",
					Parent = model,
					Shape = "Cylinder",
					Size = Vector3.new(len / n + 0.6, 1.9, 1.9),
					CFrame = CFrame.new(x, y + 0.7 + course * 1.7, z) * CFrame.Angles(0, yaw + math.pi / 2, 0),
					Material = M.Wood,
					Color = rgb(112, 92, 70),
					Destructible = true,
					Health = 400,
				})
			end
		end
	end
	return model
end

-- Amphibious tractor (LVT) wreck: boxy hull, track sponsons, open troop bay.
local function amtrac(ctx: any, cf: CFrame)
	local model = ctx:Model("AmtracWreck", ctx:Folder("Props"))
	local col = ctx:Jitter(rgb(84, 92, 70), 0.06)
	local function p(name: string, size: Vector3, lcf: CFrame, color: Color3?)
		ctx:Part({ Name = name, Parent = model, Size = size, CFrame = cf * lcf, Material = M.CorrodedMetal, Color = color or col, NoPenetration = true })
	end
	p("Hull", Vector3.new(9, 3, 22), CFrame.new(0, 2.5, 0))
	p("TrackL", Vector3.new(2, 3.6, 24), CFrame.new(-5.4, 1.8, 0), rgb(50, 48, 44))
	p("TrackR", Vector3.new(2, 3.6, 24), CFrame.new(5.4, 1.8, 0), rgb(50, 48, 44))
	p("BayL", Vector3.new(0.6, 3, 14), CFrame.new(-4.2, 5.5, 3))
	p("BayR", Vector3.new(0.6, 3, 14), CFrame.new(4.2, 5.5, 3))
	p("Cab", Vector3.new(8.6, 3, 5), CFrame.new(0, 5.5, -7))
	return model
end

-- Japanese hangar: steel-framed, corrugated walls, gabled roof with shell holes. Front faces cf.LookVector.
local function hangar(ctx: any, cf: CFrame, w: number, d: number, h: number)
	local model = ctx:Model("Hangar", ctx:Folder("Buildings"))
	local steel = rgb(110, 112, 100)
	local function p(name: string, size: Vector3, lcf: CFrame, opts: { [string]: any }?)
		local o = opts or {}
		ctx:Part({
			Name = name,
			Parent = model,
			Size = size,
			CFrame = cf * lcf,
			Material = o.material or M.CorrodedMetal,
			Color = o.color or steel,
			Destructible = o.destructible,
			NoPenetration = o.noPen,
			Shape = o.shape,
		})
	end
	p("Floor", Vector3.new(w, 1, d), CFrame.new(0, -0.3, 0), { material = M.Concrete, color = rgb(150, 146, 136) })
	p("BackWall", Vector3.new(w, h, 1), CFrame.new(0, h / 2, d / 2 - 0.5), { destructible = true })
	for _, sx in { -1, 1 } do
		-- side walls in two panels with a personnel gap
		p("SideWall", Vector3.new(1, h, d * 0.45), CFrame.new(sx * (w / 2 - 0.5), h / 2, d * 0.25), { destructible = true })
		p("SideWall", Vector3.new(1, h, d * 0.35), CFrame.new(sx * (w / 2 - 0.5), h / 2, -d * 0.32), { destructible = true })
		-- roof slopes
		local rise = w * 0.18
		local slope = math.atan2(rise, w / 2)
		local len = math.sqrt(rise * rise + (w / 2) ^ 2)
		for k = 0, 2 do
			if not (sx == 1 and k == 1) then -- shell hole
				p(
					"Roof",
					Vector3.new(len + 1, 0.5, d / 3),
					CFrame.new(sx * w / 4, h + rise / 2, -d / 3 + k * d / 3) * CFrame.Angles(0, 0, -sx * slope),
					{ destructible = true, color = rgb(96, 98, 88) }
				)
			end
		end
		-- door leaves pushed open at the front
		p("Door", Vector3.new(w * 0.22, h - 1, 0.8), CFrame.new(sx * (w / 2 - w * 0.11), (h - 1) / 2, -d / 2 + 0.4), { color = rgb(90, 96, 84) })
	end
	for k = 0, 2 do
		p("Truss", Vector3.new(w, 0.8, 0.8), CFrame.new(0, h, -d / 3 + k * d / 3), { color = rgb(80, 80, 76) })
	end
	ctx:AddMinimapCF("building", cf, w, d)
	return model
end

-- Wrecked fighter: fuselage, wings (one snapped), tail, engine and prop (7 parts).
local function planeWreck(ctx: any, cf: CFrame, broken: boolean)
	local model = ctx:Model("PlaneWreck", ctx:Folder("Props"))
	local col = ctx:Pick({ rgb(84, 96, 72), rgb(150, 150, 140), rgb(70, 78, 60) })
	local function p(name: string, size: Vector3, lcf: CFrame, opts: { [string]: any }?)
		local o = opts or {}
		ctx:Part({ Name = name, Parent = model, Size = size, CFrame = cf * lcf, Material = o.material or M.Metal, Color = o.color or col, Shape = o.shape, NoPenetration = true })
	end
	p("Fuselage", Vector3.new(20, 3.2, 3.2), CFrame.new(0, 2, 0) * CFrame.Angles(0, math.pi / 2, math.rad(4)), { shape = "Cylinder" })
	p("Engine", Vector3.new(2.6, 3.6, 3.6), CFrame.new(0, 2.4, -10.5) * CFrame.Angles(0, math.pi / 2, 0), { shape = "Cylinder", color = rgb(40, 40, 40) })
	p("Prop", Vector3.new(0.4, 7, 0.6), CFrame.new(0, 2.4, -12) * CFrame.Angles(0, 0, math.rad(ctx:Range(0, 90))), { color = rgb(50, 46, 40) })
	p("WingL", Vector3.new(14, 0.5, 5), CFrame.new(-7.5, 1.4, -3) * CFrame.Angles(0, 0, math.rad(4)))
	if broken then
		p("WingR", Vector3.new(9, 0.5, 5), CFrame.new(9, 0.4, -1) * CFrame.Angles(math.rad(10), math.rad(25), math.rad(-14)))
	else
		p("WingR", Vector3.new(14, 0.5, 5), CFrame.new(7.5, 1.4, -3) * CFrame.Angles(0, 0, math.rad(-4)))
	end
	p("TailFin", Vector3.new(0.4, 4, 3.2), CFrame.new(0, 4.6, 9.6))
	p("Stabilizer", Vector3.new(7, 0.4, 2.6), CFrame.new(0, 3, 9.6))
	return model
end

-- Wooden pier from a (shore) to b (water end) with a T-head; deck sits at deckY.
local function pier(ctx: any, a: Vector3, b: Vector3, deckY: number, width: number)
	local model = ctx:Model("Pier", ctx:Folder("Props"))
	local dir = (b - a) * Vector3.new(1, 0, 1)
	local len = dir.Magnitude
	local u = dir.Unit
	local look = CFrame.lookAt(Vector3.new(a.X, deckY, a.Z), Vector3.new(b.X, deckY, b.Z))
	local n = math.ceil(len / 12)
	for i = 0, n - 1 do
		local seg = math.min(12, len - i * 12)
		ctx:Part({
			Name = "Deck",
			Parent = model,
			Size = Vector3.new(width, 0.8, seg),
			CFrame = look * CFrame.new(0, 0, -(i * 12 + seg / 2)),
			Material = M.WoodPlanks,
			Color = ctx:Jitter(rgb(120, 98, 72), 0.06),
			Destructible = i > 1,
			Health = 300,
		})
		for _, sx in { -1, 1 } do
			local pp = look * Vector3.new(sx * (width / 2 - 0.4), 0, -(i * 12 + 6))
			local ground = ctx:GroundY(pp.X, pp.Z)
			local hgt = deckY - ground + 1
			if hgt < 1.5 then
				continue
			end
			ctx:Part({
				Name = "Pile",
				Parent = model,
				Size = Vector3.new(1, hgt, 1),
				CFrame = CFrame.new(pp.X, ground + hgt / 2 - 1, pp.Z),
				Material = M.Wood,
				Color = rgb(80, 66, 50),
			})
		end
	end
	ctx:Part({
		Name = "TDeck",
		Parent = model,
		Size = Vector3.new(width * 3, 0.8, 10),
		CFrame = look * CFrame.new(0, 0, -(len + 5)),
		Material = M.WoodPlanks,
		Color = rgb(116, 94, 70),
	})
	for _, sx in { -1, 1 } do
		local pp = look * Vector3.new(sx * width * 1.3, 0, -(len + 5))
		local ground = math.min(ctx:GroundY(pp.X, pp.Z), deckY - 1)
		ctx:Part({
			Name = "Pile",
			Parent = model,
			Size = Vector3.new(1.2, deckY - ground + 1, 1.2),
			CFrame = CFrame.new(pp.X, (deckY + ground) / 2 - 0.5, pp.Z),
			Material = M.Wood,
			Color = rgb(80, 66, 50),
		})
	end
	ctx:AddMinimapCF("building", look * CFrame.new(0, 0, -len / 2), width, len)
	return model, look, u
end

-- Steel lattice radio mast with guy wires and a hut. pos = ground point.
local function radioMast(ctx: any, pos: Vector3, height: number)
	local model = ctx:Model("RadioMast", ctx:Folder("Buildings"))
	local y = ctx:GroundY(pos.X, pos.Z)
	ctx:Part({
		Name = "Mast",
		Parent = model,
		Shape = "Truss",
		Size = Vector3.new(2, height, 2),
		CFrame = CFrame.new(pos.X, y + height / 2, pos.Z),
		Color = rgb(120, 60, 50),
	})
	ctx:Part({ Name = "Footing", Parent = model, Size = Vector3.new(5, 1.4, 5), CFrame = CFrame.new(pos.X, y + 0.3, pos.Z), Material = M.Concrete, Color = rgb(150, 146, 136) })
	for i = 0, 2 do
		local a = i * math.pi * 2 / 3 + 0.4
		local gx, gz = pos.X + math.cos(a) * height * 0.45, pos.Z + math.sin(a) * height * 0.45
		local g = Vector3.new(gx, ctx:GroundY(gx, gz), gz)
		local top = Vector3.new(pos.X, y + height * 0.85, pos.Z)
		local len = (top - g).Magnitude
		ctx:Part({
			Name = "Guy",
			Parent = model,
			Size = Vector3.new(0.12, 0.12, len),
			CFrame = CFrame.lookAt((top + g) / 2, top),
			Material = M.Metal,
			Color = rgb(60, 60, 60),
			CanCollide = false,
			CastShadow = false,
		})
	end
	ctx:Part({
		Name = "Antenna",
		Parent = model,
		Size = Vector3.new(12, 0.3, 0.3),
		CFrame = CFrame.new(pos.X, y + height - 1, pos.Z),
		Material = M.Metal,
		Color = rgb(60, 60, 60),
		CanCollide = false,
	})
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

function Pacific.Build(parent: Folder, _def: any)
	local ctx = MapKit.new(parent, { seed = SEED })
	local rng = ctx.rng
	table.clear(preparedRoads)
	table.clear(RESERVED)
	local function at(x: number, z: number, yaw: number?): CFrame
		reserve(x, z, 10)
		return ctx:GroundCF(x, z, yaw)
	end
	for _, r in ROADS do
		table.insert(preparedRoads, Geo.path(r))
	end
	if not PACIFIC_STYLE then
		local s = table.clone(Buildings.Styles.Log)
		s.wall = M.WoodPlanks
		s.wallColors = { rgb(168, 140, 100), rgb(156, 128, 92), rgb(176, 150, 108) }
		s.roofColors = { rgb(170, 150, 96), rgb(160, 138, 88) }
		PACIFIC_STYLE = s
	end

	Terrain.ApplyPalette({
		Sand = rgb(228, 216, 174),
		Grass = rgb(96, 134, 62),
		LeafyGrass = rgb(74, 118, 52),
		Ground = rgb(128, 104, 74),
		Mud = rgb(96, 80, 60),
		Limestone = rgb(222, 218, 202),
		Rock = rgb(170, 162, 142),
	}, { color = rgb(38, 132, 146), transparency = 0.75, reflectance = 0.3, waveSize = 0.12, waveSpeed = 8, decoration = true })

	-------------------------------------------------------------------------------------------
	-- 1. Terrain model
	-------------------------------------------------------------------------------------------
	local hm = Terrain.HeightModel({ baseY = 0, seed = SEED })
	hm:Custom(function(x, z, _h)
		return profile(x, z)
	end)
	hm:Hill(110, 470, 190, 34, 1.3) -- Radio Hill
	hm:Hill(-420, 250, 160, 9)
	hm:Hill(-380, -330, 120, 6)
	hm:Ridge({ V(-60, 700), V(-40, 560), V(-70, 470) }, 80, 20) -- jungle ridge east of the Axis HQ
	hm:Ridge({ V(-330, 640), V(-320, 520), V(-280, 470) }, 60, 10)
	-- lagoon: enclosed by a thin atoll rim, opened to the sea by a channel
	hm:Custom(function(x, z, h)
		local d = math.sqrt((x - LAGOON.x) ^ 2 + (z - LAGOON.z) ^ 2) + Geo.fbm(x, z, 60, 2, 11) * 18
		if d > LAGOON.r + 50 then
			return h
		end
		return Geo.lerp(-7, h, Geo.smoothstep(LAGOON.r - 20, LAGOON.r + 50, d))
	end, { LAGOON.x - 260, LAGOON.x + 260, LAGOON.z - 260, LAGOON.z + 260 })
	hm:Channel({ V(520, 240), V(640, 280), V(800, 300) }, 26, 9, 20, "U")
	-- airstrip: level coral runway with a slight embankment
	gradedRoad(hm, { AIRSTRIP.a, AIRSTRIP.b }, AIRSTRIP.width + 8, 30, 0.03)
	hm:Flatten(20, 70, 70, nil, 30)
	hm:Flatten(200, 205, 50, nil, 20)
	hm:Flatten(100, 440, 50, nil, 25)
	hm:Flatten(-140, -260, 50, nil, 25)
	Layout.PrepareHQ(hm, HQ_ALLIES, { y = 3 })
	Layout.PrepareHQ(hm, HQ_AXIS, { y = 5 })
	hm:Ridge({ V(-330, 520), V(-300, 466), V(-200, 452), V(-90, 466), V(-60, 520) }, 50, 13) -- jungle rise ringing the Axis HQ
	-- dunes and log-topped berms screening the Allied beachhead from the island interior
	hm:Ridge({ V(-280, -660), V(-275, -580), V(-250, -520) }, 40, 12)
	hm:Ridge({ V(-20, -660), V(-25, -580), V(-50, -520) }, 40, 12)
	hm:Ridge({ V(-240, -500), V(-150, -486), V(-60, -500) }, 40, 9)
	for _, r in ROADS do
		gradedRoad(hm, r, 11, 8, 0.15)
	end
	hm:Sea(0)

	local mm = Terrain.MaterialModel({ base = M.Grass, subsurface = M.Ground, seed = SEED })
	mm:Patches(M.LeafyGrass, 70, -0.1)
	mm:Patches(M.Ground, 30, 0.6)
	mm:Custom(M.Sand, function(x, z, y, _s)
		return y < 2.4 or inland(x, z) < 40
	end)
	mm:Custom(M.Sand, function(x, z, _y, _s)
		return inLagoon(x, z, 40)
	end)
	mm:Custom(M.Rock, function(_x, _z, y, slope)
		return slope > 0.7 and y > 3
	end)
	for _, r in ROADS do
		mm:Path(r, 8, M.Limestone, 1.5)
	end
	mm:Path({ AIRSTRIP.a, AIRSTRIP.b }, AIRSTRIP.width, M.Limestone, 2)
	mm:Rect(20, 70, 90, 40, 0, M.Concrete, 2) -- hangar apron
	mm:Rect(HQ_ALLIES.Position.X, HQ_ALLIES.Position.Z, 140, 100, 0, M.Sand, 4)
	mm:Rect(HQ_AXIS.Position.X, HQ_AXIS.Position.Z, 140, 100, 0, M.Ground, 6)
	mm:Circle(100, 450, 45, M.Ground, 6)

	Terrain.Generate(ctx, hm, mm, { center = Vector3.zero, size = Vector2.new(2000, 2000) })

	for _, r in ROADS do
		ctx:AddMinimapPath("road", r, 9)
	end
	ctx:AddMinimapPath("road", { AIRSTRIP.a, AIRSTRIP.b }, AIRSTRIP.width)
	ctx:AddMinimap("water", LAGOON.x, LAGOON.z, LAGOON.r * 2, LAGOON.r * 2, 0)
	ctx:AddMinimapPath("water", { V(520, 240), V(640, 280), V(800, 300) }, 30)
	-- the ocean as four bands around the island
	ctx:AddMinimap("water", 0, -760, 1600, 120, 0)
	ctx:AddMinimap("water", 0, 760, 1600, 120, 0)
	ctx:AddMinimap("water", -760, 0, 120, 1600, 0)
	ctx:AddMinimap("water", 760, 0, 120, 1600, 0)

	local props = ctx:Folder("Props")
	local nature = ctx:Folder("Nature")
	local fortFolder = ctx:Folder("Fortifications")

	-------------------------------------------------------------------------------------------
	-- 2. A: Red Beach — reef wrecks, log seawall, beach pillboxes
	-------------------------------------------------------------------------------------------
	for _, a in { { -1.25, -60 }, { -1.18, -30 }, { -1.36, -80 }, { -1.05, -40 }, { -0.95, -10 }, { -1.45, -20 }, { -0.85, -70 } } do
		local p = coastPoint(a[1], a[2])
		local y = math.max(ctx:GroundY(p.X, p.Z), -1.5)
		amtrac(ctx, CFrame.new(p.X, y - 0.8, p.Z) * CFrame.Angles(0, math.rad(rng:NextNumber(-30, 30)), math.rad(rng:NextNumber(-10, 10))))
	end
	local SEAWALL = {}
	for th = -1.55, -0.75, 0.05 do
		table.insert(SEAWALL, coastPoint(th, 58))
	end
	logWall(ctx, SEAWALL)
	ctx:AddMinimapPath("building", SEAWALL, 3)
	for i, th in { -1.4, -1.2, -1.02, -0.86 } do
		local p = coastPoint(th, 82)
		local face = math.deg(math.atan2(-(p.X - ISLAND_CX), -(p.Z - ISLAND_CZ)))
		if i % 2 == 1 then
			Fort.Bunker(ctx, at(p.X, p.Z, face + 180), { width = 14, depth = 11, slits = 2 })
		else
			Fort.LogBunker(ctx, at(p.X, p.Z, face + 180), { width = 13 })
		end
	end
	for _, th in { -1.3, -1.12, -0.95 } do
		local p = coastPoint(th, 70)
		Fort.MGNest(ctx, at(p.X, p.Z, math.deg(math.atan2(-(p.X - ISLAND_CX), -(p.Z - ISLAND_CZ))) + 180), {})
	end
	local wireTh = {}
	for th = -1.3, -0.8, 0.06 do
		table.insert(wireTh, coastPoint(th, 30))
	end
	Fort.BarbedWire(ctx, wireTh, { spacing = 12 })
	for th = -1.5, -0.8, 0.045 do
		if rng:NextNumber() < 0.6 then
			local p = coastPoint(th, rng:NextNumber(-10, 12))
			Fort.DragonTooth(ctx, p, rng:NextNumber(2.6, 3.4), fortFolder)
		end
	end
	Props.Wreck(ctx, at(40, -548, 30), { kind = "tank", burning = true })
	Props.CrateStack(ctx, at(96, -540, 0))
	Props.BarrelGroup(ctx, at(60, -500, 0))
	Fort.Sandbags(ctx, at(80, -495, 180), { length = 10, arc = 50 })
	for _ = 1, 16 do
		local x, z = rng:NextNumber(-60, 300), rng:NextNumber(-600, -440)
		if inland(x, z) > 20 and not nearRoad(x, z, 10) and not inClearing(x, z, -40) then
			Terrain.Crater(ctx, V(x, z), rng:NextNumber(4, 7), { material = M.Sand, outerMaterial = M.Sand, rimMaterial = M.Sand })
		end
	end

	-------------------------------------------------------------------------------------------
	-- 3. B: Coconut Grove — plantation rows, coconut-log bunkers, Japanese trench line
	-------------------------------------------------------------------------------------------
	for _, seg in cutAtRoads({ V(-320, -186), V(-260, -190), V(-200, -196), V(-150, -190), V(-100, -186), V(-40, -196), V(20, -190), V(70, -182) }, 12) do
		Fort.Trench(ctx, Layout.Zigzag(seg, 3.5, 12), { parapet = "left", sandbags = 0.15 })
	end
	Fort.LogBunker(ctx, at(-215, -262, 180), { width = 13 })
	Fort.LogBunker(ctx, at(-60, -250, 180), { width = 12 })
	Fort.Bunker(ctx, at(-180, -320, 180), { width = 12, depth = 10, slits = 2 })
	Fort.MGNest(ctx, at(-40, -224, 180), {})
	Fort.MGNest(ctx, at(-240, -236, 170), {})
	Fort.Sandbags(ctx, at(-160, -280, 180), { length = 9, arc = 60 })
	Props.CrateStack(ctx, at(-118, -276, 0))
	Props.Cart(ctx, at(-162, -296, 60), { broken = true })
	Buildings.Hut(ctx, at(-210, -300, 90), { style = PACIFIC_STYLE, stilts = true, width = 12, depth = 9 })
	Props.Wreck(ctx, at(-90, -370, 20), { kind = "tank" })

	local grove = ctx:Model("CoconutGrove", nature)
	for i = 0, 8 do
		for j = 0, 6 do
			local gx = -250 + i * 26 + rng:NextNumber(-3, 3)
			local gz = -330 + j * 24 + rng:NextNumber(-3, 3)
			if rng:NextNumber() < 0.82 and not nearRoad(gx, gz, 9) and not reserved(gx, gz) and (gx + 140) ^ 2 + (gz + 260) ^ 2 > 22 ^ 2 then
				if rng:NextNumber() < 0.12 then
					stumpPalm(ctx, gx, gz, grove)
				else
					palm(ctx, gx, gz, rng:NextNumber(0.9, 1.15), grove)
				end
			end
		end
	end
	ctx:AddMinimap("forest", -146, -258, 230, 170, 0)
	-------------------------------------------------------------------------------------------
	-- 4. C: Airfield — hangar, revetments, wrecked planes, AA guns, control tower
	-------------------------------------------------------------------------------------------
	reserve(20, 92, 34)
	hangar(ctx, at(20, 92, 0), 48, 36, 14)
	Buildings.Hut(ctx, at(-50, 80, 0), { style = PACIFIC_STYLE, width = 14, depth = 10, name = "OpsHut" })
	Fort.Watchtower(ctx, at(-70, 50, 0), { height = 14 })
	planeWreck(ctx, at(18, 92, 170), false) -- in the hangar
	planeWreck(ctx, at(-140, -28, 70), true)
	planeWreck(ctx, at(120, 30, -20), true)
	planeWreck(ctx, at(-300, 16, 160), false)
	planeWreck(ctx, at(-260, -90, 20), true)
	-- U-shaped earth revetments along the strip
	for _, rv in { { -300, 30 }, { -200, 40 }, { 120, 52 }, { -230, -110 }, { -100, -100 } } do
		local x, z = rv[1], rv[2]
		local facing = if z > -30 then 1 else -1
		Terrain.Berm(ctx, { V(x - 16, z), V(x - 16, z + facing * 18), V(x + 16, z + facing * 18), V(x + 16, z) }, 7, 4.5)
	end
	Fort.ATGun(ctx, at(-20, 20, 200), {})
	Fort.ATGun(ctx, at(150, 36, 160), {})
	Fort.Sandbags(ctx, at(0, 40, 180), { length = 10, arc = 80 })
	Fort.Sandbags(ctx, at(-10, 52, 180), { length = 8, arc = 50 })
	Props.BarrelGroup(ctx, at(54, 66, 0))
	Props.BarrelGroup(ctx, at(-20, 74, 0))
	Props.CrateStack(ctx, at(56, 116, 0))
	Props.Wreck(ctx, at(-30, 6, 80), { kind = "truck", burning = true })
	for _ = 1, 14 do
		local t = rng:NextNumber(0.05, 0.95)
		local x = Geo.lerp(AIRSTRIP.a.X, AIRSTRIP.b.X, t) + rng:NextNumber(-14, 14)
		local z = Geo.lerp(AIRSTRIP.a.Z, AIRSTRIP.b.Z, t) + rng:NextNumber(-14, 14)
		Terrain.Crater(ctx, V(x, z), rng:NextNumber(4, 7), { material = M.Ground, outerMaterial = M.Limestone })
	end

	-------------------------------------------------------------------------------------------
	-- 5. D: Lagoon Pier — pier, stilt warehouses, fuel dump, barge wreck
	-------------------------------------------------------------------------------------------
	local deckY = math.max(ctx:GroundY(244, 196), 2.6) + 0.8
	pier(ctx, V(244, 196), V(330, 196), deckY, 9)
	Buildings.Hut(ctx, at(200, 240, 180), { style = PACIFIC_STYLE, stilts = true, width = 16, depth = 10, name = "Warehouse" })
	Buildings.Hut(ctx, at(196, 168, 0), { style = PACIFIC_STYLE, stilts = true, width = 14, depth = 10, name = "Warehouse" })
	Buildings.Barn(ctx, at(160, 210, 90), { style = "Timber", width = 16, depth = 26, height = 11, ruin = 0.35, name = "Storehouse" })
	Buildings.Hut(ctx, at(206, 290, 200), { style = PACIFIC_STYLE, width = 12, depth = 9, ruin = 0.4 })
	for _ = 1, 4 do
		Props.BarrelGroup(ctx, at(rng:NextNumber(172, 190), rng:NextNumber(246, 262), 0))
	end
	Props.CrateStack(ctx, at(226, 186, 0))
	Props.CrateStack(ctx, CFrame.new(290, deckY + 0.4, 192), { parent = props, snap = false })
	Props.Crate(ctx, CFrame.new(306, deckY + 0.4, 199), { snap = false })
	Fort.Sandbags(ctx, at(250, 214, 90), { length = 8, arc = 40 })
	Fort.MGNest(ctx, at(214, 150, 0), {})
	Fort.LogBunker(ctx, at(215, 320, 0), { width = 12 })
	Props.Fire(ctx, V(214, 230), { size = 5 })
	-- sunken barge off the pier and boats pulled up on the lagoon beach
	do
		local cf = CFrame.new(300, -1.5, 230) * CFrame.Angles(0, math.rad(30), math.rad(-8))
		local barge = ctx:Model("BargeWreck", props)
		for _, b in { { Vector3.new(10, 1, 28), CFrame.new(0, 0.5, 0) }, { Vector3.new(0.8, 4.5, 28), CFrame.new(-4.6, 2.5, 0) }, { Vector3.new(0.8, 4.5, 28), CFrame.new(4.6, 2.5, 0) }, { Vector3.new(10, 5, 1), CFrame.new(0, 2.8, 13.5) } } do
			ctx:Part({ Name = "Hull", Parent = barge, Size = b[1], CFrame = cf * b[2], Material = M.CorrodedMetal, Color = rgb(96, 88, 76), NoPenetration = true })
		end
	end
	for _, b in { { 250, 150, 70 }, { 262, 290, 120 } } do
		ctx:Part({
			Name = "Boat",
			Parent = props,
			Size = Vector3.new(4, 1.6, 14),
			CFrame = at(b[1], b[2], b[3]) * CFrame.new(0, 0.6, 0) * CFrame.Angles(0, 0, math.rad(12)),
			Material = M.WoodPlanks,
			Color = rgb(110, 90, 66),
		})
	end

	-------------------------------------------------------------------------------------------
	-- 6. E: Radio Hill — radio station, mast, pillboxes, trench rings
	-------------------------------------------------------------------------------------------
	radioMast(ctx, V(126, 470), 56)
	Buildings.Hut(ctx, at(84, 470, 180), { style = "Brick", width = 16, depth = 11, height = 9, name = "RadioStation" })
	Buildings.Hut(ctx, at(140, 432, 90), { style = PACIFIC_STYLE, width = 12, depth = 9, ruin = 0.3 })
	Fort.Bunker(ctx, at(40, 400, -20), { width = 14, depth = 12, slits = 3 })
	Fort.Bunker(ctx, at(170, 395, 20), { width = 14, depth = 12, slits = 3 })
	Fort.LogBunker(ctx, at(220, 450, 60), { width = 12 })
	Fort.LogBunker(ctx, at(10, 508, -60), { width = 12 })
	local ring1, ring2 = {}, {}
	for a = 200, 340, 12 do
		local r = math.rad(a)
		table.insert(ring1, V(110 + math.cos(r) * 108, 470 + math.sin(r) * 100))
	end
	for a = 196, 344, 12 do
		local r = math.rad(a)
		table.insert(ring2, V(110 + math.cos(r) * 160, 470 + math.sin(r) * 150))
	end
	for _, seg in cutAtRoads(ring1, 12) do
		Fort.Trench(ctx, seg, { parapet = "right", sandbags = 0.25, revetment = 0.6 })
	end
	for _, seg in cutAtRoads(ring2, 12) do
		Fort.Trench(ctx, Layout.Zigzag(seg, 3, 12), { parapet = "right", sandbags = 0.1, revetment = 0.4 })
	end
	Fort.MGNest(ctx, at(70, 410, -10), {})
	Fort.MGNest(ctx, at(168, 452, 15), {})
	Fort.ATGun(ctx, at(124, 404, 0), {})
	Props.AmmoCache(ctx, at(110, 456, 0))
	Props.CrateStack(ctx, at(60, 450, 0))
	Props.BarrelGroup(ctx, at(150, 470, 0))
	Fort.BarbedWire(ctx, { V(-30, 330), V(60, 300), V(160, 300), V(260, 340) }, { spacing = 12 })

	-------------------------------------------------------------------------------------------
	-- 7. Jungle, palm beaches, undergrowth
	-------------------------------------------------------------------------------------------
	local jungleModels = {}
	local function jungleModel(x: number, z: number): Instance
		local key = math.floor((x + 1000) / 250) * 10 + math.floor((z + 1000) / 250)
		local m = jungleModels[key]
		if not m then
			m = ctx:Model("Jungle", nature)
			jungleModels[key] = m
		end
		return m
	end
	local SP = 26
	for gx = -780, 780, SP do
		for gz = -780, 780, SP do
			local x = gx + rng:NextNumber(-0.45, 0.45) * SP
			local z = gz + rng:NextNumber(-0.45, 0.45) * SP
			local t = inland(x, z)
			if t < 8 or inLagoon(x, z, 12) or onStrip(x, z, 16) or nearRoad(x, z, 9) or inClearing(x, z) or reserved(x, z) then
				continue
			end
			local pm = jungleModel(x, z)
			if t < 110 then
				-- palm-fringed beach band
				if rng:NextNumber() < 0.55 then
					palm(ctx, x, z, rng:NextNumber(0.85, 1.2), pm)
				end
				continue
			end
			local dens = Geo.fbm(x, z, 120, 2, 21)
			if dens < -0.25 then
				continue
			end
			if dens < 0.1 and rng:NextNumber() < 0.45 then
				continue
			end
			local roll = rng:NextNumber()
			if roll < 0.55 then
				jungleTree(ctx, x, z, rng:NextNumber(0.85, 1.25), pm)
			elseif roll < 0.72 then
				palm(ctx, x, z, rng:NextNumber(0.9, 1.25), pm)
			end
			-- undergrowth clusters
			local n = if dens > 0.35 then 3 else 1
			for _ = 1, n do
				local sx, sz = x + rng:NextNumber(-11, 11), z + rng:NextNumber(-11, 11)
				if not nearRoad(sx, sz, 8) and not onStrip(sx, sz, 10) then
					shrub(ctx, sx, sz, rng:NextNumber(0.7, 1.3), pm)
				end
			end
		end
	end
	-- palms around the lagoon shore and atoll rim
	for a = 0, 355, 9 do
		local r = math.rad(a)
		local d = LAGOON.r + rng:NextNumber(30, 55)
		local x, z = LAGOON.x + math.cos(r) * d, LAGOON.z + math.sin(r) * d
		if inland(x, z) > 6 and not nearRoad(x, z, 9) and not inClearing(x, z) and rng:NextNumber() < 0.7 then
			palm(ctx, x, z, rng:NextNumber(0.9, 1.2), jungleModel(x, z))
		end
	end
	ctx:AddMinimap("forest", -470, -60, 300, 700, 0)
	ctx:AddMinimap("forest", 320, -230, 380, 380, 0)
	ctx:AddMinimap("forest", -380, 380, 300, 260, 0)
	ctx:AddMinimap("forest", 340, 470, 320, 240, 0)
	ctx:AddMinimap("forest", -200, 210, 260, 180, 0)

	-------------------------------------------------------------------------------------------
	-- 8. HQs, objectives, MapInfo
	-------------------------------------------------------------------------------------------
	local alliesHQ = Layout.SpawnArea(ctx, HQ_ALLIES, "Allies", { spawnCount = 10, vehicleCount = 3 })
	local axisHQ = Layout.SpawnArea(ctx, HQ_AXIS, "Axis", { spawnCount = 10, vehicleCount = 3 })
	logWall(ctx, { V(-230, -520), V(-160, -514) })
	logWall(ctx, { V(-116, -514), V(-70, -520) })

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
		drySpawns(ctx, hm, obj, 5)
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
		id = "Pacific",
		bounds = { center = Vector3.new(0, 50, 0), size = Vector3.new(SIZE, 600, SIZE) },
		hq = { Allies = alliesHQ.spawns, Axis = axisHQ.spawns },
		objectives = objectives,
		vehicleSpawns = {
			Allies = vehicles(alliesHQ.vehicles, { "Tank", "Transport", "Jeep" }),
			Axis = vehicles(axisHQ.vehicles, { "Tank", "Light", "Jeep" }),
		},
		outOfBounds = 10,
	})
end

return Pacific
