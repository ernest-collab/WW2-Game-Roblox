--[[
	Wheeled & half-tracked styles:
	  "ArmoredCar" : armored body with nose/tail wedges, sloped sides, wheels, turret.
	  "Jeep"       : open light car (tub body, hood, windshield, spare wheel, pintle MG).
	  "Truck"      : frame, cab, hood, cargo bed with benches and optional canvas tilt.
	  "Halftrack"  : steerable front wheels + rear track runs, open armored compartment, MG.
	Every style returns the same BuildInfo as Tracked.build.
]]

local Common = require(script.Parent.Common)
local Kit = require(script.Parent.Kit)
local Tracked = require(script.Parent.Tracked)

local Wheeled = {}

type BuildInfo = Tracked.BuildInfo

local RIGHT = CFrame.Angles(0, -math.pi / 2, 0) -- seat facing +X
local LEFT = CFrame.Angles(0, math.pi / 2, 0) -- seat facing -X
local TAIL_DOWN = CFrame.Angles(math.pi, 0, 0) -- wedge slope faces backward-down

-- Wheels on every axle (first axle steers). Returns suspension points.
local function wheels(kit: Kit.Kit, w: any, halfTrack: number, yG: number, dual: { [number]: boolean }?): { Vector3 }
	local points = {}
	for i, z in w.axles do
		local width = if dual and dual[i] then w.width * 1.6 else w.width
		for _, side in { -1, 1 } do
			local x = side * halfTrack
			Common.wheel(kit, "Wheel", Vector3.new(x, yG + w.radius, z), w.radius, width, { steer = i == 1 })
			table.insert(points, Vector3.new(x, 0, z))
		end
	end
	return points
end

local function mudguards(kit: Kit.Kit, w: any, halfTrack: number, yG: number)
	for _, z in w.axles do
		for _, side in { -1, 1 } do
			kit:box(
				"Mudguard",
				Vector3.new(w.width + 0.3, 0.14, w.radius * 2.3),
				CFrame.new(side * halfTrack, yG + w.radius * 2 + 0.25, z),
				kit.palette.base,
				{ shadow = false }
			)
		end
	end
end

---------------------------------------------------------------------------------------------------

function Wheeled.armoredCar(kit: Kit.Kit, s: any, def: any): BuildInfo
	local P = kit.palette
	local W, H, L = s.hull.X, s.hull.Y, s.hull.Z
	local w = s.wheels
	local clr = s.clearance
	local yG = -H / 2 - clr
	local chassis = Common.chassis(kit, Vector3.new(W, H, L), s.mass)
	local u = s.upper
	local nose, tail = u.nose or 2, u.tail or 1.5
	local bodyL = L - nose - tail
	local bodyZ = (nose - tail) / 2
	local lower = kit:box("LowerHull", Vector3.new(W, H, bodyL), CFrame.new(0, 0, bodyZ), P.base)
	kit:wedge(
		"Nose",
		Vector3.new(W, H, nose),
		CFrame.new(0, 0, bodyZ - bodyL / 2 - nose / 2) * Kit.FLIP_DOWN,
		P.base
	)
	kit:wedge("Tail", Vector3.new(W, H, tail), CFrame.new(0, 0, bodyZ + bodyL / 2 + tail / 2) * TAIL_DOWN, P.base)

	local Hu, Lu, uz = u.height, u.length, u.z or bodyZ
	local ss = u.sideSlope or 0
	local yU = H / 2 + Hu / 2
	local upper = kit:box(
		"UpperHull",
		Vector3.new(W - 2 * ss, Hu, Lu),
		CFrame.new(0, yU, uz),
		P.base,
		{ collide = true }
	)
	if ss > 0 then
		kit:wedge("SideL", Vector3.new(Lu, Hu, ss), CFrame.new(-W / 2 + ss / 2, yU, uz) * Kit.FACE_LEFT, P.base)
		kit:wedge("SideR", Vector3.new(Lu, Hu, ss), CFrame.new(W / 2 - ss / 2, yU, uz) * Kit.FACE_RIGHT, P.base)
	end
	local glacis = u.glacis or 1.6
	kit:wedge("Glacis", Vector3.new(W, Hu, glacis), CFrame.new(0, yU, uz - Lu / 2 - glacis / 2), P.base)
	local rearSlope = u.rear or 1
	kit:wedge(
		"RearSlope",
		Vector3.new(W, Hu, rearSlope),
		CFrame.new(0, yU, uz + Lu / 2 + rearSlope / 2) * Kit.FACE_BACK,
		P.base
	)
	kit:box(
		"DriverVisor",
		Vector3.new(1.4, 0.4, 0.3),
		CFrame.new(-W * 0.2, H / 2 + Hu - 0.25, uz - Lu / 2 - 0.12),
		P.dark
	)
	Common.headlights(kit, Vector3.new(0, H * 0.3, bodyZ - bodyL / 2 - nose * 0.6), W * 0.32)

	local halfTrack = W / 2 - w.width * 0.3
	local points = wheels(kit, w, halfTrack, yG)
	mudguards(kit, w, halfTrack, yG)

	local turret: BasePart? = nil
	if s.turret then
		turret = Common.turret(kit, chassis, H / 2 + Hu, s.turret, s.gun, def.weapons.coax ~= nil)
	end
	if s.mg then
		Tracked.mg(kit, chassis, s.mg)
	end

	local deckY = H / 2 + Hu + 0.3
	local markPart = turret or upper
	return {
		chassis = chassis,
		points = points,
		rideHeight = H / 2 + clr,
		halfWidth = W / 2 + w.width * 0.2,
		halfLength = L / 2,
		groundY = yG,
		seats = {
			driver = CFrame.new(-W * 0.2, -H * 0.05, uz - Lu * 0.3),
			gunner = if s.mg then CFrame.new(s.mg.pos.X, deckY, s.mg.pos.Z + 1.3) else nil,
			passengers = { CFrame.new(W * 0.2, -H * 0.05, uz - Lu * 0.3), CFrame.new(0, -H * 0.05, uz + Lu * 0.2) },
		},
		marks = {
			{ part = upper, faces = { Enum.NormalId.Left, Enum.NormalId.Right }, size = math.min(Hu * 0.75, 1.6) },
		},
		numberPart = markPart,
		camo = if turret then { upper, turret, lower } else { upper, lower },
	}
end

---------------------------------------------------------------------------------------------------

function Wheeled.jeep(kit: Kit.Kit, s: any, _def: any): BuildInfo
	local P = kit.palette
	local W, H, L = s.hull.X, s.hull.Y, s.hull.Z
	local w = s.wheels
	local clr = s.clearance
	local yG = -H / 2 - clr
	local chassis = Common.chassis(kit, Vector3.new(W, H, L), s.mass)
	local body = kit:box("Body", Vector3.new(W, H, L), CFrame.identity, P.base)

	local hood = s.hood
	local hoodL, hoodH = hood.length, hood.height
	local tubL = L - hoodL
	local wallH = s.wallHeight or 1
	local yWall = H / 2 + wallH / 2
	local tubZ = -L / 2 + hoodL + tubL / 2
	-- tub walls
	local wallL = kit:box("SideL", Vector3.new(0.18, wallH, tubL), CFrame.new(-W / 2 + 0.09, yWall, tubZ), P.base)
	kit:box("SideR", Vector3.new(0.18, wallH, tubL), CFrame.new(W / 2 - 0.09, yWall, tubZ), P.base)
	kit:box("Tailgate", Vector3.new(W, wallH, 0.18), CFrame.new(0, yWall, L / 2 - 0.09), P.base)
	-- hood & grille
	local hoodZ = -L / 2 + hoodL / 2
	if hood.slope then
		kit:wedge(
			"Hood",
			Vector3.new(W * 0.9, hoodH, hoodL),
			CFrame.new(0, H / 2 + hoodH / 2, hoodZ),
			P.base
		)
	else
		kit:box("Hood", Vector3.new(W * 0.78, hoodH, hoodL), CFrame.new(0, H / 2 + hoodH / 2, hoodZ), P.base)
		kit:box(
			"Grille",
			Vector3.new(W * 0.6, hoodH + H * 0.6, 0.2),
			CFrame.new(0, H / 2 + hoodH / 2 - H * 0.3, -L / 2 - 0.1),
			P.dark,
			{ material = Enum.Material.DiamondPlate }
		)
	end
	Common.headlights(kit, Vector3.new(0, H / 2 + hoodH * 0.4, -L / 2 - 0.15), W * 0.3)
	-- windshield (frame + glass)
	local wsZ = -L / 2 + hoodL + 0.1
	local wsH = s.windshield or 1.5
	local wsY = H / 2 + hoodH + wsH / 2 - 0.1
	kit:box("WindshieldFrame", Vector3.new(W * 0.92, 0.14, 0.14), CFrame.new(0, wsY + wsH / 2, wsZ), P.base)
	kit:box("Windshield", Vector3.new(W * 0.9, wsH, 0.08), CFrame.new(0, wsY, wsZ), P.glass, {
		material = Enum.Material.Glass,
		transparency = 0.6,
		query = false,
	})
	-- spare wheel on the back
	kit:cyl(
		"SpareWheel",
		w.width * 0.9,
		w.radius * 2,
		CFrame.new(0, H / 2 + wallH * 0.4, L / 2 + w.width * 0.5) * Kit.ALONG_Z,
		P.rubber,
		{ material = Enum.Material.Rubber }
	)
	Common.jerrycans(kit, Vector3.new(W / 2 + 0.35, H / 2 + 0.3, tubZ + tubL * 0.3), 1, false)

	local halfTrack = W / 2 - w.width * 0.25
	local points = wheels(kit, w, halfTrack, yG)
	mudguards(kit, w, halfTrack, yG)

	-- seats: two front, two rear; pintle MG between the front seats (gunner sits behind it)
	local seatY = H / 2 + 0.25
	local frontZ = wsZ + 1.6
	local rearZ = L / 2 - 1.4
	local gunnerX = -W * 0.22
	Tracked.mg(kit, chassis, {
		kind = "pintle",
		pos = Vector3.new(0, H / 2, (frontZ + rearZ) / 2 - 0.4),
		height = 2.7,
	})
	return {
		chassis = chassis,
		points = points,
		rideHeight = H / 2 + clr,
		halfWidth = W / 2 + w.width * 0.25,
		halfLength = L / 2,
		groundY = yG,
		seats = {
			driver = CFrame.new(-W * 0.22, seatY, frontZ),
			gunner = CFrame.new(gunnerX, seatY + 0.2, rearZ),
			passengers = { CFrame.new(W * 0.22, seatY, frontZ), CFrame.new(W * 0.24, seatY, rearZ) },
		},
		marks = { { part = body, faces = { Enum.NormalId.Left, Enum.NormalId.Right }, size = H * 0.8 } },
		numberPart = wallL,
		camo = {},
	}
end

---------------------------------------------------------------------------------------------------

function Wheeled.truck(kit: Kit.Kit, s: any, def: any): BuildInfo
	local P = kit.palette
	local W, H, L = s.hull.X, s.hull.Y, s.hull.Z
	local w = s.wheels
	local clr = s.clearance
	local yG = -H / 2 - clr
	local chassis = Common.chassis(kit, Vector3.new(W, H, L), s.mass)
	-- frame rails
	for _, side in { -1, 1 } do
		kit:box("FrameRail", Vector3.new(0.4, H * 0.7, L), CFrame.new(side * W * 0.3, 0, 0), P.dark)
	end
	local hoodL, cabL, cabH = s.hoodLength, s.cabLength, s.cabHeight
	local front = -L / 2
	-- hood
	local hoodZ = front + hoodL / 2
	if hoodL > 0 then
		kit:box(
			"Hood",
			Vector3.new(W * 0.62, cabH * 0.45, hoodL),
			CFrame.new(0, H / 2 + cabH * 0.225, hoodZ),
			P.base
		)
		kit:box(
			"Grille",
			Vector3.new(W * 0.6, cabH * 0.5, 0.2),
			CFrame.new(0, H / 2 + cabH * 0.22, front - 0.1),
			P.dark,
			{ material = Enum.Material.DiamondPlate }
		)
		for _, side in { -1, 1 } do
			kit:wedge(
				"Fender",
				Vector3.new(W * 0.2, 0.9, hoodL * 0.9),
				CFrame.new(side * W * 0.4, H / 2 + 0.45, hoodZ),
				P.base
			)
		end
	end
	Common.headlights(kit, Vector3.new(0, H / 2 + cabH * 0.25, front - 0.25), W * 0.38)
	-- cab
	local cabZ = front + hoodL + cabL / 2
	local cabColor = if s.woodCab then P.wood else P.base
	local cab = kit:box(
		"Cab",
		Vector3.new(W, cabH * 0.55, cabL),
		CFrame.new(0, H / 2 + cabH * 0.275, cabZ),
		cabColor,
		{ collide = true, material = if s.woodCab then Enum.Material.Wood else Enum.Material.Metal }
	)
	kit:box(
		"CabRoof",
		Vector3.new(W, 0.2, cabL),
		CFrame.new(0, H / 2 + cabH - 0.1, cabZ),
		if s.canvasCab then P.canvas else cabColor,
		{ material = if s.canvasCab then Enum.Material.Fabric else Enum.Material.Metal }
	)
	kit:box("CabBack", Vector3.new(W, cabH * 0.45, 0.2), CFrame.new(0, H / 2 + cabH * 0.775, cabZ + cabL / 2 - 0.1), cabColor)
	for _, side in { -1, 1 } do
		kit:box(
			"CabPillar",
			Vector3.new(0.18, cabH * 0.45, 0.18),
			CFrame.new(side * (W / 2 - 0.09), H / 2 + cabH * 0.775, cabZ - cabL / 2 + 0.09),
			cabColor
		)
	end
	kit:box(
		"Windshield",
		Vector3.new(W - 0.4, cabH * 0.4, 0.08),
		CFrame.new(0, H / 2 + cabH * 0.76, cabZ - cabL / 2 + 0.1),
		P.glass,
		{ material = Enum.Material.Glass, transparency = 0.55, query = false }
	)
	-- cargo bed
	local bedL = L - hoodL - cabL - 0.4
	local bedZ = L / 2 - bedL / 2
	local bedY = H / 2 + 0.15
	local wood = s.woodBed == true
	local bedColor = if wood then P.wood else P.base
	local bedMat = if wood then Enum.Material.WoodPlanks else Enum.Material.Metal
	kit:box("BedFloor", Vector3.new(W, 0.3, bedL), CFrame.new(0, bedY, bedZ), bedColor, {
		material = bedMat,
		collide = true,
	})
	local sideH = 1.3
	local sideL = kit:box(
		"BedSideL",
		Vector3.new(0.2, sideH, bedL),
		CFrame.new(-W / 2 + 0.1, bedY + sideH / 2, bedZ),
		bedColor,
		{ material = bedMat }
	)
	kit:box("BedSideR", Vector3.new(0.2, sideH, bedL), CFrame.new(W / 2 - 0.1, bedY + sideH / 2, bedZ), bedColor, {
		material = bedMat,
	})
	kit:box("Tailgate", Vector3.new(W, sideH, 0.2), CFrame.new(0, bedY + sideH / 2, L / 2 - 0.1), bedColor, {
		material = bedMat,
	})
	if s.canvas then
		local tiltH = s.canvasHeight or 2.6
		kit:box(
			"Tilt",
			Vector3.new(W + 0.04, tiltH, bedL - 0.2),
			CFrame.new(0, bedY + sideH + tiltH / 2 - 0.4, bedZ + 0.1),
			P.canvas,
			{ material = Enum.Material.Fabric, query = false, transparency = 0 }
		)
		kit:cyl(
			"TiltRoof",
			bedL - 0.2,
			W + 0.04,
			CFrame.new(0, bedY + sideH + tiltH - 0.4, bedZ + 0.1) * Kit.ALONG_Z,
			P.canvas,
			{ material = Enum.Material.Fabric, query = false }
		)
	end
	-- benches
	for _, side in { -1, 1 } do
		kit:box(
			"Bench",
			Vector3.new(0.8, 0.2, bedL - 1),
			CFrame.new(side * (W / 2 - 0.7), bedY + 0.8, bedZ),
			P.wood,
			{ material = Enum.Material.Wood, query = false }
		)
	end

	local halfTrack = W / 2 - w.width * 0.4
	local dual = {}
	for i = 2, #w.axles do
		dual[i] = s.dualRear ~= false
	end
	local points = wheels(kit, w, halfTrack, yG, dual)

	-- passenger positions along the benches, facing inward
	local passengers = { CFrame.new(W * 0.24, H / 2 + 0.6, cabZ + 0.1) }
	local benchCount = 0
	for _, seat in def.seats do
		if seat.role == "passenger" then
			benchCount += 1
		end
	end
	benchCount -= 1
	local perSide = math.max(1, math.ceil(benchCount / 2))
	for i = 1, benchCount do
		local side = if i % 2 == 1 then -1 else 1
		local idx = math.ceil(i / 2)
		local z = bedZ - bedL / 2 + 1 + (bedL - 2) * ((idx - 0.5) / perSide)
		table.insert(
			passengers,
			CFrame.new(side * (W / 2 - 0.75), bedY + 1.1, z) * (if side < 0 then RIGHT else LEFT)
		)
	end

	return {
		chassis = chassis,
		points = points,
		rideHeight = H / 2 + clr,
		halfWidth = W / 2 + w.width * 0.4,
		halfLength = L / 2,
		groundY = yG,
		seats = {
			driver = CFrame.new(-W * 0.24, H / 2 + 0.6, cabZ + 0.1),
			passengers = passengers,
		},
		marks = { { part = cab, faces = { Enum.NormalId.Left, Enum.NormalId.Right }, size = cabH * 0.4 } },
		numberPart = sideL,
		camo = {},
	}
end

---------------------------------------------------------------------------------------------------

function Wheeled.halftrack(kit: Kit.Kit, s: any, def: any): BuildInfo
	local P = kit.palette
	local W, H, L = s.hull.X, s.hull.Y, s.hull.Z
	local w = s.wheels
	local clr = s.clearance
	local yG = -H / 2 - clr
	local chassis = Common.chassis(kit, Vector3.new(W, H, L), s.mass)
	local lower = kit:box("LowerHull", Vector3.new(W * 0.8, H, L), CFrame.identity, P.base)

	-- engine compartment
	local hoodL, hoodH = s.hoodLength, s.hoodHeight
	local front = -L / 2
	local hoodZ = front + hoodL / 2
	local hoodW = W * 0.72
	if s.nose then
		kit:wedge(
			"Hood",
			Vector3.new(hoodW, hoodH, hoodL),
			CFrame.new(0, H / 2 + hoodH / 2, hoodZ),
			P.base
		)
	else
		kit:box("Hood", Vector3.new(hoodW, hoodH, hoodL), CFrame.new(0, H / 2 + hoodH / 2, hoodZ), P.base)
		kit:box(
			"Radiator",
			Vector3.new(hoodW * 0.9, hoodH * 0.9, 0.2),
			CFrame.new(0, H / 2 + hoodH / 2, front - 0.1),
			P.dark,
			{ material = Enum.Material.DiamondPlate }
		)
	end
	if s.roller then
		kit:cyl("Roller", W * 0.7, 1.1, CFrame.new(0, 0, front - 0.7), P.dark)
	end
	Common.headlights(kit, Vector3.new(0, H / 2 + hoodH * 0.5, front - 0.2), hoodW * 0.42)

	-- open fighting compartment (sloped or vertical walls)
	local compL = L - hoodL
	local compZ = front + hoodL + compL / 2
	local wallH = s.wallHeight
	local yWall = H / 2 + wallH / 2
	local slope = s.wallSlope or 0
	local wallL, wallR
	if slope > 0 then
		wallL = kit:wedge(
			"WallL",
			Vector3.new(compL, wallH, slope),
			CFrame.new(-W / 2 + slope / 2, yWall, compZ) * Kit.FACE_LEFT,
			P.base
		)
		wallR = kit:wedge(
			"WallR",
			Vector3.new(compL, wallH, slope),
			CFrame.new(W / 2 - slope / 2, yWall, compZ) * Kit.FACE_RIGHT,
			P.base
		)
	else
		wallL = kit:box("WallL", Vector3.new(0.25, wallH, compL), CFrame.new(-W / 2 + 0.125, yWall, compZ), P.base)
		wallR = kit:box("WallR", Vector3.new(0.25, wallH, compL), CFrame.new(W / 2 - 0.125, yWall, compZ), P.base)
	end
	kit:box("Dash", Vector3.new(W, wallH, 0.3), CFrame.new(0, yWall, front + hoodL + 0.15), P.base)
	kit:box("RearDoor", Vector3.new(W - 2 * math.max(slope, 0.25), wallH, 0.25), CFrame.new(0, yWall, L / 2 - 0.125), P.base)
	kit:box(
		"Visor",
		Vector3.new(W * 0.8, 0.3, 0.12),
		CFrame.new(0, H / 2 + wallH - 0.4, front + hoodL),
		P.dark
	)
	kit:box("Floor", Vector3.new(W - 2 * slope, 0.2, compL), CFrame.new(0, H / 2 + 0.1, compZ), P.dark, {
		collide = true,
	})

	-- front wheels + rear tracks
	local halfTrack = W / 2 - w.width * 0.2
	local points = {}
	for _, side in { -1, 1 } do
		Common.wheel(kit, "Wheel", Vector3.new(side * halfTrack, yG + w.radius, w.axle), w.radius, w.width, {
			steer = true,
		})
		table.insert(points, Vector3.new(side * halfTrack, 0, w.axle))
	end
	local tr = table.clone(s.track)
	local tl = tr.length
	local trackZ = L / 2 - tl / 2 - 0.3
	for _, side in { -1, 1 } do
		local x = side * (W / 2 - tr.width / 2)
		Common.track(kit, side, x, yG, tr, trackZ)
		table.insert(points, Vector3.new(x, 0, trackZ - tl / 2 + 1.2))
		table.insert(points, Vector3.new(x, 0, trackZ + tl / 2 - 1.2))
	end
	-- front mudguards
	for _, side in { -1, 1 } do
		kit:box(
			"Mudguard",
			Vector3.new(w.width + 0.3, 0.14, w.radius * 2.4),
			CFrame.new(side * halfTrack, yG + w.radius * 2 + 0.25, w.axle),
			P.base,
			{ shadow = false }
		)
	end

	if s.mg then
		Tracked.mg(kit, chassis, s.mg)
	end

	-- seats: driver front-left, gunner at the MG, passengers on benches facing inward
	local seatY = H / 2 + 0.5
	local passengers = {}
	local count = 0
	for _, seat in def.seats do
		if seat.role == "passenger" then
			count += 1
		end
	end
	local perSide = math.max(1, math.ceil(count / 2))
	local benchStart = front + hoodL + 3
	local benchLen = L / 2 - 0.8 - benchStart
	for i = 1, count do
		local side = if i % 2 == 1 then -1 else 1
		local idx = math.ceil(i / 2)
		local z = benchStart + benchLen * ((idx - 0.5) / perSide)
		table.insert(
			passengers,
			CFrame.new(side * (W / 2 - slope - 0.8), seatY, z) * (if side < 0 then RIGHT else LEFT)
		)
	end
	local gunnerCf = if s.mg
		then CFrame.new(s.mg.pos.X, H / 2 + (s.mg.seatHeight or 1.2), s.mg.pos.Z + 1.3)
		else CFrame.new(W * 0.22, seatY, front + hoodL + 1.4)
	return {
		chassis = chassis,
		points = points,
		rideHeight = H / 2 + clr,
		halfWidth = W / 2,
		halfLength = L / 2,
		groundY = yG,
		seats = {
			driver = CFrame.new(-W * 0.22, seatY, front + hoodL + 1.4),
			gunner = gunnerCf,
			passengers = passengers,
		},
		marks = { { part = wallL, faces = { Enum.NormalId.Left, Enum.NormalId.Right }, size = wallH * 0.7 } },
		numberPart = wallR,
		camo = { lower },
	}
end

return Wheeled
