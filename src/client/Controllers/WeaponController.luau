--[[
	WeaponController (Combat team, client)

	Responsive client-side weapon handling. The server (CombatService) is authoritative for ammo, damage
	and fire rate; this controller predicts ammo/fire locally, does camera-ray hit detection and sends
	the results for server validation.

	  * Input (Keybinds): keyboard/mouse, gamepad, and mobile touch buttons (ContextActionService).
	  * Slots 1-4, V quick knife, G quick grenade, B fire mode, gamepad Y (primary/secondary) and
	    L1 (cycle gadgets).
	  * Fire modes Auto / Semi / Burst / Bolt (bolt cycle time = 60 / rpm).
	  * Spread (hip/ADS, movement, stance, sprint, airborne, sustained-fire bloom) via Util/Ballistics.
	  * Recoil through CameraController.AddRecoil with first-shot multiplier and per-weapon drift.
	  * ADS via ViewmodelController.SetAiming + CameraController.SetFovOffset("ADS", ...); scoped weapons
	    fire Bus "ScopeChanged"(scoped, weaponId) for the UI scope overlay.
	  * Reload (tactical vs empty, single-round for tube/shotguns; sprinting cancels).
	  * Grenades: hold to cook (cookable), release to throw. Launchers fire rockets via Combat_Throw.
	  * Gadget slots forward fire input to GadgetController.Use / SetHolding.
	  * Effects for local shots and other players' Combat_ShotFX.

	Client Bus events fired: WeaponEquipped, WeaponUnequipped, AmmoChanged, AimChanged, Fired,
	ReloadStarted, FireModeChanged, SpreadChanged, ScopeChanged (contract addition).

	Public API (contract addition):
	  WeaponController.GetEquipped() -> (weaponId?, slot?)
	  WeaponController.IsAiming() -> boolean
	  WeaponController.IsReloading() -> boolean
	  WeaponController.GetSpread() -> number            -- current cone half-angle in degrees
	  WeaponController.GetAmmo(weaponId) -> (mag, reserve)
	  WeaponController.GetMoveSpeedMultiplier() -> number  -- weapon walkSpeedMult x ADS multiplier
]]

local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local Keybinds = require(Shared.Config.Keybinds)
local Weapons = require(Shared.Config.Weapons)
local Ballistics = require(Shared.Util.Ballistics)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)
local Trove = require(Shared.Util.Trove)

local WeaponController = {}

local player = Players.LocalPlayer
local KB = Keybinds.keyboard
local GP = Keybinds.gamepad

local SLOT_ORDER = { "primary", "secondary", "gadget1", "gadget2" }
local SHOT_STRING_RESET = 0.35 -- seconds without firing before recoil restarts at "first shot"
local DEFAULT_FOV = 70
local FX_CULL_DISTANCE = 600
local THROW_LOCK = 0.55
local MELEE_ANIM_LOCK = 0.45

-------------------------------------------------------------------------------------------------
-- Sibling controllers (all optional; every call is guarded)
-------------------------------------------------------------------------------------------------

local controllerCache: { [string]: any } = {}
local function getController(name: string): any
	local cached = controllerCache[name]
	if cached ~= nil then
		return cached or nil
	end
	local module = script.Parent:FindFirstChild(name)
	local result: any = false
	if module and module:IsA("ModuleScript") then
		local ok, mod = pcall(require, module)
		if ok and type(mod) == "table" then
			result = mod
		end
	end
	controllerCache[name] = result
	return result or nil
end

-- Calls Controller.method(...) safely; returns the first result or nil.
local function call(name: string, method: string, ...: any): any
	local c = getController(name)
	local fn = c and c[method]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result = pcall(fn, ...)
	if ok then
		return result
	end
	return nil
end

-------------------------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------------------------

type AmmoEntry = { mag: number, reserve: number }

local remotes: { [string]: any } = {}
local loadout: { [string]: string } = {}
local ammo: { [string]: AmmoEntry } = {}
local fireModeIndex: { [string]: number } = {}

local equippedSlot: string? = nil
local equippedId: string? = nil
local def: any = nil
local lastSlot = "primary"

local equipEndsAt = 0
local nextShotAt = 0
local boltUntil = 0
local lastShotAt = 0
local shotIndex = 0
local bloom = 0
local burstLeft = 0
local pendingPress = false -- semi/bolt/burst trigger edge
local triggerHeld = false
local aimHeld = false
local aiming = false
local aimAlphaLocal = 0
local scoped = false
local lastSpread = -1
local currentSpread = 0
local reloading = false
local reloadThread: thread? = nil
local reloadWeapon: string? = nil
local cookStart: number? = nil
local gadgetHolding: string? = nil
local actionLockUntil = 0
local lastMelee = 0
local alive = false

local rng = Random.new()
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local meleeOverlap = OverlapParams.new()
meleeOverlap.FilterType = Enum.RaycastFilterType.Exclude

local spreadParams: Ballistics.SpreadParams = {
	aimAlpha = 0,
	moving = false,
	sprinting = false,
	airborne = false,
	stance = "Stand",
	bloom = 0,
}

local characterTrove = Trove.new()

-------------------------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------------------------

local function now(): number
	return os.clock()
end

local function getCharacter(): (Model?, Humanoid?, BasePart?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil, nil, nil
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	return character,
		hum,
		if root and root:IsA("BasePart") then root else nil,
		if head and head:IsA("BasePart") then head else nil
end

local function inVehicle(): boolean
	local uid = player:GetAttribute("VehicleUid")
	return type(uid) == "string" and uid ~= ""
end

local function menuOpen(): boolean
	return call("UIController", "IsMenuOpen") == true
end

local function inputBlocked(): boolean
	if not alive or inVehicle() or menuOpen() then
		return true
	end
	local _, hum = getCharacter()
	return not hum or hum.Health <= 0
end

local function getStance(): string
	local s = call("MovementController", "GetStance")
	if type(s) == "string" then
		return s
	end
	local character = player.Character
	local attr = character and character:GetAttribute("Stance")
	return if type(attr) == "string" then attr else "Stand"
end

local function isSprinting(): boolean
	local s = call("MovementController", "IsSprinting")
	if type(s) == "boolean" then
		return s
	end
	return getStance() == "Sprint"
end

local function baseFov(): number
	local fov = call("SettingsController", "Get", "FieldOfView")
	return if type(fov) == "number" and fov > 20 then fov else DEFAULT_FOV
end

local function fireMode(): string
	if not def then
		return "Semi"
	end
	local modes = def.fireModes
	return modes[fireModeIndex[def.id] or 1] or modes[1] or "Semi"
end

local function getAimAlpha(): number
	local a = call("ViewmodelController", "GetAimAlpha")
	if type(a) == "number" then
		return a
	end
	return aimAlphaLocal
end

local function fireAmmoChanged()
	if equippedId then
		local entry = ammo[equippedId]
		if entry then
			Bus.fire("AmmoChanged", equippedId, entry.mag, entry.reserve)
		end
	end
end

local function isFirearm(): boolean
	return def ~= nil and Weapons.isFirearm(def)
end

local function isLauncher(): boolean
	return def ~= nil and Weapons.isLauncher(def)
end

local function isThrowable(): boolean
	return def ~= nil and Weapons.isThrown(def)
end

local function isGadget(): boolean
	return def ~= nil and Weapons.isGadget(def)
end

local function canAim(): boolean
	return def ~= nil
		and (isFirearm() or isLauncher() or def.category == "Binoculars")
		and not isThrowable()
		and def.adsZoom < 1
end

local function ensureAmmo(id: string)
	if ammo[id] then
		return
	end
	local w = Weapons.get(id)
	if w then
		ammo[id] = { mag = w.magazine, reserve = w.reserve }
	end
end

-------------------------------------------------------------------------------------------------
-- Aiming
-------------------------------------------------------------------------------------------------

local function setScoped(value: boolean)
	if scoped == value then
		return
	end
	scoped = value
	Bus.fire("ScopeChanged", value, equippedId or "")
end

local function setAiming(value: boolean)
	if value and not canAim() then
		value = false
	end
	if aiming == value then
		return
	end
	aiming = value
	call("ViewmodelController", "SetAiming", value)
	local delta = 0
	if value and def then
		delta = baseFov() * (def.adsZoom - 1)
	end
	call("CameraController", "SetFovOffset", "ADS", delta)
	if not value then
		setScoped(false)
	end
	Bus.fire("AimChanged", value)
end

-------------------------------------------------------------------------------------------------
-- Reloading
-------------------------------------------------------------------------------------------------

local function stopReload(notifyServer: boolean)
	if not reloading then
		return
	end
	reloading = false
	local thread = reloadThread
	reloadThread = nil
	if thread and thread ~= coroutine.running() then
		pcall(task.cancel, thread)
	end
	if notifyServer and reloadWeapon then
		remotes.Reload:FireServer({ weaponId = reloadWeapon, cancel = true })
	end
	reloadWeapon = nil
	call("ViewmodelController", "PlayReload", 0, false) -- 0 duration: let the viewmodel return to idle
end

local function startReload()
	if reloading or not def or not equippedId then
		return
	end
	if not (isFirearm() or isLauncher()) or def.reloadTime <= 0 then
		return
	end
	local entry = ammo[equippedId]
	if not entry or entry.mag >= def.magazine or entry.reserve <= 0 then
		return
	end
	if now() < equipEndsAt then
		return
	end
	local weaponId = equippedId
	local w = def
	local empty = entry.mag == 0
	local duration
	if w.reloadType == "single" then
		local need = math.min(w.magazine - entry.mag, entry.reserve)
		duration = (if empty then w.emptyReloadTime or w.reloadTime else 0) + w.reloadTime * need
	else
		duration = if empty then w.emptyReloadTime or w.reloadTime else w.reloadTime
	end
	reloading = true
	reloadWeapon = weaponId
	burstLeft = 0
	setAiming(false)
	remotes.Reload:FireServer({ weaponId = weaponId })
	Bus.fire("ReloadStarted", weaponId, duration, empty)
	call("ViewmodelController", "PlayReload", duration, empty)
	local reloadSound = if w.reloadType == "single"
		then "Reload_Shell"
		elseif w.reloadType == "clip" then "Reload_Clip"
		else "Reload_Mag"
	call("SoundController", "Play2D", reloadSound, { volume = 0.6 })

	reloadThread = task.spawn(function()
		if w.reloadType == "single" then
			task.wait((if empty then w.emptyReloadTime or w.reloadTime else 0) + w.reloadTime)
			while reloading and entry.mag < w.magazine and entry.reserve > 0 do
				entry.mag += 1
				entry.reserve -= 1
				fireAmmoChanged()
				if entry.mag >= w.magazine or entry.reserve <= 0 then
					break
				end
				task.wait(w.reloadTime)
			end
		else
			task.wait(duration)
			local take = math.min(w.magazine - entry.mag, entry.reserve)
			if take > 0 then
				entry.mag += take
				entry.reserve -= take
			end
			fireAmmoChanged()
		end
		reloading = false
		reloadThread = nil
		reloadWeapon = nil
	end)
end

-------------------------------------------------------------------------------------------------
-- Equip
-------------------------------------------------------------------------------------------------

local function releaseGadgetHold()
	if gadgetHolding then
		call("GadgetController", "SetHolding", gadgetHolding, false)
		gadgetHolding = nil
	end
end

local function localUnequip()
	if not equippedId then
		return
	end
	stopReload(false)
	releaseGadgetHold()
	setAiming(false)
	setScoped(false)
	call("MovementController", "SetSprintBlocked", false)
	call("ViewmodelController", "Unequip")
	equippedId = nil
	equippedSlot = nil
	def = nil
	cookStart = nil
	triggerHeld = false
	pendingPress = false
	burstLeft = 0
	Bus.fire("WeaponUnequipped")
end

local function equipSlot(slot: string, force: boolean?)
	local id = loadout[slot]
	if type(id) ~= "string" or id == "" then
		return
	end
	local w = Weapons.get(id)
	if not w then
		return
	end
	if not force and equippedSlot == slot and equippedId == id then
		return
	end
	if inputBlocked() then
		return
	end
	stopReload(true)
	releaseGadgetHold()
	setAiming(false)
	setScoped(false)
	cookStart = nil
	burstLeft = 0
	pendingPress = false
	if equippedSlot and equippedSlot ~= slot then
		lastSlot = equippedSlot
	end
	equippedSlot = slot
	equippedId = id
	def = w
	ensureAmmo(id)
	shotIndex = 0
	bloom = 0
	equipEndsAt = now() + w.equipTime
	boltUntil = 0
	call("ViewmodelController", "Equip", id)
	call("ViewmodelController", "PlayEquip", w.equipTime)
	remotes.Equip:FireServer({ slot = slot })
	Bus.fire("WeaponEquipped", id, slot)
	fireAmmoChanged()
	Bus.fire("FireModeChanged", fireMode())
end

local function cycleFireMode()
	if not def or #def.fireModes < 2 then
		return
	end
	local idx = (fireModeIndex[def.id] or 1) % #def.fireModes + 1
	fireModeIndex[def.id] = idx
	burstLeft = 0
	call("SoundController", "Play2D", "UI_Click", { volume = 0.5 })
	Bus.fire("FireModeChanged", def.fireModes[idx])
end

-------------------------------------------------------------------------------------------------
-- Shooting
-------------------------------------------------------------------------------------------------

local function refreshRayParams()
	local character = player.Character
	local list: { Instance } = { workspace.CurrentCamera }
	if character then
		table.insert(list, character)
	end
	for _, name in { "CombatProjectiles", "SmokeScreens" } do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	rayParams.FilterDescendantsInstances = list
	meleeOverlap.FilterDescendantsInstances = list
end

local function muzzleCFrame(): CFrame
	local cf = call("ViewmodelController", "GetMuzzleWorldCFrame")
	if typeof(cf) == "CFrame" then
		return cf
	end
	local cam = workspace.CurrentCamera
	return cam.CFrame * CFrame.new(0.55, -0.45, -2.2)
end

-- Shot origin + aim direction. In first person the camera is the origin; in a pulled-back camera the
-- head is used (server checks origin against the head) and aimed at the camera's aim point.
local function aimRay(maxDist: number): (Vector3, Vector3)
	local cam = workspace.CurrentCamera
	local _, _, _, head = getCharacter()
	local camPos = cam.CFrame.Position
	local look = cam.CFrame.LookVector
	if not head or (camPos - head.Position).Magnitude < 4 then
		return camPos, look
	end
	local result = workspace:Raycast(camPos, look * maxDist, rayParams)
	local target = if result then result.Position else camPos + look * maxDist
	local origin = head.Position
	local dir = target - origin
	if dir.Magnitude < 0.1 then
		return origin, look
	end
	return origin, dir.Unit
end

local function applyRecoilAndFeedback(kickScale: number)
	shotIndex = if now() - lastShotAt > SHOT_STRING_RESET then 1 else shotIndex + 1
	local aimAlpha = getAimAlpha()
	local pitch, yaw = Ballistics.recoilFor(def, shotIndex, aimAlpha, getStance(), rng)
	call("CameraController", "AddRecoil", pitch, yaw)
	call("CameraController", "Shake", math.clamp(pitch * 0.08, 0.02, 0.6), 0.12)
	call("ViewmodelController", "PlayFire", math.clamp(kickScale, 0, 1.5))
	-- Sustained-fire bloom (less when aiming), capped at 3x hip spread
	local add = (def.recoil.vertical or 1) * (if aimAlpha > 0.5 then 0.06 else 0.22)
	bloom = math.min(bloom + add, (def.hipSpread or 2) * 2)
	lastShotAt = now()
end

local function fireBullets(): boolean
	local entry = equippedId and ammo[equippedId]
	if not entry or entry.mag <= 0 then
		return false
	end
	local maxDist = math.min(math.max(def.range * 1.5, 300), 2500)
	local origin, baseDir = aimRay(maxDist)
	local aimDir = Ballistics.spreadDirection(baseDir, currentSpread, rng)

	local pellets = def.pellets or 1
	local shots = table.create(pellets)
	local muzzle = muzzleCFrame()
	local muzzlePos = muzzle.Position
	local tracerBudget = if pellets > 1 then 3 else 1
	for i = 1, pellets do
		local dir = if pellets > 1 then Ballistics.spreadDirection(aimDir, def.pelletSpread or 4, rng) else aimDir
		local result = workspace:Raycast(origin, dir * maxDist, rayParams)
		local shot: { [string]: any } = { dir = dir }
		local endPos = origin + dir * maxDist
		if result then
			endPos = result.Position
			shot.pos = result.Position
			shot.normal = result.Normal
			local character = Ballistics.findCharacter(result.Instance)
			if character or Ballistics.findVehicle(result.Instance) then
				shot.hit = result.Instance
			end
			-- Local impact (blood/hit puffs on characters are left to the hitmarker feedback)
			if not character then
				call("EffectsController", "Impact", result.Position, result.Normal, result.Material)
			end
		end
		if i <= tracerBudget then
			call("EffectsController", "TracerFor", def.id, muzzlePos, endPos)
		end
		shots[i] = shot
	end

	entry.mag -= 1
	remotes.Fire:FireServer({
		weaponId = def.id,
		origin = origin,
		shots = shots,
		t = workspace:GetServerTimeNow(),
	})

	call("EffectsController", "MuzzleFlash", muzzle, if def.category == "Pistol" then 0.7 else 1)
	call("SoundController", "PlayWeaponShot", def.id, muzzlePos, true)
	if def.fireModes[1] ~= "Bolt" and def.category ~= "Shotgun" then
		call("EffectsController", "ShellEject", muzzle * CFrame.new(0.05, 0.05, 1.1), def.category)
	end
	applyRecoilAndFeedback(if def.category == "Sniper" or def.category == "BoltAction" then 1 else 0.6)
	fireAmmoChanged()
	Bus.fire("Fired", def.id)
	return true
end

local function fireLauncher(): boolean
	local entry = equippedId and ammo[equippedId]
	if not entry or entry.mag <= 0 then
		return false
	end
	local origin, baseDir = aimRay(def.range)
	local dir = Ballistics.spreadDirection(baseDir, currentSpread, rng)
	entry.mag -= 1
	remotes.Throw:FireServer({
		weaponId = def.id,
		origin = origin + dir * 1.5,
		velocity = dir * def.bulletVelocity,
	})
	local muzzle = muzzleCFrame()
	call("EffectsController", "MuzzleFlash", muzzle, 2)
	call("SoundController", "PlayWeaponShot", def.id, muzzle.Position, true)
	applyRecoilAndFeedback(1.2)
	fireAmmoChanged()
	Bus.fire("Fired", def.id)
	return true
end

local function dryFire()
	call("SoundController", "Play2D", "Dry_Fire", { volume = 0.5 })
	nextShotAt = now() + 0.25
	local entry = equippedId and ammo[equippedId]
	if entry and entry.reserve > 0 then
		startReload()
	end
end

local function tryFire()
	local t = now()
	if t < equipEndsAt or t < nextShotAt or t < boltUntil or t < actionLockUntil then
		return
	end
	if reloading then
		if def.reloadType == "single" and (ammo[def.id] and ammo[def.id].mag > 0) then
			stopReload(false) -- server cancels its reload when the shot arrives
		else
			return
		end
	end
	local mode = fireMode()
	local wantShot = false
	if mode == "Auto" then
		wantShot = triggerHeld
	elseif mode == "Burst" then
		if pendingPress then
			pendingPress = false
			burstLeft = def.burstCount or 3
		end
		wantShot = burstLeft > 0
	else -- Semi / Bolt
		wantShot = pendingPress
		pendingPress = false
	end
	if not wantShot then
		return
	end
	local entry = ammo[def.id]
	if not entry or entry.mag <= 0 then
		burstLeft = 0
		dryFire()
		return
	end
	local interval = 60 / math.max(def.rpm, 1)
	local fired = if isLauncher() then fireLauncher() else fireBullets()
	if not fired then
		return
	end
	-- Keep cadence exact under frame jitter for automatic fire
	nextShotAt = if t - nextShotAt < interval then nextShotAt + interval else t + interval
	if mode == "Burst" then
		burstLeft -= 1
		if burstLeft <= 0 then
			nextShotAt = t + math.max(interval * 2, 0.2)
		end
	elseif mode == "Bolt" then
		boltUntil = t + interval
		if entry.mag > 0 then
			call("ViewmodelController", "PlayBolt", interval * 0.8)
		end
	end
	if entry.mag <= 0 and entry.reserve > 0 and (isLauncher() or mode == "Bolt") then
		task.delay(if isLauncher() then 0.35 else interval * 0.6, function()
			if equippedId == def.id then
				startReload()
			end
		end)
	end
end

-------------------------------------------------------------------------------------------------
-- Throwables
-------------------------------------------------------------------------------------------------

local function throwItem(w: any, cook: number, quick: boolean)
	local entry = ammo[w.id]
	if not entry or entry.mag <= 0 then
		return
	end
	local _, _, root, head = getCharacter()
	if not head then
		return
	end
	local cam = workspace.CurrentCamera
	local look = cam.CFrame.LookVector
	local carrier = if root then root.AssemblyLinearVelocity * 0.5 else Vector3.zero
	local velocity = (look + Vector3.new(0, 0.2, 0)).Unit * (w.throwSpeed or 80) + carrier
	entry.mag -= 1
	remotes.Throw:FireServer({
		weaponId = w.id,
		origin = head.Position + look * 1.5,
		velocity = velocity,
		cook = cook,
	})
	call("ViewmodelController", "PlayThrow")
	call("SoundController", "Play2D", "Grenade_Throw", { volume = 0.6 })
	actionLockUntil = now() + THROW_LOCK
	if equippedId == w.id then
		fireAmmoChanged()
	end
	Bus.fire("Fired", w.id)
	if not quick and equippedId == w.id and entry.mag <= 0 then
		task.delay(THROW_LOCK, function()
			if equippedId == w.id then
				equipSlot(if loadout[lastSlot] and lastSlot ~= equippedSlot then lastSlot else "primary")
			end
		end)
	end
end

local function releaseThrow()
	if not cookStart or not def then
		cookStart = nil
		return
	end
	local cook = if def.cookable then now() - cookStart else 0
	cookStart = nil
	throwItem(def, cook, false)
end

local function quickGrenade()
	if inputBlocked() or now() < actionLockUntil then
		return
	end
	for _, slot in { "gadget1", "gadget2" } do
		local id = loadout[slot]
		local w = id and Weapons.get(id)
		if w and w.category == "Grenade" and ammo[id] and ammo[id].mag > 0 then
			stopReload(true)
			setAiming(false)
			throwItem(w, 0, true)
			return
		end
	end
end

-------------------------------------------------------------------------------------------------
-- Melee
-------------------------------------------------------------------------------------------------

local function quickMelee()
	if inputBlocked() then
		return
	end
	local knife = Weapons.get(Weapons.MELEE_ID)
	local t = now()
	if not knife or t - lastMelee < (knife.meleeCooldown or 0.65) then
		return
	end
	lastMelee = t
	stopReload(true)
	setAiming(false)
	actionLockUntil = t + MELEE_ANIM_LOCK
	call("ViewmodelController", "PlayMelee")
	call("SoundController", "Play2D", "Melee_Swing", { volume = 0.6 })

	local _, _, root = getCharacter()
	if not root then
		return
	end
	local range = knife.meleeRange or 6
	local look = workspace.CurrentCamera.CFrame.LookVector
	local best: Model? = nil
	local bestDist = math.huge
	for _, part in workspace:GetPartBoundsInRadius(root.Position, range + 1, meleeOverlap) do
		local model, hum = Ballistics.findCharacter(part)
		if model and hum and hum.Health > 0 and model ~= player.Character then
			local targetRoot = model:FindFirstChild("HumanoidRootPart")
			if targetRoot and targetRoot:IsA("BasePart") then
				local delta = targetRoot.Position - root.Position
				local d = delta.Magnitude
				if d <= range and d < bestDist and (d < 1 or delta.Unit:Dot(look) > 0.35) then
					local other = Players:GetPlayerFromCharacter(model)
					local mySide = player:GetAttribute("Side")
					if not (other and mySide and mySide ~= "" and other:GetAttribute("Side") == mySide) then
						best = model
						bestDist = d
					end
				end
			end
		end
	end
	if best then
		remotes.Melee:FireServer({ target = best })
	end
end

-------------------------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------------------------

local function onTriggerDown()
	if inputBlocked() or not def then
		return
	end
	triggerHeld = true
	if isGadget() then
		local cat = def.category
		if cat == "Repair" or cat == "Medkit" then
			gadgetHolding = cat
			call("GadgetController", "SetHolding", cat, true)
		end
		call("GadgetController", "Use", cat)
		return
	end
	if isThrowable() then
		if now() >= actionLockUntil and now() >= equipEndsAt and ammo[def.id] and ammo[def.id].mag > 0 then
			cookStart = now()
			call("SoundController", "Play2D", "UI_Click", { volume = 0.5 })
		end
		return
	end
	pendingPress = true
end

local function onTriggerUp()
	triggerHeld = false
	releaseGadgetHold()
	if cookStart then
		releaseThrow()
	end
end

local function onAim(down: boolean)
	aimHeld = down
	if not down then
		setAiming(false)
	end
end

local function onReloadPressed()
	if not inputBlocked() then
		startReload()
	end
end

local function cycleGadget()
	local nextSlot = if equippedSlot == "gadget1" then "gadget2" else "gadget1"
	if not loadout[nextSlot] or loadout[nextSlot] == "" then
		nextSlot = if nextSlot == "gadget1" then "gadget2" else "gadget1"
	end
	equipSlot(nextSlot)
end

local function matches(input: InputObject, bind: any): boolean
	if bind == nil then
		return false
	end
	if typeof(bind) == "EnumItem" then
		if bind.EnumType == Enum.UserInputType then
			return input.UserInputType == bind
		end
		return input.KeyCode == bind
	end
	return false
end

local function onInputBegan(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if matches(input, KB.Fire) or matches(input, GP.Fire) then
		onTriggerDown()
	elseif matches(input, KB.Aim) or matches(input, GP.Aim) then
		onAim(true)
	elseif matches(input, KB.Reload) or matches(input, GP.Reload) then
		onReloadPressed()
	elseif matches(input, KB.Primary) then
		equipSlot("primary")
	elseif matches(input, KB.Secondary) then
		equipSlot("secondary")
	elseif matches(input, KB.Gadget1) then
		equipSlot("gadget1")
	elseif matches(input, KB.Gadget2) then
		equipSlot("gadget2")
	elseif matches(input, KB.Melee) or matches(input, GP.Melee) then
		quickMelee()
	elseif matches(input, KB.QuickGrenade) or matches(input, GP.QuickGrenade) then
		quickGrenade()
	elseif matches(input, KB.FireMode) then
		cycleFireMode()
	elseif matches(input, GP.SwitchWeapon) then
		equipSlot(if equippedSlot == "primary" then "secondary" else "primary")
	elseif matches(input, GP.Gadget) then
		cycleGadget()
	end
end

local function onInputEnded(input: InputObject)
	if matches(input, KB.Fire) or matches(input, GP.Fire) then
		onTriggerUp()
	elseif matches(input, KB.Aim) or matches(input, GP.Aim) then
		onAim(false)
	end
end

local function bindTouch()
	if not UserInputService.TouchEnabled then
		return
	end
	local function handler(action: string, state: Enum.UserInputState)
		local began = state == Enum.UserInputState.Begin
		local ended = state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel
		if action == "WW2_Fire" then
			if began then
				onTriggerDown()
			elseif ended then
				onTriggerUp()
			end
		elseif action == "WW2_Aim" and began then
			onAim(not aimHeld) -- toggle on touch
		elseif action == "WW2_Reload" and began then
			onReloadPressed()
		elseif action == "WW2_Grenade" and began then
			quickGrenade()
		elseif action == "WW2_Switch" and began then
			equipSlot(if equippedSlot == "primary" then "secondary" else "primary")
		end
		return Enum.ContextActionResult.Sink
	end
	local buttons = {
		{ "WW2_Fire", "FIRE", UDim2.new(1, -95, 1, -150) },
		{ "WW2_Aim", "AIM", UDim2.new(1, -165, 1, -110) },
		{ "WW2_Reload", "R", UDim2.new(1, -170, 1, -185) },
		{ "WW2_Grenade", "G", UDim2.new(1, -95, 1, -225) },
		{ "WW2_Switch", "SWAP", UDim2.new(1, -235, 1, -150) },
	}
	for _, b in buttons do
		ContextActionService:BindAction(b[1], handler, true)
		ContextActionService:SetTitle(b[1], b[2])
		ContextActionService:SetPosition(b[1], b[3])
	end
end

-------------------------------------------------------------------------------------------------
-- Per-frame update
-------------------------------------------------------------------------------------------------

local function update(dt: number)
	if not def then
		return
	end
	if inputBlocked() then
		if triggerHeld then
			onTriggerUp()
		end
		if aiming then
			setAiming(false)
		end
		return
	end

	local sprinting = isSprinting()
	if sprinting and reloading then
		stopReload(true)
	end

	-- ADS
	local wantAim = aimHeld and not sprinting and not reloading and canAim()
	if wantAim ~= aiming then
		setAiming(wantAim)
	end
	local adsTime = math.max(def.adsTime or 0.25, 0.05)
	aimAlphaLocal = math.clamp(aimAlphaLocal + (if aiming then dt else -dt) / adsTime, 0, 1)
	local aimAlpha = getAimAlpha()
	if def.scope then
		setScoped(aiming and aimAlpha > 0.85)
	end
	call("MovementController", "SetSprintBlocked", aiming or (triggerHeld and (isFirearm() or isLauncher())))

	-- Spread
	local _, hum, root = getCharacter()
	local vel = if root then root.AssemblyLinearVelocity else Vector3.zero
	spreadParams.aimAlpha = aimAlpha
	spreadParams.moving = vel.X * vel.X + vel.Z * vel.Z > 4
	spreadParams.sprinting = sprinting
	spreadParams.airborne = hum ~= nil and hum.FloorMaterial == Enum.Material.Air
	spreadParams.stance = getStance()
	local recovery = (def.recoil and def.recoil.recovery or 8) * 0.6
	if now() - lastShotAt > 0.08 then
		bloom = math.max(0, bloom - recovery * dt)
	end
	spreadParams.bloom = bloom
	currentSpread = Ballistics.computeSpread(def, spreadParams)
	if math.abs(currentSpread - lastSpread) > 0.05 then
		lastSpread = currentSpread
		Bus.fire("SpreadChanged", currentSpread)
	end

	-- Grenade cooking: never let it blow up in hand; throw automatically at the last moment.
	if cookStart and def.cookable and def.fuse and now() - cookStart >= def.fuse - 0.4 then
		releaseThrow()
	end

	if (isFirearm() or isLauncher()) and (triggerHeld or pendingPress or burstLeft > 0) then
		tryFire()
	end
end

-------------------------------------------------------------------------------------------------
-- Network
-------------------------------------------------------------------------------------------------

local function onAmmo(payload: any)
	if type(payload) ~= "table" or type(payload.weaponId) ~= "string" then
		return
	end
	local mag, reserve = payload.mag, payload.reserve
	if type(mag) ~= "number" or type(reserve) ~= "number" then
		return
	end
	local entry = ammo[payload.weaponId]
	if not entry then
		ammo[payload.weaponId] = { mag = mag, reserve = reserve }
	else
		-- Shots still in flight make the server count lag behind; trust the lower mag right after firing.
		if payload.weaponId == equippedId and now() - lastShotAt < 0.3 then
			entry.mag = math.min(entry.mag, mag)
		elseif not (reloading and reloadWeapon == payload.weaponId and mag < entry.mag) then
			entry.mag = mag
		end
		entry.reserve = reserve
	end
	if payload.weaponId == equippedId then
		fireAmmoChanged()
	end
end

local function onShotFX(payload: any)
	if type(payload) ~= "table" or typeof(payload.origin) ~= "Vector3" or type(payload.hits) ~= "table" then
		return
	end
	local shooter = payload.shooter
	if shooter == player then
		return
	end
	local weaponId = if type(payload.weaponId) == "string" then payload.weaponId else ""
	local cam = workspace.CurrentCamera
	local camPos = cam.CFrame.Position
	if (payload.origin - camPos).Magnitude > 1500 then
		return
	end
	local muzzle: CFrame? = nil
	local character = typeof(shooter) == "Instance" and shooter:IsA("Player") and shooter.Character or nil
	if character then
		local model = character:FindFirstChild("EquippedWeaponModel")
		local handle = model and (model:IsA("Model") and model.PrimaryPart or model:FindFirstChild("Handle"))
		local att = handle and handle:FindFirstChild("Muzzle")
		if att and att:IsA("Attachment") then
			muzzle = att.WorldCFrame
		else
			local head = character:FindFirstChild("Head")
			if head and head:IsA("BasePart") then
				muzzle = head.CFrame
			end
		end
	end
	local from = if muzzle then muzzle.Position else payload.origin
	call("EffectsController", "MuzzleFlash", muzzle or CFrame.new(from), 0.8)
	call("SoundController", "PlayWeaponShot", weaponId, from, false)
	local n = 0
	for _, hit in payload.hits do
		n += 1
		if n > 9 then
			break
		end
		if type(hit) == "table" and typeof(hit.pos) == "Vector3" then
			if n <= 3 then
				call("EffectsController", "TracerFor", weaponId, from, hit.pos)
			end
			if (hit.pos - camPos).Magnitude < FX_CULL_DISTANCE then
				local normal = if typeof(hit.normal) == "Vector3" then hit.normal else Vector3.yAxis
				call("EffectsController", "Impact", hit.pos, normal, hit.material or "Concrete")
			end
		end
	end
end

-------------------------------------------------------------------------------------------------
-- Loadout & character lifecycle
-------------------------------------------------------------------------------------------------

local function readLoadout()
	local raw = player:GetAttribute("Loadout")
	if type(raw) ~= "string" or raw == "" then
		return
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or type(decoded) ~= "table" then
		return
	end
	table.clear(loadout)
	for _, slot in SLOT_ORDER do
		local id = decoded[slot]
		if type(id) == "string" and Weapons.get(id) then
			loadout[slot] = id
			ensureAmmo(id)
		end
	end
	loadout.melee = Weapons.MELEE_ID
end

local function equipDefault()
	if loadout.primary then
		equipSlot("primary", true)
	elseif loadout.secondary then
		equipSlot("secondary", true)
	end
end

local function onDied()
	alive = false
	localUnequip()
	table.clear(ammo) -- next life's counts come from Combat_Ammo / defaults
	call("CameraController", "SetFovOffset", "ADS", 0)
end

local function onCharacterAdded(character: Model)
	characterTrove:Clean()
	localUnequip()
	alive = false
	refreshRayParams()
	local hum = character:WaitForChild("Humanoid", 10)
	if not hum or not hum:IsA("Humanoid") or player.Character ~= character then
		return
	end
	characterTrove:Connect(hum.Died, onDied)
	characterTrove:Connect(character.ChildAdded, function()
		-- keep the exclude list current if outfits/tools are added later
		refreshRayParams()
	end)
	-- Wait for SpawnService to mark us alive (or proceed if it never writes the attribute)
	local deadline = now() + 3
	while player:GetAttribute("Alive") == false and now() < deadline and player.Character == character do
		task.wait(0.1)
	end
	if player.Character ~= character or hum.Health <= 0 then
		return
	end
	alive = true
	readLoadout()
	if not inVehicle() then
		equipDefault()
	end
end

-------------------------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------------------------

function WeaponController.GetEquipped(): (string?, string?)
	return equippedId, equippedSlot
end

function WeaponController.IsAiming(): boolean
	return aiming
end

function WeaponController.IsReloading(): boolean
	return reloading
end

function WeaponController.GetSpread(): number
	return currentSpread
end

function WeaponController.GetAmmo(weaponId: string): (number, number)
	local entry = ammo[weaponId]
	if entry then
		return entry.mag, entry.reserve
	end
	return 0, 0
end

function WeaponController.GetMoveSpeedMultiplier(): number
	if not def then
		return 1
	end
	local m = def.walkSpeedMult or 1
	if aiming then
		m *= Constants.ADS_SPEED_MULT
	end
	return m
end

-------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------

function WeaponController:Init()
	remotes.Equip = Net.event("Combat_Equip")
	remotes.Fire = Net.event("Combat_Fire")
	remotes.Reload = Net.event("Combat_Reload")
	remotes.Throw = Net.event("Combat_Throw")
	remotes.Melee = Net.event("Combat_Melee")
	remotes.Ammo = Net.event("Combat_Ammo")
	remotes.ShotFX = Net.unreliable("Combat_ShotFX")
end

function WeaponController:Start()
	remotes.Ammo.OnClientEvent:Connect(onAmmo)
	remotes.ShotFX.OnClientEvent:Connect(onShotFX)

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	bindTouch()

	Bus.connect("MenuOpened", function()
		onTriggerUp()
		onAim(false)
	end)

	player:GetAttributeChangedSignal("Loadout"):Connect(function()
		if alive then
			readLoadout()
			if equippedSlot and loadout[equippedSlot] ~= equippedId then
				equipDefault()
			end
		end
	end)
	player:GetAttributeChangedSignal("VehicleUid"):Connect(function()
		if inVehicle() then
			localUnequip()
		elseif alive then
			task.delay(0.2, function()
				if alive and not inVehicle() and not equippedId then
					equipSlot(if loadout[lastSlot] then lastSlot else "primary", true)
				end
			end)
		end
	end)

	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		task.spawn(onCharacterAdded, player.Character)
	end

	RunService:BindToRenderStep("WW2_WeaponController", Enum.RenderPriority.Input.Value + 1, update)
end

return WeaponController
