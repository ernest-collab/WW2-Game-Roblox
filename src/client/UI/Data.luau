--[[
	Data: read-only helpers that adapt other teams' configs/state for the UI.

	  * Weapons / Vehicles configs are owned by other teams and may not exist yet; every accessor
	    degrades gracefully (lookups return nil / ids are shown verbatim).
	  * Map info is decoded from GameState.MapInfoJson (cached per JSON string).
	  * Geometry helpers convert world positions into normalized map coordinates (north = -Z).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Classes = require(Shared.Config.Classes)
local GameState = require(Shared.GameState)

local Data = {}

------------------------------------------------------------------------------------------------
-- Config loading (guarded)
------------------------------------------------------------------------------------------------

local configCache: { [string]: { [string]: any } | false } = {}

--[[
	Normalizes a config module into {[id] = def}. Accepts shapes:
	  {byId = {...}}, {list = {...}}, {[id] = def}, or an array of defs.
]]
local function normalize(mod: any): { [string]: any }
	local out = {}
	if type(mod) ~= "table" then
		return out
	end
	local source = mod.byId or mod.list or mod.all or mod.weapons or mod.vehicles or mod
	if type(source) ~= "table" then
		return out
	end
	for key, def in source do
		if type(def) == "table" and (type(def.name) == "string" or type(def.id) == "string") then
			local id = type(def.id) == "string" and def.id or (type(key) == "string" and key or nil)
			if id then
				out[id] = def
			end
		end
	end
	return out
end

local function loadConfig(name: string): { [string]: any }
	local cached = configCache[name]
	if cached then
		return cached
	end
	local module = Shared:FindFirstChild("Config") and Shared.Config:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		return {} -- not (yet) present; try again next call
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn(`[UI] failed to require Config.{name}: {result}`)
		configCache[name] = {}
		return {}
	end
	local normalized = normalize(result)
	configCache[name] = normalized
	return normalized
end

function Data.weapons(): { [string]: any }
	return loadConfig("Weapons")
end

function Data.weapon(id: string?): any
	if not id or id == "" then
		return nil
	end
	return Data.weapons()[id]
end

function Data.weaponName(id: string?): string
	local def = Data.weapon(id)
	if def and def.name then
		return def.name
	end
	return id and id ~= "" and id or "—"
end

function Data.vehicle(id: string?): any
	if not id or id == "" then
		return nil
	end
	return loadConfig("Vehicles")[id]
end

function Data.vehicleName(id: string?): string
	local def = Data.vehicle(id)
	return def and def.name or (id or "Vehicle")
end

------------------------------------------------------------------------------------------------
-- Loadout helpers
------------------------------------------------------------------------------------------------

Data.SLOTS = { "primary", "secondary", "gadget1", "gadget2" }
Data.SLOT_LABELS = { primary = "PRIMARY", secondary = "SIDEARM", gadget1 = "EQUIPMENT 1", gadget2 = "EQUIPMENT 2" }

local function factionAllowed(def: any, factionId: string?): boolean
	if not factionId or factionId == "" or type(def.factions) ~= "table" or #def.factions == 0 then
		return true
	end
	return table.find(def.factions, factionId) ~= nil
end

function Data.isUnlocked(def: any, level: number, unlocked: { [string]: any }?): boolean
	if unlocked and def.id and unlocked[def.id] then
		return true
	end
	return (def.unlockLevel or 1) <= level
end

--[[
	Weapons the class may carry in `slot` for `factionId`, sorted by unlock level then name.
	Locked items are included (the UI shows them with their unlock level).
]]
function Data.weaponsFor(classId: string, slot: string, factionId: string?): { any }
	local class = Classes.byId[classId]
	local list = {}
	if not class then
		return list
	end
	local categories = (class.slots :: any)[slot] or {}
	for _, def in Data.weapons() do
		if table.find(categories, def.category) and factionAllowed(def, factionId) then
			table.insert(list, def)
		end
	end
	table.sort(list, function(a, b)
		local la, lb = a.unlockLevel or 1, b.unlockLevel or 1
		if la ~= lb then
			return la < lb
		end
		return (a.name or a.id) < (b.name or b.id)
	end)
	return list
end

--[[
	Normalized 0..1 stats for the loadout stat bars.
	Returns nil for weapons without firearm stats (gadgets / throwables use `blast` instead).
]]
function Data.stats(def: any): { { label: string, value: number } }?
	if not def then
		return nil
	end
	if type(def.damage) == "number" and type(def.rpm) == "number" then
		local pellets = def.pellets or 1
		local spread = def.adsSpread or def.hipSpread or 2
		return {
			{ label = "DAMAGE", value = math.clamp(def.damage * pellets / 120, 0.05, 1) },
			{ label = "FIRE RATE", value = math.clamp(def.rpm / 900, 0.05, 1) },
			{ label = "ACCURACY", value = math.clamp(1 - spread / 4, 0.05, 1) },
			{ label = "RANGE", value = math.clamp((def.range or 150) / 600, 0.05, 1) },
			{ label = "MOBILITY", value = math.clamp(((def.walkSpeedMult or 1) - 0.7) / 0.35, 0.05, 1) },
		}
	elseif type(def.blastDamage) == "number" or type(def.blastRadius) == "number" then
		return {
			{ label = "DAMAGE", value = math.clamp((def.blastDamage or 50) / 150, 0.05, 1) },
			{ label = "RADIUS", value = math.clamp((def.blastRadius or 10) / 30, 0.05, 1) },
			{ label = "VS ARMOR", value = math.clamp((def.vehicleDamage or 0) / 600, 0.05, 1) },
		}
	end
	return nil
end

------------------------------------------------------------------------------------------------
-- Map info
------------------------------------------------------------------------------------------------

export type MapInfo = {
	id: string,
	bounds: { cx: number, cy: number, cz: number, sx: number, sy: number, sz: number },
	objectives: { { id: string, name: string, x: number, y: number, z: number, radius: number, order: number } },
	hq: { [string]: { x: number, z: number } },
	minimap: { { kind: string, cx: number, cz: number, sx: number, sz: number, rot: number? } },
	outOfBounds: number?,
}

local lastJson = nil
local lastInfo: MapInfo? = nil

function Data.mapInfo(): MapInfo?
	local json = GameState.get("MapInfoJson")
	if type(json) ~= "string" or json == "" then
		return nil
	end
	if json == lastJson then
		return lastInfo
	end
	lastJson = json
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, json)
	if ok and type(decoded) == "table" and type(decoded.bounds) == "table" then
		local b = decoded.bounds
		b.cx, b.cy, b.cz = tonumber(b.cx) or 0, tonumber(b.cy) or 0, tonumber(b.cz) or 0
		b.sx, b.sy, b.sz = math.max(tonumber(b.sx) or 1000, 1), tonumber(b.sy) or 200, math.max(tonumber(b.sz) or 1000, 1)
		decoded.objectives = type(decoded.objectives) == "table" and decoded.objectives or {}
		decoded.minimap = type(decoded.minimap) == "table" and decoded.minimap or {}
		decoded.hq = type(decoded.hq) == "table" and decoded.hq or {}
		lastInfo = decoded
	else
		lastInfo = nil
	end
	return lastInfo
end

-- World position -> normalized map coordinates (0..1, origin top-left = north-west).
function Data.toUV(info: MapInfo, x: number, z: number): (number, number)
	local b = info.bounds
	return (x - (b.cx - b.sx / 2)) / b.sx, (z - (b.cz - b.sz / 2)) / b.sz
end

-- Compass heading (degrees clockwise from north/-Z) of a look vector.
function Data.heading(look: Vector3): number
	return math.deg(math.atan2(look.X, -look.Z)) % 360
end

function Data.cameraHeading(): number
	local cam = Workspace.CurrentCamera
	if not cam then
		return 0
	end
	return Data.heading(cam.CFrame.LookVector)
end

------------------------------------------------------------------------------------------------
-- Players
------------------------------------------------------------------------------------------------

function Data.rootPart(player: Player): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

function Data.humanoid(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid") or nil
end

function Data.localSide(): string
	local side = Players.LocalPlayer:GetAttribute("Side")
	return type(side) == "string" and side or ""
end

function Data.factionForSide(side: string): string?
	if side == "Allies" or side == "Axis" then
		local f = GameState.get(side .. "Faction")
		return type(f) == "string" and f or nil
	end
	return nil
end

function Data.isSpotted(player: Player): boolean
	local t = player:GetAttribute("Spotted")
	return type(t) == "number" and t > Workspace:GetServerTimeNow()
end

return Data
