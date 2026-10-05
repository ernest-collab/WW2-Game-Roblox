--[[
	VehicleModels: procedural vehicle builder (Vehicle team).

		local model = VehicleModels.Build("M4Sherman")   -- unparented Model at the origin
		model:PivotTo(spawnCFrame); model.Parent = workspace

	MODEL STRUCTURE (forward = -Z of the Chassis, all parts unanchored unless static)
	  Chassis (Part, PrimaryPart)  invisible, CanQuery=false collision box; the ONLY massive part.
	      Attachments  Center, UprightAtt, Susp1..N (suspension ray origins), ExitPoint (x3-4)
	      Constraints  SuspForce1..N (VectorForce), Drive & Grip (LinearVelocity, Line mode),
	                   YawTorque (Torque), Upright (AlignOrientation)   -> driven by VehicleModels.Physics
	      Attributes   RideHeight (number), Tracked (bool)
	  Visible parts    welded (Weld) to Chassis; Massless, CanCollide=false except UpperHull/Turret/
	                   Cab/Deck; CanQuery=true so shells hit the real armor faces (WedgePart glacis).
	  Turret (Part)    Motor6D "TurretMotor" (Chassis -> Turret). Yaw = Transform CFrame.Angles(0, yaw, 0).
	  Gun (Part)       Motor6D "GunMotor" (Turret -> Gun), pivot = trunnion. Pitch = CFrame.Angles(pitch, 0, 0).
	      Attachment "Muzzle" (LookVector = bore axis), "Coax" (coaxial MG muzzle, if any)
	  MGMount (Part)   Motor6D "MGMotor" (Chassis -> MGMount); Attachment "HullMG" at the MG muzzle
	                   (bow ball mounts and pintle/ring mounts alike, if the vehicle has a hullMG)
	  WheelMotor       Motor6D per spinning wheel/sprocket/idler (attributes Radius, Side, Steer)
	  Seats            Seat instances: "DriverSeat" for seat id "Driver", others named by seat id
	                   (Vehicles.seatInstanceName). CanTouch=false; seat via Seat:Sit() only.
	                   Hidden seats (exposed=false) are transparent and inside the armor.
	  Insignia         SurfaceGui national markings + tactical numbers (no image assets).
	Turret/Gun/MG Transforms are set locally by every client (VehicleController) from the model
	attributes TurretYaw / GunPitch / MGYaw / MGPitch; the server computes muzzle positions
	analytically from the same Motor6D C0/C1 (see VehicleModels.MuzzleCFrame).
]]

local RunService = game:GetService("RunService")

local Vehicles = require(script.Parent.Config.Vehicles)
local Common = require(script.Common)
local Emplacement = require(script.Emplacement)
local Kit = require(script.Kit)
local Physics = require(script.Physics)
local Specs = require(script.Specs)
local Tracked = require(script.Tracked)
local Wheeled = require(script.Wheeled)

local VehicleModels = {}

VehicleModels.Physics = Physics
VehicleModels.Specs = Specs
VehicleModels.PART_BUDGET = 120
VehicleModels.COLLISION_GROUP = "Vehicles"

local BUILDERS: { [string]: (Kit.Kit, any, any) -> Tracked.BuildInfo } = {
	Tank = Tracked.build,
	ArmoredCar = Wheeled.armoredCar,
	Jeep = Wheeled.jeep,
	Truck = Wheeled.truck,
	Halftrack = Wheeled.halftrack,
	ATGun = Emplacement.build,
}

local function hashString(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return h
end

function VehicleModels.Build(vehicleId: string): Model
	local def = Vehicles.get(vehicleId)
	local spec = Specs.byId[vehicleId]
	assert(def and spec, `[VehicleModels] unknown vehicle '{vehicleId}'`)
	local builder = BUILDERS[spec.style]
	assert(builder, `[VehicleModels] unknown style '{spec.style}'`)

	local factionId = def.factions[1]
	local palette = Specs.PALETTES[factionId] or Specs.PALETTES.US
	local model = Instance.new("Model")
	model.Name = vehicleId
	local kit = Kit.new(model, palette, VehicleModels.COLLISION_GROUP)
	local info = builder(kit, spec, def)
	local chassis = info.chassis

	-- Seats
	local passengerIndex = 0
	for _, seatDef in def.seats do
		local cf: CFrame
		if seatDef.role == "driver" then
			cf = info.seats.driver
		elseif seatDef.role == "gunner" then
			cf = info.seats.gunner or info.seats.driver * CFrame.new(1.6, 0, 0)
		else
			passengerIndex += 1
			cf = info.seats.passengers[passengerIndex] or info.seats.driver * CFrame.new(0, 0, 1.8 * passengerIndex)
		end
		local seat = kit:seat(Vehicles.seatInstanceName(seatDef.id), cf, seatDef.exposed, info.seats.base or chassis)
		seat:SetAttribute("SeatId", seatDef.id)
	end

	-- Physics rig (not for emplacements)
	if not def.static and #info.points >= 3 then
		Common.rig(kit, chassis, info.points, info.rideHeight, def.tracked)
	end
	chassis:SetAttribute("RideHeight", info.rideHeight) -- chassis centre height above ground
	chassis:SetAttribute("HalfWidth", info.halfWidth)
	chassis:SetAttribute("HalfLength", info.halfLength)
	Common.exits(kit, chassis, info.halfWidth, info.halfLength, info.groundY)

	-- Markings
	local rng = Random.new(hashString(vehicleId))
	for _, mark in info.marks do
		for _, face in mark.faces do
			Common.insignia(mark.part, face, palette.insignia, mark.size)
		end
	end
	if info.numberPart then
		local num = tostring(rng:NextInteger(1, 9) * 100 + rng:NextInteger(10, 39))
		Common.number(info.numberPart, Enum.NormalId.Back, num, math.min(info.numberPart.Size.Y * 0.4, 0.9))
	end
	for _, part in info.camo do
		Common.camo(kit, part, rng, 4)
	end

	model:SetAttribute("PartCount", kit.count)
	if RunService:IsStudio() and kit.count > VehicleModels.PART_BUDGET then
		warn(`[VehicleModels] {vehicleId} uses {kit.count} parts (budget {VehicleModels.PART_BUDGET})`)
	end
	return model
end

-- World CFrame of a Motor6D's Part1 given a yaw/pitch Transform, computed analytically from the
-- Part0 CFrame (identical on server and clients, independent of local Transform state).
function VehicleModels.JointCFrame(motor: Motor6D, part0Cf: CFrame, yaw: number, pitch: number): CFrame
	return part0Cf * motor.C0 * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0) * motor.C1:Inverse()
end

-- Main gun muzzle world CFrame for a turret yaw / gun pitch (radians). nil if the model has no gun.
function VehicleModels.MuzzleCFrame(model: Model, yaw: number, pitch: number): CFrame?
	local chassis = model.PrimaryPart
	local turret = model:FindFirstChild("Turret")
	local gun = model:FindFirstChild("Gun")
	if not (chassis and turret and gun) then
		return nil
	end
	local tm = turret:FindFirstChild("TurretMotor")
	local gm = gun:FindFirstChild("GunMotor")
	local muzzle = gun:FindFirstChild("Muzzle")
	if not (tm and tm:IsA("Motor6D") and gm and gm:IsA("Motor6D") and muzzle and muzzle:IsA("Attachment")) then
		return nil
	end
	local turretCf = VehicleModels.JointCFrame(tm, chassis.CFrame, yaw, 0)
	local gunCf = VehicleModels.JointCFrame(gm, turretCf, 0, pitch)
	return gunCf * muzzle.CFrame
end

-- Muzzle of a named attachment on the Gun ("Coax") with the given turret/gun angles.
function VehicleModels.GunAttachmentCFrame(model: Model, name: string, yaw: number, pitch: number): CFrame?
	local chassis = model.PrimaryPart
	local turret = model:FindFirstChild("Turret")
	local gun = model:FindFirstChild("Gun")
	if not (chassis and turret and gun) then
		return nil
	end
	local tm = turret:FindFirstChild("TurretMotor")
	local gm = gun:FindFirstChild("GunMotor")
	local att = gun:FindFirstChild(name)
	if not (tm and tm:IsA("Motor6D") and gm and gm:IsA("Motor6D") and att and att:IsA("Attachment")) then
		return nil
	end
	local turretCf = VehicleModels.JointCFrame(tm, chassis.CFrame, yaw, 0)
	return VehicleModels.JointCFrame(gm, turretCf, 0, pitch) * att.CFrame
end

-- Hull/pintle MG muzzle world CFrame for the given mount yaw / pitch.
function VehicleModels.HullMGCFrame(model: Model, yaw: number, pitch: number): CFrame?
	local chassis = model.PrimaryPart
	local mount = model:FindFirstChild("MGMount")
	if not (chassis and mount) then
		return nil
	end
	local m = mount:FindFirstChild("MGMotor")
	local att = mount:FindFirstChild("HullMG")
	if not (m and m:IsA("Motor6D") and att and att:IsA("Attachment")) then
		return nil
	end
	return VehicleModels.JointCFrame(m, chassis.CFrame, yaw, pitch) * att.CFrame
end

return VehicleModels
