--[[
	LightingPresets: cinematic, slightly desaturated "WWII newsreel" looks per map.

	Owned by the Sound & Atmosphere team. Applied server-side by AtmosphereService (Lighting,
	post effects, Terrain water, wind) and read client-side by AtmosphereController (weather
	particles) and SoundController (reverb / ambient beds).

	Ids (binding, referenced by Config/Maps.luau `lighting`):
	  "Overcast", "GoldenHour", "WinterSnow", "TropicalHaze", "StormRain", "Mediterranean", "Night"

	Design rules for every preset:
	  * Readability first: players must stay visible at 150+ studs, so Atmosphere density stays
	    in 0.25..0.45 and post-grading never crushes blacks (Contrast <= 0.2).
	  * Desaturated filmic grade (Saturation -0.1 .. -0.4) with a warm or cool tint.
	  * Sky uses the default Roblox skybox textures (a plain `Sky` instance) - no invented ids.
	    Terrain `Clouds` + Atmosphere do the heavy lifting for mood.

	Weather (GameState.Weather: "Clear" | "Rain" | "Snow" | "Fog" | "Storm") is layered on top of
	a preset through `LightingPresets.Weather[weather]` modifiers (see `WeatherModifier`).
]]

export type LightingProps = {
	ClockTime: number,
	GeographicLatitude: number,
	Brightness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	ColorShift_Top: Color3,
	ColorShift_Bottom: Color3,
	ExposureCompensation: number,
	EnvironmentDiffuseScale: number,
	EnvironmentSpecularScale: number,
	ShadowSoftness: number,
}

export type Preset = {
	id: string,
	name: string,
	lighting: LightingProps,
	atmosphere: { Density: number, Offset: number, Color: Color3, Decay: Color3, Glare: number, Haze: number },
	clouds: { Cover: number, Density: number, Color: Color3 },
	colorCorrection: { Brightness: number, Contrast: number, Saturation: number, TintColor: Color3 },
	bloom: { Intensity: number, Size: number, Threshold: number },
	sunRays: { Intensity: number, Spread: number },
	depthOfField: { FarIntensity: number, FocusDistance: number, InFocusRadius: number, NearIntensity: number },
	sky: { StarCount: number, CelestialBodiesShown: boolean, SunAngularSize: number, MoonAngularSize: number },
	water: {
		WaterColor: Color3,
		WaterReflectance: number,
		WaterTransparency: number,
		WaterWaveSize: number,
		WaterWaveSpeed: number,
	},
	wind: Vector3, -- workspace.GlobalWind (grass decoration + WindAffectsDrag particles)
	reverb: string, -- Enum.ReverbType name used outdoors (SoundController)
	weather: {
		default: string, -- used when GameState.Weather is "" / unknown
		dustColor: Color3, -- wind-blown dust tint for this environment
	},
}

-- Additive/multiplicative tweaks layered on top of a preset for a weather state.
export type WeatherModifier = {
	brightnessMult: number,
	exposureAdd: number,
	densityAdd: number,
	hazeAdd: number,
	glareMult: number,
	cloudCoverMin: number,
	cloudDensityMin: number,
	cloudDarken: number, -- 0..1 lerp of cloud colour towards dark grey
	saturationAdd: number,
	contrastAdd: number,
	sunRaysMult: number,
	windMult: number,
	waveMult: number,
	-- client-side particle weather (AtmosphereController)
	rain: number, -- 0..1 intensity
	snow: number,
	fog: number, -- ground fog banks 0..1
	lightning: boolean, -- AtmosphereService periodic strikes
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local Presets: { [string]: Preset } = {
	-- Normandy: flat grey Channel sky, soft shadows, muted greens.
	Overcast = {
		id = "Overcast",
		name = "Overcast",
		lighting = {
			ClockTime = 13.5,
			GeographicLatitude = 48,
			Brightness = 1.7,
			Ambient = rgb(70, 72, 76),
			OutdoorAmbient = rgb(128, 130, 134),
			ColorShift_Top = rgb(186, 186, 180),
			ColorShift_Bottom = rgb(60, 62, 66),
			ExposureCompensation = -0.05,
			EnvironmentDiffuseScale = 0.6,
			EnvironmentSpecularScale = 0.4,
			ShadowSoftness = 0.65,
		},
		atmosphere = {
			Density = 0.33,
			Offset = 0.12,
			Color = rgb(192, 194, 192),
			Decay = rgb(106, 112, 118),
			Glare = 0,
			Haze = 1.7,
		},
		clouds = { Cover = 0.82, Density = 0.55, Color = rgb(182, 184, 188) },
		colorCorrection = { Brightness = 0.02, Contrast = 0.12, Saturation = -0.28, TintColor = rgb(242, 240, 232) },
		bloom = { Intensity = 0.4, Size = 24, Threshold = 1.4 },
		sunRays = { Intensity = 0.03, Spread = 0.6 },
		depthOfField = { FarIntensity = 0.12, FocusDistance = 120, InFocusRadius = 170, NearIntensity = 0 },
		sky = { StarCount = 0, CelestialBodiesShown = false, SunAngularSize = 14, MoonAngularSize = 8 },
		water = {
			WaterColor = rgb(52, 66, 64),
			WaterReflectance = 0.4,
			WaterTransparency = 0.45,
			WaterWaveSize = 0.15,
			WaterWaveSpeed = 10,
		},
		wind = Vector3.new(8, 0, 4),
		reverb = "Plain",
		weather = { default = "Clear", dustColor = rgb(150, 140, 120) },
	},

	-- Kursk: low warm sun across wheat, long hard shadows, amber haze.
	GoldenHour = {
		id = "GoldenHour",
		name = "Golden Hour",
		lighting = {
			ClockTime = 17.6,
			GeographicLatitude = 50,
			Brightness = 2.6,
			Ambient = rgb(78, 64, 52),
			OutdoorAmbient = rgb(140, 118, 94),
			ColorShift_Top = rgb(255, 206, 150),
			ColorShift_Bottom = rgb(80, 60, 50),
			ExposureCompensation = 0,
			EnvironmentDiffuseScale = 0.7,
			EnvironmentSpecularScale = 0.6,
			ShadowSoftness = 0.25,
		},
		atmosphere = {
			Density = 0.3,
			Offset = 0.2,
			Color = rgb(222, 184, 144),
			Decay = rgb(122, 94, 72),
			Glare = 0.8,
			Haze = 2.2,
		},
		clouds = { Cover = 0.5, Density = 0.35, Color = rgb(255, 214, 182) },
		colorCorrection = { Brightness = 0.01, Contrast = 0.16, Saturation = -0.18, TintColor = rgb(255, 236, 214) },
		bloom = { Intensity = 0.6, Size = 30, Threshold = 1.2 },
		sunRays = { Intensity = 0.12, Spread = 0.7 },
		depthOfField = { FarIntensity = 0.1, FocusDistance = 150, InFocusRadius = 220, NearIntensity = 0 },
		sky = { StarCount = 0, CelestialBodiesShown = true, SunAngularSize = 18, MoonAngularSize = 8 },
		water = {
			WaterColor = rgb(70, 74, 58),
			WaterReflectance = 0.6,
			WaterTransparency = 0.4,
			WaterWaveSize = 0.1,
			WaterWaveSpeed = 8,
		},
		wind = Vector3.new(14, 0, 6),
		reverb = "Plain",
		weather = { default = "Clear", dustColor = rgb(186, 160, 120) },
	},

	-- Stalingrad / Ardennes: cold blue-white winter light, heavy grey sky.
	WinterSnow = {
		id = "WinterSnow",
		name = "Winter",
		lighting = {
			ClockTime = 11.5,
			GeographicLatitude = 52,
			Brightness = 1.8,
			Ambient = rgb(82, 88, 98),
			OutdoorAmbient = rgb(150, 158, 170),
			ColorShift_Top = rgb(210, 220, 236),
			ColorShift_Bottom = rgb(90, 96, 110),
			ExposureCompensation = -0.2,
			EnvironmentDiffuseScale = 0.7,
			EnvironmentSpecularScale = 0.5,
			ShadowSoftness = 0.7,
		},
		atmosphere = {
			Density = 0.38,
			Offset = 0.1,
			Color = rgb(200, 208, 220),
			Decay = rgb(120, 130, 148),
			Glare = 0,
			Haze = 2,
		},
		clouds = { Cover = 0.88, Density = 0.6, Color = rgb(210, 215, 222) },
		colorCorrection = { Brightness = 0, Contrast = 0.14, Saturation = -0.35, TintColor = rgb(234, 242, 255) },
		bloom = { Intensity = 0.35, Size = 24, Threshold = 1.6 },
		sunRays = { Intensity = 0.02, Spread = 0.5 },
		depthOfField = { FarIntensity = 0.14, FocusDistance = 100, InFocusRadius = 150, NearIntensity = 0 },
		sky = { StarCount = 0, CelestialBodiesShown = false, SunAngularSize = 12, MoonAngularSize = 8 },
		water = {
			WaterColor = rgb(58, 72, 82),
			WaterReflectance = 0.5,
			WaterTransparency = 0.3,
			WaterWaveSize = 0.05,
			WaterWaveSpeed = 4,
		},
		wind = Vector3.new(10, 0, -6),
		reverb = "Forest",
		weather = { default = "Snow", dustColor = rgb(120, 118, 116) },
	},

	-- Pacific: bright humid haze, saturated-but-graded greens, turquoise water.
	TropicalHaze = {
		id = "TropicalHaze",
		name = "Tropical Haze",
		lighting = {
			ClockTime = 10.5,
			GeographicLatitude = 8,
			Brightness = 2.8,
			Ambient = rgb(80, 82, 70),
			OutdoorAmbient = rgb(150, 150, 130),
			ColorShift_Top = rgb(255, 240, 210),
			ColorShift_Bottom = rgb(70, 80, 60),
			ExposureCompensation = -0.05,
			EnvironmentDiffuseScale = 0.8,
			EnvironmentSpecularScale = 0.7,
			ShadowSoftness = 0.35,
		},
		atmosphere = {
			Density = 0.32,
			Offset = 0.25,
			Color = rgb(215, 210, 182),
			Decay = rgb(130, 150, 140),
			Glare = 0.5,
			Haze = 2.6,
		},
		clouds = { Cover = 0.55, Density = 0.4, Color = rgb(250, 248, 240) },
		colorCorrection = { Brightness = 0.02, Contrast = 0.12, Saturation = -0.1, TintColor = rgb(255, 248, 230) },
		bloom = { Intensity = 0.55, Size = 28, Threshold = 1.25 },
		sunRays = { Intensity = 0.1, Spread = 0.5 },
		depthOfField = { FarIntensity = 0.1, FocusDistance = 140, InFocusRadius = 200, NearIntensity = 0 },
		sky = { StarCount = 0, CelestialBodiesShown = true, SunAngularSize = 16, MoonAngularSize = 8 },
		water = {
			WaterColor = rgb(38, 96, 90),
			WaterReflectance = 0.6,
			WaterTransparency = 0.75,
			WaterWaveSize = 0.12,
			WaterWaveSpeed = 9,
		},
		wind = Vector3.new(6, 0, 3),
		reverb = "Forest",
		weather = { default = "Clear", dustColor = rgb(200, 186, 150) },
	},

	-- Atlantic Wall: dawn landing under a black squall, wet specular, steel-grey sea.
	StormRain = {
		id = "StormRain",
		name = "Storm",
		lighting = {
			ClockTime = 7.2,
			GeographicLatitude = 49,
			Brightness = 1.2,
			Ambient = rgb(56, 60, 66),
			OutdoorAmbient = rgb(100, 106, 114),
			ColorShift_Top = rgb(150, 156, 166),
			ColorShift_Bottom = rgb(40, 44, 50),
			ExposureCompensation = -0.1,
			EnvironmentDiffuseScale = 0.5,
			EnvironmentSpecularScale = 0.7,
			ShadowSoftness = 0.9,
		},
		atmosphere = {
			Density = 0.4,
			Offset = 0.05,
			Color = rgb(140, 148, 156),
			Decay = rgb(70, 78, 88),
			Glare = 0,
			Haze = 2.3,
		},
		clouds = { Cover = 0.93, Density = 0.8, Color = rgb(122, 126, 132) },
		colorCorrection = { Brightness = -0.01, Contrast = 0.18, Saturation = -0.38, TintColor = rgb(222, 230, 238) },
		bloom = { Intensity = 0.35, Size = 20, Threshold = 1.5 },
		sunRays = { Intensity = 0, Spread = 0.3 },
		depthOfField = { FarIntensity = 0.16, FocusDistance = 90, InFocusRadius = 130, NearIntensity = 0 },
		sky = { StarCount = 0, CelestialBodiesShown = false, SunAngularSize = 10, MoonAngularSize = 8 },
		water = {
			WaterColor = rgb(42, 60, 64),
			WaterReflectance = 0.35,
			WaterTransparency = 0.35,
			WaterWaveSize = 0.35,
			WaterWaveSpeed = 22,
		},
		wind = Vector3.new(28, 0, 10),
		reverb = "Mountains",
		weather = { default = "Storm", dustColor = rgb(110, 110, 108) },
	},

	-- Sicily: harsh midday sun on limestone, bleached warm grade, deep blue sea.
	Mediterranean = {
		id = "Mediterranean",
		name = "Mediterranean",
		lighting = {
			ClockTime = 14.2,
			GeographicLatitude = 37,
			Brightness = 3,
			Ambient = rgb(92, 84, 72),
			OutdoorAmbient = rgb(160, 150, 130),
			ColorShift_Top = rgb(255, 236, 200),
			ColorShift_Bottom = rgb(90, 80, 62),
			ExposureCompensation = -0.15,
			EnvironmentDiffuseScale = 0.8,
			EnvironmentSpecularScale = 0.6,
			ShadowSoftness = 0.2,
		},
		atmosphere = {
			Density = 0.26,
			Offset = 0.3,
			Color = rgb(230, 215, 190),
			Decay = rgb(150, 140, 120),
			Glare = 0.4,
			Haze = 1.8,
		},
		clouds = { Cover = 0.35, Density = 0.25, Color = rgb(255, 250, 240) },
		colorCorrection = { Brightness = 0.02, Contrast = 0.15, Saturation = -0.12, TintColor = rgb(255, 244, 226) },
		bloom = { Intensity = 0.5, Size = 26, Threshold = 1.3 },
		sunRays = { Intensity = 0.08, Spread = 0.6 },
		depthOfField = { FarIntensity = 0.1, FocusDistance = 160, InFocusRadius = 230, NearIntensity = 0 },
		sky = { StarCount = 0, CelestialBodiesShown = true, SunAngularSize = 14, MoonAngularSize = 8 },
		water = {
			WaterColor = rgb(34, 92, 112),
			WaterReflectance = 0.7,
			WaterTransparency = 0.85,
			WaterWaveSize = 0.08,
			WaterWaveSpeed = 8,
		},
		wind = Vector3.new(8, 0, 2),
		reverb = "Mountains",
		weather = { default = "Clear", dustColor = rgb(206, 190, 160) },
	},

	-- Optional night variant: moonlit blue, readable silhouettes, muzzle flashes pop.
	Night = {
		id = "Night",
		name = "Night",
		lighting = {
			ClockTime = 1.5,
			GeographicLatitude = 48,
			Brightness = 0.6,
			Ambient = rgb(44, 48, 62),
			OutdoorAmbient = rgb(70, 78, 102),
			ColorShift_Top = rgb(140, 160, 200),
			ColorShift_Bottom = rgb(30, 34, 46),
			ExposureCompensation = 0.35,
			EnvironmentDiffuseScale = 0.5,
			EnvironmentSpecularScale = 0.5,
			ShadowSoftness = 0.5,
		},
		atmosphere = {
			Density = 0.36,
			Offset = 0.1,
			Color = rgb(72, 82, 104),
			Decay = rgb(30, 36, 52),
			Glare = 0,
			Haze = 1.5,
		},
		clouds = { Cover = 0.6, Density = 0.45, Color = rgb(62, 68, 82) },
		colorCorrection = { Brightness = 0.03, Contrast = 0.1, Saturation = -0.3, TintColor = rgb(204, 216, 255) },
		bloom = { Intensity = 0.7, Size = 28, Threshold = 1 },
		sunRays = { Intensity = 0, Spread = 0.3 },
		depthOfField = { FarIntensity = 0.12, FocusDistance = 90, InFocusRadius = 140, NearIntensity = 0 },
		sky = { StarCount = 3000, CelestialBodiesShown = true, SunAngularSize = 10, MoonAngularSize = 11 },
		water = {
			WaterColor = rgb(20, 28, 38),
			WaterReflectance = 0.6,
			WaterTransparency = 0.3,
			WaterWaveSize = 0.12,
			WaterWaveSpeed = 8,
		},
		wind = Vector3.new(6, 0, 4),
		reverb = "Plain",
		weather = { default = "Clear", dustColor = rgb(80, 84, 96) },
	},
}

local function mod(over: { [string]: any }): WeatherModifier
	local base: { [string]: any } = {
		brightnessMult = 1,
		exposureAdd = 0,
		densityAdd = 0,
		hazeAdd = 0,
		glareMult = 1,
		cloudCoverMin = 0,
		cloudDensityMin = 0,
		cloudDarken = 0,
		saturationAdd = 0,
		contrastAdd = 0,
		sunRaysMult = 1,
		windMult = 1,
		waveMult = 1,
		rain = 0,
		snow = 0,
		fog = 0,
		lightning = false,
	}
	for k, v in over do
		base[k] = v
	end
	return base :: any
end

local Weather: { [string]: WeatherModifier } = {
	Clear = mod({}),
	Fog = mod({
		brightnessMult = 0.85,
		densityAdd = 0.17,
		hazeAdd = 1.6,
		glareMult = 0.3,
		cloudCoverMin = 0.75,
		saturationAdd = -0.05,
		contrastAdd = -0.03,
		sunRaysMult = 0.3,
		windMult = 0.4,
		fog = 1,
	}),
	Rain = mod({
		brightnessMult = 0.72,
		exposureAdd = -0.05,
		densityAdd = 0.1,
		hazeAdd = 1,
		glareMult = 0,
		cloudCoverMin = 0.88,
		cloudDensityMin = 0.65,
		cloudDarken = 0.35,
		saturationAdd = -0.08,
		sunRaysMult = 0.15,
		windMult = 1.6,
		waveMult = 1.6,
		rain = 0.7,
		fog = 0.35,
	}),
	Storm = mod({
		brightnessMult = 0.6,
		exposureAdd = -0.1,
		densityAdd = 0.12,
		hazeAdd = 1.5,
		glareMult = 0,
		cloudCoverMin = 0.95,
		cloudDensityMin = 0.85,
		cloudDarken = 0.55,
		saturationAdd = -0.1,
		contrastAdd = 0.03,
		sunRaysMult = 0,
		windMult = 2.2,
		waveMult = 2.2,
		rain = 1,
		fog = 0.5,
		lightning = true,
	}),
	Snow = mod({
		brightnessMult = 0.9,
		densityAdd = 0.08,
		hazeAdd = 1,
		glareMult = 0,
		cloudCoverMin = 0.85,
		cloudDensityMin = 0.55,
		saturationAdd = -0.05,
		sunRaysMult = 0.3,
		windMult = 1.2,
		snow = 1,
		fog = 0.25,
	}),
}

-- Per-map environmental flavour (client particles + audio). Unknown maps fall back to `Default`.
export type MapAmbience = {
	reverb: string?, -- overrides the preset reverb outdoors
	indoorReverb: string, -- used when a roof is overhead
	dust: number, -- wind-blown dust density 0..1
	ash: number, -- falling ash/embers 0..1 (burning city)
	birds: boolean, -- bird chirps in Clear weather
	battle: number, -- distant battle ambience intensity 0..1
	horizonFires: boolean, -- distant artillery glow more frequent
}

local MapAmbience: { [string]: MapAmbience } = {
	Default = { indoorReverb = "Room", dust = 0, ash = 0, birds = true, battle = 0.6, horizonFires = false },
	Normandy = {
		reverb = "Plain",
		indoorReverb = "StoneRoom",
		dust = 0,
		ash = 0,
		birds = true,
		battle = 0.6,
		horizonFires = false,
	},
	Stalingrad = {
		reverb = "City",
		indoorReverb = "StoneRoom",
		dust = 0.6,
		ash = 1,
		birds = false,
		battle = 1,
		horizonFires = true,
	},
	Kursk = {
		reverb = "Plain",
		indoorReverb = "Room",
		dust = 0.8,
		ash = 0.2,
		birds = true,
		battle = 0.9,
		horizonFires = true,
	},
	AtlanticWall = {
		reverb = "Mountains",
		indoorReverb = "Hangar",
		dust = 0,
		ash = 0,
		birds = false,
		battle = 1,
		horizonFires = false,
	},
	Ardennes = {
		reverb = "Forest",
		indoorReverb = "Room",
		dust = 0,
		ash = 0,
		birds = false,
		battle = 0.6,
		horizonFires = false,
	},
	Pacific = {
		reverb = "Forest",
		indoorReverb = "Room",
		dust = 0.1,
		ash = 0,
		birds = true,
		battle = 0.7,
		horizonFires = false,
	},
	Sicily = {
		reverb = "Mountains",
		indoorReverb = "StoneRoom",
		dust = 0.4,
		ash = 0,
		birds = true,
		battle = 0.6,
		horizonFires = false,
	},
}

local LightingPresets = {
	byId = Presets,
	Weather = Weather,
	MapAmbience = MapAmbience,
	DEFAULT = "Overcast",
}

function LightingPresets.get(id: string?): Preset
	return (id and Presets[id]) or Presets.Overcast
end

function LightingPresets.getWeather(weather: string?): WeatherModifier
	return (weather and Weather[weather]) or Weather.Clear
end

function LightingPresets.getAmbience(mapId: string?): MapAmbience
	return (mapId and MapAmbience[mapId]) or MapAmbience.Default
end

-- Resolves the effective weather: GameState value if valid, else the preset default.
function LightingPresets.resolveWeather(presetId: string?, weather: string?): string
	if weather and Weather[weather] then
		return weather
	end
	return LightingPresets.get(presetId).weather.default
end

return LightingPresets
