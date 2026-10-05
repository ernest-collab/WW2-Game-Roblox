--[[
	Classes (roles). A loadout is: primary, secondary, gadget1, gadget2 (+ a knife for everyone).
	Allowed weapons for a slot = Weapons whose `category` is in the slot's category list,
	whose `factions` include the player's faction, and whose `unlockLevel` <= player level.

	Weapon categories (Weapons.luau `category`):
	  Firearms: "AssaultRifle" "SMG" "BoltAction" "SemiAuto" "MachineGun" "Pistol" "Shotgun" "Sniper"
	  Throwables / launchers: "Grenade" "Smoke" "AntiTank" "Explosive"
	  Gadgets (gameplay-service driven): "Medkit" "AmmoBox" "Repair" "Binoculars"
	  Always given: "Melee"
]]

export type ClassDef = {
	id: string,
	name: string,
	description: string,
	icon: string, -- short glyph for UI if no image: e.g. "RFL"
	slots: {
		primary: { string },
		secondary: { string },
		gadget1: { string },
		gadget2: { string },
	},
	maxHealth: number,
	speedMultiplier: number,
	unlockLevel: number,
	perks: { string }, -- informational tags read by gameplay code
}

local Classes: { [string]: ClassDef } = {
	Rifleman = {
		id = "Rifleman",
		name = "Rifleman",
		description = "Backbone of the infantry. Accurate rifles and extra grenades. Captures objectives faster.",
		icon = "RFL",
		slots = {
			primary = { "SemiAuto", "BoltAction" },
			secondary = { "Pistol" },
			gadget1 = { "Grenade" },
			gadget2 = { "Smoke", "Explosive" },
		},
		maxHealth = 100,
		speedMultiplier = 1.0,
		unlockLevel = 1,
		perks = { "FastCapture", "ExtraGrenade" },
	},
	Assault = {
		id = "Assault",
		name = "Assault",
		description = "Close-quarters shock trooper with submachine guns, assault rifles and shotguns.",
		icon = "AST",
		slots = {
			primary = { "SMG", "AssaultRifle", "Shotgun" },
			secondary = { "Pistol" },
			gadget1 = { "Grenade" },
			gadget2 = { "Smoke" },
		},
		maxHealth = 100,
		speedMultiplier = 1.05,
		unlockLevel = 1,
		perks = { "FasterSprint" },
	},
	Support = {
		id = "Support",
		name = "Support",
		description = "Machine gunner who suppresses the enemy and resupplies teammates with ammo crates.",
		icon = "SUP",
		slots = {
			primary = { "MachineGun" },
			secondary = { "Pistol" },
			gadget1 = { "AmmoBox" },
			gadget2 = { "Grenade" },
		},
		maxHealth = 100,
		speedMultiplier = 0.92,
		unlockLevel = 1,
		perks = { "Resupply" },
	},
	Medic = {
		id = "Medic",
		name = "Medic",
		description = "Keeps the squad fighting. Heals teammates and revives the wounded.",
		icon = "MED",
		slots = {
			primary = { "SMG", "SemiAuto" },
			secondary = { "Pistol" },
			gadget1 = { "Medkit" },
			gadget2 = { "Smoke" },
		},
		maxHealth = 100,
		speedMultiplier = 1.0,
		unlockLevel = 1,
		perks = { "Heal", "FullRegen" },
	},
	Engineer = {
		id = "Engineer",
		name = "Engineer",
		description = "Anti-tank specialist. Repairs friendly vehicles and destroys enemy armor.",
		icon = "ENG",
		slots = {
			primary = { "SMG", "Shotgun", "BoltAction" },
			secondary = { "Pistol" },
			gadget1 = { "AntiTank" },
			gadget2 = { "Repair", "Explosive" },
		},
		maxHealth = 100,
		speedMultiplier = 0.97,
		unlockLevel = 1,
		perks = { "Repair" },
	},
	Recon = {
		id = "Recon",
		name = "Recon",
		description = "Long-range marksman. Spots enemies for the whole team with binoculars.",
		icon = "RCN",
		slots = {
			primary = { "Sniper", "BoltAction" },
			secondary = { "Pistol" },
			gadget1 = { "Binoculars" },
			gadget2 = { "Explosive", "Smoke" },
		},
		maxHealth = 100,
		speedMultiplier = 1.0,
		unlockLevel = 1,
		perks = { "Spotting" },
	},
}

local ORDER = { "Rifleman", "Assault", "Support", "Medic", "Engineer", "Recon" }

local module = { byId = Classes, order = ORDER }

function module.get(id: string): ClassDef?
	return Classes[id]
end

return module
