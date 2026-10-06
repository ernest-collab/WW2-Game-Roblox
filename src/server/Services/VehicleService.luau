--[[
	VehicleService (server, Vehicle team): spawning, seats, network ownership, turret state,
	main guns (simulated shells with armor model), machine guns, damage/repair/destruction.

	Public API (docs/ARCHITECTURE.md section 7):
	  VehicleService.ApplyDamage(vehicle, amount, attacker?, weaponId, hitPosition?, opts?) -> number (applied)
	  VehicleService.Repair(vehicle, amount, repairer?) -> number (repaired)
	  VehicleService.SpawnTeamVehicles(mapInfo) / VehicleService.ClearAll()
	  VehicleService.GetVehicleOf(player) -> Model?
	  VehicleService.Eject(player)                     -- force a player out (e.g. on despawn)

	Lifecycle of a vehicle ("mode"):
	  Parked   : no driver; Chassis anchored at its spot (no physics cost, no replication).
	  Driven   : driver seated; unanchored, network ownership given to the driver, whose
	             VehicleController runs VehicleModels.Physics. Server checks speed sanity.
	  Settling : driver left; server simulates with zero input until it stops, then anchors.
	  Wreck    : destroyed; burning hulk, despawned after Vehicles.DAMAGE.WRECK_TIME.
	Emplaced guns (def.static) are always anchored.

	Turret replication: the driver/gunner sends `Vehicle_Aim` (unreliable, <= 30 Hz) with the
	desired turret yaw / gun pitch (radians, hull-relative). The server slews toward it at the
	configured traverse/elevation rates (authoritative for the shell origin) and mirrors the
	result to model attributes TurretYaw / GunPitch / MGYaw / MGPitch (<= 15 Hz) which every
	client applies to the Motor6D Transforms.

	Damage model: see the header of Config/Vehicles.luau.
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Constants = require(Shared.Config.Constants)
local Factions = require(Shared.Config.Factions)
local GameModes = require(Shared.Config.GameModes)
local GameState = require(Shared.GameState)
local Net = require(Shared.Util.Net)
local Trove = require(Shared.Util.Trove)
local VehicleModels = require(Shared.VehicleModels)
local Vehicles = require(Shared.Config.Vehicles)

local Physics = VehicleModels.Physics
local DAMAGE = Vehicles.DAMAGE
local VEHICLE_TAG = Constants.TAGS.Vehicle

local VehicleService = {}

---------------------------------------------------------------------------------------------------
-- Tunables
---------------------------------------------------------------------------------------------------

local ENTER_RANGE = 12 -- studs beyond the hull half-diagonal
local AIM_RATE = 30 -- Vehicle_Aim messages / s accepted
local FIRE_RATE = 30 -- Vehicle_Fire messages / s accepted
local REQUEST_RATE = 6
local SLEW_TOLERANCE = 1.15 -- server allows slightly faster traverse than config (latency jitter)
local MG_SLEW_RATE = math.rad(220)
local ATTR_SYNC_INTERVAL = 1 / 15
local SHELL_LIFETIME = 4
local AIM_TRUST_ANGLE = math.rad(3) -- use the client's aim point if within this of the server bore axis
local MG_AIM_TRUST_ANGLE = math.rad(6)
local SETTLE_MAX_TIME = 8
local ABANDON_TIME = 120 -- idle, unoccupied and away from its spawn -> respawn at base
local ABANDON_DISTANCE = 40
local FLIPPED_TIME = 15
local SPEED_TOLERANCE = 1.5 -- x top speed (+ flat margin) before ownership is revoked
local SPEED_MARGIN = 25
local SPEED_VIOLATION_TIME = 1
local REVOKE_TIME = 2
local RAM_INTERVAL = 0.1
local RAM_COOLDOWN = 0.75
local CRITICAL_SMOKE_RATE = 12

---------------------------------------------------------------------------------------------------
-- Types & state
---------------------------------------------------------------------------------------------------

type MGState = {
	mag: number,
	heat: number,
	lastShot: number,
	nextShot: number,
	reloadUntil: number,
	overheatUntil: number,
}

type Slot = {
	side: string,
	class: string,
	cframe: CFrame,
	rotation: number,
	current: VState?,
	respawnAt: number,
}

type VState = {
	uid: string,
	def: any,
	model: Model,
	chassis: BasePart,
	side: string,
	faction: string,
	health: number,
	destroyed: boolean,
	slot: Slot?,
	seats: { [string]: Seat },
	occupants: { [string]: Player },
	driver: Player?,
	rig: any?,
	mode: string,
	modeSince: number,
	turretYaw: number,
	gunPitch: number,
	targetYaw: number,
	targetPitch: number,
	mgYaw: number,
	mgPitch: number,
	mgTargetYaw: number,
	mgTargetPitch: number,
	lastSync: number,
	syncedYaw: number,
	syncedPitch: number,
	syncedMgYaw: number,
	syncedMgPitch: number,
	ammoIndex: number,
	mag: number,
	nextMainShot: number,
	reloadUntil: number,
	mgs: { [string]: MGState },
	lastOccupied: number,
	flippedSince: number?,
	speedViolation: number,
	revokedUntil: number,
	lastRam: number,
	ramHits: { [Player]: number },
	critical: boolean,
	smoke: ParticleEmitter?,
	prompt: ProximityPrompt?,
	wreckUntil: number,
	trove: any,
}

type Shell = {
	pos: Vector3,
	vel: Vector3,
	shell: any,
	shooter: Player?,
	source: VState,
	born: number,
	params: RaycastParams,
}

type CharRecord = { [Instance]: { number | boolean } }

local vehicles: { [string]: VState } = {}
local byModel: { [Model]: VState } = {}
local slots: { Slot } = {}
local playerSeat: { [Player]: { st: VState, seatId: string } } = {}
local charRecords: { [Player]: CharRecord } = {}
local shells: { Shell } = {}
local rng = Random.new()
local vehicleFolder: Folder
local currentMapInfo: any = nil

local remotes: {
	Request: RemoteEvent,
	Fire: RemoteEvent,
	State: RemoteEvent,
	Weapon: RemoteEvent,
	Aim: UnreliableRemoteEvent,
	FX: UnreliableRemoteEvent,
	HitConfirm: RemoteEvent,
	Notify: RemoteEvent,
	Explosion: RemoteEvent,
} =
	nil :: any

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

local serviceCache: { [string]: any } = {}
local function getService(name: string): any
	local cached = serviceCache[name]
	if cached ~= nil then
		return cached or nil
	end
	local folder = script.Parent
	local mod = folder and folder:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return nil -- not cached: may exist later during development
	end
	local ok, result = pcall(require, mod)
	serviceCache[name] = if ok then result else false
	return if ok then result else nil
end

local function now(): number
	return os.clock()
end

local function serverTime(): number
	return workspace:GetServerTimeNow()
end

local function isFinite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isFiniteVector(v: any): boolean
	return typeof(v) == "Vector3" and isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)
end

local function wrapAngle(a: number): number
	return (a + math.pi) % (2 * math.pi) - math.pi
end

local function approachAngle(current: number, target: number, maxStep: number): number
	local d = wrapAngle(target - current)
	return wrapAngle(current + math.clamp(d, -maxStep, maxStep))
end

local function sideOf(player: Player?): string?
	if not player then
		return nil
	end
	local s = player:GetAttribute("Side")
	if type(s) == "string" and s ~= "" then
		return s
	end
	return if player.Team then player.Team.Name else nil
end

local function humanoidOf(player: Player): Humanoid?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		return hum
	end
	return nil
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function notify(player: Player, text: string, kind: string?)
	remotes.Notify:FireClient(player, { text = text, kind = kind or "info", duration = 2.5 })
end

local function findVehicleModel(inst: Instance?): Model?
	local node = inst
	for _ = 1, 12 do
		if not node or node == workspace then
			return nil
		end
		if node:IsA("Model") and CollectionService:HasTag(node, VEHICLE_TAG) then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function seatDefOf(st: VState, seatId: string): any
	return Vehicles.getSeat(st.def, seatId)
end

local function occupantsList(st: VState): { Player }
	local list = {}
	for _, p in st.occupants do
		table.insert(list, p)
	end
	return list
end

local function occupantCharacters(st: VState): { Instance }
	local list: { Instance } = {}
	for _, p in st.occupants do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

local function modeUsesVehicles(): boolean
	local modeId = GameState.get("ModeId")
	local mode = type(modeId) == "string" and GameModes.byId[modeId] or nil
	if not mode then
		return true -- unknown / fallback mode: allow vehicles if the map provides spawns
	end
	return mode.usesVehicles
end

-- Explosion through CombatService (players + vehicles + FX + Bus) with a minimal fallback.
local function explode(
	position: Vector3,
	radius: number,
	damage: number,
	attacker: Player?,
	weaponId: string,
	kind: string,
	vehicleDamage: number
)
	local combat = getService("CombatService")
	if combat and type(combat.Explode) == "function" then
		local ok, err = pcall(combat.Explode, position, radius, damage, attacker, weaponId, {
			kind = kind,
			vehicleDamage = vehicleDamage,
		})
		if ok then
			return
		end
		warn(`[VehicleService] CombatService.Explode failed: {err}`)
	end
	remotes.Explosion:FireAllClients({ position = position, radius = radius, kind = kind })
	Bus.fire("Explosion", position, radius, damage, attacker)
	for _, p in Players:GetPlayers() do
		local hum = humanoidOf(p)
		local root = rootOf(p)
		if hum and root and (p == attacker or sideOf(p) ~= sideOf(attacker)) then
			local d = (root.Position - position).Magnitude
			if d < radius then
				hum:TakeDamage(damage * (1 - d / radius))
			end
		end
	end
end

-- Player damage through CombatService (kill feed, scoring) with a minimal fallback.
local function damagePlayer(
	victim: Player,
	amount: number,
	attacker: Player?,
	weaponId: string,
	opts: { [string]: any }
)
	local combat = getService("CombatService")
	if combat and type(combat.ApplyPlayerDamage) == "function" then
		local ok, result = pcall(combat.ApplyPlayerDamage, victim, amount, attacker, weaponId, opts)
		if ok then
			return result == true
		end
		warn(`[VehicleService] CombatService.ApplyPlayerDamage failed: {result}`)
	end
	local hum = humanoidOf(victim)
	if hum then
		hum:TakeDamage(amount)
		return hum.Health <= 0
	end
	return false
end

local function hitConfirm(player: Player?, damage: number, killed: boolean, result: string?)
	if player and player.Parent and damage > 0 then
		remotes.HitConfirm:FireClient(player, {
			damage = math.floor(damage + 0.5),
			headshot = false,
			killed = killed,
			target = "vehicle",
			result = result,
		})
	end
end

---------------------------------------------------------------------------------------------------
-- Weapon state sync
---------------------------------------------------------------------------------------------------

local function sendWeapon(player: Player, st: VState, weaponId: string)
	local t = now()
	local def = st.def
	if weaponId == "main" then
		local gun = def.weapons.main
		if not gun then
			return
		end
		local shell = gun.ammo[st.ammoIndex]
		local ready = math.max(st.reloadUntil, st.nextMainShot)
		remotes.Weapon:FireClient(player, {
			uid = st.uid,
			weapon = "main",
			ammo = shell and shell.kind or "AP",
			ammoIndex = st.ammoIndex,
			mag = st.mag,
			reloading = st.reloadUntil > t,
			readyAt = serverTime() + math.max(0, ready - t),
		})
	else
		local ms = st.mgs[weaponId]
		if not ms then
			return
		end
		local mgDef = def.weapons[weaponId]
		local heat = math.max(0, ms.heat - mgDef.coolRate * (t - ms.lastShot))
		remotes.Weapon:FireClient(player, {
			uid = st.uid,
			weapon = weaponId,
			mag = ms.mag,
			heat = heat,
			overheated = ms.overheatUntil > t,
			reloading = ms.reloadUntil > t,
			readyAt = serverTime() + math.max(0, math.max(ms.reloadUntil, ms.overheatUntil) - t),
		})
	end
end

local function sendSeatWeapons(player: Player, st: VState, seatId: string)
	local seatDef = seatDefOf(st, seatId)
	if seatDef and seatDef.weapons then
		for _, w in seatDef.weapons do
			sendWeapon(player, st, w)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Character visibility while seated
---------------------------------------------------------------------------------------------------

-- Hidden seats: occupant invisible and not hittable (inside the armor). Every seated character is
-- made massless so it does not upset the vehicle's handling.
local function storeCharacter(player: Player, hidden: boolean)
	local char = player.Character
	if not char or charRecords[player] then
		return
	end
	local rec: CharRecord = {}
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then
			rec[d] = { d.Transparency, d.CanQuery, d.Massless }
			d.Massless = true
			if hidden then
				d.Transparency = 1
				d.CanQuery = false
			end
		elseif hidden and (d:IsA("Decal") or d:IsA("Texture")) then
			rec[d] = { d.Transparency }
			d.Transparency = 1
		end
	end
	charRecords[player] = rec
end

local function restoreCharacter(player: Player)
	local rec = charRecords[player]
	charRecords[player] = nil
	if not rec then
		return
	end
	for inst, values in rec do
		if inst.Parent then
			if inst:IsA("BasePart") then
				inst.Transparency = values[1] :: number
				inst.CanQuery = values[2] :: boolean
				inst.Massless = values[3] :: boolean
			elseif inst:IsA("Decal") or inst:IsA("Texture") then
				inst.Transparency = values[1] :: number
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Driving / ownership
---------------------------------------------------------------------------------------------------

local function setMode(st: VState, mode: string)
	st.mode = mode
	st.modeSince = now()
end

local function giveOwnership(st: VState, player: Player?)
	local chassis = st.chassis
	if chassis.Anchored then
		return
	end
	pcall(function()
		chassis:SetNetworkOwner(player)
	end)
end

local function setDriver(st: VState, player: Player?)
	st.driver = player
	st.model:SetAttribute("Driver", if player then player.UserId else 0)
	if st.def.static or st.destroyed then
		return
	end
	if player then
		if st.rig then
			st.rig:Release()
		end
		st.chassis.Anchored = false
		giveOwnership(st, player)
		st.speedViolation = 0
		setMode(st, "Driven")
	else
		st.chassis.Anchored = false
		giveOwnership(st, nil)
		setMode(st, "Settling")
	end
end

---------------------------------------------------------------------------------------------------
-- Seats
---------------------------------------------------------------------------------------------------

local function sendState(player: Player, st: VState?, seatId: string?)
	if st and seatId then
		remotes.State:FireClient(player, {
			uid = st.uid,
			seat = seatId,
			inVehicle = true,
			vehicleId = st.def.id,
		})
	else
		remotes.State:FireClient(player, { uid = "", seat = "", inVehicle = false })
	end
end

local function unweld(seat: Seat)
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
end

-- Seats `player` in `seatId` (the seat must be free). Returns success.
local function sitPlayer(player: Player, st: VState, seatId: string): boolean
	local hum = humanoidOf(player)
	local seat = st.seats[seatId]
	local seatDef = seatDefOf(st, seatId)
	if not hum or not seat or not seatDef or st.occupants[seatId] then
		return false
	end
	st.occupants[seatId] = player
	playerSeat[player] = { st = st, seatId = seatId }
	st.lastOccupied = now()
	storeCharacter(player, not seatDef.exposed)
	hum.Sit = false
	seat:Sit(hum)
	player:SetAttribute("VehicleUid", st.uid)
	if seatDef.role == "driver" then
		setDriver(st, player)
	end
	sendState(player, st, seatId)
	sendSeatWeapons(player, st, seatId)
	return true
end

-- Finds a free exit spot and moves the character there.
local function placeAtExit(player: Player, st: VState)
	local char = player.Character
	local root = rootOf(player)
	if not char or not root then
		return
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { st.model, char }
	params.RespectCanCollide = true
	local chassisCf = st.chassis.CFrame
	for _, att in st.chassis:GetChildren() do
		if att:IsA("Attachment") and att.Name == "ExitPoint" then
			local pos = att.WorldPosition
			local blocked = workspace:GetPartBoundsInBox(CFrame.new(pos), Vector3.new(2.5, 4.5, 2.5), params)
			if #blocked == 0 then
				char:PivotTo(
					CFrame.lookAlong(pos, chassisCf.LookVector * Vector3.new(1, 0, 1) + Vector3.new(0, 0, 1e-3))
				)
				return
			end
		end
	end
	-- everything blocked: stand on the roof
	char:PivotTo(chassisCf * CFrame.new(0, st.chassis.Size.Y / 2 + 6, 0))
end

-- Removes `player` from whatever seat they hold. teleport: move to an exit point.
local function leaveVehicle(player: Player, teleport: boolean)
	local rec = playerSeat[player]
	if not rec then
		return
	end
	local st, seatId = rec.st, rec.seatId
	playerSeat[player] = nil
	if st.occupants[seatId] == player then
		st.occupants[seatId] = nil
	end
	st.lastOccupied = now()
	restoreCharacter(player)
	local seat = st.seats[seatId]
	if seat then
		unweld(seat)
	end
	local hum = humanoidOf(player)
	if hum then
		hum.Sit = false
	end
	if st.driver == player then
		setDriver(st, nil)
	end
	if teleport and hum then
		placeAtExit(player, st)
	end
	if player.Parent then
		player:SetAttribute("VehicleUid", "")
		sendState(player, nil, nil)
	end
end

local function canDrive(player: Player, st: VState): boolean
	local level = player:GetAttribute("Level")
	return type(level) ~= "number" or level >= (st.def.unlockLevel or 1)
end

local function enterVehicle(player: Player, st: VState, wanted: string?)
	if st.destroyed or not st.model.Parent then
		return
	end
	if sideOf(player) ~= st.side then
		notify(player, "That vehicle belongs to the enemy.", "warning")
		return
	end
	local root = rootOf(player)
	if not root or not humanoidOf(player) or player:GetAttribute("Alive") == false then
		return
	end
	local halfW = (st.chassis:GetAttribute("HalfWidth") :: number?) or 5
	local halfL = (st.chassis:GetAttribute("HalfLength") :: number?) or 8
	local reach = math.sqrt(halfW * halfW + halfL * halfL) + ENTER_RANGE
	if (root.Position - st.chassis.Position).Magnitude > reach then
		return
	end
	if playerSeat[player] then
		return
	end
	local order = {}
	if wanted then
		table.insert(order, wanted)
	end
	for _, s in st.def.seats do
		table.insert(order, s.id)
	end
	local lockedOut = false
	for _, seatId in order do
		local seatDef = seatDefOf(st, seatId)
		if seatDef and not st.occupants[seatId] then
			if seatDef.role == "driver" and not canDrive(player, st) then
				lockedOut = true
			elseif sitPlayer(player, st, seatId) then
				if lockedOut then
					notify(player, `Reach level {st.def.unlockLevel} to drive the {st.def.name}.`, "info")
				end
				return
			end
		end
	end
	notify(player, "No free seat.", "info")
end

local function switchSeat(player: Player, wanted: string?)
	local rec = playerSeat[player]
	if not rec then
		return
	end
	local st, current = rec.st, rec.seatId
	local seats = st.def.seats
	local target: string? = nil
	local wantedDef = if wanted then seatDefOf(st, wanted) else nil
	if
		wanted
		and wanted ~= current
		and wantedDef
		and not st.occupants[wanted]
		and (wantedDef.role ~= "driver" or canDrive(player, st))
	then
		target = wanted
	else
		local idx = 1
		for i, s in seats do
			if s.id == current then
				idx = i
			end
		end
		for step = 1, #seats - 1 do
			local s = seats[(idx - 1 + step) % #seats + 1]
			if not st.occupants[s.id] and (s.role ~= "driver" or canDrive(player, st)) then
				target = s.id
				break
			end
		end
	end
	if not target then
		return
	end
	local hum = humanoidOf(player)
	if not hum then
		return
	end
	-- release the old seat without teleporting, then sit in the new one
	st.occupants[current] = nil
	playerSeat[player] = nil
	restoreCharacter(player)
	local oldSeat = st.seats[current]
	if oldSeat then
		unweld(oldSeat)
	end
	if st.driver == player then
		setDriver(st, nil)
	end
	if not sitPlayer(player, st, target) then
		placeAtExit(player, st)
		player:SetAttribute("VehicleUid", "")
		sendState(player, nil, nil)
	end
end

local function onOccupantChanged(st: VState, seatId: string)
	local seat = st.seats[seatId]
	local expected = st.occupants[seatId]
	local occupant = seat.Occupant
	if occupant then
		local p = Players:GetPlayerFromCharacter(occupant.Parent)
		if p ~= expected then
			-- nobody sits in a vehicle without going through VehicleService
			task.defer(unweld, seat)
		end
	elseif expected then
		-- the occupant left on their own (jumped, died, weld broken)
		task.defer(function()
			if st.occupants[seatId] == expected and not seat.Occupant then
				leaveVehicle(expected, humanoidOf(expected) ~= nil)
			end
		end)
	end
end

---------------------------------------------------------------------------------------------------
-- Damage model
---------------------------------------------------------------------------------------------------

-- Facing struck by a projectile travelling along `dir`.
local function facingFromDirection(st: VState, dir: Vector3): string
	local incoming = st.chassis.CFrame:VectorToObjectSpace(-dir)
	if incoming.Y > DAMAGE.TOP_DOT then
		return "top"
	end
	local yaw = math.deg(math.atan2(incoming.X, -incoming.Z))
	local a = math.abs(yaw)
	if a <= DAMAGE.FRONT_ARC then
		return "front"
	elseif a >= DAMAGE.REAR_ARC then
		return "rear"
	end
	return "side"
end

-- Facing nearest to a hit position (explosions / rockets, direction unknown).
local function facingFromPosition(st: VState, pos: Vector3?): string
	if not pos or not isFiniteVector(pos) then
		return "side"
	end
	local lp = st.chassis.CFrame:PointToObjectSpace(pos)
	local halfW = (st.chassis:GetAttribute("HalfWidth") :: number?) or 4
	local halfL = (st.chassis:GetAttribute("HalfLength") :: number?) or 8
	if math.abs(lp.Z) / halfL > math.abs(lp.X) / halfW then
		return if lp.Z < 0 then "front" else "rear"
	end
	return "side"
end

local function setCritical(st: VState, critical: boolean)
	if st.critical == critical then
		return
	end
	st.critical = critical
	st.model:SetAttribute("Critical", critical)
	if st.smoke then
		st.smoke.Enabled = critical
	end
end

local destroyVehicle: (st: VState, killer: Player?, weaponId: string) -> ()

-- Applies final (post-armor) damage. Returns the amount actually removed.
local function damageInternal(st: VState, amount: number, attacker: Player?, weaponId: string, pos: Vector3?): number
	if st.destroyed or amount <= 0 or not isFinite(amount) then
		return 0
	end
	local applied = math.min(amount, st.health)
	st.health -= applied
	st.model:SetAttribute("Health", math.floor(st.health + 0.5))
	setCritical(st, st.health > 0 and st.health <= st.def.maxHealth * DAMAGE.CRITICAL_FRACTION)
	for _, p in st.occupants do
		remotes.FX:FireClient(p, { kind = "hit", uid = st.uid, amount = applied, pos = pos })
	end
	if st.health <= 0 then
		destroyVehicle(st, attacker, weaponId)
	end
	return applied
end

function VehicleService.ApplyDamage(
	vehicle: Model,
	amount: number,
	attacker: Player?,
	weaponId: string,
	hitPosition: Vector3?,
	opts: { penetration: number?, explosive: boolean? }?
): number
	local st = byModel[vehicle]
	if not st or st.destroyed or not isFinite(amount) or amount <= 0 then
		return 0
	end
	if attacker and sideOf(attacker) == st.side then
		return 0 -- no friendly fire on vehicles
	end
	local o = opts or {}
	-- Combat passes a 0..1 cover-penetration factor for small arms; only values > 1 are armor ratings.
	local pen = if type(o.penetration) == "number" and o.penetration > 1 then o.penetration else nil
	local facing = facingFromPosition(st, hitPosition)
	local armor = st.def.armor[facing] or st.def.armor.side
	local dmg
	if o.explosive then
		dmg = amount * (DAMAGE.EXPLOSIVE_FACING_MULT[facing] or 1)
		if pen and pen < armor then
			dmg *= DAMAGE.HEAT_NONPEN_FRACTION
		end
	elseif pen then
		dmg = if pen >= armor then amount * (DAMAGE.PEN_FACING_MULT[facing] or 1) else 0
	else
		-- plain small-arms hits (already scaled by the caller): armored vehicles are immune
		dmg = if st.def.smallArmsMult > 0 then amount else 0
	end
	return damageInternal(st, dmg, attacker, weaponId or "", hitPosition)
end

function VehicleService.Repair(vehicle: Model, amount: number, repairer: Player?): number
	local st = byModel[vehicle]
	if not st or st.destroyed or not isFinite(amount) or amount <= 0 then
		return 0
	end
	if repairer and sideOf(repairer) ~= st.side then
		return 0
	end
	local applied = math.min(amount, st.def.maxHealth - st.health)
	if applied <= 0 then
		return 0
	end
	st.health += applied
	st.model:SetAttribute("Health", math.floor(st.health + 0.5))
	setCritical(st, st.health <= st.def.maxHealth * DAMAGE.CRITICAL_FRACTION)
	return applied
end

function VehicleService.GetVehicleOf(player: Player): Model?
	local rec = playerSeat[player]
	return if rec then rec.st.model else nil
end

function VehicleService.Eject(player: Player)
	leaveVehicle(player, true)
end

---------------------------------------------------------------------------------------------------
-- Wreck / destruction
---------------------------------------------------------------------------------------------------

local function makeEmitter(parent: Instance, kind: string): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	if kind == "fire" then
		e.Name = "WreckFire"
		e.Texture = "rbxasset://textures/particles/fire_main.dds"
		e.Color = ColorSequence.new(Color3.fromRGB(255, 170, 60), Color3.fromRGB(200, 60, 20))
		e.LightEmission = 0.8
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 0.5) })
		e.Transparency = NumberSequence.new(0.2, 1)
		e.Lifetime = NumberRange.new(0.6, 1.2)
		e.Rate = 40
		e.Speed = NumberRange.new(6, 12)
		e.SpreadAngle = Vector2.new(25, 25)
	else
		e.Name = if kind == "critical" then "CriticalSmoke" else "WreckSmoke"
		e.Texture = "rbxasset://textures/particles/smoke_main.dds"
		local dark = if kind == "critical" then Color3.fromRGB(90, 88, 84) else Color3.fromRGB(30, 28, 26)
		e.Color = ColorSequence.new(dark)
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 9) })
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		e.Lifetime = NumberRange.new(3, 5)
		e.Rate = if kind == "critical" then CRITICAL_SMOKE_RATE else 18
		e.Speed = NumberRange.new(5, 9)
		e.SpreadAngle = Vector2.new(12, 12)
		e.RotSpeed = NumberRange.new(-30, 30)
		e.Rotation = NumberRange.new(0, 360)
	end
	e.EmissionDirection = Enum.NormalId.Top
	e.Parent = parent
	return e
end

destroyVehicle = function(st: VState, killer: Player?, weaponId: string)
	if st.destroyed then
		return
	end
	st.destroyed = true
	local model, chassis, def = st.model, st.chassis, st.def
	local pos = chassis.Position
	model:SetAttribute("Destroyed", true)
	model:SetAttribute("Health", 0)
	model:SetAttribute("Driver", 0)
	setCritical(st, false)
	if st.prompt then
		st.prompt.Enabled = false
	end

	-- killer's vehicle (for the kill feed icon) if the killer is crewing one
	local killerVehicleId: string? = nil
	local krec = killer and playerSeat[killer]
	if krec then
		killerVehicleId = krec.st.def.id
	end

	-- eject + kill the crew
	for _, p in occupantsList(st) do
		leaveVehicle(p, true)
		damagePlayer(p, DAMAGE.OCCUPANT_DEATH_DAMAGE, killer, weaponId, {
			fromPosition = pos,
			ignoreFriendlyFire = killer == nil,
			vehicleId = killerVehicleId,
			noHitConfirm = false,
		})
	end
	st.driver = nil

	Bus.fire("VehicleDestroyed", model, killer)
	local blast = DAMAGE.DESTRUCTION_BLAST
	explode(pos, blast.radius, blast.damage, killer, weaponId, "vehicle", 0)

	-- burning, blackened hulk
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= chassis then
			d.Color = d.Color:Lerp(Color3.fromRGB(25, 23, 21), 0.7)
		elseif d:IsA("SurfaceGui") then
			d:Destroy()
		end
	end
	local center = chassis:FindFirstChild("Center") or chassis
	makeEmitter(center, "fire")
	makeEmitter(center, "smoke")
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 140, 60)
	light.Range = 18
	light.Brightness = 2
	light.Parent = center

	if not def.static then
		if st.rig then
			st.rig:Release()
		end
		for _, name in { "Drive", "Grip", "YawTorque", "Upright" } do
			local c = chassis:FindFirstChild(name)
			if c and c:IsA("Constraint") then
				c.Enabled = false
			end
		end
		for _, c in chassis:GetChildren() do
			if c:IsA("VectorForce") then
				c.Enabled = false
			end
		end
		chassis.Anchored = false
		pcall(function()
			chassis:SetNetworkOwner(nil)
		end)
		setMode(st, "Wreck")
		-- turret toss for turreted tanks
		local turret = model:FindFirstChild("Turret")
		local motor = turret and turret:FindFirstChild("TurretMotor")
		if turret and turret:IsA("BasePart") and motor and def.class == "Tank" and rng:NextNumber() < 0.6 then
			motor:Destroy()
			task.defer(function()
				if turret.Parent then
					turret.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-15, 15), 70, rng:NextNumber(-15, 15))
					turret.AssemblyAngularVelocity =
						Vector3.new(rng:NextNumber(-3, 3), rng:NextNumber(-4, 4), rng:NextNumber(-3, 3))
				end
			end)
		end
		chassis:ApplyImpulse(Vector3.new(0, chassis.AssemblyMass * 25, 0))
	else
		setMode(st, "Wreck")
	end

	st.wreckUntil = now() + DAMAGE.WRECK_TIME
	if st.slot then
		st.slot.respawnAt = now() + def.respawnTime
	end
end

---------------------------------------------------------------------------------------------------
-- Spawning
---------------------------------------------------------------------------------------------------

local function removeVehicle(st: VState)
	for _, p in occupantsList(st) do
		leaveVehicle(p, true)
	end
	vehicles[st.uid] = nil
	byModel[st.model] = nil
	if st.slot and st.slot.current == st then
		st.slot.current = nil
	end
	st.trove:Clean()
	st.model:Destroy()
end

local function groundCFrame(cf: CFrame, rideHeight: number, ignore: { Instance }): CFrame
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	pcall(function()
		params.CollisionGroup = Physics.RAY_GROUP
	end)
	local origin = cf.Position + Vector3.new(0, 20, 0)
	local hit = workspace:Raycast(origin, Vector3.new(0, -80, 0), params)
	local y = if hit then hit.Position.Y + rideHeight else cf.Position.Y + rideHeight
	local look = cf.LookVector * Vector3.new(1, 0, 1)
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	end
	local pos = Vector3.new(cf.Position.X, y, cf.Position.Z)
	return CFrame.lookAlong(pos, look.Unit)
end

local function spawnVehicle(def: any, cframe: CFrame, side: string, faction: string, slot: Slot?): VState?
	local ok, model = pcall(VehicleModels.Build, def.id)
	if not ok then
		warn(`[VehicleService] failed to build {def.id}: {model}`)
		return nil
	end
	local chassis = model.PrimaryPart :: BasePart
	local uid = HttpService:GenerateGUID(false)
	local rideHeight = (chassis:GetAttribute("RideHeight") :: number?) or 3
	local ignore: { Instance } = { vehicleFolder }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	model:PivotTo(groundCFrame(cframe, rideHeight, ignore))
	chassis.Anchored = true
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model.Name = `{def.id}_{string.sub(uid, 1, 6)}`
	model:SetAttribute("VehicleId", def.id)
	model:SetAttribute("Uid", uid)
	model:SetAttribute("Side", side)
	model:SetAttribute("Faction", faction)
	model:SetAttribute("Class", def.class)
	model:SetAttribute("DisplayName", def.name)
	model:SetAttribute("Health", def.maxHealth)
	model:SetAttribute("MaxHealth", def.maxHealth)
	model:SetAttribute("Destroyed", false)
	model:SetAttribute("Critical", false)
	model:SetAttribute("Driver", 0)
	model:SetAttribute("TurretYaw", 0)
	model:SetAttribute("GunPitch", 0)
	model:SetAttribute("MGYaw", 0)
	model:SetAttribute("MGPitch", 0)

	local trove = Trove.new()
	local st: VState = {
		uid = uid,
		def = def,
		model = model,
		chassis = chassis,
		side = side,
		faction = faction,
		health = def.maxHealth,
		destroyed = false,
		slot = slot,
		seats = {},
		occupants = {},
		driver = nil,
		rig = nil,
		mode = "Parked",
		modeSince = now(),
		turretYaw = 0,
		gunPitch = 0,
		targetYaw = 0,
		targetPitch = 0,
		mgYaw = 0,
		mgPitch = 0,
		mgTargetYaw = 0,
		mgTargetPitch = 0,
		lastSync = 0,
		syncedYaw = 0,
		syncedPitch = 0,
		syncedMgYaw = 0,
		syncedMgPitch = 0,
		ammoIndex = 1,
		mag = (def.weapons.main and def.weapons.main.magazine) or 1,
		nextMainShot = 0,
		reloadUntil = 0,
		mgs = {},
		lastOccupied = now(),
		flippedSince = nil,
		speedViolation = 0,
		revokedUntil = 0,
		lastRam = 0,
		ramHits = {},
		critical = false,
		smoke = nil,
		prompt = nil,
		wreckUntil = 0,
		trove = trove,
	}
	for _, w in { "coax", "hullMG" } do
		local mg = def.weapons[w]
		if mg then
			st.mgs[w] = { mag = mg.magazine, heat = 0, lastShot = 0, nextShot = 0, reloadUntil = 0, overheatUntil = 0 }
		end
	end

	for _, seatDef in def.seats do
		local seat = model:FindFirstChild(Vehicles.seatInstanceName(seatDef.id))
		if seat and seat:IsA("Seat") then
			st.seats[seatDef.id] = seat
			trove:Connect(seat:GetPropertyChangedSignal("Occupant"), function()
				onOccupantChanged(st, seatDef.id)
			end)
		end
	end

	-- enter prompt above the hull
	local promptAtt = Instance.new("Attachment")
	promptAtt.Name = "PromptAttachment"
	promptAtt.Position = Vector3.new(0, chassis.Size.Y / 2 + 2, 0)
	promptAtt.Parent = chassis
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "EnterPrompt"
	prompt.ActionText = "Enter"
	prompt.ObjectText = def.name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.DPadUp
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = math.max(10, ((chassis:GetAttribute("HalfWidth") :: number?) or 4) + 7)
	prompt:SetAttribute("Side", side)
	prompt.Parent = promptAtt
	st.prompt = prompt
	trove:Connect(prompt.Triggered, function(player: Player)
		if Net.rateLimit(player, "VehiclePrompt", REQUEST_RATE) then
			enterVehicle(player, st, nil)
		end
	end)

	local smoke = makeEmitter(chassis:FindFirstChild("Center") or chassis, "critical")
	smoke.Enabled = false
	st.smoke = smoke

	model.Parent = vehicleFolder
	CollectionService:AddTag(model, VEHICLE_TAG)
	if not def.static then
		st.rig = Physics.new(model, def)
	end

	vehicles[uid] = st
	byModel[model] = st
	if slot then
		slot.current = st
	end
	return st
end

local function pickVehicle(side: string, class: string, rotation: number): (any, string)
	local faction = GameState.get(side .. "Faction")
	if type(faction) ~= "string" or not Factions.get(faction) then
		faction = if side == "Allies" then "US" else "DE"
	end
	local list = Vehicles.forFaction(faction, class)
	if #list == 0 then
		for _, f in Factions.forSide(side) do
			list = Vehicles.forFaction(f.id, class)
			if #list > 0 then
				break
			end
		end
	end
	if #list == 0 then
		return nil, faction
	end
	return list[rotation % #list + 1], faction
end

local function spawnSlot(slot: Slot)
	local def, faction = pickVehicle(slot.side, slot.class, slot.rotation)
	slot.rotation += 1
	if not def then
		slot.respawnAt = math.huge
		return
	end
	if not spawnVehicle(def, slot.cframe, slot.side, faction, slot) then
		slot.respawnAt = now() + 10
	end
end

function VehicleService.ClearAll()
	currentMapInfo = nil
	for _, st in table.clone(vehicles) do
		removeVehicle(st)
	end
	table.clear(slots)
	table.clear(shells)
end

function VehicleService.SpawnTeamVehicles(mapInfo: any)
	-- MapLoaded and RoundService may both request the same map: spawn only once per map info.
	if mapInfo ~= nil and mapInfo == currentMapInfo and #slots > 0 then
		return
	end
	VehicleService.ClearAll()
	currentMapInfo = mapInfo
	if type(mapInfo) ~= "table" or type(mapInfo.vehicleSpawns) ~= "table" then
		return
	end
	if not modeUsesVehicles() then
		return
	end
	for _, side in Constants.SIDES do
		local list = mapInfo.vehicleSpawns[side]
		if type(list) == "table" then
			for _, entry in list do
				if type(entry) == "table" and typeof(entry.cframe) == "CFrame" and type(entry.class) == "string" then
					local slot: Slot = {
						side = side,
						class = entry.class,
						cframe = entry.cframe,
						rotation = 0,
						current = nil,
						respawnAt = 0,
					}
					table.insert(slots, slot)
					spawnSlot(slot)
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Weapons
---------------------------------------------------------------------------------------------------

local function spreadDir(dir: Vector3, degrees: number): Vector3
	if degrees <= 0 then
		return dir
	end
	local cf = CFrame.lookAlong(Vector3.zero, dir)
	local r = math.rad(degrees) * math.sqrt(rng:NextNumber())
	local a = rng:NextNumber(0, 2 * math.pi)
	return (cf * CFrame.Angles(r * math.cos(a), r * math.sin(a), 0)).LookVector
end

local function chooseDir(boreCf: CFrame, aim: Vector3, trust: number): Vector3
	local bore = boreCf.LookVector
	local toAim = aim - boreCf.Position
	if toAim.Magnitude > 1 then
		local desired = toAim.Unit
		if math.acos(math.clamp(desired:Dot(bore), -1, 1)) <= trust then
			return desired
		end
	end
	return bore
end

local function fireMain(player: Player, st: VState, aim: Vector3)
	local gun = st.def.weapons.main
	if not gun then
		return
	end
	local t = now()
	if t < st.reloadUntil or t < st.nextMainShot - 0.05 then
		sendWeapon(player, st, "main")
		return
	end
	local shell = gun.ammo[st.ammoIndex] or gun.ammo[1]
	local muzzle = VehicleModels.MuzzleCFrame(st.model, st.turretYaw, st.gunPitch)
	if not muzzle then
		return
	end
	local dir = spreadDir(chooseDir(muzzle, aim, AIM_TRUST_ANGLE), gun.spread or 0.15)
	local magazine = gun.magazine or 1
	if magazine > 1 then
		st.mag -= 1
		if st.mag <= 0 then
			st.mag = magazine
			st.reloadUntil = t + gun.reload
		else
			st.nextMainShot = t + (gun.fireInterval or 0.25)
		end
	else
		st.mag = 1
		st.reloadUntil = t + gun.reload
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = occupantCharacters(st)
	table.insert(ignore, st.model)
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = false
	table.insert(shells, {
		pos = muzzle.Position,
		vel = dir * shell.velocity,
		shell = shell,
		shooter = player,
		source = st,
		born = t,
		params = params,
	})
	remotes.FX:FireAllClients({
		kind = "fire",
		uid = st.uid,
		shooter = player,
		weapon = "main",
		ammo = shell.kind,
		origin = muzzle.Position,
		velocity = dir * shell.velocity,
		gravity = shell.gravityScale,
		caliber = gun.recoil,
	})
	sendWeapon(player, st, "main")
end

local function fireMG(player: Player, st: VState, weaponId: string, aim: Vector3)
	local mgDef = st.def.weapons[weaponId]
	local ms = st.mgs[weaponId]
	if not mgDef or not ms then
		return
	end
	local t = now()
	local interval = 60 / mgDef.rpm
	if t < ms.nextShot - interval * 0.4 or t < ms.reloadUntil or t < ms.overheatUntil then
		return
	end
	ms.heat = math.max(0, ms.heat - mgDef.coolRate * (t - ms.lastShot)) + mgDef.heatPerShot
	ms.lastShot = t
	-- Credit up to two intervals of idle time so packets bunched by network jitter are not dropped;
	-- the long-run rate stays capped at the MG's rpm.
	ms.nextShot = math.max(t - interval * 2, ms.nextShot) + interval
	ms.mag -= 1
	local stateChanged = false
	if ms.heat >= 1 then
		ms.heat = 1
		ms.overheatUntil = t + mgDef.overheatTime
		stateChanged = true
	end
	if ms.mag <= 0 then
		ms.mag = mgDef.magazine
		ms.reloadUntil = t + mgDef.reload
		stateChanged = true
	end

	local bore: CFrame?
	if weaponId == "coax" then
		bore = VehicleModels.GunAttachmentCFrame(st.model, "Coax", st.turretYaw, st.gunPitch)
			or VehicleModels.MuzzleCFrame(st.model, st.turretYaw, st.gunPitch)
	else
		bore = VehicleModels.HullMGCFrame(st.model, st.mgYaw, st.mgPitch)
	end
	if not bore then
		return
	end
	local dir = spreadDir(chooseDir(bore, aim, MG_AIM_TRUST_ANGLE), mgDef.spread)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = occupantCharacters(st)
	table.insert(ignore, st.model)
	params.FilterDescendantsInstances = ignore
	local origin = bore.Position
	local result = workspace:Raycast(origin, dir * mgDef.range, params)
	local hitPos = origin + dir * mgDef.range
	local normal, material = nil, nil
	if result then
		hitPos, normal, material = result.Position, result.Normal, result.Material.Name
		local inst = result.Instance
		local vModel = findVehicleModel(inst)
		if vModel then
			local applied = VehicleService.ApplyDamage(vModel, mgDef.vehicleDamage, player, st.def.id, hitPos, {
				penetration = mgDef.penetration,
			})
			hitConfirm(player, applied, false, nil)
		else
			local charModel = inst:FindFirstAncestorOfClass("Model")
			local hum = charModel and charModel:FindFirstChildOfClass("Humanoid")
			if charModel and hum then
				local dist = (hitPos - origin).Magnitude
				local falloff = 1 - 0.4 * math.clamp(dist / mgDef.range, 0, 1)
				local head = inst.Name == "Head"
				local dmg = mgDef.damage * falloff * (if head then 1.5 else 1)
				local victim = Players:GetPlayerFromCharacter(charModel)
				if victim then
					damagePlayer(victim, dmg, player, st.def.id, {
						headshot = head,
						fromPosition = origin,
						vehicleId = st.def.id,
					})
				else
					hum:TakeDamage(dmg)
				end
			end
		end
	end
	remotes.FX:FireAllClients({
		kind = "mg",
		uid = st.uid,
		shooter = player,
		weapon = weaponId,
		origin = origin,
		hit = hitPos,
		normal = normal,
		material = material,
	})
	if stateChanged then
		sendWeapon(player, st, weaponId)
	end
end

local function resolveShell(s: Shell, result: RaycastResult)
	local shell = s.shell
	local src = s.source
	local weaponId = src.def.id
	local pos, normal = result.Position, result.Normal
	local dir = s.vel.Unit
	local inst = result.Instance
	local vModel = findVehicleModel(inst)
	local target = vModel and byModel[vModel]

	if target and not target.destroyed and target ~= src then
		if target.side ~= src.side then
			local facing = facingFromDirection(target, dir)
			local armor = target.def.armor[facing] or target.def.armor.side
			local cosImpact = math.abs(normal:Dot(dir))
			local impact = math.deg(math.acos(math.clamp(cosImpact, 0, 1)))
			local effective = armor / (math.max(cosImpact, 0.35) ^ 0.6)
			local outcome, dmg
			if impact >= DAMAGE.RICOCHET_ANGLE and shell.penetration < effective * 1.5 then
				outcome, dmg = "ricochet", 0
			elseif shell.penetration >= effective then
				outcome, dmg = "penetration", shell.damage * (DAMAGE.PEN_FACING_MULT[facing] or 1)
			else
				outcome, dmg = "nonpen", shell.damage * (DAMAGE.NONPEN_FRACTION[shell.kind] or 0.1)
			end
			local applied = damageInternal(target, dmg, s.shooter, weaponId, pos)
			if s.shooter then
				if applied > 0 then
					hitConfirm(s.shooter, applied, target.destroyed, outcome)
				else
					remotes.HitConfirm:FireClient(s.shooter, {
						damage = 0,
						headshot = false,
						killed = false,
						target = "vehicle",
						result = outcome,
					})
				end
			end
			remotes.FX:FireAllClients({
				kind = "impact",
				uid = target.uid,
				pos = pos,
				normal = normal,
				result = outcome,
				ammo = shell.kind,
				facing = facing,
			})
			if outcome == "ricochet" then
				return -- no blast on a glancing hit
			end
		end
	else
		local charModel = inst:FindFirstAncestorOfClass("Model")
		local victim = charModel and Players:GetPlayerFromCharacter(charModel)
		if victim then
			damagePlayer(victim, shell.directDamage, s.shooter, weaponId, {
				fromPosition = pos - dir * 5,
				vehicleId = weaponId,
			})
		end
	end
	explode(
		pos + normal * 0.5,
		shell.splashRadius,
		shell.splashDamage,
		s.shooter,
		weaponId,
		"shell",
		shell.splashVehicle or 0
	)
end

local function stepShells(dt: number)
	local t = now()
	local g = workspace.Gravity
	for i = #shells, 1, -1 do
		local s = shells[i]
		s.vel += Vector3.new(0, -g * s.shell.gravityScale * dt, 0)
		local step = s.vel * dt
		local result = workspace:Raycast(s.pos, step, s.params)
		if result then
			table.remove(shells, i)
			local ok, err = pcall(resolveShell, s, result)
			if not ok then
				warn(`[VehicleService] shell resolve failed: {err}`)
			end
		elseif t - s.born > SHELL_LIFETIME then
			table.remove(shells, i)
		else
			s.pos += step
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Remote handlers
---------------------------------------------------------------------------------------------------

local function onRequest(player: Player, payload: any)
	if type(payload) ~= "table" or not Net.rateLimit(player, "VehicleRequest", REQUEST_RATE) then
		return
	end
	local action = payload.action
	if action == "exit" then
		leaveVehicle(player, true)
	elseif action == "switchSeat" then
		switchSeat(player, if type(payload.seat) == "string" then payload.seat else nil)
	elseif action == "enter" then
		local st = type(payload.uid) == "string" and vehicles[payload.uid] or nil
		if st then
			enterVehicle(player, st, if type(payload.seat) == "string" then payload.seat else nil)
		end
	elseif action == "ammo" then
		local rec = playerSeat[player]
		if not rec or rec.st.uid ~= payload.uid then
			return
		end
		local st = rec.st
		local gun = st.def.weapons.main
		local seatDef = seatDefOf(st, rec.seatId)
		if not gun or not seatDef or not table.find(seatDef.weapons or {}, "main") then
			return
		end
		local index: number? = nil
		if type(payload.ammo) == "number" and gun.ammo[payload.ammo] then
			index = payload.ammo
		elseif type(payload.ammo) == "string" then
			for i, a in gun.ammo do
				if a.kind == payload.ammo then
					index = i
				end
			end
		end
		if index and index ~= st.ammoIndex and not st.destroyed then
			st.ammoIndex = index
			st.mag = gun.magazine or 1
			st.reloadUntil = now() + gun.reload -- switching ammunition costs a full reload
			sendWeapon(player, st, "main")
		end
	end
end

local function onAim(player: Player, payload: any)
	if type(payload) ~= "table" or not Net.rateLimit(player, "VehicleAim", AIM_RATE) then
		return
	end
	local rec = playerSeat[player]
	if not rec or rec.st.uid ~= payload.uid or rec.st.destroyed then
		return
	end
	local yaw, pitch = payload.yaw, payload.pitch
	if not isFinite(yaw) or not isFinite(pitch) then
		return
	end
	local st = rec.st
	local def = st.def
	local seatDef = seatDefOf(st, rec.seatId)
	local weapons = seatDef and seatDef.weapons or {}
	if seatDef and seatDef.role == "driver" and def.turretTraverse > 0 then
		local limit = def.turretYawLimit
		st.targetYaw = if limit then math.clamp(wrapAngle(yaw), -math.rad(limit), math.rad(limit)) else wrapAngle(yaw)
		st.targetPitch = math.clamp(pitch, math.rad(def.gunElevation.min), math.rad(def.gunElevation.max))
	elseif table.find(weapons, "hullMG") and def.weapons.hullMG then
		local mg = def.weapons.hullMG
		local limit = math.rad(mg.yawLimit or 30)
		st.mgTargetYaw = math.clamp(wrapAngle(yaw), -limit, limit)
		st.mgTargetPitch = math.clamp(pitch, math.rad(mg.pitchMin or -10), math.rad(mg.pitchMax or 20))
	end
end

local function onFire(player: Player, payload: any)
	if type(payload) ~= "table" or not Net.rateLimit(player, "VehicleFire", FIRE_RATE) then
		return
	end
	local rec = playerSeat[player]
	if not rec or rec.st.uid ~= payload.uid then
		return
	end
	local st = rec.st
	local weapon = payload.weapon
	local aim = payload.aim
	if st.destroyed or type(weapon) ~= "string" or not isFiniteVector(aim) then
		return
	end
	if (aim - st.chassis.Position).Magnitude > 5000 then
		return
	end
	local seatDef = seatDefOf(st, rec.seatId)
	if not seatDef or not seatDef.weapons or not table.find(seatDef.weapons, weapon) then
		return
	end
	if weapon == "main" then
		fireMain(player, st, aim)
	elseif weapon == "coax" or weapon == "hullMG" then
		fireMG(player, st, weapon, aim)
	end
end

---------------------------------------------------------------------------------------------------
-- Per-frame simulation
---------------------------------------------------------------------------------------------------

local ramParams = OverlapParams.new()
ramParams.FilterType = Enum.RaycastFilterType.Include

local function checkRam(st: VState, speed: number)
	local driver = st.driver
	if not driver then
		return
	end
	local t = now()
	local chars = {}
	for _, p in Players:GetPlayers() do
		if p.Character and sideOf(p) ~= st.side and not playerSeat[p] then
			table.insert(chars, p.Character)
		end
	end
	if #chars == 0 then
		return
	end
	ramParams.FilterDescendantsInstances = chars
	local halfW = (st.chassis:GetAttribute("HalfWidth") :: number?) or 4
	local halfL = (st.chassis:GetAttribute("HalfLength") :: number?) or 8
	local sign = if speed >= 0 then -1 else 1
	local cf = st.chassis.CFrame * CFrame.new(0, 0, sign * (halfL + 1))
	local parts = workspace:GetPartBoundsInBox(cf, Vector3.new(halfW * 2, 6, 3.5), ramParams)
	local hitPlayers: { [Player]: boolean } = {}
	for _, part in parts do
		local victim = Players:GetPlayerFromCharacter(part.Parent)
		if victim and not hitPlayers[victim] and t - (st.ramHits[victim] or 0) > RAM_COOLDOWN then
			hitPlayers[victim] = true
			st.ramHits[victim] = t
			damagePlayer(victim, math.abs(speed) * DAMAGE.RAM_DAMAGE_PER_SPEED, driver, st.def.id, {
				fromPosition = st.chassis.Position,
				vehicleId = st.def.id,
			})
		end
	end
end

local function syncAim(st: VState, t: number)
	if t - st.lastSync < ATTR_SYNC_INTERVAL then
		return
	end
	local model = st.model
	if math.abs(st.turretYaw - st.syncedYaw) > 0.002 then
		st.syncedYaw = st.turretYaw
		model:SetAttribute("TurretYaw", st.turretYaw)
	end
	if math.abs(st.gunPitch - st.syncedPitch) > 0.002 then
		st.syncedPitch = st.gunPitch
		model:SetAttribute("GunPitch", st.gunPitch)
	end
	if math.abs(st.mgYaw - st.syncedMgYaw) > 0.004 then
		st.syncedMgYaw = st.mgYaw
		model:SetAttribute("MGYaw", st.mgYaw)
	end
	if math.abs(st.mgPitch - st.syncedMgPitch) > 0.004 then
		st.syncedMgPitch = st.mgPitch
		model:SetAttribute("MGPitch", st.mgPitch)
	end
	st.lastSync = t
end

local function stepVehicle(st: VState, dt: number, t: number, doRam: boolean)
	local def = st.def
	local chassis = st.chassis
	if not chassis.Parent then
		return
	end
	if st.destroyed then
		if st.mode == "Wreck" and not def.static and t - st.modeSince > 6 and not chassis.Anchored then
			chassis.Anchored = true
		end
		return
	end

	-- turret / MG slew (authoritative)
	if def.turretTraverse > 0 then
		st.turretYaw = approachAngle(st.turretYaw, st.targetYaw, math.rad(def.turretTraverse) * SLEW_TOLERANCE * dt)
		local maxPitch = math.rad(def.elevationSpeed) * SLEW_TOLERANCE * dt
		st.gunPitch += math.clamp(st.targetPitch - st.gunPitch, -maxPitch, maxPitch)
	end
	if def.weapons.hullMG then
		st.mgYaw = approachAngle(st.mgYaw, st.mgTargetYaw, MG_SLEW_RATE * dt)
		st.mgPitch += math.clamp(st.mgTargetPitch - st.mgPitch, -MG_SLEW_RATE * dt, MG_SLEW_RATE * dt)
	end
	syncAim(st, t)

	if def.static then
		return
	end

	if st.mode == "Driven" then
		local vel = chassis.AssemblyLinearVelocity
		local flat = Vector3.new(vel.X, 0, vel.Z).Magnitude
		if flat > def.speed * SPEED_TOLERANCE + SPEED_MARGIN then
			st.speedViolation += dt
			if st.speedViolation > SPEED_VIOLATION_TIME and st.revokedUntil < t then
				warn(
					`[VehicleService] speed check failed for {st.driver} ({math.floor(flat)} studs/s), revoking ownership`
				)
				st.revokedUntil = t + REVOKE_TIME
				giveOwnership(st, nil)
				chassis.AssemblyLinearVelocity = Vector3.zero
			end
		else
			st.speedViolation = math.max(0, st.speedViolation - dt)
		end
		if st.revokedUntil > 0 then
			if t < st.revokedUntil then
				if st.rig then
					st.rig:Step(dt, 0, 0, 1)
				end
			else
				st.revokedUntil = 0
				giveOwnership(st, st.driver)
			end
		end
		if doRam and flat > DAMAGE.RAM_MIN_SPEED then
			checkRam(st, chassis.AssemblyLinearVelocity:Dot(chassis.CFrame.LookVector))
		end
	elseif st.mode == "Settling" then
		local rig = st.rig
		local settled = true
		if rig then
			local grounded = rig:Step(dt, 0, 0, 1)
			settled = grounded and chassis.AssemblyLinearVelocity.Magnitude < 0.6 and t - st.modeSince > 1.5
		end
		if settled or t - st.modeSince > SETTLE_MAX_TIME then
			if rig then
				rig:Release()
			end
			chassis.Anchored = true
			setMode(st, "Parked")
		end
	end
end

local ramAccum = 0
local function onHeartbeat(dt: number)
	stepShells(dt)
	local t = now()
	ramAccum += dt
	local doRam = ramAccum >= RAM_INTERVAL
	if doRam then
		ramAccum = 0
	end
	for _, st in vehicles do
		local ok, err = pcall(stepVehicle, st, dt, t, doRam)
		if not ok then
			warn(`[VehicleService] step failed for {st.def.id}: {err}`)
		end
	end
end

-- 1 Hz housekeeping: wreck cleanup, abandoned/flipped vehicles, respawns.
local function housekeeping()
	local t = now()
	for _, st in table.clone(vehicles) do
		if not st.model.Parent then
			removeVehicle(st)
		elseif st.destroyed then
			if t >= st.wreckUntil then
				removeVehicle(st)
			end
		elseif next(st.occupants) == nil then
			local chassis = st.chassis
			local fallen = chassis.Position.Y < workspace.FallenPartsDestroyHeight + 30
			if chassis.CFrame.UpVector.Y < 0.3 then
				st.flippedSince = st.flippedSince or t
			else
				st.flippedSince = nil
			end
			local flipped = st.flippedSince ~= nil and t - st.flippedSince > FLIPPED_TIME
			local away = st.slot ~= nil and (chassis.Position - st.slot.cframe.Position).Magnitude > ABANDON_DISTANCE
			local abandoned = away and t - st.lastOccupied > ABANDON_TIME
			if fallen or flipped or abandoned then
				local slot = st.slot
				removeVehicle(st)
				if slot then
					slot.respawnAt = t + 3
				end
			end
		end
	end
	for _, slot in slots do
		local cur = slot.current
		if cur and not vehicles[cur.uid] then
			slot.current = nil
		end
		if not slot.current and t >= slot.respawnAt then
			spawnSlot(slot)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

function VehicleService:Init()
	-- Ray group for suspension raycasts: ignores players and debris.
	pcall(function()
		if not PhysicsService:IsCollisionGroupRegistered(Physics.RAY_GROUP) then
			PhysicsService:RegisterCollisionGroup(Physics.RAY_GROUP)
		end
		local G = Constants.COLLISION_GROUPS
		for _, g in { G.Players, G.Debris, G.Viewmodel } do
			if PhysicsService:IsCollisionGroupRegistered(g) then
				PhysicsService:CollisionGroupSetCollidable(Physics.RAY_GROUP, g, false)
			end
		end
	end)

	remotes = {
		Request = Net.event("Vehicle_Request"),
		Fire = Net.event("Vehicle_Fire"),
		State = Net.event("Vehicle_State"),
		Weapon = Net.event("Vehicle_Weapon"),
		Aim = Net.unreliable("Vehicle_Aim"),
		FX = Net.unreliable("Vehicle_FX"),
		HitConfirm = Net.event("Combat_HitConfirm"),
		Notify = Net.event("Notify"),
		Explosion = Net.event("FX_Explosion"),
	}

	local existing = workspace:FindFirstChild("Vehicles")
	if existing and existing:IsA("Folder") then
		vehicleFolder = existing
	else
		local folder = Instance.new("Folder")
		folder.Name = "Vehicles"
		folder.Parent = workspace
		vehicleFolder = folder
	end
end

function VehicleService:Start()
	remotes.Request.OnServerEvent:Connect(onRequest)
	remotes.Fire.OnServerEvent:Connect(onFire)
	remotes.Aim.OnServerEvent:Connect(onAim)

	Bus.connect("MapLoaded", function(mapInfo)
		VehicleService.SpawnTeamVehicles(mapInfo)
	end)
	Bus.connect("MapUnloading", function()
		VehicleService.ClearAll()
	end)
	Bus.connect("RoundEnded", function()
		VehicleService.ClearAll()
	end)

	local function onPlayer(player: Player)
		player:SetAttribute("VehicleUid", "")
		player.CharacterRemoving:Connect(function()
			leaveVehicle(player, false)
		end)
		-- A crew member who dies stays welded in the seat (BreakJointsOnDeath = false): free the seat
		-- (and network ownership / controls) right away and drop the body at an exit point.
		local function onCharacter(char: Model)
			local hum = char:WaitForChild("Humanoid", 10)
			if hum and hum:IsA("Humanoid") then
				hum.Died:Connect(function()
					if player.Character == char and playerSeat[player] then
						leaveVehicle(player, true)
					end
				end)
			end
		end
		player.CharacterAdded:Connect(onCharacter)
		if player.Character then
			task.spawn(onCharacter, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		leaveVehicle(player, false)
		charRecords[player] = nil
		for _, st in vehicles do
			st.ramHits[player] = nil
		end
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(housekeeping)
			if not ok then
				warn(`[VehicleService] housekeeping failed: {err}`)
			end
		end
	end)

	-- A map may already be loaded if MapService started first.
	local mapService = getService("MapService")
	if mapService and type(mapService.GetMapInfo) == "function" then
		local ok, info = pcall(mapService.GetMapInfo)
		if ok and type(info) == "table" and next(vehicles) == nil then
			VehicleService.SpawnTeamVehicles(info)
		end
	end
end

return VehicleService
