--[[
	Visual specs for every vehicle id in Config/Vehicles, plus faction palettes.
	All dimensions in studs (~0.33 m per stud so vehicles match R15 characters).
	Styles: "Tank" (Tracked.build), "ArmoredCar", "Jeep", "Truck", "Halftrack" (Wheeled.*),
	"ATGun" (Emplacement.build). `mass` = assembly mass for the physics rig.
]]

local V = Vector3.new

local Specs = {}

---------------------------------------------------------------------------------------------------
-- Palettes (base camo + optional blotch colors) per faction
---------------------------------------------------------------------------------------------------

local function palette(base: Color3, patches: { Color3 }, insignia: string, canvas: Color3?)
	return {
		base = base,
		dark = base:Lerp(Color3.new(0, 0, 0), 0.45),
		patches = patches,
		track = Color3.fromRGB(52, 48, 44),
		wheel = base:Lerp(Color3.new(0, 0, 0), 0.25),
		metal = Color3.fromRGB(58, 58, 56),
		rubber = Color3.fromRGB(30, 30, 30),
		wood = Color3.fromRGB(112, 84, 56),
		canvas = canvas or base:Lerp(Color3.fromRGB(190, 175, 140), 0.35),
		glass = Color3.fromRGB(150, 170, 175),
		seat = Color3.fromRGB(70, 56, 42),
		insignia = insignia,
	}
end

Specs.PALETTES = {
	US = palette(Color3.fromRGB(84, 88, 52), {}, "US"),
	UK = palette(Color3.fromRGB(98, 98, 70), { Color3.fromRGB(64, 62, 50) }, "UK"),
	USSR = palette(Color3.fromRGB(74, 90, 52), {}, "USSR"),
	FR = palette(Color3.fromRGB(128, 114, 74), { Color3.fromRGB(78, 88, 56), Color3.fromRGB(98, 72, 50) }, "FR"),
	DE = palette(
		Color3.fromRGB(172, 154, 104),
		{ Color3.fromRGB(82, 92, 60), Color3.fromRGB(112, 74, 52) },
		"DE",
		Color3.fromRGB(150, 140, 105)
	),
	JP = palette(Color3.fromRGB(120, 106, 72), { Color3.fromRGB(78, 90, 58), Color3.fromRGB(160, 140, 96) }, "JP"),
	IT = palette(Color3.fromRGB(184, 164, 120), { Color3.fromRGB(132, 116, 82) }, "IT"),
}

---------------------------------------------------------------------------------------------------
-- Shared fragments
---------------------------------------------------------------------------------------------------

local function gun(length: number, radius: number, mantlet: Vector3?, extra: { [string]: any }?)
	local g: { [string]: any } = { length = length, radius = radius, mantlet = mantlet }
	if extra then
		for k, v in extra do
			g[k] = v
		end
	end
	return g
end

local S: { [string]: any } = {}
Specs.byId = S

---------------------------------------------------------------------------------------------------
-- Tanks
---------------------------------------------------------------------------------------------------

S.M4Sherman = {
	style = "Tank",
	mass = 6000,
	hull = V(4.8, 2.4, 15),
	clearance = 1.3,
	track = { width = 1.7, height = 3.3, length = 16, wheels = 6, wheelRadius = 0.95, rollers = 3 },
	upper = { height = 2.3, length = 11.6, z = 1.2, glacis = 3.4, rear = 0.6 },
	turret = { size = V(5.0, 2.3, 4.8), z = 0.4, shape = "round", bustle = 1.2, cupola = true },
	gun = gun(7.5, 0.3, V(2.6, 1.4, 0.8)),
	extras = { "spareTracks", "jerrycans", "toolbox", "antenna" },
}

S.M5Stuart = {
	style = "Tank",
	mass = 3500,
	hull = V(4.0, 2.0, 11),
	clearance = 1.2,
	track = { width = 1.4, height = 2.9, length = 12, wheels = 4, wheelRadius = 0.9, rollers = 3, sprocketRadius = 0.9 },
	upper = { height = 2.0, length = 8.2, z = 0.8, glacis = 2.6, rear = 0.8, sideSlope = 0.4 },
	turret = { size = V(3.8, 2.0, 3.6), z = 0.6, shape = "box", bustle = 0.9, sideSlope = 0.3 },
	gun = gun(5.5, 0.2, V(1.8, 1.1, 0.6)),
	extras = { "toolbox" },
}

S.Cromwell = {
	style = "Tank",
	mass = 5600,
	hull = V(5.2, 2.4, 15),
	clearance = 1.3,
	track = { width = 1.7, height = 3.4, length = 15.6, wheels = 5, wheelRadius = 1.3, sprocketRear = true },
	upper = { height = 2.2, length = 13.4, z = 0.2, glacis = 1.0, rear = 0.6 },
	turret = { size = V(5.4, 2.4, 5.0), z = -0.8, shape = "box", bustle = 0.6, cupola = true, stowage = true },
	gun = gun(7.2, 0.3, V(2.6, 1.5, 0.6)),
	extras = { "jerrycans", "toolbox", "antenna" },
}

S.Churchill = {
	style = "Tank",
	mass = 9000,
	hull = V(5.0, 2.6, 18),
	clearance = 1.0,
	lowerGlacis = 0.6,
	track = {
		width = 2.1,
		height = 4.4,
		length = 19,
		wheels = 0,
		wheelRadius = 0.6,
		panniers = true,
		sprocketRear = true,
	},
	upper = { height = 2.0, length = 15.4, z = 0.6, glacis = 0.8, rear = 0.4 },
	turret = { size = V(5.6, 2.5, 5.0), z = -1.6, shape = "box", cupola = true },
	gun = gun(7.0, 0.3, V(2.4, 1.4, 0.6)),
	extras = { "toolbox", "antenna" },
}

S.T34_85 = {
	style = "Tank",
	mass = 6200,
	hull = V(4.6, 2.4, 15),
	clearance = 1.3,
	track = { width = 2.0, height = 3.1, length = 15.8, wheels = 5, wheelRadius = 1.35, sprocketRear = true },
	upper = { height = 2.0, length = 10.4, z = 1.6, glacis = 4.2, rear = 1.4, sideSlope = 1.0 },
	turret = { size = V(5.0, 2.3, 5.6), z = -1.0, shape = "cast", bustle = 1.0, cupola = true },
	gun = gun(10, 0.3, V(2.0, 1.4, 0.9), { sleeve = true }),
	extras = { "logs", "jerrycans" },
}

S.KV1 = {
	style = "Tank",
	mass = 9000,
	hull = V(5.6, 2.6, 16),
	clearance = 1.2,
	track = {
		width = 2.0,
		height = 3.2,
		length = 16.6,
		wheels = 6,
		wheelRadius = 0.95,
		rollers = 3,
		sprocketRear = true,
	},
	upper = { height = 2.6, length = 13, z = 0.8, glacis = 1.8, rear = 1.2 },
	turret = { size = V(5.6, 2.8, 5.6), z = -0.4, shape = "box", bustle = 1.2, frontSlope = 1.0 },
	gun = gun(8, 0.32, V(2.4, 1.6, 0.8)),
	extras = { "logs" },
}

S.CharB1 = {
	style = "Tank",
	mass = 8000,
	hull = V(4.4, 3.0, 18),
	clearance = 1.0,
	track = {
		width = 2.0,
		height = 5.0,
		length = 19.5,
		wheels = 0,
		wheelRadius = 0.6,
		panniers = true,
		sprocketRear = true,
	},
	upper = { height = 2.4, length = 15, z = 0.8, glacis = 1.6, rear = 0.6 },
	turret = { size = V(3.4, 2.2, 3.6), z = -1.0, shape = "cast" },
	gun = gun(5.0, 0.22, V(1.5, 1.0, 0.6)),
	extras = { "hullGun" },
}

S.SomuaS35 = {
	style = "Tank",
	mass = 5000,
	hull = V(4.0, 2.2, 14),
	clearance = 1.1,
	track = {
		width = 1.6,
		height = 3.4,
		length = 14.6,
		wheels = 5,
		wheelRadius = 0.7,
		skirts = true,
		sprocketRear = true,
	},
	upper = { height = 2.0, length = 9.6, z = 0.8, glacis = 2.4, rear = 2.4, sideSlope = 0.6 },
	turret = { size = V(3.6, 2.2, 3.8), z = -0.6, shape = "cast", cupola = true },
	gun = gun(5.2, 0.22, V(1.5, 1.0, 0.6)),
}

S.PanzerIV = {
	style = "Tank",
	mass = 5800,
	hull = V(5.0, 2.2, 16),
	clearance = 1.2,
	track = { width = 1.6, height = 2.9, length = 16.6, wheels = 8, wheelRadius = 0.75, rollers = 4, skirts = true },
	upper = { height = 2.1, length = 14, z = 0.4, glacis = 1.2, rear = 0.6 },
	turret = {
		size = V(4.8, 2.2, 5.0),
		z = -0.6,
		shape = "box",
		sideSlope = 0.5,
		bustle = 1.4,
		stowage = true,
		cupola = true,
	},
	gun = gun(11, 0.27, V(1.8, 1.2, 0.8), { brake = true }),
	extras = { "spareTracks", "jerrycans", "antenna" },
}

S.Panther = {
	style = "Tank",
	mass = 7200,
	hull = V(5.2, 2.6, 18),
	clearance = 1.3,
	track = { width = 1.9, height = 3.3, length = 18.6, wheels = 8, wheelRadius = 1.25, skirts = true },
	upper = { height = 2.3, length = 11, z = 2.6, glacis = 5.0, rear = 1.0, sideSlope = 0.8 },
	turret = { size = V(5.0, 2.4, 6.4), z = 0.6, shape = "box", sideSlope = 0.7, frontSlope = 1.2, cupola = true },
	gun = gun(14, 0.27, V(2.2, 1.6, 1.0), { brake = true }),
	extras = { "toolbox", "antenna" },
}

S.TigerI = {
	style = "Tank",
	mass = 9500,
	hull = V(5.6, 2.6, 17),
	clearance = 1.3,
	track = { width = 2.4, height = 3.3, length = 17.6, wheels = 8, wheelRadius = 1.25 },
	upper = { height = 2.6, length = 15.6, z = 0.2, glacis = 0.9, rear = 0.4, width = 11.2 },
	turret = { size = V(6.4, 2.6, 6.6), z = 0.8, shape = "horseshoe", cupola = true, stowage = true, bustle = 1.2 },
	gun = gun(13, 0.33, V(3.4, 1.8, 0.9), { brake = true }),
	extras = { "jerrycans", "toolbox", "antenna" },
}

S.ChiHa = {
	style = "Tank",
	mass = 4200,
	hull = V(4.0, 2.0, 12.6),
	clearance = 1.1,
	track = { width = 1.4, height = 2.8, length = 13, wheels = 6, wheelRadius = 0.75, rollers = 3 },
	upper = { height = 2.0, length = 9.4, z = 0.8, glacis = 2.2, rear = 0.8 },
	turret = { size = V(3.6, 2.0, 4.2), z = -0.8, shape = "box", bustle = 1.0, frontSlope = 0.8 },
	gun = gun(6.2, 0.22, V(1.6, 1.0, 0.6)),
	extras = { "antenna" },
}

S.HaGo = {
	style = "Tank",
	mass = 2900,
	hull = V(3.4, 1.8, 10.5),
	clearance = 1.1,
	track = { width = 1.2, height = 2.5, length = 11, wheels = 4, wheelRadius = 0.8, rollers = 2 },
	upper = { height = 1.8, length = 7.0, z = 0.8, glacis = 2.0, rear = 0.5 },
	turret = { size = V(2.8, 1.6, 3.0), z = -0.8, x = -0.3, shape = "cast" },
	gun = gun(4.0, 0.18, V(1.2, 0.8, 0.5)),
}

S.M13_40 = {
	style = "Tank",
	mass = 4300,
	hull = V(4.0, 2.0, 13),
	clearance = 1.1,
	track = { width = 1.4, height = 2.8, length = 13.6, wheels = 8, wheelRadius = 0.55, rollers = 3 },
	upper = { height = 2.0, length = 10, z = 0.6, glacis = 1.8, rear = 1.0 },
	turret = { size = V(3.6, 1.8, 3.8), z = -0.4, shape = "box", frontSlope = 0.8, sideSlope = 0.3 },
	gun = gun(6.0, 0.22, V(1.4, 1.0, 0.6)),
	extras = { "jerrycans", "sandbags" },
}

S.L6_40 = {
	style = "Tank",
	mass = 2700,
	hull = V(3.4, 1.8, 10.5),
	clearance = 1.0,
	track = { width = 1.2, height = 2.4, length = 11, wheels = 4, wheelRadius = 0.6, rollers = 2 },
	upper = { height = 1.8, length = 7.5, z = 0.4, glacis = 1.6, rear = 0.5 },
	turret = { size = V(3.0, 1.6, 3.0), z = -0.4, shape = "box", sideSlope = 0.2 },
	gun = gun(4.5, 0.15, V(1.0, 0.8, 0.5)),
}

S.UniversalCarrier = {
	style = "Tank",
	mass = 1500,
	hull = V(3.6, 1.4, 10),
	clearance = 0.9,
	track = { width = 1.3, height = 2.3, length = 10.4, wheels = 3, wheelRadius = 0.8, sprocketRear = true },
	upper = { open = true, height = 1.3, length = 8.4, z = 0.6, glacis = 1.2, rear = 0 },
	mg = { kind = "pintle", pos = V(-1.4, 2.0, -3.4), height = 0.5, noPost = true, shield = true },
	extras = { "jerrycans" },
}

---------------------------------------------------------------------------------------------------
-- Armored cars
---------------------------------------------------------------------------------------------------

S.M8Greyhound = {
	style = "ArmoredCar",
	mass = 3200,
	hull = V(6.6, 2.0, 15),
	clearance = 1.6,
	wheels = { radius = 1.35, width = 1.0, axles = { -4.6, 1.4, 4.6 } },
	upper = { height = 1.8, length = 9, z = 0.4, nose = 2.2, tail = 1.2, glacis = 2.0, rear = 0.8, sideSlope = 0.6 },
	turret = { size = V(4.6, 1.8, 4.4), z = -0.2, shape = "box" },
	gun = gun(5.5, 0.2, V(1.6, 1.0, 0.6)),
	mg = { kind = "pintle", pos = V(1.6, 2.8, 4.0), height = 1.6, heavy = true },
}

S.DaimlerAC = {
	style = "ArmoredCar",
	mass = 2800,
	hull = V(5.8, 2.0, 12.5),
	clearance = 1.5,
	wheels = { radius = 1.3, width = 0.9, axles = { -3.8, 3.8 } },
	upper = { height = 2.0, length = 7, z = 0.2, nose = 2.0, tail = 1.5, glacis = 1.6, rear = 1.2, sideSlope = 0.8 },
	turret = { size = V(3.8, 1.8, 3.6), z = 0, shape = "box", sideSlope = 0.3 },
	gun = gun(5.0, 0.2, V(1.4, 1.0, 0.5)),
}

S.BA64 = {
	style = "ArmoredCar",
	mass = 2000,
	hull = V(5.0, 1.8, 11),
	clearance = 1.4,
	wheels = { radius = 1.2, width = 0.8, axles = { -3.4, 3.4 } },
	upper = { height = 2.4, length = 5.2, z = 0.4, nose = 2.6, tail = 1.6, glacis = 2.4, rear = 1.6, sideSlope = 1.0 },
	turret = { size = V(2.4, 1.2, 2.4), z = 0.6, shape = "cast" },
	gun = gun(2.0, 0.1, V(0.6, 0.6, 0.4)),
}

S.Panhard178 = {
	style = "ArmoredCar",
	mass = 3000,
	hull = V(6.0, 2.0, 14.5),
	clearance = 1.5,
	wheels = { radius = 1.3, width = 0.9, axles = { -4.4, 4.4 } },
	upper = { height = 2.0, length = 8, z = 0.2, nose = 3.0, tail = 2.0, glacis = 1.8, rear = 1.4, sideSlope = 0.6 },
	turret = { size = V(3.6, 1.8, 3.6), z = -0.8, shape = "box", frontSlope = 0.6 },
	gun = gun(4.5, 0.17, V(1.2, 0.9, 0.5)),
}

S.SdKfz222 = {
	style = "ArmoredCar",
	mass = 2700,
	hull = V(5.6, 1.8, 13.5),
	clearance = 1.4,
	wheels = { radius = 1.25, width = 0.9, axles = { -4.0, 4.0 } },
	upper = { height = 2.0, length = 6.4, z = 0.4, nose = 3.0, tail = 2.2, glacis = 2.2, rear = 1.6, sideSlope = 1.0 },
	turret = { size = V(3.6, 1.0, 3.4), z = 0.2, shape = "open" },
	gun = gun(5.0, 0.14, V(0.8, 0.7, 0.6)),
}

S.AB41 = {
	style = "ArmoredCar",
	mass = 3000,
	hull = V(5.8, 2.0, 14.5),
	clearance = 1.6,
	wheels = { radius = 1.35, width = 0.9, axles = { -4.6, 4.6 } },
	upper = { height = 2.0, length = 9, z = 0, nose = 2.6, tail = 1.6, glacis = 1.4, rear = 1.0, sideSlope = 0.4 },
	turret = { size = V(3.4, 1.6, 3.6), z = -0.4, shape = "box", frontSlope = 0.6 },
	gun = gun(5.0, 0.15, V(1.0, 0.8, 0.5)),
}

---------------------------------------------------------------------------------------------------
-- Jeeps / light cars
---------------------------------------------------------------------------------------------------

local function jeep(
	W: number,
	L: number,
	r: number,
	axles: { number },
	hood: { [string]: any },
	extra: { [string]: any }?
)
	local s: { [string]: any } = {
		style = "Jeep",
		mass = 1000,
		hull = V(W, 1.2, L),
		clearance = 1.3,
		wheels = { radius = r, width = 0.85, axles = axles },
		hood = hood,
		wallHeight = 1.0,
		windshield = 1.4,
	}
	if extra then
		for k, v in extra do
			s[k] = v
		end
	end
	return s
end

S.WillysMB = jeep(4.8, 9.8, 1.05, { -3.0, 3.1 }, { length = 3.2, height = 0.8 })
S.GAZ67 = jeep(5.0, 10.2, 1.1, { -3.2, 3.2 }, { length = 3.6, height = 0.9 })
S.Kubelwagen = jeep(5.0, 11.2, 1.1, { -3.6, 3.4 }, { length = 3.0, height = 0.9, slope = true }, { wallHeight = 1.5 })
S.Kurogane = jeep(4.6, 10.0, 1.0, { -3.2, 3.2 }, { length = 2.8, height = 0.8, slope = true })
S.Fiat508CM = jeep(4.6, 10.0, 1.0, { -3.2, 3.2 }, { length = 3.2, height = 0.9 }, { wallHeight = 1.2 })
S.LafflyV15 = jeep(5.4, 12.5, 1.15, { -4.2, 1.6, 4.2 }, { length = 3.6, height = 1.0 }, { mass = 1400 })

---------------------------------------------------------------------------------------------------
-- Trucks
---------------------------------------------------------------------------------------------------

local function truck(W: number, L: number, r: number, axles: { number }, hoodLength: number, extra: { [string]: any }?)
	local s: { [string]: any } = {
		style = "Truck",
		mass = 2500,
		hull = V(W, 1.4, L),
		clearance = 1.6,
		wheels = { radius = r, width = 0.9, axles = axles },
		hoodLength = hoodLength,
		cabLength = 3.6,
		cabHeight = 4.0,
		canvas = true,
	}
	if extra then
		for k, v in extra do
			s[k] = v
		end
	end
	return s
end

S.GMCTruck = truck(6.6, 21, 1.4, { -6.6, 3.4, 6.6 }, 4.2)
S.BedfordQL = truck(6.6, 18.5, 1.45, { -5.4, 5.4 }, 0, { cabLength = 4.2, dualRear = false })
S.ZiS5 = truck(6.4, 19.5, 1.35, { -6.0, 5.6 }, 4.4, { woodCab = true, woodBed = true, canvas = false })
S.LafflyS20 = truck(6.4, 19, 1.4, { -6.0, 2.6, 6.2 }, 3.6, { dualRear = false })
S.OpelBlitz = truck(6.6, 19.5, 1.4, { -6.0, 5.8 }, 4.2)
S.FiatSPA38 = truck(6.0, 17.5, 1.3, { -5.4, 5.0 }, 3.6, { canvasCab = true, mass = 2200 })

---------------------------------------------------------------------------------------------------
-- Halftracks
---------------------------------------------------------------------------------------------------

S.M3Halftrack = {
	style = "Halftrack",
	mass = 3500,
	hull = V(6.6, 1.6, 19),
	clearance = 1.5,
	wheels = { radius = 1.35, width = 0.9, axle = -6.4 },
	track = { width = 1.3, height = 2.8, length = 9.0, wheels = 4, wheelRadius = 0.8, sprocketRadius = 0.9 },
	hoodLength = 5.0,
	hoodHeight = 1.9,
	wallHeight = 2.6,
	roller = true,
	mg = { kind = "pintle", pos = V(1.6, 0.8, -3.4), height = 3.6, heavy = true, ring = 2.4, seatHeight = 2.2 },
}

S.SdKfz251 = {
	style = "Halftrack",
	mass = 3600,
	hull = V(6.4, 1.6, 19),
	clearance = 1.5,
	wheels = { radius = 1.3, width = 0.8, axle = -6.6 },
	track = { width = 1.4, height = 2.8, length = 10, wheels = 6, wheelRadius = 0.9, sprocketRadius = 0.9 },
	hoodLength = 5.4,
	hoodHeight = 2.0,
	nose = true,
	wallHeight = 2.6,
	wallSlope = 0.7,
	mg = { kind = "pintle", pos = V(0, 0.8, -3.0), height = 3.2, shield = true, seatHeight = 1.8 },
}

S.HoHa = {
	style = "Halftrack",
	mass = 3400,
	hull = V(6.4, 1.6, 18.5),
	clearance = 1.5,
	wheels = { radius = 1.3, width = 0.8, axle = -6.2 },
	track = { width = 1.3, height = 2.8, length = 9.5, wheels = 4, wheelRadius = 0.85, sprocketRadius = 0.9 },
	hoodLength = 5.0,
	hoodHeight = 2.0,
	nose = true,
	wallHeight = 2.5,
	wallSlope = 0.4,
	mg = { kind = "pintle", pos = V(0, 0.8, 6.0), height = 3.0, seatHeight = 1.6 },
}

---------------------------------------------------------------------------------------------------
-- Emplaced AT guns
---------------------------------------------------------------------------------------------------

local function atGun(barrel: number, radius: number, extra: { [string]: any }?)
	local s: { [string]: any } = { style = "ATGun", barrelLength = barrel, barrelRadius = radius }
	if extra then
		for k, v in extra do
			s[k] = v
		end
	end
	return s
end

S.M1_57mm = atGun(8.5, 0.22, { brake = false })
S.QF6Pounder = atGun(8.5, 0.22, { brake = true, shield = V(4.0, 2.2, 0.15), shieldTop = true })
S.ZiS3 = atGun(8.0, 0.26, { brake = true, shield = V(4.4, 2.4, 0.15) })
S.Canon47 = atGun(7.0, 0.2, { brake = true, shield = V(3.8, 2.4, 0.15) })
S.Pak40 = atGun(10, 0.26, { brake = true, shield = V(4.6, 2.4, 0.15), shieldTop = true })
S.Type1_47mm = atGun(7.0, 0.2, { brake = false, shield = V(3.6, 2.2, 0.15) })
S.Cannone47_32 = atGun(5.0, 0.2, { brake = false, shield = V(3.0, 2.0, 0.15), wheelRadius = 1.0 })

return Specs
