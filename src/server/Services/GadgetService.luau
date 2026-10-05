--[[
	GadgetService (Gameplay team)

	Server side of the teamwork gadgets. Remote `Gadget_Use {gadget, target?, position?}` where
	gadget is one of (contract addition):
	  "Medkit"     target = teammate (Player / character / any part of it) -> direct heal (Medic)
	               no target + position                                   -> drop a medical pouch that
	                                                                         heals nearby teammates
	  "AmmoBox"    position -> drop an ammo crate (tag ResupplyPoint, limited uses) (Support)
	  "Repair"     target = vehicle (Model tagged Vehicle or a part of it). Sent repeatedly (~4 Hz)
	               while the player holds the repair tool; each message repairs for the elapsed time.
	  "Binoculars" position = aim point -> spot enemies in a cone (Recon, 8 s)
	  "Spot"       position = aim point -> quick spot for every class (narrower cone, 5 s)

	Revive: when a player dies (Bus PlayerDied) a ProximityPrompt "RevivePrompt" (CollectionService
	tag "RevivePrompt", attribute Side) is placed on the body for REVIVE_WINDOW seconds and the
	victim's `Revivable` attribute is set to the deadline (server time; 0 = not revivable). A medic
	holding the prompt revives the victim in place with REVIVE_HEALTH hp via SpawnService.Revive,
	refunds the ticket and earns "Revive" points.

	Spotting writes the `Spotted` attribute (server time deadline) on players and Vehicle models.
	When a spotted enemy is killed by someone else on the spotter's side the spotter earns "Spot Assist".

	Map-placed ResupplyPoint parts (no OwnerUserId attribute) resupply everyone (optionally only
	their `Side` attribute) without limit.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local Keybinds = require(Shared.Config.Keybinds)
local Progression = require(Shared.Config.Progression)
local GameState = require(Shared.GameState)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)

local GadgetService = {}

-- Tuning
GadgetService.REVIVE_WINDOW = 10
GadgetService.REVIVE_HOLD = 2.5
GadgetService.REVIVE_HEALTH = 50
local REVIVE_RANGE = 9

local HEAL_DIRECT_AMOUNT = 35
local HEAL_DIRECT_RANGE = 10
local HEAL_DIRECT_COOLDOWN = 1.0
local POUCH_COOLDOWN = 8
local POUCH_LIFETIME = 20
local POUCH_RADIUS = 8
local POUCH_HEAL_PER_SECOND = 6

local CRATE_COOLDOWN = 10
local CRATE_LIFETIME = 60
local CRATE_USES = 10
local CRATE_RADIUS = 8
local RESUPPLY_FRACTION = 0.25
local RESUPPLY_PLAYER_COOLDOWN = 3

local REPAIR_PER_SECOND = 30
local REPAIR_RANGE = 8
local REPAIR_MAX_TICK = 0.35

local DROP_RANGE = 12

local SPOT = {
	Binoculars = { duration = 8, cone = math.rad(8), range = 600, cooldown = 1.0, max = 6 },
	Spot = { duration = 5, cone = math.rad(4), range = 350, cooldown = 2.5, max = 3 },
}

local RESUPPLY_TAG = Constants.TAGS.ResupplyPoint
local MEDICAL_TAG = Constants.TAGS.MedicalPoint
local VEHICLE_TAG = Constants.TAGS.Vehicle
local REVIVE_PROMPT_TAG = "RevivePrompt"

type Deployable = { part: BasePart, owner: Player, side: string, expires: number, uses: number }
type ReviveEntry = { deadline: number, prompt: ProximityPrompt?, body: Model?, side: string }

local pouches: { [Player]: Deployable } = {}
local crates: { [Player]: Deployable } = {}
local cooldowns: { [Player]: { [string]: number } } = {}
local resupplyCooldown: { [Player]: number } = {}
local healAccum: { [Player]: number } = {}
local repairAccum: { [Player]: number } = {}
local lastRepairTick: { [Player]: number } = {}
local spotters: { [Player]: { spotter: Player, untilT: number } } = {}
local revives: { [Player]: ReviveEntry } = {}

local serviceCache: { [string]: any } = {}
local function getService(name: string): any
	local cached = serviceCache[name]
	if cached then
		return cached
	end
	local module = script.Parent:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		serviceCache[name] = result
		return result
	end
	return nil
end

local function callService(serviceName: string, fnName: string, ...: any): (boolean, any)
	local svc = getService(serviceName)
	local fn = svc and svc[fnName]
	if type(fn) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warn(`[GadgetService] {serviceName}.{fnName} failed: {result}`)
		return false, nil
	end
	return true, result
end

local function award(player: Player, reason: string, points: number)
	callService("ScoreService", "Award", player, reason, points)
end

local function notify(player: Player, text: string, kind: string?, duration: number?)
	Net.event("Notify"):FireClient(player, { text = text, kind = kind or "info", duration = duration or 2 })
end

local function sideOf(player: Player): string
	local s = player:GetAttribute("Side")
	return if type(s) == "string" then s else ""
end

local function liveCharacter(player: Player): (Model?, Humanoid?, BasePart?)
	if player:GetAttribute("Alive") ~= true then
		return nil, nil, nil
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil, nil, nil
	end
	return character, humanoid, root
end

local function checkCooldown(player: Player, key: string, duration: number): boolean
	local map = cooldowns[player]
	if not map then
		map = {}
		cooldowns[player] = map
	end
	local now = os.clock()
	if (map[key] or 0) > now then
		return false
	end
	map[key] = now + duration
	return true
end

local function hasGadget(player: Player, category: string): boolean
	local classId = player:GetAttribute("Class")
	if type(classId) ~= "string" then
		return false
	end
	local loadout = nil
	local raw = player:GetAttribute("Loadout")
	if type(raw) == "string" and raw ~= "" then
		local ok, decoded = pcall(function()
			return game:GetService("HttpService"):JSONDecode(raw)
		end)
		if ok then
			loadout = decoded
		end
	end
	return Progression.hasGadgetCategory(classId, loadout, category)
end

local function playerFromInstance(inst: any): Player?
	if typeof(inst) ~= "Instance" then
		return nil
	end
	if inst:IsA("Player") then
		return inst
	end
	local current: Instance? = inst
	while current and current ~= workspace do
		local p = Players:GetPlayerFromCharacter(current)
		if p then
			return p
		end
		current = current.Parent
	end
	return nil
end

local function vehicleFromInstance(inst: any): Model?
	if typeof(inst) ~= "Instance" then
		return nil
	end
	local current: Instance? = inst
	while current and current ~= workspace do
		if current:IsA("Model") and CollectionService:HasTag(current, VEHICLE_TAG) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function validVector(v: any): boolean
	return typeof(v) == "Vector3" and v == v and v.Magnitude < 1e6
end

-- Ground position near `desired` (clamped to DROP_RANGE from the player's root).
local function dropPosition(root: BasePart, desired: any, character: Model): Vector3
	local target = if validVector(desired) then desired else root.Position + root.CFrame.LookVector * 3
	local offset = target - root.Position
	if offset.Magnitude > DROP_RANGE then
		target = root.Position + offset.Unit * DROP_RANGE
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	-- Never drop through a wall: clamp to the first obstacle between player and target.
	local path = target - root.Position
	if path.Magnitude > 0.1 then
		local blocked = workspace:Raycast(root.Position, path, params)
		if blocked then
			target = blocked.Position - path.Unit * 1.5
		end
	end
	local down = workspace:Raycast(target + Vector3.new(0, 3, 0), Vector3.new(0, -20, 0), params)
	return if down then down.Position else Vector3.new(target.X, root.Position.Y - 2.5, target.Z)
end

local function heal(target: Player, amount: number, healer: Player?): number
	local called, healed = callService("CombatService", "Heal", target, amount, healer)
	if called and type(healed) == "number" then
		return healed
	end
	if called then
		return 0
	end
	-- Fallback when CombatService is unavailable.
	local _, humanoid = liveCharacter(target)
	if not humanoid then
		return 0
	end
	local before = humanoid.Health
	humanoid.Health = math.min(humanoid.MaxHealth, before + amount)
	return humanoid.Health - before
end

local function accrueHealPoints(healer: Player, healed: number)
	if healed <= 0 then
		return
	end
	healAccum[healer] = (healAccum[healer] or 0) + healed
	local units = math.floor(healAccum[healer] / 20)
	if units > 0 then
		healAccum[healer] -= units * 20
		award(healer, "Heal", units * Progression.SCORE.HealPer20)
	end
end

local function accrueRepairPoints(repairer: Player, repaired: number)
	if repaired <= 0 then
		return
	end
	repairAccum[repairer] = (repairAccum[repairer] or 0) + repaired
	local units = math.floor(repairAccum[repairer] / 50)
	if units > 0 then
		repairAccum[repairer] -= units * 50
		award(repairer, "Repair", units * Progression.SCORE.RepairPer100 / 2)
	end
end

---------------------------------------------------------------------------------------------------
-- Deployables (medical pouch / ammo crate)
---------------------------------------------------------------------------------------------------

local deployFolder: Folder? = nil
local function getDeployFolder(): Folder
	if deployFolder and deployFolder.Parent then
		return deployFolder
	end
	local f = Instance.new("Folder")
	f.Name = "Deployables"
	f.Parent = workspace
	deployFolder = f
	return f
end

local function makeDeployable(kind: string, owner: Player, position: Vector3): BasePart
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if kind == "pouch" then
		part.Name = "MedicalPouch"
		part.Size = Vector3.new(1.4, 0.7, 1)
		part.Color = Color3.fromRGB(225, 222, 210)
		part.Material = Enum.Material.Fabric
		local cross = Instance.new("Part")
		cross.Name = "Cross"
		cross.Anchored = true
		cross.CanCollide = false
		cross.CanQuery = false
		cross.CanTouch = false
		cross.Size = Vector3.new(0.9, 0.05, 0.3)
		cross.Color = Color3.fromRGB(190, 30, 30)
		cross.CFrame = CFrame.new(position + Vector3.new(0, 0.73, 0))
		cross.Parent = part
		local cross2 = cross:Clone()
		cross2.Size = Vector3.new(0.3, 0.05, 0.9)
		cross2.Parent = part
		part.CFrame = CFrame.new(position + Vector3.new(0, 0.35, 0))
		CollectionService:AddTag(part, MEDICAL_TAG)
	else
		part.Name = "AmmoCrate"
		part.Size = Vector3.new(2.6, 1.4, 1.5)
		part.Color = Color3.fromRGB(78, 86, 52)
		part.Material = Enum.Material.WoodPlanks
		part.CFrame = CFrame.new(position + Vector3.new(0, 0.7, 0)) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
		CollectionService:AddTag(part, RESUPPLY_TAG)
	end
	part:SetAttribute("Side", sideOf(owner))
	part:SetAttribute("OwnerUserId", owner.UserId)
	part.Parent = getDeployFolder()
	return part
end

local function removeDeployable(map: { [Player]: Deployable }, owner: Player)
	local d = map[owner]
	if d then
		map[owner] = nil
		if d.part.Parent then
			d.part:Destroy()
		end
	end
end

local function tickPouches(now: number, dt: number)
	for owner, pouch in pouches do
		if now >= pouch.expires or not pouch.part.Parent then
			removeDeployable(pouches, owner)
		else
			local center = pouch.part.Position
			for _, p in Players:GetPlayers() do
				if sideOf(p) == pouch.side then
					local _, humanoid, root = liveCharacter(p)
					if humanoid and root and humanoid.Health < humanoid.MaxHealth then
						if (root.Position - center).Magnitude <= POUCH_RADIUS then
							local healed = heal(p, POUCH_HEAL_PER_SECOND * dt, owner)
							if p ~= owner and owner.Parent then
								accrueHealPoints(owner, healed)
							end
						end
					end
				end
			end
		end
	end
end

local function resupplyFrom(part: BasePart, side: string?, owner: Player?): number
	local used = 0
	local now = os.clock()
	for _, p in Players:GetPlayers() do
		if (side == nil or side == "" or sideOf(p) == side) and (resupplyCooldown[p] or 0) <= now then
			local _, _, root = liveCharacter(p)
			if root and (root.Position - part.Position).Magnitude <= CRATE_RADIUS then
				local ok, refilled = callService("CombatService", "Resupply", p, RESUPPLY_FRACTION)
				if ok and refilled == true then
					resupplyCooldown[p] = now + RESUPPLY_PLAYER_COOLDOWN
					used += 1
					if owner and owner ~= p and owner.Parent then
						award(owner, "Resupply", Progression.SCORE.Resupply)
					end
				end
			end
		end
	end
	return used
end

local function tickCrates(now: number)
	for owner, crate in crates do
		if now >= crate.expires or not crate.part.Parent or crate.uses <= 0 then
			removeDeployable(crates, owner)
		else
			crate.uses -= resupplyFrom(crate.part, crate.side, owner)
			crate.part:SetAttribute("Uses", crate.uses)
			if crate.uses <= 0 then
				removeDeployable(crates, owner)
			end
		end
	end
	-- Map-placed ammo points: unlimited, no points.
	for _, inst in CollectionService:GetTagged(RESUPPLY_TAG) do
		if inst:IsA("BasePart") and inst:GetAttribute("OwnerUserId") == nil and inst:IsDescendantOf(workspace) then
			local side = inst:GetAttribute("Side")
			resupplyFrom(inst, if type(side) == "string" then side else nil, nil)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Gadget handlers
---------------------------------------------------------------------------------------------------

local function useMedkit(player: Player, payload: any, character: Model, root: BasePart)
	if not hasGadget(player, "Medkit") then
		return
	end
	if payload.target ~= nil then
		local target = playerFromInstance(payload.target)
		if not target or target == player or sideOf(target) ~= sideOf(player) then
			return
		end
		local _, humanoid, targetRoot = liveCharacter(target)
		if not humanoid or not targetRoot then
			return
		end
		if (targetRoot.Position - root.Position).Magnitude > HEAL_DIRECT_RANGE then
			return
		end
		if humanoid.Health >= humanoid.MaxHealth then
			return
		end
		if not checkCooldown(player, "MedkitDirect", HEAL_DIRECT_COOLDOWN) then
			return
		end
		accrueHealPoints(player, heal(target, HEAL_DIRECT_AMOUNT, player))
		return
	end
	if not checkCooldown(player, "MedkitPouch", POUCH_COOLDOWN) then
		return
	end
	removeDeployable(pouches, player)
	local pos = dropPosition(root, payload.position, character)
	pouches[player] = {
		part = makeDeployable("pouch", player, pos),
		owner = player,
		side = sideOf(player),
		expires = os.clock() + POUCH_LIFETIME,
		uses = 0,
	}
end

local function useAmmoBox(player: Player, payload: any, character: Model, root: BasePart)
	if not hasGadget(player, "AmmoBox") then
		return
	end
	if not checkCooldown(player, "AmmoBox", CRATE_COOLDOWN) then
		return
	end
	removeDeployable(crates, player)
	local pos = dropPosition(root, payload.position, character)
	local part = makeDeployable("crate", player, pos)
	part:SetAttribute("Uses", CRATE_USES)
	crates[player] = {
		part = part,
		owner = player,
		side = sideOf(player),
		expires = os.clock() + CRATE_LIFETIME,
		uses = CRATE_USES,
	}
	notify(player, "Ammo crate deployed")
end

local function distanceToModel(model: Model, point: Vector3): number
	local cf, size = model:GetBoundingBox()
	local localPoint = cf:PointToObjectSpace(point)
	local half = size / 2
	local clamped = Vector3.new(
		math.clamp(localPoint.X, -half.X, half.X),
		math.clamp(localPoint.Y, -half.Y, half.Y),
		math.clamp(localPoint.Z, -half.Z, half.Z)
	)
	return (localPoint - clamped).Magnitude
end

local function useRepair(player: Player, payload: any, _character: Model, root: BasePart)
	if not hasGadget(player, "Repair") then
		return
	end
	local vehicle = vehicleFromInstance(payload.target)
	if not vehicle or vehicle:GetAttribute("Destroyed") == true then
		return
	end
	local vSide = vehicle:GetAttribute("Side")
	if type(vSide) == "string" and vSide ~= "" and vSide ~= sideOf(player) then
		return
	end
	local health, maxHealth = vehicle:GetAttribute("Health"), vehicle:GetAttribute("MaxHealth")
	if type(health) == "number" and type(maxHealth) == "number" and health >= maxHealth then
		lastRepairTick[player] = nil
		return
	end
	if distanceToModel(vehicle, root.Position) > REPAIR_RANGE then
		return
	end
	local now = os.clock()
	local last = lastRepairTick[player]
	lastRepairTick[player] = now
	local dt = if last then math.min(now - last, REPAIR_MAX_TICK) else 0.25
	local ok, repaired = callService("VehicleService", "Repair", vehicle, REPAIR_PER_SECOND * dt, player)
	if ok and type(repaired) == "number" then
		accrueRepairPoints(player, repaired)
	end
end

local function useSpot(player: Player, payload: any, character: Model, root: BasePart, kind: string)
	local cfg = SPOT[kind]
	if kind == "Binoculars" and not hasGadget(player, "Binoculars") then
		return
	end
	if not checkCooldown(player, kind, cfg.cooldown) then
		return
	end
	local head = character:FindFirstChild("Head")
	local origin = if head and head:IsA("BasePart") then head.Position else root.Position + Vector3.new(0, 1.5, 0)
	local dir = root.CFrame.LookVector
	if validVector(payload.position) and (payload.position - origin).Magnitude > 1 then
		dir = (payload.position - origin).Unit
	end
	local mySide = sideOf(player)
	local serverNow = workspace:GetServerTimeNow()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }

	local function visible(targetPos: Vector3, targetModel: Instance): boolean
		local hit = workspace:Raycast(origin, targetPos - origin, params)
		if not hit then
			return true
		end
		if hit.Instance:IsDescendantOf(targetModel) then
			return true
		end
		-- Players inside a vehicle are visible through their own vehicle's hull.
		local hitVehicle = vehicleFromInstance(hit.Instance)
		local p = playerFromInstance(targetModel)
		if hitVehicle and p then
			local uid = p:GetAttribute("VehicleUid")
			return type(uid) == "string" and uid ~= "" and hitVehicle:GetAttribute("Uid") == uid
		end
		return false
	end

	local candidates = {}
	for _, p in Players:GetPlayers() do
		local s = sideOf(p)
		if s ~= "" and s ~= mySide then
			local targetChar, _, targetRoot = liveCharacter(p)
			if targetChar and targetRoot then
				local to = targetRoot.Position - origin
				local dist = to.Magnitude
				if dist > 0.5 and dist <= cfg.range then
					local angle = math.acos(math.clamp(to.Unit:Dot(dir), -1, 1))
					if angle <= cfg.cone and visible(targetRoot.Position, targetChar) then
						table.insert(candidates, { kind = "player", player = p, angle = angle })
					end
				end
			end
		end
	end
	for _, vehicle in CollectionService:GetTagged(VEHICLE_TAG) do
		if vehicle:IsA("Model") and vehicle:IsDescendantOf(workspace) then
			local vSide = vehicle:GetAttribute("Side")
			if
				type(vSide) == "string"
				and vSide ~= ""
				and vSide ~= mySide
				and vehicle:GetAttribute("Destroyed") ~= true
			then
				local pos = vehicle:GetPivot().Position
				local to = pos - origin
				local dist = to.Magnitude
				if dist > 0.5 and dist <= cfg.range then
					local angle = math.acos(math.clamp(to.Unit:Dot(dir), -1, 1))
					-- vehicles are big: widen the cone slightly
					if angle <= cfg.cone * 1.5 and visible(pos, vehicle) then
						table.insert(candidates, { kind = "vehicle", model = vehicle, angle = angle })
					end
				end
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.angle < b.angle
	end)
	local count = 0
	local untilT = serverNow + cfg.duration
	for _, c in candidates do
		if count >= cfg.max then
			break
		end
		count += 1
		if c.kind == "player" then
			local current = c.player:GetAttribute("Spotted")
			if type(current) ~= "number" or current < untilT then
				c.player:SetAttribute("Spotted", untilT)
			end
			spotters[c.player] = { spotter = player, untilT = untilT }
		else
			c.model:SetAttribute("Spotted", untilT)
			c.model:SetAttribute("SpottedBy", player.UserId)
		end
	end
	if count > 0 then
		notify(player, if count == 1 then "Enemy spotted" else `{count} enemies spotted`, "info", 1.5)
	end
end

local function onGadgetUse(player: Player, payload: any)
	if not Net.rateLimit(player, "Gadget_Use", 10) then
		return
	end
	if type(payload) ~= "table" or type(payload.gadget) ~= "string" then
		return
	end
	if GameState.get("Phase") ~= "InRound" then
		return
	end
	local character, _, root = liveCharacter(player)
	if not character or not root then
		return
	end
	local gadget = payload.gadget
	if gadget == "Medkit" then
		useMedkit(player, payload, character, root)
	elseif gadget == "AmmoBox" then
		useAmmoBox(player, payload, character, root)
	elseif gadget == "Repair" then
		useRepair(player, payload, character, root)
	elseif gadget == "Binoculars" or gadget == "Spot" then
		useSpot(player, payload, character, root, gadget)
	end
end

---------------------------------------------------------------------------------------------------
-- Revive
---------------------------------------------------------------------------------------------------

local function clearRevive(victim: Player)
	local entry = revives[victim]
	revives[victim] = nil
	if entry and entry.prompt then
		local holder = entry.prompt.Parent
		entry.prompt:Destroy()
		if holder and holder:IsA("Attachment") and holder.Name == "ReviveAttachment" then
			holder:Destroy()
		end
	end
	if victim.Parent then
		local current = victim:GetAttribute("Revivable")
		if entry and type(current) == "number" and current == entry.deadline then
			victim:SetAttribute("Revivable", 0)
		end
	end
end

local function bodyPart(body: Model): BasePart?
	for _, name in { "HumanoidRootPart", "UpperTorso", "Torso", "Head" } do
		local p = body:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

local function tryRevive(medic: Player, victim: Player)
	local entry = revives[victim]
	if not entry or victim == medic then
		return
	end
	if workspace:GetServerTimeNow() > entry.deadline or victim:GetAttribute("Alive") == true then
		clearRevive(victim)
		return
	end
	if sideOf(medic) ~= entry.side or sideOf(victim) ~= entry.side then
		return
	end
	if not hasGadget(medic, "Medkit") then
		notify(medic, "Only medics can revive", "warning")
		return
	end
	local _, _, medicRoot = liveCharacter(medic)
	if not medicRoot then
		return
	end
	local body = entry.body
	local part = body and body.Parent and bodyPart(body)
	local deathPos: Vector3? = if part then part.Position else nil
	if not deathPos then
		local _, last = callService("SpawnService", "GetLastDeath", victim)
		deathPos = if type(last) == "table" then last.position else nil
	end
	if not deathPos or (deathPos - medicRoot.Position).Magnitude > REVIVE_RANGE then
		return
	end
	-- Stand the victim up on the ground at the body, facing the medic.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	if body then
		table.insert(ignore, body)
	end
	if medic.Character then
		table.insert(ignore, medic.Character)
	end
	params.FilterDescendantsInstances = ignore
	local down = workspace:Raycast(deathPos + Vector3.new(0, 3, 0), Vector3.new(0, -12, 0), params)
	local standPos = (if down then down.Position else deathPos) + Vector3.new(0, 3, 0)
	local look = Vector3.new(medicRoot.Position.X - standPos.X, 0, medicRoot.Position.Z - standPos.Z)
	local cf = if look.Magnitude > 0.1 then CFrame.lookAlong(standPos, look) else CFrame.new(standPos)

	clearRevive(victim)
	local ok, revived = callService("SpawnService", "Revive", victim, cf, GadgetService.REVIVE_HEALTH, medic)
	if ok and revived then
		award(medic, "Revive", Progression.SCORE.Revive)
		callService("RoundService", "AdjustTickets", entry.side, 1)
		notify(victim, `Revived by {medic.DisplayName}`, "info", 3)
	end
end

local function onPlayerDied(victim: any, _killer: any, weaponId: any)
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") or not victim.Parent then
		return
	end
	clearRevive(victim)
	spotters[victim] = nil
	victim:SetAttribute("Spotted", 0)
	if GameState.get("Phase") ~= "InRound" or weaponId == "OutOfBounds" then
		return
	end
	local side = sideOf(victim)
	local body = victim.Character
	local part = body and body:IsDescendantOf(workspace) and bodyPart(body)
	if side == "" or not body or not part then
		return
	end
	local deadline = workspace:GetServerTimeNow() + GadgetService.REVIVE_WINDOW
	local attachment = Instance.new("Attachment")
	attachment.Name = "ReviveAttachment"
	attachment.Parent = part
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RevivePrompt"
	prompt.ActionText = "Revive"
	prompt.ObjectText = victim.DisplayName
	prompt.HoldDuration = GadgetService.REVIVE_HOLD
	prompt.MaxActivationDistance = REVIVE_RANGE - 1
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Keybinds.keyboard.Interact
	prompt.GamepadKeyCode = Keybinds.gamepad.Interact
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt:SetAttribute("Side", side)
	prompt:SetAttribute("VictimUserId", victim.UserId)
	prompt:SetAttribute("Deadline", deadline)
	CollectionService:AddTag(prompt, REVIVE_PROMPT_TAG)
	prompt.Parent = attachment
	prompt.Triggered:Connect(function(medic: Player)
		tryRevive(medic, victim)
	end)

	local entry: ReviveEntry = { deadline = deadline, prompt = prompt, body = body, side = side }
	revives[victim] = entry
	victim:SetAttribute("Revivable", deadline)
	task.delay(GadgetService.REVIVE_WINDOW + 0.1, function()
		if revives[victim] == entry then
			clearRevive(victim)
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Spot assists
---------------------------------------------------------------------------------------------------

local function onPlayerKilled(victim: any, killer: any)
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") then
		return
	end
	local info = spotters[victim]
	spotters[victim] = nil
	if not info or typeof(killer) ~= "Instance" or not killer:IsA("Player") then
		return
	end
	if workspace:GetServerTimeNow() > info.untilT + 1 then
		return
	end
	local spotter = info.spotter
	if spotter == killer or not spotter.Parent or sideOf(spotter) ~= sideOf(killer) then
		return
	end
	if sideOf(spotter) == sideOf(victim) then
		return
	end
	award(spotter, "Spot Assist", Progression.SCORE.SpotAssist)
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

local function cleanupPlayer(player: Player)
	removeDeployable(pouches, player)
	removeDeployable(crates, player)
	clearRevive(player)
	cooldowns[player] = nil
	resupplyCooldown[player] = nil
	healAccum[player] = nil
	repairAccum[player] = nil
	lastRepairTick[player] = nil
	spotters[player] = nil
	for target, info in spotters do
		if info.spotter == player then
			spotters[target] = nil
		end
	end
end

local function clearAll()
	for owner in pouches do
		removeDeployable(pouches, owner)
	end
	for owner in crates do
		removeDeployable(crates, owner)
	end
	for victim in revives do
		clearRevive(victim)
	end
	table.clear(spotters)
	for _, p in Players:GetPlayers() do
		p:SetAttribute("Spotted", 0)
		p:SetAttribute("Revivable", 0)
	end
end

function GadgetService:Init()
	Net.event("Gadget_Use")
	Net.event("Notify")
end

function GadgetService:Start()
	Net.event("Gadget_Use").OnServerEvent:Connect(onGadgetUse)
	Bus.connect("PlayerDied", onPlayerDied)
	Bus.connect("PlayerKilled", onPlayerKilled)
	Bus.connect("PlayerSpawned", function(player: Player)
		clearRevive(player)
		lastRepairTick[player] = nil
	end)
	Bus.connect("RoundEnded", clearAll)
	Bus.connect("MapUnloading", clearAll)
	Players.PlayerAdded:Connect(function(player)
		player:SetAttribute("Spotted", 0)
		player:SetAttribute("Revivable", 0)
	end)
	for _, p in Players:GetPlayers() do
		if p:GetAttribute("Spotted") == nil then
			p:SetAttribute("Spotted", 0)
		end
		if p:GetAttribute("Revivable") == nil then
			p:SetAttribute("Revivable", 0)
		end
	end
	Players.PlayerRemoving:Connect(cleanupPlayer)

	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(0.5)
			local now = os.clock()
			local dt = math.min(now - last, 1)
			last = now
			if GameState.get("Phase") == "InRound" then
				local ok, err = pcall(tickPouches, now, dt)
				if not ok then
					warn(`[GadgetService] pouch tick failed: {err}`)
				end
				ok, err = pcall(tickCrates, now)
				if not ok then
					warn(`[GadgetService] crate tick failed: {err}`)
				end
			end
		end
	end)
end

return GadgetService
