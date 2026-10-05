--[[
	VehicleController (client, Vehicle team).

	For EVERY streamed-in vehicle (CollectionService tag "Vehicle"):
	  * applies turret / gun / MG Motor6D Transforms from the replicated attributes TurretYaw,
	    GunPitch, MGYaw, MGPitch (smoothed), or from local prediction for the vehicle we crew;
	  * spins wheels / sprockets (WheelMotor) from the hull velocity (skid-steer aware) and steers
	    the front wheels of wheeled vehicles;
	  * shows the enter prompt only to the vehicle's own side;
	  * renders shots / impacts sent by the server through Vehicle_FX.

	While the local player is seated (player attribute VehicleUid ~= "" + Vehicle_State):
	  * driver: WASD / left stick drive through VehicleModels.Physics (we own the assembly);
	  * driver of a turreted vehicle / gunner: mouse (right stick) aims; the turret follows at
	    its traverse/elevation speed; aim sent to the server via Vehicle_Aim (unreliable, 20 Hz);
	  * third-person orbit camera; RMB / L2 = gunner sight (zoom + reticle overlay);
	  * MB1 / R2 fire primary (main gun), Space / R1 secondary (coax / MG), R / Y cycle ammo,
	    1/2 pick ammo, X / ButtonX switch seat, F / D-Pad down exit, LeftAlt free look;
	  * VehicleHUD ScreenGui (see HUD.luau), engine loop + screen shake, recoil impulse.
	Fires client Bus "VehicleEntered"(uid, vehicleId, seat) / "VehicleExited".
	WeaponController disables itself while VehicleUid is set.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Constants = require(Shared.Config.Constants)
local Keybinds = require(Shared.Config.Keybinds)
local Net = require(Shared.Util.Net)
local Trove = require(Shared.Util.Trove)
local VehicleModels = require(Shared.VehicleModels)
local Vehicles = require(Shared.Config.Vehicles)

local FX = require(script.FX)
local HUD = require(script.HUD)

local Physics = VehicleModels.Physics
local player = Players.LocalPlayer

local VehicleController = {}

---------------------------------------------------------------------------------------------------
-- Tunables
---------------------------------------------------------------------------------------------------

local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 100
local MOUSE_DEG_PER_PIXEL = 0.22
local GAMEPAD_CAM_SPEED = math.rad(200)
local STICK_DEADZONE = 0.15
local CAM_DISTANCE_MULT = 2.6 -- x hull half-length
local CAM_MIN_PITCH, CAM_MAX_PITCH = math.rad(-55), math.rad(40)
local SIGHT_FOV = 22
local MG_SIGHT_FOV = 45
local AIM_SEND_INTERVAL = 1 / 20
local AIM_RANGE = 2500
local REMOTE_SMOOTH = 12 -- smoothing rate for other vehicles' turrets
local ANIMATE_RANGE = 450 -- studs from camera
local MG_SLEW = math.rad(200)

---------------------------------------------------------------------------------------------------
-- Per-vehicle visual cache (all vehicles)
---------------------------------------------------------------------------------------------------

type WheelInfo = { motor: Motor6D, radius: number, x: number, steer: boolean, angle: number }
type VisualCache = {
	model: Model,
	chassis: BasePart?,
	turretMotor: Motor6D?,
	gunMotor: Motor6D?,
	mgMotor: Motor6D?,
	wheels: { WheelInfo },
	tracked: boolean,
	halfLength: number,
	yaw: number,
	pitch: number,
	mgYaw: number,
	mgPitch: number,
	prompt: ProximityPrompt?,
}

local caches: { [Model]: VisualCache } = {}

local function buildCache(model: Model): VisualCache
	local cache: VisualCache = {
		model = model,
		chassis = model.PrimaryPart,
		turretMotor = nil,
		gunMotor = nil,
		mgMotor = nil,
		wheels = {},
		tracked = false,
		halfLength = 8,
		yaw = (model:GetAttribute("TurretYaw") :: number?) or 0,
		pitch = (model:GetAttribute("GunPitch") :: number?) or 0,
		mgYaw = (model:GetAttribute("MGYaw") :: number?) or 0,
		mgPitch = (model:GetAttribute("MGPitch") :: number?) or 0,
		prompt = nil,
	}
	local chassis = cache.chassis
	if chassis then
		cache.tracked = chassis:GetAttribute("Tracked") == true
		cache.halfLength = (chassis:GetAttribute("HalfLength") :: number?) or 8
	end
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") then
			if d.Name == "TurretMotor" then
				cache.turretMotor = d
			elseif d.Name == "GunMotor" then
				cache.gunMotor = d
			elseif d.Name == "MGMotor" then
				cache.mgMotor = d
			elseif d.Name == "WheelMotor" and chassis then
				local p1 = d.Part1
				table.insert(cache.wheels, {
					motor = d,
					radius = (d:GetAttribute("Radius") :: number?) or 1,
					x = if p1 then d.C0.Position.X else 0,
					steer = d:GetAttribute("Steer") == true,
					angle = 0,
				})
			end
		elseif d:IsA("ProximityPrompt") and d.Name == "EnterPrompt" then
			cache.prompt = d
		end
	end
	return cache
end

local function getCache(model: Model): VisualCache?
	local c = caches[model]
	if c and c.chassis and c.chassis.Parent then
		return c
	end
	if not model.PrimaryPart then
		return nil
	end
	c = buildCache(model)
	caches[model] = c
	return c
end

---------------------------------------------------------------------------------------------------
-- Session (local crew state)
---------------------------------------------------------------------------------------------------

type WeaponState = {
	readyAt: number, -- server time
	mag: number,
	ammoIndex: number,
	heat: number,
	overheated: boolean,
	reloading: boolean,
	lastShot: number,
	reloadTotal: number,
}

type Session = {
	uid: string,
	model: Model,
	chassis: BasePart,
	def: any,
	seatId: string,
	seatDef: any,
	role: string,
	trove: any,
	rig: any?,
	controlsTurret: boolean,
	controlsMG: boolean,
	turretYaw: number,
	gunPitch: number,
	mgYaw: number,
	mgPitch: number,
	camYaw: number,
	camPitch: number,
	freeLook: boolean,
	zoom: boolean,
	primaryHeld: boolean,
	primaryPressed: boolean,
	secondaryHeld: boolean,
	throttle: number,
	steer: number,
	stick: Vector2,
	camStick: Vector2,
	triggerR: number,
	lastAimSend: number,
	sentYaw: number,
	sentPitch: number,
	aimPoint: Vector3,
	weapons: { [string]: WeaponState },
	engine: any?,
	shake: number,
	kick: number,
	baseFov: number,
}

local session: Session? = nil
local hud: HUD.HUD
local remotes: {
	Request: RemoteEvent,
	Fire: RemoteEvent,
	State: RemoteEvent,
	Weapon: RemoteEvent,
	Aim: UnreliableRemoteEvent,
	FX: UnreliableRemoteEvent,
	HitConfirm: RemoteEvent,
} =
	nil :: any
local menuOpen = false
local camRayParams = RaycastParams.new()
camRayParams.FilterType = Enum.RaycastFilterType.Exclude
local aimRayParams = RaycastParams.new()
aimRayParams.FilterType = Enum.RaycastFilterType.Exclude

local controllerCache: { [string]: any } = {}
local function getController(name: string): any
	local c = controllerCache[name]
	if c ~= nil then
		return c or nil
	end
	local mod = script.Parent:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, mod)
	controllerCache[name] = if ok then result else false
	return if ok then result else nil
end

local function callController(name: string, method: string, ...: any): any
	local c = getController(name)
	local fn = c and c[method]
	if type(fn) == "function" then
		local ok, result = pcall(fn, ...)
		if ok then
			return result
		end
	end
	return nil
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function wrapAngle(a: number): number
	return (a + math.pi) % (2 * math.pi) - math.pi
end

local function approachAngle(current: number, target: number, maxStep: number): number
	local d = wrapAngle(target - current)
	return wrapAngle(current + math.clamp(d, -maxStep, maxStep))
end

local function deadzone(v: Vector2): Vector2
	if v.Magnitude < STICK_DEADZONE then
		return Vector2.zero
	end
	return v
end

local function lastInputIsGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t.Name:sub(1, 7) == "Gamepad"
end

---------------------------------------------------------------------------------------------------
-- Weapons (client prediction; server is authoritative and corrects through Vehicle_Weapon)
---------------------------------------------------------------------------------------------------

local function seatWeapon(s: Session, index: number): string?
	local list = s.seatDef.weapons
	return list and list[index] or nil
end

local function weaponReady(s: Session, weaponId: string): boolean
	local w = s.weapons[weaponId]
	if not w then
		return false
	end
	return serverNow() >= w.readyAt and not w.overheated
end

local function boreCFrame(s: Session, weaponId: string): CFrame?
	if weaponId == "main" then
		return VehicleModels.MuzzleCFrame(s.model, s.turretYaw, s.gunPitch)
	elseif weaponId == "coax" then
		return VehicleModels.GunAttachmentCFrame(s.model, "Coax", s.turretYaw, s.gunPitch)
			or VehicleModels.MuzzleCFrame(s.model, s.turretYaw, s.gunPitch)
	else
		return VehicleModels.HullMGCFrame(s.model, s.mgYaw, s.mgPitch)
	end
end

local function addShake(s: Session, amount: number)
	s.shake = math.min(s.shake + amount, 2.5)
end

local function fireMain(s: Session)
	local gun = s.def.weapons.main
	local w = s.weapons.main
	if not gun or not w or not weaponReady(s, "main") then
		return
	end
	local bore = boreCFrame(s, "main")
	if not bore then
		return
	end
	local magazine = gun.magazine or 1
	if magazine > 1 then
		w.mag -= 1
		if w.mag <= 0 then
			w.mag = magazine
			w.readyAt = serverNow() + gun.reload
			w.reloadTotal = gun.reload
			w.reloading = true
		else
			w.readyAt = serverNow() + (gun.fireInterval or 0.25)
			w.reloadTotal = gun.fireInterval or 0.25
			w.reloading = false
		end
	else
		w.readyAt = serverNow() + gun.reload
		w.reloadTotal = gun.reload
		w.reloading = true
	end
	remotes.Fire:FireServer({ uid = s.uid, weapon = "main", aim = s.aimPoint })
	local shell = gun.ammo[w.ammoIndex] or gun.ammo[1]
	local dir = (s.aimPoint - bore.Position)
	local bdir = bore.LookVector
	if dir.Magnitude > 1 and math.acos(math.clamp(dir.Unit:Dot(bdir), -1, 1)) <= math.rad(3) then
		bdir = dir.Unit
	end
	FX.MainGunFired(bore.Position, bdir * shell.velocity, shell.gravityScale, gun.recoil, s.model)
	addShake(s, gun.shake)
	s.kick = math.min(s.kick + gun.shake * 0.04, 0.08)
	callController("CameraController", "Shake", gun.shake, 0.35)
	-- recoil impulse (only effective while we own the assembly)
	if s.role == "driver" and not s.chassis.Anchored and gun.recoil > 0 then
		s.chassis:ApplyImpulseAtPosition(-bdir * s.chassis.AssemblyMass * gun.recoil * 0.5, bore.Position)
	end
end

local mgRayParams = RaycastParams.new()
mgRayParams.FilterType = Enum.RaycastFilterType.Exclude

local function fireMG(s: Session, weaponId: string)
	local mgDef = s.def.weapons[weaponId]
	local w = s.weapons[weaponId]
	if not mgDef or not w then
		return
	end
	local now = serverNow()
	local interval = 60 / mgDef.rpm
	if now < w.readyAt or w.overheated or now - w.lastShot < interval then
		return
	end
	local bore = boreCFrame(s, weaponId)
	if not bore then
		return
	end
	w.heat = math.max(0, w.heat - mgDef.coolRate * (now - w.lastShot)) + mgDef.heatPerShot
	w.lastShot = now
	if w.heat >= 1 then
		w.heat = 1
		w.overheated = true
		w.readyAt = now + mgDef.overheatTime
		w.reloadTotal = mgDef.overheatTime
	end
	w.mag -= 1
	if w.mag <= 0 then
		w.mag = mgDef.magazine
		w.readyAt = now + mgDef.reload
		w.reloadTotal = mgDef.reload
		w.reloading = true
	end
	remotes.Fire:FireServer({ uid = s.uid, weapon = weaponId, aim = s.aimPoint })
	-- local tracer to where we aim (cosmetic; the server raycasts its own shot)
	local origin = bore.Position
	local dir = s.aimPoint - origin
	if dir.Magnitude < 1 then
		dir = bore.LookVector
	end
	mgRayParams.FilterDescendantsInstances = { s.model, player.Character :: Instance }
	local hit = Workspace:Raycast(origin, dir.Unit * mgDef.range, mgRayParams)
	local hitPos = if hit then hit.Position else origin + dir.Unit * mgDef.range
	FX.MGFired(
		origin,
		hitPos,
		if hit then hit.Normal else nil,
		if hit then hit.Material.Name else nil,
		mgDef.damage >= 25
	)
	addShake(s, 0.05)
end

local function cycleAmmo(s: Session, index: number?)
	local gun = s.def.weapons.main
	local w = s.weapons.main
	if not gun or not w or #gun.ammo < 2 then
		return
	end
	local nextIndex = index or (w.ammoIndex % #gun.ammo + 1)
	if nextIndex == w.ammoIndex or not gun.ammo[nextIndex] then
		return
	end
	w.ammoIndex = nextIndex
	w.mag = gun.magazine or 1
	w.readyAt = serverNow() + gun.reload
	w.reloadTotal = gun.reload
	w.reloading = true
	remotes.Request:FireServer({ action = "ammo", uid = s.uid, ammo = nextIndex })
end

---------------------------------------------------------------------------------------------------
-- Per-frame: turrets & wheels for every vehicle
---------------------------------------------------------------------------------------------------

local function animateVehicles(dt: number)
	local cam = Workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	local s = session
	local smooth = 1 - math.exp(-REMOTE_SMOOTH * dt)
	for _, model in CollectionService:GetTagged(Constants.TAGS.Vehicle) do
		if not model:IsA("Model") then
			continue
		end
		local c = getCache(model)
		local chassis = c and c.chassis
		if not c or not chassis then
			continue
		end
		local own = s ~= nil and s.model == model
		if not own and (chassis.Position - camPos).Magnitude > ANIMATE_RANGE then
			continue
		end
		-- turret / gun / MG
		if own and s and s.controlsTurret then
			c.yaw, c.pitch = s.turretYaw, s.gunPitch
		else
			local ty = (model:GetAttribute("TurretYaw") :: number?) or 0
			local tp = (model:GetAttribute("GunPitch") :: number?) or 0
			c.yaw = c.yaw + wrapAngle(ty - c.yaw) * smooth
			c.pitch = c.pitch + (tp - c.pitch) * smooth
		end
		if own and s and s.controlsMG then
			c.mgYaw, c.mgPitch = s.mgYaw, s.mgPitch
		else
			local my = (model:GetAttribute("MGYaw") :: number?) or 0
			local mp = (model:GetAttribute("MGPitch") :: number?) or 0
			c.mgYaw = c.mgYaw + wrapAngle(my - c.mgYaw) * smooth
			c.mgPitch = c.mgPitch + (mp - c.mgPitch) * smooth
		end
		if c.turretMotor and c.turretMotor.Parent then
			c.turretMotor.Transform = CFrame.Angles(0, c.yaw, 0)
		end
		if c.gunMotor then
			c.gunMotor.Transform = CFrame.Angles(c.pitch, 0, 0)
		end
		if c.mgMotor then
			c.mgMotor.Transform = CFrame.Angles(0, c.mgYaw, 0) * CFrame.Angles(c.mgPitch, 0, 0)
		end
		-- wheels / sprockets
		if #c.wheels > 0 and not chassis.Anchored then
			local cf = chassis.CFrame
			local vF = chassis.AssemblyLinearVelocity:Dot(cf.LookVector)
			local yawRate = chassis.AssemblyAngularVelocity:Dot(cf.UpVector)
			local steerAngle = 0
			if not c.tracked and math.abs(vF) > 1 then
				steerAngle = math.clamp(math.atan(yawRate * c.halfLength * 1.4 / vF), -0.55, 0.55)
			end
			for _, wh in c.wheels do
				local speed = if c.tracked then vF + yawRate * wh.x else vF
				wh.angle = (wh.angle - speed * dt / wh.radius) % (2 * math.pi)
				local spin = CFrame.Angles(wh.angle, 0, 0)
				wh.motor.Transform = if wh.steer then CFrame.Angles(0, steerAngle, 0) * spin else spin
			end
		end
	end
end

-- 2 Hz: enter prompts visible only for our side and while on foot.
local function refreshPrompts()
	local mySide = player:GetAttribute("Side")
	local onFoot = session == nil
	for _, model in CollectionService:GetTagged(Constants.TAGS.Vehicle) do
		if model:IsA("Model") then
			local c = getCache(model)
			local prompt = c and c.prompt
			if prompt then
				local allowed = onFoot
					and model:GetAttribute("Destroyed") ~= true
					and model:GetAttribute("Side") == mySide
				if prompt.Enabled ~= allowed then
					prompt.Enabled = allowed
				end
			end
		end
	end
	for model in caches do
		if not model.Parent then
			caches[model] = nil
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Session per-frame
---------------------------------------------------------------------------------------------------

local function readDriveInput(s: Session)
	if menuOpen then
		s.throttle, s.steer = 0, 0
		return
	end
	local throttle, steer = 0, 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then
		throttle += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then
		throttle -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
		steer += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
		steer -= 1
	end
	local stick = deadzone(s.stick)
	if stick.Magnitude > 0 then
		throttle = math.clamp(throttle + stick.Y, -1, 1)
		steer = math.clamp(steer + stick.X, -1, 1)
	end
	s.throttle, s.steer = throttle, steer
end

local function onPreSimulation(dt: number)
	animateVehicles(dt)
	local s = session
	if s and s.rig and s.role == "driver" and s.model.Parent then
		readDriveInput(s)
		local critical = s.model:GetAttribute("Critical") == true
		s.rig:Step(dt, s.throttle, s.steer, if critical then Vehicles.DAMAGE.CRITICAL_SPEED_MULT else 1)
	end
	FX.Step(dt)
end

local function cameraFocus(s: Session): Vector3
	local chassis = s.chassis
	local up = (chassis:GetAttribute("RideHeight") :: number?) or 3
	return chassis.Position + Vector3.new(0, up + 3.5, 0)
end

-- Desired yaw/pitch (hull-relative) for a pivot whose rest frame is chassis * motor.C0.
local function aimAngles(chassisCf: CFrame, motor: Motor6D, target: Vector3): (number, number)
	local pivot = chassisCf * motor.C0
	local d = pivot:PointToObjectSpace(target)
	local yaw = math.atan2(-d.X, -d.Z)
	local flat = math.sqrt(d.X * d.X + d.Z * d.Z)
	local pitch = math.atan2(d.Y, flat)
	return yaw, pitch
end

local function updateAim(s: Session, dt: number)
	local def = s.def
	local chassisCf = s.chassis.CFrame
	if s.freeLook then
		return
	end
	if s.controlsTurret then
		local turret = s.model:FindFirstChild("Turret")
		local motor = turret and turret:FindFirstChild("TurretMotor")
		if motor and motor:IsA("Motor6D") then
			local yaw, pitch = aimAngles(chassisCf, motor, s.aimPoint)
			if def.turretYawLimit then
				local lim = math.rad(def.turretYawLimit)
				yaw = math.clamp(yaw, -lim, lim)
			end
			s.turretYaw = approachAngle(s.turretYaw, yaw, math.rad(def.turretTraverse) * dt)
			if def.turretYawLimit then
				local lim = math.rad(def.turretYawLimit)
				s.turretYaw = math.clamp(s.turretYaw, -lim, lim)
			end
			-- pitch is measured from the gun trunnion for accuracy
			local gun = s.model:FindFirstChild("Gun")
			local gm = gun and gun:FindFirstChild("GunMotor")
			if gm and gm:IsA("Motor6D") then
				local turretCf = VehicleModels.JointCFrame(motor, chassisCf, s.turretYaw, 0)
				local trunnion = turretCf * gm.C0
				local d = trunnion:PointToObjectSpace(s.aimPoint)
				pitch = math.atan2(d.Y, math.sqrt(d.X * d.X + d.Z * d.Z))
			end
			pitch = math.clamp(pitch, math.rad(def.gunElevation.min), math.rad(def.gunElevation.max))
			local maxP = math.rad(def.elevationSpeed) * dt
			s.gunPitch += math.clamp(pitch - s.gunPitch, -maxP, maxP)
		end
	elseif s.controlsMG then
		local mount = s.model:FindFirstChild("MGMount")
		local motor = mount and mount:FindFirstChild("MGMotor")
		local mg = def.weapons.hullMG
		if motor and motor:IsA("Motor6D") and mg then
			local yaw, pitch = aimAngles(chassisCf, motor, s.aimPoint)
			local lim = math.rad(mg.yawLimit or 30)
			yaw = math.clamp(yaw, -lim, lim)
			pitch = math.clamp(pitch, math.rad(mg.pitchMin or -10), math.rad(mg.pitchMax or 20))
			s.mgYaw = approachAngle(s.mgYaw, yaw, MG_SLEW * dt)
			s.mgPitch += math.clamp(pitch - s.mgPitch, -MG_SLEW * dt, MG_SLEW * dt)
		end
	end
	-- replicate (unreliable, rate limited, only when changed)
	local t = os.clock()
	if (s.controlsTurret or s.controlsMG) and t - s.lastAimSend >= AIM_SEND_INTERVAL then
		local yaw = if s.controlsTurret then s.turretYaw else s.mgYaw
		local pitch = if s.controlsTurret then s.gunPitch else s.mgPitch
		if math.abs(yaw - s.sentYaw) > 0.001 or math.abs(pitch - s.sentPitch) > 0.001 then
			s.lastAimSend = t
			s.sentYaw, s.sentPitch = yaw, pitch
			remotes.Aim:FireServer({ uid = s.uid, yaw = yaw, pitch = pitch })
		end
	end
end

local function updateHud(s: Session)
	local def = s.def
	local model = s.model
	hud:SetHealth(
		(model:GetAttribute("Health") :: number?) or 0,
		(model:GetAttribute("MaxHealth") :: number?) or def.maxHealth,
		model:GetAttribute("Critical") == true
	)
	hud:SetSpeed(s.chassis.AssemblyLinearVelocity:Dot(s.chassis.CFrame.LookVector))
	local now = serverNow()
	local primary = seatWeapon(s, 1)
	local gun = def.weapons.main
	local wMain = s.weapons.main
	if primary == "main" and gun and wMain then
		local names = {}
		for _, a in gun.ammo do
			table.insert(names, a.name)
		end
		local magazine = gun.magazine or 1
		hud:SetAmmo(names, wMain.ammoIndex, if magazine > 1 then `{wMain.mag}/{magazine}` else nil)
		local remaining = wMain.readyAt - now
		if remaining > 0 then
			hud:SetReload(1 - remaining / math.max(wMain.reloadTotal, 0.01), string.format("%.1fs", remaining))
		else
			hud:SetReload(1, "READY")
		end
	elseif primary then
		local w = s.weapons[primary]
		local mgDef = def.weapons[primary]
		if w and mgDef then
			hud:SetAmmo({ mgDef.name }, 1, `{w.mag}/{mgDef.magazine}`)
			local remaining = w.readyAt - now
			hud:SetReload(
				if remaining > 0 then 1 - remaining / math.max(w.reloadTotal, 0.01) else 1,
				if remaining > 0 then (if w.overheated then "OVERHEAT" else "RELOAD") else "READY"
			)
		end
	end
	-- heat of the MG (secondary, or primary for gunners)
	local mgId = if primary == "main" then seatWeapon(s, 2) else primary
	local w = mgId and s.weapons[mgId]
	local mgDef = mgId and def.weapons[mgId]
	if w and mgDef then
		if w.overheated and now >= w.readyAt then
			w.overheated = false
			w.heat = 0
		end
		local heat = math.max(0, w.heat - mgDef.coolRate * (now - w.lastShot))
		hud:SetHeat(heat, w.overheated)
	end

	-- gun marker: where the primary weapon actually points
	local cam = Workspace.CurrentCamera
	if primary and cam then
		local bore = boreCFrame(s, primary)
		if bore then
			aimRayParams.FilterDescendantsInstances = { s.model, player.Character :: Instance }
			local hit = Workspace:Raycast(bore.Position, bore.LookVector * 1500, aimRayParams)
			local p = if hit then hit.Position else bore.Position + bore.LookVector * 1500
			local screen, onScreen = cam:WorldToViewportPoint(p)
			if onScreen then
				local center = cam.ViewportSize / 2
				local aligned = (Vector2.new(screen.X, screen.Y) - center).Magnitude < 12
				hud:SetGunMarker(Vector2.new(screen.X, screen.Y), weaponReady(s, primary), aligned)
			else
				hud:SetGunMarker(nil, false, false)
			end
		end
	else
		hud:SetGunMarker(nil, false, false)
	end
end

local function onRenderStep(dt: number)
	local s = session
	local cam = Workspace.CurrentCamera
	if not s or not cam then
		return
	end
	if not s.model.Parent or not s.chassis.Parent then
		return
	end
	-- input: camera rotation
	if not menuOpen then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
		local delta = UserInputService:GetMouseDelta()
		local sens = MOUSE_DEG_PER_PIXEL * (if s.zoom then 0.35 else 1)
		s.camYaw -= math.rad(delta.X * sens)
		s.camPitch -= math.rad(delta.Y * sens)
		local stick = deadzone(s.camStick)
		if stick.Magnitude > 0 then
			local rate = GAMEPAD_CAM_SPEED * (if s.zoom then 0.35 else 1) * dt
			s.camYaw -= stick.X * rate
			s.camPitch += stick.Y * rate
		end
		s.camPitch = math.clamp(s.camPitch, CAM_MIN_PITCH, CAM_MAX_PITCH)
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end

	-- camera placement
	s.shake = math.max(0, s.shake - dt * 3)
	s.kick = math.max(0, s.kick - dt * 0.5)
	local look = CFrame.fromOrientation(s.camPitch + s.kick, s.camYaw, 0)
	local shakeCf = CFrame.identity
	if s.shake > 0 then
		local m = s.shake * 0.02
		shakeCf = CFrame.Angles(math.random() * m - m / 2, math.random() * m - m / 2, math.random() * m * 0.5)
	end
	local camCf: CFrame
	local fov = s.baseFov
	camRayParams.FilterDescendantsInstances = { s.model, player.Character :: Instance }
	if s.zoom and s.controlsTurret then
		local gun = s.model:FindFirstChild("Gun")
		local base = if gun and gun:IsA("BasePart") then gun.Position else cameraFocus(s)
		camCf = CFrame.new(base + s.chassis.CFrame.UpVector * 1.1) * look
		fov = SIGHT_FOV
	else
		local focus = cameraFocus(s)
		local dist = math.max(((s.chassis:GetAttribute("HalfLength") :: number?) or 8) * CAM_DISTANCE_MULT, 14)
		local desired = focus - look.LookVector * dist
		local hit = Workspace:Raycast(focus, desired - focus, camRayParams)
		local pos = if hit then hit.Position + hit.Normal * 0.6 else desired
		camCf = CFrame.new(pos) * look
		if s.zoom then
			fov = MG_SIGHT_FOV
		end
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = camCf * shakeCf
	cam.FieldOfView = cam.FieldOfView + (fov - cam.FieldOfView) * math.min(1, dt * 14)
	hud:SetSight(s.zoom and s.controlsTurret)

	-- aim point: what the screen centre looks at
	aimRayParams.FilterDescendantsInstances = { s.model, player.Character :: Instance }
	local aimHit = Workspace:Raycast(camCf.Position, camCf.LookVector * AIM_RANGE, aimRayParams)
	if not s.freeLook then
		s.aimPoint = if aimHit then aimHit.Position else camCf.Position + camCf.LookVector * AIM_RANGE
	end
	updateAim(s, dt)

	-- firing
	if not menuOpen then
		local primary = seatWeapon(s, 1)
		local secondary = seatWeapon(s, 2)
		local primaryHeld = s.primaryHeld or s.triggerR > 0.5
		if primary == "main" then
			local gun = s.def.weapons.main
			local auto = gun and (gun.magazine or 1) > 1
			if s.primaryPressed or (auto and primaryHeld) then
				fireMain(s)
			end
		elseif primary and primaryHeld then
			fireMG(s, primary)
		end
		if secondary and s.secondaryHeld then
			if secondary == "main" then
				fireMain(s)
			else
				fireMG(s, secondary)
			end
		end
	end
	s.primaryPressed = false

	-- engine sound pitch
	if s.engine then
		local speed = math.abs(s.chassis.AssemblyLinearVelocity.Magnitude)
		local load = math.clamp(speed / math.max(s.def.speed, 1), 0, 1)
		pcall(function()
			s.engine:SetPitch(0.85 + load * 0.5 + math.abs(s.throttle) * 0.1)
		end)
	end
	updateHud(s)
end

---------------------------------------------------------------------------------------------------
-- Input
---------------------------------------------------------------------------------------------------

local ACTIONS = {
	Fire = "VehicleFire",
	Alt = "VehicleAltFire",
	Zoom = "VehicleZoom",
	Exit = "VehicleExit",
	Switch = "VehicleSwitchSeat",
	Ammo = "VehicleAmmo",
	Ammo1 = "VehicleAmmo1",
	Ammo2 = "VehicleAmmo2",
	FreeLook = "VehicleFreeLook",
}

local function handleAction(name: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local s = session
	if not s then
		return Enum.ContextActionResult.Pass
	end
	if menuOpen then
		return Enum.ContextActionResult.Pass
	end
	local began = state == Enum.UserInputState.Begin
	local ended = state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel
	if name == ACTIONS.Fire then
		if began then
			s.primaryHeld = true
			s.primaryPressed = true
		elseif ended then
			s.primaryHeld = false
		end
	elseif name == ACTIONS.Alt then
		if began then
			s.secondaryHeld = true
		elseif ended then
			s.secondaryHeld = false
		end
	elseif name == ACTIONS.Zoom then
		if began then
			s.zoom = true
		elseif ended then
			s.zoom = false
		end
	elseif name == ACTIONS.FreeLook then
		if began then
			s.freeLook = true
		elseif ended then
			s.freeLook = false
		end
	elseif began then
		if name == ACTIONS.Exit then
			remotes.Request:FireServer({ action = "exit", uid = s.uid })
		elseif name == ACTIONS.Switch then
			remotes.Request:FireServer({ action = "switchSeat", uid = s.uid })
		elseif name == ACTIONS.Ammo then
			cycleAmmo(s, nil)
		elseif name == ACTIONS.Ammo1 then
			cycleAmmo(s, 1)
		elseif name == ACTIONS.Ammo2 then
			cycleAmmo(s, 2)
		end
	end
	return Enum.ContextActionResult.Sink
end

local function bindActions(trove: any)
	local kb = Keybinds.keyboard
	local gp = Keybinds.gamepad
	local function bind(name: string, ...: any)
		ContextActionService:BindActionAtPriority(name, handleAction, false, ACTION_PRIORITY, ...)
		trove:Add(function()
			ContextActionService:UnbindAction(name)
		end)
	end
	bind(ACTIONS.Fire, kb.VehicleFire or Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)
	bind(ACTIONS.Alt, kb.VehicleAltFire or Enum.KeyCode.Space, Enum.KeyCode.ButtonR1)
	bind(ACTIONS.Zoom, kb.VehicleZoom or Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2)
	bind(ACTIONS.Exit, kb.VehicleExit or Enum.KeyCode.F, gp.VehicleExit or Enum.KeyCode.DPadDown)
	bind(ACTIONS.Switch, kb.VehicleSwitchSeat or Enum.KeyCode.X, Enum.KeyCode.ButtonX)
	bind(ACTIONS.Ammo, Enum.KeyCode.R, Enum.KeyCode.ButtonY)
	bind(ACTIONS.Ammo1, Enum.KeyCode.One)
	bind(ACTIONS.Ammo2, Enum.KeyCode.Two)
	bind(ACTIONS.FreeLook, kb.VehicleFreeLook or Enum.KeyCode.LeftAlt, Enum.KeyCode.ButtonL3)
end

---------------------------------------------------------------------------------------------------
-- Session lifecycle
---------------------------------------------------------------------------------------------------

local function findVehicle(uid: string, timeout: number): Model?
	local deadline = os.clock() + timeout
	repeat
		for _, model in CollectionService:GetTagged(Constants.TAGS.Vehicle) do
			if model:IsA("Model") and model:GetAttribute("Uid") == uid and model.PrimaryPart then
				return model
			end
		end
		task.wait(0.1)
	until os.clock() > deadline
	return nil
end

local function endSession()
	local s = session
	if not s then
		return
	end
	session = nil
	if s.rig and s.role == "driver" then
		pcall(function()
			s.rig:Release()
		end)
	end
	if s.engine then
		pcall(function()
			s.engine:Stop()
		end)
	end
	s.trove:Clean()
	hud:Hide()
	local cam = Workspace.CurrentCamera
	if cam then
		cam.FieldOfView = s.baseFov
		cam.CameraType = Enum.CameraType.Custom
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			cam.CameraSubject = hum
			pcall(function()
				hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			end)
		end
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
	callController("CameraController", "SetFirstPerson", true)
	Bus.fire("VehicleExited")
	refreshPrompts()
end

local function startSession(uid: string, seatId: string)
	if session and session.uid == uid and session.seatId == seatId then
		return
	end
	local switching = session ~= nil and session.uid == uid
	local prevCam = session and { yaw = session.camYaw, pitch = session.camPitch }
	if session then
		endSession()
	end
	local model = findVehicle(uid, 5)
	if not model or player:GetAttribute("VehicleUid") ~= uid then
		return
	end
	local def = Vehicles.get(model:GetAttribute("VehicleId") :: string)
	local seatDef = def and Vehicles.getSeat(def, seatId)
	local chassis = model.PrimaryPart
	if not def or not seatDef or not chassis then
		return
	end
	local cam = Workspace.CurrentCamera
	local settingsFov = callController("SettingsController", "Get", "FieldOfView")
	local baseFov = if type(settingsFov) == "number" then settingsFov else (if cam then cam.FieldOfView else 70)
	local weapons = seatDef.weapons or {}
	local look = chassis.CFrame.LookVector
	local s: Session = {
		uid = uid,
		model = model,
		chassis = chassis,
		def = def,
		seatId = seatId,
		seatDef = seatDef,
		role = seatDef.role,
		trove = Trove.new(),
		rig = nil,
		controlsTurret = seatDef.role == "driver" and def.turretTraverse > 0 and model:FindFirstChild("Turret") ~= nil,
		controlsMG = table.find(weapons, "hullMG") ~= nil and model:FindFirstChild("MGMount") ~= nil,
		turretYaw = (model:GetAttribute("TurretYaw") :: number?) or 0,
		gunPitch = (model:GetAttribute("GunPitch") :: number?) or 0,
		mgYaw = (model:GetAttribute("MGYaw") :: number?) or 0,
		mgPitch = (model:GetAttribute("MGPitch") :: number?) or 0,
		camYaw = if prevCam then prevCam.yaw else math.atan2(-look.X, -look.Z),
		camPitch = if prevCam then prevCam.pitch else math.rad(-10),
		freeLook = false,
		zoom = false,
		primaryHeld = false,
		primaryPressed = false,
		secondaryHeld = false,
		throttle = 0,
		steer = 0,
		stick = Vector2.zero,
		camStick = Vector2.zero,
		triggerR = 0,
		lastAimSend = 0,
		sentYaw = 1e9,
		sentPitch = 1e9,
		aimPoint = chassis.Position + look * 100,
		weapons = {},
		engine = nil,
		shake = 0,
		kick = 0,
		baseFov = baseFov,
	}
	for _, w in weapons do
		local entry: WeaponState = {
			readyAt = 0,
			mag = 1,
			ammoIndex = 1,
			heat = 0,
			overheated = false,
			reloading = false,
			lastShot = 0,
			reloadTotal = 1,
		}
		if w == "main" and def.weapons.main then
			entry.mag = def.weapons.main.magazine or 1
		elseif def.weapons[w] then
			entry.mag = def.weapons[w].magazine
		end
		s.weapons[w] = entry
	end
	if s.role == "driver" and not def.static then
		s.rig = Physics.new(model, def)
	end
	session = s

	-- humanoid: no jumping out of the seat with Space
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(function()
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		end)
	end
	callController("CameraController", "SetFirstPerson", false)
	bindActions(s.trove)

	-- gamepad sticks / triggers
	s.trove:Connect(UserInputService.InputChanged, function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			s.stick = Vector2.new(input.Position.X, input.Position.Y)
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			s.camStick = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)
	s.trove:Connect(UserInputService.InputEnded, function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			s.stick = Vector2.zero
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			s.camStick = Vector2.zero
		end
	end)
	s.trove:Connect(model.AncestryChanged, function()
		if not model:IsDescendantOf(Workspace) and session == s then
			endSession()
		end
	end)

	-- engine loop (SoundController handles fallbacks / missing ids)
	if s.role == "driver" and not def.static then
		local key = if def.tracked and def.class ~= "Transport" then "Tank_Engine" else "Jeep_Engine"
		s.engine = callController("SoundController", "PlayLoop", key, chassis, { volume = 0.9 })
	end

	hud:Show(def, seatId, seatDef, lastInputIsGamepad())
	if not switching then
		callController("SoundController", "PlayAt", "UI_Click", chassis.Position, { volume = 0.4 })
	end
	Bus.fire("VehicleEntered", uid, def.id, seatId)
	refreshPrompts()
end

---------------------------------------------------------------------------------------------------
-- Remote handlers
---------------------------------------------------------------------------------------------------

local function onState(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if payload.inVehicle and type(payload.uid) == "string" and type(payload.seat) == "string" then
		task.spawn(startSession, payload.uid, payload.seat)
	else
		endSession()
	end
end

local function onWeapon(payload: any)
	local s = session
	if type(payload) ~= "table" or not s or payload.uid ~= s.uid then
		return
	end
	local w = s.weapons[payload.weapon]
	if not w then
		return
	end
	if type(payload.readyAt) == "number" then
		local remaining = payload.readyAt - serverNow()
		if remaining > 0.05 then
			w.reloadTotal = math.max(remaining, 0.1)
		end
		w.readyAt = payload.readyAt
	end
	if type(payload.mag) == "number" then
		w.mag = payload.mag
	end
	if type(payload.ammoIndex) == "number" then
		w.ammoIndex = payload.ammoIndex
	end
	if type(payload.heat) == "number" then
		w.heat = payload.heat
		w.lastShot = serverNow()
	end
	if payload.overheated ~= nil then
		w.overheated = payload.overheated == true
	end
	w.reloading = payload.reloading == true
end

local function modelByUid(uid: any): Model?
	if type(uid) ~= "string" then
		return nil
	end
	for model, c in caches do
		if c.model:GetAttribute("Uid") == uid then
			return model
		end
	end
	return nil
end

local function onFX(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local kind = payload.kind
	local s = session
	local mine = s ~= nil and payload.uid == s.uid
	if kind == "fire" then
		if payload.shooter == player then
			return -- already predicted
		end
		if typeof(payload.origin) == "Vector3" and typeof(payload.velocity) == "Vector3" then
			FX.MainGunFired(
				payload.origin,
				payload.velocity,
				tonumber(payload.gravity) or 0.2,
				tonumber(payload.caliber) or 3,
				modelByUid(payload.uid)
			)
			if mine and s then
				addShake(s, 0.6)
			end
		end
	elseif kind == "mg" then
		if payload.shooter == player then
			return
		end
		if typeof(payload.origin) == "Vector3" and typeof(payload.hit) == "Vector3" then
			FX.MGFired(payload.origin, payload.hit, payload.normal, payload.material, false)
		end
	elseif kind == "impact" then
		if typeof(payload.pos) == "Vector3" and typeof(payload.normal) == "Vector3" then
			FX.ArmorImpact(payload.pos, payload.normal, tostring(payload.result))
		end
		if mine and s then
			local result = payload.result
			addShake(s, if result == "penetration" then 1.4 else 0.6)
			callController("CameraController", "Shake", if result == "penetration" then 1.2 else 0.5, 0.4)
		end
	elseif kind == "hit" then
		if mine and s then
			local amount = tonumber(payload.amount) or 0
			addShake(s, math.clamp(amount / 400, 0.15, 1.2))
			hud:Flash(math.clamp(amount / 1200, 0.08, 0.4))
		end
	end
end

local RESULT_TEXT = {
	penetration = { "PENETRATION", HUD.COLORS.GREEN },
	nonpen = { "NON-PENETRATION", HUD.COLORS.AMBER },
	ricochet = { "RICOCHET", HUD.COLORS.RED },
}

local function onHitConfirm(payload: any)
	if type(payload) ~= "table" or not session then
		return
	end
	local r = RESULT_TEXT[payload.result]
	if r then
		local text = r[1]
		if payload.killed then
			text = "TARGET DESTROYED"
		end
		hud:ShowResult(text, if payload.killed then HUD.COLORS.GREEN else r[2])
	elseif payload.killed and payload.target == "vehicle" then
		hud:ShowResult("TARGET DESTROYED", HUD.COLORS.GREEN)
	end
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

function VehicleController:Init()
	remotes = {
		Request = Net.event("Vehicle_Request"),
		Fire = Net.event("Vehicle_Fire"),
		State = Net.event("Vehicle_State"),
		Weapon = Net.event("Vehicle_Weapon"),
		Aim = Net.unreliable("Vehicle_Aim"),
		FX = Net.unreliable("Vehicle_FX"),
		HitConfirm = Net.event("Combat_HitConfirm"),
	}
	hud = HUD.new(player:WaitForChild("PlayerGui"))
	FX.Init(getController)
end

function VehicleController:Start()
	remotes.State.OnClientEvent:Connect(onState)
	remotes.Weapon.OnClientEvent:Connect(onWeapon)
	remotes.FX.OnClientEvent:Connect(onFX)
	remotes.HitConfirm.OnClientEvent:Connect(onHitConfirm)

	player:GetAttributeChangedSignal("VehicleUid"):Connect(function()
		local uid = player:GetAttribute("VehicleUid")
		if (uid == nil or uid == "") and session then
			endSession()
		end
	end)
	player:GetAttributeChangedSignal("Side"):Connect(refreshPrompts)
	player.CharacterRemoving:Connect(function()
		endSession()
	end)
	Bus.connect("MenuOpened", function()
		menuOpen = true
		local s = session
		if s then
			s.primaryHeld, s.secondaryHeld, s.zoom = false, false, false
		end
	end)
	Bus.connect("MenuClosed", function()
		menuOpen = false
	end)
	CollectionService:GetInstanceAddedSignal(Constants.TAGS.Vehicle):Connect(function(inst)
		if inst:IsA("Model") then
			caches[inst] = nil
			task.defer(refreshPrompts)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(Constants.TAGS.Vehicle):Connect(function(inst)
		if inst:IsA("Model") then
			caches[inst] = nil
		end
	end)

	RunService.PreSimulation:Connect(onPreSimulation)
	RunService:BindToRenderStep("VehicleCamera", Enum.RenderPriority.Camera.Value + 10, onRenderStep)

	task.spawn(function()
		while true do
			task.wait(0.5)
			pcall(refreshPrompts)
		end
	end)

	-- Already seated (controller reloaded / late start)?
	local uid = player:GetAttribute("VehicleUid")
	if type(uid) == "string" and uid ~= "" then
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		local seatId = seat and seat:GetAttribute("SeatId")
		if type(seatId) == "string" then
			task.spawn(startSession, uid, seatId)
		end
	end
end

return VehicleController
