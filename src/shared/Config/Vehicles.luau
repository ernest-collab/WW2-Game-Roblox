--[[
	Vehicles: every drivable vehicle and emplaced gun, per faction. Owned by the Vehicle team.
	Read by VehicleService (server, authoritative), VehicleController (client prediction/HUD),
	VehicleModels (procedural models, seat layout) and Progression (unlock track).

		local Vehicles = require(Shared.Config.Vehicles)
		Vehicles.get("M4Sherman")                -> VehicleDef?
		Vehicles.forFaction("DE", "Tank")        -> {VehicleDef}  (sorted by unlockLevel, then order)
		Vehicles.byId / Vehicles.order

	Units: distances/speeds in studs (1 stud ~ 0.28 m), angles in degrees, times in seconds.

	=============================================================================================
	DAMAGE MODEL (implemented by VehicleService.ApplyDamage; constants in Vehicles.DAMAGE)
	=============================================================================================
	Every vehicle has `maxHealth` and an armor rating per facing `armor = {front, side, rear, top}`
	(mm-like "effective" thickness that already includes the vehicle's typical slope).

	Facing is decided from where the hit came from, in the vehicle's local frame:
	  * shells (direction known): the incoming direction's yaw vs the hull forward axis
	    (|yaw| <= 50 deg front, >= 130 deg rear, else side; steeply from above = top);
	  * explosions / rockets (only a position known): the hit position relative to hull centre.

	1. Tank shells (Vehicle_Fire "main", carry `penetration`):
	     effective = armor[facing] * angleFactor,  angleFactor = 1 / max(cos(impact), 0.35)^0.6
	     (impact = angle between shell path and the struck surface normal; softened for arcade)
	     impact >= RICOCHET_ANGLE and penetration < effective * 1.5   -> RICOCHET   (no damage)
	     penetration >= effective                                     -> PENETRATION
	         damage = shell.damage * PEN_FACING_MULT[facing]  (front 1.0, side 1.15, rear 1.35)
	     otherwise                                                    -> NON-PENETRATION
	         damage = shell.damage * NONPEN_FRACTION[shell.kind]  (AP 10 %, HE 30 %)
	   e.g. a 75 mm AP round (600 dmg) kills a 2000 hp medium tank in 4 frontal / 3 side or rear pens.

	2. Infantry anti-tank weapons / explosions (CombatService -> ApplyDamage with opts.explosive):
	     damage = amount * EXPLOSIVE_FACING_MULT[facing] (front 0.6, side 1.0, rear 1.4, top 1.4)
	     If opts.penetration is supplied too (HEAT), a hit that fails to beat armor[facing] only deals
	     HEAT_NONPEN_FRACTION (25 %).
	   With Weapons.vehicleDamage ~500 per rocket a medium tank (1700-2200 hp) dies to 4 side hits,
	   3 rear hits and ~7 frontal hits; heavies (2400-2600 hp) need 5-6 side / 4 rear hits.

	3. Bullets / vehicle machine guns (opts.penetration supplied, not explosive):
	     penetration >= armor[facing] -> amount * PEN_FACING_MULT[facing], else 0.
	   Plain calls with neither penetration nor explosive (e.g. rifle hits) are scaled by the
	   vehicle's `smallArmsMult` (0 for armored vehicles, ~0.3 for soft-skins).

	Below CRITICAL_FRACTION (25 %) health a vehicle smokes, its top speed drops to
	CRITICAL_SPEED_MULT and it shows "Critical" on the HUD. Engineers repair via GadgetService ->
	VehicleService.Repair. At 0 hp the vehicle explodes; every occupant is killed (attributed to the
	attacker) and the burning wreck despawns after WRECK_TIME seconds. Friendly fire never damages
	vehicles.

	Weapons (`weapons.main` / `weapons.coax` / `weapons.hullMG`):
	  main  : cannon. `ammo` is a list of shells (index 1 = default, usually AP; 2 = alt, usually HE).
	          Switching ammo costs a full reload. `magazine` > 1 for autocannons (fireInterval between
	          shots, `reload` after the magazine is emptied).
	  coax  : machine gun fixed to the main gun (uses the turret's aim).
	  hullMG: bow / pintle machine gun with its own aim cone (`yawLimit`, `pitchMin`, `pitchMax`
	          relative to the hull).
	Seats: `role` "driver" (drives AND aims/fires the turret, arcade style), "gunner" (hullMG),
	"passenger". `weapons` = {primary (MB1), secondary (Space)}. `exposed` = occupant visible and
	shootable (jeeps/trucks) vs hidden inside the armor (tanks).
]]

export type ShellDef = {
	kind: "AP" | "HE",
	name: string,
	penetration: number, -- armor rating defeated at a perpendicular impact
	damage: number, -- vehicle damage on penetration (before facing multiplier)
	velocity: number, -- muzzle velocity, studs/s
	gravityScale: number, -- fraction of workspace.Gravity applied to the shell
	splashRadius: number, -- infantry blast radius (studs)
	splashDamage: number, -- max infantry blast damage
	splashVehicle: number, -- blast damage to vehicles (other than the one directly hit)
	directDamage: number, -- damage to an infantryman hit directly
}

export type MainGunDef = {
	name: string,
	reload: number,
	magazine: number?, -- autocannons: rounds per magazine (nil/1 = single shot)
	fireInterval: number?, -- autocannons: seconds between rounds
	spread: number?, -- degrees
	shake: number, -- camera shake magnitude for the crew when firing
	recoil: number, -- recoil impulse scale (multiplied by vehicle mass)
	ammo: { ShellDef },
}

export type MGDef = {
	name: string,
	damage: number, -- per bullet vs infantry (at close range)
	rpm: number,
	range: number,
	spread: number, -- degrees
	magazine: number, -- belt size
	reload: number,
	heatPerShot: number, -- 0..1 heat added per shot
	coolRate: number, -- heat removed per second
	overheatTime: number, -- lockout when heat reaches 1
	penetration: number, -- armor rating (thin-skinned vehicles only)
	vehicleDamage: number,
	yawLimit: number?, -- hullMG: half-cone around the hull forward axis (180 = all round)
	pitchMin: number?,
	pitchMax: number?,
}

export type SeatDef = {
	id: string, -- "Driver" (model seat "DriverSeat"), "Gunner", "Passenger1".. (model seat named by id)
	role: "driver" | "gunner" | "passenger",
	exposed: boolean,
	weapons: { string }?,
}

export type VehicleDef = {
	id: string,
	name: string,
	class: "Tank" | "Light" | "Transport" | "Jeep" | "AT",
	factions: { string },
	description: string,
	unlockLevel: number, -- level required to DRIVE it (anyone may ride)
	respawnTime: number,
	maxHealth: number,
	armor: { front: number, side: number, rear: number, top: number },
	smallArmsMult: number,
	tracked: boolean,
	static: boolean?, -- emplaced gun: anchored, cannot drive
	speed: number, -- top forward speed (studs/s)
	reverseSpeed: number,
	acceleration: number, -- studs/s^2
	turnRate: number, -- hull yaw rate (deg/s); tracked vehicles pivot in place
	turretTraverse: number, -- deg/s (0 = no turret)
	elevationSpeed: number, -- deg/s
	gunElevation: { min: number, max: number },
	turretYawLimit: number?, -- half-arc for limited-traverse guns (nil = 360)
	weapons: { main: MainGunDef?, coax: MGDef?, hullMG: MGDef? },
	seats: { SeatDef },
}

---------------------------------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------------------------------

local function AP(penetration: number, damage: number, velocity: number?): ShellDef
	return {
		kind = "AP",
		name = "AP",
		penetration = penetration,
		damage = damage,
		velocity = velocity or 950,
		gravityScale = 0.2,
		splashRadius = 4,
		splashDamage = 40,
		splashVehicle = 0,
		directDamage = 220,
	}
end

local function HE(caliber: number): ShellDef
	-- Scales with caliber (mm): bigger gun, bigger blast.
	return {
		kind = "HE",
		name = "HE",
		penetration = math.floor(caliber * 0.35),
		damage = math.floor(caliber * 6),
		velocity = 650,
		gravityScale = 0.3,
		splashRadius = math.clamp(caliber * 0.16, 5, 15),
		splashDamage = math.clamp(caliber * 1.7, 60, 150),
		splashVehicle = math.floor(caliber * 1.2),
		directDamage = 300,
	}
end

-- Autocannon AP round (fast, flat, weak).
local function AC(penetration: number, damage: number): ShellDef
	local s = AP(penetration, damage, 1050)
	s.splashRadius = 2.5
	s.splashDamage = 25
	s.directDamage = 70
	s.gravityScale = 0.15
	return s
end

local function MG(name: string, damage: number, rpm: number, opts: { [string]: any }?): MGDef
	local def: MGDef = {
		name = name,
		damage = damage,
		rpm = rpm,
		range = 650,
		spread = 1.1,
		magazine = 150,
		reload = 4.5,
		heatPerShot = 0.018,
		coolRate = 0.3,
		overheatTime = 3,
		penetration = 8,
		vehicleDamage = 6,
	}
	if opts then
		for k, v in opts do
			(def :: any)[k] = v
		end
	end
	return def
end

-- Machine guns by nation. `o` overrides individual fields.
local function merged(base: { [string]: any }, o: { [string]: any }?): { [string]: any }
	local out = table.clone(base)
	if o then
		for k, v in o do
			out[k] = v
		end
	end
	return out
end
local function M1919(o: { [string]: any }?): MGDef
	return MG("M1919 .30", 19, 500, o)
end
local function M2HB(o: { [string]: any }?): MGDef
	return MG(
		"M2 .50",
		28,
		450,
		merged({ penetration = 18, vehicleDamage = 14, magazine = 100, heatPerShot = 0.022 }, o)
	)
end
local function BESA(o: { [string]: any }?): MGDef
	return MG("BESA 7.92", 19, 600, o)
end
local function BREN(o: { [string]: any }?): MGDef
	return MG("Bren", 21, 520, merged({ magazine = 30, reload = 3.2 }, o))
end
local function DT(o: { [string]: any }?): MGDef
	return MG("DT", 18, 600, merged({ magazine = 63, reload = 3.5 }, o))
end
local function REIBEL(o: { [string]: any }?): MGDef
	return MG("Reibel", 18, 650, o)
end
local function MG34(o: { [string]: any }?): MGDef
	return MG("MG 34", 20, 800, o)
end
local function TYPE97(o: { [string]: any }?): MGDef
	return MG("Type 97", 18, 500, o)
end
local function BREDA38(o: { [string]: any }?): MGDef
	return MG("Breda 38", 20, 460, o)
end

-- Hull (bow) MG cone, pintle mounts.
local BOW = { yawLimit = 30, pitchMin = -10, pitchMax = 18 }
local PINTLE = { yawLimit = 180, pitchMin = -12, pitchMax = 45 }
local RING = { yawLimit = 150, pitchMin = -10, pitchMax = 50 }

local function withCone(gun: MGDef, cone: { [string]: number }): MGDef
	for k, v in cone do
		(gun :: any)[k] = v
	end
	return gun
end

-- Seat layouts.
local function tankSeats(hasBowMG: boolean): { SeatDef }
	local seats: { SeatDef } = {
		{ id = "Driver", role = "driver", exposed = false, weapons = { "main", "coax" } },
	}
	if hasBowMG then
		table.insert(seats, { id = "Gunner", role = "gunner", exposed = false, weapons = { "hullMG" } })
	end
	return seats
end

local function passengerSeats(seats: { SeatDef }, count: number, exposed: boolean): { SeatDef }
	for i = 1, count do
		table.insert(seats, { id = "Passenger" .. i, role = "passenger", exposed = exposed })
	end
	return seats
end

local function jeepSeats(): { SeatDef }
	return passengerSeats({
		{ id = "Driver", role = "driver", exposed = true, weapons = {} },
		{ id = "Gunner", role = "gunner", exposed = true, weapons = { "hullMG" } },
	}, 2, true)
end

local function truckSeats(passengers: number): { SeatDef }
	return passengerSeats({ { id = "Driver", role = "driver", exposed = true, weapons = {} } }, passengers, true)
end

local function halftrackSeats(passengers: number): { SeatDef }
	return passengerSeats({
		{ id = "Driver", role = "driver", exposed = true, weapons = {} },
		{ id = "Gunner", role = "gunner", exposed = true, weapons = { "hullMG" } },
	}, passengers, true)
end

local function atSeats(): { SeatDef }
	return { { id = "Driver", role = "driver", exposed = true, weapons = { "main" } } }
end

-- Common stat blocks by archetype (copied then overridden per vehicle).
local ARCHETYPE = {
	HeavyTank = {
		class = "Tank",
		tracked = true,
		smallArmsMult = 0,
		speed = 22,
		reverseSpeed = 9,
		acceleration = 9,
		turnRate = 26,
		turretTraverse = 20,
		elevationSpeed = 10,
		gunElevation = { min = -8, max = 17 },
		respawnTime = 90,
	},
	MediumTank = {
		class = "Tank",
		tracked = true,
		smallArmsMult = 0,
		speed = 30,
		reverseSpeed = 11,
		acceleration = 12,
		turnRate = 38,
		turretTraverse = 30,
		elevationSpeed = 14,
		gunElevation = { min = -9, max = 20 },
		respawnTime = 60,
	},
	LightTank = {
		class = "Light",
		tracked = true,
		smallArmsMult = 0,
		speed = 38,
		reverseSpeed = 14,
		acceleration = 16,
		turnRate = 55,
		turretTraverse = 45,
		elevationSpeed = 20,
		gunElevation = { min = -10, max = 25 },
		respawnTime = 45,
	},
	ArmoredCar = {
		class = "Light",
		tracked = false,
		smallArmsMult = 0,
		speed = 50,
		reverseSpeed = 16,
		acceleration = 18,
		turnRate = 55,
		turretTraverse = 55,
		elevationSpeed = 24,
		gunElevation = { min = -10, max = 30 },
		respawnTime = 40,
	},
	Jeep = {
		class = "Jeep",
		tracked = false,
		smallArmsMult = 0.35,
		speed = 62,
		reverseSpeed = 20,
		acceleration = 26,
		turnRate = 75,
		turretTraverse = 0,
		elevationSpeed = 0,
		gunElevation = { min = 0, max = 0 },
		respawnTime = 20,
	},
	Truck = {
		class = "Transport",
		tracked = false,
		smallArmsMult = 0.25,
		speed = 46,
		reverseSpeed = 14,
		acceleration = 15,
		turnRate = 45,
		turretTraverse = 0,
		elevationSpeed = 0,
		gunElevation = { min = 0, max = 0 },
		respawnTime = 30,
	},
	Halftrack = {
		class = "Transport",
		tracked = true, -- rear tracks: steers like a tracked vehicle at low speed in arcade terms
		smallArmsMult = 0.08,
		speed = 42,
		reverseSpeed = 13,
		acceleration = 14,
		turnRate = 42,
		turretTraverse = 0,
		elevationSpeed = 0,
		gunElevation = { min = 0, max = 0 },
		respawnTime = 35,
	},
	ATGun = {
		class = "AT",
		tracked = false,
		static = true,
		smallArmsMult = 0.4,
		speed = 0,
		reverseSpeed = 0,
		acceleration = 0,
		turnRate = 0,
		turretTraverse = 22,
		elevationSpeed = 12,
		gunElevation = { min = -6, max = 15 },
		turretYawLimit = 32,
		respawnTime = 30,
	},
}

local Vehicles: { [string]: VehicleDef } = {}
local ORDER: { string } = {}

local function def(archetype: string, fields: { [string]: any })
	local base = ARCHETYPE[archetype]
	assert(base, archetype)
	local d: any = table.clone(base)
	d.gunElevation = table.clone(base.gunElevation)
	for k, v in fields do
		d[k] = v
	end
	d.weapons = d.weapons or {}
	d.unlockLevel = d.unlockLevel or 1
	d.armor.top = d.armor.top or math.max(8, math.floor(d.armor.rear * 0.5))
	assert(d.id and d.name and d.factions and d.maxHealth and d.seats, "incomplete vehicle def")
	Vehicles[d.id] = d
	table.insert(ORDER, d.id)
end

---------------------------------------------------------------------------------------------------
-- United States
---------------------------------------------------------------------------------------------------

def("MediumTank", {
	id = "M4Sherman",
	name = "M4A3 Sherman",
	factions = { "US" },
	description = "Reliable all-rounder with a fast power traverse and a useful HE round.",
	maxHealth = 2000,
	armor = { front = 90, side = 45, rear = 38 },
	speed = 31,
	turretTraverse = 36,
	weapons = {
		main = {
			name = "75mm M3",
			reload = 4.2,
			shake = 0.7,
			recoil = 5,
			ammo = { AP(95, 600, 900), HE(75) },
		},
		coax = M1919(),
		hullMG = withCone(M1919(), BOW),
	},
	seats = tankSeats(true),
})

def("LightTank", {
	id = "M5Stuart",
	name = "M5A1 Stuart",
	factions = { "US" },
	description = "Fast, nimble light tank. Its 37mm only threatens enemy armor from the flanks.",
	maxHealth = 1400,
	armor = { front = 50, side = 28, rear = 25 },
	speed = 40,
	weapons = {
		main = { name = "37mm M6", reload = 2.4, shake = 0.4, recoil = 2.5, ammo = { AP(60, 330, 1000), HE(37) } },
		coax = M1919(),
		hullMG = withCone(M1919(), BOW),
	},
	seats = tankSeats(true),
	unlockLevel = 3,
})

def("ArmoredCar", {
	id = "M8Greyhound",
	name = "M8 Greyhound",
	factions = { "US" },
	description = "Six-wheeled scout car with a 37mm gun and a ring-mounted .50 cal.",
	maxHealth = 1200,
	armor = { front = 25, side = 14, rear = 12 },
	speed = 52,
	weapons = {
		main = { name = "37mm M6", reload = 2.4, shake = 0.4, recoil = 2.5, ammo = { AP(60, 330, 1000), HE(37) } },
		coax = M1919(),
		hullMG = withCone(M2HB(), RING),
	},
	seats = passengerSeats({
		{ id = "Driver", role = "driver", exposed = false, weapons = { "main", "coax" } },
		{ id = "Gunner", role = "gunner", exposed = true, weapons = { "hullMG" } },
	}, 1, false),
	unlockLevel = 5,
})

def("Jeep", {
	id = "WillysMB",
	name = "Willys MB",
	factions = { "US" },
	description = "Light utility truck with a pintle-mounted M1919. Fast, fragile, everywhere.",
	maxHealth = 650,
	armor = { front = 4, side = 2, rear = 2 },
	weapons = { hullMG = withCone(M1919(), PINTLE) },
	seats = jeepSeats(),
})

def("Halftrack", {
	id = "M3Halftrack",
	name = "M3 Halftrack",
	factions = { "US" },
	description = "Armored personnel carrier with a ring-mounted .50 cal. Carries a squad.",
	maxHealth = 1300,
	armor = { front = 16, side = 8, rear = 8 },
	weapons = { hullMG = withCone(M2HB(), RING) },
	seats = halftrackSeats(6),
})

def("Truck", {
	id = "GMCTruck",
	name = "GMC CCKW",
	factions = { "US" },
	description = "The 'Deuce and a Half'. Moves eight soldiers to the front.",
	maxHealth = 1000,
	armor = { front = 3, side = 2, rear = 2 },
	seats = truckSeats(7),
	unlockLevel = 2,
})

def("ATGun", {
	id = "M1_57mm",
	name = "57mm M1 AT Gun",
	factions = { "US" },
	description = "Emplaced anti-tank gun. Limited traverse, hard-hitting.",
	maxHealth = 600,
	armor = { front = 10, side = 2, rear = 2 },
	weapons = { main = { name = "57mm M1", reload = 4.0, shake = 0.5, recoil = 0, ammo = { AP(110, 560, 1000), HE(57) } } },
	seats = atSeats(),
})

---------------------------------------------------------------------------------------------------
-- United Kingdom
---------------------------------------------------------------------------------------------------

def("MediumTank", {
	id = "Cromwell",
	name = "Cromwell Mk IV",
	factions = { "UK" },
	description = "The fastest cruiser tank of the war. Hit and run.",
	maxHealth = 1900,
	armor = { front = 80, side = 40, rear = 32 },
	speed = 36,
	acceleration = 14,
	turretTraverse = 34,
	weapons = {
		main = { name = "QF 75mm", reload = 4.0, shake = 0.7, recoil = 5, ammo = { AP(92, 580, 900), HE(75) } },
		coax = BESA(),
		hullMG = withCone(BESA(), BOW),
	},
	seats = tankSeats(true),
})

def("HeavyTank", {
	id = "Churchill",
	name = "Churchill Mk VII",
	factions = { "UK" },
	description = "Infantry tank with immense armor and a modest gun. Slow but very hard to stop.",
	maxHealth = 2600,
	armor = { front = 130, side = 90, rear = 60 },
	speed = 20,
	turretTraverse = 24,
	weapons = {
		main = { name = "QF 75mm", reload = 4.6, shake = 0.7, recoil = 4, ammo = { AP(92, 560, 900), HE(75) } },
		coax = BESA(),
		hullMG = withCone(BESA(), BOW),
	},
	seats = tankSeats(true),
	unlockLevel = 10,
})

def("ArmoredCar", {
	id = "DaimlerAC",
	name = "Daimler Armoured Car",
	factions = { "UK" },
	description = "Quick reconnaissance car carrying a 2-pounder anti-tank gun.",
	maxHealth = 1100,
	armor = { front = 22, side = 14, rear = 12 },
	weapons = {
		main = { name = "QF 2-pdr", reload = 2.5, shake = 0.4, recoil = 2.5, ammo = { AP(70, 340, 1050), HE(40) } },
		coax = BESA(),
	},
	seats = passengerSeats({ { id = "Driver", role = "driver", exposed = false, weapons = { "main", "coax" } } }, 1, false),
})

def("Jeep", {
	id = "UniversalCarrier",
	name = "Universal Carrier",
	factions = { "UK" },
	description = "Small tracked carrier with a Bren gun. Shrugs off rifle fire from the front.",
	maxHealth = 800,
	armor = { front = 10, side = 7, rear = 7 },
	tracked = true,
	speed = 46,
	smallArmsMult = 0.1,
	weapons = { hullMG = withCone(BREN(), { yawLimit = 60, pitchMin = -10, pitchMax = 30 }) },
	seats = jeepSeats(),
})

def("Truck", {
	id = "BedfordQL",
	name = "Bedford QL",
	factions = { "UK" },
	description = "Four-wheel-drive army lorry.",
	maxHealth = 1000,
	armor = { front = 3, side = 2, rear = 2 },
	seats = truckSeats(7),
})

def("ATGun", {
	id = "QF6Pounder",
	name = "QF 6-Pounder",
	factions = { "UK" },
	description = "Emplaced anti-tank gun with a low profile.",
	maxHealth = 600,
	armor = { front = 10, side = 2, rear = 2 },
	weapons = { main = { name = "QF 6-pdr", reload = 3.8, shake = 0.5, recoil = 0, ammo = { AP(110, 550, 1050), HE(57) } } },
	seats = atSeats(),
})

---------------------------------------------------------------------------------------------------
-- Soviet Union
---------------------------------------------------------------------------------------------------

def("MediumTank", {
	id = "T34_85",
	name = "T-34-85",
	factions = { "USSR" },
	description = "Sloped armor, wide tracks and an 85mm gun. Excellent cross-country.",
	maxHealth = 2000,
	armor = { front = 100, side = 55, rear = 45 },
	speed = 34,
	turretTraverse = 28,
	weapons = {
		main = { name = "85mm ZiS-S-53", reload = 5.2, shake = 0.8, recoil = 6, ammo = { AP(135, 650, 950), HE(85) } },
		coax = DT(),
		hullMG = withCone(DT(), BOW),
	},
	seats = tankSeats(true),
})

def("HeavyTank", {
	id = "KV1",
	name = "KV-1",
	factions = { "USSR" },
	description = "Heavily armored breakthrough tank. Its 76mm gun struggles against late-war armor.",
	maxHealth = 2600,
	armor = { front = 110, side = 80, rear = 65 },
	turretTraverse = 22,
	weapons = {
		main = { name = "76mm ZiS-5", reload = 5.0, shake = 0.75, recoil = 5, ammo = { AP(98, 600, 900), HE(76) } },
		coax = DT(),
		hullMG = withCone(DT(), BOW),
	},
	seats = tankSeats(true),
	unlockLevel = 8,
})

def("ArmoredCar", {
	id = "BA64",
	name = "BA-64",
	factions = { "USSR" },
	description = "Tiny, steeply sloped scout car with a turret DT machine gun.",
	maxHealth = 900,
	armor = { front = 25, side = 14, rear = 10 },
	speed = 54,
	turnRate = 65,
	weapons = { coax = DT({ magazine = 63 }) },
	seats = { { id = "Driver", role = "driver", exposed = false, weapons = { "coax" } } },
})

def("Jeep", {
	id = "GAZ67",
	name = "GAZ-67",
	factions = { "USSR" },
	description = "Tough Soviet field car with a pintle DT.",
	maxHealth = 650,
	armor = { front = 4, side = 2, rear = 2 },
	weapons = { hullMG = withCone(DT(), PINTLE) },
	seats = jeepSeats(),
})

def("Truck", {
	id = "ZiS5",
	name = "ZiS-5",
	factions = { "USSR" },
	description = "Workhorse three-tonne lorry.",
	maxHealth = 1000,
	armor = { front = 3, side = 2, rear = 2 },
	speed = 42,
	seats = truckSeats(7),
})

def("ATGun", {
	id = "ZiS3",
	name = "ZiS-3 Divisional Gun",
	factions = { "USSR" },
	description = "Versatile 76mm field gun with a powerful HE shell.",
	maxHealth = 600,
	armor = { front = 10, side = 2, rear = 2 },
	weapons = { main = { name = "76mm ZiS-3", reload = 4.2, shake = 0.55, recoil = 0, ammo = { AP(100, 580, 900), HE(76) } } },
	seats = atSeats(),
})

---------------------------------------------------------------------------------------------------
-- France
---------------------------------------------------------------------------------------------------

def("HeavyTank", {
	id = "CharB1",
	name = "Char B1 bis",
	factions = { "FR" },
	description = "Thick-skinned heavy tank with a 47mm turret gun. Slow and steady.",
	maxHealth = 2400,
	armor = { front = 75, side = 60, rear = 55 },
	speed = 20,
	turretTraverse = 25,
	weapons = {
		main = { name = "47mm SA35", reload = 3.2, shake = 0.5, recoil = 3, ammo = { AP(75, 430, 950), HE(75) } },
		coax = REIBEL(),
		hullMG = withCone(REIBEL(), BOW),
	},
	seats = tankSeats(true),
})

def("MediumTank", {
	id = "SomuaS35",
	name = "Somua S35",
	factions = { "FR" },
	description = "Well-armored cavalry tank with a cast hull and a quick 47mm gun.",
	maxHealth = 1800,
	armor = { front = 60, side = 42, rear = 35 },
	speed = 30,
	weapons = {
		main = { name = "47mm SA35", reload = 3.0, shake = 0.5, recoil = 3, ammo = { AP(75, 420, 950), HE(47) } },
		coax = REIBEL(),
		hullMG = withCone(REIBEL(), BOW),
	},
	seats = tankSeats(true),
	unlockLevel = 4,
})

def("ArmoredCar", {
	id = "Panhard178",
	name = "Panhard 178",
	factions = { "FR" },
	description = "Reconnaissance car with a 25mm anti-tank autocannon.",
	maxHealth = 1100,
	armor = { front = 20, side = 14, rear = 10 },
	weapons = {
		main = {
			name = "25mm SA34",
			reload = 3.8,
			magazine = 6,
			fireInterval = 0.55,
			shake = 0.25,
			recoil = 1.2,
			ammo = { AC(50, 170) },
		},
		coax = REIBEL(),
	},
	seats = passengerSeats({ { id = "Driver", role = "driver", exposed = false, weapons = { "main", "coax" } } }, 1, false),
})

def("Jeep", {
	id = "LafflyV15",
	name = "Laffly V15R",
	factions = { "FR" },
	description = "Six-wheeled all-terrain reconnaissance car.",
	maxHealth = 700,
	armor = { front = 4, side = 2, rear = 2 },
	speed = 56,
	weapons = { hullMG = withCone(REIBEL(), PINTLE) },
	seats = jeepSeats(),
})

def("Truck", {
	id = "LafflyS20",
	name = "Laffly S20TL",
	factions = { "FR" },
	description = "Six-wheeled troop carrier.",
	maxHealth = 1000,
	armor = { front = 3, side = 2, rear = 2 },
	seats = truckSeats(7),
})

def("ATGun", {
	id = "Canon47",
	name = "Canon de 47 SA37",
	factions = { "FR" },
	description = "Precise 47mm anti-tank gun.",
	maxHealth = 600,
	armor = { front = 10, side = 2, rear = 2 },
	weapons = { main = { name = "47mm SA37", reload = 3.2, shake = 0.45, recoil = 0, ammo = { AP(85, 450, 1000), HE(47) } } },
	seats = atSeats(),
})

---------------------------------------------------------------------------------------------------
-- Germany
---------------------------------------------------------------------------------------------------

def("MediumTank", {
	id = "PanzerIV",
	name = "Panzer IV Ausf. H",
	factions = { "DE" },
	description = "The backbone of the Panzerwaffe. Long 75mm gun, side skirts, thin rear.",
	maxHealth = 1900,
	armor = { front = 85, side = 40, rear = 30 },
	speed = 29,
	turretTraverse = 28,
	weapons = {
		main = { name = "7.5cm KwK 40", reload = 4.8, shake = 0.75, recoil = 5, ammo = { AP(125, 600, 1000), HE(75) } },
		coax = MG34(),
		hullMG = withCone(MG34(), BOW),
	},
	seats = tankSeats(true),
})

def("MediumTank", {
	id = "Panther",
	name = "Panther Ausf. G",
	factions = { "DE" },
	description = "Superb frontal armor and a high-velocity gun, but vulnerable flanks.",
	maxHealth = 2200,
	armor = { front = 140, side = 50, rear = 45 },
	speed = 32,
	turretTraverse = 24,
	weapons = {
		main = { name = "7.5cm KwK 42", reload = 5.6, shake = 0.8, recoil = 5.5, ammo = { AP(175, 620, 1150), HE(75) } },
		coax = MG34(),
		hullMG = withCone(MG34(), BOW),
	},
	seats = tankSeats(true),
	unlockLevel = 12,
})

def("HeavyTank", {
	id = "TigerI",
	name = "Tiger I",
	factions = { "DE" },
	description = "Feared heavy tank with the 88. Slow turret and long reload: flank it.",
	maxHealth = 2600,
	armor = { front = 120, side = 85, rear = 80 },
	speed = 22,
	turretTraverse = 18,
	weapons = {
		main = { name = "8.8cm KwK 36", reload = 7.0, shake = 1, recoil = 7, ammo = { AP(160, 760, 950), HE(88) } },
		coax = MG34(),
		hullMG = withCone(MG34(), BOW),
	},
	seats = tankSeats(true),
	unlockLevel = 18,
})

def("ArmoredCar", {
	id = "SdKfz222",
	name = "Sd.Kfz. 222",
	factions = { "DE" },
	description = "Light armored car with a 2cm autocannon behind an open mesh-screened turret.",
	maxHealth = 1000,
	armor = { front = 20, side = 10, rear = 10 },
	speed = 52,
	weapons = {
		main = {
			name = "2cm KwK 30",
			reload = 4.5,
			magazine = 10,
			fireInterval = 0.22,
			shake = 0.2,
			recoil = 0.8,
			ammo = { AC(38, 90) },
		},
		coax = MG34(),
	},
	seats = passengerSeats({ { id = "Driver", role = "driver", exposed = false, weapons = { "main", "coax" } } }, 1, false),
})

def("Jeep", {
	id = "Kubelwagen",
	name = "Kübelwagen",
	factions = { "DE" },
	description = "Air-cooled light car with an MG 34 on a pintle.",
	maxHealth = 600,
	armor = { front = 3, side = 2, rear = 2 },
	speed = 60,
	weapons = { hullMG = withCone(MG34(), PINTLE) },
	seats = jeepSeats(),
})

def("Halftrack", {
	id = "SdKfz251",
	name = "Sd.Kfz. 251",
	factions = { "DE" },
	description = "Armored halftrack with a shielded MG 34. Carries a squad.",
	maxHealth = 1300,
	armor = { front = 15, side = 8, rear = 8 },
	weapons = { hullMG = withCone(MG34(), { yawLimit = 60, pitchMin = -10, pitchMax = 40 }) },
	seats = halftrackSeats(6),
})

def("Truck", {
	id = "OpelBlitz",
	name = "Opel Blitz",
	factions = { "DE" },
	description = "Standard three-tonne lorry.",
	maxHealth = 1000,
	armor = { front = 3, side = 2, rear = 2 },
	seats = truckSeats(7),
	unlockLevel = 2,
})

def("ATGun", {
	id = "Pak40",
	name = "7.5cm Pak 40",
	factions = { "DE" },
	description = "Powerful emplaced anti-tank gun.",
	maxHealth = 600,
	armor = { front = 10, side = 2, rear = 2 },
	weapons = { main = { name = "7.5cm Pak 40", reload = 4.6, shake = 0.6, recoil = 0, ammo = { AP(130, 620, 1000), HE(75) } } },
	seats = atSeats(),
})

---------------------------------------------------------------------------------------------------
-- Japan
---------------------------------------------------------------------------------------------------

def("MediumTank", {
	id = "ChiHa",
	name = "Type 97 Shinhoto Chi-Ha",
	factions = { "JP" },
	description = "Light-armored medium tank with a high-velocity 47mm gun.",
	maxHealth = 1700,
	armor = { front = 40, side = 25, rear = 20 },
	speed = 32,
	turretTraverse = 36,
	weapons = {
		main = { name = "47mm Type 1", reload = 3.1, shake = 0.5, recoil = 3, ammo = { AP(80, 430, 1000), HE(57) } },
		coax = TYPE97(),
		hullMG = withCone(TYPE97(), BOW),
	},
	seats = tankSeats(true),
})

def("LightTank", {
	id = "HaGo",
	name = "Type 95 Ha-Go",
	factions = { "JP" },
	description = "Fast light tank with paper-thin armor.",
	maxHealth = 1200,
	armor = { front = 18, side = 12, rear = 10 },
	speed = 40,
	weapons = {
		main = { name = "37mm Type 94", reload = 2.4, shake = 0.4, recoil = 2.5, ammo = { AP(45, 300, 900), HE(37) } },
		coax = TYPE97(),
		hullMG = withCone(TYPE97(), BOW),
	},
	seats = tankSeats(true),
})

def("Jeep", {
	id = "Kurogane",
	name = "Type 95 Kurogane",
	factions = { "JP" },
	description = "Light four-wheel-drive scout car.",
	maxHealth = 600,
	armor = { front = 3, side = 2, rear = 2 },
	weapons = { hullMG = withCone(TYPE97(), PINTLE) },
	seats = jeepSeats(),
})

def("Halftrack", {
	id = "HoHa",
	name = "Type 1 Ho-Ha",
	factions = { "JP" },
	description = "Armored halftrack with a rear-mounted machine gun.",
	maxHealth = 1250,
	armor = { front = 12, side = 6, rear = 6 },
	weapons = { hullMG = withCone(TYPE97(), RING) },
	seats = halftrackSeats(6),
})

def("ATGun", {
	id = "Type1_47mm",
	name = "Type 1 47mm AT Gun",
	factions = { "JP" },
	description = "Light, accurate anti-tank gun.",
	maxHealth = 600,
	armor = { front = 10, side = 2, rear = 2 },
	weapons = { main = { name = "47mm Type 1", reload = 3.2, shake = 0.45, recoil = 0, ammo = { AP(80, 440, 1000), HE(47) } } },
	seats = atSeats(),
})

---------------------------------------------------------------------------------------------------
-- Italy
---------------------------------------------------------------------------------------------------

def("MediumTank", {
	id = "M13_40",
	name = "Carro Armato M13/40",
	factions = { "IT" },
	description = "Riveted medium tank with a 47/32 gun and twin hull machine guns.",
	maxHealth = 1700,
	armor = { front = 45, side = 25, rear = 20 },
	speed = 27,
	weapons = {
		main = { name = "47/32 M35", reload = 3.0, shake = 0.5, recoil = 3, ammo = { AP(65, 410, 900), HE(47) } },
		coax = BREDA38(),
		hullMG = withCone(BREDA38({ rpm = 600 }), BOW),
	},
	seats = tankSeats(true),
})

def("LightTank", {
	id = "L6_40",
	name = "L6/40",
	factions = { "IT" },
	description = "Light tank armed with a Breda 20mm autocannon.",
	maxHealth = 1200,
	armor = { front = 35, side = 15, rear = 15 },
	speed = 38,
	weapons = {
		main = {
			name = "Breda 20/65",
			reload = 4.0,
			magazine = 8,
			fireInterval = 0.26,
			shake = 0.2,
			recoil = 0.8,
			ammo = { AC(35, 95) },
		},
		coax = BREDA38(),
	},
	seats = tankSeats(false),
})

def("ArmoredCar", {
	id = "AB41",
	name = "Autoblinda AB 41",
	factions = { "IT" },
	description = "Fast armored car with a 20mm turret. Drives equally well in reverse.",
	maxHealth = 1100,
	armor = { front = 18, side = 10, rear = 10 },
	reverseSpeed = 30,
	weapons = {
		main = {
			name = "Breda 20/65",
			reload = 4.0,
			magazine = 8,
			fireInterval = 0.26,
			shake = 0.2,
			recoil = 0.8,
			ammo = { AC(35, 95) },
		},
		coax = BREDA38(),
	},
	seats = passengerSeats({ { id = "Driver", role = "driver", exposed = false, weapons = { "main", "coax" } } }, 1, false),
	unlockLevel = 4,
})

def("Jeep", {
	id = "Fiat508CM",
	name = "Fiat 508 CM Coloniale",
	factions = { "IT" },
	description = "Light military car with a pintle Breda.",
	maxHealth = 600,
	armor = { front = 3, side = 2, rear = 2 },
	weapons = { hullMG = withCone(BREDA38(), PINTLE) },
	seats = jeepSeats(),
})

def("Truck", {
	id = "FiatSPA38",
	name = "Fiat-SPA 38R",
	factions = { "IT" },
	description = "Light military lorry.",
	maxHealth = 950,
	armor = { front = 3, side = 2, rear = 2 },
	seats = truckSeats(7),
})

def("ATGun", {
	id = "Cannone47_32",
	name = "Cannone da 47/32",
	factions = { "IT" },
	description = "Compact infantry/anti-tank gun.",
	maxHealth = 550,
	armor = { front = 8, side = 2, rear = 2 },
	weapons = { main = { name = "47/32 M35", reload = 3.0, shake = 0.45, recoil = 0, ammo = { AP(65, 410, 900), HE(47) } } },
	seats = atSeats(),
})

---------------------------------------------------------------------------------------------------
-- Module
---------------------------------------------------------------------------------------------------

local module = {
	byId = Vehicles,
	order = ORDER,
	CLASSES = { "Tank", "Light", "Jeep", "Transport", "AT" },

	-- Damage-model constants (see header).
	DAMAGE = {
		PEN_FACING_MULT = { front = 1.0, side = 1.15, rear = 1.35, top = 1.35 },
		EXPLOSIVE_FACING_MULT = { front = 0.6, side = 1.0, rear = 1.4, top = 1.4 },
		NONPEN_FRACTION = { AP = 0.1, HE = 0.3 },
		HEAT_NONPEN_FRACTION = 0.25,
		RICOCHET_ANGLE = 72, -- degrees from the surface normal
		FRONT_ARC = 50, -- |yaw| <= FRONT_ARC -> front
		REAR_ARC = 130, -- |yaw| >= REAR_ARC -> rear
		TOP_DOT = 0.75, -- incoming direction's downward component above which a hit counts as top
		CRITICAL_FRACTION = 0.25,
		CRITICAL_SPEED_MULT = 0.6,
		WRECK_TIME = 25,
		OCCUPANT_DEATH_DAMAGE = 1000, -- damage dealt to every occupant when the vehicle is destroyed
		DESTRUCTION_BLAST = { radius = 14, damage = 70 },
		RAM_MIN_SPEED = 18, -- studs/s: running over enemy infantry above this speed hurts them
		RAM_DAMAGE_PER_SPEED = 4,
	},

	-- Optional uploaded sound ids (empty = fall back to SoundController keys / silence).
	SOUNDS = {
		engineTracked = "",
		engineWheeled = "",
	},
}

function module.get(id: string): VehicleDef?
	return Vehicles[id]
end

-- Vehicles available to a faction (optionally of one class), sorted by unlockLevel then catalog order.
function module.forFaction(factionId: string, class: string?): { VehicleDef }
	local list = {}
	for _, id in ORDER do
		local d = Vehicles[id]
		if table.find(d.factions, factionId) and (class == nil or d.class == class) then
			table.insert(list, d)
		end
	end
	table.sort(list, function(a, b)
		if a.unlockLevel ~= b.unlockLevel then
			return a.unlockLevel < b.unlockLevel
		end
		return (table.find(ORDER, a.id) or 0) < (table.find(ORDER, b.id) or 0)
	end)
	return list
end

-- Seat definition by id (nil if the vehicle has no such seat).
function module.getSeat(vehicleDef: VehicleDef, seatId: string): SeatDef?
	for _, s in vehicleDef.seats do
		if s.id == seatId then
			return s
		end
	end
	return nil
end

-- Model Seat instance name for a seat id ("Driver" -> "DriverSeat").
function module.seatInstanceName(seatId: string): string
	return if seatId == "Driver" then "DriverSeat" else seatId
end

return module
