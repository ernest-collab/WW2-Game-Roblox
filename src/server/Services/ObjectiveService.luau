--[[
	ObjectiveService (Gameplay team)

	Builds the replicated objective folders (GameState.Objectives.<id>) from MapInfo at round start
	and runs the capture simulation every TICK seconds.

	Capture model (Progress: -1 = Axis owned .. 0 = neutral .. +1 = Allies owned)
	  * Alive players of each side inside the (mode-scaled) radius are counted. Players in vehicles
	    count too. Riflemen (perk "FastCapture") count as FAST_CAPTURE_WEIGHT players.
	  * Only one side present -> progress moves toward that side. Both present -> Contested; the side
	    with more (weighted) players still progresses using its advantage, equal numbers freeze it.
	  * Rate = 1 / mode.captureTime per second x min(3, advantage ^ 0.6)  (diminishing, capped at 3x).
	  * Enemy-owned points must first be neutralised (progress crosses 0 -> Owner "Neutral",
	    "Objective Neutralized" award), then captured (|progress| reaches 1 -> Owner = side,
	    Bus ObjectiveCaptured, capture awards via ScoreService).
	  * With nobody inside, progress slowly returns to the owner's resting value.
	  * Frontline: points are ordered (Order 1 = Allies end). Capturable = neutral points between the
	    two fronts, or (if none) the frontmost point of each side. Everything else is Locked.
	  * Defending: a kill made by the owning side on/near its objective awards "Objective Defended".

	Public API
	  ObjectiveService.Setup(mapInfo, modeDef)
	  ObjectiveService.Clear()
	  ObjectiveService.GetOwnedCount(side) -> number
	  ObjectiveService.GetObjectiveCount() -> number
	  ObjectiveService.GetObjectiveSpawns(side) -> {{id, name, position, spawns: {CFrame}, available, reason?}}
	  ObjectiveService.GetObjectives() -> {{id, name, position, radius, order, owner, locked, contested}}
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local Classes = require(Shared.Config.Classes)
local Progression = require(Shared.Config.Progression)
local GameState = require(Shared.GameState)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)

local ObjectiveService = {}

local TICK = 0.25
local MAX_MULTIPLIER = 3
local FAST_CAPTURE_WEIGHT = 1.5
local DECAY_RATE_SCALE = 0.5 -- resting-state recovery speed relative to a single capturer
local VERTICAL_TOLERANCE = 30
local DEFEND_RADIUS_SCALE = 1.5

type Objective = {
	id: string,
	name: string,
	position: Vector3,
	radius: number,
	order: number,
	owner: string, -- "Allies" | "Axis" | "Neutral"
	progress: number,
	contested: boolean,
	capturing: string,
	locked: boolean,
	spawns: { CFrame },
	folder: Folder,
	present: { Allies: { Player }, Axis: { Player } },
}

local objectives: { Objective } = {}
local byId: { [string]: Objective } = {}
local mode: any = nil
local loopToken = 0

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

local function award(player: Player, reason: string, points: number)
	local score = getService("ScoreService")
	if score and score.Award then
		pcall(score.Award, player, reason, points)
	end
end

local function enemyOf(side: string): string
	return if side == "Allies" then "Axis" elseif side == "Axis" then "Allies" else ""
end

local function restingProgress(owner: string): number
	return if owner == "Allies" then 1 elseif owner == "Axis" then -1 else 0
end

local function notifySide(side: string, text: string)
	local remote = Net.event("Notify")
	for _, p in Players:GetPlayers() do
		if p:GetAttribute("Side") == side then
			remote:FireClient(p, { text = text, kind = "objective", duration = 4 })
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Replication & world visuals
---------------------------------------------------------------------------------------------------

local function recolorFlag(obj: Objective)
	local map = workspace:FindFirstChild("Map")
	local folder = map and map:FindFirstChild("Objectives")
	local holder = folder and folder:FindFirstChild(obj.id)
	local flag = holder and holder:FindFirstChild("Flag")
	if not flag then
		return
	end
	local color = Constants.SIDE_COLORS[obj.owner] or Constants.SIDE_COLORS.Neutral
	if flag:IsA("BasePart") then
		flag.Color = color
	else
		for _, d in flag:GetDescendants() do
			if d:IsA("BasePart") and d.Name ~= "Pole" then
				d.Color = color
			end
		end
	end
end

local function writeFolder(obj: Objective)
	local f = obj.folder
	f:SetAttribute("Owner", obj.owner)
	f:SetAttribute("Progress", math.round(obj.progress * 1000) / 1000)
	f:SetAttribute("Contested", obj.contested)
	f:SetAttribute("Capturing", obj.capturing)
	f:SetAttribute("Locked", obj.locked)
end

---------------------------------------------------------------------------------------------------
-- Frontline locking
---------------------------------------------------------------------------------------------------

local function isFrontline(): boolean
	return mode ~= nil and mode.id == "Frontline"
end

local function updateLocks()
	if not isFrontline() then
		for _, obj in objectives do
			obj.locked = false
		end
		return
	end
	-- objectives is sorted by order. Allies front = highest Allies-owned order, Axis front = lowest Axis-owned.
	local alliesFront, axisFront = 0, #objectives + 1
	for i, obj in objectives do
		if obj.owner == "Allies" then
			alliesFront = math.max(alliesFront, i)
		end
	end
	for i = #objectives, 1, -1 do
		if objectives[i].owner == "Axis" then
			axisFront = math.min(axisFront, i)
		end
	end
	local neutralBetween = false
	for i = alliesFront + 1, axisFront - 1 do
		if objectives[i] and objectives[i].owner == "Neutral" then
			neutralBetween = true
		end
	end
	for i, obj in objectives do
		local capturable
		if neutralBetween then
			capturable = i > alliesFront and i < axisFront and obj.owner == "Neutral"
		else
			capturable = i == alliesFront or i == axisFront
		end
		obj.locked = not capturable
	end
end

---------------------------------------------------------------------------------------------------
-- Capture simulation
---------------------------------------------------------------------------------------------------

local function liveRoot(player: Player): BasePart?
	if player:GetAttribute("Alive") ~= true then
		return nil
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

local function inside(obj: Objective, position: Vector3, scale: number): boolean
	local d = position - obj.position
	local r = obj.radius * scale
	return d.X * d.X + d.Z * d.Z <= r * r and math.abs(d.Y) <= math.max(VERTICAL_TOLERANCE, r)
end

local function captureWeight(player: Player): number
	local classId = player:GetAttribute("Class")
	local class = Classes.get(if type(classId) == "string" then classId else "")
	if class and table.find(class.perks, "FastCapture") then
		return FAST_CAPTURE_WEIGHT
	end
	return 1
end

local function captured(obj: Objective, side: string)
	obj.owner = side
	obj.progress = restingProgress(side)
	local capturers = table.clone(obj.present[side])
	recolorFlag(obj)
	Bus.fire("ObjectiveCaptured", obj.id, side, capturers)
	notifySide(side, `Objective {obj.id} captured — {obj.name}`)
	notifySide(enemyOf(side), `The enemy captured objective {obj.id} — {obj.name}`)
end

local function neutralized(obj: Objective, bySide: string)
	local previous = obj.owner
	obj.owner = "Neutral"
	recolorFlag(obj)
	for _, p in obj.present[bySide] do
		award(p, "Objective Neutralized", Progression.SCORE.Neutralize)
	end
	notifySide(bySide, `Objective {obj.id} neutralized`)
	notifySide(previous, `Objective {obj.id} is being lost!`)
end

local function tickObjective(obj: Objective, dt: number, lockChanged: { boolean })
	local present = { Allies = {}, Axis = {} }
	local weight = { Allies = 0, Axis = 0 }
	for _, p in Players:GetPlayers() do
		local side = p:GetAttribute("Side")
		if side == "Allies" or side == "Axis" then
			local root = liveRoot(p)
			if root and inside(obj, root.Position, 1) then
				table.insert(present[side], p)
				weight[side] += captureWeight(p)
			end
		end
	end
	obj.present = present

	local hasA, hasX = #present.Allies > 0, #present.Axis > 0
	obj.contested = hasA and hasX
	obj.capturing = ""

	if obj.locked then
		obj.progress = restingProgress(obj.owner)
		writeFolder(obj)
		return
	end

	local baseRate = 1 / math.max(1, (mode and mode.captureTime) or 12)
	local advantage = weight.Allies - weight.Axis
	if advantage ~= 0 then
		local side = if advantage > 0 then "Allies" else "Axis"
		local dir = if advantage > 0 then 1 else -1
		local resting = restingProgress(obj.owner)
		-- Already fully owned by this side: nothing to do.
		if not (obj.owner == side and obj.progress * dir >= 1) then
			local mult = math.min(MAX_MULTIPLIER, math.abs(advantage) ^ 0.6)
			local before = obj.progress
			local after = math.clamp(before + dir * baseRate * mult * dt, -1, 1)
			obj.progress = after
			obj.capturing = side
			-- Crossing zero from the enemy's side neutralizes the point.
			if obj.owner == enemyOf(side) and before * dir < 0 and after * dir >= 0 then
				neutralized(obj, side)
				lockChanged[1] = true
			end
			if after * dir >= 1 and obj.owner ~= side then
				captured(obj, side)
				lockChanged[1] = true
			end
		elseif resting ~= obj.progress then
			obj.progress = resting
		end
	elseif not hasA and not hasX then
		-- Nobody here: recover toward the resting value.
		local resting = restingProgress(obj.owner)
		local diff = resting - obj.progress
		if math.abs(diff) > 1e-3 then
			local step = baseRate * DECAY_RATE_SCALE * dt
			obj.progress += math.clamp(diff, -step, step)
		else
			obj.progress = resting
		end
	end
	writeFolder(obj)
end

local function runLoop(token: number)
	local last = os.clock()
	while loopToken == token do
		task.wait(TICK)
		if loopToken ~= token then
			break
		end
		local now = os.clock()
		local dt = math.min(now - last, 1)
		last = now
		if GameState.get("Phase") == "InRound" then
			local lockChanged = { false }
			for _, obj in objectives do
				local ok, err = pcall(tickObjective, obj, dt, lockChanged)
				if not ok then
					warn(`[ObjectiveService] tick {obj.id} failed: {err}`)
				end
			end
			if lockChanged[1] then
				updateLocks()
				for _, obj in objectives do
					writeFolder(obj)
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Setup / teardown
---------------------------------------------------------------------------------------------------

local function defaultSpawns(position: Vector3, radius: number): { CFrame }
	local list = {}
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	for i = 0, 5 do
		local a = i / 6 * math.pi * 2
		local p = position + Vector3.new(math.cos(a), 0, math.sin(a)) * radius * 0.7
		local hit = workspace:Raycast(p + Vector3.new(0, 60, 0), Vector3.new(0, -160, 0), params)
		local y = if hit then hit.Position.Y else p.Y
		local spawnPos = Vector3.new(p.X, y + 3, p.Z)
		table.insert(list, CFrame.lookAt(spawnPos, Vector3.new(position.X, spawnPos.Y, position.Z)))
	end
	return list
end

function ObjectiveService.Clear()
	loopToken += 1
	objectives = {}
	byId = {}
	mode = nil
	local folder = GameState.objectives()
	for _, child in folder:GetChildren() do
		child:Destroy()
	end
end

function ObjectiveService.Setup(mapInfo: any, modeDef: any)
	ObjectiveService.Clear()
	mode = modeDef
	if not modeDef or not modeDef.usesObjectives or type(mapInfo) ~= "table" then
		return
	end
	local defs = {}
	for _, def in (mapInfo.objectives or {}) :: { any } do
		if type(def) == "table" and type(def.id) == "string" and typeof(def.position) == "Vector3" then
			table.insert(defs, def)
		end
	end
	table.sort(defs, function(a, b)
		return (a.order or 0) < (b.order or 0)
	end)

	-- Frontline: Allies hold the low end, Axis the high end, the middle point (odd count) is neutral.
	local frontlineOwners: { string }? = nil
	if modeDef.id == "Frontline" then
		local owners = {}
		local n = #defs
		for i = 1, n do
			if n % 2 == 1 and i == (n + 1) / 2 then
				owners[i] = "Neutral"
			elseif i <= n / 2 then
				owners[i] = "Allies"
			else
				owners[i] = "Axis"
			end
		end
		frontlineOwners = owners
	end

	local scale = modeDef.captureRadiusScale or 1
	local parent = GameState.objectives()
	for i, def in defs do
		local owner = if frontlineOwners
			then frontlineOwners[i]
			elseif def.initialOwner == "Allies" or def.initialOwner == "Axis" then def.initialOwner
			else "Neutral"
		local radius = (if type(def.radius) == "number" then def.radius else 20) * scale
		local spawns = {}
		if type(def.spawns) == "table" then
			for _, cf in def.spawns do
				if typeof(cf) == "CFrame" then
					table.insert(spawns, cf)
				end
			end
		end
		if #spawns == 0 then
			spawns = defaultSpawns(def.position, radius)
		end
		local folder = Instance.new("Folder")
		folder.Name = def.id
		folder:SetAttribute("DisplayName", tostring(def.name or def.id))
		folder:SetAttribute("Position", def.position)
		folder:SetAttribute("Radius", radius)
		folder:SetAttribute("Order", i)
		local obj: Objective = {
			id = def.id,
			name = tostring(def.name or def.id),
			position = def.position,
			radius = radius,
			order = i,
			owner = owner,
			progress = restingProgress(owner),
			contested = false,
			capturing = "",
			locked = false,
			spawns = spawns,
			folder = folder,
			present = { Allies = {}, Axis = {} },
		}
		table.insert(objectives, obj)
		byId[obj.id] = obj
	end
	updateLocks()
	for _, obj in objectives do
		writeFolder(obj)
		obj.folder.Parent = parent
		recolorFlag(obj)
	end
	local token = loopToken
	task.spawn(runLoop, token)
end

---------------------------------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------------------------------

function ObjectiveService.GetOwnedCount(side: string): number
	local n = 0
	for _, obj in objectives do
		if obj.owner == side then
			n += 1
		end
	end
	return n
end

function ObjectiveService.GetObjectiveCount(): number
	return #objectives
end

function ObjectiveService.GetObjectives()
	local list = {}
	for _, obj in objectives do
		table.insert(list, {
			id = obj.id,
			name = obj.name,
			position = obj.position,
			radius = obj.radius,
			order = obj.order,
			owner = obj.owner,
			locked = obj.locked,
			contested = obj.contested,
		})
	end
	return list
end

-- Spawn options at objectives owned by `side`. Unavailable while enemies are on the point.
function ObjectiveService.GetObjectiveSpawns(side: string)
	local list = {}
	for _, obj in objectives do
		if obj.owner == side then
			local enemies = obj.present[enemyOf(side)] or {}
			local available = #enemies == 0 and #obj.spawns > 0
			table.insert(list, {
				id = obj.id,
				name = obj.name,
				position = obj.position,
				spawns = obj.spawns,
				available = available,
				reason = if available then nil else "Objective under attack",
			})
		end
	end
	return list
end

---------------------------------------------------------------------------------------------------
-- Defend awards
---------------------------------------------------------------------------------------------------

local function onPlayerKilled(victim: any, killer: any)
	if #objectives == 0 then
		return
	end
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") then
		return
	end
	if typeof(killer) ~= "Instance" or not killer:IsA("Player") or killer == victim then
		return
	end
	local killerSide = killer:GetAttribute("Side")
	if killerSide == victim:GetAttribute("Side") then
		return
	end
	local positions = {}
	for _, p in { victim, killer } do
		local character = p.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(positions, root.Position)
		end
	end
	for _, obj in objectives do
		if obj.owner == killerSide and not obj.locked then
			for _, pos in positions do
				if inside(obj, pos, DEFEND_RADIUS_SCALE) then
					award(killer, "Objective Defended", Progression.SCORE.Defend)
					return
				end
			end
		end
	end
end

function ObjectiveService:Init()
	Net.event("Notify")
end

function ObjectiveService:Start()
	Bus.connect("PlayerKilled", onPlayerKilled)
end

return ObjectiveService
