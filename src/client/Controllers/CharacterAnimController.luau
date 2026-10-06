--[[
	CharacterAnimController (Animation/Models team, client)

	Procedurally poses every R15 character (other players, and the local one for shadows / third
	person views) by writing Motor6D.Transform each frame from replicated state:
	  * AimPitch / Stance character attributes (CharacterAnimService), the local character reads
	    the camera + MovementController directly.
	  * Weapon hold: CombatService welds "EquippedWeaponModel" to RightHand with a Motor6D
	    "WeaponGrip". We drive that joint's Transform so the weapon sits shouldered along the aim
	    (pistols extended, launchers on the shoulder, gadgets/grenades at a low ready) and solve
	    two-bone IK so the right hand reaches "Grip" and the left hand reaches "Support".
	  * Waist / neck pitch, crouch (lowered root, bent legs, forward lean), prone (body laid flat,
	    head raised, crawl), sprint (port-arms weapon pose, bigger stride, lean), seated pose,
	    airborne tuck, velocity-scaled walk cycle (forward + strafe swing), free arm swing when
	    unarmed.
	  * Remote characters' footsteps at foot plants (SoundController.PlayAt "Footstep_<Material>").
	  * LOD: full rate within 60 studs (on screen), every 2nd frame up to 150 studs, every 3rd up
	    to 450 studs, skipped beyond; characters outside the camera's view cone update every 4th
	    frame (they still cast shadows, so they are not frozen).

	The default "Animate" script is removed (server: CharacterAnimService; client fallback here)
	so stock walk/idle tracks never fight these poses.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)

local CharacterAnimController = {}

local player = Players.LocalPlayer

local CF = CFrame.new
local ANG = CFrame.Angles
local IDENTITY = CFrame.identity
local V3 = Vector3.new

local RENDER_PRIORITY = Enum.RenderPriority.Character.Value
local CLOSE_DISTANCE = 60
local NEAR_DISTANCE = 150
local FAR_DISTANCE = 450
local MID_STEP = 2 -- frames between updates in the 60..150 band
local FAR_STEP = 3 -- frames between updates in the far band
local OFFSCREEN_STEP = 4 -- frames between updates for characters behind the camera
local OFFSCREEN_DOT = 0.2 -- cos of the half view cone treated as "on screen" (generous: ~78 deg)
local FOOTSTEP_DISTANCE = 70
local STRIDE_RATE = 0.6 -- walk-cycle radians per stud travelled

local FOOTSTEP_KEYS: { [Enum.Material]: string } = {
	[Enum.Material.Grass] = "Footstep_Grass",
	[Enum.Material.LeafyGrass] = "Footstep_Grass",
	[Enum.Material.Ground] = "Footstep_Grass",
	[Enum.Material.Wood] = "Footstep_Wood",
	[Enum.Material.WoodPlanks] = "Footstep_Wood",
	[Enum.Material.Snow] = "Footstep_Snow",
	[Enum.Material.Glacier] = "Footstep_Snow",
	[Enum.Material.Ice] = "Footstep_Snow",
	[Enum.Material.Mud] = "Footstep_Mud",
	[Enum.Material.Sand] = "Footstep_Sand",
	[Enum.Material.Metal] = "Footstep_Metal",
	[Enum.Material.DiamondPlate] = "Footstep_Metal",
	[Enum.Material.CorrodedMetal] = "Footstep_Metal",
	[Enum.Material.Concrete] = "Footstep_Concrete",
	[Enum.Material.Brick] = "Footstep_Concrete",
	[Enum.Material.Cobblestone] = "Footstep_Concrete",
	[Enum.Material.Pavement] = "Footstep_Concrete",
	[Enum.Material.Asphalt] = "Footstep_Concrete",
	[Enum.Material.Rock] = "Footstep_Concrete",
	[Enum.Material.Slate] = "Footstep_Concrete",
	[Enum.Material.SmoothPlastic] = "Footstep_Concrete",
	[Enum.Material.Plastic] = "Footstep_Concrete",
}
local STEP_VOLUME = { Stand = 0.55, Sprint = 0.9, Crouch = 0.25, Prone = 0 }

type Limb = {
	j1: Motor6D, -- shoulder / hip
	j2: Motor6D, -- elbow / knee
	j3: Motor6D?, -- wrist / ankle
	len1: number,
	len2: number,
}

type Rig = {
	character: Model,
	owner: Player?,
	isLocal: boolean,
	humanoid: Humanoid,
	root: BasePart,
	rootJoint: Motor6D,
	waist: Motor6D,
	neck: Motor6D?,
	rArm: Limb,
	lArm: Limb,
	rLeg: Limb,
	lLeg: Limb,
	rootHeight: number,
	crouchDrop: number,
	phase: number,
	pitch: number,
	crouchA: number,
	proneA: number,
	sprintA: number,
	seatA: number,
	accum: number,
	frame: number,
	weaponHidden: boolean,
	lastWeapon: Model?,
	-- cached lookups for lastWeapon (refreshed only when the weapon model changes)
	weaponGrip: Motor6D?,
	weaponHandle: BasePart?,
	weaponHold: any,
	weaponRearZ: number,
	weaponGripLocal: Vector3,
	weaponSupportLocal: Vector3,
}

local rigs: { [Model]: Rig } = {}
local frameCounter = 0
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

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

local function motor(character: Model, partName: string, jointName: string): Motor6D?
	local part = character:FindFirstChild(partName)
	local m = part and part:FindFirstChild(jointName)
	if m and m:IsA("Motor6D") then
		return m
	end
	return nil
end

local function limb(character: Model, side: string, isArm: boolean): Limb?
	local j1, j2, j3
	if isArm then
		j1 = motor(character, side .. "UpperArm", side .. "Shoulder")
		j2 = motor(character, side .. "LowerArm", side .. "Elbow")
		j3 = motor(character, side .. "Hand", side .. "Wrist")
	else
		j1 = motor(character, side .. "UpperLeg", side .. "Hip")
		j2 = motor(character, side .. "LowerLeg", side .. "Knee")
		j3 = motor(character, side .. "Foot", side .. "Ankle")
	end
	if not (j1 and j2) then
		return nil
	end
	local len1 = (j2.C0.Position - j1.C1.Position).Magnitude
	local len2 = if j3 then (j3.C0.Position - j2.C1.Position).Magnitude else len1
	return { j1 = j1, j2 = j2, j3 = j3, len1 = math.max(len1, 0.2), len2 = math.max(len2, 0.2) }
end

-- Part CFrame mapping the part-space segment pA->pB onto world points A->B, rolled so the
-- part's sideways axis follows `side`.
local function alignSegment(pA: Vector3, pB: Vector3, a: Vector3, b: Vector3, side: Vector3): CFrame
	local u = pB - pA
	if u.Magnitude < 1e-4 then
		u = V3(0, -1, 0)
	end
	local a1 = u.Unit
	local ref = if math.abs(a1.X) < 0.9 then Vector3.xAxis else Vector3.zAxis
	local b1 = (ref - a1 * ref:Dot(a1)).Unit
	local c1 = a1:Cross(b1)

	local d = b - a
	local dir = if d.Magnitude > 1e-4 then d.Unit else V3(0, -1, 0)
	local b2 = side - dir * side:Dot(dir)
	if b2.Magnitude < 1e-3 then
		b2 = Vector3.yAxis - dir * dir.Y
		if b2.Magnitude < 1e-3 then
			b2 = Vector3.zAxis
		end
	end
	b2 = b2.Unit
	local c2 = dir:Cross(b2)
	local rot = CFrame.fromMatrix(Vector3.zero, dir, b2, c2) * CFrame.fromMatrix(Vector3.zero, a1, b1, c1):Inverse()
	return rot + (a - rot:VectorToWorldSpace(pA))
end

local function solveElbow(s: Vector3, t: Vector3, pole: Vector3, a: number, b: number): (Vector3, Vector3)
	local d = t - s
	local dist = math.clamp(d.Magnitude, math.abs(a - b) + 0.02, (a + b) * 0.999)
	local dir = if d.Magnitude > 1e-4 then d.Unit else V3(0, 0, -1)
	local cosA = math.clamp((a * a + dist * dist - b * b) / (2 * a * dist), -1, 1)
	local sinA = math.sqrt(1 - cosA * cosA)
	local toPole = pole - s
	local perp = toPole - dir * toPole:Dot(dir)
	if perp.Magnitude < 1e-4 then
		perp = V3(0, -1, 0)
	end
	perp = perp.Unit
	local elbow = s + dir * (a * cosA) + perp * (a * sinA)
	local wrist = elbow + (s + dir * dist - elbow).Unit * b
	return elbow, wrist
end

-- IK one arm toward world `target`; writes shoulder/elbow/wrist Transforms; returns hand CFrame.
local function poseArmIK(arm: Limb, parentCF: CFrame, target: Vector3, pole: Vector3, side: Vector3): CFrame
	local j1, j2 = arm.j1, arm.j2
	local s = (parentCF * j1.C0).Position
	local elbow, wrist = solveElbow(s, target, pole, arm.len1, arm.len2)
	local upperCF = alignSegment(j1.C1.Position, j2.C0.Position, s, elbow, side)
	j1.Transform = (parentCF * j1.C0):Inverse() * upperCF * j1.C1
	local j3 = arm.j3
	local lowerEnd = if j3 then j3.C0.Position else j2.C1.Position + V3(0, -arm.len2, 0)
	local lowerCF = alignSegment(j2.C1.Position, lowerEnd, elbow, wrist, side)
	j2.Transform = (upperCF * j2.C0):Inverse() * lowerCF * j2.C1
	if j3 then
		j3.Transform = IDENTITY
		return lowerCF * j3.C0 * j3.C1:Inverse()
	end
	return lowerCF
end

local function setAngles(arm: Limb, a1: CFrame, a2: CFrame, a3: CFrame?)
	arm.j1.Transform = a1
	arm.j2.Transform = a2
	local j3 = arm.j3
	if j3 then
		j3.Transform = a3 or IDENTITY
	end
end

--------------------------------------------------------------------------------------------------
-- Rig lifecycle
--------------------------------------------------------------------------------------------------

local function disableAnimate(character: Model)
	local animate = character:FindFirstChild("Animate")
	if animate and (animate:IsA("LocalScript") or animate:IsA("Script")) then
		animate.Enabled = false
		if player.Character == character then
			pcall(animate.Destroy, animate)
		end
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, track in animator:GetPlayingAnimationTracks() do
			track:Stop(0)
		end
	end
end

local function buildRig(character: Model): Rig?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local rootJoint = motor(character, "LowerTorso", "Root")
	local waist = motor(character, "UpperTorso", "Waist")
	if not (humanoid and root and root:IsA("BasePart") and rootJoint and waist) then
		return nil
	end
	local rArm, lArm = limb(character, "Right", true), limb(character, "Left", true)
	local rLeg, lLeg = limb(character, "Right", false), limb(character, "Left", false)
	if not (rArm and lArm and rLeg and lLeg) then
		return nil
	end
	local owner = Players:GetPlayerFromCharacter(character)
	local rootHeight = humanoid.HipHeight + root.Size.Y / 2 + rootJoint.C0.Position.Y
	local legLen = rLeg.len1 + rLeg.len2
	return {
		character = character,
		owner = owner,
		isLocal = owner == player,
		humanoid = humanoid,
		root = root,
		rootJoint = rootJoint,
		waist = waist,
		neck = motor(character, "Head", "Neck"),
		rArm = rArm,
		lArm = lArm,
		rLeg = rLeg,
		lLeg = lLeg,
		rootHeight = math.max(rootHeight, 1),
		crouchDrop = legLen * 0.42,
		phase = 0,
		pitch = 0,
		crouchA = 0,
		proneA = 0,
		sprintA = 0,
		seatA = 0,
		accum = 0,
		frame = math.random(0, 11), -- stagger LOD buckets (lcm of MID/FAR/OFFSCREEN steps)
		weaponHidden = false,
		lastWeapon = nil,
		weaponGrip = nil,
		weaponHandle = nil,
		weaponHold = nil,
		weaponRearZ = 1,
		weaponGripLocal = V3(0, -0.1, 0.3),
		weaponSupportLocal = V3(0, -0.07, -0.6),
	}
end

local function trackCharacter(character: Model)
	if rigs[character] then
		return
	end
	task.spawn(function()
		-- wait for the R15 joints to stream in
		for _ = 1, 40 do
			if
				character.Parent == nil
				or (
					motor(character, "LowerTorso", "Root")
					and motor(character, "RightFoot", "RightAnkle")
					and motor(character, "LeftHand", "LeftWrist")
				)
			then
				break
			end
			task.wait(0.25)
		end
		if character.Parent == nil then
			return
		end
		disableAnimate(character)
		local rig = buildRig(character)
		if rig then
			rigs[character] = rig
		end
	end)
	-- Animate may be inserted after CharacterAdded
	local conn
	conn = character.ChildAdded:Connect(function(child)
		if child.Name == "Animate" then
			task.defer(disableAnimate, character)
		end
	end)
	task.delay(6, function()
		conn:Disconnect()
	end)
end

local function untrack(character: Model)
	rigs[character] = nil
end

--------------------------------------------------------------------------------------------------
-- Weapon helpers
--------------------------------------------------------------------------------------------------

local function findWeapon(character: Model): (Model?, Motor6D?, BasePart?)
	local model = character:FindFirstChild("EquippedWeaponModel")
	if not (model and model:IsA("Model")) then
		return nil, nil, nil
	end
	local handle = model.PrimaryPart or model:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		return nil, nil, nil
	end
	local grip = handle:FindFirstChild("WeaponGrip")
	if grip and grip:IsA("Motor6D") then
		return model, grip, handle
	end
	return model, nil, handle
end

local function attachmentPos(handle: BasePart, name: string, default: Vector3): Vector3
	local a = handle:FindFirstChild(name)
	if a and a:IsA("Attachment") then
		return a.Position
	end
	return default
end

local function setModelHidden(model: Model, hidden: boolean)
	local v = if hidden then 1 else 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = v
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Footsteps for remote characters
--------------------------------------------------------------------------------------------------

local function remoteFootstep(rig: Rig, stance: string)
	local vol = STEP_VOLUME[stance] or 0.5
	if vol <= 0 then
		return
	end
	local sound = getController("SoundController")
	if not (sound and type(sound.PlayAt) == "function") then
		return
	end
	rayParams.FilterDescendantsInstances = { rig.character }
	local origin = rig.root.Position
	local hit = workspace:Raycast(origin, V3(0, -(rig.rootHeight + 2), 0), rayParams)
	if not hit then
		return
	end
	local key = FOOTSTEP_KEYS[hit.Material] or "Footstep_Default"
	pcall(sound.PlayAt, key, hit.Position, { volume = vol, pitch = 0.92 + math.random() * 0.16 })
end

--------------------------------------------------------------------------------------------------
-- Pose
--------------------------------------------------------------------------------------------------

local function poseRig(rig: Rig, dt: number, camPos: Vector3)
	local character, humanoid, root = rig.character, rig.humanoid, rig.root

	-- inputs
	local pitch, stance = 0, "Stand"
	if rig.isLocal then
		local camera = workspace.CurrentCamera
		if camera then
			pitch = math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1))
		end
		local movement = getController("MovementController")
		if movement and type(movement.GetStance) == "function" then
			local ok, s = pcall(movement.GetStance)
			if ok and type(s) == "string" then
				stance = s
			end
		end
	else
		local p = character:GetAttribute("AimPitch")
		pitch = if type(p) == "number" then p else 0
		local s = character:GetAttribute("Stance")
		stance = if type(s) == "string" then s else "Stand"
	end
	local owner = rig.owner
	local seated = humanoid.Sit or (owner ~= nil and (owner:GetAttribute("VehicleUid") or "") ~= "")

	local k = 1 - math.exp(-dt * 8)
	rig.pitch += (pitch - rig.pitch) * (1 - math.exp(-dt * 15))
	rig.crouchA += ((if stance == "Crouch" and not seated then 1 else 0) - rig.crouchA) * k
	rig.proneA += ((if stance == "Prone" and not seated then 1 else 0) - rig.proneA) * k
	rig.sprintA += ((if stance == "Sprint" and not seated then 1 else 0) - rig.sprintA) * k
	rig.seatA += ((if seated then 1 else 0) - rig.seatA) * (1 - math.exp(-dt * 12))
	local crouchA, proneA, sprintA, seatA = rig.crouchA, rig.proneA, rig.sprintA, rig.seatA
	local standA = 1 - proneA
	local aimPitch = rig.pitch

	-- locomotion
	local vel = root.AssemblyLinearVelocity
	local localVel = root.CFrame:VectorToObjectSpace(vel)
	local speed = Vector3.new(localVel.X, 0, localVel.Z).Magnitude
	local grounded = if rig.isLocal then humanoid.FloorMaterial ~= Enum.Material.Air else math.abs(vel.Y) < 8
	local moving = speed > 0.6 and grounded and seatA < 0.5
	local prevPhase = rig.phase
	if moving then
		rig.phase = (rig.phase + dt * speed * STRIDE_RATE * (if proneA > 0.5 then 0.8 else 1)) % (math.pi * 2)
	end
	local fwd, side = 0, 0
	if speed > 0.3 then
		fwd, side = -localVel.Z / speed, localVel.X / speed
	end
	local amp = (if moving then math.clamp(speed / Constants.WALK_SPEED, 0, 1.4) else 0)
		* (0.5 + 0.3 * sprintA)
		* (1 - 0.45 * crouchA)
	local swing = math.sin(rig.phase)

	-- footsteps at foot plants (phase crosses 0 or pi)
	if moving and not rig.isLocal and (root.Position - camPos).Magnitude < FOOTSTEP_DISTANCE then
		local half = math.pi
		if math.floor(prevPhase / half) ~= math.floor(rig.phase / half) then
			remoteFootstep(rig, stance)
		end
	end

	-- root / torso
	local lean = 0.2 * crouchA + 0.16 * sprintA
	local drop = rig.crouchDrop * crouchA * standA + (rig.rootHeight - 0.55) * proneA
	local rootT = CF(0, -drop, 0) * ANG(-lean * standA - proneA * math.pi / 2, 0, 0)
	rig.rootJoint.Transform = rootT
	local waistPitch = aimPitch * 0.4 * standA + lean * 0.5 * crouchA + 0.3 * proneA
	local waistT = ANG(waistPitch, 0, 0)
	rig.waist.Transform = waistT
	local neck = rig.neck
	if neck then
		neck.Transform = ANG(aimPitch * 0.45 * standA + proneA * (1.15 + aimPitch * 0.4), 0, 0)
	end

	-- legs
	local legLen = rig.rLeg.len1 + rig.rLeg.len2
	local crouchT = math.acos(math.clamp(1 - rig.crouchDrop * crouchA / legLen, -1, 1))
	local thighBase = (crouchT + lean) * standA
	local kneeBase = -2 * crouchT * standA
	local ankleBase = crouchT * standA
	if seatA > 0.01 then
		thighBase += 1.5 * seatA
		kneeBase -= 1.5 * seatA
	end
	if not grounded and seatA < 0.5 then
		thighBase += 0.35
		kneeBase -= 0.7
	end
	local swingX = amp * fwd * standA
	local swingZ = amp * 0.6 * side * standA
	local kneeR = -amp * 0.9 * math.max(0, math.sin(rig.phase + 1.3)) * standA
	local kneeL = -amp * 0.9 * math.max(0, math.sin(rig.phase + math.pi + 1.3)) * standA
	local crawl = if proneA > 0.5 and moving then 0.3 else 0
	setAngles(
		rig.rLeg,
		ANG(thighBase + swingX * swing + crawl * swing, 0, -swingZ * swing - 0.12 * proneA),
		ANG(kneeBase + kneeR - crawl * math.max(0, swing), 0, 0),
		ANG(ankleBase, 0, 0)
	)
	setAngles(
		rig.lLeg,
		ANG(thighBase - swingX * swing - crawl * swing, 0, swingZ * swing + 0.12 * proneA),
		ANG(kneeBase + kneeL - crawl * math.max(0, -swing), 0, 0),
		ANG(ankleBase, 0, 0)
	)

	-- upper-body world frames (computed analytically from this frame's transforms)
	local ltCF = root.CFrame * rig.rootJoint.C0 * rootT * rig.rootJoint.C1:Inverse()
	local utCF = ltCF * rig.waist.C0 * waistT * rig.waist.C1:Inverse()

	-- weapon (the model/joint/attachment lookups are cached per weapon model; only the cheap
	-- identity check runs every frame)
	local weaponModel = rig.lastWeapon
	if not (weaponModel and weaponModel.Parent == character and rig.weaponGrip and rig.weaponGrip.Parent) then
		local m, g, h = findWeapon(character)
		weaponModel = m
		if m ~= rig.lastWeapon or g ~= rig.weaponGrip then
			rig.lastWeapon = m
			rig.weaponHidden = false
			rig.weaponGrip = g
			rig.weaponHandle = h
			if m and h then
				rig.weaponHold = m:GetAttribute("Hold")
				rig.weaponRearZ = tonumber(m:GetAttribute("RearZ")) or 1
				rig.weaponGripLocal = attachmentPos(h, "Grip", V3(0, -0.1, 0.3))
				rig.weaponSupportLocal = attachmentPos(h, "Support", V3(0, -0.07, -0.6))
			end
		end
	end
	local gripJoint, handle = rig.weaponGrip, rig.weaponHandle
	if weaponModel and (seatA > 0.5) ~= rig.weaponHidden then
		rig.weaponHidden = seatA > 0.5
		setModelHidden(weaponModel, rig.weaponHidden)
	end

	local bodyRot = root.CFrame.Rotation
	local right = bodyRot.RightVector
	if weaponModel and gripJoint and handle and seatA < 0.5 then
		local hold = rig.weaponHold
		local rearZ = rig.weaponRearZ
		local gripLocal = rig.weaponGripLocal
		local supportLocal = rig.weaponSupportLocal
		local neckBase = if neck then (utCF * neck.C0).Position else (utCF * CF(0, 0.8, 0)).Position
		local aimFrame = CF(neckBase) * bodyRot * ANG(aimPitch, 0, 0)
		local lowFrame = CF(neckBase) * bodyRot * ANG(aimPitch * 0.3, 0, 0)

		local aimCF: CFrame
		if hold == "Pistol" then
			aimCF = aimFrame * CF(0.25, -0.3, -1.55)
		elseif hold == "Launcher" then
			aimCF = aimFrame * CF(0.62, -0.62, 0.55 - rearZ)
		elseif hold == "Rifle" or hold == "MG" or hold == nil then
			aimCF = aimFrame * CF(0.45, -0.32, 0.12 - rearZ)
		else -- Throwable / Melee / Gadget / Binoculars: low ready
			aimCF = lowFrame * CF(0.55, -1.0, -0.85) * CF(-gripLocal)
		end
		if sprintA > 0.01 and (hold == "Rifle" or hold == "MG" or hold == "Launcher" or hold == nil) then
			local portCF = CF(neckBase)
				* bodyRot
				* CF(0.25, -0.9, -0.7)
				* ANG(0, 1.1, 0)
				* ANG(0.55, 0, 0)
				* CF(-gripLocal)
			aimCF = aimCF:Lerp(portCF, sprintA)
		elseif sprintA > 0.01 and hold == "Pistol" then
			aimCF = aimCF:Lerp(lowFrame * CF(0.45, -1.1, -0.7) * ANG(-0.9, 0, 0), sprintA)
		end

		local rightTarget = (aimCF * CF(gripLocal)).Position
		local leftTarget = (aimCF * CF(supportLocal)).Position
		local down = -bodyRot.UpVector
		local back = bodyRot.LookVector * -1
		local handCF =
			poseArmIK(rig.rArm, utCF, rightTarget, rightTarget + right * 1.2 + down * 1.5 + back * 0.4, right)
		poseArmIK(rig.lArm, utCF, leftTarget, leftTarget - right * 1.2 + down * 1.6 + back * 0.2, right)
		gripJoint.Transform = (handCF * gripJoint.C0):Inverse() * aimCF * gripJoint.C1
	else
		-- unarmed (or seated): free arms
		local armSwing = amp * 0.9 * fwd * standA
		local shoulderBase = 0.55 * seatA + 2.6 * proneA
		setAngles(
			rig.rArm,
			ANG(shoulderBase - armSwing * swing, 0, 0.05),
			ANG(0.25 + 0.5 * seatA + 0.4 * sprintA, 0, 0)
		)
		setAngles(
			rig.lArm,
			ANG(shoulderBase + armSwing * swing, 0, -0.05),
			ANG(0.25 + 0.5 * seatA + 0.4 * sprintA, 0, 0)
		)
		if gripJoint then
			gripJoint.Transform = IDENTITY
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Frame loop
--------------------------------------------------------------------------------------------------

local function step(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	frameCounter += 1
	debug.profilebegin("WW2CharacterAnim")
	local camCF = camera.CFrame
	local camPos = camCF.Position
	local camLook = camCF.LookVector
	for character, rig in rigs do
		if character.Parent == nil then
			rigs[character] = nil
			continue
		end
		local humanoid = rig.humanoid
		if humanoid.Health <= 0 or not rig.root.Parent then
			continue -- ragdoll owns the body now
		end
		local offset = rig.root.Position - camPos
		local dist = offset.Magnitude
		if dist > FAR_DISTANCE and not rig.isLocal then
			continue
		end
		rig.accum += dt
		if dist > CLOSE_DISTANCE and not rig.isLocal then
			local every = if dist > NEAR_DISTANCE then FAR_STEP else MID_STEP
			if offset:Dot(camLook) < OFFSCREEN_DOT * dist then
				every = OFFSCREEN_STEP
			end
			rig.frame += 1
			if rig.frame % every ~= 0 then
				continue
			end
		end
		local ok, err = pcall(poseRig, rig, math.min(rig.accum, 0.2), camPos)
		rig.accum = 0
		if not ok then
			warn(`[CharacterAnimController] pose failed for {character.Name}: {err}`)
			rigs[character] = nil
		end
	end
	debug.profileend()
end

--------------------------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------------------------

local function onPlayer(p: Player)
	p.CharacterAdded:Connect(trackCharacter)
	p.CharacterRemoving:Connect(untrack)
	if p.Character then
		trackCharacter(p.Character)
	end
end

function CharacterAnimController:Init() end

function CharacterAnimController:Start()
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	RunService:BindToRenderStep("WW2CharacterAnim", RENDER_PRIORITY, step)
end

-- Debug/inspection helper: number of characters currently posed.
function CharacterAnimController.GetTrackedCount(): number
	local n = 0
	for _ in rigs do
		n += 1
	end
	return n
end

return CharacterAnimController
