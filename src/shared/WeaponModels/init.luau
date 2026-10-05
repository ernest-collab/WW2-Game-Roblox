--[[
	WeaponModels (Animation/Models team) — procedural weapon models built from Parts.

		local model = WeaponModels.Build("Kar98k") -- a fresh clone, unparented

	Contract (docs/ARCHITECTURE.md §7):
	  * PrimaryPart "Handle"; Handle.CFrame.LookVector is the barrel direction.
	  * Attachments on Handle: "Muzzle", "Grip" (right hand), "Support" (left hand), "Sight" (eye
	    position for ADS, looking down the barrel), "Eject" (shell ejection).
	  * All parts Anchored=false, CanCollide/CanQuery/CanTouch=false, Massless=true, welded to Handle
	    (with `Weld`s, so the viewmodel can animate the named sub-parts Mag/Bolt/Slide/Pump/Lid).

	Model attributes (presentation metadata): WeaponId, Archetype, Variant, Hold, EyeRelief, MagOut,
	Action, PartCount — see Builder.meta.

	Input: Config.Weapons[weaponId].visual = { archetype, magazine, length, woodColor, metalColor,
	scope, bayonet, variant? }. `length` is the overall length in studs (values < 2.5 that are
	below half the archetype default are treated as a multiplier). `variant` is optional; when it is
	absent the silhouette variant (e.g. "kar98", "mp40", "bren") is inferred from the weapon id/name.
	Unknown weapons fall back to a guessed archetype or a generic bolt-action rifle.

	Templates are built once per weapon id and cached; Build() returns :Clone()s.
]]

local Builder = require(script.Builder)
local Rifles = require(script.Rifles)
local Automatics = require(script.Automatics)
local Handguns = require(script.Handguns)
local Launchers = require(script.Launchers)
local Throwables = require(script.Throwables)
local Gadgets = require(script.Gadgets)

local WeaponModels = {}

-- Archetype -> builder function
local BUILDERS: { [string]: (Builder.Builder) -> () } = {
	BoltRifle = function(b)
		Rifles.BoltRifle(b)
	end,
	SemiRifle = function(b)
		Rifles.SemiRifle(b)
	end,
	SniperRifle = Rifles.SniperRifle,
	Shotgun = Rifles.Shotgun,
	AssaultRifle = Rifles.AssaultRifle,
	SMG = Automatics.SMG,
	LMG = Automatics.LMG,
	HMG = Automatics.HMG,
	Pistol = Handguns.Pistol,
	Revolver = Handguns.Revolver,
	Bazooka = Launchers.Bazooka,
	Panzerfaust = Launchers.Panzerfaust,
	PIAT = Launchers.PIAT,
	StickGrenade = Throwables.StickGrenade,
	FragGrenade = Throwables.FragGrenade,
	SmokeGrenade = Throwables.SmokeGrenade,
	Satchel = Throwables.Satchel,
	Knife = Gadgets.Knife,
	Wrench = Gadgets.Wrench,
	Medkit = Gadgets.Medkit,
	AmmoBox = Gadgets.AmmoBox,
	Binoculars = Gadgets.Binoculars,
}

-- Default overall lengths (studs) and magazine layouts per archetype.
local DEFAULTS: { [string]: { length: number, magazine: string } } = {
	BoltRifle = { length = 3.7, magazine = "internal" },
	SemiRifle = { length = 3.5, magazine = "internal" },
	SniperRifle = { length = 3.7, magazine = "internal" },
	Shotgun = { length = 3.4, magazine = "internal" },
	AssaultRifle = { length = 3.1, magazine = "box" },
	SMG = { length = 2.6, magazine = "stick" },
	LMG = { length = 3.9, magazine = "box" },
	HMG = { length = 4.0, magazine = "box" },
	Pistol = { length = 0.9, magazine = "box" },
	Revolver = { length = 1.0, magazine = "internal" },
	Bazooka = { length = 4.6, magazine = "none" },
	Panzerfaust = { length = 3.2, magazine = "none" },
	PIAT = { length = 3.0, magazine = "none" },
	StickGrenade = { length = 1.4, magazine = "none" },
	FragGrenade = { length = 0.4, magazine = "none" },
	SmokeGrenade = { length = 0.6, magazine = "none" },
	Satchel = { length = 0.8, magazine = "none" },
	Knife = { length = 1.2, magazine = "none" },
	Wrench = { length = 1.4, magazine = "none" },
	Medkit = { length = 0.7, magazine = "none" },
	AmmoBox = { length = 0.9, magazine = "none" },
	Binoculars = { length = 0.6, magazine = "none" },
}

-- Ordered (pattern, archetype, variant) hints matched against the lowercase id/name.
-- Used for silhouette variants, and to guess an archetype when the config is missing.
local HINTS: { { string } } = {
	{ "panzerschreck", "Bazooka", "panzerschreck" },
	{ "rpzb", "Bazooka", "panzerschreck" },
	{ "bazooka", "Bazooka", "generic" },
	{ "panzerfaust", "Panzerfaust", "generic" },
	{ "piat", "PIAT", "generic" },
	{ "mg42", "HMG", "mg42" },
	{ "mg34", "HMG", "mg34" },
	{ "m1919", "HMG", "m1919" },
	{ "browning30", "HMG", "m1919" },
	{ "bren", "LMG", "bren" },
	{ "dp28", "LMG", "dp" },
	{ "degtyarev", "LMG", "dp" },
	{ "type96", "LMG", "type96" },
	{ "type99lmg", "LMG", "type96" },
	{ "breda", "LMG", "type96" },
	{ "m1918", "LMG", "bar" },
	{ "thompson", "SMG", "thompson" },
	{ "tommy", "SMG", "thompson" },
	{ "mp40", "SMG", "mp40" },
	{ "mp38", "SMG", "mp40" },
	{ "pps43", "SMG", "mp40" },
	{ "sten", "SMG", "sten" },
	{ "ppsh", "SMG", "ppsh" },
	{ "greasegun", "SMG", "m3" },
	{ "grease", "SMG", "m3" },
	{ "stg44", "AssaultRifle", "stg44" },
	{ "stg", "AssaultRifle", "stg44" },
	{ "mp44", "AssaultRifle", "stg44" },
	{ "fg42", "AssaultRifle", "fg42" },
	{ "garand", "SemiRifle", "garand" },
	{ "svt", "SemiRifle", "svt" },
	{ "g43", "SemiRifle", "g43" },
	{ "gewehr43", "SemiRifle", "g43" },
	{ "carbine", "SemiRifle", "carbine" },
	{ "kar98", "BoltRifle", "kar98" },
	{ "k98", "BoltRifle", "kar98" },
	{ "98k", "BoltRifle", "kar98" },
	{ "mosin", "BoltRifle", "mosin" },
	{ "enfield", "BoltRifle", "enfield" },
	{ "smle", "BoltRifle", "enfield" },
	{ "springfield", "BoltRifle", "springfield" },
	{ "m1903", "BoltRifle", "springfield" },
	{ "arisaka", "BoltRifle", "arisaka" },
	{ "carcano", "BoltRifle", "carcano" },
	{ "trench", "Shotgun", "trench" },
	{ "m1897", "Shotgun", "trench" },
	{ "shotgun", "Shotgun", "generic" },
	{ "luger", "Pistol", "luger" },
	{ "p08", "Pistol", "luger" },
	{ "nambu", "Pistol", "luger" },
	{ "webley", "Revolver", "generic" },
	{ "nagant", "Revolver", "generic" },
	{ "revolver", "Revolver", "generic" },
	{ "m1911", "Pistol", "auto" },
	{ "colt", "Pistol", "auto" },
	{ "walther", "Pistol", "auto" },
	{ "p38", "Pistol", "auto" },
	{ "tt33", "Pistol", "auto" },
	{ "pistol", "Pistol", "auto" },
	{ "type97", "FragGrenade", "type97" },
	{ "stielhandgranate", "StickGrenade", "generic" },
	{ "m24", "StickGrenade", "generic" },
	{ "nebel", "SmokeGrenade", "stick" },
	{ "smoke", "SmokeGrenade", "generic" },
	{ "satchel", "Satchel", "generic" },
	{ "grenade", "FragGrenade", "generic" },
	{ "mills", "FragGrenade", "generic" },
	{ "knife", "Knife", "generic" },
	{ "bayonet", "Knife", "generic" },
	{ "wrench", "Wrench", "generic" },
	{ "repair", "Wrench", "generic" },
	{ "medkit", "Medkit", "generic" },
	{ "medic", "Medkit", "generic" },
	{ "ammo", "AmmoBox", "generic" },
	{ "binocular", "Binoculars", "generic" },
	{ "sniper", "SniperRifle", "generic" },
	{ "bar", "LMG", "bar" }, -- last: short pattern
}

-- Archetype per Weapons `category`, for configs that lack `visual.archetype`.
local CATEGORY_ARCHETYPE = {
	AssaultRifle = "AssaultRifle",
	SMG = "SMG",
	BoltAction = "BoltRifle",
	SemiAuto = "SemiRifle",
	MachineGun = "LMG",
	Pistol = "Pistol",
	Shotgun = "Shotgun",
	Sniper = "SniperRifle",
	Grenade = "FragGrenade",
	Smoke = "SmokeGrenade",
	AntiTank = "Bazooka",
	Explosive = "Satchel",
	Medkit = "Medkit",
	AmmoBox = "AmmoBox",
	Repair = "Wrench",
	Binoculars = "Binoculars",
	Melee = "Knife",
}

local DEFAULT_WOOD = Color3.fromRGB(112, 72, 42)
local DEFAULT_METAL = Color3.fromRGB(58, 58, 62)
local DEFAULT_ACCENT: { [string]: Color3 } = {
	StickGrenade = Color3.fromRGB(74, 80, 60),
	FragGrenade = Color3.fromRGB(78, 86, 56),
	SmokeGrenade = Color3.fromRGB(110, 116, 100),
	Satchel = Color3.fromRGB(108, 100, 70),
	Medkit = Color3.fromRGB(104, 100, 70),
	Binoculars = Color3.fromRGB(60, 60, 58),
}
local DEFAULT_BODY: { [string]: Color3 } = {
	Bazooka = Color3.fromRGB(78, 86, 60),
	Panzerfaust = Color3.fromRGB(96, 98, 64),
	PIAT = Color3.fromRGB(84, 88, 62),
	AmmoBox = Color3.fromRGB(96, 104, 66),
}

--------------------------------------------------------------------------------------------------
-- Config access
--------------------------------------------------------------------------------------------------

local weaponsModule: any = nil
local weaponsResolved = false

local function weaponsConfig(): any
	if weaponsResolved then
		return weaponsModule
	end
	local configFolder = script.Parent:FindFirstChild("Config")
	local mod = configFolder and configFolder:FindFirstChild("Weapons")
	if mod and mod:IsA("ModuleScript") then
		local ok, result = pcall(require, mod)
		if ok and type(result) == "table" then
			weaponsModule = result
		end
		weaponsResolved = true -- module exists: either loaded or broken, don't retry every call
	end
	return weaponsModule
end

--[[
	Returns the Weapons config entry for `weaponId` (or nil). Accepts the common module shapes:
	`{byId = {...}}`, `{get = fn}`, or a flat `{[id] = def}` map.
]]
function WeaponModels.GetConfig(weaponId: string?): any
	if type(weaponId) ~= "string" or weaponId == "" then
		return nil
	end
	local w = weaponsConfig()
	if type(w) ~= "table" then
		return nil
	end
	if type(w.byId) == "table" and w.byId[weaponId] then
		return w.byId[weaponId]
	end
	if type(w.get) == "function" then
		local ok, def = pcall(w.get, weaponId)
		if ok and type(def) == "table" then
			return def
		end
	end
	local def = w[weaponId]
	if type(def) == "table" then
		return def
	end
	return nil
end

local function matchHint(text: string, archetype: string?): (string?, string?)
	local lower = string.lower(text):gsub("[%s%-_%.]", "")
	for _, hint in HINTS do
		if (archetype == nil or hint[2] == archetype) and string.find(lower, hint[1], 1, true) then
			return hint[2], hint[3]
		end
	end
	return nil, nil
end

local function resolveParams(weaponId: string): Builder.Params
	local def = WeaponModels.GetConfig(weaponId)
	local visual = (def and type(def.visual) == "table") and def.visual or {}
	local searchText = weaponId .. " " .. ((def and type(def.name) == "string") and def.name or "")

	local archetype = visual.archetype
	if type(archetype) ~= "string" or not BUILDERS[archetype] then
		archetype = def and CATEGORY_ARCHETYPE[def.category] or nil
		local guessed = matchHint(searchText, nil)
		archetype = archetype or guessed or "BoltRifle"
	end
	assert(type(archetype) == "string")

	local variant = visual.variant
	if type(variant) ~= "string" then
		local _, v = matchHint(searchText, archetype)
		-- Snipers borrow rifle variants (Kar98k scoped, Mosin PU...)
		if not v and archetype == "SniperRifle" then
			_, v = matchHint(searchText, "BoltRifle")
			if not v then
				_, v = matchHint(searchText, "SemiRifle")
			end
		end
		variant = v or "generic"
	end

	local defaults = DEFAULTS[archetype] or DEFAULTS.BoltRifle
	local length = tonumber(visual.length) or defaults.length
	if length < 2.5 and length < defaults.length * 0.5 then
		length *= defaults.length -- multiplier form
	end
	length = math.clamp(length, defaults.length * 0.6, defaults.length * 1.5)

	local magazine = visual.magazine
	if type(magazine) ~= "string" then
		magazine = defaults.magazine
	end

	local metal = typeof(visual.metalColor) == "Color3" and visual.metalColor
		or DEFAULT_BODY[archetype]
		or DEFAULT_METAL
	local wood = typeof(visual.woodColor) == "Color3" and visual.woodColor or DEFAULT_WOOD
	local accent = DEFAULT_ACCENT[archetype] or metal
	if typeof(visual.metalColor) == "Color3" and DEFAULT_ACCENT[archetype] then
		accent = visual.metalColor -- throwables/gadgets tint their body with metalColor
	end

	return {
		id = weaponId,
		archetype = archetype,
		variant = variant,
		magazine = magazine,
		length = length,
		scale = length / defaults.length,
		wood = wood,
		metal = metal,
		dark = Builder.shade(metal, 0.55),
		accent = accent,
		scope = visual.scope == true or (def ~= nil and def.scope == true) or archetype == "SniperRifle",
		bayonet = visual.bayonet == true,
	}
end

--------------------------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------------------------

local templates: { [string]: Model } = {}

local function buildTemplate(weaponId: string): Model
	local params = resolveParams(weaponId)
	local b = Builder.new(weaponId, params)
	local fn = BUILDERS[params.archetype] or BUILDERS.BoltRifle
	local ok, err = pcall(fn, b)
	if not ok then
		warn(`[WeaponModels] failed to build '{weaponId}' ({params.archetype}): {err}`)
		b.model:Destroy()
		params.archetype = "BoltRifle"
		params.variant = "generic"
		b = Builder.new(weaponId, params)
		Rifles.BoltRifle(b)
	elseif params.scope and params.archetype ~= "SniperRifle" and b.model:FindFirstChild("ScopeTube") == nil then
		-- a scoped non-sniper archetype (e.g. scoped semi rifle): rebuild with the scope path
		if params.archetype == "BoltRifle" or params.archetype == "SemiRifle" then
			b.model:Destroy()
			b = Builder.new(weaponId, params)
			if params.archetype == "BoltRifle" then
				Rifles.BoltRifle(b, true)
			else
				Rifles.SemiRifle(b, true)
			end
		end
	end
	return b:finish()
end

-- Returns a fresh (unparented) clone of the weapon model.
function WeaponModels.Build(weaponId: string): Model
	local id = (type(weaponId) == "string" and weaponId ~= "") and weaponId or "Generic"
	local template = templates[id]
	if not template then
		template = buildTemplate(id)
		templates[id] = template
	end
	return template:Clone()
end

-- Builds templates ahead of time (e.g. the local loadout) to avoid a hitch on first equip.
function WeaponModels.Preload(weaponIds: { string })
	for _, id in weaponIds do
		if not templates[id] then
			templates[id] = buildTemplate(id)
		end
	end
end

-- Resolved presentation info without building (archetype/variant/hold decisions).
function WeaponModels.GetArchetype(weaponId: string): string
	return resolveParams(weaponId).archetype
end

WeaponModels.Archetypes = DEFAULTS

return WeaponModels
