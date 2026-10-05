--[[
	RoundService (Gameplay team)

	The match state machine. Writes GameState (Phase, ModeId, MapId, TimeLeft, factions, tickets,
	scores, Winner, LightingPreset, Weather; MapInfoJson only when using the fallback arena).

	  Waiting      -> until Constants.MIN_PLAYERS_TO_START players are in the server
	  Intermission -> countdown (short when only one player is present); next map from
	                  MapService.GetAvailableMaps() rotation + a mode supported by that map
	  Loading      -> MapService.LoadMap (FallbackArena if MapService is missing/fails), random factions
	                  from the map definition, tickets/scores init, objectives, vehicles, spawning on
	  InRound      -> mode rules (Conquest / Frontline / TDM, see Config/GameModes.luau), timer, win checks
	  PostRound    -> Winner, Round_Ended (top players + MVP), Bus RoundEnded, round XP, despawn
	  -> map unload -> Intermission

	Tickets: every death (Bus PlayerDied from SpawnService, includes falls / out-of-bounds) costs the
	victim's side 1 ticket in Conquest & Frontline. Revives refund it (GadgetService -> AdjustTickets).

	Public API
	  RoundService.GetMapInfo() -> MapInfo?     (server form; from MapService or FallbackArena)
	  RoundService.GetMode() -> ModeDef?
	  RoundService.GetPhase() -> string
	  RoundService.AdjustTickets(side, delta)
	  RoundService.EndRound(winner)             -- force the current round to end (admin / debug)
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local GameModes = require(Shared.Config.GameModes)
local Maps = require(Shared.Config.Maps)
local Progression = require(Shared.Config.Progression)
local GameState = require(Shared.GameState)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)

local RoundService = {}

local SOLO_INTERMISSION = 5
local LOADING_SETTLE = 1.5 -- seconds after the map is built before deployment opens
local DESPAWN_DELAY = 4 -- seconds into PostRound before everyone is despawned
local TOP_PLAYERS = 10
local FALLBACK_FACTIONS = { Allies = "US", Axis = "DE" }

local mapInfo: any = nil
local mode: any = nil
local usingFallback = false
local tickets = { Allies = 0, Axis = 0 }
local teamScore = { Allies = 0, Axis = 0 }
local pendingWinner: string? = nil
local rotationIndex = 0
local lastMapId = ""
local lastModeByMap: { [string]: string } = {}
local modeCursor = 0

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
		warn(`[RoundService] {serviceName}.{fnName} failed: {result}`)
		return false, nil
	end
	return true, result
end

local function notifyAll(text: string, kind: string?, duration: number?)
	Net.event("Notify"):FireAllClients({ text = text, kind = kind or "info", duration = duration or 5 })
end

local function setPhase(phase: string, timeLeft: number?)
	GameState.set("Phase", phase)
	GameState.set("TimeLeft", math.max(0, math.ceil(timeLeft or 0)))
end

local function playerCount(): number
	return #Players:GetPlayers()
end

---------------------------------------------------------------------------------------------------
-- Tickets / score
---------------------------------------------------------------------------------------------------

local function writeTickets()
	GameState.set("AlliesTickets", math.max(0, math.ceil(tickets.Allies)))
	GameState.set("AxisTickets", math.max(0, math.ceil(tickets.Axis)))
end

local function writeScores()
	GameState.set("AlliesScore", teamScore.Allies)
	GameState.set("AxisScore", teamScore.Axis)
end

local function usesTickets(): boolean
	return mode ~= nil and type(mode.tickets) == "number"
end

function RoundService.AdjustTickets(side: string, delta: number)
	if GameState.get("Phase") ~= "InRound" or not usesTickets() then
		return
	end
	if side ~= "Allies" and side ~= "Axis" or type(delta) ~= "number" or delta ~= delta then
		return
	end
	tickets[side] = math.clamp(tickets[side] + delta, 0, mode.tickets)
	writeTickets()
end

function RoundService.GetMapInfo(): any
	return mapInfo
end

function RoundService.GetMode(): any
	return mode
end

function RoundService.GetPhase(): string
	return GameState.get("Phase")
end

function RoundService.EndRound(winner: string)
	if GameState.get("Phase") == "InRound" then
		pendingWinner = if winner == "Allies" or winner == "Axis" then winner else "Draw"
	end
end

---------------------------------------------------------------------------------------------------
-- Map / mode selection
---------------------------------------------------------------------------------------------------

-- Returns a list of map ids that can be loaded.
local function availableMaps(): { string }
	local list = {}
	local ok, result = callService("MapService", "GetAvailableMaps")
	if ok and type(result) == "table" then
		for _, entry in result do
			local id = if type(entry) == "string" then entry elseif type(entry) == "table" then entry.id else nil
			if type(id) == "string" and Maps.byId[id] then
				table.insert(list, id)
			end
		end
	elseif getService("MapService") then
		-- MapService without GetAvailableMaps: every registered map whose builder module exists.
		local mapsFolder = script.Parent.Parent:FindFirstChild("Maps")
		for _, id in Maps.order do
			local def = Maps.byId[id]
			if def and mapsFolder and mapsFolder:FindFirstChild(def.builder) then
				table.insert(list, id)
			end
		end
	end
	return list
end

local function chooseMap(): string?
	local list = availableMaps()
	if #list == 0 then
		return nil
	end
	-- Rotation in registry order, skipping a repeat of the last map when there is a choice.
	for _ = 1, #list do
		rotationIndex = rotationIndex % #list + 1
		local id = list[rotationIndex]
		if id ~= lastMapId or #list == 1 then
			return id
		end
	end
	return list[1]
end

local function chooseMode(mapId: string?): string
	local def = mapId and Maps.byId[mapId]
	local supported = {}
	local source = if def then def.modes else GameModes.order
	for _, id in source do
		if GameModes.byId[id] then
			table.insert(supported, id)
		end
	end
	if #supported == 0 then
		return "Conquest"
	end
	-- Cycle through the supported modes, avoiding the mode last played on this map.
	local last = if mapId then lastModeByMap[mapId] else nil
	for _ = 1, #supported do
		modeCursor = modeCursor % #supported + 1
		local id = supported[modeCursor]
		if id ~= last or #supported == 1 then
			return id
		end
	end
	return supported[1]
end

local function pickRandom(list: { string }?, fallback: string): string
	if type(list) ~= "table" or #list == 0 then
		return fallback
	end
	return list[math.random(1, #list)]
end

local function encodePublicMapInfo(info: any): string
	local objectives = {}
	for _, o in info.objectives or {} do
		table.insert(objectives, {
			id = o.id,
			name = o.name,
			x = o.position.X,
			y = o.position.Y,
			z = o.position.Z,
			radius = o.radius,
			order = o.order,
		})
	end
	local function hqPoint(list: { CFrame }?)
		local cf = list and list[1]
		return if cf then { x = cf.Position.X, z = cf.Position.Z } else { x = 0, z = 0 }
	end
	local c, s = info.bounds.center, info.bounds.size
	local ok, json = pcall(HttpService.JSONEncode, HttpService, {
		id = info.id,
		bounds = { cx = c.X, cy = c.Y, cz = c.Z, sx = s.X, sy = s.Y, sz = s.Z },
		objectives = objectives,
		hq = { Allies = hqPoint(info.hq.Allies), Axis = hqPoint(info.hq.Axis) },
		minimap = info.minimap or {},
	})
	return if ok then json else ""
end

local function validMapInfo(info: any): boolean
	return type(info) == "table"
		and type(info.hq) == "table"
		and type(info.hq.Allies) == "table"
		and type(info.hq.Axis) == "table"
		and #info.hq.Allies > 0
		and #info.hq.Axis > 0
		and type(info.bounds) == "table"
end

local function loadFallback(): any
	local module = script.Parent:FindFirstChild("FallbackArena")
	if not module then
		error("FallbackArena module missing")
	end
	local arena = require(module) :: any
	callService("MapService", "UnloadMap")
	local info = arena.Build()
	usingFallback = true
	GameState.set("MapInfoJson", encodePublicMapInfo(info))
	Bus.fire("MapLoaded", info) -- MapService would normally fire this
	return info
end

local function unloadMap()
	if usingFallback then
		local module = script.Parent:FindFirstChild("FallbackArena")
		if module then
			pcall(function()
				(require(module) :: any).Destroy()
			end)
		end
		usingFallback = false
		Bus.fire("MapUnloading")
	else
		callService("MapService", "UnloadMap")
	end
	mapInfo = nil
end

---------------------------------------------------------------------------------------------------
-- Round flow
---------------------------------------------------------------------------------------------------

local function phaseWaiting()
	setPhase("Waiting", 0)
	GameState.set("Winner", "")
	while playerCount() < Constants.MIN_PLAYERS_TO_START do
		task.wait(1)
	end
end

-- Returns false if players dropped below the minimum (back to Waiting).
local function phaseIntermission(): (boolean, string?, string)
	callService("TeamService", "Rebalance")
	local mapId = chooseMap()
	local modeId = chooseMode(mapId)
	GameState.set("MapId", mapId or "FallbackArena")
	GameState.set("ModeId", modeId)
	GameState.set("Winner", "")
	local duration = if playerCount() <= 1 then SOLO_INTERMISSION else Constants.INTERMISSION_TIME
	local deadline = os.clock() + duration
	while os.clock() < deadline do
		if playerCount() < Constants.MIN_PLAYERS_TO_START then
			return false, nil, modeId
		end
		setPhase("Intermission", deadline - os.clock())
		task.wait(0.5)
	end
	return true, mapId, modeId
end

local function phaseLoading(mapId: string?, modeId: string): boolean
	setPhase("Loading", 0)
	local def = mapId and Maps.byId[mapId]
	local alliesFaction = if def then pickRandom(def.alliedFactions, "US") else FALLBACK_FACTIONS.Allies
	local axisFaction = if def then pickRandom(def.axisFactions, "DE") else FALLBACK_FACTIONS.Axis
	GameState.set("AlliesFaction", alliesFaction)
	GameState.set("AxisFaction", axisFaction)
	if def then
		GameState.set("LightingPreset", def.lighting)
		GameState.set("Weather", pickRandom(def.weather, "Clear"))
	end
	callService("TeamService", "ApplyFactions")

	-- Build the map.
	local info = nil
	usingFallback = false
	if mapId and getService("MapService") then
		local ok, result = callService("MapService", "LoadMap", mapId)
		if ok and validMapInfo(result) then
			info = result
		else
			warn(`[RoundService] MapService failed to load '{mapId}', using the fallback arena`)
		end
	end
	if not info then
		local ok, result = pcall(loadFallback)
		if not ok or not validMapInfo(result) then
			warn(`[RoundService] fallback arena failed: {result}`)
			return false
		end
		info = result
		mapId = info.id
		GameState.set("MapId", info.id)
		if not GameModes.byId[modeId] then
			modeId = "Conquest"
		end
	end
	mapInfo = info
	mode = GameModes.byId[modeId] or GameModes.byId.Conquest
	GameState.set("ModeId", mode.id)
	if mapId then
		lastMapId = mapId
		lastModeByMap[mapId] = mode.id
	end

	-- Round state
	tickets.Allies = mode.tickets or 0
	tickets.Axis = mode.tickets or 0
	teamScore.Allies, teamScore.Axis = 0, 0
	pendingWinner = nil
	writeTickets()
	writeScores()
	GameState.set("Winner", "")
	callService("ScoreService", "ResetRound")

	if mode.usesObjectives then
		callService("ObjectiveService", "Setup", mapInfo, mode)
	else
		callService("ObjectiveService", "Clear")
	end
	if mode.usesVehicles then
		callService("VehicleService", "SpawnTeamVehicles", mapInfo)
	end
	task.wait(LOADING_SETTLE)
	return true
end

-- Evaluates win conditions. Returns winner or nil.
local function checkWin(timeUp: boolean): string?
	if pendingWinner then
		return pendingWinner
	end
	local id = mode.id
	if id == "TDM" then
		local limit = mode.scoreLimit or 150
		if teamScore.Allies >= limit then
			return "Allies"
		elseif teamScore.Axis >= limit then
			return "Axis"
		end
		if timeUp then
			return if teamScore.Allies > teamScore.Axis
				then "Allies"
				elseif teamScore.Axis > teamScore.Allies then "Axis"
				else "Draw"
		end
		return nil
	end

	-- Ticket modes
	if tickets.Allies <= 0 and tickets.Axis <= 0 then
		return "Draw"
	elseif tickets.Allies <= 0 then
		return "Axis"
	elseif tickets.Axis <= 0 then
		return "Allies"
	end
	local ok, total = callService("ObjectiveService", "GetObjectiveCount")
	local _, ownedA = callService("ObjectiveService", "GetOwnedCount", "Allies")
	local _, ownedX = callService("ObjectiveService", "GetOwnedCount", "Axis")
	ownedA, ownedX = ownedA or 0, ownedX or 0
	if id == "Frontline" and ok and type(total) == "number" and total > 0 then
		if ownedA >= total then
			return "Allies"
		elseif ownedX >= total then
			return "Axis"
		end
	end
	if timeUp then
		if id == "Frontline" and ownedA ~= ownedX then
			return if ownedA > ownedX then "Allies" else "Axis"
		end
		local a, x = math.ceil(tickets.Allies), math.ceil(tickets.Axis)
		return if a > x then "Allies" elseif x > a then "Axis" else "Draw"
	end
	return nil
end

local function phaseInRound(): string
	callService("SpawnService", "SetSpawningEnabled", true)
	setPhase("InRound", mode.timeLimit)
	Bus.fire("RoundStarted", mode.id, GameState.get("MapId"))
	notifyAll(`{mode.name} — {mode.description}`, "objective", 6)

	local endsAt = os.clock() + mode.timeLimit
	local last = os.clock()
	local bleedAccum = { Allies = 0, Axis = 0 }
	while true do
		task.wait(0.5)
		local now = os.clock()
		local dt = now - last
		last = now
		GameState.set("TimeLeft", math.max(0, math.ceil(endsAt - now)))

		if playerCount() == 0 then
			return "Draw"
		end

		-- Conquest ticket bleed: the side holding more points drains the other.
		if mode.id == "Conquest" and mode.ticketBleedPerSecond then
			local _, ownedA = callService("ObjectiveService", "GetOwnedCount", "Allies")
			local _, ownedX = callService("ObjectiveService", "GetOwnedCount", "Axis")
			local diff = (ownedA or 0) - (ownedX or 0)
			if diff ~= 0 then
				local loser = if diff > 0 then "Axis" else "Allies"
				bleedAccum[loser] += mode.ticketBleedPerSecond * math.abs(diff) * dt
				if bleedAccum[loser] >= 0.05 then
					tickets[loser] = math.max(0, tickets[loser] - bleedAccum[loser])
					bleedAccum[loser] = 0
					writeTickets()
				end
			end
		end

		local winner = checkWin(now >= endsAt)
		if winner then
			return winner
		end
	end
end

local function phasePostRound(winner: string)
	callService("SpawnService", "SetSpawningEnabled", false)
	GameState.set("Winner", winner)
	setPhase("PostRound", Constants.POST_ROUND_TIME)

	-- Results
	local _, top = callService("ScoreService", "GetTopPlayers", TOP_PLAYERS)
	local topPlayers = {}
	local mvp = nil
	if type(top) == "table" then
		for i, entry in top do
			table.insert(topPlayers, {
				name = entry.name,
				userId = entry.userId,
				side = entry.side,
				score = entry.score,
				kills = entry.kills,
				deaths = entry.deaths,
			})
			if i == 1 and entry.score > 0 then
				mvp = { name = entry.name, score = entry.score, userId = entry.userId, side = entry.side }
			end
		end
	end
	Net.event("Round_Ended"):FireAllClients({ winner = winner, mvp = mvp, topPlayers = topPlayers })
	Bus.fire("RoundEnded", winner)
	if winner == "Draw" then
		notifyAll("The battle ended in a draw.", "objective", 6)
	else
		notifyAll(`The {winner} are victorious!`, "objective", 6)
	end

	-- Round XP + career stats
	for _, p in Players:GetPlayers() do
		local side = p:GetAttribute("Side")
		if side == "Allies" or side == "Axis" then
			local result = if winner == "Draw" then "Draw" elseif winner == side then "Win" else "Loss"
			local xp = Progression.ROUND_XP[result]
			callService("ProgressionService", "AddXP", p, xp, result)
			callService("ProgressionService", "RecordMatch", p, result)
			Net.event("Score_Event"):FireClient(p, {
				reason = if result == "Win" then "Victory" elseif result == "Loss" then "Participation" else "Draw",
				points = xp,
				xpOnly = true,
			})
		end
	end

	local deadline = os.clock() + Constants.POST_ROUND_TIME
	local despawned = false
	while os.clock() < deadline do
		if not despawned and os.clock() >= deadline - Constants.POST_ROUND_TIME + DESPAWN_DELAY then
			despawned = true
			callService("SpawnService", "KillAndDespawnAll")
		end
		GameState.set("TimeLeft", math.max(0, math.ceil(deadline - os.clock())))
		task.wait(0.5)
	end
	if not despawned then
		callService("SpawnService", "KillAndDespawnAll")
	end

	callService("ObjectiveService", "Clear")
	callService("VehicleService", "ClearAll")
	unloadMap()
	mode = nil
end

local function runLoop()
	while true do
		local ok, err = pcall(function()
			phaseWaiting()
			local proceed, mapId, modeId = phaseIntermission()
			if not proceed then
				return
			end
			if not phaseLoading(mapId, modeId) then
				callService("SpawnService", "SetSpawningEnabled", false)
				task.wait(3)
				return
			end
			local winner = phaseInRound()
			phasePostRound(winner)
		end)
		if not ok then
			warn(`[RoundService] round loop error: {err}`)
			-- Recover: make sure nothing is left running, then start over.
			pcall(callService, "SpawnService", "SetSpawningEnabled", false)
			pcall(callService, "SpawnService", "KillAndDespawnAll")
			pcall(callService, "ObjectiveService", "Clear")
			pcall(callService, "VehicleService", "ClearAll")
			pcall(unloadMap)
			mode = nil
			task.wait(3)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------------------------------------------

local function onPlayerDied(victim: any)
	if GameState.get("Phase") ~= "InRound" or not usesTickets() then
		return
	end
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") then
		return
	end
	local side = victim:GetAttribute("Side")
	if side == "Allies" or side == "Axis" then
		RoundService.AdjustTickets(side, -1)
	end
end

local function onPlayerKilled(victim: any, killer: any)
	if GameState.get("Phase") ~= "InRound" then
		return
	end
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") then
		return
	end
	if typeof(killer) ~= "Instance" or not killer:IsA("Player") or killer == victim then
		return
	end
	local ks, vs = killer:GetAttribute("Side"), victim:GetAttribute("Side")
	if (ks == "Allies" or ks == "Axis") and ks ~= vs then
		teamScore[ks] += 1
		writeScores()
	end
end

local function onObjectiveCaptured(_id: any, side: any)
	if GameState.get("Phase") ~= "InRound" or not mode or mode.id ~= "Frontline" then
		return
	end
	if (side == "Allies" or side == "Axis") and type(mode.ticketsOnCapture) == "number" then
		RoundService.AdjustTickets(side, mode.ticketsOnCapture)
	end
end

function RoundService:Init()
	Net.event("Round_Ended")
	Net.event("Notify")
	Net.event("Score_Event")
end

function RoundService:Start()
	Bus.connect("PlayerDied", onPlayerDied)
	Bus.connect("PlayerKilled", onPlayerKilled)
	Bus.connect("ObjectiveCaptured", onObjectiveCaptured)
	task.spawn(runLoop)
end

return RoundService
