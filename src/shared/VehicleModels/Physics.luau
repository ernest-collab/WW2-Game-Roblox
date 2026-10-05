--[[
	VehicleModels.Physics: raycast-suspension vehicle controller shared by the server (idle /
	settling vehicles) and the client (the driver, who owns the assembly's network ownership).

	It drives the constraints that VehicleModels.Build creates on the Chassis (see Common.rig):
	  * one VectorForce per suspension point: spring + damper from a downward ray
	    (static compression REST_COMPRESSION, so the hull rides at the Chassis "RideHeight");
	  * LinearVelocity "Drive" (line along hull forward): throttle, rate-limited by acceleration,
	    MaxForce sized to climb ~35 degree slopes and to hold the vehicle on hills when stopped;
	  * LinearVelocity "Grip" (line along hull right): lateral traction (tracks grip more);
	  * Torque "YawTorque": skid-steer for tracked vehicles (pivot in place), speed-dependent
	    steering for wheeled ones;
	  * AlignOrientation "Upright": limited-torque assist that aligns hull-up with the averaged
	    ground normal (world up when airborne) so vehicles follow slopes but rarely flip.
	Drive/grip/yaw only act while at least two suspension rays touch the ground.

		local rig = Physics.new(model, vehicleDef)   -- nil for static emplacements
		rig:Step(dt, throttle, steer, speedMult)     -- each PreSimulation by whoever simulates it
		rig:Release()                                -- zero every force (before anchoring / on exit)
]]

local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")

local Physics = {}
Physics.__index = Physics

Physics.RAY_GROUP = "VehicleRays" -- registered by VehicleService (does not collide with Players/Debris)

local REST_COMPRESSION = 0.9
local DAMPING_RATIO = 0.6
local GRIP_TRACKED = 150
local GRIP_WHEELED = 85
local CLIMB_G = 0.65 -- extra drive force as a fraction of gravity (slope climbing / hill hold)
local IS_SERVER = RunService:IsServer()

type Spring = { att: Attachment, force: VectorForce, last: number }

export type Rig = typeof(setmetatable(
	{} :: {
		model: Model,
		chassis: BasePart,
		def: any,
		springs: { Spring },
		drive: LinearVelocity,
		grip: LinearVelocity,
		yaw: Torque,
		upright: AlignOrientation,
		params: RaycastParams,
		rideHeight: number,
		inertiaYaw: number,
		lastNormal: Vector3,
		grounded: boolean,
		forwardSpeed: number,
	},
	Physics
))

function Physics.new(model: Model, def: any): Rig?
	local chassis = model.PrimaryPart
	if not chassis or def.static then
		return nil
	end
	local springs: { Spring } = {}
	local i = 1
	while true do
		local att = chassis:FindFirstChild("Susp" .. i)
		local vf = chassis:FindFirstChild("SuspForce" .. i)
		if not (att and att:IsA("Attachment") and vf and vf:IsA("VectorForce")) then
			break
		end
		table.insert(springs, { att = att, force = vf, last = 0 })
		i += 1
	end
	local drive = chassis:FindFirstChild("Drive")
	local grip = chassis:FindFirstChild("Grip")
	local yaw = chassis:FindFirstChild("YawTorque")
	local upright = chassis:FindFirstChild("Upright")
	if
		#springs < 3
		or not (drive and drive:IsA("LinearVelocity"))
		or not (grip and grip:IsA("LinearVelocity"))
		or not (yaw and yaw:IsA("Torque"))
		or not (upright and upright:IsA("AlignOrientation"))
	then
		return nil
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	params.IgnoreWater = true
	local okGroup, registered = pcall(PhysicsService.IsCollisionGroupRegistered, PhysicsService, Physics.RAY_GROUP)
	if okGroup and registered then
		params.CollisionGroup = Physics.RAY_GROUP
	end

	local s = chassis.Size
	-- The chassis is the only massive part; GetMass() is valid even while it is anchored (parked).
	local mass = chassis:GetMass()
	local self = setmetatable({
		model = model,
		chassis = chassis,
		def = def,
		springs = springs,
		drive = drive,
		grip = grip,
		yaw = yaw,
		upright = upright,
		params = params,
		rideHeight = (chassis:GetAttribute("RideHeight") :: number?) or 3,
		inertiaYaw = mass * (s.X * s.X + s.Z * s.Z) / 12,
		lastNormal = Vector3.yAxis,
		grounded = false,
		forwardSpeed = 0,
	}, Physics)
	upright.MaxTorque = mass * (s.Y * s.Y + s.Z * s.Z) / 12 * 30
	return self
end

-- Sets a VectorForce, skipping tiny changes on the server (property writes replicate there).
local function setForce(vf: VectorForce, value: Vector3, tolerance: number)
	if IS_SERVER then
		if (vf.Force - value).Magnitude > tolerance then
			vf.Force = value
		end
	else
		vf.Force = value
	end
end

-- throttle, steer in -1..1 (steer > 0 = turn right). speedMult scales top speed (critical damage).
function Physics.Step(self: Rig, dt: number, throttle: number, steer: number, speedMult: number?): (boolean, number)
	local chassis = self.chassis
	if chassis.Anchored or not chassis.Parent then
		return false, 0
	end
	local def = self.def
	local g = workspace.Gravity
	local mass = chassis.AssemblyMass
	local cf = chassis.CFrame
	local up = cf.UpVector
	local n = #self.springs
	local perMass = mass / n
	local k = perMass * g / REST_COMPRESSION
	local c = 2 * DAMPING_RATIO * math.sqrt(k * perMass)
	local maxLen = self.rideHeight + REST_COMPRESSION
	local castDir = -up * (maxLen + 0.8)
	local maxF = perMass * g * 4
	local tolerance = perMass * g * 0.03

	local contacts = 0
	local normalSum = Vector3.zero
	for _, s in self.springs do
		local origin = s.att.WorldPosition
		local hit = workspace:Raycast(origin, castDir, self.params)
		local f = 0
		if hit then
			contacts += 1
			normalSum += hit.Normal
			if hit.Distance < maxLen then
				local x = maxLen - hit.Distance
				local vUp = chassis:GetVelocityAtPosition(origin):Dot(up)
				f = math.clamp(k * x - c * vUp, 0, maxF)
			end
		end
		s.last = f
		setForce(s.force, up * f, tolerance)
	end

	local grounded = contacts >= 2
	self.grounded = grounded
	local normal = if contacts > 0 then normalSum.Unit else Vector3.yAxis
	if (normal - self.lastNormal).Magnitude > 0.02 then
		self.lastNormal = normal
		self.upright.PrimaryAxis = normal
	end

	local vel = chassis.AssemblyLinearVelocity
	local fwd = cf.LookVector
	local vF = vel:Dot(fwd)
	self.forwardSpeed = vF

	if not grounded then
		self.drive.MaxForce = 0
		self.grip.MaxForce = 0
		self.yaw.Torque = Vector3.zero
		return false, vF
	end

	-- Throttle: rate-limited target speed (the constraint has ample force; the ramp is the accel).
	local mult = speedMult or 1
	local desired = 0
	if throttle > 0 then
		desired = throttle * def.speed * mult
	elseif throttle < 0 then
		desired = throttle * def.reverseSpeed * mult
	end
	local accel = def.acceleration
	local rate
	if throttle == 0 then
		rate = accel * 1.6 -- engine braking
	elseif desired * vF < 0 and math.abs(vF) > 1 then
		rate = accel * 2.5 -- braking against motion
	else
		rate = accel
	end
	local target = vF + math.clamp(desired - vF, -rate * dt, rate * dt)
	local driveForce = mass * (accel * 3 + g * CLIMB_G)
	if self.drive.MaxForce ~= driveForce then
		self.drive.MaxForce = driveForce
	end
	if not IS_SERVER or math.abs(self.drive.LineVelocity - target) > 0.05 then
		self.drive.LineVelocity = target
	end
	local gripForce = mass * (if def.tracked then GRIP_TRACKED else GRIP_WHEELED)
	if self.grip.MaxForce ~= gripForce then
		self.grip.MaxForce = gripForce
	end

	-- Steering (positive steer = clockwise seen from above = negative yaw about +Y).
	local turn = math.rad(def.turnRate)
	local targetYaw
	if def.tracked then
		local speedFactor = 1 - 0.3 * math.clamp(math.abs(vF) / math.max(def.speed, 1), 0, 1)
		targetYaw = -steer * turn * speedFactor
	else
		local s = math.clamp(math.abs(vF) / math.max(def.speed * 0.3, 1), 0, 1)
		targetYaw = -steer * turn * s * (if vF < -0.5 then -1 else 1)
	end
	local currentYaw = chassis.AssemblyAngularVelocity:Dot(up)
	local maxAngAccel = turn * 5
	local angAccel = math.clamp((targetYaw - currentYaw) * 8, -maxAngAccel, maxAngAccel)
	local torque = up * (self.inertiaYaw * angAccel)
	if not IS_SERVER or (self.yaw.Torque - torque).Magnitude > self.inertiaYaw * 0.05 then
		self.yaw.Torque = torque
	end
	return true, vF
end

function Physics.Release(self: Rig)
	for _, s in self.springs do
		s.force.Force = Vector3.zero
		s.last = 0
	end
	self.drive.MaxForce = 0
	self.drive.LineVelocity = 0
	self.grip.MaxForce = 0
	self.yaw.Torque = Vector3.zero
end

-- Sum of current suspension forces relative to the vehicle weight (for HUD / debugging).
function Physics.Load(self: Rig): number
	local total = 0
	for _, s in self.springs do
		total += s.last
	end
	return total / math.max(self.chassis.AssemblyMass * workspace.Gravity, 1)
end

return Physics
