--[[
	Common building blocks shared by every vehicle style: the physics chassis + rig, wheels,
	tracks, turret & gun, machine-gun mounts, exit points, insignia and camouflage.
	Coordinates are chassis-local (Chassis at the origin, forward = -Z, up = +Y).
]]

local Kit = require(script.Parent.Kit)

local Common = {}

type Kit = Kit.Kit

local PIXELS_PER_STUD = 40

---------------------------------------------------------------------------------------------------
-- Chassis & physics rig
---------------------------------------------------------------------------------------------------

-- Invisible collision box that is the PrimaryPart and the only massive part of the vehicle.
-- `mass` is the desired assembly mass (density is clamped to Roblox's 0.01..100 range).
function Common.chassis(kit: Kit, size: Vector3, mass: number): Part
	local volume = size.X * size.Y * size.Z
	local density = math.clamp(mass / volume, 0.01, 100)
	local p = kit:box("Chassis", size, CFrame.identity, kit.palette.base, {
		noWeld = true,
		collide = true,
		query = false, -- shells/bullets hit the visible armor parts instead
		transparency = 1,
		shadow = false,
	})
	p.Massless = false
	p.CustomPhysicalProperties = PhysicalProperties.new(density, 0.35, 0.1, 1, 1)
	kit.base = p
	kit.model.PrimaryPart = p
	return p
end

--[[
	Creates the constraint set driven by VehicleModels.Physics (see that module):
	  Attachment "Center", "UprightAtt", "Susp1".."SuspN"  (suspension ray origins at hull centre height)
	  VectorForce "SuspForce1".."SuspForceN"  (one per suspension point, world space)
	  LinearVelocity "Drive" (line along hull forward), "Grip" (line along hull right, velocity 0)
	  Torque "YawTorque" (world space), AlignOrientation "Upright" (limited-torque anti-flip assist)
	Chassis attributes: RideHeight (attachment height above ground at rest), Tracked.
]]
function Common.rig(kit: Kit, chassis: BasePart, points: { Vector3 }, rideHeight: number, tracked: boolean)
	local center = kit:attachment("Center", chassis, CFrame.identity)
	local upright = Instance.new("Attachment")
	upright.Name = "UprightAtt"
	upright.CFrame = CFrame.fromMatrix(Vector3.zero, Vector3.yAxis, Vector3.zAxis) -- primary axis = hull up
	upright.Parent = chassis

	for i, p in points do
		local att = kit:attachment("Susp" .. i, chassis, CFrame.new(p.X, 0, p.Z))
		local vf = Instance.new("VectorForce")
		vf.Name = "SuspForce" .. i
		vf.Attachment0 = att
		vf.RelativeTo = Enum.ActuatorRelativeTo.World
		vf.ApplyAtCenterOfMass = false
		vf.Force = Vector3.zero
		vf.Parent = chassis
	end

	local drive = Instance.new("LinearVelocity")
	drive.Name = "Drive"
	drive.Attachment0 = center
	drive.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	drive.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	drive.LineDirection = Vector3.new(0, 0, -1)
	drive.LineVelocity = 0
	drive.MaxForce = 0
	drive.Parent = chassis

	local grip = Instance.new("LinearVelocity")
	grip.Name = "Grip"
	grip.Attachment0 = center
	grip.RelativeTo = Enum.ActuatorRelativeTo.Attachment0
	grip.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
	grip.LineDirection = Vector3.new(1, 0, 0)
	grip.LineVelocity = 0
	grip.MaxForce = 0
	grip.Parent = chassis

	local torque = Instance.new("Torque")
	torque.Name = "YawTorque"
	torque.Attachment0 = center
	torque.RelativeTo = Enum.ActuatorRelativeTo.World
	torque.Torque = Vector3.zero
	torque.Parent = chassis

	local align = Instance.new("AlignOrientation")
	align.Name = "Upright"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = upright
	align.AlignType = Enum.AlignType.PrimaryAxisParallel
	align.PrimaryAxis = Vector3.yAxis
	align.Responsiveness = 10
	align.MaxTorque = 0 -- set from the assembly mass by Physics
	align.RigidityEnabled = false
	align.Parent = chassis

	chassis:SetAttribute("RideHeight", rideHeight)
	chassis:SetAttribute("Tracked", tracked)
end

-- Exit points: left, right and rear of the hull at ground + 3 studs.
function Common.exits(kit: Kit, chassis: BasePart, halfWidth: number, halfLength: number, groundY: number)
	local y = groundY + 3
	kit:attachment("ExitPoint", chassis, CFrame.new(-(halfWidth + 3), y, 0))
	kit:attachment("ExitPoint", chassis, CFrame.new(halfWidth + 3, y, 0))
	kit:attachment("ExitPoint", chassis, CFrame.new(0, y, halfLength + 4))
	kit:attachment("ExitPoint", chassis, CFrame.new(-(halfWidth + 3), y, -halfLength * 0.6))
end

---------------------------------------------------------------------------------------------------
-- Wheels & tracks
---------------------------------------------------------------------------------------------------

-- Spinning wheel (Motor6D "WheelMotor" with Radius/Side/Steer attributes for VehicleController).
-- A spoke bar across the hub makes rotation visible.
function Common.wheel(
	kit: Kit,
	name: string,
	pos: Vector3,
	radius: number,
	width: number,
	opts: { steer: boolean?, tire: Color3?, hub: Color3?, hubScale: number?, spin: boolean? }?
): Part
	local o = opts or {}
	local P = kit.palette
	local side = if pos.X < 0 then -1 else 1
	local wheel = kit:cyl(name, width, radius * 2, CFrame.new(pos), o.tire or P.rubber, {
		noWeld = true,
		material = Enum.Material.Rubber,
	})
	local hubD = radius * 2 * (o.hubScale or 0.62)
	kit:cyl("Hub", width + 0.08, hubD, CFrame.new(pos), o.hub or P.base, { base = wheel })
	if o.spin ~= false then
		kit:box(
			"Spoke",
			Vector3.new(width + 0.14, hubD * 0.22, hubD * 0.9),
			CFrame.new(pos),
			P.dark,
			{ base = wheel, shadow = false }
		)
		local m = kit:motor("WheelMotor", kit.base, wheel)
		m:SetAttribute("Radius", radius)
		m:SetAttribute("Side", side)
		m:SetAttribute("Steer", o.steer == true)
	else
		kit:weld(wheel, kit.base)
	end
	return wheel
end

export type TrackSpec = {
	width: number,
	height: number,
	length: number,
	wheels: number,
	wheelRadius: number,
	sprocketRadius: number?,
	rollers: number?,
	skirts: boolean?,
	panniers: boolean?,
	sprocketRear: boolean?,
}

-- One track run on `side` (-1 left / +1 right), centred at x, on ground level groundY.
function Common.track(kit: Kit, side: number, x: number, groundY: number, t: TrackSpec)
	local P = kit.palette
	local tw, th, tl = t.width, t.height, t.length
	local belt = 0.32
	local rs = t.sprocketRadius or math.min(th * 0.32, 1.1)
	local yTop = groundY + th
	local zF, zR = -tl / 2, tl / 2
	local ySpr = yTop - rs
	local r = t.wheelRadius
	local yWheel = groundY + belt + r

	-- Sprocket (front unless sprocketRear) and idler: spinning so the track looks driven.
	local zSpr = if t.sprocketRear then zR - rs else zF + rs
	local zIdl = if t.sprocketRear then zF + rs else zR - rs
	Common.wheel(kit, "Sprocket", Vector3.new(x, ySpr, zSpr), rs, tw * 0.7, {
		tire = P.track,
		hub = P.metal,
		hubScale = 0.8,
	})
	Common.wheel(kit, "Idler", Vector3.new(x, ySpr, zIdl), rs * 0.9, tw * 0.6, {
		tire = P.track,
		hub = P.metal,
		hubScale = 0.75,
	})

	-- Road wheels (static; the visible spin comes from the sprocket/idler).
	local first, last = zF + rs * 2 + r * 0.6, zR - rs * 2 - r * 0.6
	local n = t.wheels
	if n > 0 and not t.panniers then
		for i = 1, n do
			local a = if n == 1 then 0.5 else (i - 1) / (n - 1)
			local z = first + (last - first) * a
			kit:cyl("RoadWheel", tw * 0.72, r * 2, CFrame.new(x, yWheel, z), P.wheel, { material = Enum.Material.Metal })
		end
	end
	for i = 1, (t.rollers or 0) do
		local z = first + (last - first) * (i / ((t.rollers or 0) + 1))
		kit:cyl("ReturnRoller", tw * 0.5, 0.55, CFrame.new(x, yTop - belt - 0.3, z), P.wheel)
	end

	-- Track belt: top run, bottom run, front and rear slants.
	local bottomF = Vector3.new(x, groundY + belt / 2, first - r * 0.4)
	local bottomR = Vector3.new(x, groundY + belt / 2, last + r * 0.4)
	kit:box(
		"TrackTop",
		Vector3.new(tw, belt, (zIdl - zSpr) * side * 0 + math.abs(zIdl - zSpr)),
		CFrame.new(x, yTop - belt / 2, (zSpr + zIdl) / 2),
		P.track,
		{ material = Enum.Material.DiamondPlate }
	)
	kit:box(
		"TrackBottom",
		Vector3.new(tw, belt, bottomR.Z - bottomF.Z),
		CFrame.new(x, groundY + belt / 2, (bottomF.Z + bottomR.Z) / 2),
		P.track,
		{ material = Enum.Material.DiamondPlate }
	)
	kit:beam("TrackFront", bottomF, Vector3.new(x, ySpr, zF + 0.05), tw, belt, P.track, {
		material = Enum.Material.DiamondPlate,
	})
	kit:beam("TrackRear", bottomR, Vector3.new(x, ySpr, zR - 0.05), tw, belt, P.track, {
		material = Enum.Material.DiamondPlate,
	})

	if t.panniers then
		-- Churchill / Char B1 style: armored pannier covering the whole run.
		kit:box(
			"Pannier",
			Vector3.new(0.3, th * 0.62, tl - rs * 3),
			CFrame.new(x + side * (tw / 2 + 0.05), groundY + th * 0.5, 0),
			P.base
		)
	elseif t.skirts then
		-- Schuerzen / side skirts in three plates with small gaps.
		local seg = (tl - rs * 2) / 3
		for i = 0, 2 do
			kit:box(
				"Skirt",
				Vector3.new(0.14, th * 0.5, seg - 0.15),
				CFrame.new(x + side * (tw / 2 + 0.25), yTop - th * 0.25, zF + rs + seg * (i + 0.5)),
				P.base
			)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Turret & gun
---------------------------------------------------------------------------------------------------

export type TurretSpec = {
	size: Vector3,
	z: number?,
	x: number?,
	shape: string?, -- "box" | "round" | "cast" | "horseshoe" | "open"
	bustle: number?,
	cupola: boolean?,
	sideSlope: number?,
	frontSlope: number?,
	stowage: boolean?,
	color: Color3?,
}

export type GunSpec = {
	length: number,
	radius: number,
	mantlet: Vector3?,
	y: number?,
	brake: boolean?,
	sleeve: boolean?,
	coaxOffset: number?,
}

-- Builds turret (Motor6D "TurretMotor" Chassis->Turret) and gun (Motor6D "GunMotor" Turret->Gun)
-- on a turret ring whose top is at `ringY`. Returns turret, gun.
function Common.turret(kit: Kit, chassis: BasePart, ringY: number, t: TurretSpec, g: GunSpec, hasCoax: boolean)
	local P = kit.palette
	local T = t.size
	local color = t.color or P.base
	local tcf = CFrame.new(t.x or 0, ringY + T.Y / 2, t.z or 0)
	local shape = t.shape or "box"

	-- turret ring (static, on the hull)
	kit:cyl(
		"TurretRing",
		0.3,
		math.min(T.X, T.Z) * 0.85,
		CFrame.new(t.x or 0, ringY + 0.1, t.z or 0) * Kit.VERTICAL,
		P.dark
	)

	local turret = kit:box(
		"Turret",
		if shape == "round" or shape == "cast" then Vector3.new(T.X * 0.82, T.Y, T.Z * 0.82) else T,
		tcf,
		color,
		{ noWeld = true, collide = true }
	)
	kit:motor("TurretMotor", chassis, turret)
	local prevBase = kit.base
	kit.base = turret

	if shape == "round" or shape == "cast" then
		kit:cyl("TurretCast", T.Y * 0.98, math.max(T.X, T.Z), tcf * Kit.VERTICAL, color)
		if shape == "cast" then
			-- sloped cheeks give the cast/rounded look
			kit:wedge(
				"TurretFace",
				Vector3.new(T.X * 0.8, T.Y * 0.6, T.Z * 0.22),
				tcf * CFrame.new(0, T.Y * 0.2, -T.Z * 0.5 - T.Z * 0.05),
				color
			)
		end
	elseif shape == "horseshoe" then
		kit:cyl(
			"TurretRear",
			T.Y * 0.98,
			T.X,
			tcf * CFrame.new(0, 0, T.Z * 0.15) * Kit.VERTICAL,
			color
		)
	elseif shape == "open" then
		-- open-topped turret: the Turret part is the floor/ring; add thin walls and a mesh screen
		kit:box("TurretWallL", Vector3.new(0.2, T.Y * 0.9, T.Z), tcf * CFrame.new(-T.X / 2, T.Y * 0.4, 0), color)
		kit:box("TurretWallR", Vector3.new(0.2, T.Y * 0.9, T.Z), tcf * CFrame.new(T.X / 2, T.Y * 0.4, 0), color)
		kit:wedge(
			"MeshScreenL",
			Vector3.new(T.Z, T.Y * 0.6, T.X * 0.5),
			tcf * CFrame.new(-T.X * 0.25, T.Y * 1.15, 0) * Kit.FACE_LEFT,
			P.metal,
			{ transparency = 0.55, material = Enum.Material.DiamondPlate }
		)
		kit:wedge(
			"MeshScreenR",
			Vector3.new(T.Z, T.Y * 0.6, T.X * 0.5),
			tcf * CFrame.new(T.X * 0.25, T.Y * 1.15, 0) * Kit.FACE_RIGHT,
			P.metal,
			{ transparency = 0.55, material = Enum.Material.DiamondPlate }
		)
	end

	if t.sideSlope and t.sideSlope > 0 then
		local d = t.sideSlope
		local h = T.Y * 0.55
		kit:wedge(
			"TurretCheekL",
			Vector3.new(T.Z * 0.95, h, d),
			tcf * CFrame.new(-T.X / 2 - d / 2, T.Y / 2 - h / 2, 0) * Kit.FACE_LEFT,
			color
		)
		kit:wedge(
			"TurretCheekR",
			Vector3.new(T.Z * 0.95, h, d),
			tcf * CFrame.new(T.X / 2 + d / 2, T.Y / 2 - h / 2, 0) * Kit.FACE_RIGHT,
			color
		)
	end
	if t.frontSlope and t.frontSlope > 0 then
		local d = t.frontSlope
		kit:wedge(
			"TurretRoofSlope",
			Vector3.new(T.X * 0.9, T.Y * 0.35, d),
			tcf * CFrame.new(0, T.Y / 2 + T.Y * 0.175 - 0.01, -T.Z / 2 + d / 2 + 0.01),
			color
		)
	end
	if t.bustle and t.bustle > 0 then
		local b = t.bustle
		kit:box(
			if t.stowage then "StowageBin" else "Bustle",
			Vector3.new(T.X * 0.8, T.Y * 0.7, b),
			tcf * CFrame.new(0, T.Y * 0.08, T.Z / 2 + b / 2),
			if t.stowage then P.dark else color
		)
	end
	if t.cupola then
		local cpos = tcf * CFrame.new(-T.X * 0.22, T.Y / 2 + 0.3, T.Z * 0.22)
		kit:cyl("Cupola", 0.6, math.min(T.X, T.Z) * 0.36, cpos * Kit.VERTICAL, color)
		kit:cyl("Hatch", 0.15, math.min(T.X, T.Z) * 0.3, cpos * CFrame.new(0, 0.36, 0) * Kit.VERTICAL, P.dark)
	else
		kit:box(
			"Hatch",
			Vector3.new(T.X * 0.3, 0.14, T.Z * 0.3),
			tcf * CFrame.new(T.X * 0.18, T.Y / 2 + 0.07, T.Z * 0.15),
			P.dark
		)
	end
	-- periscope / vision block
	kit:box("Periscope", Vector3.new(0.5, 0.35, 0.4), tcf * CFrame.new(T.X * 0.2, T.Y / 2 + 0.17, -T.Z * 0.25), P.metal)

	-- Gun (Motor6D "GunMotor" pivots at the mantlet centre = trunnion).
	local M = g.mantlet or Vector3.new(T.X * 0.4, T.Y * 0.55, 0.7)
	local gunCf = tcf * CFrame.new(0, g.y or -T.Y * 0.05, -(if shape == "round" or shape == "cast" then math.max(T.X, T.Z) / 2 else T.Z / 2) - M.Z / 2 + 0.25)
	local gun = kit:box("Gun", M, gunCf, color, { noWeld = true })
	kit:motor("GunMotor", turret, gun)
	kit.base = gun

	local L, r = g.length, g.radius
	local front = -M.Z / 2
	if g.sleeve then
		kit:cyl("GunSleeve", L * 0.22, r * 2.6, gunCf * CFrame.new(0, 0, front - L * 0.11) * Kit.ALONG_Z, color)
	end
	kit:cyl("Barrel", L, r * 2, gunCf * CFrame.new(0, 0, front - L / 2) * Kit.ALONG_Z, P.metal)
	if g.brake then
		kit:cyl("MuzzleBrake", 0.8, r * 3.2, gunCf * CFrame.new(0, 0, front - L + 0.2) * Kit.ALONG_Z, P.metal)
	end
	kit:attachment("Muzzle", gun, gunCf * CFrame.new(0, 0, front - L - 0.15))
	if hasCoax then
		local cx = g.coaxOffset or M.X * 0.32
		kit:cyl("CoaxMG", 1.1, 0.16, gunCf * CFrame.new(cx, 0.12, front - 0.45) * Kit.ALONG_Z, P.metal)
		kit:attachment("Coax", gun, gunCf * CFrame.new(cx, 0.12, front - 1.05))
	end

	kit.base = prevBase
	return turret, gun
end

---------------------------------------------------------------------------------------------------
-- Machine-gun mounts ("MGMount" part, Motor6D "MGMotor", Attachment "HullMG" at the muzzle)
---------------------------------------------------------------------------------------------------

-- Ball-mounted bow MG on a glacis at `pos`.
function Common.bowMG(kit: Kit, chassis: BasePart, pos: Vector3)
	local P = kit.palette
	local mount = kit:ball("MGMount", 0.75, CFrame.new(pos), P.base, { noWeld = true })
	kit:motor("MGMotor", chassis, mount)
	kit:cyl("HullMGBarrel", 1.3, 0.16, CFrame.new(pos + Vector3.new(0, 0, -0.65)) * Kit.ALONG_Z, P.metal, {
		base = mount,
	})
	kit:attachment("HullMG", mount, CFrame.new(pos + Vector3.new(0, 0, -1.35)))
end

-- Pintle / ring-mounted MG on a post rising from `basePos`, gun at basePos + up*height.
function Common.pintleMG(
	kit: Kit,
	chassis: BasePart,
	basePos: Vector3,
	height: number,
	opts: { shield: boolean?, heavy: boolean?, ring: number?, noPost: boolean? }?
)
	local o = opts or {}
	local P = kit.palette
	if o.ring then
		kit:cyl(
			"MGRing",
			0.18,
			o.ring,
			CFrame.new(basePos + Vector3.new(0, height - 0.35, 0)) * Kit.VERTICAL,
			P.metal,
			{ material = Enum.Material.DiamondPlate }
		)
	elseif not o.noPost then
		kit:cyl(
			"MGPost",
			height,
			0.22,
			CFrame.new(basePos + Vector3.new(0, height / 2, 0)) * Kit.VERTICAL,
			P.metal
		)
	end
	local gunPos = basePos + Vector3.new(0, height, 0)
	local mount = kit:box("MGMount", Vector3.new(0.3, 0.45, 1.6), CFrame.new(gunPos), P.metal, { noWeld = true })
	kit:motor("MGMotor", chassis, mount)
	local barrelLen = if o.heavy then 2.6 else 1.8
	kit:cyl(
		"MGBarrel",
		barrelLen,
		if o.heavy then 0.24 else 0.16,
		CFrame.new(gunPos + Vector3.new(0, 0.05, -0.8 - barrelLen / 2)) * Kit.ALONG_Z,
		P.metal,
		{ base = mount }
	)
	kit:box("MGAmmo", Vector3.new(0.45, 0.4, 0.55), CFrame.new(gunPos + Vector3.new(0.35, -0.1, 0)), P.dark, {
		base = mount,
	})
	kit:box("MGGrip", Vector3.new(0.18, 0.4, 0.3), CFrame.new(gunPos + Vector3.new(0, -0.2, 0.75)), P.wood, {
		base = mount,
	})
	if o.shield then
		kit:box(
			"MGShield",
			Vector3.new(1.8, 1.3, 0.12),
			CFrame.new(gunPos + Vector3.new(0, 0.25, -0.9)),
			P.base,
			{ base = mount }
		)
	end
	kit:attachment("HullMG", mount, CFrame.new(gunPos + Vector3.new(0, 0.05, -0.85 - barrelLen)))
end

---------------------------------------------------------------------------------------------------
-- Decoration: insignia, camouflage, stowage
---------------------------------------------------------------------------------------------------

local function frame(parent: Instance, size: number, color: Color3, round: boolean, zIndex: number): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale(0.5, 0.5)
	f.Size = UDim2.fromScale(size, size)
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.ZIndex = zIndex
	if round then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = f
	end
	f.Parent = parent
	return f
end

local function glyph(parent: Instance, text: string, color: Color3, stroke: Color3?, zIndex: number)
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.52)
	l.Size = UDim2.fromScale(1.1, 1.1)
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextScaled = true
	l.Font = Enum.Font.SourceSansBold
	l.TextColor3 = color
	l.ZIndex = zIndex
	if stroke then
		l.TextStrokeColor3 = stroke
		l.TextStrokeTransparency = 0
	end
	l.Parent = parent
end

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.fromRGB(20, 20, 20)

-- National marking on `face` of `part`, `size` studs across. Built from GUI frames (no assets).
function Common.insignia(part: BasePart, face: Enum.NormalId, insignia: string, size: number, offset: Vector2?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Insignia"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD
	gui.LightInfluence = 1
	gui.MaxDistance = 400
	gui.Parent = part
	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	local off = offset or Vector2.zero
	root.Position = UDim2.new(0.5, off.X * PIXELS_PER_STUD, 0.5, off.Y * PIXELS_PER_STUD)
	root.Size = UDim2.fromOffset(size * PIXELS_PER_STUD, size * PIXELS_PER_STUD)
	root.Parent = gui

	if insignia == "US" then
		local ring = frame(root, 1, WHITE, true, 1)
		ring.BackgroundTransparency = 1
		local s = Instance.new("UIStroke")
		s.Color = WHITE
		s.Thickness = size * 2.5
		s.Parent = ring
		glyph(root, "★", WHITE, nil, 2)
	elseif insignia == "UK" then
		frame(root, 1, Color3.fromRGB(36, 52, 120), true, 1)
		frame(root, 0.66, WHITE, true, 2)
		frame(root, 0.34, Color3.fromRGB(190, 30, 40), true, 3)
	elseif insignia == "FR" then
		frame(root, 1, Color3.fromRGB(200, 40, 45), true, 1)
		frame(root, 0.66, WHITE, true, 2)
		frame(root, 0.34, Color3.fromRGB(30, 60, 150), true, 3)
	elseif insignia == "USSR" then
		glyph(root, "★", Color3.fromRGB(200, 25, 25), WHITE, 1)
	elseif insignia == "DE" then
		local bars = {
			{ Vector2.new(1, 0.36), WHITE, 1 },
			{ Vector2.new(0.36, 1), WHITE, 1 },
			{ Vector2.new(0.86, 0.2), BLACK, 2 },
			{ Vector2.new(0.2, 0.86), BLACK, 2 },
		}
		for _, b in bars do
			local f = frame(root, 1, b[2], false, b[3])
			f.Size = UDim2.fromScale(b[1].X, b[1].Y)
		end
	elseif insignia == "JP" then
		glyph(root, "★", Color3.fromRGB(230, 200, 60), BLACK, 1)
	elseif insignia == "IT" then
		local f = frame(root, 1, Color3.fromRGB(180, 40, 40), false, 1)
		f.Size = UDim2.fromScale(1, 0.6)
		local bar = frame(root, 1, WHITE, false, 2)
		bar.Size = UDim2.fromScale(0.12, 0.6)
	end
end

-- Tactical number painted on `face`.
function Common.number(part: BasePart, face: Enum.NormalId, text: string, height: number, offset: Vector2?)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "TacticalNumber"
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PIXELS_PER_STUD
	gui.LightInfluence = 1
	gui.MaxDistance = 250
	gui.Parent = part
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	local off = offset or Vector2.zero
	l.Position = UDim2.new(0.5, off.X * PIXELS_PER_STUD, 0.5, off.Y * PIXELS_PER_STUD)
	l.Size = UDim2.fromOffset(height * 2.2 * PIXELS_PER_STUD, height * PIXELS_PER_STUD)
	l.Text = text
	l.TextScaled = true
	l.Font = Enum.Font.SourceSansBold
	l.TextColor3 = Color3.fromRGB(235, 235, 225)
	l.TextTransparency = 0.1
	l.Parent = gui
end

-- Camouflage blotches on the side faces of `part` (thin plates welded to it).
function Common.camo(kit: Kit, part: BasePart, rng: Random, count: number)
	local patches = kit.palette.patches
	if #patches == 0 then
		return
	end
	local s = part.Size
	for i = 1, count do
		local side = if i % 2 == 0 then 1 else -1
		local w = math.min(s.Z * rng:NextNumber(0.25, 0.45), 4)
		local h = math.min(s.Y * rng:NextNumber(0.35, 0.7), 2)
		local z = rng:NextNumber(-s.Z / 2 + w / 2, s.Z / 2 - w / 2)
		local y = rng:NextNumber(-s.Y / 2 + h / 2, s.Y / 2 - h / 2)
		kit:box(
			"Camo",
			Vector3.new(0.05, h, w),
			part.CFrame * CFrame.new(side * (s.X / 2 + 0.02), y, z),
			patches[rng:NextInteger(1, #patches)],
			{ base = part, shadow = false, query = false }
		)
	end
end

function Common.jerrycans(kit: Kit, pos: Vector3, count: number, alongX: boolean)
	for i = 1, count do
		local off = (i - (count + 1) / 2) * 0.75
		local p = if alongX then pos + Vector3.new(off, 0, 0) else pos + Vector3.new(0, 0, off)
		kit:box("Jerrycan", Vector3.new(0.6, 1.1, 0.8), CFrame.new(p), kit.palette.dark, { shadow = false })
	end
end

function Common.exhausts(kit: Kit, pos: Vector3, spacing: number)
	for _, s in { -1, 1 } do
		kit:cyl(
			"Exhaust",
			1.4,
			0.5,
			CFrame.new(pos + Vector3.new(s * spacing, 0, 0)) * Kit.ALONG_Z,
			Color3.fromRGB(70, 52, 40),
			{ material = Enum.Material.CorrodedMetal }
		)
	end
end

function Common.headlights(kit: Kit, pos: Vector3, spacing: number)
	for _, s in { -1, 1 } do
		kit:cyl(
			"Headlight",
			0.3,
			0.55,
			CFrame.new(pos + Vector3.new(s * spacing, 0, 0)) * Kit.ALONG_Z,
			Color3.fromRGB(200, 200, 180),
			{ material = Enum.Material.Glass, shadow = false }
		)
	end
end

return Common
