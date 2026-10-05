--[[
	MovementController (Animation/Models team, client)

	Infantry locomotion for the local character:
	  * Sprint (hold Shift / toggle L3) with stamina; blocked while aiming, while another system
	    calls SetSprintBlocked(true) (e.g. reloading), while crouched-sliding or in menus.
	  * Crouch (toggle C / B) and Prone (toggle Z). Jump from crouch/prone stands up instead.
	  * Slide: pressing crouch while sprinting gives a short decaying burst of speed.
	  * WalkSpeed = Constants stance speed x class speedMultiplier (player attribute Class +
	    Classes config) x weapon walkSpeedMult (EquippedWeapon + Weapons config) x ADS mult.
	  * Camera height per stance via Humanoid.CameraOffset (smoothed).
	  * Bus "StanceChanged"(stance) on change; `Anim_State` {pitch, stance} to the server at
	    <= 15 Hz, only when something changed.
	  * Footsteps via SoundController.PlayAt("Footstep_<Material>") keyed by FloorMaterial.

	API: GetStance() -> "Stand"|"Crouch"|"Prone"|"Sprint", IsSprinting(), SetSprintBlocked(bool),
	     GetStamina() -> 0..1, IsSliding(), GetBaseStance() -> "Stand"|"Crouch"|"Prone"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)
local Constants = require(Shared.Config.Constants)
local Classes = require(Shared.Config.Classes)
local Keybinds = require(Shared.Config.Keybinds)
local WeaponModels = require(Shared.WeaponModels)

local MovementController = {}

local player = Players.LocalPlayer

-- Tunables
local SEND_INTERVAL = 1 / 15
local PITCH_EPSILON = 0.025
local STAMINA_DRAIN = 1 / 7 -- full bar lasts 7 s of sprinting
local STAMINA_REGEN = 1 / 4
local STAMINA_REGEN_DELAY = 0.8
local STAMINA_RECOVER_THRESHOLD = 0.3
local SLIDE_TIME = 0.75
local SLIDE_BOOST = 1.4 -- x sprint speed at slide start
local SPRINT_PERK_MULT = 1.08 -- Assault "FasterSprint"
local CAMERA_OFFSETS = {
	Stand = Vector3.new(0, 0, 0),
	Crouch = Vector3.new(0, -1.3, -0.15),
	Prone = Vector3.new(0, -3.1, -1.4),
}
local STRIDE = { Stand = 4.6, Sprint = 6.4, Crouch = 3.4, Prone = 3.0 }
local STEP_VOLUME = { Stand = 0.6, Sprint = 0.95, Crouch = 0.28, Prone = 0.22 }

local FOOTSTEP_KEYS: { [Enum.Material]: string } = {
	[Enum.Material.Grass] = "Footstep_Grass",
	[Enum.Material.LeafyGrass] = "Footstep_Grass",
	[Enum.Material.Ground] = "Footstep_Grass",
	[Enum.Material.Concrete] = "Footstep_Concrete",
	[Enum.Material.Slate] = "Footstep_Concrete",
	[Enum.Material.Brick] = "Footstep_Concrete",
	[Enum.Material.Cobblestone] = "Footstep_Concrete",
	[Enum.Material.Pavement] = "Footstep_Concrete",
	[Enum.Material.Asphalt] = "Footstep_Concrete",
	[Enum.Material.Rock] = "Footstep_Concrete",
	[Enum.Material.Basalt] = "Footstep_Concrete",
	[Enum.Material.Granite] = "Footstep_Concrete",
	[Enum.Material.Marble] = "Footstep_Concrete",
	[Enum.Material.Limestone] = "Footstep_Concrete",
	[Enum.Material.Sandstone] = "Footstep_Concrete",
	[Enum.Material.SmoothPlastic] = "Footstep_Concrete",
	[Enum.Material.Plastic] = "Footstep_Concrete",
	[Enum.Material.Wood] = "Footstep_Wood",
	[Enum.Material.WoodPlanks] = "Footstep_Wood",
	[Enum.Material.Snow] = "Footstep_Snow",
	[Enum.Material.Glacier] = "Footstep_Snow",
	[Enum.Material.Ice] = "Footstep_Snow",
	[Enum.Material.Mud] = "Footstep_Mud",
	[Enum.Material.Sand] = "Footstep_Sand",
	[Enum.Material.Salt] = "Footstep_Sand",
	[Enum.Material.Metal] = "Footstep_Metal",
	[Enum.Material.DiamondPlate] = "Footstep_Metal",
	[Enum.Material.CorrodedMetal] = "Footstep_Metal",
	[Enum.Material.Foil] = "Footstep_Metal",
}

-- State
local character: Model? = nil
local humanoid: Humanoid? = nil
local root: BasePart? = nil
local baseStance = "Stand" -- Stand | Crouch | Prone
local sprinting = false
local sprintHeld = false
local sprintToggled = false -- gamepad
local sprintBlocked = false
local aiming = false
local menuOpen = false
local inVehicle = false
local stamina = 1
local exhausted = false
local lastSprintTime = 0
local slideTimer = 0
local lastJumpRequest = 0
local reportedStance = "Stand"
local stepDistance = 0
local wasAirborne = false
local airborneTime = 0
local lastSentPitch = 999
local lastSentStance = ""
local lastSendTime = 0
local animRemote: UnreliableRemoteEvent? = nil
local currentSpeed = Constants.WALK_SPEED

-- Guarded sibling access ----------------------------------------------------------------------

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

local function isMenuOpen(): boolean
	local ui = getController("UIController")
	if ui and type(ui.IsMenuOpen) == "function" then
		local ok, open = pcall(ui.IsMenuOpen)
		if ok then
			return open == true
		end
	end
	return menuOpen
end

-- Speed multipliers ---------------------------------------------------------------------------

local function classMultiplier(): number
	local classId = player:GetAttribute("Class")
	local def = type(classId) == "string" and Classes.get(classId) or nil
	return def and def.speedMultiplier or 1
end

local function hasPerk(perk: string): boolean
	local classId = player:GetAttribute("Class")
	local def = type(classId) == "string" and Classes.get(classId) or nil
	return def ~= nil and table.find(def.perks, perk) ~= nil
end

local function weaponMultiplier(): number
	local def = WeaponModels.GetConfig(player:GetAttribute("EquippedWeapon"))
	local m = def and tonumber(def.walkSpeedMult)
	return m or 1
end

-- Stance --------------------------------------------------------------------------------------

local function effectiveStance(): string
	if sprinting then
		return "Sprint"
	end
	return baseStance
end

local function publishStance()
	local s = effectiveStance()
	if s ~= reportedStance then
		reportedStance = s
		Bus.fire("StanceChanged", s)
	end
end

local function setBaseStance(s: string)
	if inVehicle and s ~= "Stand" then
		return
	end
	if baseStance == s then
		return
	end
	baseStance = s
	if s ~= "Stand" then
		sprinting = false
	end
	local h = humanoid
	if h then
		h:SetStateEnabled(Enum.HumanoidStateType.Jumping, s == "Stand")
	end
	publishStance()
end

-- Input ---------------------------------------------------------------------------------------

local function inputMatches(input: InputObject, bind: any): boolean
	if bind == nil then
		return false
	end
	if typeof(bind) == "EnumItem" then
		return input.KeyCode == bind or input.UserInputType == bind
	end
	return false
end

local function onCrouchPressed()
	if sprinting and humanoid and humanoid.FloorMaterial ~= Enum.Material.Air then
		-- slide into a crouch
		slideTimer = SLIDE_TIME
		sprinting = false
		setBaseStance("Crouch")
		return
	end
	setBaseStance(if baseStance == "Crouch" then "Stand" else "Crouch")
end

local function onPronePressed()
	slideTimer = 0
	setBaseStance(if baseStance == "Prone" then "Stand" else "Prone")
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if gameProcessed or isMenuOpen() then
		return
	end
	local kb, gp = Keybinds.keyboard, Keybinds.gamepad
	if inputMatches(input, kb.Sprint) then
		sprintHeld = true
	elseif inputMatches(input, gp.Sprint) then
		sprintToggled = not sprintToggled
	elseif inputMatches(input, kb.Crouch) or inputMatches(input, gp.Crouch) then
		onCrouchPressed()
	elseif inputMatches(input, kb.Prone) then
		onPronePressed()
	end
end

local function onInputEnded(input: InputObject)
	if inputMatches(input, Keybinds.keyboard.Sprint) then
		sprintHeld = false
	end
end

local function onJumpRequest()
	local now = os.clock()
	if now - lastJumpRequest < 0.25 then
		return
	end
	lastJumpRequest = now
	if isMenuOpen() then
		return
	end
	if baseStance == "Prone" then
		setBaseStance("Crouch")
	elseif baseStance == "Crouch" then
		slideTimer = 0
		setBaseStance("Stand")
	end
end

-- Character -----------------------------------------------------------------------------------

local function onCharacterAdded(char: Model)
	character = char
	humanoid = char:WaitForChild("Humanoid", 10) :: Humanoid?
	root = char:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	baseStance = "Stand"
	sprinting = false
	slideTimer = 0
	stamina = 1
	exhausted = false
	stepDistance = 0
	lastSentStance = ""
	lastSentPitch = 999
	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid.CameraOffset = Vector3.zero
	end
	publishStance()
end

-- Footsteps -----------------------------------------------------------------------------------

local function playFootstep(material: Enum.Material, position: Vector3, stance: string)
	local sound = getController("SoundController")
	if not (sound and type(sound.PlayAt) == "function") then
		return
	end
	local key = FOOTSTEP_KEYS[material] or "Footstep_Default"
	pcall(sound.PlayAt, key, position, {
		volume = STEP_VOLUME[stance] or 0.5,
		pitch = 0.92 + math.random() * 0.16,
	})
end

local function playKey(key: string, position: Vector3, volume: number)
	local sound = getController("SoundController")
	if sound and type(sound.PlayAt) == "function" then
		pcall(sound.PlayAt, key, position, { volume = volume })
	end
end

-- Per-frame update ----------------------------------------------------------------------------

local function update(dt: number)
	local h, r = humanoid, root
	if not (h and r and character and character.Parent) or h.Health <= 0 then
		return
	end
	inVehicle = (player:GetAttribute("VehicleUid") or "") ~= "" or h.Sit
	if inVehicle and baseStance ~= "Stand" then
		baseStance = "Stand"
	end

	local moveDir = h.MoveDirection
	local moving = moveDir.Magnitude > 0.1
	local grounded = h.FloorMaterial ~= Enum.Material.Air
	local camera = workspace.CurrentCamera
	local look = camera and camera.CFrame.LookVector or r.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	local forwardness = if flatLook.Magnitude > 1e-3 and moving then moveDir:Dot(flatLook.Unit) else 0

	-- Sprint
	local wantsSprint = (sprintHeld or sprintToggled) and moving and forwardness > 0.45
	local canSprint = not sprintBlocked
		and not aiming
		and not inVehicle
		and not exhausted
		and slideTimer <= 0
		and not isMenuOpen()
	local nowSprinting = wantsSprint and canSprint
	if nowSprinting and baseStance ~= "Stand" then
		baseStance = "Stand" -- sprinting stands you up
		h:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
	end
	if sprintToggled and not moving then
		sprintToggled = false
	end
	sprinting = nowSprinting

	-- Stamina
	local now = os.clock()
	if sprinting then
		stamina = math.max(0, stamina - STAMINA_DRAIN * dt)
		lastSprintTime = now
		if stamina <= 0 then
			exhausted = true
			sprinting = false
		end
	elseif now - lastSprintTime > STAMINA_REGEN_DELAY then
		stamina = math.min(1, stamina + STAMINA_REGEN * dt)
		if exhausted and stamina >= STAMINA_RECOVER_THRESHOLD then
			exhausted = false
		end
	end
	publishStance()

	-- Speed
	local speed
	if sprinting then
		speed = Constants.SPRINT_SPEED * (if hasPerk("FasterSprint") then SPRINT_PERK_MULT else 1)
	elseif baseStance == "Crouch" then
		speed = Constants.CROUCH_SPEED
	elseif baseStance == "Prone" then
		speed = Constants.PRONE_SPEED
	else
		speed = Constants.WALK_SPEED
	end
	speed *= classMultiplier() * weaponMultiplier()
	if aiming and not sprinting then
		speed *= Constants.ADS_SPEED_MULT
	end
	if slideTimer > 0 then
		slideTimer -= dt
		local a = math.clamp(slideTimer / SLIDE_TIME, 0, 1)
		local slideSpeed = Constants.SPRINT_SPEED * SLIDE_BOOST
		speed = speed + (slideSpeed - speed) * a * a
		if not grounded then
			slideTimer = 0
		end
	end
	if math.abs(currentSpeed - speed) > 0.01 then
		currentSpeed = speed
	end
	if math.abs(h.WalkSpeed - currentSpeed) > 0.01 then
		h.WalkSpeed = currentSpeed
	end

	-- Camera height
	local target = CAMERA_OFFSETS[baseStance] or Vector3.zero
	if slideTimer > 0 then
		target += Vector3.new(0, -0.35, 0)
	end
	local current = h.CameraOffset
	local alpha = 1 - math.exp(-dt * 10)
	local nextOffset = current:Lerp(target, alpha)
	if (nextOffset - current).Magnitude > 1e-4 then
		h.CameraOffset = nextOffset
	end

	-- Footsteps + landing
	local vel = r.AssemblyLinearVelocity
	local horizontal = Vector3.new(vel.X, 0, vel.Z).Magnitude
	if grounded then
		if wasAirborne and airborneTime > 0.35 then
			playKey("Footstep_Land", r.Position - Vector3.new(0, 2.5, 0), math.clamp(airborneTime, 0.4, 1))
		end
		wasAirborne = false
		airborneTime = 0
		if horizontal > 1 then
			stepDistance += horizontal * dt
			local stance = effectiveStance()
			if stepDistance >= (STRIDE[stance] or 4.6) then
				stepDistance = 0
				playFootstep(h.FloorMaterial, r.Position - Vector3.new(0, 2.8, 0), stance)
			end
		end
	else
		wasAirborne = true
		airborneTime += dt
	end

	-- Network: Anim_State
	local remote = animRemote
	if remote and now - lastSendTime >= SEND_INTERVAL then
		local pitch = math.asin(math.clamp(look.Y, -1, 1))
		local stance = effectiveStance()
		if stance ~= lastSentStance or math.abs(pitch - lastSentPitch) > PITCH_EPSILON then
			lastSendTime = now
			lastSentStance = stance
			lastSentPitch = pitch
			remote:FireServer({ pitch = pitch, stance = stance })
		end
	end
end

-- API -----------------------------------------------------------------------------------------

function MovementController.GetStance(): string
	return effectiveStance()
end

function MovementController.GetBaseStance(): string
	return baseStance
end

function MovementController.IsSprinting(): boolean
	return sprinting
end

function MovementController.IsSliding(): boolean
	return slideTimer > 0
end

function MovementController.GetStamina(): number
	return stamina
end

function MovementController.SetSprintBlocked(blocked: boolean)
	sprintBlocked = blocked == true
	if sprintBlocked then
		sprinting = false
		publishStance()
	end
end

function MovementController.SetStance(stance: string)
	if stance == "Stand" or stance == "Crouch" or stance == "Prone" then
		setBaseStance(stance)
	end
end

-- Lifecycle -----------------------------------------------------------------------------------

function MovementController:Init() end

function MovementController:Start()
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UserInputService.JumpRequest:Connect(onJumpRequest)

	Bus.connect("AimChanged", function(isAiming)
		aiming = isAiming == true
		if aiming then
			sprinting = false
			publishStance()
		end
	end)
	Bus.connect("MenuOpened", function()
		menuOpen = true
		sprintHeld = false
		sprintToggled = false
	end)
	Bus.connect("MenuClosed", function()
		menuOpen = false
	end)
	Bus.connect("VehicleEntered", function()
		inVehicle = true
		setBaseStance("Stand")
	end)
	Bus.connect("VehicleExited", function()
		inVehicle = false
	end)

	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end

	RunService.Heartbeat:Connect(update)

	-- Remote last: Net.event may yield until the server creates it.
	task.spawn(function()
		animRemote = Net.unreliable("Anim_State")
	end)
end

return MovementController
