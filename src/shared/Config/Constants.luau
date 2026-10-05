-- Global constants shared by server and client.
local Constants = {}

Constants.SIDES = { "Allies", "Axis" }
Constants.SIDE_COLORS = {
	Allies = Color3.fromRGB(86, 140, 214),
	Axis = Color3.fromRGB(214, 86, 74),
	Neutral = Color3.fromRGB(200, 200, 200),
}

Constants.MAX_PLAYERS = 40
Constants.SQUAD_SIZE = 4
Constants.DEFAULT_HEALTH = 100
Constants.RESPAWN_TIME = 8 -- seconds (deploy screen countdown)
Constants.SPAWN_PROTECTION = 2.5 -- seconds of invulnerability after spawn (cancelled by firing)
Constants.HEALTH_REGEN_DELAY = 7 -- seconds after damage before regen starts
Constants.HEALTH_REGEN_RATE = 6 -- hp/sec, regen caps at REGEN_CAP unless healed by a medic
Constants.HEALTH_REGEN_CAP = 60
Constants.HEADSHOT_PART_NAMES = { Head = true }
Constants.LIMB_PART_NAMES = {
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
}

Constants.WALK_SPEED = 14
Constants.SPRINT_SPEED = 21
Constants.CROUCH_SPEED = 8
Constants.PRONE_SPEED = 4
Constants.ADS_SPEED_MULT = 0.6

Constants.INTERMISSION_TIME = 20
Constants.POST_ROUND_TIME = 15
Constants.MIN_PLAYERS_TO_START = 1 -- lets a solo tester play; raise for production

-- CollectionService tags
Constants.TAGS = {
	Vehicle = "Vehicle", -- vehicle Model (attributes: VehicleId, Side, Health, MaxHealth)
	Destructible = "Destructible", -- BasePart/Model that explosions may break
	MapGeometry = "MapGeometry",
	ResupplyPoint = "ResupplyPoint", -- ammo crate placed by Support or by map
	MedicalPoint = "MedicalPoint",
	NoBulletPenetration = "NoBulletPenetration",
}

-- Collision groups (created by the server bootstrap)
Constants.COLLISION_GROUPS = {
	Players = "Players",
	Vehicles = "Vehicles",
	Debris = "Debris", -- ragdolls, shells, gibs: do not collide with players
	Viewmodel = "Viewmodel",
}

return Constants
