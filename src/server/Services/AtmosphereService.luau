--[[
	AtmosphereService (server): applies LightingPresets + weather to Lighting, post effects,
	Terrain water/clouds and wind, and drives replicated ambient events.

	Driven by GameState attributes `LightingPreset` and `Weather` (written by Gameplay/MapService).
	Public API (docs/ARCHITECTURE.md section 7):
	    AtmosphereService.ApplyPreset(presetId: string, weather: string)

	Remotes created here (contract additions):
	    FX_Lightning        (all)  {position: Vector3, intensity: number (0.5..1)}
	        -> AtmosphereController flash + bolt + delayed thunder. Only while weather has lightning.
	    FX_DistantArtillery (all)  {position: Vector3, count: number, spacing: number}
	        -> AtmosphereController horizon flashes + delayed rumble. Only during Phase "InRound".

	All instances we own in Lighting are named "WW2_*" so other systems can leave them alone.
]]

local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameState = require(Shared.GameState)
local LightingPresets = require(Shared.Config.LightingPresets)
local Net = require(Shared.Util.Net)
local Bus = require(Shared.Util.Bus)

local AtmosphereService = {}

local currentPreset = LightingPresets.DEFAULT
local currentWeather = "Clear"
local rng = Random.new()

local lightningRemote: RemoteEvent? = nil
local artilleryRemote: RemoteEvent? = nil

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

-- Finds (or creates) a uniquely named child of a given class we own.
local function owned<T>(parent: Instance, className: string, name: string): T
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing :: any
	end
	if existing then
		existing:Destroy()
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst :: any
end

local function darken(c: Color3, amount: number): Color3
	return c:Lerp(Color3.fromRGB(70, 72, 78), math.clamp(amount, 0, 1))
end

-- Public bounds of the current map (from GameState.MapInfoJson); falls back to a 1500 stud square.
local function mapBounds(): (Vector3, Vector3)
	local json = GameState.get("MapInfoJson")
	if type(json) == "string" and json ~= "" then
		local ok, info = pcall(HttpService.JSONDecode, HttpService, json)
		if ok and type(info) == "table" and type(info.bounds) == "table" then
			local b = info.bounds
			local cx, cy, cz = tonumber(b.cx), tonumber(b.cy), tonumber(b.cz)
			local sx, sy, sz = tonumber(b.sx), tonumber(b.sy), tonumber(b.sz)
			if cx and cy and cz and sx and sy and sz then
				return Vector3.new(cx, cy, cz), Vector3.new(sx, sy, sz)
			end
		end
	end
	return Vector3.zero, Vector3.new(1500, 200, 1500)
end

-- Random point on a ring beyond the map edge (for distant strikes/artillery).
local function pointBeyondMap(minExtra: number, maxExtra: number): Vector3
	local center, size = mapBounds()
	local radius = math.max(size.X, size.Z) * 0.5 + rng:NextNumber(minExtra, maxExtra)
	local angle = rng:NextNumber(0, math.pi * 2)
	return center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

---------------------------------------------------------------------------------------------------
-- Apply
---------------------------------------------------------------------------------------------------

function AtmosphereService.ApplyPreset(presetId: string, weather: string)
	local preset = LightingPresets.get(presetId)
	local weatherId = LightingPresets.resolveWeather(preset.id, weather)
	local w = LightingPresets.getWeather(weatherId)
	currentPreset = preset.id
	currentWeather = weatherId

	-- Lighting core
	local L = preset.lighting
	Lighting.ClockTime = L.ClockTime
	Lighting.GeographicLatitude = L.GeographicLatitude
	Lighting.Brightness = L.Brightness * w.brightnessMult
	Lighting.Ambient = L.Ambient
	Lighting.OutdoorAmbient = L.OutdoorAmbient
	Lighting.ColorShift_Top = L.ColorShift_Top
	Lighting.ColorShift_Bottom = L.ColorShift_Bottom
	Lighting.ExposureCompensation = L.ExposureCompensation + w.exposureAdd
	Lighting.EnvironmentDiffuseScale = L.EnvironmentDiffuseScale
	Lighting.EnvironmentSpecularScale = L.EnvironmentSpecularScale
	Lighting.ShadowSoftness = L.ShadowSoftness
	Lighting.GlobalShadows = true
	-- Atmosphere overrides classic fog, but keep it sane in case the Atmosphere is removed.
	Lighting.FogColor = preset.atmosphere.Color
	Lighting.FogStart = 0
	Lighting.FogEnd = 100000

	-- Only one Atmosphere/Sky is honoured: remove foreign ones so ours wins.
	for _, child in Lighting:GetChildren() do
		if (child:IsA("Atmosphere") or child:IsA("Sky")) and not string.find(child.Name, "^WW2_") then
			child:Destroy()
		end
	end

	local A = preset.atmosphere
	local atmosphere = owned(Lighting, "Atmosphere", "WW2_Atmosphere") :: Atmosphere
	atmosphere.Density = math.clamp(A.Density + w.densityAdd, 0, 0.7)
	atmosphere.Offset = A.Offset
	atmosphere.Color = A.Color
	atmosphere.Decay = darken(A.Decay, w.cloudDarken * 0.5)
	atmosphere.Glare = A.Glare * w.glareMult
	atmosphere.Haze = math.clamp(A.Haze + w.hazeAdd, 0, 10)

	-- Default Roblox skybox (a fresh Sky with default textures) + celestial settings.
	local sky = owned(Lighting, "Sky", "WW2_Sky") :: Sky
	sky.StarCount = preset.sky.StarCount
	sky.CelestialBodiesShown = preset.sky.CelestialBodiesShown and w.cloudCoverMin < 0.9
	sky.SunAngularSize = preset.sky.SunAngularSize
	sky.MoonAngularSize = preset.sky.MoonAngularSize

	local C = preset.colorCorrection
	local cc = owned(Lighting, "ColorCorrectionEffect", "WW2_Grade") :: ColorCorrectionEffect
	cc.Brightness = C.Brightness
	cc.Contrast = math.clamp(C.Contrast + w.contrastAdd, -0.2, 0.3)
	cc.Saturation = math.clamp(C.Saturation + w.saturationAdd, -0.6, 0.2)
	cc.TintColor = C.TintColor
	cc.Enabled = true

	local bloom = owned(Lighting, "BloomEffect", "WW2_Bloom") :: BloomEffect
	bloom.Intensity = preset.bloom.Intensity
	bloom.Size = preset.bloom.Size
	bloom.Threshold = preset.bloom.Threshold

	local rays = owned(Lighting, "SunRaysEffect", "WW2_SunRays") :: SunRaysEffect
	rays.Intensity = preset.sunRays.Intensity * w.sunRaysMult
	rays.Spread = preset.sunRays.Spread
	rays.Enabled = rays.Intensity > 0.001

	local D = preset.depthOfField
	local dof = owned(Lighting, "DepthOfFieldEffect", "WW2_DoF") :: DepthOfFieldEffect
	dof.FarIntensity = D.FarIntensity
	dof.FocusDistance = D.FocusDistance
	dof.InFocusRadius = D.InFocusRadius
	dof.NearIntensity = D.NearIntensity

	-- Terrain: clouds, water, decoration
	local terrain = workspace.Terrain
	local clouds = owned(terrain, "Clouds", "WW2_Clouds") :: Clouds
	clouds.Cover = math.max(preset.clouds.Cover, w.cloudCoverMin)
	clouds.Density = math.max(preset.clouds.Density, w.cloudDensityMin)
	clouds.Color = darken(preset.clouds.Color, w.cloudDarken)
	clouds.Enabled = true

	local W = preset.water
	terrain.WaterColor = W.WaterColor
	terrain.WaterReflectance = W.WaterReflectance
	terrain.WaterTransparency = W.WaterTransparency
	terrain.WaterWaveSize = math.clamp(W.WaterWaveSize * w.waveMult, 0, 1)
	terrain.WaterWaveSpeed = math.clamp(W.WaterWaveSpeed * w.waveMult, 0, 100)
	-- Decoration (animated grass) is not scriptable in every environment; best effort.
	pcall(function()
		(terrain :: any).Decoration = true
	end)

	workspace.GlobalWind = preset.wind * w.windMult
end

function AtmosphereService.GetCurrent(): (string, string)
	return currentPreset, currentWeather
end

local function applyFromState()
	local ok, err = pcall(AtmosphereService.ApplyPreset, GameState.get("LightingPreset"), GameState.get("Weather"))
	if not ok then
		warn(`[AtmosphereService] apply failed: {err}`)
	end
end

---------------------------------------------------------------------------------------------------
-- Ambient event loops
---------------------------------------------------------------------------------------------------

local function lightningLoop()
	while true do
		local w = LightingPresets.getWeather(currentWeather)
		if w.lightning and lightningRemote then
			-- Mostly far strikes (beyond the map) with the occasional close one for drama.
			local position = if rng:NextNumber() < 0.2 then pointBeyondMap(-200, 100) else pointBeyondMap(300, 1400)
			local intensity = rng:NextNumber(0.5, 1)
			lightningRemote:FireAllClients({ position = position, intensity = intensity })
			task.wait(rng:NextNumber(7, 22))
		else
			task.wait(3)
		end
	end
end

local function artilleryLoop()
	while true do
		local phase = GameState.get("Phase")
		local ambience = LightingPresets.getAmbience(GameState.get("MapId"))
		if phase == "InRound" and artilleryRemote and ambience.battle > 0 then
			artilleryRemote:FireAllClients({
				position = pointBeyondMap(500, 1600),
				count = rng:NextInteger(1, 4),
				spacing = rng:NextNumber(0.4, 1.4),
			})
			-- Modest frequency: busier maps (battle ~1) every ~20-40s, calmer ones every ~35-70s.
			local scale = 1 / math.max(ambience.battle, 0.35)
			task.wait(rng:NextNumber(20, 40) * scale)
		else
			task.wait(5)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

function AtmosphereService:Init()
	lightningRemote = Net.event("FX_Lightning")
	artilleryRemote = Net.event("FX_DistantArtillery")
end

function AtmosphereService:Start()
	applyFromState()
	GameState.changed("LightingPreset"):Connect(applyFromState)
	GameState.changed("Weather"):Connect(applyFromState)
	-- Map rebuilds may reset terrain water/clouds; re-apply after every load.
	Bus.connect("MapLoaded", function()
		task.defer(applyFromState)
	end)
	task.spawn(lightningLoop)
	task.spawn(artilleryLoop)
end

return AtmosphereService
