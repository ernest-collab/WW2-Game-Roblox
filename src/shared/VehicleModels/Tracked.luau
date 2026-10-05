--[[
	Tracked styles: "Tank" (turreted tanks, light tanks) and open-topped tracked carriers
	("Tank" with upper.open = true, no turret).

	Layout (chassis-local, forward = -Z):
	  Chassis       invisible collision box spanning hull + tracks (PrimaryPart, only massive part)
	  LowerHull     visible hull between the tracks, LowerGlacis wedge below the nose
	  Track runs    Common.track on both sides (sprocket/idler spin via WheelMotor)
	  UpperHull     superstructure over the tracks (sponsons) + Glacis / RearSlope / side wedges
	  Turret/Gun    Common.turret on the roof (TurretMotor / GunMotor)
	  MG            bow ball mount (default when the vehicle has a hullMG) or spec.mg pintle
]]

local Common = require(script.Parent.Common)
local Kit = require(script.Parent.Kit)

local Tracked = {}

export type BuildInfo = {
	chassis: BasePart,
	points: { Vector3 },
	rideHeight: number,
	halfWidth: number,
	halfLength: number,
	groundY: number,
	seats: { driver: CFrame, gunner: CFrame?, passengers: { CFrame }, base: BasePart? },
	marks: { { part: BasePart, faces: { Enum.NormalId }, size: number } },
	numberPart: BasePart?,
	camo: { BasePart },
}

local RIGHT = CFrame.Angles(0, -math.pi / 2, 0) -- seat facing +X
local LEFT = CFrame.Angles(0, math.pi / 2, 0) -- seat facing -X

-- Optional MG mount described by spec.mg = {kind = "pintle"|"bow", pos, height?, shield?, heavy?, ring?, noPost?}
function Tracked.mg(kit: Kit.Kit, chassis: BasePart, mg: any)
	if mg.kind == "bow" then
		Common.bowMG(kit, chassis, mg.pos)
	else
		Common.pintleMG(kit, chassis, mg.pos, mg.height or 2, {
			shield = mg.shield,
			heavy = mg.heavy,
			ring = mg.ring,
			noPost = mg.noPost,
		})
	end
end

function Tracked.build(kit: Kit.Kit, s: any, def: any): BuildInfo
	local P = kit.palette
	local W, H, L = s.hull.X, s.hull.Y, s.hull.Z
	local tr = table.clone(s.track)
	tr.length = tr.length or (L + 1)
	local tw, tl = tr.width, tr.length
	local clr = s.clearance
	local yG = -H / 2 - clr
	local fullW = W + 2 * tw

	local chassis = Common.chassis(kit, Vector3.new(fullW, H, L), s.mass)
	local lower = kit:box("LowerHull", Vector3.new(W, H, L), CFrame.identity, P.base)
	local lg = s.lowerGlacis or 1
	kit:wedge("LowerGlacis", Vector3.new(W, H, lg), CFrame.new(0, 0, -L / 2 - lg / 2) * Kit.FLIP_DOWN, P.base)
	kit:box("RearPlate", Vector3.new(W, H * 0.9, 0.25), CFrame.new(0, 0, L / 2 + 0.12), P.dark)

	for _, side in { -1, 1 } do
		Common.track(kit, side, side * (W / 2 + tw / 2), yG, tr)
	end

	-- Superstructure
	local u = s.upper
	local Wu = u.width or fullW
	local Hu, Lu, uz = u.height, u.length, u.z or 0
	local yU = H / 2 + Hu / 2
	local ss = u.sideSlope or 0
	local upper: BasePart
	if u.open then
		-- open-topped fighting compartment: thin armored walls around the hull roof
		local wall = 0.25
		upper = kit:box("WallL", Vector3.new(wall, Hu, Lu), CFrame.new(-Wu / 2 + wall / 2, yU, uz), P.base)
		kit:box("WallR", Vector3.new(wall, Hu, Lu), CFrame.new(Wu / 2 - wall / 2, yU, uz), P.base)
		kit:box("WallRear", Vector3.new(Wu, Hu, wall), CFrame.new(0, yU, uz + Lu / 2 - wall / 2), P.base)
		kit:box("Deck", Vector3.new(Wu, 0.2, Lu), CFrame.new(0, H / 2 + 0.1, uz), P.dark, { collide = true })
	else
		upper = kit:box(
			"UpperHull",
			Vector3.new(Wu - 2 * ss, Hu, Lu),
			CFrame.new(0, yU, uz),
			P.base,
			{ collide = true }
		)
		if ss > 0 then
			kit:wedge(
				"SponsonL",
				Vector3.new(Lu, Hu, ss),
				CFrame.new(-Wu / 2 + ss / 2, yU, uz) * Kit.FACE_LEFT,
				P.base
			)
			kit:wedge(
				"SponsonR",
				Vector3.new(Lu, Hu, ss),
				CFrame.new(Wu / 2 - ss / 2, yU, uz) * Kit.FACE_RIGHT,
				P.base
			)
		end
		-- engine deck grille
		kit:box(
			"EngineDeck",
			Vector3.new((Wu - 2 * ss) * 0.6, 0.12, Lu * 0.28),
			CFrame.new(0, H / 2 + Hu + 0.06, uz + Lu * 0.3),
			P.dark,
			{ material = Enum.Material.DiamondPlate, shadow = false }
		)
	end
	local glacis = u.glacis or 1
	kit:wedge("Glacis", Vector3.new(Wu, Hu, glacis), CFrame.new(0, yU, uz - Lu / 2 - glacis / 2), P.base)
	if u.rear and u.rear > 0 then
		kit:wedge(
			"RearSlope",
			Vector3.new(Wu, Hu, u.rear),
			CFrame.new(0, yU, uz + Lu / 2 + u.rear / 2) * Kit.FACE_BACK,
			P.base
		)
	end
	-- mudguards over the track fronts
	for _, side in { -1, 1 } do
		kit:box(
			"Mudguard",
			Vector3.new(tw + 0.1, 0.12, 1.4),
			CFrame.new(side * (W / 2 + tw / 2), H / 2 - 0.06, -tl / 2 + 0.3),
			P.base,
			{ shadow = false }
		)
	end
	-- driver's visor block on the glacis top edge
	local frontZ = uz - Lu / 2
	kit:box(
		"DriverVisor",
		Vector3.new(1.3, 0.45, 0.35),
		CFrame.new(-Wu * 0.22, H / 2 + Hu - 0.2, frontZ - 0.1),
		P.dark
	)
	Common.headlights(kit, Vector3.new(0, H / 2 + Hu * 0.3, frontZ - glacis - 0.1), Wu * 0.36)
	Common.exhausts(kit, Vector3.new(0, H * 0.2, L / 2 + 0.5), W * 0.3)

	-- Weapons
	local turret: BasePart? = nil
	if s.turret then
		turret = Common.turret(kit, chassis, H / 2 + Hu, s.turret, s.gun, def.weapons.coax ~= nil)
	end
	if s.mg then
		Tracked.mg(kit, chassis, s.mg)
	elseif def.weapons.hullMG then
		Common.bowMG(kit, chassis, Vector3.new(Wu * 0.24, yU - Hu * 0.05, frontZ - glacis * 0.5 - 0.1))
	end

	-- Stowage
	local extras = s.extras or {}
	if table.find(extras, "jerrycans") then
		Common.jerrycans(kit, Vector3.new(0, H / 2 + Hu * 0.4, uz + Lu / 2 + (u.rear or 0) + 0.45), 3, true)
	end
	if table.find(extras, "spareTracks") then
		-- links laid along the glacis slope (from its lower front edge towards the roof)
		local a = Vector3.new(Wu * 0.3, H / 2 + 0.15, frontZ - glacis + 0.1)
		local b = Vector3.new(Wu * 0.3, H / 2 + Hu + 0.15, frontZ + 0.1)
		for i = 0, 2 do
			local f0, f1 = 0.15 + i * 0.25, 0.35 + i * 0.25
			kit:beam("SpareTrack", a:Lerp(b, f0), a:Lerp(b, f1), tw * 0.9, 0.18, P.track, { shadow = false })
		end
	end
	if table.find(extras, "logs") then
		kit:cyl(
			"Log",
			Wu * 0.9,
			0.7,
			CFrame.new(0, H / 2 + Hu + 0.35, uz + Lu * 0.45),
			P.wood,
			{ material = Enum.Material.Wood }
		)
	end
	if table.find(extras, "toolbox") then
		kit:box(
			"Toolbox",
			Vector3.new(tw * 0.8, 0.6, 2.2),
			CFrame.new(-(Wu / 2 - tw / 2), H / 2 + Hu + 0.3, uz + Lu * 0.2),
			P.dark
		)
	end
	if table.find(extras, "sandbags") then
		for i = -1, 1 do
			kit:box(
				"Sandbag",
				Vector3.new(Wu * 0.28, 0.5, 0.8),
				CFrame.new(i * Wu * 0.3, yU + Hu * 0.25, frontZ - glacis * 0.55),
				Color3.fromRGB(150, 135, 100),
				{ material = Enum.Material.Fabric, shadow = false }
			)
		end
	end
	if table.find(extras, "hullGun") then
		-- Char B1 bis 75mm hull howitzer (cosmetic)
		kit:cyl(
			"HullGun",
			3,
			0.55,
			CFrame.new(Wu * 0.18, yU - Hu * 0.15, frontZ - glacis - 0.8) * Kit.ALONG_Z,
			P.metal
		)
	end
	if table.find(extras, "antenna") then
		kit:cyl(
			"Antenna",
			5,
			0.08,
			CFrame.new(Wu * 0.38, H / 2 + Hu + 2.5, uz + Lu * 0.35) * Kit.VERTICAL,
			P.metal,
			{ shadow = false, query = false }
		)
	end

	-- Seats
	local seatY = -H * 0.1
	local seats
	if u.open then
		local y = H / 2 + 0.45
		seats = {
			driver = CFrame.new(Wu * 0.2, y, frontZ + 1.3),
			gunner = CFrame.new(-Wu * 0.2, y, frontZ + 1.3),
			passengers = {
				CFrame.new(-Wu * 0.25, y, uz + Lu * 0.25) * RIGHT,
				CFrame.new(Wu * 0.25, y, uz + Lu * 0.25) * LEFT,
			},
		}
	else
		seats = {
			driver = CFrame.new(-W * 0.22, seatY, -L * 0.25),
			gunner = CFrame.new(W * 0.22, seatY, -L * 0.25),
			passengers = { CFrame.new(0, seatY, L * 0.05), CFrame.new(0, seatY, L * 0.2) },
		}
	end

	local markPart = turret or upper
	local zs = tl / 2 - 1.6
	local xs = W / 2 + tw / 2
	return {
		chassis = chassis,
		points = {
			Vector3.new(-xs, 0, -zs),
			Vector3.new(xs, 0, -zs),
			Vector3.new(-xs, 0, 0),
			Vector3.new(xs, 0, 0),
			Vector3.new(-xs, 0, zs),
			Vector3.new(xs, 0, zs),
		},
		rideHeight = H / 2 + clr,
		halfWidth = fullW / 2,
		halfLength = L / 2,
		groundY = yG,
		seats = seats,
		marks = {
			{
				part = markPart,
				faces = { Enum.NormalId.Left, Enum.NormalId.Right },
				size = math.min(markPart.Size.Y * 0.8, 1.8),
			},
		},
		numberPart = if turret then turret else lower,
		camo = if turret then { upper, turret } else { upper },
	}
end

return Tracked
