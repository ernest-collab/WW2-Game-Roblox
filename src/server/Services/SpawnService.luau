--[[
	SpawnService (Gameplay team)

	Server-authoritative deployment.
	  * `Spawn_Request {classId, loadout, spawnId}` -> validates class unlock (ProgressionService level),
	    loadout (Config/Progression helpers over Config/Weapons; class defaults when Weapons is absent),
	    spawn option availability and the respawn timer, then deploys. Replies with `Spawn_Result`.
	  * `Spawn_GetOptions` (RemoteFunction) -> {{id, name, position, kind, available, reason?}}
	    ids: "HQ", objective ids, "Squad".
	  * Deploy: LoadCharacter (CharacterAutoLoads = false), place at a randomised spawn CFrame that
	    avoids nearby enemies, set Class / Loadout / Alive, collision group Players, MaxHealth & walk
	    speed per class, BreakJointsOnDeath = false, SpawnProtected, OutfitService.Apply,
	    CombatService.GiveLoadout, Bus PlayerSpawned.
	  * Death: Humanoid.Died (or the character vanishing, e.g. fell into the void) -> Alive = false,
	    Bus `PlayerDied(victim, killer?, weaponId?)` for EVERY death (contract addition; RoundService
	    ticket loss + ScoreService deaths), `Player_Died {killer, weaponId, respawnTime}` to the client.
	  * Out of bounds: player attribute `OutOfBounds` (server time deadline, 0 = inside; contract
	    addition). The player dies when the deadline passes, or immediately when falling below the map.
	  * If the place has no deploy UI (no Client.Controllers.UIController), players are auto-deployed
	    so the core loop is always playable.

	Public API
	  SpawnService.SetSpawningEnabled(enabled)
	  SpawnService.IsSpawningEnabled() -> boolean
	  SpawnService.KillAndDespawnAll()
	  SpawnService.GetOptions(player) -> options
	  SpawnService.Revive(player, cframe, health, reviver?) -> boolean   (used by GadgetService)
	  SpawnService.GetLastDeath(player) -> {position: Vector3, time: number}?
	  SpawnService.GetRespawnTime() -> number
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local Classes = require(Shared.Config.Classes)
local GameModes = require(Shared.Config.GameModes)
local Progression = require(Shared.Config.Progression)
local GameState = require(Shared.GameState)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)
local Trove = require(Shared.Util.Trove)

local SpawnService = {}

local ENEMY_SAFE_RADIUS = 40
local SPAWN_JITTER = 2.5
local KILL_INFO_WINDOW = 1.5
local OOB_DEFAULT_SECONDS = 10
local OOB_FALL_MARGIN = 60
local TIMER_SLACK = 0.3
local AUTO_DEPLOY_CLASS = "Rifleman"

type PlayerState = {
	trove: any, -- Trove for the current character
	character: Model?,
	spawning: boolean,
	despawning: boolean,
	nextSpawnAt: number, -- os.clock()
	lastClass: string?,
	lastLoadout: any,
	lastDeath: { position: Vector3, time: number }?,
	oobNotified: boolean,
}

local states: { [Player]: PlayerState } = {}
local recentKills: { [Player]: { killer: Player?, weaponId: string?, t: number } } = {}
local spawningEnabled = false
local autoDeploy = false

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

-- pcall a function on another service if it exists. Returns (called, ...results) — every return
-- value is forwarded (SquadService.GetSquadSpawn returns cframe, target, reason).
local function callService(serviceName: string, fnName: string, ...: any): (boolean, ...any)
	local svc = getService(serviceName)
	local fn = svc and svc[fnName]
	if type(fn) ~= "function" then
		return false, nil
	end
	local results = table.pack(pcall(fn, ...))
	if not results[1] then
		warn(`[SpawnService] {serviceName}.{fnName} failed: {results[2]}`)
		return false, nil
	end
	return table.unpack(results, 1, results.n)
end

local function getState(player: Player): PlayerState
	local s = states[player]
	if not s then
		s = {
			trove = Trove.new(),
			character = nil,
			spawning = false,
			despawning = false,
			nextSpawnAt = 0,
			lastClass = nil,
			lastLoadout = nil,
			lastDeath = nil,
			oobNotified = false,
		}
		states[player] = s
	end
	return s
end

local function notify(player: Player, text: string, kind: string?)
	Net.event("Notify"):FireClient(player, { text = text, kind = kind or "info", duration = 4 })
end

local function sideOf(player: Player): string
	local s = player:GetAttribute("Side")
	return if type(s) == "string" then s else ""
end

local function currentMode(): any
	return GameModes.byId[GameState.get("ModeId") or ""]
end

function SpawnService.GetRespawnTime(): number
	local mode = currentMode()
	return if mode and type(mode.respawnTime) == "number" then mode.respawnTime else Constants.RESPAWN_TIME
end

local function currentMapInfo(): any
	local _, info = callService("RoundService", "GetMapInfo")
	return info
end

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

---------------------------------------------------------------------------------------------------
-- Spawn options
---------------------------------------------------------------------------------------------------

type Option = {
	id: string,
	name: string,
	position: Vector3,
	kind: string,
	available: boolean,
	reason: string?,
	cframes: { CFrame },
	target: Player?,
}

local function buildOptions(player: Player): { Option }
	local options: { Option } = {}
	local side = sideOf(player)
	local mapInfo = currentMapInfo()
	if side == "" or type(mapInfo) ~= "table" then
		return options
	end

	local hq = mapInfo.hq and mapInfo.hq[side]
	if type(hq) == "table" and #hq > 0 then
		table.insert(options, {
			id = "HQ",
			name = "Headquarters",
			position = hq[1].Position,
			kind = "HQ",
			available = true,
			cframes = hq,
		})
	end

	local mode = currentMode()
	if mode and mode.usesObjectives then
		local ok, list = callService("ObjectiveService", "GetObjectiveSpawns", side)
		if ok and type(list) == "table" then
			for _, o in list do
				table.insert(options, {
					id = o.id,
					name = `{o.id} — {o.name}`,
					position = o.position,
					kind = "Objective",
					available = o.available == true,
					reason = o.reason,
					cframes = o.spawns or {},
				})
			end
		end
	end

	local ok, cf, target, reason = callService("SquadService", "GetSquadSpawn", player)
	if ok then
		local squadCf: CFrame? = if typeof(cf) == "CFrame" then cf else nil
		local targetPlayer: Player? = if typeof(target) == "Instance" and target:IsA("Player") then target else nil
		local position = if squadCf
			then squadCf.Position
			elseif targetPlayer and liveRoot(targetPlayer) then (liveRoot(targetPlayer) :: BasePart).Position
			else Vector3.zero
		table.insert(options, {
			id = "Squad",
			name = if targetPlayer then `Squad — {targetPlayer.DisplayName}` else "Squad",
			position = position,
			kind = "Squad",
			available = squadCf ~= nil,
			reason = if squadCf then nil else (if type(reason) == "string" then reason else "Unavailable"),
			cframes = if squadCf then { squadCf } else {},
			target = targetPlayer,
		})
	end
	return options
end

function SpawnService.GetOptions(player: Player)
	local out = {}
	for _, o in buildOptions(player) do
		table.insert(out, {
			id = o.id,
			name = o.name,
			position = o.position,
			kind = o.kind,
			available = o.available,
			reason = o.reason,
		})
	end
	return out
end

-- Picks a random CFrame with no enemy nearby (or the one farthest from enemies), plus jitter.
local function chooseSpawn(cframes: { CFrame }, side: string, jitter: boolean): CFrame?
	if #cframes == 0 then
		return nil
	end
	local enemies = {}
	for _, p in Players:GetPlayers() do
		local s = sideOf(p)
		if s ~= "" and s ~= side then
			local root = liveRoot(p)
			if root then
				table.insert(enemies, root.Position)
			end
		end
	end
	local safe = {}
	local best, bestDist = cframes[1], -1
	for _, cf in cframes do
		local minDist = math.huge
		for _, pos in enemies do
			minDist = math.min(minDist, (pos - cf.Position).Magnitude)
		end
		if minDist >= ENEMY_SAFE_RADIUS then
			table.insert(safe, cf)
		end
		if minDist > bestDist then
			best, bestDist = cf, minDist
		end
	end
	local chosen = if #safe > 0 then safe[math.random(1, #safe)] else best
	if jitter then
		local a = math.random() * math.pi * 2
		local r = math.random() * SPAWN_JITTER
		chosen = chosen + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
	end
	return chosen
end

---------------------------------------------------------------------------------------------------
-- Death handling
---------------------------------------------------------------------------------------------------

local function sendDied(player: Player, killer: Player?, weaponId: string?)
	local state = states[player]
	local remaining = if state then math.max(0, state.nextSpawnAt - os.clock()) else SpawnService.GetRespawnTime()
	Net.event("Player_Died"):FireClient(player, {
		killer = killer,
		weaponId = weaponId,
		respawnTime = remaining,
	})
end

local function onCharacterDied(player: Player, character: Model)
	local state = states[player]
	if not state or state.character ~= character or state.despawning then
		return
	end
	if player:GetAttribute("Alive") ~= true then
		return -- already handled
	end
	player:SetAttribute("Alive", false)
	player:SetAttribute("OutOfBounds", 0)
	character:SetAttribute("SpawnProtected", false)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		state.lastDeath = { position = root.Position, time = os.clock() }
	end
	state.nextSpawnAt = os.clock() + SpawnService.GetRespawnTime()
	state.oobNotified = false

	-- Wait a moment so CombatService's PlayerKilled (if any) can be attributed to this death.
	task.delay(0.15, function()
		if not player.Parent then
			return
		end
		local info = recentKills[player]
		local killer: Player?, weaponId: string? = nil, nil
		if info and os.clock() - info.t <= KILL_INFO_WINDOW then
			killer, weaponId = info.killer, info.weaponId
		end
		recentKills[player] = nil
		if not weaponId then
			local oob = character:GetAttribute("DiedOutOfBounds")
			weaponId = if oob then "OutOfBounds" else "Environment"
		end
		Bus.fire("PlayerDied", player, killer, weaponId)
		sendDied(player, killer, weaponId)
	end)
end

---------------------------------------------------------------------------------------------------
-- Deploy
---------------------------------------------------------------------------------------------------

type SpawnOpts = { health: number?, protection: number? }

local function setCollisionGroup(instance: Instance)
	if instance:IsA("BasePart") then
		instance.CollisionGroup = Constants.COLLISION_GROUPS.Players
	end
end

-- LoadCharacterAsync where available (newer engines), LoadCharacter otherwise.
local function loadCharacter(player: Player)
	local asyncOk = pcall(function()
		return (player :: any).LoadCharacterAsync
	end)
	if asyncOk then
		player:LoadCharacterAsync()
	else
		(player :: any):LoadCharacter()
	end
end

local function spawnCharacter(player: Player, classId: string, loadout: any, cframe: CFrame, opts: SpawnOpts?): boolean
	local state = getState(player)
	if state.spawning then
		return false
	end
	local class = Classes.get(classId)
	if not class then
		return false
	end
	state.spawning = true
	state.despawning = true -- the old body is being replaced: not a death
	state.trove:Clean()

	player:SetAttribute("Class", classId)
	player:SetAttribute("Loadout", HttpService:JSONEncode(loadout))
	player:SetAttribute("OutOfBounds", 0)
	player:SetAttribute("Revivable", 0)

	-- Workspace.StreamingEnabled: stream the destination in first, otherwise the client-owned
	-- character can land before the ground exists there and fall through the map.
	if workspace.StreamingEnabled then
		pcall(function()
			player:RequestStreamAroundAsync(cframe.Position, 4)
		end)
	end

	local ok, err = pcall(loadCharacter, player)
	state.despawning = false
	if not ok or not player.Parent then
		state.spawning = false
		if not ok then
			warn(`[SpawnService] LoadCharacter failed for {player.Name}: {err}`)
		end
		return false
	end
	local character = player.Character
	local humanoid = character
		and (character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5))
	local root = character and character:WaitForChild("HumanoidRootPart", 5)
	if not character or not humanoid or not humanoid:IsA("Humanoid") or not root then
		state.spawning = false
		warn(`[SpawnService] character for {player.Name} is missing Humanoid/HumanoidRootPart`)
		return false
	end
	state.character = character
	local trove = state.trove

	-- Physical setup
	humanoid.BreakJointsOnDeath = false
	humanoid.MaxHealth = class.maxHealth
	humanoid.Health = math.clamp((opts and opts.health) or class.maxHealth, 1, class.maxHealth)
	humanoid.WalkSpeed = Constants.WALK_SPEED * class.speedMultiplier
	character:SetAttribute("SpeedMultiplier", class.speedMultiplier)
	for _, d in character:GetDescendants() do
		setCollisionGroup(d)
	end
	trove:Add(character.DescendantAdded:Connect(setCollisionGroup))
	character:PivotTo(cframe)

	-- Spawn protection (CombatService cancels it when the player fires).
	local protection = (opts and opts.protection) or Constants.SPAWN_PROTECTION
	character:SetAttribute("SpawnProtected", protection > 0)
	if protection > 0 then
		trove:Add(task.delay(protection, function()
			if character.Parent then
				character:SetAttribute("SpawnProtected", false)
			end
		end))
	end

	-- Death detection: Humanoid.Died, or the body disappearing (void, external Destroy).
	trove:Add(humanoid.Died:Connect(function()
		onCharacterDied(player, character)
	end))
	trove:Add(character.AncestryChanged:Connect(function()
		if not character:IsDescendantOf(workspace) then
			onCharacterDied(player, character)
		end
	end))

	state.lastClass = classId
	state.lastLoadout = loadout
	player:SetAttribute("Alive", true)

	-- Other subsystems (guarded; they may not exist yet).
	local faction = player:GetAttribute("Faction") or ""
	task.spawn(callService, "OutfitService", "Apply", character, faction, classId)
	callService("CombatService", "GiveLoadout", player, loadout)

	state.spawning = false
	Bus.fire("PlayerSpawned", player, character, classId)
	return true
end

local function playerLevel(player: Player): number
	local ok, level = callService("ProgressionService", "GetLevel", player)
	return if ok and type(level) == "number" then level else 1
end

-- Validates and performs a deploy request. Returns (ok, error).
local function handleRequest(player: Player, payload: any): (boolean, string?)
	if type(payload) ~= "table" then
		return false, "Invalid request"
	end
	if not spawningEnabled or GameState.get("Phase") ~= "InRound" then
		return false, "Deployment is closed"
	end
	local side = sideOf(player)
	if side == "" then
		return false, "Join a team first"
	end
	local state = getState(player)
	if state.spawning then
		return false, "Already deploying"
	end
	if player:GetAttribute("Alive") == true then
		return false, "Already deployed"
	end
	local wait = state.nextSpawnAt - os.clock()
	if wait > TIMER_SLACK then
		return false, `Deploy available in {math.ceil(wait)}s`
	end

	local classId = payload.classId
	if type(classId) ~= "string" then
		return false, "Choose a class"
	end
	local class = Classes.get(classId)
	if not class then
		return false, "Unknown class"
	end
	local level = playerLevel(player)
	if class.unlockLevel > level then
		return false, `{class.name} unlocks at level {class.unlockLevel}`
	end
	local factionAttr = player:GetAttribute("Faction")
	local faction: string? = if type(factionAttr) == "string" then factionAttr else nil
	local loadout = Progression.validateLoadout(classId, faction, level, payload.loadout)
	-- Weapons bought early (MonetizationService "Instant Weapon Unlock") skip only the level check:
	-- class slot category + faction rules still apply.
	if type(payload.loadout) == "table" then
		for _, slot in Progression.SLOTS do
			local wanted = payload.loadout[slot]
			if type(wanted) == "string" and wanted ~= "" and (loadout :: any)[slot] ~= wanted then
				local _, purchased = callService("MonetizationService", "IsWeaponPurchased", player, wanted)
				local allowed = false
				if purchased == true then
					for _, def in Progression.allowedWeapons(classId, slot, faction, math.huge) do
						if def.id == wanted then
							allowed = true
							break
						end
					end
				end
				if allowed then
					(loadout :: any)[slot] = wanted
				end
			end
		end
	end

	local spawnId = payload.spawnId
	if type(spawnId) ~= "string" or #spawnId > 32 then
		spawnId = "HQ"
	end
	local chosen: Option? = nil
	for _, o in buildOptions(player) do
		if o.id == spawnId then
			chosen = o
			break
		end
	end
	if not chosen then
		return false, "Spawn point not available"
	end
	if not chosen.available then
		return false, chosen.reason or "Spawn point not available"
	end
	local cf = chooseSpawn(chosen.cframes, side, chosen.kind ~= "Squad")
	if not cf then
		return false, "Spawn point not available"
	end
	if not spawnCharacter(player, classId, loadout, cf) then
		return false, "Deploy failed, try again"
	end
	if chosen.kind == "Squad" and chosen.target then
		callService("ScoreService", "Award", chosen.target, "Squad Spawn", Progression.SCORE.SquadSpawn)
	end
	return true, nil
end

---------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------

function SpawnService.SetSpawningEnabled(enabled: boolean)
	spawningEnabled = enabled == true
	if spawningEnabled then
		for _, state in states do
			state.nextSpawnAt = 0
		end
	end
end

function SpawnService.IsSpawningEnabled(): boolean
	return spawningEnabled
end

function SpawnService.KillAndDespawnAll()
	for _, player in Players:GetPlayers() do
		local state = getState(player)
		state.despawning = true
		state.trove:Clean()
		local character = player.Character
		state.character = nil
		player:SetAttribute("Alive", false)
		player:SetAttribute("OutOfBounds", 0)
		player:SetAttribute("Revivable", 0)
		if character then
			character:Destroy()
		end
		pcall(function()
			(player :: any).Character = nil
		end)
		state.lastDeath = nil
		state.despawning = false
	end
	table.clear(recentKills)
end

function SpawnService.GetLastDeath(player: Player)
	local state = states[player]
	return state and state.lastDeath
end

-- Revive a dead player in place (GadgetService). Uses their last class & loadout.
function SpawnService.Revive(player: Player, cframe: CFrame, health: number, _reviver: Player?): boolean
	if not spawningEnabled or GameState.get("Phase") ~= "InRound" then
		return false
	end
	local state = states[player]
	if not state or not state.lastClass or player:GetAttribute("Alive") == true or state.spawning then
		return false
	end
	local ok = spawnCharacter(player, state.lastClass, state.lastLoadout or {}, cframe, {
		health = health,
		protection = 1,
	})
	if ok then
		Net.event("Spawn_Result"):FireClient(player, { ok = true, revived = true })
	end
	return ok
end

---------------------------------------------------------------------------------------------------
-- Out of bounds + auto deploy loop
---------------------------------------------------------------------------------------------------

local function killCharacter(character: Model, outOfBounds: boolean)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		if outOfBounds then
			character:SetAttribute("DiedOutOfBounds", true)
		end
		humanoid.Health = 0
	end
end

local function checkBounds()
	local mapInfo = currentMapInfo()
	local bounds = type(mapInfo) == "table" and mapInfo.bounds
	if type(bounds) ~= "table" or typeof(bounds.center) ~= "Vector3" or typeof(bounds.size) ~= "Vector3" then
		return
	end
	local center: Vector3, size: Vector3 = bounds.center, bounds.size
	local grace = if type(mapInfo.outOfBounds) == "number" then mapInfo.outOfBounds else OOB_DEFAULT_SECONDS
	local serverNow = workspace:GetServerTimeNow()
	for _, player in Players:GetPlayers() do
		local root = liveRoot(player)
		local character = player.Character
		if root and character then
			local p = root.Position
			if p.Y < center.Y - size.Y / 2 - OOB_FALL_MARGIN then
				killCharacter(character, true)
			else
				local outside = math.abs(p.X - center.X) > size.X / 2 or math.abs(p.Z - center.Z) > size.Z / 2
				local deadline = player:GetAttribute("OutOfBounds")
				local state = getState(player)
				if outside then
					if type(deadline) ~= "number" or deadline <= 0 then
						player:SetAttribute("OutOfBounds", serverNow + grace)
						if not state.oobNotified then
							state.oobNotified = true
							notify(player, `Return to the battlefield! ({grace}s)`, "warning")
						end
					elseif serverNow >= deadline then
						killCharacter(character, true)
					end
				elseif type(deadline) == "number" and deadline > 0 then
					player:SetAttribute("OutOfBounds", 0)
					state.oobNotified = false
				end
			end
		end
	end
end

local function autoDeployTick()
	if not autoDeploy or not spawningEnabled or GameState.get("Phase") ~= "InRound" then
		return
	end
	for _, player in Players:GetPlayers() do
		local state = getState(player)
		if
			player:GetAttribute("Alive") ~= true
			and not state.spawning
			and sideOf(player) ~= ""
			and os.clock() >= state.nextSpawnAt
		then
			local revivable = player:GetAttribute("Revivable")
			if not (type(revivable) == "number" and revivable > workspace:GetServerTimeNow()) then
				task.spawn(handleRequest, player, {
					classId = state.lastClass or AUTO_DEPLOY_CLASS,
					loadout = state.lastLoadout,
					spawnId = "HQ",
				})
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

local function detectDeployUI(): boolean
	local scripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
	local client = scripts and scripts:FindFirstChild("Client")
	local controllers = client and client:FindFirstChild("Controllers")
	return controllers ~= nil and controllers:FindFirstChild("UIController") ~= nil
end

function SpawnService:Init()
	Players.CharacterAutoLoads = false
	Net.event("Spawn_Request")
	Net.event("Spawn_Result")
	Net.event("Player_Died")
	Net.event("Notify")
	Net.func("Spawn_GetOptions")
end

function SpawnService:Start()
	autoDeploy = not detectDeployUI()
	if autoDeploy then
		warn("[SpawnService] no UIController found: players will be auto-deployed at HQ.")
	end

	Net.event("Spawn_Request").OnServerEvent:Connect(function(player: Player, payload: any)
		if not Net.rateLimit(player, "Spawn_Request", 3) then
			return
		end
		local ok, err = handleRequest(player, payload)
		Net.event("Spawn_Result"):FireClient(player, { ok = ok, error = err })
	end)

	Net.func("Spawn_GetOptions").OnServerInvoke = function(player: Player)
		if not Net.rateLimit(player, "Spawn_GetOptions", 6) then
			return {}
		end
		return SpawnService.GetOptions(player)
	end

	Bus.connect("PlayerKilled", function(victim: any, killer: any, weaponId: any)
		if typeof(victim) == "Instance" and victim:IsA("Player") then
			recentKills[victim] = {
				killer = if typeof(killer) == "Instance" and killer:IsA("Player") then killer else nil,
				weaponId = if type(weaponId) == "string" then weaponId else nil,
				t = os.clock(),
			}
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		getState(player)
		player:SetAttribute("Alive", false)
		player:SetAttribute("Class", player:GetAttribute("Class") or "")
		player:SetAttribute("Loadout", player:GetAttribute("Loadout") or "")
		player:SetAttribute("OutOfBounds", 0)
	end)
	for _, p in Players:GetPlayers() do
		getState(p)
		if p:GetAttribute("Alive") == nil then
			p:SetAttribute("Alive", false)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		local state = states[player]
		if state then
			state.despawning = true
			state.trove:Clean()
		end
		states[player] = nil
		recentKills[player] = nil
	end)

	task.spawn(function()
		while true do
			task.wait(0.5)
			local ok, err = pcall(checkBounds)
			if not ok then
				warn(`[SpawnService] bounds check failed: {err}`)
			end
			pcall(autoDeployTick)
		end
	end)
end

return SpawnService
