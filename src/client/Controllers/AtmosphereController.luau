--[[
	AtmosphereController (client): weather particles and ambient sky events.

	  * Rain (far + near streak layers, ground splashes), snow, ground fog banks, wind-blown dust
	    and falling ash/embers, all on camera-following rigs. Driven by GameState LightingPreset /
	    Weather / MapId through Config/LightingPresets (Weather modifiers + MapAmbience).
	  * Indoor detection (roof raycasts) fades precipitation out under cover so rain never falls
	    through ceilings.
	  * FX_Lightning {position, intensity}: screen flash (client-only ColorCorrection), a jagged
	    bolt on the horizon, then thunder delayed by distance / speed of sound.
	  * FX_DistantArtillery {position, count, spacing}: horizon muzzle/impact flashes, smoke plumes
	    and a delayed 3D rumble.
	  * Everything scales with SettingsController GraphicsQuality (1..3).

	Public helpers:
	    AtmosphereController.IsIndoors() -> boolean
	    AtmosphereController.GetWeather() -> string  -- effective weather id
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameState = require(Shared.GameState)
local LightingPresets = require(Shared.Config.LightingPresets)
local Sounds = require(Shared.Config.Sounds)
local Bus = require(Shared.Util.Bus)

local AtmosphereController = {}

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"

local HIDDEN = CFrame.new(0, -10000, 0)
local SPEED_OF_SOUND = Sounds.SPEED_OF_SOUND

-- Per GraphicsQuality (1..3)
local RAIN_RATE = { 260, 600, 1000 }
local NEAR_RAIN_RATE = { 0, 120, 220 }
local SNOW_RATE = { 90, 200, 340 }
local SPLASHES_PER_STEP = { 2, 5, 9 }
local FOG_RATE = { 0.5, 0.9, 1.4 }
local DUST_RATE = { 0.8, 1.6, 2.6 }
local ASH_RATE = { 10, 24, 40 }

local rng = Random.new()
local quality = 2
local folder: Folder = nil :: any

local skyRig: Part = nil :: any -- precipitation (above camera)
local nearRig: Part = nil :: any -- close rain streaks
local groundRig: Part = nil :: any -- fog/dust (camera ground level)
local splashRig: Part = nil :: any
local em: { [string]: ParticleEmitter } = {}

local flashCC: ColorCorrectionEffect? = nil
local boltParts: { Part } = {}
local horizonRigs: { { part: Part, flash: ParticleEmitter, plume: ParticleEmitter, light: PointLight, gen: number } } =
	{}
local horizonCursor = 0

local indoors = false
local coverAlpha = 0 -- smoothed 0 (open sky) .. 1 (roofed)
local groundY = 0
local lastCamPos = Vector3.zero
local camVelocity = Vector3.zero

-- Current targets (from GameState)
local target = {
	weather = "Clear",
	rain = 0,
	snow = 0,
	fog = 0,
	dust = 0,
	ash = 0,
	dustColor = Color3.fromRGB(150, 140, 120),
	fogColor = Color3.fromRGB(200, 200, 200),
	dark = false,
}

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

local function ns(...: number): NumberSequence
	local args = { ... }
	local keys = {}
	for i = 1, #args, 2 do
		table.insert(keys, NumberSequenceKeypoint.new(args[i], args[i + 1]))
	end
	return NumberSequence.new(keys)
end

local function nr(a: number, b: number?): NumberRange
	return NumberRange.new(a, b or a)
end

local function cs(a: Color3, b: Color3?): ColorSequence
	return ColorSequence.new(a, b or a)
end

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function camPos(): Vector3
	local cam = workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

local function newPart(name: string, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Locked = true
	p.CFrame = HIDDEN
	p.Parent = folder
	return p
end

local function emitter(parent: Instance, name: string, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Enabled = false
	e.Rate = 0
	e.Texture = TEX_SMOKE
	e.LightInfluence = 1
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	return e
end

local function getController(name: string): any
	local m = script.Parent and script.Parent:FindFirstChild(name)
	if m and m:IsA("ModuleScript") then
		local ok, result = pcall(require, m)
		if ok then
			return result
		end
	end
	return nil
end

local function sound(): any
	local sc = getController("SoundController")
	return if sc and type(sc.Play2D) == "function" then sc else nil
end

local function refreshQuality()
	local settings = getController("SettingsController")
	if settings and type(settings.Get) == "function" then
		local ok, q = pcall(settings.Get, "GraphicsQuality")
		if ok and type(q) == "number" then
			quality = math.clamp(math.floor(q + 0.5), 1, 3)
			return
		end
	end
	quality = 2
end

local function onRemote(name: string, fn: (...any) -> ())
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local function hook(r: Instance)
		if r:IsA("RemoteEvent") then
			r.OnClientEvent:Connect(fn)
		elseif r:IsA("UnreliableRemoteEvent") then
			r.OnClientEvent:Connect(fn)
		end
	end
	local existing = remotes:FindFirstChild(name)
	if existing then
		hook(existing)
		return
	end
	local conn: RBXScriptConnection
	conn = remotes.ChildAdded:Connect(function(child)
		if child.Name == name then
			conn:Disconnect()
			hook(child)
		end
	end)
end

-- Minimal timed-animation list (single loop, no per-effect threads).
type Anim = { t0: number, duration: number, step: (alpha: number) -> (), done: (() -> ())? }
local anims: { Anim } = {}
local function animate(delay: number, duration: number, step: (alpha: number) -> (), done: (() -> ())?)
	if #anims > 120 then
		return
	end
	table.insert(anims, { t0 = os.clock() + delay, duration = math.max(duration, 1e-3), step = step, done = done })
end
local function stepAnims(now: number)
	local i = 1
	while i <= #anims do
		local a = anims[i]
		if now < a.t0 then
			i += 1
			continue
		end
		local alpha = math.min((now - a.t0) / a.duration, 1)
		a.step(alpha)
		if alpha >= 1 then
			if a.done then
				a.done()
			end
			anims[i] = anims[#anims]
			anims[#anims] = nil
		else
			i += 1
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------------------------------

local function build()
	skyRig = newPart("WeatherSky", Vector3.new(130, 1, 130))
	em.rain = emitter(skyRig, "Rain", {
		Lifetime = nr(0.65, 0.8),
		Speed = nr(95, 115),
		EmissionDirection = Enum.NormalId.Bottom,
		SpreadAngle = Vector2.new(3, 3),
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		Color = cs(rgb(196, 206, 218)),
		Size = ns(0, 0.09, 1, 0.09),
		Squash = ns(0, 2.6, 1, 2.6),
		Transparency = ns(0, 0.5, 1, 0.6),
		LightEmission = 0.15,
		LightInfluence = 0.8,
		WindAffectsDrag = true,
		Drag = 0.2,
	})
	em.snow = emitter(skyRig, "Snow", {
		Lifetime = nr(6, 9),
		Speed = nr(5, 9),
		EmissionDirection = Enum.NormalId.Bottom,
		SpreadAngle = Vector2.new(25, 25),
		Color = cs(rgb(250, 252, 255)),
		Size = ns(0, 0.22, 1, 0.18),
		Transparency = ns(0, 1, 0.08, 0.1, 0.9, 0.2, 1, 1),
		Rotation = nr(0, 360),
		RotSpeed = nr(-60, 60),
		Drag = 0.6,
		WindAffectsDrag = true,
		LightInfluence = 0.9,
	})
	em.ash = emitter(skyRig, "Ash", {
		Lifetime = nr(7, 11),
		Speed = nr(3, 6),
		EmissionDirection = Enum.NormalId.Bottom,
		SpreadAngle = Vector2.new(35, 35),
		Color = cs(rgb(70, 68, 66), rgb(120, 116, 112)),
		Size = ns(0, 0.16, 1, 0.12),
		Transparency = ns(0, 1, 0.1, 0.15, 0.9, 0.3, 1, 1),
		Rotation = nr(0, 360),
		RotSpeed = nr(-90, 90),
		Drag = 0.8,
		WindAffectsDrag = true,
	})
	em.embers = emitter(skyRig, "Embers", {
		Texture = TEX_SPARK,
		Lifetime = nr(4, 7),
		Speed = nr(2, 5),
		EmissionDirection = Enum.NormalId.Bottom,
		SpreadAngle = Vector2.new(50, 50),
		Color = cs(rgb(255, 160, 70)),
		Size = ns(0, 0.12, 1, 0.04),
		Transparency = ns(0, 0, 1, 1),
		LightEmission = 1,
		LightInfluence = 0,
		Brightness = 2,
		Drag = 1,
		WindAffectsDrag = true,
	})

	nearRig = newPart("WeatherNear", Vector3.new(26, 1, 26))
	em.nearRain = emitter(nearRig, "NearRain", {
		Lifetime = nr(0.25, 0.32),
		Speed = nr(95, 110),
		EmissionDirection = Enum.NormalId.Bottom,
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		Color = cs(rgb(206, 214, 224)),
		Size = ns(0, 0.06, 1, 0.06),
		Squash = ns(0, 2.8, 1, 2.8),
		Transparency = ns(0, 0.55, 1, 0.65),
		LightInfluence = 0.8,
		WindAffectsDrag = true,
		Drag = 0.2,
	})

	groundRig = newPart("WeatherGround", Vector3.new(320, 6, 320))
	em.fog = emitter(groundRig, "FogBanks", {
		Lifetime = nr(16, 24),
		Speed = nr(0.5, 2),
		SpreadAngle = Vector2.new(180, 10),
		Color = cs(rgb(200, 200, 200)),
		Size = ns(0, 30, 0.5, 55, 1, 70),
		Transparency = ns(0, 1, 0.3, 0.84, 0.7, 0.86, 1, 1),
		Rotation = nr(0, 360),
		RotSpeed = nr(-3, 3),
		Drag = 0.3,
		WindAffectsDrag = true,
	})
	em.dust = emitter(groundRig, "Dust", {
		Lifetime = nr(6, 10),
		Speed = nr(2, 6),
		SpreadAngle = Vector2.new(180, 15),
		Color = cs(rgb(160, 140, 110)),
		Size = ns(0, 6, 1, 22),
		Transparency = ns(0, 1, 0.3, 0.86, 1, 1),
		Rotation = nr(0, 360),
		RotSpeed = nr(-8, 8),
		Drag = 0.5,
		WindAffectsDrag = true,
	})

	splashRig = newPart("RainSplash", Vector3.new(0.2, 0.2, 0.2))
	em.splash = emitter(splashRig, "Splash", {
		Lifetime = nr(0.18, 0.3),
		Speed = nr(2, 5),
		EmissionDirection = Enum.NormalId.Top,
		SpreadAngle = Vector2.new(55, 55),
		Acceleration = Vector3.new(0, -30, 0),
		Color = cs(rgb(220, 228, 236)),
		Size = ns(0, 0.12, 1, 0.45),
		Transparency = ns(0, 0.35, 1, 1),
	})

	-- Lightning flash grade (client-only; never touches server-owned Lighting properties).
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "WW2_LightningFlash"
	cc.Enabled = false
	cc.TintColor = rgb(225, 235, 255)
	cc.Parent = Lighting
	flashCC = cc

	-- Lightning bolt segments.
	for i = 1, 14 do
		local p = newPart("Bolt" .. i, Vector3.new(3, 3, 10))
		p.Material = Enum.Material.Neon
		p.Color = rgb(222, 232, 255)
		table.insert(boltParts, p)
	end

	-- Horizon artillery rigs.
	for i = 1, 5 do
		local part = newPart("Horizon" .. i, Vector3.new(8, 8, 8))
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 170, 90)
		light.Range = 60
		light.Brightness = 0
		light.Shadows = false
		light.Enabled = false
		light.Parent = part
		table.insert(horizonRigs, {
			part = part,
			light = light,
			gen = 0,
			flash = emitter(part, "Flash", {
				Texture = TEX_FIRE,
				Lifetime = nr(0.2, 0.35),
				Speed = nr(0),
				LightEmission = 1,
				LightInfluence = 0,
				Brightness = 4,
				Color = cs(rgb(255, 220, 160), rgb(255, 120, 40)),
				Size = ns(0, 30, 1, 70),
				Transparency = ns(0, 0, 1, 1),
				Rotation = nr(0, 360),
			}),
			plume = emitter(part, "Plume", {
				Lifetime = nr(9, 14),
				Speed = nr(6, 12),
				EmissionDirection = Enum.NormalId.Top,
				SpreadAngle = Vector2.new(15, 15),
				Color = cs(rgb(56, 52, 48), rgb(110, 104, 98)),
				Size = ns(0, 30, 1, 110),
				Transparency = ns(0, 0.4, 0.6, 0.6, 1, 1),
				Rotation = nr(0, 360),
				RotSpeed = nr(-4, 4),
				Drag = 0.3,
				WindAffectsDrag = true,
			}),
		})
	end
end

---------------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------------

local function refreshTarget()
	local presetId = GameState.get("LightingPreset")
	local preset = LightingPresets.get(presetId)
	local weatherId = LightingPresets.resolveWeather(presetId, GameState.get("Weather"))
	local w = LightingPresets.getWeather(weatherId)
	local ambience = LightingPresets.getAmbience(GameState.get("MapId"))
	target.weather = weatherId
	target.rain = w.rain
	target.snow = w.snow
	target.fog = w.fog
	target.dust = if w.rain > 0 or w.snow > 0.5 then ambience.dust * 0.3 else ambience.dust
	target.ash = ambience.ash
	target.dustColor = preset.weather.dustColor
	target.fogColor = preset.atmosphere.Color
	target.dark = preset.lighting.Brightness * w.brightnessMult < 1.4 or preset.lighting.ClockTime < 6

	if em.fog then
		em.fog.Color = cs(target.fogColor:Lerp(rgb(255, 255, 255), 0.15))
		em.dust.Color = cs(target.dustColor)
	end
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function refreshFilter()
	local exclude: { Instance } = { folder }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	local fx = workspace:FindFirstChild("ClientFX")
	if fx then
		table.insert(exclude, fx)
	end
	rayParams.FilterDescendantsInstances = exclude
end

local function probeEnvironment()
	refreshFilter()
	local origin = camPos()
	local up = workspace:Raycast(origin, Vector3.new(0, 80, 0), rayParams)
	local covered = false
	if up then
		local cam = workspace.CurrentCamera
		local offset = if cam then cam.CFrame.LookVector * Vector3.new(4, 0, 4) else Vector3.new(3, 0, 0)
		covered = workspace:Raycast(origin + offset, Vector3.new(0, 80, 0), rayParams) ~= nil
	end
	indoors = covered
	local down = workspace:Raycast(origin + Vector3.new(0, 2, 0), Vector3.new(0, -300, 0), rayParams)
	groundY = if down then down.Position.Y else origin.Y - 6
end

---------------------------------------------------------------------------------------------------
-- Per-frame
---------------------------------------------------------------------------------------------------

local splashAcc = 0
-- Emitter writes only when the value actually changes (steady-state weather writes nothing).
local function setEmitter(e: ParticleEmitter, rate: number, enabled: boolean)
	if math.abs(e.Rate - rate) > 0.05 then
		e.Rate = rate
	end
	if e.Enabled ~= enabled then
		e.Enabled = enabled
	end
end

local function stepWeather(dt: number)
	local cam = camPos()
	if dt > 0 then
		camVelocity = camVelocity:Lerp((cam - lastCamPos) / dt, math.clamp(dt * 4, 0, 1))
	end
	lastCamPos = cam
	if camVelocity.Magnitude > 200 then
		camVelocity = Vector3.zero -- teleport / respawn
	end

	coverAlpha += ((if indoors then 1 else 0) - coverAlpha) * math.clamp(dt * 5, 0, 1)
	local open = 1 - coverAlpha

	-- Lead the rigs in the movement direction so vehicles do not outrun the weather.
	local lead = Vector3.new(camVelocity.X, 0, camVelocity.Z) * 0.6
	skyRig.CFrame = CFrame.new(cam + lead + Vector3.new(0, if target.snow > 0 then 28 else 38, 0))
	nearRig.CFrame = CFrame.new(cam + lead * 0.3 + Vector3.new(0, 14, 0))
	groundRig.CFrame = CFrame.new(Vector3.new(cam.X, groundY + 4, cam.Z) + lead)

	local q = quality
	local rain = target.rain * open
	setEmitter(em.rain, RAIN_RATE[q] * rain, rain > 0.02)
	setEmitter(em.nearRain, NEAR_RAIN_RATE[q] * rain, rain > 0.02 and q >= 2)
	local snow = target.snow * open
	setEmitter(em.snow, SNOW_RATE[q] * snow, snow > 0.02)
	local ash = target.ash * open
	setEmitter(em.ash, ASH_RATE[q] * ash, ash > 0.02)
	setEmitter(em.embers, ASH_RATE[q] * 0.15 * ash, ash > 0.3 and q >= 2)
	-- Fog/dust are volumetric-ish: keep them indoors too (they drift in through openings).
	setEmitter(em.fog, FOG_RATE[q] * target.fog, target.fog > 0.02)
	setEmitter(em.dust, DUST_RATE[q] * target.dust, target.dust > 0.02)

	-- Rain splashes on whatever surface is below random points around the camera.
	if rain > 0.05 then
		splashAcc += dt
		if splashAcc >= 1 / 30 then
			splashAcc = 0
			local n = math.ceil(SPLASHES_PER_STEP[q] * rain)
			for _ = 1, n do
				local a = rng:NextNumber(0, math.pi * 2)
				local r = math.sqrt(rng:NextNumber()) * 30
				local from = cam + Vector3.new(math.cos(a) * r, 30, math.sin(a) * r)
				local hit = workspace:Raycast(from, Vector3.new(0, -80, 0), rayParams)
				if hit then
					splashRig.CFrame = CFrame.new(hit.Position)
					em.splash:Emit(1)
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Lightning
---------------------------------------------------------------------------------------------------

local function flash(intensity: number, darkScene: boolean)
	local cc = flashCC
	if not cc then
		return
	end
	local peak = intensity * (if darkScene then 0.45 else 0.25)
	-- Three flickers: strong, dim, medium.
	local pulses = { { 0, 0.09, peak }, { 0.13, 0.07, peak * 0.4 }, { 0.24, 0.16, peak * 0.75 } }
	for _, p in pulses do
		local delay, dur, amount = p[1], p[2], p[3]
		animate(delay, dur, function(alpha)
			cc.Enabled = true
			cc.Brightness = amount * (1 - alpha) ^ 1.5
			cc.Contrast = -amount * 0.3 * (1 - alpha)
		end, function()
			if cc.Brightness < 0.01 then
				cc.Enabled = false
			end
		end)
	end
	animate(0.5, 0.01, function()
		cc.Enabled = false
		cc.Brightness = 0
		cc.Contrast = 0
	end)
end

local function bolt(groundPos: Vector3, intensity: number)
	local top = groundPos + Vector3.new(rng:NextNumber(-80, 80), rng:NextNumber(450, 650), rng:NextNumber(-80, 80))
	local n = #boltParts
	local points = { top }
	for i = 1, n do
		local t = i / n
		local base = top:Lerp(groundPos, t)
		local jitter = if i == n then Vector3.zero else Vector3.new(rng:NextNumber(-35, 35), 0, rng:NextNumber(-35, 35))
		table.insert(points, base + jitter)
	end
	local width = 2.5 + intensity * 3
	for i = 1, n do
		local a, b = points[i], points[i + 1]
		local p = boltParts[i]
		local len = (b - a).Magnitude
		p.Size = Vector3.new(width, width, len)
		p.CFrame = CFrame.lookAt((a + b) / 2, b)
		p.Transparency = 0
	end
	animate(0, 0.32, function(alpha)
		-- Flicker then fade.
		local flick = if alpha < 0.4 then (if math.floor(alpha * 20) % 2 == 0 then 0 else 0.6) else alpha
		for _, p in boltParts do
			p.Transparency = math.clamp(flick, 0, 1)
		end
	end, function()
		for _, p in boltParts do
			p.Transparency = 1
			p.CFrame = HIDDEN
		end
	end)
end

local function onLightning(payload: any)
	if type(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end
	local intensity = math.clamp(tonumber(payload.intensity) or 0.8, 0.1, 1)
	local position: Vector3 = payload.position
	local cam = camPos()
	local dist = (Vector3.new(position.X, cam.Y, position.Z) - cam).Magnitude
	-- Strikes land on the horizon: put the bolt at ground level of the far point.
	local groundPos = Vector3.new(position.X, math.min(position.Y, groundY), position.Z)
	local nearness = math.clamp(1 - dist / 3000, 0.25, 1)
	flash(intensity * nearness, target.dark)
	if quality >= 2 or dist < 1500 then
		bolt(groundPos, intensity)
	end
	local sc = sound()
	if sc then
		local delay = math.min(dist / SPEED_OF_SOUND, 6)
		pcall(sc.Play2D, "Thunder", {
			delay = delay,
			volume = math.clamp(1.25 - dist / 3500, 0.35, 1.2) * intensity,
			pitch = if dist > 1500 then 0.85 else 1,
			lowpass = math.clamp(dist / 3000, 0, 0.85) + coverAlpha * 0.2,
		})
	end
end

---------------------------------------------------------------------------------------------------
-- Distant artillery
---------------------------------------------------------------------------------------------------

local function horizonImpact(position: Vector3, lingering: boolean)
	horizonCursor = horizonCursor % #horizonRigs + 1
	local rig = horizonRigs[horizonCursor]
	rig.gen += 1
	local gen = rig.gen
	rig.part.CFrame = CFrame.new(position)
	rig.flash:Emit(if quality >= 2 then 2 else 1)
	if quality >= 2 then
		rig.plume:Emit(if quality == 3 then 3 else 2)
	end
	rig.light.Enabled = true
	local life = if lingering then 2.5 else 0.6
	animate(0, life, function(alpha)
		if rig.gen == gen then
			rig.light.Brightness = 10 * (1 - alpha) ^ 2
		end
	end, function()
		if rig.gen == gen then
			rig.light.Enabled = false
		end
	end)
	-- Subtle sky glow in dark scenes.
	local cc = flashCC
	if cc and target.dark then
		animate(0, 0.4, function(alpha)
			if not cc.Enabled or cc.Brightness < 0.04 then
				cc.Enabled = alpha < 1
				cc.Brightness = 0.04 * (1 - alpha)
			end
		end, nil)
	end
	local sc = sound()
	if sc and type(sc.PlayAt) == "function" then
		local dist = (position - camPos()).Magnitude
		pcall(sc.PlayAt, "Artillery_Distant", position, {
			delay = dist / SPEED_OF_SOUND,
			lowpass = math.clamp(0.4 + dist / 4000 + coverAlpha * 0.2, 0, 0.95),
		})
	end
end

local function onArtillery(payload: any)
	if type(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end
	local n = math.clamp(math.floor(tonumber(payload.count) or 1), 1, 6)
	local spacing = math.clamp(tonumber(payload.spacing) or 0.8, 0.1, 4)
	local base: Vector3 = payload.position
	local ambience = LightingPresets.getAmbience(GameState.get("MapId"))
	for i = 1, n do
		local offset = Vector3.new(rng:NextNumber(-60, 60), 0, rng:NextNumber(-60, 60))
		local delay = (i - 1) * spacing + rng:NextNumber(0, 0.25)
		-- Drop to the horizon's ground height so flashes sit on the skyline, not in the sky.
		local pos = Vector3.new(base.X, groundY, base.Z) + offset
		animate(delay, 0.01, function() end, function()
			horizonImpact(pos, ambience.horizonFires)
		end)
	end
end

---------------------------------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------------------------------

function AtmosphereController.IsIndoors(): boolean
	return indoors
end

function AtmosphereController.GetWeather(): string
	return target.weather
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

function AtmosphereController:Init()
	local f = Instance.new("Folder")
	f.Name = "ClientWeather"
	f.Parent = workspace
	folder = f
	build()
end

function AtmosphereController:Start()
	refreshQuality()
	Bus.connect("SettingsChanged", refreshQuality)
	refreshTarget()
	for _, attr in { "LightingPreset", "Weather", "MapId" } do
		GameState.changed(attr):Connect(refreshTarget)
	end

	onRemote("FX_Lightning", onLightning)
	onRemote("FX_DistantArtillery", onArtillery)

	lastCamPos = camPos()
	probeEnvironment()
	local probeAcc, qualityAcc = 0, 0
	RunService.RenderStepped:Connect(function(dt)
		probeAcc += dt
		qualityAcc += dt
		if probeAcc >= 0.25 then
			probeAcc = 0
			probeEnvironment()
		end
		if qualityAcc >= 3 then
			qualityAcc = 0
			refreshQuality()
		end
		stepWeather(dt)
		stepAnims(os.clock())
	end)
end

return AtmosphereController
