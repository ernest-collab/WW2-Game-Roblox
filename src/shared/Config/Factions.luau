--[[
	Factions: the seven playable WWII nations.
	Weapons/vehicles reference factions by id via their `factions` list.
	Outfit colors are used by the procedural uniform builder (OutfitService).
]]

export type Faction = {
	id: string,
	name: string,
	adjective: string,
	side: "Allies" | "Axis",
	helmet: string, -- helmet style key for OutfitService: "M1" | "Brodie" | "SSh40" | "Adrian" | "Stahlhelm" | "Type90" | "M33"
	colors: {
		tunic: Color3,
		trousers: Color3,
		helmet: Color3,
		webbing: Color3,
		boots: Color3,
		accent: Color3, -- UI accent / insignia
	},
	flag: { Color3 }, -- simplified flag stripes for UI
	callsign: string, -- shown in kill feed tags, e.g. "[US]"
}

local Factions: { [string]: Faction } = {
	US = {
		id = "US",
		name = "United States",
		adjective = "American",
		side = "Allies",
		helmet = "M1",
		colors = {
			tunic = Color3.fromRGB(116, 107, 74),
			trousers = Color3.fromRGB(128, 112, 82),
			helmet = Color3.fromRGB(86, 90, 58),
			webbing = Color3.fromRGB(150, 140, 100),
			boots = Color3.fromRGB(92, 62, 40),
			accent = Color3.fromRGB(70, 110, 190),
		},
		flag = { Color3.fromRGB(178, 34, 52), Color3.fromRGB(255, 255, 255), Color3.fromRGB(60, 59, 110) },
		callsign = "US",
	},
	UK = {
		id = "UK",
		name = "United Kingdom",
		adjective = "British",
		side = "Allies",
		helmet = "Brodie",
		colors = {
			tunic = Color3.fromRGB(122, 104, 70),
			trousers = Color3.fromRGB(122, 104, 70),
			helmet = Color3.fromRGB(92, 88, 60),
			webbing = Color3.fromRGB(170, 160, 120),
			boots = Color3.fromRGB(40, 32, 28),
			accent = Color3.fromRGB(200, 60, 60),
		},
		flag = { Color3.fromRGB(1, 33, 105), Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 16, 46) },
		callsign = "UK",
	},
	USSR = {
		id = "USSR",
		name = "Soviet Union",
		adjective = "Soviet",
		side = "Allies",
		helmet = "SSh40",
		colors = {
			tunic = Color3.fromRGB(128, 116, 78),
			trousers = Color3.fromRGB(96, 92, 66),
			helmet = Color3.fromRGB(70, 82, 52),
			webbing = Color3.fromRGB(110, 86, 58),
			boots = Color3.fromRGB(36, 30, 26),
			accent = Color3.fromRGB(204, 30, 30),
		},
		flag = { Color3.fromRGB(204, 0, 0), Color3.fromRGB(255, 215, 0) },
		callsign = "USSR",
	},
	FR = {
		id = "FR",
		name = "France",
		adjective = "French",
		side = "Allies",
		helmet = "Adrian",
		colors = {
			tunic = Color3.fromRGB(132, 114, 80),
			trousers = Color3.fromRGB(132, 114, 80),
			helmet = Color3.fromRGB(96, 100, 74),
			webbing = Color3.fromRGB(96, 70, 46),
			boots = Color3.fromRGB(44, 34, 28),
			accent = Color3.fromRGB(0, 85, 164),
		},
		flag = { Color3.fromRGB(0, 85, 164), Color3.fromRGB(255, 255, 255), Color3.fromRGB(239, 65, 53) },
		callsign = "FR",
	},
	DE = {
		id = "DE",
		name = "Germany",
		adjective = "German",
		side = "Axis",
		helmet = "Stahlhelm",
		colors = {
			tunic = Color3.fromRGB(92, 98, 84),
			trousers = Color3.fromRGB(84, 88, 80),
			helmet = Color3.fromRGB(72, 76, 70),
			webbing = Color3.fromRGB(40, 36, 32),
			boots = Color3.fromRGB(30, 26, 24),
			accent = Color3.fromRGB(150, 150, 150),
		},
		flag = { Color3.fromRGB(30, 30, 30), Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 30, 30) },
		callsign = "DE",
	},
	JP = {
		id = "JP",
		name = "Japan",
		adjective = "Japanese",
		side = "Axis",
		helmet = "Type90",
		colors = {
			tunic = Color3.fromRGB(140, 124, 72),
			trousers = Color3.fromRGB(134, 118, 70),
			helmet = Color3.fromRGB(104, 100, 62),
			webbing = Color3.fromRGB(120, 92, 56),
			boots = Color3.fromRGB(70, 50, 34),
			accent = Color3.fromRGB(188, 0, 45),
		},
		flag = { Color3.fromRGB(255, 255, 255), Color3.fromRGB(188, 0, 45) },
		callsign = "JP",
	},
	IT = {
		id = "IT",
		name = "Italy",
		adjective = "Italian",
		side = "Axis",
		helmet = "M33",
		colors = {
			tunic = Color3.fromRGB(110, 110, 88),
			trousers = Color3.fromRGB(104, 104, 84),
			helmet = Color3.fromRGB(92, 94, 74),
			webbing = Color3.fromRGB(90, 70, 50),
			boots = Color3.fromRGB(60, 42, 30),
			accent = Color3.fromRGB(0, 146, 70),
		},
		flag = { Color3.fromRGB(0, 146, 70), Color3.fromRGB(255, 255, 255), Color3.fromRGB(206, 43, 55) },
		callsign = "IT",
	},
}

local ORDER = { "US", "UK", "USSR", "FR", "DE", "JP", "IT" }

local module = {
	byId = Factions,
	order = ORDER,
}

function module.get(id: string): Faction
	return Factions[id]
end

function module.forSide(side: string): { Faction }
	local list = {}
	for _, id in ORDER do
		if Factions[id].side == side then
			table.insert(list, Factions[id])
		end
	end
	return list
end

return module
