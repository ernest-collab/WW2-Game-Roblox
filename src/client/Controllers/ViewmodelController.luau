--[[
	ViewmodelController (Animation/Models team, client)

	First-person arms + weapon. Everything is procedural:
	  * Arms are 8 anchored Parts (sleeves in the player's faction tunic colour, skin-coloured
	    hands) solved every frame with two-bone IK onto the weapon's "Grip" (right hand) and
	    "Support" (left hand) attachments. Shoulders are virtual and slide toward the target when it
	    is out of reach, so long rifles never leave a gap between hand and forend.
	  * The weapon is a WeaponModels clone with an anchored Handle; animated sub-parts (Mag, Bolt,
	    Slide, Pump, Lid) are moved by editing their Weld.C0.
	  * Pose = camera * (hip <-> ADS lerp, sprint pose, stance offsets, equip raise) * springs
	    (recoil, sway, strafe tilt, landing) * bob/breathing * active animation.
	  * ADS aligns the "Sight" attachment to the camera centre with the model's EyeRelief, over the
	    weapon's adsTime (eased); FOV zoom is pushed to CameraController as offset key "ADS".
	  * Animations: equip raise / unequip lower, fire kick (+ slide/bolt cycling for autos),
	    reload by reloadType (magazine | clip | single, bolt work for bolt rifles, pump for
	    shotguns, charge when empty), PlayBolt, PlayThrow, PlayMelee (knife slash / rifle bash),
	    PlayInspect, idle breathing.
	  * Hidden when dead, in a vehicle, in menus or when the camera is not in first person.

	Rendered at RenderPriority.Camera + 2 (after CameraController's Camera + 1 post pass so
	recoil/shake are already in the camera CFrame).

	Bus fallbacks: if WeaponController only fires its Bus events (WeaponEquipped, WeaponUnequipped,
	AimChanged, Fired, ReloadStarted) without calling this API, the matching API is invoked
	automatically; when it calls the API directly the Bus event is ignored (deduplicated).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Factions = require(Shared.Config.Factions)
local Constants = require(Shared.Config.Constants)
local WeaponModels = require(Shared.WeaponModels)
local Spring = require(Shared.WeaponModels.Spring)

local ViewmodelController = {}

local player = Players.LocalPlayer

local CF = CFrame.new
local ANG = CFrame.Angles
local IDENTITY = CFrame.identity
local V3 = Vector3.new

local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2
local VIEWMODEL_GROUP = Constants.COLLISION_GROUPS.Viewmodel

-- Optional uploaded animation ids (unused while empty; procedural animation is the default).
ViewmodelController.AnimationIds = {} :: { [string]: string }

--------------------------------------------------------------------------------------------------
-- Hold profiles (handle CFrame relative to the camera)
--------------------------------------------------------------------------------------------------

type Profile = {
	hip: CFrame,
	sprint: CFrame,
	lowered: CFrame,
	crouch: CFrame,
	prone: CFrame,
	canAim: boolean,
	oneHanded: boolean,
	bob: number,
}

local PROFILES: { [string]: Profile } = {
	Rifle = {
		hip = CF(0.46, -0.58, -1.0),
		sprint = CF(0.22, -0.62, -0.8) * ANG(-0.55, 0.85, 0.5),
		lowered = CF(0.35, -2.0, -0.3) * ANG(-1.2, 0.4, 0.3),
		crouch = CF(-0.03, 0.03, 0.02) * ANG(0, 0, 0.05),
		prone = CF(0.04, 0.08, 0.1) * ANG(0.02, 0, -0.1),
		canAim = true,
		oneHanded = false,
		bob = 1,
	},
	MG = {
		hip = CF(0.48, -0.68, -0.95),
		sprint = CF(0.25, -0.75, -0.7) * ANG(-0.6, 0.8, 0.45),
		lowered = CF(0.35, -2.1, -0.3) * ANG(-1.1, 0.4, 0.3),
		crouch = CF(-0.03, 0.03, 0.02) * ANG(0, 0, 0.05),
		prone = CF(0.04, 0.1, 0.1) * ANG(0.02, 0, -0.08),
		canAim = true,
		oneHanded = false,
		bob = 1.25,
	},
	Pistol = {
		hip = CF(0.36, -0.62, -1.45),
		sprint = CF(0.25, -0.95, -1.0) * ANG(-1.0, 0.3, 0.1),
		lowered = CF(0.3, -1.9, -0.8) * ANG(-1.3, 0.2, 0),
		crouch = CF(-0.02, 0.02, 0) * ANG(0, 0, 0.06),
		prone = CF(0, 0.06, 0.1) * ANG(0, 0, -0.08),
		canAim = true,
		oneHanded = false,
		bob = 0.9,
	},
	Launcher = {
		hip = CF(0.55, -0.9, -0.5),
		sprint = CF(0.5, -1.15, -0.2) * ANG(-0.5, 0.5, 0.35),
		lowered = CF(0.4, -2.3, 0.2) * ANG(-0.9, 0.3, 0.2),
		crouch = CF(-0.03, 0.03, 0),
		prone = CF(0, 0.08, 0.1),
		canAim = true,
		oneHanded = false,
		bob = 1.3,
	},
	Throwable = {
		hip = CF(0.55, -0.78, -1.3) * ANG(0.1, 0, -0.15),
		sprint = CF(0.5, -1.05, -1.0) * ANG(-0.4, 0.2, 0),
		lowered = CF(0.5, -2.0, -0.8) * ANG(-0.8, 0, 0),
		crouch = IDENTITY,
		prone = CF(0, 0.05, 0),
		canAim = false,
		oneHanded = false,
		bob = 1,
	},
	Melee = {
		hip = CF(0.6, -0.72, -1.25) * ANG(0.35, 0.35, -0.5),
		sprint = CF(0.5, -0.95, -1.0) * ANG(-0.3, 0.3, -0.2),
		lowered = CF(0.5, -2.0, -0.8) * ANG(-0.9, 0.2, 0),
		crouch = IDENTITY,
		prone = CF(0, 0.05, 0),
		canAim = false,
		oneHanded = true,
		bob = 1,
	},
	Gadget = {
		hip = CF(0.05, -1.05, -1.5),
		sprint = CF(0.05, -1.25, -1.2) * ANG(-0.25, 0, 0),
		lowered = CF(0.05, -2.3, -1.0) * ANG(-0.6, 0, 0),
		crouch = IDENTITY,
		prone = CF(0, 0.1, 0),
		canAim = false,
		oneHanded = false,
		bob = 1,
	},
	Binoculars = {
		hip = CF(0.25, -0.95, -1.15) * ANG(-0.6, 0.3, 0),
		sprint = CF(0.25, -1.15, -0.9) * ANG(-0.9, 0.3, 0),
		lowered = CF(0.25, -2.0, -0.8) * ANG(-1.0, 0, 0),
		crouch = IDENTITY,
		prone = CF(0, 0.05, 0),
		canAim = true,
		oneHanded = false,
		bob = 1,
	},
}

-- Arm rig (camera space)
local R_SHOULDER = V3(0.78, -1.5, 0.35)
local L_SHOULDER = V3(-0.78, -1.5, 0.35)
local R_POLE = V3(1.9, -2.6, 0.4)
local L_POLE = V3(-1.9, -2.7, 0.0)
local UPPER_LEN = 1.25
local LOWER_LEN = 1.15
local HAND_LEN = 0.16 -- wrist -> palm centre
local LEFT_REST = CF(-0.65, -2.1, -0.6) -- one-handed holds: left hand out of view

--------------------------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------------------------

type AnimState = {
	kind: string,
	t0: number,
	duration: number,
	empty: boolean,
	count: number,
}

type Weapon = {
	id: string,
	model: Model,
	handle: BasePart,
	profile: Profile,
	hold: string,
	action: string,
	archetype: string,
	reloadType: string,
	adsTime: number,
	adsZoom: number,
	eyeRelief: number,
	grip: CFrame,
	support: CFrame,
	sight: CFrame,
	muzzle: Attachment?,
	adsCF: CFrame,
	magWeld: Weld?,
	magBase: CFrame,
	magOut: Vector3,
	magParts: { BasePart },
	boltWeld: Weld?,
	boltBase: CFrame,
	knobLocal: CFrame, -- knob relative to the bolt part
	pumpWeld: Weld?,
	pumpBase: CFrame,
	lidWeld: Weld?,
	lidBase: CFrame,
	lidLen: number,
	parts: { BasePart },
	recoilScale: number,
}

local container: Model? = nil
local armParts: { BasePart } = {}
local armCFrames: { CFrame } = {}
local sleeveParts: { BasePart } = {}
local cuffParts: { BasePart } = {}
local handParts: { BasePart } = {}

local weapon: Weapon? = nil
local visible = false
local aiming = false
local aimProgress = 0 -- linear 0..1
local aimAlpha = 0 -- eased
local raise = 0 -- 0 lowered .. 1 raised
local raiseRate = 2
local lowering = false
local anim: AnimState? = nil
local cycleT = 1 -- fire cycle (slide/bolt reciprocation) 0..1
local cycleDuration = 0.08
local sprintAlpha = 0
local crouchAlpha = 0
local proneAlpha = 0
local bobPhase = 0
local bobAmp = 0
local lastCamCF: CFrame? = nil
local wasGrounded = true
local lastFallSpeed = 0
local menuCount = 0
local inVehicle = false
local lastColorRefresh = 0
local adsFovApplied: number? = nil
local scoped = false -- Combat's scope overlay is up: hide the viewmodel

local recoilPos = Spring.new(Vector3.zero, 22, 0.62)
local recoilRot = Spring.new(Vector3.zero, 20, 0.55)
local swayRot = Spring.new(Vector3.zero, 14, 0.75)
local tilt = Spring.new(0, 10, 0.8)
local land = Spring.new(0, 12, 0.45)

local lastApi: { [string]: number } = {}

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

local controllerCache: { [string]: any } = {}
local function getController(name: string): any
	local cached = controllerCache[name]
	if cached ~= nil then
		return cached or nil
	end
	local m = script.Parent:FindFirstChild(name)
	local result: any = false
	if m and m:IsA("ModuleScript") then
		local ok, mod = pcall(require, m)
		if ok and type(mod) == "table" then
			result = mod
		end
	end
	controllerCache[name] = result
	return result or nil
end

local function callController(name: string, fn: string, ...: any): any
	local c = getController(name)
	if c and type(c[fn]) == "function" then
		local ok, result = pcall(c[fn], ...)
		if ok then
			return result
		end
	end
	return nil
end

local function smooth(t: number): number
	return t * t * (3 - 2 * t)
end

local function seg(t: number, a: number, b: number): number
	if t <= a then
		return 0
	elseif t >= b then
		return 1
	end
	return smooth((t - a) / (b - a))
end

-- rises over [a,b], falls over [c,d]
local function pulse(t: number, a: number, b: number, c: number, d: number): number
	return seg(t, a, b) - seg(t, c, d)
end

local function easeInOutCubic(t: number): number
	if t < 0.5 then
		return 4 * t * t * t
	end
	local f = -2 * t + 2
	return 1 - f * f * f / 2
end

local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	pcall(function()
		p.CollisionGroup = VIEWMODEL_GROUP
	end)
	return p
end

local function solveIK(s: Vector3, t: Vector3, pole: Vector3, a: number, b: number): (Vector3, Vector3)
	local d = t - s
	local dist = d.Magnitude
	local reach = (a + b) * 0.985
	if dist > reach then
		-- virtual shoulder slides toward the target (it is off-screen anyway)
		s = t - d.Unit * reach
		d = t - s
		dist = reach
	end
	dist = math.max(dist, math.abs(a - b) + 0.05)
	local dir = d / math.max(d.Magnitude, 1e-4)
	local cosA = math.clamp((a * a + dist * dist - b * b) / (2 * a * dist), -1, 1)
	local sinA = math.sqrt(1 - cosA * cosA)
	local toPole = pole - s
	local perp = toPole - dir * toPole:Dot(dir)
	if perp.Magnitude < 1e-4 then
		perp = Vector3.yAxis:Cross(dir)
	end
	perp = perp.Unit
	return s, s + dir * (a * cosA) + perp * (a * sinA)
end

local function segmentCF(a: Vector3, b: Vector3, up: Vector3): CFrame
	local mid = (a + b) * 0.5
	if (b - a).Magnitude < 1e-4 then
		return CF(mid)
	end
	return CFrame.lookAt(mid, b, up)
end

--------------------------------------------------------------------------------------------------
-- Arms
--------------------------------------------------------------------------------------------------

local function buildArms(parent: Model)
	local tunic = Color3.fromRGB(116, 107, 74)
	local skin = Color3.fromRGB(222, 176, 140)
	for _, side in { "Right", "Left" } do
		local upper = newPart(side .. "UpperSleeve", V3(0.44, 0.44, UPPER_LEN), tunic, Enum.Material.Fabric)
		local lower = newPart(side .. "LowerSleeve", V3(0.38, 0.38, LOWER_LEN), tunic, Enum.Material.Fabric)
		local cuff = newPart(side .. "Cuff", V3(0.41, 0.41, 0.14), tunic, Enum.Material.Fabric)
		local hand = newPart(side .. "Hand", V3(0.26, 0.22, 0.38), skin, Enum.Material.SmoothPlastic)
		for _, p in { upper, lower, cuff, hand } do
			p.Parent = parent
			table.insert(armParts, p)
			table.insert(armCFrames, IDENTITY)
		end
		table.insert(sleeveParts, upper)
		table.insert(sleeveParts, lower)
		table.insert(cuffParts, cuff)
		table.insert(handParts, hand)
	end
end

local function refreshColors()
	local factionId = player:GetAttribute("Faction")
	local f = type(factionId) == "string" and Factions.get(factionId) or nil
	local tunic = f and f.colors.tunic or Color3.fromRGB(116, 107, 74)
	for _, p in sleeveParts do
		p.Color = tunic
	end
	for _, p in cuffParts do
		p.Color = Color3.new(tunic.R * 0.82, tunic.G * 0.82, tunic.B * 0.82)
	end
	local character = player.Character
	local hand = character and character:FindFirstChild("RightHand")
	if hand and hand:IsA("BasePart") then
		for _, p in handParts do
			p.Color = hand.Color
		end
	end
end

-- Writes one arm's 4 CFrames into armCFrames starting at index `i`.
local function poseArm(i: number, camCF: CFrame, shoulderLocal: Vector3, poleLocal: Vector3, target: Vector3)
	local s = camCF * shoulderLocal
	local pole = camCF * poleLocal
	local up = camCF.UpVector
	local lowerEff = LOWER_LEN + HAND_LEN
	local s2, elbow = solveIK(s, target, pole, UPPER_LEN, lowerEff)
	local fdir = target - elbow
	fdir = if fdir.Magnitude > 1e-4 then fdir.Unit else camCF.LookVector
	local wrist = elbow + fdir * LOWER_LEN
	armCFrames[i] = segmentCF(s2, elbow, up)
	armCFrames[i + 1] = segmentCF(elbow, wrist, up)
	armCFrames[i + 2] = CFrame.lookAt(wrist - fdir * 0.06, wrist + fdir, up)
	armCFrames[i + 3] = CFrame.lookAt(wrist + fdir * HAND_LEN, wrist + fdir * 2, up)
end

--------------------------------------------------------------------------------------------------
-- Weapon setup
--------------------------------------------------------------------------------------------------

local function weldOf(part: Instance?): Weld?
	if part and part:IsA("BasePart") then
		local w = part:FindFirstChild("Weld")
		if w and w:IsA("Weld") then
			return w
		end
	end
	return nil
end

local function attachmentCF(handle: BasePart, name: string): CFrame
	local a = handle:FindFirstChild(name)
	if a and a:IsA("Attachment") then
		return a.CFrame
	end
	return IDENTITY
end

local function defaultReloadType(archetype: string): string
	if archetype == "BoltRifle" or archetype == "SniperRifle" then
		return "clip"
	elseif archetype == "Shotgun" or archetype == "Revolver" then
		return "single"
	end
	return "magazine"
end

local function prepareWeapon(weaponId: string): Weapon?
	local ok, model = pcall(WeaponModels.Build, weaponId)
	if not ok or typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local handle = model.PrimaryPart or model:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		model:Destroy()
		return nil
	end
	local parts: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d.Massless = true
			d.Anchored = d == handle
			pcall(function()
				d.CollisionGroup = VIEWMODEL_GROUP
			end)
			table.insert(parts, d)
		end
	end

	local def = WeaponModels.GetConfig(weaponId) or {}
	local hold = model:GetAttribute("Hold")
	hold = if type(hold) == "string" and PROFILES[hold] then hold else "Rifle"
	local archetype = model:GetAttribute("Archetype")
	archetype = if type(archetype) == "string" then archetype else "BoltRifle"
	local eye = tonumber(model:GetAttribute("EyeRelief")) or 0.6
	local sight = attachmentCF(handle, "Sight")
	local magOut = model:GetAttribute("MagOut")

	local magPart = model:FindFirstChild("Mag")
	local magParts: { BasePart } = {}
	if magPart and magPart:IsA("BasePart") then
		table.insert(magParts, magPart)
		for _, p in parts do
			local w = weldOf(p)
			if w and w.Part0 == magPart then
				table.insert(magParts, p)
			end
		end
	end
	local boltPart = model:FindFirstChild("Bolt") or model:FindFirstChild("Slide")
	local knob = model:FindFirstChild("BoltKnob")
	local knobWeld = weldOf(knob)
	local lid = model:FindFirstChild("Lid")
	local magWeld, boltWeld, pumpWeld, lidWeld =
		weldOf(magPart), weldOf(boltPart), weldOf(model:FindFirstChild("Pump")), weldOf(lid)

	local recoil = type(def.recoil) == "table" and def.recoil or {}
	local w: Weapon = {
		id = weaponId,
		model = model,
		handle = handle,
		profile = PROFILES[hold],
		hold = hold,
		action = tostring(model:GetAttribute("Action") or "slide"),
		archetype = archetype,
		reloadType = if type(def.reloadType) == "string" then def.reloadType else defaultReloadType(archetype),
		adsTime = math.clamp(tonumber(def.adsTime) or 0.25, 0.05, 1.5),
		adsZoom = math.clamp(tonumber(def.adsZoom) or (if hold == "Binoculars" then 0.3 else 0.8), 0.1, 1),
		eyeRelief = eye,
		grip = attachmentCF(handle, "Grip"),
		support = attachmentCF(handle, "Support"),
		sight = sight,
		muzzle = handle:FindFirstChild("Muzzle") :: Attachment?,
		adsCF = CF(0, 0, -eye) * sight:Inverse(),
		magWeld = magWeld,
		magBase = if magWeld then magWeld.C0 else IDENTITY,
		magOut = if typeof(magOut) == "Vector3" and magOut.Magnitude > 0 then magOut.Unit else V3(0, -1, 0),
		magParts = magParts,
		boltWeld = boltWeld,
		boltBase = if boltWeld then boltWeld.C0 else IDENTITY,
		knobLocal = if knobWeld then knobWeld.C0 else CF(0.2, -0.05, 0.16),
		pumpWeld = pumpWeld,
		pumpBase = if pumpWeld then pumpWeld.C0 else IDENTITY,
		lidWeld = lidWeld,
		lidBase = if lidWeld then lidWeld.C0 else IDENTITY,
		lidLen = if lid and lid:IsA("BasePart") then lid.Size.Z else 0.5,
		parts = parts,
		recoilScale = math.clamp((tonumber(recoil.vertical) or 1.5) / 2.5, 0.35, 1.6),
	}
	return w
end

local function resetSubParts(w: Weapon)
	if w.magWeld then
		w.magWeld.C0 = w.magBase
	end
	if w.boltWeld then
		w.boltWeld.C0 = w.boltBase
	end
	if w.pumpWeld then
		w.pumpWeld.C0 = w.pumpBase
	end
	if w.lidWeld then
		w.lidWeld.C0 = w.lidBase
	end
	for _, p in w.magParts do
		p.LocalTransparencyModifier = 0
	end
end

local weaponHidden = false
local function setWeaponHidden(w: Weapon, hidden: boolean)
	if hidden == weaponHidden then
		return
	end
	weaponHidden = hidden
	local v = if hidden then 1 else 0
	for _, p in w.parts do
		if p ~= w.handle then
			p.LocalTransparencyModifier = v
		end
	end
end

local function destroyWeapon()
	local w = weapon
	weapon = nil
	anim = nil
	if w then
		w.model:Destroy()
	end
	if adsFovApplied and not getController("WeaponController") then
		callController("CameraController", "SetFovOffset", "ADS", nil)
	end
	adsFovApplied = nil
end

--------------------------------------------------------------------------------------------------
-- Animation evaluation
--------------------------------------------------------------------------------------------------

-- Per-frame animation outputs (module-level to avoid table allocation)
local outCF = IDENTITY -- handle-space offset
local outAimBlock = 0
local outLeftW = 0
local outLeftT: CFrame? = nil -- handle-space
local outLeftCam: CFrame? = nil -- camera-space (takes priority)
local outRightW = 0
local outRightT: CFrame? = nil -- handle-space
local outMag = 0
local outBoltZ = 0
local outBoltLift = 0
local outPump = 0
local outLid = 0
local outHide = false
local outRaiseOverride: number? = nil

local function boltCF(w: Weapon, z: number, lift: number): CFrame
	local base = w.boltBase
	if lift ~= 0 then
		return CF(base.Position + V3(0, 0, z)) * ANG(0, 0, lift) * base.Rotation
	end
	return base + V3(0, 0, z)
end

local function evalReloadMagazine(w: Weapon, t: number, empty: boolean)
	local p = pulse(t, 0, 0.12, 0.86, 1)
	outCF = CF(-0.08 * p, -0.12 * p, 0.06 * p) * ANG(0.18 * p, 0.25 * p, 0.55 * p)
	outAimBlock = p
	outMag = 1.4 * seg(t, 0.18, 0.34) - 1.15 * seg(t, 0.42, 0.6) - 0.25 * seg(t, 0.6, 0.68)
	outLid = pulse(t, 0.1, 0.2, 0.7, 0.8)
	outLeftW = pulse(t, 0.1, 0.18, 0.7, 0.8)
	outLeftT = nil -- resolved to the magazine in applyAnimation
	if empty then
		local charge = pulse(t, 0.8, 0.86, 0.88, 0.94)
		outBoltZ = 0.22 * charge
		if t > 0.74 then
			outLeftW = pulse(t, 0.74, 0.8, 0.93, 0.99)
			outLeftT = boltCF(w, outBoltZ, 0) * CF(-0.1, 0.02, 0)
		end
	end
end

local function evalReloadClip(w: Weapon, t: number, _empty: boolean)
	local p = pulse(t, 0, 0.12, 0.88, 1)
	outCF = CF(-0.05 * p, -0.08 * p, 0.05 * p) * ANG(0.2 * p, 0.2 * p, 0.35 * p)
	outAimBlock = p
	if w.action == "bolt" then
		outBoltLift = 1.15 * (seg(t, 0.1, 0.18) - seg(t, 0.78, 0.86))
		outBoltZ = 0.4 * (seg(t, 0.18, 0.28) - seg(t, 0.68, 0.78))
		outRightW = pulse(t, 0.04, 0.11, 0.86, 0.94)
		outRightT = boltCF(w, outBoltZ, outBoltLift) * w.knobLocal
	end
	local push = 0.2 * seg(t, 0.4, 0.5) + 0.1 * seg(t, 0.52, 0.6)
	outLeftW = pulse(t, 0.26, 0.36, 0.62, 0.72)
	outLeftT = CF(0, 0.5 - push, -0.15)
end

local function evalReloadSingle(w: Weapon, t: number, empty: boolean, count: number)
	local p = pulse(t, 0, 0.1, 0.9, 1)
	outCF = CF(0.05 * p, 0.05 * p, 0) * ANG(0.12 * p, -0.15 * p, -0.6 * p)
	outAimBlock = p
	local finish = if empty and w.action == "pump" then 0.82 else 0.88
	local u = math.clamp((t - 0.1) / (finish - 0.1), 0, 1) * count
	local frac = u % 1
	local ins = if frac < 0.5 then smooth(frac * 2) else 1 - smooth((frac - 0.5) * 2)
	if t >= finish then
		ins = 0
	end
	outLeftW = pulse(t, 0.06, 0.12, finish, finish + 0.06)
	outLeftT = CF(0, -0.55 + 0.38 * ins, -0.08 - 0.12 * ins)
	if w.archetype == "Revolver" then
		outMag = 0.18 * p -- cylinder swings out
	end
	if empty and w.action == "pump" then
		outPump = 0.3 * pulse(t, 0.86, 0.9, 0.93, 0.98)
		if t > finish then
			outLeftW = 1
			outLeftT = w.pumpBase + V3(0, -0.03, outPump)
		end
	end
end

local function evalBolt(w: Weapon, t: number)
	if w.action == "bolt" then
		outBoltLift = 1.15 * pulse(t, 0.06, 0.22, 0.74, 0.9)
		outBoltZ = 0.42 * pulse(t, 0.22, 0.4, 0.56, 0.74)
		outRightW = pulse(t, 0, 0.1, 0.88, 1)
		outRightT = boltCF(w, outBoltZ, outBoltLift) * w.knobLocal
		outCF = CF(0, -0.03 * outRightW, 0.04 * outRightW) * ANG(0.06 * outRightW, 0, 0.2 * outRightW)
		outAimBlock = 0.55 * outRightW
	elseif w.action == "pump" then
		outPump = 0.32 * pulse(t, 0.08, 0.4, 0.5, 0.85)
		outCF = CF(0, 0, 0.05 * outPump) * ANG(0.12 * outPump, 0, 0)
		outLeftW = 1
		outLeftT = w.pumpBase + V3(0, -0.03, outPump)
		outAimBlock = 0.3 * pulse(t, 0, 0.1, 0.85, 1)
	else
		local pull = pulse(t, 0.2, 0.45, 0.55, 0.7)
		outBoltZ = 0.25 * pull
		outLeftW = pulse(t, 0.05, 0.2, 0.7, 0.9)
		outLeftT = boltCF(w, outBoltZ, 0) * CF(-0.08, 0.02, 0)
		outCF = ANG(0.05 * outLeftW, 0.15 * outLeftW, 0.35 * outLeftW)
		outAimBlock = outLeftW
	end
end

local function evalThrow(t: number)
	local wind = seg(t, 0, 0.32)
	local throw = seg(t, 0.32, 0.48)
	local cf = CF(0.15 * wind - 0.25 * throw, 0.75 * wind - 0.35 * throw, 0.9 * wind - 2.4 * throw)
		* ANG(1.0 * wind - 1.8 * throw, 0, -0.3 * wind + 0.2 * throw)
	outCF = cf
	outAimBlock = 1
	outLeftW = pulse(t, 0, 0.22, 0.45, 0.65)
	outLeftCam = CF(-0.55, -0.35, -1.7)
	outHide = t > 0.47 and t < 0.75
	if t >= 0.75 then
		outCF = IDENTITY
		outRaiseOverride = seg(t, 0.75, 1)
	end
end

local function evalMelee(w: Weapon, t: number)
	if w.hold == "Melee" then
		local wind = seg(t, 0, 0.22)
		local slash = seg(t, 0.22, 0.42)
		local back = seg(t, 0.55, 1)
		local k = 1 - back
		outCF = CF((0.45 * wind - 1.1 * slash) * k, (0.4 * wind - 0.55 * slash) * k, (0.2 * wind - 0.55 * slash) * k)
			* ANG((0.35 * wind - 0.7 * slash) * k, (0.7 * wind - 1.5 * slash) * k, (-0.5 * wind + 1.0 * slash) * k)
	else
		local e = pulse(t, 0, 0.22, 0.42, 1)
		outCF = CF(-0.25 * e, 0.12 * e, -0.55 * e) * ANG(0.25 * e, 1.0 * e, 0.45 * e)
	end
	outAimBlock = 1
end

local function evalInspect(t: number)
	local e = pulse(t, 0, 0.18, 0.82, 1)
	local flip = seg(t, 0.38, 0.6)
	outCF = CF(-0.35 * e, 0.22 * e, 0.25 * e) * ANG(0.25 * e, (0.9 - 1.5 * flip) * e, (0.6 - 1.1 * flip) * e)
	outAimBlock = e
end

local function evaluateAnim(w: Weapon, now: number)
	outCF = IDENTITY
	outAimBlock = 0
	outLeftW, outLeftT, outLeftCam = 0, nil, nil
	outRightW, outRightT = 0, nil
	outMag, outBoltZ, outBoltLift, outPump, outLid = 0, 0, 0, 0, 0
	outHide = false
	outRaiseOverride = nil

	local a = anim
	if a then
		local t = (now - a.t0) / a.duration
		if t >= 1 then
			anim = nil
			resetSubParts(w)
			setWeaponHidden(w, false)
		else
			t = math.max(t, 0)
			local kind = a.kind
			if kind == "reload" then
				if w.reloadType == "single" then
					evalReloadSingle(w, t, a.empty, a.count)
				elseif w.reloadType == "clip" then
					evalReloadClip(w, t, a.empty)
				else
					evalReloadMagazine(w, t, a.empty)
				end
			elseif kind == "bolt" then
				evalBolt(w, t)
			elseif kind == "throw" then
				evalThrow(t)
			elseif kind == "melee" then
				evalMelee(w, t)
			elseif kind == "inspect" then
				evalInspect(t)
			end
		end
	end

	-- fire cycle: slide / bolt carrier snaps back and returns
	if cycleT < 1 and w.action ~= "bolt" and w.action ~= "none" then
		local c = math.sin(math.pi * cycleT)
		if w.action == "pump" then
			-- pump guns cycle with PlayBolt
			c = 0
		end
		outBoltZ = math.max(outBoltZ, (if w.hold == "Pistol" then 0.16 else 0.12) * c)
	end
end

local function applySubParts(w: Weapon)
	if not anim and cycleT >= 1 then
		return
	end
	if w.magWeld then
		w.magWeld.C0 = w.magBase + w.magOut * outMag
		local fade = math.clamp((outMag - 0.6) / 0.4, 0, 1)
		for _, p in w.magParts do
			p.LocalTransparencyModifier = fade
		end
	end
	if w.boltWeld then
		w.boltWeld.C0 = boltCF(w, outBoltZ, outBoltLift)
	end
	if w.pumpWeld then
		w.pumpWeld.C0 = w.pumpBase + V3(0, 0, outPump)
	end
	if w.lidWeld then
		local half = w.lidLen / 2
		w.lidWeld.C0 = w.lidBase * CF(0, 0, half) * ANG(1.1 * outLid, 0, 0) * CF(0, 0, -half)
	end
end

--------------------------------------------------------------------------------------------------
-- Visibility
--------------------------------------------------------------------------------------------------

local function isMenuOpen(): boolean
	local ui = getController("UIController")
	if ui and type(ui.IsMenuOpen) == "function" then
		local ok, open = pcall(ui.IsMenuOpen)
		if ok then
			return open == true
		end
	end
	return menuCount > 0
end

local function isFirstPerson(camera: Camera, head: BasePart?): boolean
	local cam = getController("CameraController")
	if cam and type(cam.IsFirstPerson) == "function" then
		local ok, fp = pcall(cam.IsFirstPerson)
		if ok then
			return fp == true
		end
	end
	return head ~= nil and (camera.CFrame.Position - head.Position).Magnitude < 2
end

local function setVisible(v: boolean, camera: Camera)
	if v == visible then
		return
	end
	visible = v
	local c = container
	if c then
		c.Parent = if v then camera else nil
	end
	if v then
		lastCamCF = nil
		refreshColors()
	end
end

--------------------------------------------------------------------------------------------------
-- Render step
--------------------------------------------------------------------------------------------------

local function render(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local now = os.clock()
	local w = weapon
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = character and character:FindFirstChild("Head") :: BasePart?

	local show = w ~= nil
		and humanoid ~= nil
		and humanoid.Health > 0
		and root ~= nil
		and not inVehicle
		and (player:GetAttribute("VehicleUid") or "") == ""
		and not isMenuOpen()
		and not scoped
		and isFirstPerson(camera, head)
	setVisible(show, camera)
	if not show or not w or not root or not humanoid then
		return
	end

	if now - lastColorRefresh > 1.5 then
		lastColorRefresh = now
		refreshColors()
	end

	local camCF = camera.CFrame
	local profile = w.profile

	-- movement state
	local movement = getController("MovementController")
	local sprinting, stance = false, "Stand"
	if movement then
		local ok1, s1 = pcall(movement.IsSprinting)
		local ok2, s2 = pcall(movement.GetStance)
		sprinting = ok1 and s1 == true
		stance = if ok2 and type(s2) == "string" then s2 else "Stand"
	end
	local k = 1 - math.exp(-dt * 10)
	sprintAlpha += ((if sprinting and aimAlpha < 0.5 and not anim then 1 else 0) - sprintAlpha) * k
	crouchAlpha += ((if stance == "Crouch" then 1 else 0) - crouchAlpha) * k
	proneAlpha += ((if stance == "Prone" then 1 else 0) - proneAlpha) * k

	-- equip raise / lower
	if lowering then
		raise = math.max(0, raise - dt * raiseRate)
		if raise <= 0 then
			lowering = false
			destroyWeapon()
			setVisible(false, camera)
			return
		end
	else
		raise = math.min(1, raise + dt * raiseRate)
	end

	-- animation
	evaluateAnim(w, now)
	if cycleT < 1 then
		cycleT = math.min(1, cycleT + dt / cycleDuration)
	end
	applySubParts(w)

	-- ADS
	local wantAim = aiming and profile.canAim and not lowering
	aimProgress = math.clamp(aimProgress + (if wantAim then dt else -dt) / w.adsTime, 0, 1)
	aimAlpha = easeInOutCubic(aimProgress)
	local aimEff = aimAlpha * (1 - outAimBlock)

	-- push ADS zoom to the camera (only when no WeaponController owns the "ADS" key)
	local base = callController("CameraController", "GetBaseFov") or 80
	local fov = (tonumber(base) or 80) * (w.adsZoom - 1) * aimAlpha
	if getController("WeaponController") then
		fov = adsFovApplied or 0
	end
	if adsFovApplied == nil or math.abs(fov - adsFovApplied) > 0.05 then
		adsFovApplied = fov
		callController("CameraController", "SetFovOffset", "ADS", if math.abs(fov) < 0.05 then nil else fov)
	end

	-- sway from camera angular velocity
	local prev = lastCamCF
	lastCamCF = camCF
	if prev and dt > 0 then
		local rx, ry = prev:ToObjectSpace(camCF):ToEulerAnglesYXZ()
		local scale = 0.028 * (1 - 0.75 * aimAlpha)
		swayRot.Target = V3(
			math.clamp(-rx / dt * scale, -0.22, 0.22),
			math.clamp(-ry / dt * scale, -0.28, 0.28),
			math.clamp(-ry / dt * scale * 0.6, -0.2, 0.2)
		)
	end
	local sway = swayRot:Update(dt)

	-- velocity-driven bob / tilt / landing
	local vel = root.AssemblyLinearVelocity
	local localVel = camCF:VectorToObjectSpace(vel)
	local horizontal = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	if grounded and not wasGrounded then
		land:Impulse(-math.clamp(lastFallSpeed, 0, 70) * 0.025)
	end
	if not grounded then
		lastFallSpeed = math.max(0, -vel.Y)
	end
	wasGrounded = grounded
	tilt.Target = math.clamp(-localVel.X / 16, -1, 1) * 0.07 * (1 - 0.7 * aimAlpha)
	local tiltV = tilt:Update(dt)
	local landV = land:Update(dt)

	local moveFactor = if grounded then math.clamp(horizontal / Constants.WALK_SPEED, 0, 1.8) else 0
	local targetAmp = moveFactor
		* profile.bob
		* (1 + 0.9 * sprintAlpha)
		* (1 - 0.88 * aimAlpha)
		* (1 + 0.6 * proneAlpha)
	bobAmp += (targetAmp - bobAmp) * (1 - math.exp(-dt * 8))
	local freq = (if proneAlpha > 0.5 then 5 else 8.5) * (1 + 0.2 * sprintAlpha)
	bobPhase = (bobPhase + dt * freq * math.clamp(moveFactor, 0.4, 1.5)) % (math.pi * 4)
	local bx = math.sin(bobPhase) * 0.035 * bobAmp
	local by = math.sin(bobPhase * 2) * 0.022 * bobAmp
	local breathe = math.sin(now * 1.3) * (1 - 0.6 * aimAlpha)

	-- recoil springs
	local rp = recoilPos:Update(dt)
	local rr = recoilRot:Update(dt)

	-- compose handle pose
	local hip = profile.hip * IDENTITY:Lerp(profile.crouch, crouchAlpha) * IDENTITY:Lerp(profile.prone, proneAlpha)
	hip = hip:Lerp(profile.sprint, sprintAlpha)
	local pose = hip:Lerp(w.adsCF, aimEff)
	local raised = smooth(outRaiseOverride or raise)
	if raised < 1 then
		pose = profile.lowered:Lerp(pose, raised)
	end

	local handleCF = camCF
		* CF(bx + sway.Y * 0.08, by + landV + breathe * 0.006, 0)
		* pose
		* CF(rp.X, rp.Y, rp.Z)
		* CFrame.fromEulerAnglesYXZ(
			rr.X + sway.X + breathe * 0.004,
			rr.Y + sway.Y + math.cos(bobPhase) * 0.012 * bobAmp,
			rr.Z + sway.Z + tiltV + math.sin(bobPhase) * 0.02 * bobAmp
		)
		* outCF

	w.handle.CFrame = handleCF
	setWeaponHidden(w, outHide)

	-- hands
	local rightTarget = handleCF * w.grip
	if outRightW > 0 and outRightT then
		rightTarget = rightTarget:Lerp(handleCF * outRightT, outRightW)
	end
	local leftTarget: CFrame
	if profile.oneHanded then
		leftTarget = camCF * LEFT_REST
	else
		leftTarget = handleCF * w.support
	end
	if outLeftW > 0 then
		local override: CFrame
		if outLeftCam then
			override = camCF * outLeftCam
		elseif outLeftT then
			override = handleCF * outLeftT
		elseif w.magWeld then
			override = handleCF * w.magWeld.C0
		else
			override = camCF * LEFT_REST
		end
		leftTarget = leftTarget:Lerp(override, outLeftW)
	end

	poseArm(1, camCF, R_SHOULDER, R_POLE, rightTarget.Position)
	poseArm(5, camCF, L_SHOULDER, L_POLE, leftTarget.Position)
	workspace:BulkMoveTo(armParts, armCFrames, Enum.BulkMoveMode.FireCFrameChanged)
end

--------------------------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------------------------

function ViewmodelController.Equip(weaponId: string)
	lastApi.equip = os.clock()
	if type(weaponId) ~= "string" or weaponId == "" then
		ViewmodelController.Unequip()
		return
	end
	if weapon and weapon.id == weaponId and not lowering then
		return
	end
	destroyWeapon()
	lowering = false
	local w = prepareWeapon(weaponId)
	if not w then
		return
	end
	weapon = w
	weaponHidden = false
	if container then
		w.model.Parent = container
	end
	aimProgress, aimAlpha = 0, 0
	cycleT = 1
	cycleDuration = 0.08
	local def = WeaponModels.GetConfig(weaponId)
	local rpm = def and tonumber(def.rpm)
	if rpm and rpm > 0 then
		cycleDuration = math.clamp(60 / rpm * 0.8, 0.04, 0.12)
	end
	ViewmodelController.PlayEquip(def and tonumber(def.equipTime) or 0.5)
end

function ViewmodelController.Unequip()
	lastApi.unequip = os.clock()
	if weapon and not lowering then
		lowering = true
		raiseRate = 1 / 0.22
		anim = nil
		resetSubParts(weapon)
	end
end

function ViewmodelController.SetAiming(isAiming: boolean)
	lastApi.aim = os.clock()
	aiming = isAiming == true
end

function ViewmodelController.PlayFire(kick: number?)
	lastApi.fire = os.clock()
	local w = weapon
	if not w then
		return
	end
	local k = math.clamp(tonumber(kick) or 0.5, 0, 2) * w.recoilScale
	local ads = 1 - 0.55 * aimAlpha
	recoilPos:Impulse(V3((math.random() - 0.5) * 0.25 * k, 0.15 * k * ads, 2.4 * k * (1 - 0.35 * aimAlpha)))
	recoilRot:Impulse(V3(2.0 * k * ads, (math.random() - 0.5) * 0.7 * k, (math.random() - 0.5) * 1.1 * k))
	cycleT = 0
end

function ViewmodelController.PlayReload(duration: number, empty: boolean?)
	lastApi.reload = os.clock()
	local w = weapon
	if not w then
		return
	end
	local requested = tonumber(duration) or 2
	if requested <= 0 then
		-- cancelled reload: return to idle
		if anim and anim.kind == "reload" then
			anim = nil
			resetSubParts(w)
		end
		return
	end
	local d = math.max(requested, 0.3)
	local count = 1
	if w.reloadType == "single" then
		count = math.max(1, math.floor((d - 0.5) / 0.45 + 0.5))
	end
	resetSubParts(w)
	anim = { kind = "reload", t0 = os.clock(), duration = d, empty = empty == true, count = count }
end

function ViewmodelController.PlayEquip(duration: number?)
	lastApi.equip = os.clock()
	lowering = false
	raise = 0
	raiseRate = 1 / math.clamp(tonumber(duration) or 0.5, 0.1, 3)
end

function ViewmodelController.PlayBolt(duration: number?)
	local w = weapon
	if not w then
		return
	end
	anim = {
		kind = "bolt",
		t0 = os.clock(),
		duration = math.clamp(tonumber(duration) or 0.8, 0.2, 3),
		empty = false,
		count = 1,
	}
end

function ViewmodelController.PlayThrow()
	if not weapon then
		return
	end
	anim = { kind = "throw", t0 = os.clock(), duration = 0.75, empty = false, count = 1 }
end

function ViewmodelController.PlayMelee()
	if not weapon then
		return
	end
	anim = { kind = "melee", t0 = os.clock(), duration = 0.55, empty = false, count = 1 }
end

function ViewmodelController.PlayInspect()
	if not weapon or anim then
		return
	end
	anim = { kind = "inspect", t0 = os.clock(), duration = 2.4, empty = false, count = 1 }
end

function ViewmodelController.GetMuzzleWorldCFrame(): CFrame?
	local w = weapon
	if not w or not visible then
		return nil
	end
	local m = w.muzzle
	if m then
		return w.handle.CFrame * m.CFrame
	end
	return w.handle.CFrame
end

function ViewmodelController.GetAimAlpha(): number
	return aimAlpha
end

function ViewmodelController.IsVisible(): boolean
	return visible
end

function ViewmodelController.GetEquippedId(): string?
	return weapon and weapon.id
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

-- Run `fn` for a Bus event unless the matching API was called within the last 0.1 s.
local function fallback(eventName: string, apiKey: string, fn: (...any) -> ())
	Bus.connect(eventName, function(...)
		local args = table.pack(...)
		task.defer(function()
			if os.clock() - (lastApi[apiKey] or -1) > 0.1 then
				fn(table.unpack(args, 1, args.n))
			end
		end)
	end)
end

function ViewmodelController:Init()
	local model = Instance.new("Model")
	model.Name = "Viewmodel"
	container = model
	buildArms(model)
end

function ViewmodelController:Start()
	Bus.connect("MenuOpened", function()
		menuCount += 1
	end)
	Bus.connect("MenuClosed", function()
		menuCount = math.max(0, menuCount - 1)
	end)
	Bus.connect("VehicleEntered", function()
		inVehicle = true
	end)
	Bus.connect("ScopeChanged", function(isScoped)
		scoped = isScoped == true
	end)
	Bus.connect("VehicleExited", function()
		inVehicle = false
	end)

	fallback("WeaponEquipped", "equip", function(weaponId)
		ViewmodelController.Equip(weaponId)
	end)
	fallback("WeaponUnequipped", "unequip", function()
		ViewmodelController.Unequip()
	end)
	fallback("AimChanged", "aim", function(isAiming)
		ViewmodelController.SetAiming(isAiming)
	end)
	fallback("Fired", "fire", function(weaponId)
		local def = WeaponModels.GetConfig(weaponId)
		local v = def and type(def.recoil) == "table" and tonumber(def.recoil.vertical) or 1.5
		ViewmodelController.PlayFire(math.clamp(v / 3, 0.2, 1.2))
	end)
	fallback("ReloadStarted", "reload", function(_weaponId, duration, empty)
		ViewmodelController.PlayReload(duration, empty)
	end)

	player:GetAttributeChangedSignal("Faction"):Connect(refreshColors)
	local function hookCharacter(character: Model)
		aiming = false
		task.delay(1, refreshColors)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				if player.Character == character then
					destroyWeapon()
					aiming = false
				end
			end)
		end
	end
	player.CharacterAdded:Connect(hookCharacter)
	if player.Character then
		task.spawn(hookCharacter, player.Character)
	end

	RunService:BindToRenderStep("WW2Viewmodel", RENDER_PRIORITY, render)
end

return ViewmodelController
