--[[
	Weapons: the WW2 Frontlines arsenal (Combat team). Schema: docs/ARCHITECTURE.md section 8.

	Every faction has at least one unlockLevel-1 item for every category used by Classes.luau
	slots, so any class is playable at level 1 with any nation. Where a nation historically lacked a
	weapon type, a plausible shared / lend-lease / captured / prototype item fills the slot; those
	choices are documented next to the entry.

	Balance targets (100 HP, see Util/Ballistics for falloff + hit zones):
	  * Bolt rifles:  one-shot headshot, two-shot body at nearly all ranges.
	  * Scoped rifles: one-shot body inside ~250 studs, two-shot beyond.
	  * Semi rifles:  3 shots body, 2 headshots.
	  * SMGs:         4-5 shots, best TTK inside ~35 studs, drop off hard after ~80.
	  * Assault rifles: 4 shots out to ~60 studs, flatter falloff than SMGs.
	  * LMGs:         3-4 shots, slow ADS/handling, huge magazines.
	  * Shotguns:     one pump kills inside ~12 studs, useless beyond ~45.
	  * Pistols:      3-4 shots, fast handling sidearms.

	Additional (Combat-owned) fields beyond the schema:
	  burstCount     number?   rounds per burst for "Burst" mode
	  pelletSpread   number?   shotgun pellet cone half-angle (degrees), on top of aim spread
	  projectile     string?   "frag" | "impact" | "smoke" | "sticky" | "satchel" | "rocket"
	                           (nil = hitscan firearm / gadget / melee)
	  cookable       boolean?  grenade fuse starts while held
	  gravityScale   number?   rocket drop (1 = full gravity)
	  smokeRadius, smokeDuration  number?  smoke screen size / lifetime
	  meleeRange, meleeCooldown   number?  knife
	  vehicleDamage  number?   also used by hitscan anti-tank rifles (damage per hit to vehicles)
]]

export type FalloffPoint = { range: number, multiplier: number }
export type Recoil = { vertical: number, horizontal: number, recovery: number, firstShotMult: number }
export type Visual = {
	archetype: string,
	magazine: string,
	length: number?,
	woodColor: Color3?,
	metalColor: Color3?,
	scope: boolean?,
	bayonet: boolean?,
}
export type Weapon = {
	id: string,
	name: string,
	category: string,
	factions: { string },
	unlockLevel: number,
	description: string,
	damage: number,
	headshotMultiplier: number,
	limbMultiplier: number,
	damageFalloff: { FalloffPoint },
	rpm: number,
	fireModes: { string },
	burstCount: number?,
	magazine: number,
	reserve: number,
	reloadTime: number,
	emptyReloadTime: number?,
	reloadType: string,
	pellets: number?,
	pelletSpread: number?,
	hipSpread: number,
	adsSpread: number,
	moveSpreadMult: number,
	recoil: Recoil,
	adsTime: number,
	adsZoom: number,
	scope: boolean?,
	bulletVelocity: number,
	range: number,
	equipTime: number,
	walkSpeedMult: number,
	penetration: number,
	suppression: number?,
	fuse: number?,
	blastRadius: number?,
	blastDamage: number?,
	vehicleDamage: number?,
	throwSpeed: number?,
	projectile: string?,
	cookable: boolean?,
	gravityScale: number?,
	smokeRadius: number?,
	smokeDuration: number?,
	meleeRange: number?,
	meleeCooldown: number?,
	visual: Visual,
	sound: string,
}

local ALL = { "US", "UK", "USSR", "FR", "DE", "JP", "IT" }

-- Common finishes
local WOOD = Color3.fromRGB(112, 74, 44)
local DARK_WOOD = Color3.fromRGB(78, 50, 32)
local LIGHT_WOOD = Color3.fromRGB(150, 104, 64)
local RED_WOOD = Color3.fromRGB(120, 60, 40) -- Soviet shellac
local BLUED = Color3.fromRGB(40, 42, 46)
local PARKERIZED = Color3.fromRGB(62, 64, 60)
local STAMPED = Color3.fromRGB(52, 52, 54)
local OLIVE = Color3.fromRGB(78, 86, 58)
local FIELD_GREY = Color3.fromRGB(88, 92, 86)

-------------------------------------------------------------------------------------------------
-- Templates (per category). Entries override any field; `recoil` and `visual` merge shallowly.
-------------------------------------------------------------------------------------------------

local BOLT = {
	category = "BoltAction",
	damage = 90,
	headshotMultiplier = 2.0,
	limbMultiplier = 0.8,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 150, multiplier = 1 },
		{ range = 450, multiplier = 0.7 },
	},
	rpm = 50,
	fireModes = { "Bolt" },
	magazine = 5,
	reserve = 40,
	reloadTime = 3.0,
	emptyReloadTime = 3.4,
	reloadType = "clip",
	hipSpread = 4.0,
	adsSpread = 0.05,
	moveSpreadMult = 2.0,
	recoil = { vertical = 4.5, horizontal = 0.8, recovery = 8, firstShotMult = 1 },
	adsTime = 0.32,
	adsZoom = 0.6,
	bulletVelocity = 2600,
	range = 600,
	equipTime = 0.6,
	walkSpeedMult = 0.97,
	penetration = 0.5,
	suppression = 0.5,
	visual = { archetype = "BoltRifle", magazine = "internal", length = 4.4, woodColor = WOOD, metalColor = BLUED },
	sound = "Rifle_Bolt",
}

local SNIPER = {
	category = "Sniper",
	damage = 100,
	headshotMultiplier = 2.0,
	limbMultiplier = 0.75,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 250, multiplier = 1 },
		{ range = 700, multiplier = 0.82 },
	},
	rpm = 45,
	fireModes = { "Bolt" },
	magazine = 5,
	reserve = 30,
	reloadTime = 3.4,
	emptyReloadTime = 3.8,
	reloadType = "clip",
	hipSpread = 6.0,
	adsSpread = 0.0,
	moveSpreadMult = 2.5,
	recoil = { vertical = 5.5, horizontal = 1.0, recovery = 6, firstShotMult = 1 },
	adsTime = 0.45,
	adsZoom = 0.28,
	scope = true,
	bulletVelocity = 2800,
	range = 1000,
	equipTime = 0.75,
	walkSpeedMult = 0.95,
	penetration = 0.6,
	suppression = 0.7,
	visual = {
		archetype = "SniperRifle",
		magazine = "internal",
		length = 4.4,
		woodColor = WOOD,
		metalColor = BLUED,
		scope = true,
	},
	sound = "Rifle_Bolt",
}

local SEMI = {
	category = "SemiAuto",
	damage = 48,
	headshotMultiplier = 1.8,
	limbMultiplier = 0.85,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 90, multiplier = 1 },
		{ range = 300, multiplier = 0.74 },
	},
	rpm = 300,
	fireModes = { "Semi" },
	magazine = 10,
	reserve = 70,
	reloadTime = 2.6,
	emptyReloadTime = 3.0,
	reloadType = "magazine",
	hipSpread = 3.0,
	adsSpread = 0.15,
	moveSpreadMult = 1.8,
	recoil = { vertical = 2.2, horizontal = 0.6, recovery = 9, firstShotMult = 1.1 },
	adsTime = 0.28,
	adsZoom = 0.7,
	bulletVelocity = 2500,
	range = 450,
	equipTime = 0.55,
	walkSpeedMult = 0.97,
	penetration = 0.45,
	suppression = 0.45,
	visual = { archetype = "SemiRifle", magazine = "box", length = 4.2, woodColor = WOOD, metalColor = PARKERIZED },
	sound = "Rifle_Semi",
}

local SMG = {
	category = "SMG",
	damage = 26,
	headshotMultiplier = 1.5,
	limbMultiplier = 0.9,
	damageFalloff = { { range = 0, multiplier = 1 }, { range = 32, multiplier = 1 }, { range = 90, multiplier = 0.62 } },
	rpm = 650,
	fireModes = { "Auto", "Semi" },
	magazine = 30,
	reserve = 150,
	reloadTime = 2.3,
	emptyReloadTime = 2.8,
	reloadType = "magazine",
	hipSpread = 2.0,
	adsSpread = 0.6,
	moveSpreadMult = 1.25,
	recoil = { vertical = 0.9, horizontal = 0.55, recovery = 10, firstShotMult = 1.3 },
	adsTime = 0.2,
	adsZoom = 0.82,
	bulletVelocity = 1300,
	range = 160,
	equipTime = 0.4,
	walkSpeedMult = 1.0,
	penetration = 0.15,
	suppression = 0.35,
	visual = { archetype = "SMG", magazine = "stick", length = 3.0, woodColor = WOOD, metalColor = STAMPED },
	sound = "SMG",
}

local AR = {
	category = "AssaultRifle",
	damage = 31,
	headshotMultiplier = 1.6,
	limbMultiplier = 0.9,
	damageFalloff = { { range = 0, multiplier = 1 }, { range = 65, multiplier = 1 }, { range = 200, multiplier = 0.7 } },
	rpm = 550,
	fireModes = { "Auto", "Semi" },
	magazine = 30,
	reserve = 150,
	reloadTime = 2.6,
	emptyReloadTime = 3.1,
	reloadType = "magazine",
	hipSpread = 2.6,
	adsSpread = 0.3,
	moveSpreadMult = 1.5,
	recoil = { vertical = 1.2, horizontal = 0.5, recovery = 9, firstShotMult = 1.3 },
	adsTime = 0.26,
	adsZoom = 0.75,
	bulletVelocity = 2100,
	range = 320,
	equipTime = 0.5,
	walkSpeedMult = 0.97,
	penetration = 0.35,
	suppression = 0.5,
	visual = { archetype = "AssaultRifle", magazine = "box", length = 3.6, woodColor = WOOD, metalColor = STAMPED },
	sound = "AssaultRifle",
}

local LMG = {
	category = "MachineGun",
	damage = 34,
	headshotMultiplier = 1.5,
	limbMultiplier = 0.9,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 90, multiplier = 1 },
		{ range = 280, multiplier = 0.76 },
	},
	rpm = 550,
	fireModes = { "Auto" },
	magazine = 30,
	reserve = 240,
	reloadTime = 4.2,
	emptyReloadTime = 5.0,
	reloadType = "magazine",
	hipSpread = 4.0,
	adsSpread = 0.45,
	moveSpreadMult = 2.5,
	recoil = { vertical = 1.3, horizontal = 0.85, recovery = 7, firstShotMult = 1.4 },
	adsTime = 0.42,
	adsZoom = 0.75,
	bulletVelocity = 2400,
	range = 450,
	equipTime = 1.0,
	walkSpeedMult = 0.88,
	penetration = 0.6,
	suppression = 0.9,
	visual = { archetype = "LMG", magazine = "top", length = 4.6, woodColor = WOOD, metalColor = PARKERIZED },
	sound = "LMG",
}

local SHOTGUN = {
	category = "Shotgun",
	damage = 19,
	pellets = 9,
	pelletSpread = 4.0,
	headshotMultiplier = 1.25,
	limbMultiplier = 0.9,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 12, multiplier = 1 },
		{ range = 28, multiplier = 0.45 },
		{ range = 50, multiplier = 0.12 },
	},
	rpm = 70,
	fireModes = { "Bolt" }, -- pump action: manual cycle between shots
	magazine = 6,
	reserve = 30,
	reloadTime = 0.55, -- per shell (reloadType "single")
	emptyReloadTime = 0.9, -- first shell when empty (chambering)
	reloadType = "single",
	hipSpread = 1.4,
	adsSpread = 0.9,
	moveSpreadMult = 1.2,
	recoil = { vertical = 6.0, horizontal = 1.6, recovery = 7, firstShotMult = 1 },
	adsTime = 0.26,
	adsZoom = 0.85,
	bulletVelocity = 1200,
	range = 60,
	equipTime = 0.55,
	walkSpeedMult = 0.98,
	penetration = 0.05,
	suppression = 0.4,
	visual = { archetype = "Shotgun", magazine = "internal", length = 3.8, woodColor = WOOD, metalColor = BLUED },
	sound = "Shotgun",
}

local PISTOL = {
	category = "Pistol",
	damage = 34,
	headshotMultiplier = 1.6,
	limbMultiplier = 0.9,
	damageFalloff = { { range = 0, multiplier = 1 }, { range = 25, multiplier = 1 }, { range = 75, multiplier = 0.6 } },
	rpm = 400,
	fireModes = { "Semi" },
	magazine = 8,
	reserve = 48,
	reloadTime = 1.8,
	emptyReloadTime = 2.1,
	reloadType = "magazine",
	hipSpread = 1.8,
	adsSpread = 0.5,
	moveSpreadMult = 1.2,
	recoil = { vertical = 2.4, horizontal = 0.6, recovery = 9, firstShotMult = 1 },
	adsTime = 0.16,
	adsZoom = 0.85,
	bulletVelocity = 1100,
	range = 100,
	equipTime = 0.3,
	walkSpeedMult = 1.03,
	penetration = 0.1,
	suppression = 0.2,
	visual = { archetype = "Pistol", magazine = "internal", length = 0.9, woodColor = DARK_WOOD, metalColor = BLUED },
	sound = "Pistol",
}

-- Base for non-firearms (throwables, launchers, gadgets, melee). Firearm fields are inert.
local NONFIRE = {
	damage = 0,
	headshotMultiplier = 1,
	limbMultiplier = 1,
	damageFalloff = { { range = 0, multiplier = 1 } },
	rpm = 60,
	fireModes = { "Semi" },
	magazine = 1,
	reserve = 0,
	reloadTime = 0,
	reloadType = "magazine",
	hipSpread = 0,
	adsSpread = 0,
	moveSpreadMult = 1,
	recoil = { vertical = 0, horizontal = 0, recovery = 10, firstShotMult = 1 },
	adsTime = 0.25,
	adsZoom = 1,
	bulletVelocity = 0,
	range = 0,
	equipTime = 0.45,
	walkSpeedMult = 1.0,
	penetration = 0,
}

local function merge(base: { [string]: any }, o: { [string]: any }): { [string]: any }
	local t = table.clone(base)
	for k, v in o do
		if (k == "recoil" or k == "visual") and type(base[k]) == "table" then
			local sub = table.clone(base[k])
			for k2, v2 in v do
				sub[k2] = v2
			end
			t[k] = sub
		else
			t[k] = v
		end
	end
	return t
end

local GRENADE = merge(NONFIRE, {
	category = "Grenade",
	magazine = 2, -- grenades: magazine = carried count, no reload
	projectile = "frag",
	cookable = true,
	fuse = 4.0,
	blastRadius = 18,
	blastDamage = 150,
	vehicleDamage = 40,
	throwSpeed = 85,
	visual = { archetype = "FragGrenade", magazine = "none" },
	sound = "Grenade",
})

local SMOKE = merge(NONFIRE, {
	category = "Smoke",
	magazine = 2,
	projectile = "smoke",
	fuse = 1.5,
	blastRadius = 0,
	blastDamage = 0,
	smokeRadius = 24,
	smokeDuration = 28,
	throwSpeed = 80,
	visual = { archetype = "SmokeGrenade", magazine = "none" },
	sound = "Grenade",
})

local EXPLOSIVE = merge(NONFIRE, {
	category = "Explosive",
	magazine = 2,
	projectile = "satchel",
	fuse = 5.0,
	blastRadius = 22,
	blastDamage = 250,
	vehicleDamage = 450,
	throwSpeed = 40,
	walkSpeedMult = 0.97,
	visual = { archetype = "Satchel", magazine = "none" },
	sound = "Explosive",
})

-- Shoulder-fired rocket launchers. magazine 1 + reserve rockets; "reload" loads the next rocket.
local LAUNCHER = merge(NONFIRE, {
	category = "AntiTank",
	projectile = "rocket",
	magazine = 1,
	reserve = 3,
	reloadTime = 3.8,
	adsTime = 0.45,
	adsZoom = 0.75,
	hipSpread = 2.5,
	adsSpread = 0.4,
	bulletVelocity = 260,
	gravityScale = 0.25,
	range = 350,
	blastRadius = 9,
	blastDamage = 130,
	vehicleDamage = 700,
	penetration = 1,
	equipTime = 1.0,
	walkSpeedMult = 0.92,
	recoil = { vertical = 3, horizontal = 0.6, recovery = 5, firstShotMult = 1 },
	visual = { archetype = "Bazooka", magazine = "none", length = 5.2, metalColor = OLIVE },
	sound = "Rocket",
})

-- Thrown anti-tank grenades: impact fuse, heavy vehicle damage, small blast.
local AT_GRENADE = merge(NONFIRE, {
	category = "AntiTank",
	projectile = "impact",
	magazine = 2,
	throwSpeed = 70,
	blastRadius = 8,
	blastDamage = 120,
	vehicleDamage = 520,
	penetration = 0.8,
	walkSpeedMult = 0.96,
	visual = { archetype = "StickGrenade", magazine = "none" },
	sound = "Explosive",
})

-- Anti-tank rifles: hitscan firearms with large vehicle damage (effective vs light armor).
local AT_RIFLE = merge(BOLT, {
	category = "AntiTank",
	damage = 160,
	headshotMultiplier = 1.5,
	limbMultiplier = 1,
	damageFalloff = { { range = 0, multiplier = 1 } },
	rpm = 30,
	magazine = 1,
	reserve = 20,
	reloadTime = 2.6,
	emptyReloadTime = 2.6,
	reloadType = "magazine",
	hipSpread = 6,
	adsSpread = 0.1,
	moveSpreadMult = 3,
	recoil = { vertical = 7, horizontal = 1.6, recovery = 4, firstShotMult = 1 },
	adsTime = 0.55,
	adsZoom = 0.55,
	range = 700,
	equipTime = 1.1,
	walkSpeedMult = 0.86,
	penetration = 1,
	vehicleDamage = 140,
	suppression = 1,
	visual = { archetype = "BoltRifle", magazine = "box", length = 6.0, woodColor = DARK_WOOD, metalColor = BLUED },
	sound = "ATRifle",
})

local GADGET = merge(NONFIRE, { equipTime = 0.5, sound = "Gadget" })

-------------------------------------------------------------------------------------------------
-- Registry
-------------------------------------------------------------------------------------------------

local byId: { [string]: Weapon } = {}
local order: { string } = {}

local function add(base: { [string]: any }, o: { [string]: any })
	local w = merge(base, o)
	assert(w.id and not byId[w.id], `duplicate or missing weapon id {w.id}`)
	byId[w.id] = w :: any
	table.insert(order, w.id)
end

-------------------------------------------------------------------------------------------------
-- Semi-automatic rifles
-------------------------------------------------------------------------------------------------

add(SEMI, {
	id = "M1Garand",
	name = "M1 Garand",
	factions = { "US" },
	unlockLevel = 1,
	description = "The .30-06 battle rifle that gave the GI a firepower edge. 8-round en-bloc clip.",
	damage = 50,
	magazine = 8,
	reserve = 64,
	reloadType = "clip",
	reloadTime = 2.4,
	emptyReloadTime = 2.2, -- empty clip ejects with the famous "ping", fastest when empty
	recoil = { vertical = 2.4, horizontal = 0.55 },
	visual = { length = 4.4 },
})
add(SEMI, {
	id = "M1Carbine",
	name = "M1 Carbine",
	factions = { "US", "UK", "FR" }, -- lend-lease to Commonwealth and Free French units
	unlockLevel = 1,
	description = "Light, handy .30 Carbine. Lower damage than a full rifle but fast and accurate.",
	damage = 36,
	headshotMultiplier = 1.7,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 60, multiplier = 1 },
		{ range = 200, multiplier = 0.72 },
	},
	rpm = 450,
	magazine = 15,
	reserve = 90,
	reloadTime = 2.0,
	emptyReloadTime = 2.4,
	hipSpread = 2.2,
	adsSpread = 0.25,
	recoil = { vertical = 1.3, horizontal = 0.4 },
	adsTime = 0.22,
	adsZoom = 0.75,
	bulletVelocity = 1900,
	range = 300,
	equipTime = 0.45,
	walkSpeedMult = 1.0,
	visual = { length = 3.4 },
	sound = "Carbine",
})
add(SEMI, {
	id = "SVT40",
	name = "SVT-40",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "Tokarev's semi-automatic rifle in 7.62x54R. Detachable 10-round magazine.",
	damage = 48,
	recoil = { vertical = 2.6, horizontal = 0.8 },
	visual = { woodColor = RED_WOOD, metalColor = BLUED },
})
add(SEMI, {
	id = "MAS44",
	name = "MAS 44",
	factions = { "FR" },
	unlockLevel = 1,
	description = "Late-war French semi-automatic (direct ancestor of the MAS 49), issued in small numbers.",
	damage = 48,
	rpm = 280,
	recoil = { vertical = 2.3, horizontal = 0.6 },
	visual = { woodColor = LIGHT_WOOD },
})
add(SEMI, {
	id = "Gewehr43",
	name = "Gewehr 43",
	factions = { "DE" },
	unlockLevel = 1,
	description = "Gas-operated 7.92mm self-loader with a 10-round detachable magazine.",
	damage = 48,
	recoil = { vertical = 2.4, horizontal = 0.7 },
	visual = { woodColor = DARK_WOOD, metalColor = FIELD_GREY },
})
add(SEMI, {
	id = "Type5Rifle",
	name = "Type 5 Rifle",
	factions = { "JP" },
	unlockLevel = 1,
	description = "Japanese 7.7mm Garand derivative, a 1945 prototype fed by stripper clips into a fixed magazine.",
	damage = 49,
	reloadType = "clip",
	reloadTime = 2.9,
	emptyReloadTime = 3.1,
	recoil = { vertical = 2.4, horizontal = 0.6 },
	visual = { magazine = "internal", woodColor = LIGHT_WOOD },
})
add(SEMI, {
	id = "Armaguerra39",
	name = "Armaguerra Mod. 39",
	factions = { "IT" },
	unlockLevel = 1,
	description = "Rare Italian 6.5mm semi-automatic rifle. Light recoil, small 6-round magazine.",
	damage = 46,
	rpm = 330,
	magazine = 6,
	reserve = 60,
	reloadType = "clip",
	reloadTime = 2.2,
	emptyReloadTime = 2.4,
	recoil = { vertical = 1.9, horizontal = 0.5 },
	visual = { magazine = "internal", woodColor = LIGHT_WOOD },
})
add(SEMI, {
	id = "Gewehr41",
	name = "Gewehr 41",
	factions = { "DE", "IT" },
	unlockLevel = 10,
	description = "Muzzle-trap predecessor of the G43. Front-heavy but hard-hitting; loaded by stripper clips.",
	damage = 52,
	rpm = 270,
	reloadType = "clip",
	reloadTime = 3.2,
	emptyReloadTime = 3.4,
	adsTime = 0.32,
	recoil = { vertical = 2.6, horizontal = 0.7 },
	visual = { magazine = "internal", length = 4.6, woodColor = DARK_WOOD, metalColor = FIELD_GREY },
})
add(SEMI, {
	id = "M1941Johnson",
	name = "M1941 Johnson Rifle",
	factions = { "US" },
	unlockLevel = 12,
	description = "Recoil-operated rifle with a 10-round rotary magazine, favoured by Marine Raiders.",
	damage = 50,
	magazine = 10,
	reserve = 70,
	reloadType = "clip",
	reloadTime = 2.9,
	emptyReloadTime = 3.0,
	recoil = { vertical = 2.2, horizontal = 0.65 },
	visual = { magazine = "internal" },
})
add(SEMI, {
	id = "SVT38",
	name = "SVT-38",
	factions = { "USSR" },
	unlockLevel = 14,
	description = "The SVT-40's longer predecessor. Slightly more accurate, a touch slower to handle.",
	damage = 50,
	rpm = 280,
	adsSpread = 0.1,
	adsTime = 0.31,
	recoil = { vertical = 2.4, horizontal = 0.6 },
	visual = { length = 4.6, woodColor = RED_WOOD },
})

-------------------------------------------------------------------------------------------------
-- Bolt-action rifles
-------------------------------------------------------------------------------------------------

add(BOLT, {
	id = "M1903",
	name = "M1903 Springfield",
	factions = { "US" },
	unlockLevel = 1,
	description = "Precise .30-06 bolt-action, the US Army's rifle before the Garand.",
	rpm = 52,
	visual = { woodColor = WOOD, metalColor = PARKERIZED },
})
add(BOLT, {
	id = "M1917Enfield",
	name = "M1917 Enfield",
	factions = { "US" },
	unlockLevel = 10,
	description = "Heavy American Enfield with a six-round magazine and a smooth cock-on-close bolt.",
	damage = 92,
	magazine = 6,
	reserve = 42,
	rpm = 50,
	adsTime = 0.34,
	visual = { length = 4.6 },
})
add(BOLT, {
	id = "LeeEnfieldNo4",
	name = "Lee-Enfield No.4 Mk I",
	factions = { "UK" },
	unlockLevel = 1,
	description = "Ten rounds and the fastest bolt of the war. The 'mad minute' rifle.",
	damage = 88,
	rpm = 62,
	magazine = 10,
	reserve = 50,
	reloadTime = 3.4,
	emptyReloadTime = 3.8,
	visual = { metalColor = PARKERIZED, magazine = "box" },
})
add(BOLT, {
	id = "SMLE",
	name = "SMLE No.1 Mk III*",
	factions = { "UK" },
	unlockLevel = 10,
	description = "The Great War veteran Short Magazine Lee-Enfield. Shorter and quicker to aim.",
	damage = 86,
	rpm = 60,
	magazine = 10,
	reserve = 50,
	reloadTime = 3.3,
	emptyReloadTime = 3.7,
	adsTime = 0.28,
	visual = { length = 4.1, magazine = "box" },
})
add(BOLT, {
	id = "MosinNagant",
	name = "Mosin-Nagant M91/30",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "Rugged 7.62x54R service rifle. Stiff bolt, long sight radius.",
	damage = 94,
	rpm = 46,
	adsSpread = 0.03,
	visual = { length = 4.8, woodColor = RED_WOOD, bayonet = true },
})
add(BOLT, {
	id = "MosinM38",
	name = "Mosin-Nagant M38",
	factions = { "USSR" },
	unlockLevel = 10,
	description = "Carbine Mosin for engineers and signallers: snappier handling, harsher recoil.",
	damage = 90,
	rpm = 48,
	adsTime = 0.26,
	recoil = { vertical = 5.2 },
	range = 450,
	walkSpeedMult = 1.0,
	visual = { length = 3.6, woodColor = RED_WOOD },
})
add(BOLT, {
	id = "MAS36",
	name = "MAS-36",
	factions = { "FR" },
	unlockLevel = 1,
	description = "Compact French 7.5mm rifle with a rearward-angled bolt handle.",
	rpm = 52,
	adsTime = 0.3,
	visual = { length = 4.0, woodColor = LIGHT_WOOD, bayonet = true },
})
add(BOLT, {
	id = "Lebel1886",
	name = "Lebel Mle 1886/93",
	factions = { "FR" },
	unlockLevel = 10,
	description = "The first smokeless-powder rifle. Eight-round tube magazine loaded round by round.",
	damage = 95,
	rpm = 46,
	magazine = 8,
	reserve = 48,
	reloadType = "single",
	reloadTime = 0.55,
	emptyReloadTime = 0.8,
	adsTime = 0.36,
	visual = { length = 5.0, woodColor = DARK_WOOD },
})
add(BOLT, {
	id = "Kar98k",
	name = "Karabiner 98k",
	factions = { "DE" },
	unlockLevel = 1,
	description = "The Wehrmacht's standard 7.92mm Mauser. Exceptionally accurate.",
	rpm = 52,
	adsSpread = 0.03,
	visual = { woodColor = DARK_WOOD, metalColor = BLUED },
})
add(BOLT, {
	id = "G3340",
	name = "Gewehr 33/40",
	factions = { "DE", "IT" },
	unlockLevel = 10,
	description = "Shortened mountain-troop Mauser. Fast to shoulder, fierce muzzle blast.",
	rpm = 54,
	adsTime = 0.26,
	recoil = { vertical = 5.4 },
	range = 450,
	walkSpeedMult = 1.0,
	visual = { length = 3.7, woodColor = WOOD },
})
add(BOLT, {
	id = "ArisakaType99",
	name = "Arisaka Type 99",
	factions = { "JP" },
	unlockLevel = 1,
	description = "7.7mm Japanese service rifle with a smooth bolt and anti-aircraft sight wings.",
	rpm = 52,
	visual = { woodColor = LIGHT_WOOD, metalColor = BLUED, bayonet = true },
})
add(BOLT, {
	id = "ArisakaType38",
	name = "Arisaka Type 38",
	factions = { "JP" },
	unlockLevel = 10,
	description = "Long 6.5mm rifle: very mild recoil, slightly lower stopping power at range.",
	damage = 86,
	rpm = 55,
	recoil = { vertical = 3.6, horizontal = 0.6 },
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 160, multiplier = 1 },
		{ range = 450, multiplier = 0.66 },
	},
	visual = { length = 5.0, woodColor = LIGHT_WOOD },
})
add(BOLT, {
	id = "CarcanoM9138",
	name = "Carcano M91/38",
	factions = { "IT" },
	unlockLevel = 1,
	description = "Short Italian 7.35mm/6.5mm rifle with Mannlicher-style en-bloc clip.",
	damage = 88,
	rpm = 56,
	magazine = 6,
	reserve = 48,
	reloadTime = 2.8,
	emptyReloadTime = 2.6,
	adsTime = 0.29,
	visual = { length = 4.0, woodColor = WOOD },
})
add(BOLT, {
	id = "CarcanoM91",
	name = "Carcano M91 Long Rifle",
	factions = { "IT" },
	unlockLevel = 10,
	description = "Full-length Carcano: steadier at range, longer to bring to bear.",
	damage = 92,
	rpm = 52,
	magazine = 6,
	reserve = 48,
	reloadTime = 2.8,
	emptyReloadTime = 2.6,
	adsSpread = 0.03,
	adsTime = 0.36,
	visual = { length = 5.0, woodColor = WOOD, bayonet = true },
})

-------------------------------------------------------------------------------------------------
-- Scoped rifles
-------------------------------------------------------------------------------------------------

add(SNIPER, {
	id = "M1903A4",
	name = "M1903A4 Springfield",
	factions = { "US" },
	unlockLevel = 1,
	description = "Springfield with a Weaver 2.5x scope. No iron sights, all business.",
	rpm = 48,
	visual = { metalColor = PARKERIZED },
})
add(SNIPER, {
	id = "M1C",
	name = "M1C Garand Sniper",
	factions = { "US" },
	unlockLevel = 14,
	description = "Semi-automatic scoped Garand. Two-shot body kills with fast follow-ups.",
	damage = 70,
	headshotMultiplier = 2.0,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 200, multiplier = 1 },
		{ range = 600, multiplier = 0.8 },
	},
	rpm = 240,
	fireModes = { "Semi" },
	magazine = 8,
	reserve = 48,
	reloadTime = 2.6,
	emptyReloadTime = 2.4,
	recoil = { vertical = 3.6, horizontal = 0.8 },
	adsZoom = 0.32,
	visual = { archetype = "SniperRifle", magazine = "internal", metalColor = PARKERIZED },
	sound = "Rifle_Semi",
})
add(SNIPER, {
	id = "LeeEnfieldNo4T",
	name = "Lee-Enfield No.4 Mk I (T)",
	factions = { "UK" },
	unlockLevel = 1,
	description = "Holland & Holland converted No.4 with a No.32 3.5x scope and cheek rest.",
	rpm = 54,
	magazine = 10,
	reserve = 40,
	adsZoom = 0.26,
	visual = { magazine = "box" },
})
add(SNIPER, {
	id = "MosinPU",
	name = "Mosin-Nagant (PU scope)",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "Bent-bolt M91/30 with a compact 3.5x PU optic. The rifle of Stalingrad's snipers.",
	rpm = 44,
	visual = { length = 4.8, woodColor = RED_WOOD },
})
add(SNIPER, {
	id = "SVT40Sniper",
	name = "SVT-40 (PU scope)",
	factions = { "USSR" },
	unlockLevel = 14,
	description = "Semi-auto sniper SVT. Two-shot body kill, quick follow-up shots.",
	damage = 70,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 200, multiplier = 1 },
		{ range = 600, multiplier = 0.8 },
	},
	rpm = 240,
	fireModes = { "Semi" },
	magazine = 10,
	reserve = 50,
	reloadType = "magazine",
	reloadTime = 2.8,
	emptyReloadTime = 3.2,
	recoil = { vertical = 3.8, horizontal = 1.0 },
	adsZoom = 0.32,
	visual = { magazine = "box", woodColor = RED_WOOD },
	sound = "Rifle_Semi",
})
add(SNIPER, {
	id = "MAS36Scoped",
	name = "MAS-36 (APX scope)",
	factions = { "FR" },
	unlockLevel = 1,
	-- Historical note: scoped MAS-36s are mostly post-war (Indochina); included as a plausible
	-- Free French field conversion so France has a level-1 sniper.
	description = "MAS-36 fitted with an APX telescopic sight. Short, handy and accurate.",
	rpm = 50,
	adsTime = 0.42,
	visual = { length = 4.0, woodColor = LIGHT_WOOD },
})
add(SNIPER, {
	id = "Kar98kZF39",
	name = "Kar98k (ZF39 scope)",
	factions = { "DE" },
	unlockLevel = 1,
	description = "Hand-picked Kar98k with a 4x Zeiss scope on a turret mount.",
	rpm = 46,
	adsZoom = 0.25,
	visual = { woodColor = DARK_WOOD },
})
add(SNIPER, {
	id = "Gewehr43ZF4",
	name = "Gewehr 43 (ZF4 scope)",
	factions = { "DE" },
	unlockLevel = 14,
	description = "Semi-automatic G43 with the 4x ZF4 optic. Two-shot body kills at a fast cadence.",
	damage = 70,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 200, multiplier = 1 },
		{ range = 600, multiplier = 0.8 },
	},
	rpm = 240,
	fireModes = { "Semi" },
	magazine = 10,
	reserve = 50,
	reloadType = "magazine",
	reloadTime = 2.7,
	emptyReloadTime = 3.1,
	recoil = { vertical = 3.6, horizontal = 0.9 },
	adsZoom = 0.3,
	visual = { magazine = "box", woodColor = DARK_WOOD, metalColor = FIELD_GREY },
	sound = "Rifle_Semi",
})
add(SNIPER, {
	id = "Type97Sniper",
	name = "Type 97 Sniper Rifle",
	factions = { "JP" },
	unlockLevel = 1,
	description = "6.5mm Arisaka with an offset 2.5x scope. Almost no muzzle flash, very light recoil.",
	damage = 96,
	rpm = 50,
	recoil = { vertical = 4.2, horizontal = 0.7 },
	adsZoom = 0.34,
	visual = { length = 5.0, woodColor = LIGHT_WOOD },
})
add(SNIPER, {
	id = "Type99Sniper",
	name = "Type 99 Sniper Rifle",
	factions = { "JP" },
	unlockLevel = 14,
	description = "7.7mm Type 99 with a 4x scope: more punch at long range.",
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 300, multiplier = 1 },
		{ range = 750, multiplier = 0.85 },
	},
	rpm = 46,
	adsZoom = 0.26,
	visual = { woodColor = LIGHT_WOOD },
})
add(SNIPER, {
	id = "CarcanoScoped",
	name = "Carcano M91/41 (scoped)",
	factions = { "IT" },
	unlockLevel = 1,
	description = "Carcano with a field-fitted German-pattern scope, used by Italian marksmen in Russia.",
	damage = 96,
	rpm = 52,
	magazine = 6,
	reserve = 36,
	reloadTime = 2.9,
	emptyReloadTime = 2.7,
	recoil = { vertical = 4.6 },
	visual = { length = 4.6, woodColor = WOOD },
})

-------------------------------------------------------------------------------------------------
-- Submachine guns
-------------------------------------------------------------------------------------------------

add(SMG, {
	id = "ThompsonM1A1",
	name = "Thompson M1A1",
	factions = { "US" },
	unlockLevel = 1,
	description = "The 'Tommy gun' in simplified wartime form. Heavy .45 ACP slugs, 30-round stick.",
	damage = 28,
	rpm = 700,
	recoil = { vertical = 1.0, horizontal = 0.6 },
	walkSpeedMult = 0.98,
	visual = { length = 3.2, woodColor = WOOD, metalColor = PARKERIZED },
})
add(SMG, {
	id = "M3GreaseGun",
	name = "M3 Grease Gun",
	factions = { "US", "FR" },
	unlockLevel = 8,
	description = "Cheap stamped-steel .45 SMG. Slow, controllable rate of fire.",
	damage = 28,
	rpm = 450,
	hipSpread = 1.8,
	adsSpread = 0.5,
	recoil = { vertical = 0.7, horizontal = 0.35, firstShotMult = 1.1 },
	adsTime = 0.18,
	visual = { length = 2.6, metalColor = PARKERIZED, woodColor = PARKERIZED },
})
add(SMG, {
	id = "ThompsonM1928",
	name = "Thompson M1928 (drum)",
	factions = { "US", "UK" },
	unlockLevel = 16,
	description = "Pre-war Thompson with a 50-round drum and Cutts compensator. Heavy but relentless.",
	damage = 28,
	rpm = 750,
	magazine = 50,
	reserve = 150,
	reloadTime = 3.2,
	emptyReloadTime = 3.8,
	adsTime = 0.24,
	walkSpeedMult = 0.95,
	recoil = { vertical = 0.95, horizontal = 0.55 },
	visual = { magazine = "drum", length = 3.4, woodColor = WOOD, metalColor = BLUED },
})
add(SMG, {
	id = "StenMkII",
	name = "Sten Mk II",
	factions = { "UK", "FR" }, -- air-dropped in quantity to the French Resistance
	unlockLevel = 1,
	description = "Crude, cheap and effective 9mm SMG with a side-mounted magazine.",
	damage = 25,
	rpm = 550,
	magazine = 32,
	reserve = 160,
	recoil = { vertical = 0.8, horizontal = 0.5 },
	visual = { magazine = "side", length = 2.8, woodColor = STAMPED },
})
add(SMG, {
	id = "Lanchester",
	name = "Lanchester Mk I",
	factions = { "UK" },
	unlockLevel = 8,
	description = "Royal Navy's brass-fitted MP28 copy. 50-round magazine, very stable.",
	damage = 25,
	rpm = 600,
	magazine = 50,
	reserve = 150,
	reloadTime = 2.8,
	emptyReloadTime = 3.3,
	adsTime = 0.24,
	recoil = { vertical = 0.75, horizontal = 0.4 },
	walkSpeedMult = 0.97,
	visual = { magazine = "side", length = 3.3, woodColor = WOOD },
})
add(SMG, {
	id = "StenMkV",
	name = "Sten Mk V",
	factions = { "UK" },
	unlockLevel = 20,
	description = "Paratrooper Sten with wooden furniture and a forward pistol grip.",
	damage = 25,
	rpm = 575,
	magazine = 32,
	reserve = 160,
	hipSpread = 1.7,
	adsSpread = 0.45,
	recoil = { vertical = 0.7, horizontal = 0.4 },
	visual = { magazine = "side", length = 3.0, woodColor = WOOD },
})
add(SMG, {
	id = "PPSh41",
	name = "PPSh-41",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "The 'Papasha'. A torrent of 7.62mm Tokarev from a 71-round drum.",
	damage = 21,
	rpm = 950,
	magazine = 71,
	reserve = 213,
	reloadTime = 3.0,
	emptyReloadTime = 3.6,
	hipSpread = 2.3,
	adsSpread = 0.75,
	recoil = { vertical = 0.75, horizontal = 0.65 },
	adsTime = 0.23,
	walkSpeedMult = 0.97,
	damageFalloff = { { range = 0, multiplier = 1 }, { range = 30, multiplier = 1 }, { range = 90, multiplier = 0.65 } },
	visual = { magazine = "drum", length = 3.3, woodColor = RED_WOOD },
})
add(SMG, {
	id = "PPS43",
	name = "PPS-43",
	factions = { "USSR" },
	unlockLevel = 8,
	description = "Stamped Leningrad SMG with a folding stock. Moderate rate, superb handling.",
	damage = 24,
	rpm = 650,
	magazine = 35,
	reserve = 175,
	hipSpread = 1.8,
	recoil = { vertical = 0.75, horizontal = 0.45 },
	adsTime = 0.18,
	walkSpeedMult = 1.02,
	visual = { length = 2.6, woodColor = STAMPED },
})
add(SMG, {
	id = "PPD40",
	name = "PPD-40",
	factions = { "USSR" },
	unlockLevel = 18,
	description = "Machined pre-war Degtyaryov SMG. Drum-fed and beautifully finished.",
	damage = 22,
	rpm = 850,
	magazine = 71,
	reserve = 213,
	reloadTime = 3.1,
	emptyReloadTime = 3.6,
	adsSpread = 0.6,
	recoil = { vertical = 0.7, horizontal = 0.5 },
	adsTime = 0.22,
	walkSpeedMult = 0.97,
	visual = { magazine = "drum", length = 3.3, woodColor = RED_WOOD },
})
add(SMG, {
	id = "MAS38",
	name = "MAS-38",
	factions = { "FR" },
	unlockLevel = 1,
	description = "Compact French SMG in 7.65mm Longue: low recoil, light rounds.",
	damage = 23,
	rpm = 700,
	magazine = 32,
	reserve = 160,
	hipSpread = 1.7,
	adsSpread = 0.5,
	recoil = { vertical = 0.6, horizontal = 0.4 },
	adsTime = 0.18,
	walkSpeedMult = 1.02,
	visual = { length = 2.7, woodColor = LIGHT_WOOD },
})
add(SMG, {
	id = "MP40",
	name = "MP 40",
	factions = { "DE", "IT" },
	unlockLevel = 1,
	description = "Iconic 9mm 'Schmeisser'. Steady 550 RPM, very controllable.",
	damage = 27,
	rpm = 560,
	magazine = 32,
	reserve = 160,
	hipSpread = 1.9,
	adsSpread = 0.5,
	recoil = { vertical = 0.75, horizontal = 0.4 },
	visual = { length = 2.9, woodColor = STAMPED, metalColor = BLUED },
})
add(SMG, {
	id = "MP28",
	name = "MP 28/II",
	factions = { "DE" },
	unlockLevel = 8,
	description = "Schmeisser's interwar SMG with a wooden stock and side magazine.",
	damage = 26,
	rpm = 620,
	magazine = 32,
	reserve = 160,
	recoil = { vertical = 0.8, horizontal = 0.45 },
	adsTime = 0.22,
	visual = { magazine = "side", length = 3.2, woodColor = WOOD },
})
add(SMG, {
	id = "MP35",
	name = "MP 35",
	factions = { "DE" },
	unlockLevel = 18,
	description = "Bergmann's precise right-side-fed SMG, favoured by the Waffen-SS.",
	damage = 26,
	rpm = 600,
	magazine = 32,
	reserve = 160,
	hipSpread = 1.7,
	adsSpread = 0.45,
	recoil = { vertical = 0.7, horizontal = 0.35 },
	visual = { magazine = "side", length = 3.3, woodColor = WOOD },
})
add(SMG, {
	id = "Type100",
	name = "Type 100",
	factions = { "JP" },
	unlockLevel = 1,
	description = "Japan's 8mm Nambu SMG with a curved side magazine and bayonet lug.",
	damage = 26,
	rpm = 600,
	magazine = 30,
	reserve = 150,
	recoil = { vertical = 0.8, horizontal = 0.5 },
	visual = { magazine = "side", length = 3.0, woodColor = LIGHT_WOOD, bayonet = true },
})
add(SMG, {
	id = "Type100Late",
	name = "Type 100 (1944)",
	factions = { "JP" },
	unlockLevel = 12,
	description = "Simplified late-war Type 100 with a much higher cyclic rate and muzzle brake.",
	damage = 24,
	rpm = 800,
	magazine = 30,
	reserve = 150,
	recoil = { vertical = 0.85, horizontal = 0.6 },
	visual = { magazine = "side", length = 2.9, woodColor = WOOD },
})
add(SMG, {
	id = "BerettaM38A",
	name = "Beretta M1938A",
	factions = { "IT" },
	unlockLevel = 1,
	description = "Exquisitely made Italian SMG with twin triggers for semi and full auto.",
	damage = 26,
	rpm = 600,
	magazine = 30,
	reserve = 150,
	hipSpread = 1.8,
	adsSpread = 0.45,
	recoil = { vertical = 0.75, horizontal = 0.4 },
	adsTime = 0.22,
	visual = { length = 3.4, woodColor = WOOD },
})
add(SMG, {
	id = "TZ45",
	name = "TZ-45",
	factions = { "IT" },
	unlockLevel = 10,
	description = "Rough late-war Italian SMG with a grip safety and sliding wire stock.",
	damage = 25,
	rpm = 550,
	magazine = 40,
	reserve = 160,
	recoil = { vertical = 0.8, horizontal = 0.5 },
	adsTime = 0.18,
	walkSpeedMult = 1.02,
	visual = { length = 2.6, woodColor = STAMPED },
})
add(SMG, {
	id = "FNAB43",
	name = "FNAB-43",
	factions = { "IT" },
	unlockLevel = 18,
	description = "Delayed-blowback machined SMG: low rate of fire, laser-like accuracy.",
	damage = 26,
	rpm = 400,
	magazine = 40,
	reserve = 160,
	hipSpread = 1.6,
	adsSpread = 0.35,
	recoil = { vertical = 0.55, horizontal = 0.3, firstShotMult = 1.0 },
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 40, multiplier = 1 },
		{ range = 100, multiplier = 0.65 },
	},
	visual = { length = 2.8, woodColor = STAMPED },
})

-------------------------------------------------------------------------------------------------
-- Assault rifles / automatic rifles
-------------------------------------------------------------------------------------------------

add(AR, {
	id = "M2Carbine",
	name = "M2 Carbine",
	-- The select-fire M1 Carbine stands in as the Allied "assault rifle" (US, lend-lease UK, Free French).
	factions = { "US", "UK", "FR" },
	unlockLevel = 1,
	description = "Select-fire M1 Carbine with a 30-round magazine. The Allies' closest thing to an StG.",
	damage = 28,
	rpm = 750,
	magazine = 30,
	reserve = 150,
	damageFalloff = { { range = 0, multiplier = 1 }, { range = 55, multiplier = 1 }, { range = 180, multiplier = 0.7 } },
	recoil = { vertical = 1.0, horizontal = 0.55 },
	adsTime = 0.22,
	walkSpeedMult = 1.0,
	visual = { archetype = "AssaultRifle", magazine = "box", length = 3.4, woodColor = WOOD, metalColor = PARKERIZED },
	sound = "Carbine",
})
add(AR, {
	id = "StG44",
	name = "StG 44",
	-- Small numbers reached Italian RSI units; Japanese access is a game-balance liberty (Axis transfers).
	factions = { "DE", "IT", "JP" },
	unlockLevel = 1,
	description = "The first true assault rifle. Intermediate 7.92x33 Kurz cartridge, 30-round magazine.",
	damage = 31,
	rpm = 560,
	visual = { magazine = "box", length = 3.6, woodColor = DARK_WOOD, metalColor = STAMPED },
})
add(AR, {
	id = "AVS36",
	name = "AVS-36",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "Simonov's select-fire full-power rifle. Hits like a truck, kicks like a mule.",
	damage = 40,
	headshotMultiplier = 1.7,
	rpm = 600,
	magazine = 15,
	reserve = 120,
	reloadTime = 2.5,
	emptyReloadTime = 3.0,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 80, multiplier = 1 },
		{ range = 250, multiplier = 0.75 },
	},
	recoil = { vertical = 1.9, horizontal = 0.9, firstShotMult = 1.2 },
	adsTime = 0.3,
	visual = { archetype = "AssaultRifle", magazine = "box", length = 4.4, woodColor = RED_WOOD },
	sound = "Rifle_Semi",
})
add(AR, {
	id = "FedorovAvtomat",
	name = "Fedorov Avtomat",
	factions = { "USSR" },
	unlockLevel = 12,
	description = "1916 select-fire rifle in 6.5mm Arisaka, pressed back into service in 1940.",
	damage = 33,
	rpm = 480,
	magazine = 25,
	reserve = 125,
	recoil = { vertical = 1.15, horizontal = 0.55 },
	visual = { length = 3.8, woodColor = RED_WOOD },
})
add(AR, {
	id = "CharltonAR",
	name = "Charlton Automatic Rifle",
	factions = { "UK" },
	unlockLevel = 12,
	-- New Zealand / Australian conversion of the SMLE into a light automatic rifle (1942).
	description = "Antipodean full-auto Lee-Enfield conversion. Full-power .303, 10-round magazine.",
	damage = 40,
	headshotMultiplier = 1.7,
	rpm = 600,
	magazine = 10,
	reserve = 120,
	reloadTime = 2.4,
	emptyReloadTime = 2.9,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 80, multiplier = 1 },
		{ range = 260, multiplier = 0.75 },
	},
	recoil = { vertical = 1.8, horizontal = 0.8 },
	adsTime = 0.3,
	visual = { archetype = "AssaultRifle", magazine = "box", length = 4.2, woodColor = WOOD },
	sound = "Rifle_Semi",
})
add(AR, {
	id = "BredaPG",
	name = "Breda Mod. PG",
	factions = { "IT" },
	unlockLevel = 10,
	description = "Italian 7mm select-fire rifle firing 2-round bursts.",
	damage = 36,
	rpm = 600,
	fireModes = { "Burst", "Semi" },
	burstCount = 2,
	magazine = 20,
	reserve = 120,
	recoil = { vertical = 1.4, horizontal = 0.5 },
	visual = { length = 4.0, woodColor = WOOD },
})
add(AR, {
	id = "FG42",
	name = "FG 42",
	factions = { "DE" },
	unlockLevel = 12,
	description = "Paratrooper battle rifle with a side magazine. Full-power 7.92mm on full auto.",
	damage = 38,
	rpm = 750,
	magazine = 20,
	reserve = 120,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 80, multiplier = 1 },
		{ range = 260, multiplier = 0.75 },
	},
	recoil = { vertical = 1.7, horizontal = 0.85 },
	adsTime = 0.3,
	visual = { magazine = "side", length = 3.8, woodColor = STAMPED },
})
add(AR, {
	id = "MKb42H",
	name = "MKb 42(H)",
	factions = { "DE", "JP" },
	unlockLevel = 22,
	description = "Haenel's trials 'Maschinenkarabiner', the StG 44's ancestor. Slower and smoother.",
	damage = 31,
	rpm = 500,
	recoil = { vertical = 1.0, horizontal = 0.4 },
	adsTime = 0.28,
	visual = { length = 3.8, woodColor = DARK_WOOD },
})

-------------------------------------------------------------------------------------------------
-- Shotguns
-------------------------------------------------------------------------------------------------

add(SHOTGUN, {
	id = "M1897Trench",
	name = "Winchester M1897 Trench",
	factions = { "US", "UK" },
	unlockLevel = 1,
	description = "Pump-action 'trench broom'. Slam-fire capable, devastating up close.",
	rpm = 80,
	visual = { length = 3.9, bayonet = true },
})
add(SHOTGUN, {
	id = "Ithaca37",
	name = "Ithaca 37",
	factions = { "US" },
	unlockLevel = 10,
	description = "Bottom-ejecting pump gun. Tighter pattern, quicker handling.",
	rpm = 85,
	pelletSpread = 3.4,
	adsTime = 0.22,
	visual = { length = 3.6 },
})
add(SHOTGUN, {
	id = "BrowningAuto5",
	name = "Browning Auto-5",
	factions = { "US", "UK", "FR", "DE", "IT" }, -- FN-made; issued or captured by many armies
	unlockLevel = 18,
	description = "Long-recoil semi-automatic shotgun. Five shells as fast as you can pull.",
	damage = 16,
	rpm = 220,
	fireModes = { "Semi" },
	magazine = 5,
	recoil = { vertical = 5.0, horizontal = 1.4 },
	visual = { length = 4.0 },
})
add(SHOTGUN, {
	id = "TOZDouble",
	name = "TOZ-B Double Barrel",
	factions = { "USSR" }, -- civilian hunting gun, used by partisans and militia
	unlockLevel = 1,
	description = "Partisan's side-by-side. Two barrels, two very bad days for the enemy.",
	damage = 21,
	rpm = 400,
	fireModes = { "Semi" },
	magazine = 2,
	reserve = 26,
	reloadType = "magazine",
	reloadTime = 2.3,
	emptyReloadTime = 2.3,
	pelletSpread = 3.6,
	visual = { length = 3.7, woodColor = RED_WOOD },
})
add(SHOTGUN, {
	id = "RobustDouble",
	name = "Manufrance Robust",
	factions = { "FR" }, -- Saint-Etienne hunting gun widely used by the Resistance
	unlockLevel = 1,
	description = "French-made side-by-side hunting gun. A Resistance favourite.",
	damage = 21,
	rpm = 400,
	fireModes = { "Semi" },
	magazine = 2,
	reserve = 26,
	reloadType = "magazine",
	reloadTime = 2.2,
	emptyReloadTime = 2.2,
	pelletSpread = 3.6,
	visual = { length = 3.7, woodColor = LIGHT_WOOD },
})
add(SHOTGUN, {
	id = "DrillingM30",
	name = "Drilling M30",
	factions = { "DE" }, -- Luftwaffe aircrew survival gun
	unlockLevel = 1,
	description = "Luftwaffe survival drilling: two 12-gauge barrels over a rifle barrel.",
	damage = 20,
	rpm = 400,
	fireModes = { "Semi" },
	magazine = 2,
	reserve = 26,
	reloadType = "magazine",
	reloadTime = 2.4,
	emptyReloadTime = 2.4,
	pelletSpread = 3.4,
	visual = { length = 3.8, woodColor = DARK_WOOD },
})
add(SHOTGUN, {
	id = "Lupara",
	name = "Lupara (sawn-off)",
	factions = { "IT", "JP" }, -- improvised sawn-off double; for JP a captured/civilian stand-in
	unlockLevel = 1,
	description = "Sawn-off side-by-side. Wide spread, enormous close-range punch, fast handling.",
	damage = 22,
	pellets = 9,
	rpm = 450,
	fireModes = { "Semi" },
	magazine = 2,
	reserve = 26,
	reloadType = "magazine",
	reloadTime = 2.0,
	emptyReloadTime = 2.0,
	pelletSpread = 5.0,
	damageFalloff = {
		{ range = 0, multiplier = 1 },
		{ range = 9, multiplier = 1 },
		{ range = 22, multiplier = 0.4 },
		{ range = 40, multiplier = 0.1 },
	},
	adsTime = 0.18,
	equipTime = 0.4,
	walkSpeedMult = 1.02,
	visual = { length = 2.4, woodColor = WOOD },
})

-------------------------------------------------------------------------------------------------
-- Machine guns
-------------------------------------------------------------------------------------------------

add(LMG, {
	id = "BAR",
	name = "M1918A2 BAR",
	factions = { "US", "FR" }, -- also issued to Free French divisions
	unlockLevel = 1,
	description = "Browning Automatic Rifle. Full-power .30-06, 20-round box, slow-fire mode.",
	damage = 40,
	headshotMultiplier = 1.6,
	rpm = 500,
	magazine = 20,
	reserve = 200,
	reloadTime = 2.8,
	emptyReloadTime = 3.3,
	adsTime = 0.36,
	walkSpeedMult = 0.92,
	recoil = { vertical = 1.5, horizontal = 0.7 },
	visual = { archetype = "LMG", magazine = "box", length = 4.6, metalColor = PARKERIZED },
})
add(LMG, {
	id = "M1919A6",
	name = "M1919A6",
	factions = { "US" },
	unlockLevel = 12,
	description = "Belt-fed Browning with a shoulder stock and bipod. 100-round belt, long reload.",
	damage = 36,
	rpm = 550,
	magazine = 100,
	reserve = 300,
	reloadTime = 6.5,
	emptyReloadTime = 7.0,
	adsTime = 0.5,
	walkSpeedMult = 0.84,
	hipSpread = 4.8,
	recoil = { vertical = 1.2, horizontal = 0.9 },
	visual = { archetype = "HMG", magazine = "box", length = 5.0, metalColor = PARKERIZED },
})
add(LMG, {
	id = "JohnsonLMG",
	name = "M1941 Johnson LMG",
	factions = { "US" },
	unlockLevel = 22,
	description = "Side-fed, light and fast-handling Marine LMG. Top-off reloads through the side.",
	damage = 36,
	rpm = 600,
	magazine = 25,
	reserve = 225,
	reloadTime = 2.9,
	emptyReloadTime = 3.4,
	adsTime = 0.34,
	walkSpeedMult = 0.93,
	recoil = { vertical = 1.25, horizontal = 0.7 },
	visual = { magazine = "side", length = 4.3 },
})
add(LMG, {
	id = "Bren",
	name = "Bren Mk II",
	factions = { "UK" },
	unlockLevel = 1,
	description = "Exceptionally accurate .303 LMG with a curved top magazine.",
	damage = 38,
	rpm = 520,
	magazine = 30,
	reserve = 240,
	reloadTime = 3.0,
	emptyReloadTime = 3.6,
	adsSpread = 0.35,
	adsTime = 0.38,
	walkSpeedMult = 0.9,
	recoil = { vertical = 1.15, horizontal = 0.55 },
	visual = { magazine = "top", length = 4.5 },
})
add(LMG, {
	id = "LewisGun",
	name = "Lewis Gun",
	factions = { "UK" },
	unlockLevel = 12,
	description = "Air-cooled Great War LMG with a 47-round pan magazine. Pulled from Home Guard stores.",
	damage = 36,
	rpm = 550,
	magazine = 47,
	reserve = 235,
	reloadTime = 4.0,
	emptyReloadTime = 4.6,
	adsTime = 0.46,
	walkSpeedMult = 0.86,
	recoil = { vertical = 1.2, horizontal = 0.75 },
	visual = { magazine = "drum", length = 4.6 },
})
add(LMG, {
	id = "VickersBerthier",
	name = "Vickers-Berthier Mk III",
	factions = { "UK" },
	unlockLevel = 22,
	description = "Indian Army LMG. Faster cyclic rate than the Bren, harder to keep on target.",
	damage = 36,
	rpm = 600,
	magazine = 30,
	reserve = 240,
	reloadTime = 3.0,
	emptyReloadTime = 3.6,
	recoil = { vertical = 1.3, horizontal = 0.7 },
	visual = { magazine = "top", length = 4.5 },
})
add(LMG, {
	id = "DP27",
	name = "DP-27",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "The 'record player': a 47-round pan magazine on a simple, reliable LMG.",
	damage = 36,
	rpm = 550,
	magazine = 47,
	reserve = 235,
	reloadTime = 3.8,
	emptyReloadTime = 4.4,
	recoil = { vertical = 1.2, horizontal = 0.75 },
	visual = { magazine = "drum", length = 4.6, woodColor = RED_WOOD },
})
add(LMG, {
	id = "DS39",
	name = "DS-39",
	factions = { "USSR" },
	unlockLevel = 12,
	description = "Degtyaryov's belt-fed medium MG. Shoulder-fired here with a 100-round belt.",
	damage = 34,
	rpm = 800,
	magazine = 100,
	reserve = 300,
	reloadTime = 6.4,
	emptyReloadTime = 7.0,
	adsTime = 0.52,
	hipSpread = 5.0,
	walkSpeedMult = 0.82,
	recoil = { vertical = 1.35, horizontal = 1.0 },
	visual = { archetype = "HMG", magazine = "box", length = 5.0 },
})
add(LMG, {
	id = "RPD44",
	name = "RPD (1944 trials)",
	factions = { "USSR" },
	unlockLevel = 22,
	description = "Prototype belt-fed LMG in 7.62x39 from the 1944 trials. Light and controllable.",
	damage = 31,
	rpm = 700,
	magazine = 100,
	reserve = 300,
	reloadTime = 5.4,
	emptyReloadTime = 6.0,
	adsTime = 0.36,
	walkSpeedMult = 0.93,
	recoil = { vertical = 0.95, horizontal = 0.6 },
	visual = { magazine = "drum", length = 4.2 },
})
add(LMG, {
	id = "FM2429",
	name = "FM 24/29",
	factions = { "FR" },
	unlockLevel = 1,
	description = "France's 7.5mm Châtellerault LMG with twin triggers and a top magazine.",
	damage = 36,
	rpm = 500,
	magazine = 25,
	reserve = 225,
	reloadTime = 2.9,
	emptyReloadTime = 3.4,
	adsTime = 0.38,
	walkSpeedMult = 0.9,
	recoil = { vertical = 1.15, horizontal = 0.6 },
	visual = { magazine = "top", length = 4.4, woodColor = LIGHT_WOOD },
})
add(LMG, {
	id = "Chauchat",
	name = "Chauchat CSRG",
	factions = { "FR" },
	unlockLevel = 12,
	description = "The infamous Great War automatic rifle. Half-moon magazine, slow, heavy-hitting.",
	damage = 42,
	headshotMultiplier = 1.6,
	rpm = 240,
	magazine = 20,
	reserve = 200,
	reloadTime = 3.0,
	emptyReloadTime = 3.4,
	hipSpread = 3.5,
	adsSpread = 0.4,
	adsTime = 0.4,
	walkSpeedMult = 0.92,
	recoil = { vertical = 1.8, horizontal = 0.6, firstShotMult = 1.1 },
	visual = { magazine = "box", length = 4.4 },
})
add(LMG, {
	id = "MG34",
	name = "MG 34",
	factions = { "DE" },
	unlockLevel = 1,
	description = "The first general-purpose machine gun. 50-round belt drum, 850 RPM.",
	damage = 33,
	rpm = 850,
	magazine = 50,
	reserve = 250,
	reloadTime = 4.8,
	emptyReloadTime = 5.4,
	recoil = { vertical = 1.15, horizontal = 0.85 },
	visual = { archetype = "HMG", magazine = "drum", length = 4.8, metalColor = BLUED },
})
add(LMG, {
	id = "MG42",
	name = "MG 42",
	factions = { "DE", "IT" },
	unlockLevel = 12,
	description = "'Hitler's buzzsaw'. 1,200 rounds a minute from a 75-round belt.",
	damage = 31,
	rpm = 1200,
	magazine = 75,
	reserve = 300,
	reloadTime = 5.2,
	emptyReloadTime = 5.8,
	adsTime = 0.48,
	walkSpeedMult = 0.84,
	hipSpread = 4.8,
	recoil = { vertical = 1.05, horizontal = 1.0, firstShotMult = 1.3 },
	visual = { archetype = "HMG", magazine = "box", length = 4.8, metalColor = STAMPED },
})
add(LMG, {
	id = "MG15",
	name = "MG 15 (ground)",
	factions = { "DE" },
	unlockLevel = 22,
	description = "Luftwaffe observer gun converted for infantry use. 75-round saddle drum.",
	damage = 31,
	rpm = 1000,
	magazine = 75,
	reserve = 300,
	reloadTime = 4.4,
	emptyReloadTime = 5.0,
	adsTime = 0.4,
	recoil = { vertical = 1.1, horizontal = 0.95 },
	visual = { magazine = "drum", length = 4.4 },
})
add(LMG, {
	id = "Type96LMG",
	name = "Type 96 LMG",
	factions = { "JP" },
	unlockLevel = 1,
	description = "6.5mm top-fed LMG with an integral oiler and optional 2.5x scope.",
	damage = 34,
	rpm = 550,
	magazine = 30,
	reserve = 240,
	reloadTime = 3.0,
	emptyReloadTime = 3.6,
	adsSpread = 0.35,
	recoil = { vertical = 1.0, horizontal = 0.55 },
	visual = { magazine = "top", length = 4.5, woodColor = LIGHT_WOOD },
})
add(LMG, {
	id = "Type99LMG",
	name = "Type 99 LMG",
	factions = { "JP" },
	unlockLevel = 10,
	description = "7.7mm evolution of the Type 96. Harder-hitting, still dead accurate.",
	damage = 38,
	rpm = 800,
	magazine = 30,
	reserve = 240,
	reloadTime = 3.0,
	emptyReloadTime = 3.6,
	adsSpread = 0.35,
	recoil = { vertical = 1.3, horizontal = 0.7 },
	visual = { magazine = "top", length = 4.6, woodColor = LIGHT_WOOD },
})
add(LMG, {
	id = "Type11LMG",
	name = "Type 11 LMG",
	factions = { "JP" },
	unlockLevel = 18,
	description = "Hopper-fed from rifle clips: tops up with 5-round chargers, never truly empty.",
	damage = 33,
	rpm = 500,
	magazine = 30,
	reserve = 240,
	reloadType = "single", -- one 5-round clip per insert cycle, modelled as rounds
	reloadTime = 0.18,
	emptyReloadTime = 0.6,
	recoil = { vertical = 1.0, horizontal = 0.6 },
	visual = { magazine = "side", length = 4.4, woodColor = LIGHT_WOOD },
})
add(LMG, {
	id = "Breda30",
	name = "Breda 30",
	factions = { "IT" },
	unlockLevel = 1,
	description = "Italy's quirky 6.5mm LMG with a fixed, side-hinged 20-round magazine.",
	damage = 34,
	rpm = 500,
	magazine = 20,
	reserve = 200,
	reloadTime = 2.6,
	emptyReloadTime = 3.0,
	adsTime = 0.38,
	walkSpeedMult = 0.91,
	recoil = { vertical = 1.0, horizontal = 0.6 },
	visual = { magazine = "side", length = 4.3, woodColor = WOOD },
})
add(LMG, {
	id = "Breda37",
	name = "Breda Mod. 37",
	factions = { "IT" },
	unlockLevel = 12,
	description = "Heavy 8mm machine gun fed by 20-round strips. Brutal hits, very heavy.",
	damage = 42,
	headshotMultiplier = 1.6,
	rpm = 450,
	magazine = 40,
	reserve = 240,
	reloadTime = 4.4,
	emptyReloadTime = 5.0,
	adsTime = 0.52,
	walkSpeedMult = 0.82,
	hipSpread = 5,
	recoil = { vertical = 1.6, horizontal = 0.8 },
	visual = { archetype = "HMG", magazine = "side", length = 5.0, woodColor = DARK_WOOD },
})

-------------------------------------------------------------------------------------------------
-- Pistols
-------------------------------------------------------------------------------------------------

add(PISTOL, {
	id = "M1911",
	name = "M1911A1",
	factions = { "US", "FR" },
	unlockLevel = 1,
	description = "The .45 ACP sidearm. Seven rounds of serious stopping power.",
	damage = 40,
	rpm = 360,
	magazine = 7,
	reserve = 42,
	recoil = { vertical = 2.8, horizontal = 0.7 },
	visual = { metalColor = PARKERIZED },
})
add(PISTOL, {
	id = "SWVictory",
	name = "S&W Victory Model",
	factions = { "US", "UK" },
	unlockLevel = 10,
	description = "Lend-lease .38 revolver. Smooth double action, slow to reload.",
	damage = 45,
	rpm = 260,
	magazine = 6,
	reserve = 36,
	reloadTime = 2.6,
	emptyReloadTime = 2.6,
	recoil = { vertical = 3.0, horizontal = 0.6 },
	visual = { archetype = "Revolver", magazine = "internal" },
	sound = "Revolver",
})
add(PISTOL, {
	id = "WebleyMkIV",
	name = "Webley Mk IV",
	factions = { "UK" },
	unlockLevel = 1,
	description = "Top-break .38/200 revolver: fast to reload for a wheel gun.",
	damage = 45,
	rpm = 250,
	magazine = 6,
	reserve = 36,
	reloadTime = 2.2,
	emptyReloadTime = 2.2,
	recoil = { vertical = 3.0, horizontal = 0.7 },
	visual = { archetype = "Revolver", magazine = "internal" },
	sound = "Revolver",
})
add(PISTOL, {
	id = "HiPower",
	name = "Browning Hi-Power",
	factions = { "UK", "FR", "DE" }, -- Inglis (Canada) for the Allies, P 640(b) for Germany
	unlockLevel = 16,
	description = "13-round 9mm double-stack. The most capacity of any sidearm of the war.",
	damage = 30,
	rpm = 420,
	magazine = 13,
	reserve = 65,
	recoil = { vertical = 2.0, horizontal = 0.5 },
})
add(PISTOL, {
	id = "TT33",
	name = "Tokarev TT-33",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "Hot 7.62x25mm pistol with excellent penetration.",
	damage = 34,
	rpm = 400,
	magazine = 8,
	reserve = 48,
	penetration = 0.25,
	recoil = { vertical = 2.4, horizontal = 0.6 },
})
add(PISTOL, {
	id = "NagantM1895",
	name = "Nagant M1895",
	factions = { "USSR" },
	unlockLevel = 8,
	description = "Gas-seal revolver loaded one cartridge at a time. Accurate, painfully slow to reload.",
	damage = 42,
	rpm = 240,
	magazine = 7,
	reserve = 42,
	reloadType = "single",
	reloadTime = 0.45,
	emptyReloadTime = 0.7,
	adsSpread = 0.35,
	recoil = { vertical = 2.6, horizontal = 0.5 },
	visual = { archetype = "Revolver", magazine = "internal" },
	sound = "Revolver",
})
add(PISTOL, {
	id = "MABD",
	name = "MAB Modèle D",
	factions = { "FR" },
	unlockLevel = 1,
	description = "Compact 7.65mm French pistol with a 9-round magazine.",
	damage = 30,
	rpm = 450,
	magazine = 9,
	reserve = 54,
	recoil = { vertical = 1.8, horizontal = 0.5 },
})
add(PISTOL, {
	id = "MAS1935A",
	name = "MAS 1935A",
	factions = { "FR" },
	unlockLevel = 8,
	description = "Petter-designed French service pistol. Precise and light-recoiling.",
	damage = 32,
	rpm = 420,
	magazine = 8,
	reserve = 48,
	adsSpread = 0.35,
	recoil = { vertical = 1.8, horizontal = 0.4 },
})
add(PISTOL, {
	id = "P38",
	name = "Walther P38",
	factions = { "DE", "IT" },
	unlockLevel = 1,
	description = "Double-action 9mm service pistol of the Wehrmacht.",
	damage = 34,
	rpm = 400,
	magazine = 8,
	reserve = 48,
	recoil = { vertical = 2.2, horizontal = 0.5 },
})
add(PISTOL, {
	id = "LugerP08",
	name = "Luger P08",
	factions = { "DE" },
	unlockLevel = 8,
	description = "Toggle-locked 9mm Parabellum classic. Superb pointing, crisp trigger.",
	damage = 34,
	rpm = 450,
	magazine = 8,
	reserve = 48,
	adsSpread = 0.35,
	recoil = { vertical = 2.0, horizontal = 0.4 },
})
add(PISTOL, {
	id = "MauserM712",
	name = "Mauser M712 Schnellfeuer",
	factions = { "DE", "IT" },
	unlockLevel = 24,
	description = "Select-fire 'broomhandle' Mauser. A machine pistol for the brave.",
	damage = 28,
	rpm = 900,
	fireModes = { "Auto", "Semi" },
	magazine = 20,
	reserve = 80,
	reloadTime = 2.4,
	emptyReloadTime = 2.8,
	hipSpread = 2.6,
	recoil = { vertical = 1.5, horizontal = 1.1, firstShotMult = 1.2 },
	visual = { magazine = "box", length = 1.3 },
})
add(PISTOL, {
	id = "NambuType14",
	name = "Nambu Type 14",
	factions = { "JP" },
	unlockLevel = 1,
	description = "8mm Nambu service pistol. Mild recoil, light round.",
	damage = 31,
	rpm = 420,
	magazine = 8,
	reserve = 48,
	recoil = { vertical = 1.7, horizontal = 0.4 },
})
add(PISTOL, {
	id = "Type94Pistol",
	name = "Type 94 Pistol",
	factions = { "JP" },
	unlockLevel = 8,
	description = "Compact officer's pistol for aircrew and tankers. Very fast handling.",
	damage = 30,
	rpm = 450,
	magazine = 6,
	reserve = 48,
	equipTime = 0.25,
	adsTime = 0.14,
	reloadTime = 1.6,
	emptyReloadTime = 1.9,
	recoil = { vertical = 1.7, horizontal = 0.5 },
})
add(PISTOL, {
	id = "Type26Revolver",
	name = "Type 26 Revolver",
	factions = { "JP" },
	unlockLevel = 16,
	description = "Double-action-only top-break revolver dating back to 1893.",
	damage = 44,
	rpm = 260,
	magazine = 6,
	reserve = 36,
	reloadTime = 2.4,
	emptyReloadTime = 2.4,
	recoil = { vertical = 2.6, horizontal = 0.6 },
	visual = { archetype = "Revolver", magazine = "internal" },
	sound = "Revolver",
})
add(PISTOL, {
	id = "BerettaM1934",
	name = "Beretta M1934",
	factions = { "IT" },
	unlockLevel = 1,
	description = "Compact 9mm Corto pistol, standard issue for the Regio Esercito.",
	damage = 31,
	rpm = 440,
	magazine = 7,
	reserve = 49,
	recoil = { vertical = 1.8, horizontal = 0.4 },
})
add(PISTOL, {
	id = "GlisentiM1910",
	name = "Glisenti M1910",
	factions = { "IT" },
	unlockLevel = 8,
	description = "Great War Italian service pistol. Weak cartridge but very controllable.",
	damage = 28,
	rpm = 480,
	magazine = 7,
	reserve = 49,
	recoil = { vertical = 1.4, horizontal = 0.35 },
})

-------------------------------------------------------------------------------------------------
-- Grenades (magazine = carried count)
-------------------------------------------------------------------------------------------------

add(GRENADE, {
	id = "Mk2",
	name = "Mk 2 Fragmentation",
	factions = { "US" },
	unlockLevel = 1,
	description = "The 'pineapple'. Reliable 4.5-second fuse.",
	fuse = 4.5,
})
add(GRENADE, {
	id = "MillsBomb",
	name = "No.36M Mills Bomb",
	factions = { "UK" },
	unlockLevel = 1,
	description = "Segmented British grenade with a 4-second fuse.",
	fuse = 4.0,
})
add(GRENADE, {
	id = "RGD33",
	name = "RGD-33",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "Soviet stick grenade with a fragmentation sleeve: big blast radius.",
	fuse = 3.8,
	blastRadius = 20,
	throwSpeed = 88,
	visual = { archetype = "StickGrenade" },
})
add(GRENADE, {
	id = "F1Grenade",
	name = "F1 Grenade",
	factions = { "FR" },
	unlockLevel = 1,
	description = "French defensive fragmentation grenade, copied the world over.",
	fuse = 4.0,
	blastRadius = 19,
})
add(GRENADE, {
	id = "M24",
	name = "M24 Stielhandgranate",
	factions = { "DE" },
	unlockLevel = 1,
	description = "The 'potato masher'. The handle lets you throw it further than anything else.",
	fuse = 4.5,
	throwSpeed = 100,
	blastDamage = 140,
	visual = { archetype = "StickGrenade" },
})
add(GRENADE, {
	id = "Type97Grenade",
	name = "Type 97 Grenade",
	factions = { "JP" },
	unlockLevel = 1,
	description = "Striker-ignited Japanese frag with a short 4-second fuse.",
	fuse = 4.0,
})
add(GRENADE, {
	id = "OTOMod35",
	name = "OTO Mod. 35",
	factions = { "IT" },
	unlockLevel = 1,
	description = "Italian 'red devil' impact grenade: detonates on contact, smaller blast.",
	projectile = "impact",
	cookable = false,
	fuse = 6, -- safety: self-destructs if it never hits anything
	blastRadius = 14,
	blastDamage = 130,
})
add(GRENADE, {
	id = "M39Egg",
	name = "M39 Eihandgranate",
	factions = { "DE", "IT" },
	unlockLevel = 10,
	description = "Small egg grenade: you can carry three and throw them a long way.",
	magazine = 3,
	fuse = 4.0,
	blastRadius = 15,
	blastDamage = 130,
	throwSpeed = 95,
})
add(GRENADE, {
	id = "RG42",
	name = "RG-42",
	factions = { "USSR" },
	unlockLevel = 10,
	description = "Simple tin-can grenade with a 3.5-second fuse. Carry three.",
	magazine = 3,
	fuse = 3.5,
	blastRadius = 15,
	blastDamage = 130,
})
add(GRENADE, {
	id = "Gammon82",
	name = "No.82 Gammon Bomb",
	factions = { "UK", "US" },
	unlockLevel = 16,
	description = "Paratrooper's plastic-explosive bag with an impact fuze. Huge blast, carry one.",
	projectile = "impact",
	cookable = false,
	magazine = 1,
	fuse = 6,
	blastRadius = 22,
	blastDamage = 200,
	vehicleDamage = 160,
	throwSpeed = 70,
	visual = { archetype = "Satchel" },
})
add(GRENADE, {
	id = "Type99Grenade",
	name = "Type 99 Grenade",
	factions = { "JP" },
	unlockLevel = 10,
	description = "Smooth 'Kiska' grenade with a fast 4-second fuse. Carry three.",
	magazine = 3,
	fuse = 4.0,
	blastRadius = 15,
	blastDamage = 130,
})
add(GRENADE, {
	id = "SRCMMod35",
	name = "SRCM Mod. 35",
	factions = { "IT" },
	unlockLevel = 10,
	description = "Impact-fuzed Italian grenade. Carry three.",
	projectile = "impact",
	cookable = false,
	magazine = 3,
	fuse = 6,
	blastRadius = 13,
	blastDamage = 120,
})
add(GRENADE, {
	id = "F1Limonka",
	name = "F-1 'Limonka'",
	factions = { "USSR" },
	unlockLevel = 18,
	description = "Soviet copy of the French F1. Heavy fragmentation, wide radius.",
	fuse = 3.8,
	blastRadius = 22,
	blastDamage = 150,
})

-------------------------------------------------------------------------------------------------
-- Smoke
-------------------------------------------------------------------------------------------------

add(SMOKE, {
	id = "ANM8",
	name = "AN-M8 HC Smoke",
	factions = { "US", "FR" },
	unlockLevel = 1,
	description = "Thick white hexachloroethane smoke screen.",
})
add(SMOKE, {
	id = "No77WP",
	name = "No.77 WP Smoke",
	factions = { "UK" },
	unlockLevel = 1,
	description = "White phosphorus: bursts instantly into a dense cloud.",
	fuse = 0.6,
	projectile = "smoke",
	smokeDuration = 22,
	smokeRadius = 26,
})
add(SMOKE, {
	id = "RDG2",
	name = "RDG-2 Smoke",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "Friction-ignited Soviet smoke pot.",
	smokeDuration = 32,
})
add(SMOKE, {
	id = "NbHgr39",
	name = "Nebelhandgranate 39",
	factions = { "DE", "IT" },
	unlockLevel = 1,
	description = "Smoke stick grenade, marked with a white band.",
	throwSpeed = 95,
	visual = { archetype = "StickGrenade" },
})
add(SMOKE, {
	id = "Type94Smoke",
	name = "Type 94 Smoke Candle",
	factions = { "JP" },
	unlockLevel = 1,
	description = "Japanese smoke candle for screening assaults.",
	smokeDuration = 30,
	smokeRadius = 22,
})

-------------------------------------------------------------------------------------------------
-- Explosives (demolition)
-------------------------------------------------------------------------------------------------

add(EXPLOSIVE, {
	id = "SatchelCharge",
	name = "Satchel Charge",
	factions = ALL,
	unlockLevel = 1,
	description = "Bag of TNT with a 5-second pull fuse. Clears bunkers and cripples armor.",
})
add(EXPLOSIVE, {
	id = "GeballteLadung",
	name = "Geballte Ladung",
	factions = { "DE", "IT" },
	unlockLevel = 8,
	description = "Six grenade heads wired around a stick grenade. Throws further than a satchel.",
	projectile = "frag",
	fuse = 4.5,
	throwSpeed = 70,
	blastRadius = 20,
	blastDamage = 220,
	vehicleDamage = 380,
	visual = { archetype = "StickGrenade" },
})
add(EXPLOSIVE, {
	id = "StickyBomb",
	name = "No.74 Sticky Bomb",
	factions = { "UK", "FR" },
	unlockLevel = 8,
	description = "Adhesive-coated glass sphere of nitroglycerin. Sticks to anything it hits.",
	projectile = "sticky",
	fuse = 5,
	throwSpeed = 60,
	blastRadius = 14,
	blastDamage = 200,
	vehicleDamage = 500,
	magazine = 1,
	visual = { archetype = "FragGrenade" },
})
add(EXPLOSIVE, {
	id = "Type99Magnetic",
	name = "Type 99 Magnetic Mine",
	factions = { "JP" },
	unlockLevel = 8,
	description = "Hakobakurai: a magnet-backed charge that clings to vehicles and walls.",
	projectile = "sticky",
	fuse = 6,
	throwSpeed = 50,
	blastRadius = 14,
	blastDamage = 200,
	vehicleDamage = 520,
	magazine = 2,
})
add(EXPLOSIVE, {
	id = "C2Demolition",
	name = "M3 Demolition Block (C2)",
	factions = { "US", "USSR" }, -- lend-lease plastic explosive
	unlockLevel = 12,
	description = "Plastic explosive block with a 6-second fuse. The biggest bang you can carry.",
	fuse = 6,
	blastRadius = 25,
	blastDamage = 280,
	vehicleDamage = 550,
	magazine = 1,
})

-------------------------------------------------------------------------------------------------
-- Anti-tank
-------------------------------------------------------------------------------------------------

add(LAUNCHER, {
	id = "M1A1Bazooka",
	name = "M1A1 Bazooka",
	factions = { "US", "FR" },
	unlockLevel = 1,
	description = "2.36-inch rocket launcher. Shaped-charge warhead defeats most tank armor from the side.",
	reserve = 4,
})
add(LAUNCHER, {
	id = "M9Bazooka",
	name = "M9A1 Bazooka",
	factions = { "US", "FR" },
	unlockLevel = 14,
	description = "Improved two-piece Bazooka: faster rocket, better sight, quicker reload.",
	bulletVelocity = 300,
	reloadTime = 3.3,
	reserve = 4,
	adsTime = 0.4,
	vehicleDamage = 740,
	visual = { length = 5.4 },
})
add(LAUNCHER, {
	id = "PIAT",
	name = "PIAT",
	factions = { "UK", "FR" },
	unlockLevel = 1,
	description = "Spring-launched spigot mortar. No backblast, slow arcing bomb, hard-hitting.",
	bulletVelocity = 200,
	gravityScale = 0.45,
	reloadTime = 4.2,
	reserve = 4,
	vehicleDamage = 720,
	visual = { archetype = "PIAT", length = 3.4 },
})
add(AT_RIFLE, {
	id = "BoysATRifle",
	name = "Boys Anti-Tank Rifle",
	factions = { "UK" },
	unlockLevel = 10,
	description = ".55 calibre AT rifle with a 5-round magazine. Shreds light vehicles and infantry.",
	rpm = 40,
	magazine = 5,
	reserve = 25,
	reloadTime = 3.6,
	emptyReloadTime = 3.6,
	vehicleDamage = 110,
	visual = { magazine = "top" },
})
add(AT_GRENADE, {
	id = "RPG40",
	name = "RPG-40",
	factions = { "USSR" },
	unlockLevel = 1,
	description = "Heavy blast anti-tank hand grenade with an impact fuze.",
})
add(AT_RIFLE, {
	id = "PTRD41",
	name = "PTRD-41",
	factions = { "USSR" },
	unlockLevel = 10,
	description = "Single-shot 14.5mm anti-tank rifle. One round, one kill.",
	vehicleDamage = 150,
})
add(AT_GRENADE, {
	id = "RPG43",
	name = "RPG-43",
	factions = { "USSR" },
	unlockLevel = 18,
	description = "Shaped-charge AT grenade with a stabilising cloth drogue.",
	vehicleDamage = 620,
	blastDamage = 110,
})
add(LAUNCHER, {
	id = "Panzerfaust",
	name = "Panzerfaust 30",
	factions = { "DE", "IT" },
	unlockLevel = 1,
	description = "Disposable recoilless launcher. Short range, lobbed warhead, deadly against armor.",
	projectile = "rocket",
	bulletVelocity = 150,
	gravityScale = 0.5,
	range = 120,
	reserve = 2,
	reloadTime = 2.6, -- drop the tube, grab the next one
	vehicleDamage = 800,
	visual = { archetype = "Panzerfaust", length = 3.4 },
})
add(LAUNCHER, {
	id = "Panzerschreck",
	name = "Panzerschreck RPzB 54",
	factions = { "DE" },
	unlockLevel = 10,
	description = "88mm 'tank terror' with blast shield. The most powerful man-portable AT weapon.",
	bulletVelocity = 260,
	reloadTime = 4.0,
	reserve = 3,
	vehicleDamage = 820,
	adsTime = 0.5,
	walkSpeedMult = 0.9,
	visual = { length = 5.6, metalColor = FIELD_GREY },
})
add(AT_RIFLE, {
	id = "PzB39",
	name = "Panzerbüchse 39",
	factions = { "DE" },
	unlockLevel = 18,
	description = "7.92x94mm single-shot AT rifle. Fast reload, flat trajectory.",
	reloadTime = 2.0,
	emptyReloadTime = 2.0,
	vehicleDamage = 100,
})
add(AT_GRENADE, {
	id = "Type3AT",
	name = "Type 3 AT Grenade",
	factions = { "JP" },
	unlockLevel = 1,
	description = "Hand-thrown shaped charge with a hemp tail for stability.",
	vehicleDamage = 540,
})
add(AT_GRENADE, {
	id = "LungeMine",
	name = "Lunge Mine",
	factions = { "JP" },
	unlockLevel = 10,
	description = "Shaped charge on a pole. Used at point-blank range; enormous penetration.",
	throwSpeed = 28, -- "thrust" range only
	magazine = 1,
	vehicleDamage = 950,
	blastDamage = 140,
	blastRadius = 7,
	visual = { archetype = "Panzerfaust" },
})
add(AT_RIFLE, {
	id = "Type97ATRifle",
	name = "Type 97 20mm AT Rifle",
	factions = { "JP" },
	unlockLevel = 18,
	description = "Semi-automatic 20mm 'elephant gun' with a 7-round magazine.",
	fireModes = { "Semi" },
	rpm = 120,
	magazine = 7,
	reserve = 21,
	reloadTime = 4.2,
	emptyReloadTime = 4.6,
	vehicleDamage = 120,
	walkSpeedMult = 0.82,
	visual = { magazine = "top", length = 6.4 },
})
add(AT_RIFLE, {
	id = "SolothurnS18",
	name = "Solothurn S-18/1000",
	factions = { "IT", "DE" },
	unlockLevel = 12,
	description = "Swiss-made semi-auto 20mm AT rifle with a 10-round side magazine.",
	fireModes = { "Semi" },
	rpm = 120,
	magazine = 10,
	reserve = 20,
	reloadTime = 4.4,
	emptyReloadTime = 4.8,
	vehicleDamage = 120,
	walkSpeedMult = 0.82,
	visual = { magazine = "side", length = 6.6 },
})

-------------------------------------------------------------------------------------------------
-- Gadgets (used by GadgetService/GadgetController; Combat only equips them)
-------------------------------------------------------------------------------------------------

add(GADGET, {
	id = "FieldMedkit",
	name = "Field Medkit",
	category = "Medkit",
	factions = ALL,
	unlockLevel = 1,
	description = "Bandages and morphine. Heal teammates and yourself.",
	magazine = 1,
	visual = { archetype = "Medkit", magazine = "none" },
})
add(GADGET, {
	id = "AmmoCrate",
	name = "Ammunition Crate",
	category = "AmmoBox",
	factions = ALL,
	unlockLevel = 1,
	description = "Deployable crate of mixed ammunition for the squad.",
	magazine = 1,
	visual = { archetype = "AmmoBox", magazine = "none" },
})
add(GADGET, {
	id = "RepairTool",
	name = "Repair Tool",
	category = "Repair",
	factions = ALL,
	unlockLevel = 1,
	description = "Wrench and welding kit for patching up friendly vehicles.",
	visual = { archetype = "Wrench", magazine = "none" },
})
add(GADGET, {
	id = "Binoculars",
	name = "Binoculars",
	category = "Binoculars",
	factions = ALL,
	unlockLevel = 1,
	description = "6x30 field glasses. Aim to zoom and spot enemies for your team.",
	adsTime = 0.3,
	adsZoom = 0.2,
	scope = true,
	visual = { archetype = "Binoculars", magazine = "none" },
})

-------------------------------------------------------------------------------------------------
-- Melee (always given)
-------------------------------------------------------------------------------------------------

add(NONFIRE, {
	id = "Knife",
	name = "Combat Knife",
	category = "Melee",
	factions = ALL,
	unlockLevel = 1,
	description = "Fighting knife. Two slashes to kill, or one from behind.",
	damage = 55,
	meleeRange = 6,
	meleeCooldown = 0.65,
	equipTime = 0.3,
	walkSpeedMult = 1.05,
	visual = { archetype = "Knife", magazine = "none" },
	sound = "Melee",
})

-------------------------------------------------------------------------------------------------
-- API
-------------------------------------------------------------------------------------------------

local THROWABLE = { Grenade = true, Smoke = true, Explosive = true }
local GADGET_CATEGORIES = { Medkit = true, AmmoBox = true, Repair = true, Binoculars = true }

local module = {
	byId = byId,
	order = order,
	MELEE_ID = "Knife",
	THROWABLE_CATEGORIES = THROWABLE,
	GADGET_CATEGORIES = GADGET_CATEGORIES,
}

function module.get(id: string): Weapon?
	return byId[id]
end

local function hasFaction(w: Weapon, factionId: string?): boolean
	if not factionId then
		return true
	end
	return table.find(w.factions, factionId) ~= nil
end

-- All weapons of a category (optionally restricted to a faction), in registry order.
function module.forCategory(category: string, factionId: string?): { Weapon }
	local list = {}
	for _, id in order do
		local w = byId[id]
		if w.category == category and hasFaction(w, factionId) then
			table.insert(list, w)
		end
	end
	return list
end

-- Weapons usable in a class slot for a faction at a level (Classes.luau slot categories).
-- `level` nil = ignore unlocks. Sorted by unlockLevel then registry order.
function module.available(classId: string, slot: string, factionId: string?, level: number?): { Weapon }
	local Classes = require(script.Parent.Classes)
	local class = Classes.get(classId)
	if not class then
		return {}
	end
	local categories = (class.slots :: any)[slot]
	if not categories then
		return {}
	end
	local list = {}
	for _, id in order do
		local w = byId[id]
		if
			table.find(categories, w.category)
			and hasFaction(w, factionId)
			and (level == nil or w.unlockLevel <= level)
		then
			table.insert(list, w)
		end
	end
	table.sort(list, function(a, b)
		if a.unlockLevel ~= b.unlockLevel then
			return a.unlockLevel < b.unlockLevel
		end
		return (table.find(order, a.id) or 0) < (table.find(order, b.id) or 0)
	end)
	return list
end

-- True when `weaponId` is legal in `slot` for class/faction/level (server-side loadout validation).
function module.isAllowed(weaponId: string, classId: string, slot: string, factionId: string?, level: number?): boolean
	for _, w in module.available(classId, slot, factionId, level) do
		if w.id == weaponId then
			return true
		end
	end
	return false
end

-- Default level-1 loadout for a class + faction: {primary, secondary, gadget1, gadget2}.
function module.defaultLoadout(classId: string, factionId: string): { [string]: string }
	local loadout = {}
	for _, slot in { "primary", "secondary", "gadget1", "gadget2" } do
		local list = module.available(classId, slot, factionId, 1)
		loadout[slot] = if list[1] then list[1].id else ""
	end
	return loadout
end

-- Weapon is thrown by hand (grenade/smoke/explosive or thrown AT grenade).
function module.isThrown(w: Weapon): boolean
	return THROWABLE[w.category] == true or w.projectile == "impact" and w.category == "AntiTank"
end

-- Weapon fires a rocket via Combat_Throw (launcher).
function module.isLauncher(w: Weapon): boolean
	return w.projectile == "rocket"
end

-- Weapon fires hitscan bullets via Combat_Fire.
function module.isFirearm(w: Weapon): boolean
	return w.projectile == nil and w.damage > 0 and w.category ~= "Melee" and not GADGET_CATEGORIES[w.category]
end

function module.isGadget(w: Weapon): boolean
	return GADGET_CATEGORIES[w.category] == true
end

return module
