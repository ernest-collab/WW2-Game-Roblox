--[[
	CombatService (Combat team): authoritative infantry combat.

	Responsibilities
	  * Per-player weapon state: loadout, per-weapon magazine/reserve, equipped weapon, fire-rate budget,
	    server-timed reloads.
	  * Remote handlers: Combat_Equip / Combat_Fire / Combat_Reload / Combat_Throw / Combat_Melee.
	  * Hit validation (origin tolerance, aim deviation, lag-tolerant hit-part check, world LOS with
	    thin-cover penetration), damage with falloff + hit zones, friendly fire off, spawn protection.
	  * Deaths: Bus PlayerKilled (+assisters), Bus PlayerAssist, Combat_Kill to everyone.
	  * Health regeneration (Constants), medic FullRegen perk.
	  * Projectiles: physics grenades/satchels, stepped rockets / impact grenades / sticky bombs, smoke.
	  * Explode(): LOS-checked player damage, vehicle damage via VehicleService, FX_Explosion, Bus Explosion.
	  * Third-person weapon model welded to the character's right hand.

	Public API: see docs/ARCHITECTURE.md section 7 (+ contract additions in section 9).
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local Classes = require(Shared.Config.Classes)
local Weapons = require(Shared.Config.Weapons)
local Ballistics = require(Shared.Util.Ballistics)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)
local Trove = require(Shared.Util.Trove)

local CombatService = {}

-------------------------------------------------------------------------------------------------
-- Tuning
-------------------------------------------------------------------------------------------------

local ORIGIN_TOLERANCE = 10 -- studs between claimed shot origin and the server head position
local AIM_TOLERANCE_COS = math.cos(math.rad(5)) -- claimed hit point vs claimed direction
local HIT_LAG_TOLERANCE = 7 -- studs between claimed hit point and server part position (+ velocity)
local FIRE_BURST_WINDOW = 0.3 -- seconds of packet bunching tolerated by the fire-rate budget
local FIRE_RATE_SLACK = 0.9 -- accept shots at up to ~111% of the weapon RPM (clock jitter)
local RELOAD_GRACE = 0.3 -- a shot this close to reload completion completes the reload instead
local ASSIST_WINDOW = 10
local ASSIST_MIN_DAMAGE = 15
local THROW_COOLDOWN = 0.6
local LAUNCH_COOLDOWN = 0.5
local REGEN_TICK = 0.25
local MAX_FX_DISTANCE = 1200 -- players farther than this from a shot don't receive Combat_ShotFX
local BACKSTAB_DOT = -0.35
local BACKSTAB_DAMAGE = 200
local MELEE_LAG_BONUS = 2.5
local GRAVITY = Vector3.new(0, -workspace.Gravity, 0)
local SLOTS = { primary = true, secondary = true, gadget1 = true, gadget2 = true, melee = true }
local TORSO_NAMES = { UpperTorso = true, LowerTorso = true, Torso = true, HumanoidRootPart = true }
local EMPTY = table.freeze({})

-------------------------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------------------------

type AmmoEntry = { mag: number, reserve: number }
type Contribution = { damage: number, time: number }
type PlayerState = {
	player: Player,
	loadout: { [string]: string },
	ammo: { [string]: AmmoEntry },
	slot: string?,
	weaponId: string?,
	equipReadyAt: number,
	fireClock: number,
	lastShot: number,
	reloading: boolean,
	reloadEnd: number,
	reloadThread: thread?,
	lastMelee: number,
	lastThrow: number,
	lastLaunch: number,
	lastDamaged: number,
	loadoutTime: number,
	charAddedAt: number,
	contributors: { [Player]: Contribution },
	deathHandled: boolean,
	lastHeadshot: boolean,
	weaponModel: Model?,
	rayParams: RaycastParams,
	charTrove: any,
}

local states: { [Player]: PlayerState } = {}
local remotes: { [string]: any } = {}

local projectileFolder: Folder
local smokeFolder: Folder
local worldParams = RaycastParams.new() -- excludes every character + projectiles (LOS / cover checks)
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.IgnoreWater = true
local characterList: { Model } = {}
local worldParamsDirty = true
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Exclude

local rng = Random.new()

-- Scratch tables reused by Explode (avoid per-explosion allocation of lookup tables)
local scratchCharDist: { [Model]: number } = {}
local scratchVehicleDist: { [Model]: number } = {}
local scratchConfirm: { [Player]: { damage: number, killed: boolean } } = {}

-------------------------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------------------------

local serviceCache: { [string]: any } = {}
-- Lazily requires a sibling service; returns nil (and caches the miss) when it is absent/broken.
local function getService(name: string): any
	local cached = serviceCache[name]
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
	serviceCache[name] = result
	return result or nil
end

local vehiclesConfig: any = nil
local function getVehicleClass(vehicle: Model): string?
	if vehiclesConfig == nil then
		vehiclesConfig = false
		local cfg = Shared.Config:FindFirstChild("Vehicles")
		if cfg then
			local ok, mod = pcall(require, cfg)
			if ok and type(mod) == "table" then
				vehiclesConfig = mod
			end
		end
	end
	if not vehiclesConfig then
		return nil
	end
	local id = vehicle:GetAttribute("VehicleId")
	local byId = vehiclesConfig.byId or vehiclesConfig
	local def = type(id) == "string" and type(byId) == "table" and byId[id] or nil
	return def and def.class or nil
end

local function now(): number
	return os.clock()
end

local function getHumanoid(character: Model?): Humanoid?
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function isAlive(player: Player): boolean
	local hum = getHumanoid(player.Character)
	return hum ~= nil and hum.Health > 0
end

local function sideOf(player: Player): string?
	local side = player:GetAttribute("Side")
	if type(side) == "string" and side ~= "" then
		return side
	end
	if player.Team then
		return player.Team.Name
	end
	return nil
end

local function sameSide(a: Player, b: Player): boolean
	local sa, sb = sideOf(a), sideOf(b)
	return sa ~= nil and sa == sb
end

local function inVehicle(player: Player): boolean
	local uid = player:GetAttribute("VehicleUid")
	return type(uid) == "string" and uid ~= ""
end

local function refreshWorldParams()
	if not worldParamsDirty then
		return
	end
	worldParamsDirty = false
	local list: { Instance } = { projectileFolder, smokeFolder }
	for _, c in characterList do
		table.insert(list, c)
	end
	worldParams.FilterDescendantsInstances = list
end

local function sendAmmo(st: PlayerState, weaponId: string)
	local entry = st.ammo[weaponId]
	if entry then
		remotes.Ammo:FireClient(st.player, { weaponId = weaponId, mag = entry.mag, reserve = entry.reserve })
	end
end

local function sendAllAmmo(st: PlayerState)
	for id in st.ammo do
		sendAmmo(st, id)
	end
end

local function hasPerk(player: Player, perk: string): boolean
	local classId = player:GetAttribute("Class")
	local class = type(classId) == "string" and Classes.get(classId) or nil
	return class ~= nil and table.find(class.perks, perk) ~= nil
end

-- Maps an arbitrary hit part inside a character to a body-part name for hit-zone multipliers
-- (helmets/accessories/outfit parts resolve to the limb they are attached to).
local function resolveBodyPart(character: Model, part: BasePart): string
	local name = part.Name
	if Constants.HEADSHOT_PART_NAMES[name] or Constants.LIMB_PART_NAMES[name] or TORSO_NAMES[name] then
		return name
	end
	local weld = part:FindFirstChild("AccessoryWeld")
	if weld and weld:IsA("Weld") and weld.Part1 then
		return weld.Part1.Name
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") and (head.Position - part.Position).Magnitude < 1.4 then
		return "Head"
	end
	return "UpperTorso"
end

-------------------------------------------------------------------------------------------------
-- Third-person weapon model
-------------------------------------------------------------------------------------------------

local weaponModelsModule: any = nil
local function loadWeaponModels(): any
	if weaponModelsModule == nil then
		weaponModelsModule = false
		local m = Shared:FindFirstChild("WeaponModels")
		if m and m:IsA("ModuleScript") then
			local ok, mod = pcall(require, m)
			if ok and type(mod) == "table" and type(mod.Build) == "function" then
				weaponModelsModule = mod
			end
		end
	end
	return weaponModelsModule or nil
end

-- Builds the shared procedural model (WeaponModels.Build) or a placeholder when unavailable.
local function buildWeaponModel(weaponId: string, noPlaceholder: boolean?): Model?
	if loadWeaponModels() then
		local ok, model = pcall(weaponModelsModule.Build, weaponId)
		if ok and typeof(model) == "Instance" and model:IsA("Model") then
			return model
		end
	end
	if noPlaceholder then
		return nil
	end
	-- Placeholder: a simple dark receiver block with Grip + Muzzle attachments.
	local def = Weapons.get(weaponId)
	local length = def and def.visual and def.visual.length or 2
	local model = Instance.new("Model")
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.25, 0.4, math.max(0.6, length * 0.7))
	handle.Color = def and def.visual and def.visual.metalColor or Color3.fromRGB(45, 45, 48)
	handle.Material = Enum.Material.Metal
	handle.Parent = model
	local grip = Instance.new("Attachment")
	grip.Name = "Grip"
	grip.Position = Vector3.new(0, -0.1, handle.Size.Z * 0.15)
	grip.Parent = handle
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(0, 0.05, -handle.Size.Z * 0.5)
	muzzle.Parent = handle
	model.PrimaryPart = handle
	return model
end

local function detachWeaponModel(st: PlayerState)
	if st.weaponModel then
		st.weaponModel:Destroy()
		st.weaponModel = nil
	end
end

local function attachWeaponModel(st: PlayerState, weaponId: string)
	detachWeaponModel(st)
	local character = st.player.Character
	if not character then
		return
	end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		return
	end
	local model = buildWeaponModel(weaponId)
	if not model then
		return
	end
	model.Name = "EquippedWeaponModel"
	model:SetAttribute("WeaponId", weaponId)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		end
	end
	local handle = model.PrimaryPart or model:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		model:Destroy()
		return
	end
	local handAtt = hand:FindFirstChild("RightGripAttachment")
	local gripAtt = handle:FindFirstChild("Grip")
	local joint = Instance.new("Motor6D")
	joint.Name = "WeaponGrip"
	joint.Part0 = hand
	joint.Part1 = handle
	joint.C0 = if handAtt and handAtt:IsA("Attachment") then handAtt.CFrame else CFrame.new(0, -hand.Size.Y * 0.5, 0)
	joint.C1 = if gripAtt and gripAtt:IsA("Attachment") then gripAtt.CFrame else CFrame.identity
	joint.Parent = handle
	model.Parent = character
	st.weaponModel = model
end

-------------------------------------------------------------------------------------------------
-- Reloading
-------------------------------------------------------------------------------------------------

local function cancelReload(st: PlayerState, sync: boolean?)
	if not st.reloading then
		return
	end
	st.reloading = false
	local thread = st.reloadThread
	st.reloadThread = nil
	if thread and thread ~= coroutine.running() then
		pcall(task.cancel, thread)
	end
	if sync and st.weaponId then
		sendAmmo(st, st.weaponId)
	end
end

local function finishMagazineReload(st: PlayerState, weaponId: string)
	local def = Weapons.get(weaponId)
	local entry = st.ammo[weaponId]
	st.reloading = false
	st.reloadThread = nil
	if not def or not entry then
		return
	end
	local take = math.min(def.magazine - entry.mag, entry.reserve)
	if take > 0 then
		entry.mag += take
		entry.reserve -= take
	end
	sendAmmo(st, weaponId)
end

local function startReload(st: PlayerState, weaponId: string): boolean
	local def = Weapons.get(weaponId)
	local entry = st.ammo[weaponId]
	if not def or not entry or st.reloading then
		return false
	end
	if entry.mag >= def.magazine or entry.reserve <= 0 or def.reloadTime <= 0 then
		return false
	end
	local empty = entry.mag == 0
	st.reloading = true
	if def.reloadType == "single" then
		-- Round-by-round: the first round takes the (empty) chamber time, then reloadTime per round.
		local first = (if empty then def.emptyReloadTime or def.reloadTime else 0) + def.reloadTime
		st.reloadEnd = now() + first + (def.magazine - entry.mag - 1) * def.reloadTime
		st.reloadThread = task.spawn(function()
			task.wait(first)
			while st.reloading and entry.mag < def.magazine and entry.reserve > 0 do
				entry.mag += 1
				entry.reserve -= 1
				if entry.mag >= def.magazine or entry.reserve <= 0 then
					break
				end
				task.wait(def.reloadTime)
			end
			st.reloading = false
			st.reloadThread = nil
			sendAmmo(st, weaponId)
		end)
	else
		local duration = if empty then def.emptyReloadTime or def.reloadTime else def.reloadTime
		st.reloadEnd = now() + duration
		st.reloadThread = task.delay(duration, finishMagazineReload, st, weaponId)
	end
	return true
end

-------------------------------------------------------------------------------------------------
-- Equip
-------------------------------------------------------------------------------------------------

local function unequip(st: PlayerState)
	cancelReload(st, true)
	st.slot = nil
	st.weaponId = nil
	detachWeaponModel(st)
	st.player:SetAttribute("EquippedWeapon", "")
end

local function equip(st: PlayerState, slot: string, weaponId: string)
	local def = Weapons.get(weaponId)
	if not def then
		return
	end
	if st.weaponId == weaponId and st.slot == slot and st.weaponModel and st.weaponModel.Parent then
		return
	end
	cancelReload(st, true)
	st.slot = slot
	st.weaponId = weaponId
	-- Half the equip time is enforced server-side; the rest is latency slack.
	st.equipReadyAt = now() + def.equipTime * 0.5
	st.player:SetAttribute("EquippedWeapon", weaponId)
	attachWeaponModel(st, weaponId)
end

-------------------------------------------------------------------------------------------------
-- Damage & death
-------------------------------------------------------------------------------------------------

local function handleDeath(victim: Player, attacker: Player?, weaponId: string, headshot: boolean, opts: any)
	local st = states[victim]
	if not st or st.deathHandled then
		return
	end
	st.deathHandled = true
	local killer: Player? = if attacker and attacker ~= victim then attacker else nil
	local t = now()

	local assisters: { Player } = {}
	for p, rec in st.contributors do
		if p ~= killer and p.Parent and t - rec.time <= ASSIST_WINDOW and rec.damage >= ASSIST_MIN_DAMAGE then
			table.insert(assisters, p)
		end
	end
	table.clear(st.contributors)

	local distance = 0
	local vChar, kChar = victim.Character, killer and killer.Character
	local vRoot = vChar and vChar:FindFirstChild("HumanoidRootPart")
	local kRoot = kChar and kChar:FindFirstChild("HumanoidRootPart")
	if vRoot and kRoot and vRoot:IsA("BasePart") and kRoot:IsA("BasePart") then
		distance = math.floor((vRoot.Position - kRoot.Position).Magnitude + 0.5)
	end

	remotes.Kill:FireAllClients({
		killer = killer,
		victim = victim,
		weaponId = weaponId,
		headshot = headshot,
		killerSide = killer and sideOf(killer) or nil,
		victimSide = sideOf(victim),
		distance = distance,
		vehicleId = opts and opts.vehicleId or nil,
		assist = assisters[1],
	})
	Bus.fire("PlayerKilled", victim, killer, weaponId, headshot, assisters)
	for _, a in assisters do
		Bus.fire("PlayerAssist", a, victim, killer)
	end
	unequip(st)
end

-- Core player damage. Returns (killed, appliedAmount). Does not send hit confirms.
local function damagePlayer(
	victim: Player,
	amount: number,
	attacker: Player?,
	weaponId: string,
	headshot: boolean,
	fromPosition: Vector3?,
	ignoreFriendlyFire: boolean?,
	opts: any
): (boolean, number)
	local character = victim.Character
	local hum = getHumanoid(character)
	if not hum or hum.Health <= 0 or amount ~= amount or amount <= 0 then
		return false, 0
	end
	if attacker and attacker ~= victim then
		if not ignoreFriendlyFire and sameSide(attacker, victim) then
			return false, 0
		end
		if character and character:GetAttribute("SpawnProtected") == true then
			return false, 0
		end
	end
	local st = states[victim]
	local applied = math.min(amount, hum.Health)
	hum.Health = math.max(0, hum.Health - amount)
	local t = now()
	if st then
		st.lastDamaged = t
		st.lastHeadshot = headshot
		if attacker and attacker ~= victim then
			local rec = st.contributors[attacker]
			if rec then
				rec.damage += applied
				rec.time = t
			else
				st.contributors[attacker] = { damage = applied, time = t }
			end
		end
	end
	remotes.Damaged:FireClient(victim, { amount = applied, fromPosition = fromPosition, weaponId = weaponId })
	Bus.fire("PlayerDamaged", victim, attacker, applied, weaponId)
	if hum.Health <= 0 then
		handleDeath(victim, attacker, weaponId, headshot, opts)
		return true, applied
	end
	return false, applied
end

-- Damage to a non-player humanoid (training dummies, NPCs). Returns (killed, applied).
local function damageNpc(hum: Humanoid, amount: number): (boolean, number)
	if hum.Health <= 0 or amount <= 0 then
		return false, 0
	end
	local applied = math.min(amount, hum.Health)
	hum.Health = math.max(0, hum.Health - amount)
	return hum.Health <= 0, applied
end

local function hitConfirm(attacker: Player?, damage: number, headshot: boolean, killed: boolean, target: string)
	if attacker and attacker.Parent and damage > 0 then
		remotes.HitConfirm:FireClient(attacker, {
			damage = math.floor(damage + 0.5),
			headshot = headshot,
			killed = killed,
			target = target,
		})
	end
end

local function damageVehicle(
	vehicle: Model,
	amount: number,
	attacker: Player?,
	weaponId: string,
	pos: Vector3?,
	opts: any
)
	if amount <= 0 or vehicle:GetAttribute("Destroyed") == true then
		return false
	end
	if attacker then
		local vSide = vehicle:GetAttribute("Side")
		local aSide = sideOf(attacker)
		if type(vSide) == "string" and vSide ~= "" and vSide == aSide then
			return false -- friendly fire off for vehicles too
		end
	end
	local vs = getService("VehicleService")
	if vs and type(vs.ApplyDamage) == "function" then
		local ok, err = pcall(vs.ApplyDamage, vehicle, amount, attacker, weaponId, pos, opts)
		if not ok then
			warn(`[CombatService] VehicleService.ApplyDamage failed: {err}`)
			return false
		end
		return true
	end
	return false
end

-------------------------------------------------------------------------------------------------
-- Explosions
-------------------------------------------------------------------------------------------------

local function hasLineOfSight(from: Vector3, to: Vector3, ignoreModel: Instance?): boolean
	refreshWorldParams()
	local delta = to - from
	local result = workspace:Raycast(from, delta, worldParams)
	if not result then
		return true
	end
	if ignoreModel and result.Instance:IsDescendantOf(ignoreModel) then
		return true
	end
	return (result.Position - to).Magnitude < 0.75
end

local function explodeInternal(
	position: Vector3,
	radius: number,
	maxDamage: number,
	attacker: Player?,
	weaponId: string,
	vehicleDamage: number,
	kind: string,
	directVehicle: Model?,
	penetration: number?
)
	table.clear(scratchCharDist)
	table.clear(scratchVehicleDist)
	table.clear(scratchConfirm)

	if radius > 0 then
		local parts = workspace:GetPartBoundsInRadius(position, radius, overlapParams)
		for _, part in parts do
			local character, hum = Ballistics.findCharacter(part)
			if character and hum then
				local d = Ballistics.distanceToBox(position, part.CFrame, part.Size)
				local prev = scratchCharDist[character]
				if not prev or d < prev then
					scratchCharDist[character] = d
				end
			else
				local vehicle = Ballistics.findVehicle(part)
				if vehicle then
					local d = Ballistics.distanceToBox(position, part.CFrame, part.Size)
					local prev = scratchVehicleDist[vehicle]
					if not prev or d < prev then
						scratchVehicleDist[vehicle] = d
					end
				end
			end
		end
	end

	-- Infantry
	if maxDamage > 0 then
		for character, d in scratchCharDist do
			local hum = character:FindFirstChildOfClass("Humanoid")
			if not hum or hum.Health <= 0 then
				continue
			end
			local root = character:FindFirstChild("HumanoidRootPart")
			local head = character:FindFirstChild("Head")
			local visible = (root and root:IsA("BasePart") and hasLineOfSight(position, root.Position))
				or (head and head:IsA("BasePart") and hasLineOfSight(position, head.Position))
			if not visible then
				continue
			end
			local dmg = Ballistics.explosionDamage(maxDamage, d, radius)
			if dmg < 1 then
				continue
			end
			local victim = Players:GetPlayerFromCharacter(character)
			local killed, applied
			if victim then
				killed, applied = damagePlayer(victim, dmg, attacker, weaponId, false, position, false, nil)
			else
				killed, applied = damageNpc(hum, dmg)
			end
			if attacker and attacker ~= victim and applied > 0 then
				local agg = scratchConfirm[attacker]
				if agg then
					agg.damage += applied
					agg.killed = agg.killed or killed
				else
					scratchConfirm[attacker] = { damage = applied, killed = killed }
				end
			end
		end
	end

	-- Vehicles
	if vehicleDamage > 0 then
		if directVehicle and not scratchVehicleDist[directVehicle] then
			scratchVehicleDist[directVehicle] = 0
		end
		local vOpts = { explosive = true, penetration = penetration or 0.5 }
		for vehicle, d in scratchVehicleDist do
			local amount
			if vehicle == directVehicle then
				amount = vehicleDamage
			else
				amount = vehicleDamage * math.clamp(1 - d / math.max(radius, 1), 0, 1) ^ 1.5
			end
			if amount >= 1 and damageVehicle(vehicle, amount, attacker, weaponId, position, vOpts) then
				hitConfirm(attacker, amount, false, false, "vehicle")
			end
		end
	end

	for p, agg in scratchConfirm do
		hitConfirm(p, agg.damage, false, agg.killed, "player")
	end

	remotes.Explosion:FireAllClients({ position = position, radius = radius, kind = kind })
	Bus.fire("Explosion", position, radius, maxDamage, attacker)
end

-------------------------------------------------------------------------------------------------
-- Projectiles
-------------------------------------------------------------------------------------------------

type Projectile = {
	kind: string,
	def: any,
	owner: Player,
	part: BasePart,
	pos: Vector3,
	vel: Vector3,
	gravityScale: number,
	expiresAt: number,
	stuck: boolean,
	params: RaycastParams,
}
local stepped: { Projectile } = {}

local function makeProjectilePart(def: any, physics: boolean): BasePart
	local part = Instance.new("Part")
	part.Name = def.id
	part.Shape = Enum.PartType.Ball
	part.Size = if def.category == "Explosive" then Vector3.new(1.1, 1.1, 1.1) else Vector3.new(0.7, 0.7, 0.7)
	part.Color = Color3.fromRGB(70, 74, 52)
	part.Material = Enum.Material.Metal
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.CollisionGroup = Constants.COLLISION_GROUPS.Debris
	if physics then
		part.CanCollide = true
		part.CustomPhysicalProperties = PhysicalProperties.new(2.5, 0.8, 0.25, 1, 1)
	else
		part.Anchored = true
		part.CanCollide = false
	end
	-- Optional visual from WeaponModels, welded onto the (then invisible) collider
	local visual = buildWeaponModel(def.id, true)
	if visual then
		local handle = visual.PrimaryPart or visual:FindFirstChild("Handle")
		if handle and handle:IsA("BasePart") then
			for _, d in visual:GetDescendants() do
				if d:IsA("BasePart") then
					d.Anchored = false
					d.CanCollide = false
					d.CanQuery = false
					d.CanTouch = false
					d.Massless = true
				end
			end
			handle.CFrame = part.CFrame
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = part
			weld.Part1 = handle
			weld.Parent = part
			visual.Parent = part
			part.Transparency = 1
		else
			visual:Destroy()
		end
	end
	return part
end

local function detonate(def: any, owner: Player?, position: Vector3, directVehicle: Model?)
	local kind = if def.projectile == "rocket"
		then "rocket"
		elseif def.category == "Explosive" or def.category == "AntiTank" then "satchel"
		else "grenade"
	explodeInternal(
		position,
		def.blastRadius or 10,
		def.blastDamage or 100,
		owner,
		def.id,
		def.vehicleDamage or 0,
		kind,
		directVehicle,
		def.penetration
	)
end

local function deploySmoke(def: any, position: Vector3)
	local radius = def.smokeRadius or 22
	local duration = def.smokeDuration or 25
	local marker = Instance.new("Part")
	marker.Name = "SmokeScreen"
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.Transparency = 1
	marker.Size = Vector3.new(1, 1, 1)
	marker.Position = position
	marker:SetAttribute("Radius", radius)
	marker:SetAttribute("ExpiresAt", workspace:GetServerTimeNow() + duration)
	marker.Parent = smokeFolder
	CollectionService:AddTag(marker, "SmokeScreen")
	task.delay(duration, function()
		marker:Destroy()
	end)
	remotes.Smoke:FireAllClients({ position = position, radius = radius, duration = duration })
end

local function spawnPhysicsProjectile(def: any, owner: Player, origin: Vector3, velocity: Vector3, fuseLeft: number)
	local part = makeProjectilePart(def, true)
	part.CFrame = CFrame.new(origin)
	part.AssemblyLinearVelocity = velocity
	part.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8))
	part.Parent = projectileFolder
	pcall(part.SetNetworkOwner, part, nil)
	task.delay(math.max(0, fuseLeft), function()
		if not part.Parent then
			return
		end
		local pos = part.Position
		if def.projectile == "smoke" then
			part.Anchored = true
			deploySmoke(def, pos)
			task.delay(def.smokeDuration or 25, function()
				part:Destroy()
			end)
		else
			part:Destroy()
			detonate(def, owner, pos + Vector3.new(0, 0.4, 0), nil)
		end
	end)
end

local function spawnSteppedProjectile(def: any, owner: Player, origin: Vector3, velocity: Vector3)
	local st = states[owner]
	local part = makeProjectilePart(def, false)
	part.CFrame = CFrame.lookAt(origin, origin + velocity)
	part.Parent = projectileFolder
	local lifetime
	if def.projectile == "rocket" then
		lifetime = (def.range or 300) / math.max(velocity.Magnitude, 1) + 0.75
	else
		lifetime = def.fuse or 6
	end
	table.insert(stepped, {
		kind = def.projectile,
		def = def,
		owner = owner,
		part = part,
		pos = origin,
		vel = velocity,
		gravityScale = def.gravityScale or 1,
		expiresAt = now() + lifetime,
		stuck = false,
		params = st and st.rayParams or worldParams,
	})
end

local function stepProjectiles(dt: number)
	local t = now()
	local i = 1
	while i <= #stepped do
		local p = stepped[i]
		local remove = false
		if not p.part.Parent then
			remove = true
		elseif t >= p.expiresAt then
			-- Rockets self-destruct at max range, sticky/impact fuses run out.
			remove = true
			p.part:Destroy()
			detonate(p.def, p.owner, p.pos, nil)
		elseif not p.stuck then
			local step = p.vel * dt
			local result = workspace:Raycast(p.pos, step, p.params)
			if result then
				local hitPos = result.Position + result.Normal * 0.3
				if p.kind == "sticky" then
					p.stuck = true
					p.pos = hitPos
					p.part.CFrame = CFrame.new(hitPos)
					local target = result.Instance
					if not target.Anchored then
						p.part.Anchored = false
						p.part.Massless = true
						local weld = Instance.new("WeldConstraint")
						weld.Part0 = p.part
						weld.Part1 = target
						weld.Parent = p.part
					end
				else
					remove = true
					p.part:Destroy()
					detonate(p.def, p.owner, hitPos, Ballistics.findVehicle(result.Instance))
				end
			else
				p.pos += step
				p.vel += GRAVITY * (p.gravityScale * dt)
				p.part.CFrame = CFrame.lookAt(p.pos, p.pos + p.vel)
			end
		elseif not p.part.Anchored then
			p.pos = p.part.Position -- stuck to a moving vehicle
		end
		if remove then
			stepped[i] = stepped[#stepped]
			stepped[#stepped] = nil
		else
			i += 1
		end
	end
end

-------------------------------------------------------------------------------------------------
-- Remote handlers
-------------------------------------------------------------------------------------------------

local function validState(player: Player): (PlayerState?, Model?, BasePart?)
	local st = states[player]
	local character = player.Character
	if not st or not character or inVehicle(player) then
		return nil, nil, nil
	end
	local hum = getHumanoid(character)
	local head = character:FindFirstChild("Head")
	if not hum or hum.Health <= 0 or not head or not head:IsA("BasePart") then
		return nil, nil, nil
	end
	return st, character, head
end

local function onEquip(player: Player, payload: any)
	if not Net.rateLimit(player, "Combat_Equip", 10) or type(payload) ~= "table" then
		return
	end
	local slot = payload.slot
	if type(slot) ~= "string" or not SLOTS[slot] then
		return
	end
	local st = validState(player)
	if not st then
		return
	end
	local weaponId = st.loadout[slot]
	if type(weaponId) ~= "string" or weaponId == "" or not Weapons.get(weaponId) then
		return
	end
	equip(st, slot, weaponId)
end

-- Validates one claimed bullet and applies its damage. Accumulates hit confirms into `agg`.
-- Returns the impact position/normal/material for FX (or nil when the bullet hit nothing).
local function processShot(
	st: PlayerState,
	def: any,
	origin: Vector3,
	shot: any,
	maxDist: number,
	agg: { [string]: any }
): (Vector3?, Vector3?, string?)
	local dir = shot.dir
	if not Ballistics.isFiniteVector(dir) or dir.Magnitude < 0.5 then
		return nil, nil, nil
	end
	dir = dir.Unit

	local claimedHit = shot.hit
	local claimedPos = shot.pos
	if
		typeof(claimedHit) == "Instance"
		and claimedHit:IsA("BasePart")
		and claimedHit:IsDescendantOf(workspace)
		and Ballistics.isFiniteVector(claimedPos)
	then
		local toPos = claimedPos - origin
		local dist = toPos.Magnitude
		local character, hum = Ballistics.findCharacter(claimedHit)
		local vehicle = if character then nil else Ballistics.findVehicle(claimedHit)
		if
			(character or vehicle)
			and character ~= st.player.Character
			and dist <= maxDist
			and dist > 0.05
			and toPos.Unit:Dot(dir) >= AIM_TOLERANCE_COS
		then
			-- Lag tolerance: the claimed point must be near where the server sees the part.
			local speed = claimedHit.AssemblyLinearVelocity.Magnitude
			local slack = claimedHit.Size.Magnitude * 0.5 + HIT_LAG_TOLERANCE + speed * 0.25
			if (claimedHit.Position - claimedPos).Magnitude <= slack then
				-- World line of sight (characters ignored). One thin layer of cover can be penetrated.
				refreshWorldParams()
				local damageMult = 1
				local blocked = workspace:Raycast(origin, toPos, worldParams)
				if blocked and vehicle and blocked.Instance:IsDescendantOf(vehicle) then
					blocked = nil
				end
				if blocked and (blocked.Position - claimedPos).Magnitude > 1 then
					local wall = blocked.Instance
					local thickness = math.min(wall.Size.X, wall.Size.Y, wall.Size.Z)
					local canPen = (def.penetration or 0) > 0.25
						and thickness <= (def.penetration or 0) * 2
						and not CollectionService:HasTag(wall, Constants.TAGS.NoBulletPenetration)
					if canPen then
						local resume = blocked.Position + toPos.Unit * (thickness + 0.1)
						local second = workspace:Raycast(resume, claimedPos - resume, worldParams)
						if second and not (vehicle and second.Instance:IsDescendantOf(vehicle)) then
							return blocked.Position, blocked.Normal, blocked.Material.Name
						end
						damageMult = 0.6
					else
						return blocked.Position, blocked.Normal, blocked.Material.Name
					end
				end

				if character and hum then
					local partName = resolveBodyPart(character, claimedHit)
					local dmg, headshot = Ballistics.damageAt(def, dist, partName)
					dmg *= damageMult
					local victim = Players:GetPlayerFromCharacter(character)
					local killed, applied
					if victim then
						killed, applied = damagePlayer(victim, dmg, st.player, def.id, headshot, origin, false, nil)
					else
						killed, applied = damageNpc(hum, dmg)
					end
					if applied > 0 then
						agg.playerDamage += applied
						agg.headshot = agg.headshot or headshot
						agg.killed = agg.killed or killed
					end
				elseif vehicle then
					local amount
					if def.vehicleDamage then
						amount = def.vehicleDamage * damageMult
					else
						local class = getVehicleClass(vehicle)
						if class == "Tank" or class == "Light" or class == "AT" then
							amount = if class == "Light" then def.damage * 0.04 else 0
						else
							amount = def.damage * 0.2
						end
					end
					if
						amount > 0
						and damageVehicle(vehicle, amount, st.player, def.id, claimedPos, {
							penetration = def.penetration,
							explosive = false,
						})
					then
						agg.vehicleDamage += amount
					end
				end
				local material = claimedHit.Material.Name
				local normal = if Ballistics.isFiniteVector(shot.normal) and shot.normal.Magnitude > 0.5
					then shot.normal.Unit
					else -dir
				return claimedPos, normal, material
			end
		end
	end

	-- No (valid) claimed hit: authoritative ray for impact FX only.
	local result = workspace:Raycast(origin, dir * maxDist, st.rayParams)
	if result then
		return result.Position, result.Normal, result.Material.Name
	end
	return nil, nil, nil
end

local function onFire(player: Player, payload: any)
	if not Net.rateLimit(player, "Combat_Fire", 30) or type(payload) ~= "table" then
		return
	end
	local weaponId, origin, shots = payload.weaponId, payload.origin, payload.shots
	if type(weaponId) ~= "string" or not Ballistics.isFiniteVector(origin) or type(shots) ~= "table" then
		return
	end
	local st, character, head = validState(player)
	if not st or not character or not head then
		return
	end
	if st.weaponId ~= weaponId then
		return
	end
	local def = Weapons.get(weaponId)
	if not def or not Weapons.isFirearm(def) then
		return
	end
	local t = now()
	if t < st.equipReadyAt then
		return
	end
	local entry = st.ammo[weaponId]
	if not entry then
		return
	end
	if st.reloading then
		if def.reloadType == "single" then
			cancelReload(st, false) -- shotguns/tube rifles can interrupt a reload to fire
		elseif st.reloadEnd - t <= RELOAD_GRACE then
			cancelReload(st, false)
			finishMagazineReload(st, weaponId)
		else
			sendAmmo(st, weaponId)
			return
		end
	end
	if entry.mag <= 0 then
		sendAmmo(st, weaponId)
		return
	end
	-- Fire-rate budget: tolerates packet bunching but caps the long-run rate at the weapon's RPM.
	-- `fireClock` is the earliest time the next shot is allowed.
	if st.fireClock > t + 0.05 then
		return
	end
	local interval = 60 / math.max(def.rpm, 1) * FIRE_RATE_SLACK
	st.fireClock = math.max(st.fireClock, t - math.min(FIRE_BURST_WINDOW, interval * 0.5)) + interval
	-- Origin must be close to the server's view of the head (latency + movement slack).
	local root = character:FindFirstChild("HumanoidRootPart")
	local speed = root and root:IsA("BasePart") and root.AssemblyLinearVelocity.Magnitude or 0
	if (origin - head.Position).Magnitude > ORIGIN_TOLERANCE + speed * 0.15 then
		return
	end

	entry.mag -= 1
	st.lastShot = t
	if character:GetAttribute("SpawnProtected") == true then
		character:SetAttribute("SpawnProtected", false) -- Constants: protection is cancelled by firing
	end

	local maxShots = def.pellets or 1
	local maxDist = math.min(math.max(def.range * 1.5, 300), 2500)
	local agg = { playerDamage = 0, vehicleDamage = 0, headshot = false, killed = false }
	local fxHits = {}
	local count = 0
	for _, shot in shots do
		count += 1
		if count > maxShots then
			break
		end
		if type(shot) == "table" then
			local pos, normal, material = processShot(st, def, origin, shot, maxDist, agg)
			if pos then
				table.insert(fxHits, { pos = pos, normal = normal, material = material })
			end
		end
	end

	if agg.playerDamage > 0 then
		hitConfirm(player, agg.playerDamage, agg.headshot, agg.killed, "player")
	end
	if agg.vehicleDamage > 0 then
		hitConfirm(player, agg.vehicleDamage, false, false, "vehicle")
	end

	local fx = { shooter = player, weaponId = weaponId, origin = origin, hits = fxHits }
	for _, other in Players:GetPlayers() do
		if other ~= player then
			local oc = other.Character
			local oroot = oc and oc:FindFirstChild("HumanoidRootPart")
			if oroot and oroot:IsA("BasePart") and (oroot.Position - origin).Magnitude <= MAX_FX_DISTANCE then
				remotes.ShotFX:FireClient(other, fx)
			end
		end
	end
end

local function onReload(player: Player, payload: any)
	if not Net.rateLimit(player, "Combat_Reload", 4) or type(payload) ~= "table" then
		return
	end
	local weaponId = payload.weaponId
	local st = validState(player)
	if not st or type(weaponId) ~= "string" or st.weaponId ~= weaponId then
		return
	end
	if not startReload(st, weaponId) then
		sendAmmo(st, weaponId)
	end
end

local function onThrow(player: Player, payload: any)
	if not Net.rateLimit(player, "Combat_Throw", 5) or type(payload) ~= "table" then
		return
	end
	local weaponId, origin, velocity = payload.weaponId, payload.origin, payload.velocity
	if
		type(weaponId) ~= "string"
		or not Ballistics.isFiniteVector(origin)
		or not Ballistics.isFiniteVector(velocity)
	then
		return
	end
	local st, character, head = validState(player)
	if not st or not character or not head then
		return
	end
	-- Weapon must be in the loadout (quick-grenade may throw without equipping the slot).
	local owned = false
	for _, id in st.loadout do
		if id == weaponId then
			owned = true
			break
		end
	end
	local def = Weapons.get(weaponId)
	if not owned or not def then
		return
	end
	local launcher = Weapons.isLauncher(def)
	if not launcher and not Weapons.isThrown(def) then
		return
	end
	local entry = st.ammo[weaponId]
	if not entry then
		return
	end
	local t = now()
	if launcher then
		if st.weaponId ~= weaponId or t < st.equipReadyAt or t - st.lastLaunch < LAUNCH_COOLDOWN then
			return
		end
		if st.reloading then
			if st.reloadEnd - t <= RELOAD_GRACE then
				cancelReload(st, false)
				finishMagazineReload(st, weaponId)
			else
				return
			end
		end
	elseif t - st.lastThrow < THROW_COOLDOWN then
		return
	end
	if entry.mag <= 0 then
		sendAmmo(st, weaponId)
		return
	end
	if (origin - head.Position).Magnitude > ORIGIN_TOLERANCE then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local carrier = root and root:IsA("BasePart") and root.AssemblyLinearVelocity or Vector3.zero
	local maxSpeed = (if launcher then def.bulletVelocity else def.throwSpeed or 80) * 1.2
	local speed = velocity.Magnitude
	if speed < 1 then
		return
	end
	if (velocity - carrier).Magnitude > maxSpeed + 5 then
		velocity = velocity.Unit * maxSpeed
	end

	entry.mag -= 1
	sendAmmo(st, weaponId)
	if launcher then
		st.lastLaunch = t
	else
		st.lastThrow = t
	end
	if character:GetAttribute("SpawnProtected") == true then
		character:SetAttribute("SpawnProtected", false)
	end

	local kind = def.projectile
	if kind == "frag" or kind == "smoke" or kind == "satchel" then
		local fuse = def.fuse or 4
		local cook = 0
		if def.cookable and type(payload.cook) == "number" and payload.cook == payload.cook then
			cook = math.clamp(payload.cook, 0, fuse)
		end
		local left = fuse - cook
		if left <= 0.05 then
			detonate(def, player, head.Position, nil) -- cooked too long
		else
			spawnPhysicsProjectile(def, player, origin, velocity, left)
		end
	else
		spawnSteppedProjectile(def, player, origin, velocity)
	end
end

local function onMelee(player: Player, payload: any)
	if not Net.rateLimit(player, "Combat_Melee", 4) or type(payload) ~= "table" then
		return
	end
	local target = payload.target
	if typeof(target) ~= "Instance" or not target:IsA("Model") or not target:IsDescendantOf(workspace) then
		return
	end
	local st, character = validState(player)
	if not st or not character or target == character then
		return
	end
	local knife = Weapons.get(Weapons.MELEE_ID)
	if not knife then
		return
	end
	local t = now()
	if t - st.lastMelee < (knife.meleeCooldown or 0.65) * 0.85 then
		return
	end
	local myRoot = character:FindFirstChild("HumanoidRootPart")
	local targetRoot = target:FindFirstChild("HumanoidRootPart")
	local hum = target:FindFirstChildOfClass("Humanoid")
	if not myRoot or not targetRoot or not hum or hum.Health <= 0 then
		return
	end
	if not myRoot:IsA("BasePart") or not targetRoot:IsA("BasePart") then
		return
	end
	local delta = targetRoot.Position - myRoot.Position
	if delta.Magnitude > (knife.meleeRange or 6) + MELEE_LAG_BONUS then
		return
	end
	if not hasLineOfSight(myRoot.Position, targetRoot.Position, nil) then
		return
	end
	st.lastMelee = t

	-- Backstab: attacker is behind the victim (victim facing away).
	local look = targetRoot.CFrame.LookVector * Vector3.new(1, 0, 1)
	local toAttacker = (myRoot.Position - targetRoot.Position) * Vector3.new(1, 0, 1)
	local backstab = look.Magnitude > 0.01
		and toAttacker.Magnitude > 0.01
		and look.Unit:Dot(toAttacker.Unit) < BACKSTAB_DOT
	local damage = if backstab then BACKSTAB_DAMAGE else knife.damage

	local victim = Players:GetPlayerFromCharacter(target)
	local killed, applied
	if victim then
		killed, applied = damagePlayer(victim, damage, player, knife.id, false, myRoot.Position, false, nil)
	else
		killed, applied = damageNpc(hum, damage)
	end
	hitConfirm(player, applied, false, killed, "player")
end

-------------------------------------------------------------------------------------------------
-- Character lifecycle
-------------------------------------------------------------------------------------------------

local function fallbackLoadout(player: Player): { [string]: string }?
	local raw = player:GetAttribute("Loadout")
	if type(raw) == "string" and raw ~= "" then
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	local classId = player:GetAttribute("Class")
	local factionId = player:GetAttribute("Faction")
	if type(classId) ~= "string" or classId == "" then
		classId = "Rifleman"
	end
	if type(factionId) ~= "string" or factionId == "" then
		factionId = if sideOf(player) == "Axis" then "DE" else "US"
	end
	return Weapons.defaultLoadout(classId, factionId)
end

local function onCharacterAdded(player: Player, character: Model)
	local st = states[player]
	if not st then
		return
	end
	st.charTrove:Clean()
	detachWeaponModel(st)
	cancelReload(st, false)
	st.slot = nil
	st.weaponId = nil
	st.deathHandled = false
	st.lastDamaged = 0
	st.charAddedAt = now()
	table.clear(st.contributors)
	player:SetAttribute("EquippedWeapon", "")

	st.rayParams.FilterDescendantsInstances = { character, projectileFolder, smokeFolder }
	table.insert(characterList, character)
	worldParamsDirty = true

	-- Combat owns regeneration: remove Roblox's default Health regen script.
	local function stripHealthScript(child: Instance)
		if child.Name == "Health" and child:IsA("Script") then
			child:Destroy()
		end
	end
	for _, c in character:GetChildren() do
		stripHealthScript(c)
	end
	st.charTrove:Connect(character.ChildAdded, stripHealthScript)

	st.charTrove:Add(function()
		local idx = table.find(characterList, character)
		if idx then
			table.remove(characterList, idx)
			worldParamsDirty = true
		end
	end)
	st.charTrove:Connect(character.AncestryChanged, function(_, parent)
		if parent == nil then
			st.charTrove:Clean()
		end
	end)

	local hum = character:WaitForChild("Humanoid", 10)
	if hum and hum:IsA("Humanoid") and character.Parent then
		st.charTrove:Connect(hum.Died, function()
			unequip(st)
		end)
	end

	-- Fallback: if SpawnService did not call GiveLoadout around this spawn, build one ourselves.
	task.delay(1.0, function()
		if player.Character ~= character or not states[player] then
			return
		end
		if st.loadoutTime < st.charAddedAt - 2 then
			local loadout = fallbackLoadout(player)
			if loadout then
				CombatService.GiveLoadout(player, loadout)
			end
		end
	end)
end

local function onPlayerAdded(player: Player)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { projectileFolder, smokeFolder }
	local st: PlayerState = {
		player = player,
		loadout = {},
		ammo = {},
		slot = nil,
		weaponId = nil,
		equipReadyAt = 0,
		fireClock = 0,
		lastShot = 0,
		reloading = false,
		reloadEnd = 0,
		reloadThread = nil,
		lastMelee = 0,
		lastThrow = 0,
		lastLaunch = 0,
		lastDamaged = 0,
		loadoutTime = -math.huge,
		charAddedAt = 0,
		contributors = {},
		deathHandled = false,
		lastHeadshot = false,
		weaponModel = nil,
		rayParams = params,
		charTrove = Trove.new(),
	}
	states[player] = st
	player:SetAttribute("EquippedWeapon", "")
	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
	player:GetAttributeChangedSignal("VehicleUid"):Connect(function()
		if inVehicle(player) and states[player] then
			unequip(st)
		end
	end)
end

local function onPlayerRemoving(player: Player)
	local st = states[player]
	if not st then
		return
	end
	cancelReload(st, false)
	st.charTrove:Clean()
	detachWeaponModel(st)
	states[player] = nil
	for _, other in states do
		other.contributors[player] = nil
	end
end

-------------------------------------------------------------------------------------------------
-- Health regeneration
-------------------------------------------------------------------------------------------------

local regenAccum = 0
local function regenTick(dt: number)
	regenAccum += dt
	if regenAccum < REGEN_TICK then
		return
	end
	local step = regenAccum
	regenAccum = 0
	local t = now()
	for player, st in states do
		if t - st.lastDamaged < Constants.HEALTH_REGEN_DELAY then
			continue
		end
		local hum = getHumanoid(player.Character)
		if not hum or hum.Health <= 0 or hum.Health >= hum.MaxHealth then
			continue
		end
		local cap = if hasPerk(player, "FullRegen")
			then hum.MaxHealth
			else math.min(Constants.HEALTH_REGEN_CAP, hum.MaxHealth)
		if hum.Health < cap then
			hum.Health = math.min(cap, hum.Health + Constants.HEALTH_REGEN_RATE * step)
		end
	end
end

-------------------------------------------------------------------------------------------------
-- Public API (docs/ARCHITECTURE.md section 7)
-------------------------------------------------------------------------------------------------

-- Returns true if the victim was killed. opts: {headshot, fromPosition, ignoreFriendlyFire, vehicleId,
-- noHitConfirm}. Sends Combat_HitConfirm to the attacker unless opts.noHitConfirm.
function CombatService.ApplyPlayerDamage(
	victim: Player,
	amount: number,
	attacker: Player?,
	weaponId: string,
	opts: { [string]: any }?
): boolean
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") or type(amount) ~= "number" then
		return false
	end
	local o: { [string]: any } = opts or EMPTY
	local killed, applied = damagePlayer(
		victim,
		amount,
		attacker,
		weaponId or "",
		o.headshot == true,
		o.fromPosition,
		o.ignoreFriendlyFire == true,
		o
	)
	if attacker and attacker ~= victim and not o.noHitConfirm then
		hitConfirm(attacker, applied, o.headshot == true, killed, "player")
	end
	return killed
end

function CombatService.Explode(
	position: Vector3,
	radius: number,
	maxDamage: number,
	attacker: Player?,
	weaponId: string,
	opts: { [string]: any }?
)
	if not Ballistics.isFiniteVector(position) then
		return
	end
	local o: { [string]: any } = opts or EMPTY
	explodeInternal(
		position,
		radius,
		maxDamage,
		attacker,
		weaponId or "",
		o.vehicleDamage or 0,
		o.kind or "grenade",
		o.directVehicle,
		o.penetration
	)
end

function CombatService.GiveLoadout(player: Player, loadout: { [string]: string })
	local st = states[player]
	if not st or type(loadout) ~= "table" then
		return
	end
	cancelReload(st, false)
	table.clear(st.loadout)
	table.clear(st.ammo)
	for _, slot in { "primary", "secondary", "gadget1", "gadget2" } do
		local id = loadout[slot]
		if type(id) == "string" and Weapons.get(id) then
			st.loadout[slot] = id
		end
	end
	st.loadout.melee = Weapons.MELEE_ID
	local extraGrenade = hasPerk(player, "ExtraGrenade")
	for _, id in st.loadout do
		local def = Weapons.get(id)
		if def and not st.ammo[id] then
			local mag = def.magazine
			if extraGrenade and def.category == "Grenade" then
				mag += 1
			end
			st.ammo[id] = { mag = mag, reserve = def.reserve }
		end
	end
	st.loadoutTime = now()
	st.fireClock = 0
	sendAllAmmo(st)
	if isAlive(player) and not inVehicle(player) then
		local first = st.loadout.primary or st.loadout.secondary
		if first then
			equip(st, if st.loadout.primary then "primary" else "secondary", first)
		end
	end
end

-- Refills `fraction` (0..1) of each weapon's max reserve; throwables/launchers get +1 item.
function CombatService.Resupply(player: Player, fraction: number): boolean
	local st = states[player]
	if not st or type(fraction) ~= "number" or fraction <= 0 then
		return false
	end
	local changed = false
	local extraGrenade = hasPerk(player, "ExtraGrenade")
	for id, entry in st.ammo do
		local def = Weapons.get(id)
		if not def or Weapons.isGadget(def) or def.category == "Melee" then
			continue
		end
		if Weapons.isThrown(def) then
			local max = def.magazine + (if extraGrenade and def.category == "Grenade" then 1 else 0)
			if entry.mag < max then
				entry.mag += 1
				changed = true
				sendAmmo(st, id)
			end
		elseif def.reserve > 0 and entry.reserve < def.reserve then
			local add = math.max(1, math.ceil(def.reserve * math.min(fraction, 1)))
			entry.reserve = math.min(def.reserve, entry.reserve + add)
			changed = true
			sendAmmo(st, id)
		end
	end
	return changed
end

-- Heals up to MaxHealth. Returns hp actually healed.
function CombatService.Heal(player: Player, amount: number, healer: Player?): number
	local hum = getHumanoid(player.Character)
	if not hum or hum.Health <= 0 or type(amount) ~= "number" or amount <= 0 then
		return 0
	end
	local before = hum.Health
	hum.Health = math.min(hum.MaxHealth, before + amount)
	return hum.Health - before
end

-- Contract additions (section 9)
function CombatService.GetEquipped(player: Player): string?
	local st = states[player]
	return st and st.weaponId or nil
end

function CombatService.GetAmmo(player: Player, weaponId: string): (number, number)
	local st = states[player]
	local entry = st and st.ammo[weaponId]
	if entry then
		return entry.mag, entry.reserve
	end
	return 0, 0
end

function CombatService.Unequip(player: Player)
	local st = states[player]
	if st then
		unequip(st)
	end
end

-- Seconds since the player last took damage (math.huge if never this life).
function CombatService.TimeSinceDamaged(player: Player): number
	local st = states[player]
	if not st or st.lastDamaged == 0 then
		return math.huge
	end
	return now() - st.lastDamaged
end

-------------------------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------------------------

function CombatService:Init()
	local function ensureFolder(name: string): Folder
		local existing = workspace:FindFirstChild(name)
		if existing and existing:IsA("Folder") then
			return existing
		end
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = workspace
		return f
	end
	projectileFolder = ensureFolder("CombatProjectiles")
	smokeFolder = ensureFolder("SmokeScreens")
	overlapParams.FilterDescendantsInstances = { projectileFolder, smokeFolder }

	-- Client -> server
	remotes.Equip = Net.event("Combat_Equip")
	remotes.Fire = Net.event("Combat_Fire")
	remotes.Reload = Net.event("Combat_Reload")
	remotes.Throw = Net.event("Combat_Throw")
	remotes.Melee = Net.event("Combat_Melee")
	-- Server -> client
	remotes.Kill = Net.event("Combat_Kill")
	remotes.HitConfirm = Net.event("Combat_HitConfirm")
	remotes.Damaged = Net.event("Combat_Damaged")
	remotes.Ammo = Net.event("Combat_Ammo")
	remotes.ShotFX = Net.unreliable("Combat_ShotFX")
	remotes.Explosion = Net.event("FX_Explosion")
	remotes.Smoke = Net.event("FX_Smoke")
end

function CombatService:Start()
	remotes.Equip.OnServerEvent:Connect(onEquip)
	remotes.Fire.OnServerEvent:Connect(onFire)
	remotes.Reload.OnServerEvent:Connect(onReload)
	remotes.Throw.OnServerEvent:Connect(onThrow)
	remotes.Melee.OnServerEvent:Connect(onMelee)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		if not states[p] then
			onPlayerAdded(p)
		end
	end

	RunService.Heartbeat:Connect(function(dt)
		if #stepped > 0 then
			stepProjectiles(dt)
		end
		regenTick(dt)
	end)
end

return CombatService
