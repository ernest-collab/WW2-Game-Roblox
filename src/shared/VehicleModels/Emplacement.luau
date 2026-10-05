--[[
	"ATGun" style: emplaced anti-tank gun. Static (Chassis anchored, no physics rig).
	  Chassis   invisible axle block (anchored)
	  Wheels    two non-spinning wheels, split trails dug into the ground
	  Turret    upper carriage / cradle (TurretMotor, limited traverse) carrying the gun shield
	            and the gunner's seat (the gunner swings with the gun)
	  Gun       recoil sleeve + barrel + muzzle brake, "Muzzle" attachment
]]

local Common = require(script.Parent.Common)
local Kit = require(script.Parent.Kit)
local Tracked = require(script.Parent.Tracked)

local Emplacement = {}

function Emplacement.build(kit: Kit.Kit, s: any, _def: any): Tracked.BuildInfo
	local P = kit.palette
	local axleH = s.axleHeight or 1.4
	local yG = -axleH
	local track = s.track or 3.6
	local chassis = Common.chassis(kit, Vector3.new(track - 0.6, 0.8, 1.6), s.mass or 600)
	chassis.Anchored = true

	kit:cyl("Axle", track, 0.35, CFrame.identity, P.metal)
	local wr = s.wheelRadius or 1.2
	for _, side in { -1, 1 } do
		Common.wheel(kit, "Wheel", Vector3.new(side * track / 2, yG + wr, 0), wr, 0.45, { spin = false })
		-- split trails
		local a = Vector3.new(side * 0.4, 0, 0.4)
		local b = Vector3.new(side * (s.trailSpread or 2.4), yG + 0.2, s.trailLength or 6)
		kit:beam("Trail", a, b, 0.35, 0.45, P.base)
		kit:box("Spade", Vector3.new(0.7, 0.7, 0.15), CFrame.new(b + Vector3.new(0, -0.1, 0.1)), P.dark)
	end

	-- Upper carriage (turret) and shield
	local cradleCf = CFrame.new(0, 0.55, -0.1)
	local turret = kit:box("Turret", Vector3.new(1.3, 0.7, 2.2), cradleCf, P.base, { noWeld = true, collide = true })
	kit:motor("TurretMotor", chassis, turret)
	local prev = kit.base
	kit.base = turret
	local sh = s.shield or Vector3.new(4.2, 2.6, 0.15)
	local shieldCf = CFrame.new(0, 0.55 + sh.Y * 0.35, -0.9)
	local shield = kit:box("Shield", sh, shieldCf * CFrame.Angles(math.rad(-8), 0, 0), P.base)
	if s.shieldTop then
		kit:box(
			"ShieldTop",
			Vector3.new(sh.X * 0.7, sh.Y * 0.35, sh.Z),
			shieldCf * CFrame.new(0, sh.Y * 0.62, 0.1) * CFrame.Angles(math.rad(-15), 0, 0),
			P.base
		)
	end
	kit:box("SightBox", Vector3.new(0.3, 0.35, 0.6), cradleCf * CFrame.new(-0.6, 0.6, 0.1), P.dark)

	-- Gun (elevates about the trunnion)
	local gunCf = CFrame.new(0, 1.05, -0.2)
	local gun = kit:box("Gun", Vector3.new(0.7, 0.7, 2.4), gunCf, P.base, { noWeld = true })
	kit:motor("GunMotor", turret, gun)
	kit.base = gun
	local L, r = s.barrelLength or 7, s.barrelRadius or 0.2
	kit:cyl("Barrel", L, r * 2, gunCf * CFrame.new(0, 0, -1.2 - L / 2) * Kit.ALONG_Z, P.metal)
	if s.brake then
		kit:cyl("MuzzleBrake", 0.7, r * 3.2, gunCf * CFrame.new(0, 0, -1.2 - L + 0.3) * Kit.ALONG_Z, P.metal)
	end
	kit:cyl("Breech", 0.9, 0.9, gunCf * CFrame.new(0, 0, 1.1) * Kit.ALONG_Z, P.metal)
	kit:attachment("Muzzle", gun, gunCf * CFrame.new(0, 0, -1.2 - L - 0.15))
	kit.base = prev

	return {
		chassis = chassis,
		points = {},
		rideHeight = axleH,
		halfWidth = track / 2 + 0.5,
		halfLength = 2,
		groundY = yG,
		seats = {
			driver = CFrame.new(-0.95, yG + 1.3, 1.4),
			passengers = {},
			base = turret,
		},
		marks = { { part = shield, faces = { Enum.NormalId.Front }, size = 0.9 } },
		numberPart = nil,
		camo = {},
	}
end

return Emplacement
