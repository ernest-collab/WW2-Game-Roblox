--[[
	Map registry. Each entry points at a builder ModuleScript in ServerScriptService.Server.Maps
	(src/server/Maps/<builder>.luau) that implements the MapBuilder contract in docs/ARCHITECTURE.md.
	MapService skips entries whose builder module does not exist (yet).
]]

export type MapDef = {
	id: string,
	name: string,
	theater: "Western" | "Eastern" | "Pacific" | "Mediterranean",
	environment: string,
	description: string,
	builder: string,
	alliedFactions: { string }, -- one is chosen at random each round
	axisFactions: { string },
	lighting: string, -- LightingPresets id
	weather: { string }, -- picked at random: "Clear" | "Rain" | "Snow" | "Fog" | "Storm"
	modes: { string }, -- supported GameModes ids
	size: Vector2, -- approximate playable footprint in studs (X, Z)
	vehicleHeavy: boolean,
}

local Maps: { [string]: MapDef } = {
	Normandy = {
		id = "Normandy",
		name = "Saint-Laurent",
		theater = "Western",
		environment = "European village & hedgerows",
		description = "A Norman village surrounded by bocage hedgerows, orchards and a church tower.",
		builder = "Normandy",
		alliedFactions = { "US", "UK", "FR" },
		axisFactions = { "DE" },
		lighting = "Overcast",
		weather = { "Clear", "Fog", "Rain" },
		modes = { "Conquest", "Frontline", "TDM" },
		size = Vector2.new(1400, 1400),
		vehicleHeavy = false,
	},
	Stalingrad = {
		id = "Stalingrad",
		name = "Red October Ruins",
		theater = "Eastern",
		environment = "Destroyed city",
		description = "Shattered factory district and apartment blocks. Brutal close-quarters fighting.",
		builder = "Stalingrad",
		alliedFactions = { "USSR" },
		axisFactions = { "DE" },
		lighting = "WinterSnow",
		weather = { "Snow", "Fog" },
		modes = { "Conquest", "Frontline", "TDM" },
		size = Vector2.new(1100, 1100),
		vehicleHeavy = false,
	},
	Kursk = {
		id = "Kursk",
		name = "Prokhorovka Fields",
		theater = "Eastern",
		environment = "Open battlefield",
		description = "Rolling wheat fields, trench lines and a burning collective farm. Tank country.",
		builder = "Kursk",
		alliedFactions = { "USSR" },
		axisFactions = { "DE" },
		lighting = "GoldenHour",
		weather = { "Clear" },
		modes = { "Conquest", "Frontline" },
		size = Vector2.new(2000, 2000),
		vehicleHeavy = true,
	},
	AtlanticWall = {
		id = "AtlanticWall",
		name = "Atlantic Wall",
		theater = "Western",
		environment = "Beach landing",
		description = "Storm the beach under the guns of concrete bunkers and climb the bluffs.",
		builder = "AtlanticWall",
		alliedFactions = { "US", "UK" },
		axisFactions = { "DE" },
		lighting = "StormRain",
		weather = { "Storm", "Rain", "Fog" },
		modes = { "Frontline", "Conquest", "TDM" },
		size = Vector2.new(1600, 1200),
		vehicleHeavy = false,
	},
	Ardennes = {
		id = "Ardennes",
		name = "Ardennes Forest",
		theater = "Western",
		environment = "Snowy forest",
		description = "Dense pine forest, foxholes and a frozen logging camp.",
		builder = "Ardennes",
		alliedFactions = { "US", "FR" },
		axisFactions = { "DE" },
		lighting = "WinterSnow",
		weather = { "Snow", "Fog" },
		modes = { "Conquest", "Frontline", "TDM" },
		size = Vector2.new(1500, 1500),
		vehicleHeavy = false,
	},
	Pacific = {
		id = "Pacific",
		name = "Coral Atoll",
		theater = "Pacific",
		environment = "Pacific island",
		description = "Palm-lined beaches, jungle, coconut-log bunkers and an airstrip.",
		builder = "Pacific",
		alliedFactions = { "US" },
		axisFactions = { "JP" },
		lighting = "TropicalHaze",
		weather = { "Clear", "Rain" },
		modes = { "Conquest", "Frontline", "TDM" },
		size = Vector2.new(1600, 1600),
		vehicleHeavy = false,
	},
	Sicily = {
		id = "Sicily",
		name = "Sicilian Hills",
		theater = "Mediterranean",
		environment = "Mediterranean hill town",
		description = "Sun-baked stone villages, olive groves and winding mountain roads.",
		builder = "Sicily",
		alliedFactions = { "UK", "US" },
		axisFactions = { "IT", "DE" },
		lighting = "Mediterranean",
		weather = { "Clear" },
		modes = { "Conquest", "Frontline", "TDM" },
		size = Vector2.new(1600, 1600),
		vehicleHeavy = true,
	},
}

local ORDER = { "Normandy", "Stalingrad", "Kursk", "AtlanticWall", "Ardennes", "Pacific", "Sicily" }

return { byId = Maps, order = ORDER }
