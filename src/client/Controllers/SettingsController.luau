--[[
	SettingsController: player settings with defaults, validation, persistence and application.

	Public API (docs/ARCHITECTURE.md §7):
	  SettingsController.Get(key) -> any            -- always returns a valid value (default fallback)
	  SettingsController.GetAll() -> table           -- copy of all settings
	  SettingsController.Set(key, value)             -- validates, applies, fires Bus "SettingsChanged"
	  SettingsController.Save()                      -- persists now via Settings_Save
	  SettingsController.ResetDefaults()
	  SettingsController.Schema                      -- ordered list used by the settings menu

	Persistence: loaded from Progression_Get().settings on start, saved with the `Settings_Save`
	remote (debounced after every change, immediately on Save()).

	Applied here:
	  MouseSensitivity -> UserInputService.MouseDeltaSensitivity
	  *Volume          -> SoundService SoundGroups "Master" / "Effects" / "Music" (created if missing;
	                      Effects/Music volumes are pre-multiplied by Master since they are siblings)
	Read by others: AimSensitivity (ADS multiplier), FieldOfView (CameraController),
	  GraphicsQuality 1..3, ShowFPS / CrosshairColor / Hitmarkers / MinimapRotate (UI).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)

local UI = script.Parent.Parent:WaitForChild("UI")
local Remotes = require(UI:WaitForChild("Remotes"))

local SettingsController = {}

-- Phones/tablets (touch, no keyboard) start on LOW graphics so mid-range devices hold 30+ FPS;
-- a saved setting always wins over this default.
local DEFAULT_QUALITY = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then 1 else 2

export type SettingDef = {
	key: string,
	label: string,
	category: string,
	kind: "slider" | "toggle" | "choice" | "data",
	default: any,
	min: number?,
	max: number?,
	step: number?,
	percent: boolean?,
	options: { any }?,
	optionLabels: { string }?,
}

SettingsController.Schema = {
	{
		key = "MouseSensitivity",
		label = "Mouse Sensitivity",
		category = "Controls",
		kind = "slider",
		default = 1,
		min = 0.1,
		max = 4,
		step = 0.05,
	},
	{
		key = "AimSensitivity",
		label = "Aim Sensitivity (ADS)",
		category = "Controls",
		kind = "slider",
		default = 0.75,
		min = 0.1,
		max = 2,
		step = 0.05,
	},
	{
		key = "FieldOfView",
		label = "Field of View",
		category = "Controls",
		kind = "slider",
		default = 80,
		min = 60,
		max = 100,
		step = 1,
	},
	{
		key = "MasterVolume",
		label = "Master Volume",
		category = "Audio",
		kind = "slider",
		default = 1,
		min = 0,
		max = 1,
		step = 0.05,
		percent = true,
	},
	{
		key = "EffectsVolume",
		label = "Effects Volume",
		category = "Audio",
		kind = "slider",
		default = 1,
		min = 0,
		max = 1,
		step = 0.05,
		percent = true,
	},
	{
		key = "MusicVolume",
		label = "Music Volume",
		category = "Audio",
		kind = "slider",
		default = 0.5,
		min = 0,
		max = 1,
		step = 0.05,
		percent = true,
	},
	{
		key = "GraphicsQuality",
		label = "Graphics Quality",
		category = "Video",
		kind = "choice",
		default = DEFAULT_QUALITY,
		options = { 1, 2, 3 },
		optionLabels = { "LOW", "MEDIUM", "HIGH" },
	},
	{ key = "ShowFPS", label = "Show FPS", category = "Video", kind = "toggle", default = false },
	{
		key = "CrosshairColor",
		label = "Crosshair Colour",
		category = "Interface",
		kind = "choice",
		default = "White",
		options = { "White", "Green", "Yellow", "Cyan", "Red" },
	},
	{ key = "Hitmarkers", label = "Hitmarkers", category = "Interface", kind = "toggle", default = true },
	{ key = "MinimapRotate", label = "Rotating Minimap", category = "Interface", kind = "toggle", default = true },
	-- Hidden data: last loadout per class ({[classId] = {primary, secondary, gadget1, gadget2}}).
	{ key = "Loadouts", label = "Loadouts", category = "Data", kind = "data", default = {} },
	{ key = "LastClass", label = "Last Class", category = "Data", kind = "data", default = "Rifleman" },
} :: { SettingDef }

local defsByKey: { [string]: SettingDef } = {}
for _, def in SettingsController.Schema do
	defsByKey[def.key] = def
end

local current: { [string]: any } = {}
for _, def in SettingsController.Schema do
	current[def.key] = if type(def.default) == "table" then table.clone(def.default) else def.default
end

local saveScheduled = false
local loaded = false

------------------------------------------------------------------------------------------------
-- Validation
------------------------------------------------------------------------------------------------

local function validate(def: SettingDef, value: any): (boolean, any)
	if def.kind == "slider" then
		local n = tonumber(value)
		if not n or n ~= n then
			return false, nil
		end
		n = math.clamp(n, def.min or -math.huge, def.max or math.huge)
		if def.step then
			n = math.floor(n / def.step + 0.5) * def.step
			n = math.floor(n * 1000 + 0.5) / 1000 -- strip float noise
		end
		return true, n
	elseif def.kind == "toggle" then
		if type(value) == "boolean" then
			return true, value
		end
		return false, nil
	elseif def.kind == "choice" then
		for _, opt in (def.options or {}) :: { any } do
			if opt == value then
				return true, value
			end
		end
		-- Numbers may round-trip through JSON as floats.
		local n = tonumber(value)
		if n then
			for _, opt in (def.options or {}) :: { any } do
				if opt == n then
					return true, n
				end
			end
		end
		return false, nil
	elseif def.kind == "data" then
		if type(value) == type(def.default) then
			return true, value
		end
		return false, nil
	end
	return false, nil
end

------------------------------------------------------------------------------------------------
-- Application
------------------------------------------------------------------------------------------------

local function soundGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end
	local g = Instance.new("SoundGroup")
	g.Name = name
	g.Volume = 1
	g.Parent = SoundService
	return g
end

local function apply()
	pcall(function()
		UserInputService.MouseDeltaSensitivity = current.MouseSensitivity
	end)
	local master = current.MasterVolume
	soundGroup("Master").Volume = master
	soundGroup("Effects").Volume = master * current.EffectsVolume
	soundGroup("Music").Volume = master * current.MusicVolume
end

local function changed()
	apply()
	Bus.fire("SettingsChanged", table.clone(current))
end

------------------------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------------------------

function SettingsController.Get(key: string): any
	local v = current[key]
	if v == nil then
		local def = defsByKey[key]
		return def and def.default or nil
	end
	return v
end

function SettingsController.GetAll(): { [string]: any }
	return table.clone(current)
end

function SettingsController.GetDef(key: string): SettingDef?
	return defsByKey[key]
end

--[[
	ProgressionService only accepts flat values (no nested tables), so the per-class loadout table
	is persisted as string keys: LO_<classId> = "primary|secondary|gadget1|gadget2".
]]
local LOADOUT_PREFIX = "LO_"
local LOADOUT_SLOTS = { "primary", "secondary", "gadget1", "gadget2" }

local function serialize(): { [string]: any }
	local out = {}
	for key, value in current do
		if key ~= "Loadouts" then
			out[key] = value
		end
	end
	for classId, loadout in current.Loadouts or {} do
		if type(classId) == "string" and type(loadout) == "table" then
			local parts = {}
			for i, slot in LOADOUT_SLOTS do
				parts[i] = type(loadout[slot]) == "string" and loadout[slot] or ""
			end
			local encoded = table.concat(parts, "|")
			if #encoded <= 64 and #(LOADOUT_PREFIX .. classId) <= 32 then
				out[LOADOUT_PREFIX .. classId] = encoded
			end
		end
	end
	return out
end

function SettingsController.Save()
	saveScheduled = false
	task.spawn(Remotes.fire, "Settings_Save", serialize())
end

local function scheduleSave()
	if saveScheduled then
		return
	end
	saveScheduled = true
	task.delay(4, function()
		if saveScheduled then
			SettingsController.Save()
		end
	end)
end

function SettingsController.Set(key: string, value: any)
	local def = defsByKey[key]
	if not def then
		warn(`[Settings] unknown setting '{key}'`)
		return
	end
	local ok, v = validate(def, value)
	if not ok then
		return
	end
	if def.kind ~= "data" and current[key] == v then
		return
	end
	current[key] = v
	changed()
	scheduleSave()
end

function SettingsController.ResetDefaults()
	for _, def in SettingsController.Schema do
		if def.kind ~= "data" then
			current[def.key] = def.default
		end
	end
	changed()
	scheduleSave()
end

function SettingsController.IsLoaded(): boolean
	return loaded
end

-- Merges a persisted settings table (from ProgressionData.settings), ignoring invalid entries.
function SettingsController.LoadFrom(saved: any)
	if type(saved) ~= "table" then
		return
	end
	for key, value in saved do
		local def = defsByKey[key]
		if type(key) == "string" and key:sub(1, #LOADOUT_PREFIX) == LOADOUT_PREFIX and type(value) == "string" then
			local classId = key:sub(#LOADOUT_PREFIX + 1)
			local parts = string.split(value, "|")
			local loadout = {}
			for i, slot in LOADOUT_SLOTS do
				if parts[i] and parts[i] ~= "" then
					loadout[slot] = parts[i]
				end
			end
			current.Loadouts = table.clone(current.Loadouts or {})
			current.Loadouts[classId] = loadout
		elseif def then
			local ok, v = validate(def, value)
			if ok then
				current[key] = v
			end
		end
	end
	loaded = true
	changed()
end

------------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------------

function SettingsController:Init()
	-- Create the SoundGroups before SoundController's Init (alphabetical order) so it can use them.
	apply()
end

function SettingsController:Start()
	Bus.fire("SettingsChanged", table.clone(current))
	local ok, data = Remotes.invoke("Progression_Get", 20)
	if ok and type(data) == "table" then
		SettingsController.LoadFrom(data.settings)
	else
		loaded = true
	end
end

return SettingsController
