--[[
	Progression: XP curve, score/XP tables and loadout/unlock helpers shared by server and client.
	Owned by the Gameplay team.

	XP curve
	  Levels 1..MAX_LEVEL. `xpToNext(level)` is the XP needed to go from `level` to `level + 1`.
	  Players earn XP equal to the score points they earn, plus end-of-round XP (`ROUND_XP`).

	Unlocks
	  Derived from `unlockLevel` in Config/Weapons and Config/Vehicles (Combat / Vehicle teams) and
	  Config/Classes. Those modules may not exist yet; every helper degrades gracefully.

	Loadout rules (see Config/Classes.luau): a weapon is allowed in a slot when its `category` is in
	the class slot's category list, its `factions` contain the player's faction (missing/empty
	`factions` = every faction) and its `unlockLevel` <= the player's level.
]]

local Classes = require(script.Parent.Classes)

local Progression = {}

Progression.MAX_LEVEL = 50
Progression.DATASTORE_NAME = "WW2Frontlines_v1"

-- Score points per action (ScoreService). XP granted = points.
Progression.SCORE = {
	Kill = 100,
	Headshot = 25,
	Assist = 50,
	Capture = 250, -- every capturer gets the full amount (no split)
	Neutralize = 100,
	Defend = 75,
	HealPer20 = 10, -- 10 points per 20 hp healed on a teammate
	Revive = 100,
	Resupply = 25,
	RepairPer100 = 10, -- 10 points per 100 vehicle hp repaired
	SpotAssist = 30,
	VehicleDestroyed = 300,
	SquadSpawn = 10, -- squad leader / squadmate when a teammate deploys on them
}

-- End-of-round XP (ProgressionService, awarded by RoundService).
Progression.ROUND_XP = {
	Win = 500,
	Loss = 200,
	Draw = 300,
}

-- Settings_Save validation limits.
Progression.SETTINGS_LIMITS = {
	maxKeys = 48,
	maxKeyLength = 32,
	maxStringLength = 64,
	maxArrayLength = 4,
	maxEncodedBytes = 4096,
}

-- XP needed to advance from `level` to `level + 1` (0 at max level).
function Progression.xpToNext(level: number): number
	if level >= Progression.MAX_LEVEL then
		return 0
	end
	local l = math.max(level, 1) - 1
	return math.floor(1500 + 320 * l + 8 * l * l)
end

-- Total XP required to reach `level` from zero.
function Progression.totalXPForLevel(level: number): number
	local total = 0
	for l = 1, math.min(level, Progression.MAX_LEVEL) - 1 do
		total += Progression.xpToNext(l)
	end
	return total
end

-- Returns level, xp into the current level, xp needed for the next level.
function Progression.levelFromXP(totalXP: number): (number, number, number)
	local level = 1
	local remaining = math.max(0, math.floor(totalXP))
	while level < Progression.MAX_LEVEL do
		local need = Progression.xpToNext(level)
		if remaining < need then
			return level, remaining, need
		end
		remaining -= need
		level += 1
	end
	return Progression.MAX_LEVEL, remaining, 0
end

---------------------------------------------------------------------------------------------------
-- Optional config access (Weapons / Vehicles are owned by other teams and may not exist yet)
---------------------------------------------------------------------------------------------------

local cache: { [string]: { [string]: any } } = {}
local rawModules: { [string]: any } = {}

local function normalize(mod: any, requiredField: string): { [string]: any }
	local out = {}
	if type(mod) ~= "table" then
		return out
	end
	local src = mod.byId or mod
	if type(src) ~= "table" then
		return out
	end
	for key, def in src do
		if type(def) == "table" and def[requiredField] ~= nil then
			local id = if type(def.id) == "string" then def.id else key
			if type(id) == "string" then
				out[id] = def
			end
		end
	end
	return out
end

local function loadConfig(name: string, requiredField: string): { [string]: any }
	local cached = cache[name]
	if cached then
		return cached
	end
	local configFolder = script.Parent
	local moduleScript = configFolder:FindFirstChild(name)
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		return {} -- not cached: the module may appear later (e.g. during development)
	end
	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn(`[Progression] failed to require Config.{name}: {result}`)
		cache[name] = {}
		return cache[name]
	end
	local normalized = normalize(result, requiredField)
	cache[name] = normalized
	rawModules[name] = result
	return normalized
end

-- {[weaponId]: WeaponDef} (empty when Config/Weapons is missing)
function Progression.getWeapons(): { [string]: any }
	return loadConfig("Weapons", "category")
end

-- {[vehicleId]: VehicleDef} (empty when Config/Vehicles is missing)
function Progression.getVehicles(): { [string]: any }
	return loadConfig("Vehicles", "class")
end

function Progression.hasWeaponsConfig(): boolean
	return next(Progression.getWeapons()) ~= nil
end

local function factionAllowed(def: any, factionId: string?): boolean
	local factions = def.factions
	if type(factions) ~= "table" or #factions == 0 or factionId == nil or factionId == "" then
		return true
	end
	return table.find(factions, factionId) ~= nil
end

local function unlockLevelOf(def: any): number
	return if type(def.unlockLevel) == "number" then def.unlockLevel else 1
end

export type Loadout = { primary: string, secondary: string, gadget1: string, gadget2: string }

Progression.SLOTS = { "primary", "secondary", "gadget1", "gadget2" }

-- Weapons allowed for a class slot, sorted by unlock level then name.
function Progression.allowedWeapons(classId: string, slot: string, factionId: string?, level: number): { any }
	local class = Classes.get(classId)
	local list = {}
	if not class then
		return list
	end
	local categories = (class.slots :: any)[slot]
	if type(categories) ~= "table" then
		return list
	end
	local weapons = Progression.getWeapons()
	-- Prefer the Combat team's own helper so ordering matches their UI / defaults exactly.
	local raw = rawModules.Weapons
	if type(raw) == "table" and type(raw.available) == "function" then
		local ok, result = pcall(raw.available, classId, slot, factionId, level)
		if ok and type(result) == "table" then
			return result
		end
	end
	for _, def in weapons do
		if table.find(categories, def.category) and factionAllowed(def, factionId) and unlockLevelOf(def) <= level then
			table.insert(list, def)
		end
	end
	table.sort(list, function(a, b)
		local la, lb = unlockLevelOf(a), unlockLevelOf(b)
		if la ~= lb then
			return la < lb
		end
		return tostring(a.name or a.id) < tostring(b.name or b.id)
	end)
	return list
end

-- Default loadout for a class: the lowest-level allowed weapon in each slot ("" when none).
function Progression.defaultLoadout(classId: string, factionId: string?, level: number): Loadout
	local loadout = { primary = "", secondary = "", gadget1 = "", gadget2 = "" }
	for _, slot in Progression.SLOTS do
		local allowed = Progression.allowedWeapons(classId, slot, factionId, level)
		if allowed[1] then
			(loadout :: any)[slot] = allowed[1].id
		end
	end
	return loadout
end

-- Sanitizes a client-supplied loadout: every invalid/locked slot is replaced by the default.
-- Returns the sanitized loadout and whether the input was fully valid.
function Progression.validateLoadout(classId: string, factionId: string?, level: number, input: any): (Loadout, boolean)
	local result = Progression.defaultLoadout(classId, factionId, level)
	local valid = true
	if not Progression.hasWeaponsConfig() then
		return result, true -- nothing to validate against: class defaults
	end
	for _, slot in Progression.SLOTS do
		local wanted = if type(input) == "table" then input[slot] else nil
		if type(wanted) == "string" and wanted ~= "" then
			local ok = false
			for _, def in Progression.allowedWeapons(classId, slot, factionId, level) do
				if def.id == wanted then
					ok = true
					break
				end
			end
			if ok then
				(result :: any)[slot] = wanted
			else
				valid = false
			end
		end
	end
	return result, valid
end

-- Does this class + loadout carry a gadget of `category` ("Medkit" | "AmmoBox" | "Repair" | "Binoculars")?
function Progression.hasGadgetCategory(classId: string, loadout: any, category: string): boolean
	local weapons = Progression.getWeapons()
	if next(weapons) ~= nil and type(loadout) == "table" then
		local knownAny = false
		for _, slot in { "gadget1", "gadget2" } do
			local def = weapons[loadout[slot] or ""]
			if def then
				knownAny = true
				if def.category == category then
					return true
				end
			end
		end
		if knownAny then
			return false
		end
	end
	-- Fallback: the class can carry that gadget category in either gadget slot.
	local class = Classes.get(classId)
	if not class then
		return false
	end
	return table.find(class.slots.gadget1, category) ~= nil or table.find(class.slots.gadget2, category) ~= nil
end

-- Set of weapon ids unlocked at `level` (all factions).
function Progression.unlockedWeapons(level: number): { [string]: boolean }
	local set = {}
	for id, def in Progression.getWeapons() do
		if unlockLevelOf(def) <= level then
			set[id] = true
		end
	end
	return set
end

-- What becomes available exactly at `level` (for level-up toasts / UI unlock track).
function Progression.unlocksAtLevel(level: number): { weapons: { any }, vehicles: { any }, classes: { any } }
	local result = { weapons = {}, vehicles = {}, classes = {} }
	for _, def in Progression.getWeapons() do
		if unlockLevelOf(def) == level then
			table.insert(result.weapons, def)
		end
	end
	for _, def in Progression.getVehicles() do
		if unlockLevelOf(def) == level then
			table.insert(result.vehicles, def)
		end
	end
	for _, id in Classes.order do
		local def = Classes.get(id)
		if def and def.unlockLevel == level then
			table.insert(result.classes, def)
		end
	end
	return result
end

-- Full unlock track {level -> unlocks} for levels 2..MAX_LEVEL (only levels with unlocks).
function Progression.unlockTrack(): { [number]: { weapons: { any }, vehicles: { any }, classes: { any } } }
	local track = {}
	for level = 2, Progression.MAX_LEVEL do
		local u = Progression.unlocksAtLevel(level)
		if #u.weapons + #u.vehicles + #u.classes > 0 then
			track[level] = u
		end
	end
	return track
end

return Progression
