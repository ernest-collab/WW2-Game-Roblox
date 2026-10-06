--[[
	CameraController (Animation/Models team, client)

	* Forced first person while deployed on foot (Player.CameraMode = LockFirstPerson); classic
	  third person in vehicles / when dead / when SetFirstPerson(false).
	* Free mouse while a UIController menu is open (a Modal button unlocks the cursor even in
	  LockFirstPerson).
	* Recoil: AddRecoil(pitchDeg, yawDeg) rotates the aim through a spring; ~55% of each kick
	  recovers once firing stops, the rest stays (the player pulls down to compensate).
	* Shake(magnitude, duration): perlin noise, decaying; Combat_Damaged flinch; FX_Explosion
	  proximity shake. Shake/flinch are temporary offsets, undone before the default camera
	  updates so they never drift the aim.
	* FOV: SettingsController.Get("FieldOfView") (default 80) + keyed offsets (SetFovOffset),
	  smoothly blended.
	* Death cam: on death the camera orbits the ragdoll, then turns toward the killer.

	Render order: pre-step at Camera-1 (undo temp offset, apply recoil), post-step at Camera+1
	(temp offset, FOV, death cam). ViewmodelController renders at Camera+2.

	API: AddRecoil, Shake, SetFovOffset, SetFirstPerson, IsFirstPerson() -> boolean, GetBaseFov()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)
local Spring = require(Shared.WeaponModels.Spring)

local CameraController = {}

local player = Players.LocalPlayer

local PRE_PRIORITY = Enum.RenderPriority.Camera.Value - 1
local POST_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local DEFAULT_FOV = 80
local RECOIL_RECOVER_FRACTION = 0.55
local RECOIL_RECOVER_DELAY = 0.12
local RECOIL_RECOVER_RATE = 7 -- 1/s exponential
local MAX_PITCH = math.rad(80)
local MAX_SHAKE = 6
local DEATH_CAM_TIME = 4.5
local KILLER_LOOK_DELAY = 1.3

-- State
local firstPersonEnabled = true
local appliedFirstPerson: boolean? = nil
local menusOpen: { [string]: boolean } = {}
local menuCount = 0
local inVehicle = false
local baseFov = DEFAULT_FOV
local currentFov = DEFAULT_FOV
local fovOffsets: { [string]: number } = {}

-- Recoil: spring follows (permanent + recoverable) target; deltas are applied to the camera.
local recoilSpring = Spring.new(Vector3.zero, 26, 0.85) -- x = pitch deg, y = yaw deg
local recoverable = Vector3.zero
local permanent = Vector3.zero
local lastRecoilApplied = Vector3.zero
local lastRecoilTime = 0

-- Temporary offsets (shake + flinch)
type ShakeEntry = { magnitude: number, duration: number, t0: number, seed: number }
local shakes: { ShakeEntry } = {}
local flinchSpring = Spring.new(Vector3.zero, 16, 0.45) -- x = pitch rad, y = yaw rad, z = roll rad
local lastTempOffset = CFrame.identity

-- Death cam
local deathCam: { t0: number, character: Model, killer: Player?, active: boolean }? = nil
local modalGui: ScreenGui? = nil
local modalButton: TextButton? = nil

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
	return menuCount > 0
end

local function readBaseFov()
	local settings = getController("SettingsController")
	if settings and type(settings.Get) == "function" then
		local ok, v = pcall(settings.Get, "FieldOfView")
		if ok and type(v) == "number" and v >= 30 and v <= 120 then
			baseFov = v
			return
		end
	end
	baseFov = DEFAULT_FOV
end

local function aliveHumanoid(): Humanoid?
	local character = player.Character
	local h = character and character:FindFirstChildOfClass("Humanoid")
	if h and h.Health > 0 then
		return h
	end
	return nil
end

-- Mode ----------------------------------------------------------------------------------------

local function wantFirstPerson(): boolean
	if not firstPersonEnabled or inVehicle or deathCam then
		return false
	end
	if (player:GetAttribute("VehicleUid") or "") ~= "" then
		return false
	end
	return aliveHumanoid() ~= nil
end

local function applyMode()
	local want = wantFirstPerson()
	if want == appliedFirstPerson then
		return
	end
	appliedFirstPerson = want
	if want then
		player.CameraMode = Enum.CameraMode.LockFirstPerson
	else
		player.CameraMode = Enum.CameraMode.Classic
		-- leaving LockFirstPerson keeps the zoom at 0.5; push the camera back out once
		local prevMin = player.CameraMinZoomDistance
		player.CameraMinZoomDistance = math.min(8, player.CameraMaxZoomDistance)
		task.delay(0.1, function()
			player.CameraMinZoomDistance = math.min(prevMin, 0.5)
		end)
	end
end

local function updateMouse()
	local open = isMenuOpen()
	if modalButton and modalButton.Visible ~= open then
		modalButton.Visible = open
	end
	local fp = appliedFirstPerson == true
	local wantIcon = open or not fp
	if UserInputService.MouseIconEnabled ~= wantIcon then
		UserInputService.MouseIconEnabled = wantIcon
	end
end

-- Recoil + temporary offsets ------------------------------------------------------------------

local function rotateCamera(camera: Camera, pitch: number, yaw: number)
	if pitch == 0 and yaw == 0 then
		return
	end
	local cf = camera.CFrame
	local _, curYaw, _ = cf:ToEulerAnglesYXZ()
	local curPitch = math.asin(math.clamp(cf.LookVector.Y, -1, 1))
	local newPitch = math.clamp(curPitch + pitch, -MAX_PITCH, MAX_PITCH)
	camera.CFrame = CFrame.new(cf.Position) * CFrame.fromEulerAnglesYXZ(newPitch, curYaw + yaw, 0)
end

local function preRender(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	-- 1) undo last frame's temporary offset so the default camera never integrates it
	if lastTempOffset ~= CFrame.identity then
		camera.CFrame = camera.CFrame * lastTempOffset:Inverse()
		lastTempOffset = CFrame.identity
	end

	-- 2) recoil (persistent aim change through a spring)
	local now = os.clock()
	if now - lastRecoilTime > RECOIL_RECOVER_DELAY and recoverable.Magnitude > 1e-4 then
		recoverable *= math.exp(-RECOIL_RECOVER_RATE * dt)
		if recoverable.Magnitude < 1e-3 then
			recoverable = Vector3.zero
		end
	end
	recoilSpring.Target = permanent + recoverable
	local pos = recoilSpring:Update(dt)
	local delta = pos - lastRecoilApplied
	lastRecoilApplied = pos
	if camera.CameraType ~= Enum.CameraType.Scriptable and (math.abs(delta.X) > 1e-5 or math.abs(delta.Y) > 1e-5) then
		rotateCamera(camera, math.rad(delta.X), math.rad(delta.Y))
	end
	-- rebase accumulators once settled so numbers stay small
	if
		recoverable == Vector3.zero
		and (recoilSpring.Velocity :: Vector3).Magnitude < 1e-3
		and (pos - permanent).Magnitude < 1e-3
		and permanent ~= Vector3.zero
	then
		-- everything has been applied to the camera already; restart from zero
		recoilSpring:Reset(Vector3.zero)
		permanent = Vector3.zero
		lastRecoilApplied = Vector3.zero
	end
end

local function computeTempOffset(now: number, dt: number): CFrame
	local amp = 0
	local i = 1
	while i <= #shakes do
		local s = shakes[i]
		local t = (now - s.t0) / s.duration
		if t >= 1 then
			table.remove(shakes, i)
		else
			amp += s.magnitude * (1 - t) * (1 - t)
			i += 1
		end
	end
	amp = math.min(amp, MAX_SHAKE)
	local flinch = flinchSpring:Update(dt)
	local px, py, pr = flinch.X, flinch.Y, flinch.Z
	if amp > 1e-3 then
		local f = now * 18
		local a = math.rad(amp)
		px += math.noise(f, 0.1, 3.7) * a
		py += math.noise(4.2, f, 0.3) * a
		pr += math.noise(1.3, 7.7, f) * a * 0.6
	end
	if math.abs(px) + math.abs(py) + math.abs(pr) < 1e-5 then
		return CFrame.identity
	end
	return CFrame.fromEulerAnglesYXZ(px, py, pr)
end

local function updateDeathCam(camera: Camera, now: number, dt: number)
	local dc = deathCam
	if not dc then
		return
	end
	local elapsed = now - dc.t0
	local head = dc.character:FindFirstChild("Head") or dc.character:FindFirstChild("HumanoidRootPart")
	if elapsed > DEATH_CAM_TIME or not (head and head:IsA("BasePart")) or not dc.character.Parent then
		deathCam = nil
		if camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
		end
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	local focus = head.Position
	local orbit = elapsed * 0.35
	local desiredPos = focus + Vector3.new(math.cos(orbit) * 7, 4.5, math.sin(orbit) * 7)
	local lookAt = focus
	local killerChar = dc.killer and dc.killer.Character
	local killerRoot = killerChar and killerChar:FindFirstChild("HumanoidRootPart")
	if elapsed > KILLER_LOOK_DELAY and killerRoot and killerRoot:IsA("BasePart") then
		local w = math.clamp((elapsed - KILLER_LOOK_DELAY) / 1.2, 0, 1)
		w = w * w * (3 - 2 * w)
		lookAt = focus:Lerp(killerRoot.Position, w)
		desiredPos = desiredPos:Lerp(focus + Vector3.new(0, 4, 0) - (killerRoot.Position - focus).Unit * 5, w * 0.6)
	end
	local a = 1 - math.exp(-dt * 4)
	local pos = camera.CFrame.Position:Lerp(desiredPos, a)
	camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(pos, lookAt), a * 1.5)
end

local function postRender(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local now = os.clock()
	applyMode()
	updateMouse()

	if deathCam then
		updateDeathCam(camera, now, dt)
	end

	-- temporary shake/flinch on top of whatever the camera produced this frame
	local temp = computeTempOffset(now, dt)
	if temp ~= CFrame.identity and camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CFrame = camera.CFrame * temp
		lastTempOffset = temp
	end

	-- FOV (VehicleController owns the FOV while seated: gunner sight zoom)
	if inVehicle then
		currentFov = camera.FieldOfView
		return
	end
	local target = baseFov
	for _, d in fovOffsets do
		target += d
	end
	target = math.clamp(target, 8, 120)
	currentFov += (target - currentFov) * (1 - math.exp(-dt * 14))
	if math.abs(camera.FieldOfView - currentFov) > 0.01 then
		camera.FieldOfView = currentFov
	end
end

-- Events --------------------------------------------------------------------------------------

local function onExplosion(payload: any)
	if type(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local radius = math.max(tonumber(payload.radius) or 12, 2)
	local dist = (camera.CFrame.Position - payload.position).Magnitude
	local kindScale = ({ grenade = 1, shell = 1.4, rocket = 1.15, satchel = 1.5, vehicle = 1.3 })[payload.kind] or 1
	local falloff = math.clamp(1 - dist / (radius * 5), 0, 1)
	local intensity = falloff * falloff * kindScale * 4
	if intensity > 0.05 then
		CameraController.Shake(intensity, 0.35 + intensity * 0.18)
		if falloff > 0.6 then
			flinchSpring:Impulse(
				Vector3.new((math.random() - 0.3) * 0.25, (math.random() - 0.5) * 0.2, (math.random() - 0.5) * 0.3)
					* falloff
			)
		end
	end
end

local function onDamaged(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local amount = math.clamp(tonumber(payload.amount) or 10, 0, 100)
	local camera = workspace.CurrentCamera
	local strength = 0.05 + amount / 100 * 0.35
	local yawSign = (math.random() < 0.5) and -1 or 1
	if camera and typeof(payload.fromPosition) == "Vector3" then
		local rel = camera.CFrame:PointToObjectSpace(payload.fromPosition)
		yawSign = if rel.X > 0 then -1 else 1 -- flinch away from the shooter
	end
	flinchSpring:Impulse(Vector3.new(strength * 2.2, yawSign * strength * 1.4, yawSign * strength * 1.8))
	CameraController.Shake(0.25 + amount / 100 * 1.5, 0.25)
end

local function onDied(character: Model)
	deathCam = { t0 = os.clock(), character = character, killer = nil, active = true }
	recoverable = Vector3.zero
	table.clear(shakes)
end

local function hookCharacter(character: Model)
	deathCam = nil
	local camera = workspace.CurrentCamera
	if camera and camera.CameraType == Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Custom
	end
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		if camera then
			camera.CameraSubject = humanoid
		end
		humanoid.Died:Connect(function()
			if player.Character == character then
				onDied(character)
			end
		end)
	end
end

-- API -----------------------------------------------------------------------------------------

function CameraController.AddRecoil(pitchDeg: number, yawDeg: number)
	local p, y = tonumber(pitchDeg) or 0, tonumber(yawDeg) or 0
	recoverable += Vector3.new(p * RECOIL_RECOVER_FRACTION, y * RECOIL_RECOVER_FRACTION, 0)
	permanent += Vector3.new(p * (1 - RECOIL_RECOVER_FRACTION), y * (1 - RECOIL_RECOVER_FRACTION), 0)
	lastRecoilTime = os.clock()
end

function CameraController.Shake(magnitude: number, duration: number)
	local m, d = tonumber(magnitude) or 0, tonumber(duration) or 0
	if m <= 0 or d <= 0 then
		return
	end
	if #shakes >= 16 then
		table.remove(shakes, 1)
	end
	table.insert(shakes, { magnitude = m, duration = d, t0 = os.clock(), seed = math.random() * 100 })
end

function CameraController.SetFovOffset(key: string, delta: number?)
	if type(key) ~= "string" then
		return
	end
	if delta == nil or delta == 0 then
		fovOffsets[key] = nil
	else
		fovOffsets[key] = delta
	end
end

function CameraController.SetFirstPerson(enabled: boolean)
	firstPersonEnabled = enabled == true
end

function CameraController.IsFirstPerson(): boolean
	return appliedFirstPerson == true
end

function CameraController.GetBaseFov(): number
	return baseFov
end

-- Lifecycle -----------------------------------------------------------------------------------

function CameraController:Init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "CameraMouseUnlock"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -100
	local button = Instance.new("TextButton")
	button.Name = "Modal"
	button.Modal = true
	button.Visible = false
	button.Text = ""
	button.BackgroundTransparency = 1
	button.Size = UDim2.fromOffset(0, 0)
	button.Parent = gui
	modalGui = gui
	modalButton = button
end

function CameraController:Start()
	local playerGui = player:WaitForChild("PlayerGui")
	if modalGui then
		modalGui.Parent = playerGui
	end
	readBaseFov()
	currentFov = baseFov

	Bus.connect("SettingsChanged", readBaseFov)
	Bus.connect("MenuOpened", function(name)
		local key = tostring(name)
		if not menusOpen[key] then
			menusOpen[key] = true
			menuCount += 1
		end
	end)
	Bus.connect("MenuClosed", function(name)
		local key = tostring(name)
		if menusOpen[key] then
			menusOpen[key] = nil
			menuCount -= 1
		end
	end)
	Bus.connect("VehicleEntered", function()
		inVehicle = true
	end)
	Bus.connect("VehicleExited", function()
		inVehicle = false
	end)
	Bus.connect("Deployed", function()
		deathCam = nil
	end)

	player.CharacterAdded:Connect(hookCharacter)
	if player.Character then
		task.spawn(hookCharacter, player.Character)
	end

	RunService:BindToRenderStep("WW2CameraPre", PRE_PRIORITY, preRender)
	RunService:BindToRenderStep("WW2CameraPost", POST_PRIORITY, postRender)

	-- Remotes (each may yield until the server creates it)
	task.spawn(function()
		Net.event("FX_Explosion").OnClientEvent:Connect(onExplosion)
	end)
	task.spawn(function()
		Net.event("Combat_Damaged").OnClientEvent:Connect(onDamaged)
	end)
	task.spawn(function()
		Net.event("Player_Died").OnClientEvent:Connect(function(payload)
			local dc = deathCam
			if
				dc
				and type(payload) == "table"
				and typeof(payload.killer) == "Instance"
				and payload.killer:IsA("Player")
			then
				if payload.killer ~= player then
					dc.killer = payload.killer
				end
			end
		end)
	end)
end

return CameraController
