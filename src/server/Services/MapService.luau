--[[
	MapService (Map team)

	Loads/unloads procedural maps and enforces the playable bounds.

	API (ARCHITECTURE.md §7):
	  MapService.LoadMap(mapId) -> MapInfo?   builds the map into workspace.Map (yields while building),
	                                           validates/normalises the MapInfo, writes
	                                           GameState.MapInfoJson / LightingPreset / Weather and fires
	                                           Bus "MapLoaded"(mapInfo). Returns nil if the build failed.
	  MapService.UnloadMap()                   fires Bus "MapUnloading", destroys workspace.Map, clears Terrain
	  MapService.GetMapInfo() -> MapInfo?
	  MapService.GetAvailableMaps() -> {mapId} registry ids (Config/Maps order) whose builder module exists

	Builders live in ServerScriptService.Server.Maps.<builder> and implement
	  Builder.Build(parent: Folder, mapDef) -> MapInfo

	Out of bounds: enforced by Gameplay's SpawnService (player attribute `OutOfBounds`). MapService
	only runs its own fallback check (Notify countdown, death after MapInfo.outOfBounds seconds)
	when SpawnService is not present.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)
local GameState = require(Shared.GameState)
local Maps = require(Shared.Config.Maps)

local MapService = {}

local SIDES = { "Allies", "Axis" }
local DEFAULT_OOB = 10
local OOB_TICK = 0.5

local current: any = nil
local loading = false
local oobTimers: { [Player]: number } = {}
local oobLastNotify: { [Player]: number } = {}

local function mapsFolder(): Instance?
	return script.Parent.Parent:FindFirstChild("Maps")
end

local function builderModule(def: any): ModuleScript?
	local folder = mapsFolder()
	local m = folder and folder:FindFirstChild(def.builder)
	if m and m:IsA("ModuleScript") then
		return m
	end
	return nil
end

---------------------------------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------------------------------

local function isCFrame(v: any): boolean
	return typeof(v) == "CFrame"
end

-- Normalises a builder's MapInfo in place. Returns (ok, error).
local function normalise(info: any, def: any): (boolean, string?)
	if type(info) ~= "table" then
		return false, "builder did not return a table"
	end
	info.id = info.id or def.id

	-- bounds
	local b = info.bounds
	if type(b) ~= "table" or typeof(b.center) ~= "Vector3" or typeof(b.size) ~= "Vector3" then
		info.bounds = { center = Vector3.new(0, 0, 0), size = Vector3.new(def.size.X, 600, def.size.Y) }
	end

	-- HQ spawns: at least 2 per side
	if type(info.hq) ~= "table" then
		return false, "missing hq"
	end
	for _, side in SIDES do
		local list = info.hq[side]
		if type(list) ~= "table" then
			return false, `missing hq.{side}`
		end
		local clean = {}
		for _, cf in list do
			if isCFrame(cf) then
				table.insert(clean, cf)
			end
		end
		if #clean == 0 then
			return false, `no hq spawns for {side}`
		end
		local i = 1
		while #clean < 2 do
			table.insert(clean, clean[i] * CFrame.new(6, 0, 0))
			i += 1
		end
		info.hq[side] = clean
	end

	-- objectives
	local objectives = {}
	local seen = {}
	for i, obj in (if type(info.objectives) == "table" then info.objectives else {}) do
		if type(obj) ~= "table" or type(obj.id) ~= "string" or seen[obj.id] or typeof(obj.position) ~= "Vector3" then
			warn(`[MapService] {def.id}: dropping invalid objective #{i}`)
			continue
		end
		seen[obj.id] = true
		obj.name = if type(obj.name) == "string" then obj.name else obj.id
		obj.radius = if type(obj.radius) == "number" and obj.radius > 0 then obj.radius else 25
		obj.order = if type(obj.order) == "number" then obj.order else i
		if obj.initialOwner ~= "Allies" and obj.initialOwner ~= "Axis" then
			obj.initialOwner = "Neutral"
		end
		local spawns = {}
		for _, cf in (if type(obj.spawns) == "table" then obj.spawns else {}) do
			if isCFrame(cf) then
				table.insert(spawns, cf)
			end
		end
		if #spawns == 0 then
			table.insert(spawns, CFrame.new(obj.position + Vector3.new(obj.radius + 6, 5, 0)))
		end
		obj.spawns = spawns
		table.insert(objectives, obj)
	end
	table.sort(objectives, function(a, c)
		return a.order < c.order
	end)
	info.objectives = objectives

	-- vehicle spawns
	local vs = if type(info.vehicleSpawns) == "table" then info.vehicleSpawns else {}
	for _, side in SIDES do
		local clean = {}
		for _, entry in (if type(vs[side]) == "table" then vs[side] else {}) do
			if type(entry) == "table" and isCFrame(entry.cframe) and type(entry.class) == "string" then
				table.insert(clean, entry)
			end
		end
		vs[side] = clean
	end
	info.vehicleSpawns = vs
	info.minimap = if type(info.minimap) == "table" then info.minimap else {}
	info.outOfBounds = if type(info.outOfBounds) == "number" then info.outOfBounds else DEFAULT_OOB
	return true, nil
end

local function round(n: number): number
	return math.floor(n * 10 + 0.5) / 10
end

-- Public subset for GameState.MapInfoJson (ARCHITECTURE.md §8).
local function encodePublic(info: any): string
	local b = info.bounds
	local pub = {
		id = info.id,
		bounds = {
			cx = round(b.center.X),
			cy = round(b.center.Y),
			cz = round(b.center.Z),
			sx = round(b.size.X),
			sy = round(b.size.Y),
			sz = round(b.size.Z),
		},
		objectives = {},
		hq = {},
		minimap = info.minimap,
	}
	for _, obj in info.objectives do
		table.insert(pub.objectives, {
			id = obj.id,
			name = obj.name,
			x = round(obj.position.X),
			y = round(obj.position.Y),
			z = round(obj.position.Z),
			radius = obj.radius,
			order = obj.order,
		})
	end
	for _, side in SIDES do
		local sx, sz, n = 0, 0, 0
		for _, cf in info.hq[side] do
			sx += cf.Position.X
			sz += cf.Position.Z
			n += 1
		end
		pub.hq[side] = { x = round(sx / math.max(n, 1)), z = round(sz / math.max(n, 1)) }
	end
	local ok, json = pcall(HttpService.JSONEncode, HttpService, pub)
	if not ok then
		warn(`[MapService] failed to encode MapInfoJson: {json}`)
		return ""
	end
	return json
end

---------------------------------------------------------------------------------------------------
-- Load / unload
---------------------------------------------------------------------------------------------------

local function clearWorld()
	local old = Workspace:FindFirstChild("Map")
	if old then
		old:Destroy()
	end
	Workspace.Terrain:Clear()
end

function MapService.UnloadMap()
	if current or Workspace:FindFirstChild("Map") then
		Bus.fire("MapUnloading")
	end
	current = nil
	clearWorld()
	for p in oobTimers do
		oobTimers[p] = nil
	end
	GameState.set("MapInfoJson", "")
end

function MapService.LoadMap(mapId: string): any
	local def = Maps.byId[mapId]
	if not def then
		warn(`[MapService] unknown map '{tostring(mapId)}'`)
		return nil
	end
	local module = builderModule(def)
	if not module then
		warn(`[MapService] builder '{def.builder}' for map '{mapId}' does not exist`)
		return nil
	end
	while loading do
		task.wait(0.1)
	end
	loading = true
	MapService.UnloadMap()

	local folder = Instance.new("Folder")
	folder.Name = "Map"
	folder.Parent = Workspace

	local started = os.clock()
	local ok, result = pcall(function()
		local builder = require(module) :: any
		return builder.Build(folder, def)
	end)
	local valid, err = false, nil
	if ok then
		valid, err = normalise(result, def)
	else
		err = tostring(result)
	end
	if not valid then
		warn(`[MapService] failed to build '{mapId}': {err}`)
		clearWorld()
		loading = false
		return nil
	end

	current = result
	GameState.set("MapInfoJson", encodePublic(result))
	GameState.set("LightingPreset", def.lighting)
	local weather = GameState.get("Weather")
	if not table.find(def.weather, weather) then
		weather = def.weather[math.random(1, #def.weather)] or "Clear"
	end
	GameState.set("Weather", weather)
	print(`[MapService] loaded '{mapId}' in {string.format("%.1f", os.clock() - started)}s`)
	loading = false
	Bus.fire("MapLoaded", result)
	return result
end

function MapService.GetMapInfo(): any
	return current
end

function MapService.GetAvailableMaps(): { string }
	local list = {}
	for _, id in Maps.order do
		local def = Maps.byId[id]
		if def and builderModule(def) then
			table.insert(list, id)
		end
	end
	return list
end

-- True while a map is being built (other services may want to wait).
function MapService.IsLoading(): boolean
	return loading
end

---------------------------------------------------------------------------------------------------
-- Out-of-bounds enforcement
---------------------------------------------------------------------------------------------------

local function outside(info: any, pos: Vector3): boolean
	local c, s = info.bounds.center, info.bounds.size
	return math.abs(pos.X - c.X) > s.X / 2 or math.abs(pos.Z - c.Z) > s.Z / 2 or pos.Y < c.Y - s.Y / 2
end

local function notify(player: Player, text: string, kind: string, duration: number)
	Net.event("Notify"):FireClient(player, { text = text, kind = kind, duration = duration })
end

local function tickBounds()
	local info = current
	if not info or loading then
		return
	end
	-- Gameplay's SpawnService owns out-of-bounds (player attribute `OutOfBounds`); this is only a
	-- fallback so players are never killed twice.
	if script.Parent:FindFirstChild("SpawnService") then
		return
	end
	local limit = info.outOfBounds or DEFAULT_OOB
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (root and hum and hum.Health > 0) then
			oobTimers[player] = nil
			continue
		end
		if outside(info, root.Position) then
			local t = (oobTimers[player] or 0) + OOB_TICK
			oobTimers[player] = t
			local remaining = math.max(0, math.ceil(limit - t))
			if t >= limit then
				oobTimers[player] = nil
				hum.Health = 0
			elseif t <= OOB_TICK or now - (oobLastNotify[player] or 0) >= 2.5 then
				oobLastNotify[player] = now
				notify(player, `Return to the battlefield! {remaining}s`, "warning", 2.5)
			end
		elseif oobTimers[player] then
			oobTimers[player] = nil
			notify(player, "Back in the combat area", "info", 1.5)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

function MapService:Init()
	Net.event("Notify")
end

function MapService:Start()
	Players.PlayerRemoving:Connect(function(p)
		oobTimers[p] = nil
		oobLastNotify[p] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(OOB_TICK)
			local ok, e = pcall(tickBounds)
			if not ok then
				warn(`[MapService] bounds check error: {e}`)
			end
		end
	end)
	-- Dev convenience: with no RoundService to drive map loading, load the first available map.
	if not script.Parent:FindFirstChild("RoundService") then
		task.delay(2, function()
			if not current and not loading then
				local first = MapService.GetAvailableMaps()[1]
				if first then
					MapService.LoadMap(first)
				end
			end
		end)
	end
end

return MapService
