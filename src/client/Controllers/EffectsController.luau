--[[
	EffectsController (client): pooled, procedural combat VFX.

	Public API (docs/ARCHITECTURE.md section 7 + contract additions):
	    EffectsController.MuzzleFlash(cframe: CFrame, scale: number?)       -- LookVector = barrel
	    EffectsController.Tracer(from: Vector3, to: Vector3, color: Color3?)
	    EffectsController.TracerFor(weaponId, from, to, color?)  -- applies ~1-in-3 thinning for automatics
	    EffectsController.Impact(position: Vector3, normal: Vector3, material: Enum.Material | string)
	    EffectsController.Explosion(position: Vector3, radius: number, kind: string)
	        kind: "grenade" | "shell" | "rocket" | "satchel" | "vehicle" | "smoke"
	    EffectsController.Smoke(position: Vector3, radius: number, duration: number)  -- vision-blocking screen
	    EffectsController.ShellEject(cframe: CFrame, kind: string?)  -- "rifle" | "pistol" | "shotgun" | "mg"
	    EffectsController.Fire(target: BasePart | Vector3, duration: number?, scale: number?) -> () -> ()
	        Burning wreck/fire; returns a stop function. Destroyed vehicles (tag "Vehicle", attribute
	        Destroyed = true) get fire automatically.

	Listens to: FX_Explosion (all kinds incl. "smoke"), optional FX_Smoke {position, radius?, duration?}.

	Performance model:
	  * Every effect is a pre-built "rig" (anchored invisible part + ParticleEmitters). Particles are
	    world-space, so one rig can be moved and Emit()-ed many times per frame at different places.
	  * Physical bits (debris, shells, bullet marks, flashes, rings, scorches) come from fixed pools;
	    the oldest item is recycled when a pool is exhausted.
	  * Particle counts scale with SettingsController GraphicsQuality (1..3) and distance; per-frame
	    budgets cap impacts/explosions so a 40-player firefight cannot spike a frame.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local GameState = require(Shared.GameState)
local LightingPresets = require(Shared.Config.LightingPresets)
local Bus = require(Shared.Util.Bus)

local EffectsController = {}

local rng = Random.new()

-- Built-in particle textures (ship with the client).
local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local TEX_CORE = "rbxasset://textures/particles/explosion01_core_main.dds"

local QUALITY_MULT = { 0.4, 0.7, 1 }
local MAX_IMPACTS_PER_FRAME = { 6, 10, 16 }
local MAX_EXPLOSIONS_PER_FRAME = 3
local IMPACT_CULL = 320
local MARK_LIFE = 14
local SCORCH_LIFE = 35
local MAX_ANIMS = 300
local DEBRIS_GROUP = Constants.COLLISION_GROUPS.Debris

local fxFolder: Folder = nil :: any
local quality = 2
local impactsThisFrame = 0
local explosionsThisFrame = 0
local started = false

---------------------------------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------------------------------

local function ns(...: number): NumberSequence
	local args = { ... }
	local keys = {}
	for i = 1, #args, 2 do
		table.insert(keys, NumberSequenceKeypoint.new(args[i], args[i + 1]))
	end
	return NumberSequence.new(keys)
end

local function cs(a: Color3, b: Color3?): ColorSequence
	return ColorSequence.new(a, b or a)
end

local function nr(a: number, b: number?): NumberRange
	return NumberRange.new(a, b or a)
end

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function camPos(): Vector3
	local cam = workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

local function qmult(): number
	return QUALITY_MULT[quality] or 0.7
end

local function count(n: number, lod: number?): number
	local v = n * qmult() * (lod or 1)
	if v <= 0 then
		return 0
	end
	return math.max(1, math.floor(v + 0.5))
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
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Locked = true
	return p
end

local HIDDEN = CFrame.new(0, -10000, 0)

local function emitter(parent: Instance, name: string, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Enabled = false
	e.Rate = 0
	e.LightInfluence = 1
	e.Texture = TEX_SMOKE
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	return e
end

local function emit(e: ParticleEmitter?, n: number)
	if e and n > 0 then
		e:Emit(n)
	end
end

-- Safe CFrame looking along `dir` (handles dir parallel to world up).
local function lookAlong(pos: Vector3, dir: Vector3): CFrame
	if dir.Magnitude < 1e-4 then
		dir = Vector3.yAxis
	end
	dir = dir.Unit
	local up = if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(pos, pos + dir, up)
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

local soundController: any = nil
local function playSoundAt(key: string, position: Vector3, opts: { [string]: any }?)
	if soundController == nil then
		soundController = getController("SoundController") or false
	end
	if soundController and type(soundController.PlayAt) == "function" then
		pcall(soundController.PlayAt, key, position, opts)
	end
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

---------------------------------------------------------------------------------------------------
-- Tiny animation scheduler (one RenderStepped loop for everything, no per-effect threads)
---------------------------------------------------------------------------------------------------

type Anim = { t0: number, duration: number, step: ((alpha: number) -> ())?, done: (() -> ())? }
local anims: { Anim } = {}

local function animate(duration: number, step: ((alpha: number) -> ())?, done: (() -> ())?)
	if #anims >= MAX_ANIMS then
		-- Saturated: finish immediately rather than grow without bound.
		if step then
			step(1)
		end
		if done then
			done()
		end
		return
	end
	table.insert(anims, { t0 = os.clock(), duration = math.max(duration, 1e-3), step = step, done = done })
end

local function stepAnims(now: number)
	local i = 1
	while i <= #anims do
		local a = anims[i]
		local alpha = math.min((now - a.t0) / a.duration, 1)
		if a.step then
			a.step(alpha)
		end
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
-- Generic round-robin pool of parts
---------------------------------------------------------------------------------------------------

type PoolItem = { part: BasePart, gen: number, busy: boolean, t: number }
type Pool = { items: { PoolItem }, cursor: number }

local function makePool(n: number, factory: () -> BasePart): Pool
	local pool: Pool = { items = {}, cursor = 0 }
	for _ = 1, n do
		local p = factory()
		p.CFrame = HIDDEN
		p.Parent = fxFolder
		table.insert(pool.items, { part = p, gen = 0, busy = false, t = 0 })
	end
	return pool
end

-- Next free item, or the least recently used one.
local function take(pool: Pool, limit: number?): PoolItem
	local items = pool.items
	local n = math.min(limit or #items, #items)
	for i = 1, n do
		local idx = (pool.cursor + i - 1) % n + 1
		if not items[idx].busy then
			pool.cursor = idx
			local it = items[idx]
			it.gen += 1
			it.busy = true
			it.t = os.clock()
			return it
		end
	end
	local oldest = items[1]
	for i = 2, n do
		if items[i].t < oldest.t then
			oldest = items[i]
		end
	end
	oldest.gen += 1
	oldest.busy = true
	oldest.t = os.clock()
	return oldest
end

local function release(it: PoolItem, gen: number)
	if it.gen ~= gen then
		return
	end
	it.busy = false
	local p = it.part
	if not p.Anchored then
		p.AssemblyLinearVelocity = Vector3.zero
		p.AssemblyAngularVelocity = Vector3.zero
		p.Anchored = true
	end
	p.Transparency = 1
	p.CFrame = HIDDEN
end

---------------------------------------------------------------------------------------------------
-- Muzzle flash
---------------------------------------------------------------------------------------------------

type MuzzleRig = {
	part: Part,
	core: ParticleEmitter,
	star: ParticleEmitter,
	jets: ParticleEmitter,
	light: PointLight,
	gen: number,
}
local muzzleRigs: { MuzzleRig } = {}
local muzzleCursor = 0
local muzzleSmoke: { part: Part, smoke: ParticleEmitter } = nil :: any

local function buildMuzzle()
	for i = 1, 10 do
		local part = newPart("MuzzleRig" .. i, Vector3.new(0.1, 0.1, 0.1))
		local rig: MuzzleRig = {
			part = part,
			core = emitter(part, "Core", {
				Texture = TEX_FIRE,
				Lifetime = nr(0.04, 0.06),
				Speed = nr(0),
				LightEmission = 1,
				LightInfluence = 0,
				Brightness = 4,
				Color = cs(rgb(255, 236, 170), rgb(255, 150, 60)),
				Size = ns(0, 0.9, 1, 1.4),
				Transparency = ns(0, 0, 1, 0.6),
				Rotation = nr(0, 360),
				LockedToPart = true,
				ZOffset = 0.4,
			}),
			star = emitter(part, "Star", {
				Texture = TEX_SPARK,
				Lifetime = nr(0.035, 0.05),
				Speed = nr(0),
				LightEmission = 1,
				LightInfluence = 0,
				Brightness = 5,
				Color = cs(rgb(255, 244, 210)),
				Size = ns(0, 1.3, 1, 1.8),
				Transparency = ns(0, 0, 1, 0.8),
				Rotation = nr(0, 360),
				LockedToPart = true,
				ZOffset = 0.5,
			}),
			jets = emitter(part, "Jets", {
				Texture = TEX_FIRE,
				Lifetime = nr(0.03, 0.05),
				Speed = nr(30, 55),
				EmissionDirection = Enum.NormalId.Front,
				SpreadAngle = Vector2.new(14, 14),
				LightEmission = 1,
				LightInfluence = 0,
				Brightness = 3,
				Orientation = Enum.ParticleOrientation.VelocityParallel,
				Color = cs(rgb(255, 210, 120), rgb(255, 120, 40)),
				Size = ns(0, 0.45, 1, 0.15),
				Squash = ns(0, 1.5, 1, 1.5),
				Transparency = ns(0, 0.1, 1, 1),
			}),
			light = Instance.new("PointLight"),
			gen = 0,
		}
		rig.light.Color = rgb(255, 180, 90)
		rig.light.Brightness = 4
		rig.light.Range = 12
		rig.light.Shadows = false
		rig.light.Enabled = false
		rig.light.Parent = part
		part.CFrame = HIDDEN
		part.Parent = fxFolder
		table.insert(muzzleRigs, rig)
	end
	-- One shared smoke rig: lingering puffs are world-space so reuse is free.
	local sp = newPart("MuzzleSmoke", Vector3.new(0.1, 0.1, 0.1))
	muzzleSmoke = {
		part = sp,
		smoke = emitter(sp, "Smoke", {
			Lifetime = nr(0.8, 1.5),
			Speed = nr(2, 6),
			EmissionDirection = Enum.NormalId.Front,
			SpreadAngle = Vector2.new(25, 25),
			Drag = 3,
			Acceleration = Vector3.new(0, 1.6, 0),
			Color = cs(rgb(196, 194, 188), rgb(170, 168, 164)),
			Size = ns(0, 0.4, 1, 2.6),
			Transparency = ns(0, 0.72, 0.3, 0.78, 1, 1),
			Rotation = nr(0, 360),
			RotSpeed = nr(-30, 30),
			WindAffectsDrag = true,
		}),
	}
	sp.CFrame = HIDDEN
	sp.Parent = fxFolder
end

function EffectsController.MuzzleFlash(cframe: CFrame, scale: number?)
	if not started or typeof(cframe) ~= "CFrame" then
		return
	end
	local s = math.clamp(scale or 1, 0.2, 4)
	local dist = (cframe.Position - camPos()).Magnitude
	if dist > 700 then
		return
	end
	muzzleCursor = muzzleCursor % #muzzleRigs + 1
	local rig = muzzleRigs[muzzleCursor]
	rig.gen += 1
	local gen = rig.gen
	rig.part.CFrame = cframe
	-- Flash particles live ~0.05s, so resizing this rig per shot cannot disturb older particles.
	rig.core.Size = ns(0, 0.9 * s, 1, 1.4 * s)
	rig.star.Size = ns(0, 1.2 * s, 1, 1.7 * s)
	rig.jets.Size = ns(0, 0.45 * s, 1, 0.15 * s)
	rig.core:Emit(if quality >= 2 then 2 else 1)
	rig.star:Emit(1)
	if dist < 250 then
		rig.jets:Emit(count(4 * s))
	end
	if dist < 180 or quality == 3 then
		rig.light.Range = 10 + 6 * s
		rig.light.Enabled = true
		animate(0.05, nil, function()
			if rig.gen == gen then
				rig.light.Enabled = false
			end
		end)
	end
	if dist < 220 then
		muzzleSmoke.part.CFrame = cframe
		emit(muzzleSmoke.smoke, count(if s >= 1.2 then 3 else 2))
	end
end

---------------------------------------------------------------------------------------------------
-- Tracers (Beams between two Terrain attachments, animated as a moving streak)
---------------------------------------------------------------------------------------------------

type Tracer = {
	a0: Attachment,
	a1: Attachment,
	beam: Beam,
	active: boolean,
	from: Vector3,
	dir: Vector3,
	length: number,
	t0: number,
	speed: number,
	seg: number,
}
local tracers: { Tracer } = {}
local tracerCursor = 0
local DEFAULT_TRACER_COLOR = rgb(255, 196, 120)
local TRACER_SPEED = 2600
local TRACER_SEGMENT = 16

local function buildTracers()
	for _ = 1, 40 do
		local a0 = Instance.new("Attachment")
		a0.Name = "TracerTail"
		a0.Parent = workspace.Terrain
		local a1 = Instance.new("Attachment")
		a1.Name = "TracerHead"
		a1.Parent = workspace.Terrain
		local beam = Instance.new("Beam")
		beam.Name = "Tracer"
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.FaceCamera = true
		beam.Segments = 1
		beam.Width0 = 0.04
		beam.Width1 = 0.14
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Brightness = 6
		beam.Transparency = ns(0, 1, 0.5, 0.45, 1, 0)
		beam.Color = cs(DEFAULT_TRACER_COLOR)
		beam.Enabled = false
		beam.Parent = a0
		table.insert(tracers, {
			a0 = a0,
			a1 = a1,
			beam = beam,
			active = false,
			from = Vector3.zero,
			dir = Vector3.zAxis,
			length = 0,
			t0 = 0,
			speed = TRACER_SPEED,
			seg = TRACER_SEGMENT,
		})
	end
end

function EffectsController.Tracer(from: Vector3, to: Vector3, color: Color3?)
	if not started or typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" then
		return
	end
	local delta = to - from
	local length = delta.Magnitude
	if length < 4 then
		return
	end
	-- Prefer a free tracer; otherwise recycle round-robin.
	local chosen: Tracer? = nil
	for i = 1, #tracers do
		local idx = (tracerCursor + i - 1) % #tracers + 1
		if not tracers[idx].active then
			chosen = tracers[idx]
			tracerCursor = idx
			break
		end
	end
	if not chosen then
		tracerCursor = tracerCursor % #tracers + 1
		chosen = tracers[tracerCursor]
	end
	local tr = chosen :: Tracer
	tr.active = true
	tr.from = from
	tr.dir = delta / length
	tr.length = length
	tr.t0 = os.clock()
	tr.speed = TRACER_SPEED
	tr.seg = math.min(TRACER_SEGMENT, length * 0.5)
	tr.beam.Color = cs(color or DEFAULT_TRACER_COLOR)
	tr.a0.Position = from
	tr.a1.Position = from
	tr.beam.Enabled = true
end

-- Applies the ~1-in-3 tracer rule for automatic weapons (Config/Weapons fireModes/rpm, guarded).
local tracerCounters: { [string]: number } = {}
local autoCache: { [string]: boolean } = {}
local weaponsModule: any = nil
local function isAutomatic(weaponId: string): boolean
	local cached = autoCache[weaponId]
	if cached ~= nil then
		return cached
	end
	if weaponsModule == nil then
		local m = Shared.Config:FindFirstChild("Weapons")
		if m and m:IsA("ModuleScript") then
			local ok, result = pcall(require, m)
			weaponsModule = if ok then result else false
		end
	end
	local W = weaponsModule
	local d = nil
	if type(W) == "table" then
		d = (type(W.byId) == "table" and W.byId[weaponId]) or W[weaponId]
	end
	local auto = false
	if type(d) == "table" then
		if type(d.fireModes) == "table" and table.find(d.fireModes, "Auto") then
			auto = true
		elseif type(d.rpm) == "number" and d.rpm >= 450 then
			auto = true
		end
		autoCache[weaponId] = auto
	end
	return auto
end

function EffectsController.TracerFor(weaponId: string, from: Vector3, to: Vector3, color: Color3?)
	if isAutomatic(tostring(weaponId)) then
		local n = (tracerCounters[weaponId] or 0) + 1
		tracerCounters[weaponId] = n
		if n % 3 ~= 1 then
			return
		end
	end
	EffectsController.Tracer(from, to, color)
end

local function stepTracers(now: number)
	for _, tr in tracers do
		if tr.active then
			local travelled = (now - tr.t0) * tr.speed
			local head = math.min(travelled, tr.length)
			local tail = math.max(0, travelled - tr.seg)
			if tail >= tr.length then
				tr.active = false
				tr.beam.Enabled = false
			else
				tr.a0.Position = tr.from + tr.dir * tail
				tr.a1.Position = tr.from + tr.dir * head
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Bullet impacts
---------------------------------------------------------------------------------------------------

type ImpactStyle = {
	dust: Color3?,
	dustN: number,
	chunk: Color3?,
	chunkN: number,
	sparks: number,
	splinters: boolean?,
	splash: number,
	mark: Color3?,
	ricochet: number, -- chance of a ricochet sound
}

local IMPACT_STYLES: { [string]: ImpactStyle } = {
	dirt = {
		dust = rgb(112, 94, 72),
		dustN = 4,
		chunk = rgb(70, 56, 40),
		chunkN = 6,
		sparks = 0,
		splash = 0,
		mark = rgb(40, 32, 24),
		ricochet = 0,
	},
	foliage = {
		dust = rgb(86, 98, 60),
		dustN = 3,
		chunk = rgb(66, 96, 46),
		chunkN = 6,
		sparks = 0,
		splash = 0,
		mark = nil,
		ricochet = 0,
	},
	sand = {
		dust = rgb(198, 178, 134),
		dustN = 5,
		chunk = rgb(170, 150, 110),
		chunkN = 5,
		sparks = 0,
		splash = 0,
		mark = rgb(126, 106, 76),
		ricochet = 0,
	},
	snow = {
		dust = rgb(236, 240, 248),
		dustN = 5,
		chunk = rgb(246, 248, 255),
		chunkN = 6,
		sparks = 0,
		splash = 0,
		mark = rgb(150, 160, 176),
		ricochet = 0,
	},
	wood = {
		dust = rgb(124, 98, 68),
		dustN = 2,
		chunk = rgb(156, 116, 74),
		chunkN = 6,
		sparks = 0,
		splinters = true,
		splash = 0,
		mark = rgb(36, 26, 16),
		ricochet = 0,
	},
	metal = {
		dust = rgb(96, 96, 96),
		dustN = 1,
		chunk = nil,
		chunkN = 0,
		sparks = 9,
		splash = 0,
		mark = rgb(34, 34, 36),
		ricochet = 0.3,
	},
	stone = {
		dust = rgb(156, 150, 140),
		dustN = 4,
		chunk = rgb(112, 106, 100),
		chunkN = 5,
		sparks = 1,
		splash = 0,
		mark = rgb(44, 42, 40),
		ricochet = 0.08,
	},
	water = { dust = nil, dustN = 0, chunk = nil, chunkN = 0, sparks = 0, splash = 7, mark = nil, ricochet = 0 },
	glass = {
		dust = rgb(210, 220, 226),
		dustN = 1,
		chunk = rgb(206, 226, 236),
		chunkN = 7,
		sparks = 0,
		splash = 0,
		mark = rgb(220, 230, 236),
		ricochet = 0,
	},
	flesh = {
		dust = rgb(96, 22, 22),
		dustN = 2,
		chunk = nil,
		chunkN = 0,
		sparks = 0,
		splash = 0,
		mark = nil,
		ricochet = 0,
	},
}

local MATERIAL_CATEGORY: { [string]: string } = {
	Grass = "dirt",
	Ground = "dirt",
	Mud = "dirt",
	Pebble = "dirt",
	Salt = "sand",
	LeafyGrass = "foliage",
	Sand = "sand",
	Snow = "snow",
	Glacier = "snow",
	Ice = "glass",
	Glass = "glass",
	ForceField = "glass",
	Wood = "wood",
	WoodPlanks = "wood",
	Cardboard = "wood",
	Fabric = "wood",
	Carpet = "wood",
	Metal = "metal",
	CorrodedMetal = "metal",
	DiamondPlate = "metal",
	Foil = "metal",
	Water = "water",
	Flesh = "flesh",
	Blood = "flesh",
	Humanoid = "flesh",
}

type ImpactRig = {
	part: Part,
	dust: ParticleEmitter?,
	chunks: ParticleEmitter?,
	sparks: ParticleEmitter?,
	splash: ParticleEmitter?,
	mist: ParticleEmitter?,
}
local impactRigs: { [string]: ImpactRig } = {}
local markPool: Pool = nil :: any

local function buildImpacts()
	for category, style in IMPACT_STYLES do
		local part = newPart("Impact_" .. category, Vector3.new(0.2, 0.2, 0.2))
		local rig: ImpactRig = { part = part }
		if style.dust then
			rig.dust = emitter(part, "Dust", {
				Lifetime = nr(0.6, 1.4),
				Speed = nr(3, 9),
				EmissionDirection = Enum.NormalId.Front,
				SpreadAngle = Vector2.new(28, 28),
				Drag = 4,
				Acceleration = Vector3.new(0, -1.5, 0),
				Color = cs(style.dust),
				Size = ns(0, 0.35, 1, 2.2),
				Transparency = ns(0, 0.3, 0.4, 0.6, 1, 1),
				Rotation = nr(0, 360),
				RotSpeed = nr(-40, 40),
				WindAffectsDrag = true,
			})
		end
		if style.chunk then
			rig.chunks = emitter(part, "Chunks", {
				Lifetime = nr(0.45, 0.8),
				Speed = nr(14, 26),
				EmissionDirection = Enum.NormalId.Front,
				SpreadAngle = Vector2.new(38, 38),
				Acceleration = Vector3.new(0, -70, 0),
				Color = cs(style.chunk),
				Size = if style.splinters then ns(0, 0.22, 1, 0.16) else ns(0, 0.18, 1, 0.12),
				Squash = if style.splinters then ns(0, 2, 1, 2) else ns(0, 0, 1, 0),
				Orientation = if style.splinters
					then Enum.ParticleOrientation.VelocityParallel
					else Enum.ParticleOrientation.FacingCamera,
				Transparency = ns(0, 0, 0.8, 0, 1, 1),
				Rotation = nr(0, 360),
				RotSpeed = nr(-300, 300),
			})
		end
		if style.sparks > 0 then
			rig.sparks = emitter(part, "Sparks", {
				Texture = TEX_SPARK,
				Lifetime = nr(0.12, 0.32),
				Speed = nr(22, 48),
				EmissionDirection = Enum.NormalId.Front,
				SpreadAngle = Vector2.new(55, 55),
				Acceleration = Vector3.new(0, -60, 0),
				Drag = 2,
				LightEmission = 1,
				LightInfluence = 0,
				Brightness = 5,
				Orientation = Enum.ParticleOrientation.VelocityParallel,
				Color = cs(rgb(255, 230, 160), rgb(255, 140, 50)),
				Size = ns(0, 0.16, 1, 0.06),
				Squash = ns(0, 1.2, 1, 1.2),
				Transparency = ns(0, 0, 1, 0.4),
			})
		end
		if style.splash > 0 then
			rig.splash = emitter(part, "Splash", {
				Lifetime = nr(0.45, 0.75),
				Speed = nr(12, 22),
				EmissionDirection = Enum.NormalId.Front,
				SpreadAngle = Vector2.new(14, 14),
				Acceleration = Vector3.new(0, -55, 0),
				Color = cs(rgb(226, 236, 240)),
				Size = ns(0, 0.25, 0.5, 0.6, 1, 0.9),
				Squash = ns(0, 1.5, 1, 0.5),
				Orientation = Enum.ParticleOrientation.VelocityParallel,
				Transparency = ns(0, 0.15, 1, 1),
			})
			rig.mist = emitter(part, "Mist", {
				Lifetime = nr(0.5, 0.9),
				Speed = nr(2, 5),
				EmissionDirection = Enum.NormalId.Front,
				SpreadAngle = Vector2.new(60, 60),
				Drag = 3,
				Color = cs(rgb(220, 230, 235)),
				Size = ns(0, 0.5, 1, 1.8),
				Transparency = ns(0, 0.5, 1, 1),
			})
		end
		part.CFrame = HIDDEN
		part.Parent = fxFolder
		impactRigs[category] = rig
	end

	-- Bullet holes: tiny flat cylinders (X axis = surface normal).
	markPool = makePool(64, function()
		local p = newPart("BulletMark", Vector3.new(0.03, 0.28, 0.28))
		p.Shape = Enum.PartType.Cylinder
		p.Color = rgb(30, 26, 22)
		return p
	end)
end

local function categoryOf(material: any): string
	local name: string
	if typeof(material) == "EnumItem" then
		name = material.Name
	else
		name = tostring(material)
	end
	return MATERIAL_CATEGORY[name] or "stone"
end

local MARK_LIMIT = { 20, 40, 64 } -- usable slice of the mark pool per GraphicsQuality

local function placeMark(position: Vector3, normal: Vector3, color: Color3)
	local it = take(markPool, MARK_LIMIT[quality])
	local gen = it.gen
	local p = it.part
	local cf = lookAlong(position + normal * 0.015, normal) * CFrame.Angles(0, math.pi / 2, 0)
	p.CFrame = cf * CFrame.Angles(rng:NextNumber(0, math.pi * 2), 0, 0)
	local size = rng:NextNumber(0.22, 0.32)
	p.Size = Vector3.new(0.03, size, size)
	p.Color = color
	p.Transparency = 0.05
	animate(MARK_LIFE, function(alpha)
		if it.gen == gen and alpha > 0.75 then
			p.Transparency = 0.05 + (alpha - 0.75) / 0.25 * 0.95
		end
	end, function()
		release(it, gen)
	end)
end

function EffectsController.Impact(position: Vector3, normal: Vector3, material: any)
	if not started or typeof(position) ~= "Vector3" then
		return
	end
	if impactsThisFrame >= MAX_IMPACTS_PER_FRAME[quality] then
		return
	end
	local dist = (position - camPos()).Magnitude
	if dist > IMPACT_CULL then
		return
	end
	impactsThisFrame += 1
	if typeof(normal) ~= "Vector3" or normal.Magnitude < 1e-3 then
		normal = Vector3.yAxis
	else
		normal = normal.Unit
	end
	local category = categoryOf(material)
	local style = IMPACT_STYLES[category]
	local rig = impactRigs[category]
	local lod = if dist > 140 then 0.5 else 1
	rig.part.CFrame = lookAlong(position, normal)
	emit(rig.dust, count(style.dustN, lod))
	if dist < 160 then
		emit(rig.chunks, count(style.chunkN, lod))
	end
	emit(rig.sparks, count(style.sparks, lod))
	emit(rig.splash, count(style.splash, lod))
	emit(rig.mist, count(3, lod))
	if style.mark and dist < 110 then
		placeMark(position, normal, style.mark)
	end
	if dist < 80 then
		playSoundAt("Bullet_Impact", position, { volume = if category == "metal" then 1.1 else 0.8 })
		if style.ricochet > 0 and rng:NextNumber() < style.ricochet then
			playSoundAt("Ricochet", position)
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Shell ejection (physical brass, pooled)
---------------------------------------------------------------------------------------------------

local shellPool: Pool = nil :: any
local SHELL_KINDS = {
	rifle = { size = Vector3.new(0.08, 0.08, 0.3), color = rgb(198, 160, 82) },
	mg = { size = Vector3.new(0.08, 0.08, 0.3), color = rgb(188, 150, 76) },
	pistol = { size = Vector3.new(0.08, 0.08, 0.16), color = rgb(206, 170, 90) },
	shotgun = { size = Vector3.new(0.16, 0.16, 0.3), color = rgb(150, 32, 30) },
}

local function buildShells()
	shellPool = makePool(28, function()
		local p = newPart("Shell", SHELL_KINDS.rifle.size)
		p.Transparency = 1
		p.Material = Enum.Material.Metal
		p.Massless = false
		pcall(function()
			p.CollisionGroup = DEBRIS_GROUP
		end)
		return p
	end)
end

function EffectsController.ShellEject(cframe: CFrame, kind: string?)
	if not started or typeof(cframe) ~= "CFrame" then
		return
	end
	if (cframe.Position - camPos()).Magnitude > 60 then
		return
	end
	local spec = SHELL_KINDS[kind or "rifle"] or SHELL_KINDS.rifle
	local it = take(shellPool)
	local gen = it.gen
	local p = it.part
	p.Size = spec.size
	p.Color = spec.color
	p.CFrame = cframe * CFrame.Angles(0, math.pi / 2, 0)
	p.Transparency = 0
	p.CanCollide = true
	p.Anchored = false
	p.AssemblyLinearVelocity = cframe.RightVector * rng:NextNumber(7, 12)
		+ cframe.UpVector * rng:NextNumber(4, 8)
		- cframe.LookVector * rng:NextNumber(0, 2)
	p.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-25, 25), rng:NextNumber(-25, 25), rng:NextNumber(-25, 25))
	animate(1.4, nil, function()
		if it.gen == gen then
			p.CanCollide = false
			release(it, gen)
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Explosions
---------------------------------------------------------------------------------------------------

type KindSpec = {
	R: number, -- nominal radius the particle sizes are authored for
	core: number,
	fire: number,
	sparks: number,
	dirt: number,
	column: number,
	smoke: number,
	ring: number,
	debris: number,
	smokeLife: NumberRange,
	smokeColor: Color3,
	light: number,
	scorch: boolean,
	metalDebris: boolean?,
}

local KINDS: { [string]: KindSpec } = {
	grenade = {
		R = 12,
		core = 2,
		fire = 8,
		sparks = 14,
		dirt = 18,
		column = 8,
		smoke = 6,
		ring = 10,
		debris = 3,
		smokeLife = nr(4, 7),
		smokeColor = rgb(92, 88, 82),
		light = 35,
		scorch = true,
	},
	rocket = {
		R = 14,
		core = 2,
		fire = 14,
		sparks = 22,
		dirt = 16,
		column = 8,
		smoke = 8,
		ring = 10,
		debris = 4,
		smokeLife = nr(5, 8),
		smokeColor = rgb(70, 68, 66),
		light = 45,
		scorch = true,
	},
	shell = {
		R = 20,
		core = 2,
		fire = 14,
		sparks = 20,
		dirt = 30,
		column = 14,
		smoke = 10,
		ring = 14,
		debris = 6,
		smokeLife = nr(6, 10),
		smokeColor = rgb(84, 80, 74),
		light = 60,
		scorch = true,
	},
	satchel = {
		R = 22,
		core = 3,
		fire = 16,
		sparks = 18,
		dirt = 34,
		column = 16,
		smoke = 12,
		ring = 16,
		debris = 8,
		smokeLife = nr(6, 10),
		smokeColor = rgb(88, 84, 78),
		light = 65,
		scorch = true,
	},
	vehicle = {
		R = 24,
		core = 3,
		fire = 22,
		sparks = 30,
		dirt = 10,
		column = 6,
		smoke = 14,
		ring = 12,
		debris = 8,
		smokeLife = nr(9, 14),
		smokeColor = rgb(40, 38, 36),
		light = 70,
		scorch = true,
		metalDebris = true,
	},
}

type ExplosionRig = {
	part: Part,
	core: ParticleEmitter,
	fire: ParticleEmitter,
	sparks: ParticleEmitter,
	dirt: ParticleEmitter,
	column: ParticleEmitter,
	smoke: ParticleEmitter,
	ring: ParticleEmitter,
	splash: ParticleEmitter,
}
local explosionRigs: { [string]: ExplosionRig } = {}
local flashPool: Pool = nil :: any
local shockPool: Pool = nil :: any
local scorchPool: Pool = nil :: any
local debrisPool: Pool = nil :: any
local lightPool: Pool = nil :: any

local function buildExplosionRig(kind: string, k: KindSpec): ExplosionRig
	local R = k.R
	local part = newPart("Explosion_" .. kind, Vector3.new(1, 1, 1))
	local rig: ExplosionRig = {
		part = part,
		core = emitter(part, "Core", {
			Texture = TEX_CORE,
			Lifetime = nr(0.12, 0.22),
			Speed = nr(0),
			LightEmission = 1,
			LightInfluence = 0,
			Brightness = 3,
			Color = cs(rgb(255, 240, 200), rgb(255, 140, 50)),
			Size = ns(0, R * 0.4, 1, R * 0.95),
			Transparency = ns(0, 0, 1, 1),
			Rotation = nr(0, 360),
			ZOffset = 2,
		}),
		fire = emitter(part, "Fireball", {
			Texture = TEX_FIRE,
			Lifetime = nr(0.3, 0.65),
			Speed = nr(R * 0.4, R * 1.1),
			SpreadAngle = Vector2.new(180, 180),
			Drag = 6,
			Acceleration = Vector3.new(0, 12, 0),
			LightEmission = 0.75,
			LightInfluence = 0,
			Brightness = 2,
			Color = cs(rgb(255, 196, 110), rgb(200, 70, 20)),
			Size = ns(0, R * 0.22, 0.4, R * 0.42, 1, R * 0.2),
			Transparency = ns(0, 0.05, 0.6, 0.4, 1, 1),
			Rotation = nr(0, 360),
			RotSpeed = nr(-90, 90),
			ZOffset = 1,
		}),
		sparks = emitter(part, "Sparks", {
			Texture = TEX_SPARK,
			Lifetime = nr(0.5, 1.1),
			Speed = nr(R * 3, R * 5),
			EmissionDirection = Enum.NormalId.Top,
			SpreadAngle = Vector2.new(70, 70),
			Acceleration = Vector3.new(0, -80, 0),
			Drag = 1,
			LightEmission = 1,
			LightInfluence = 0,
			Brightness = 4,
			Orientation = Enum.ParticleOrientation.VelocityParallel,
			Color = cs(rgb(255, 220, 140), rgb(255, 110, 30)),
			Size = ns(0, 0.35, 1, 0.1),
			Squash = ns(0, 1.5, 1, 1.5),
			Transparency = ns(0, 0, 1, 0.3),
		}),
		dirt = emitter(part, "Dirt", {
			Lifetime = nr(0.9, 1.7),
			Speed = nr(R * 1.8, R * 3.6),
			EmissionDirection = Enum.NormalId.Top,
			SpreadAngle = Vector2.new(45, 45),
			Acceleration = Vector3.new(0, -90, 0),
			Color = cs(rgb(66, 54, 42)),
			Size = ns(0, 0.55, 1, 0.35),
			Transparency = ns(0, 0, 0.85, 0, 1, 1),
			Rotation = nr(0, 360),
			RotSpeed = nr(-200, 200),
		}),
		column = emitter(part, "Column", {
			Lifetime = nr(1.6, 3.2),
			Speed = nr(R * 1.1, R * 2.2),
			EmissionDirection = Enum.NormalId.Top,
			SpreadAngle = Vector2.new(18, 18),
			Drag = 2.5,
			Acceleration = Vector3.new(0, -5, 0),
			Color = cs(rgb(118, 100, 80)),
			Size = ns(0, R * 0.3, 1, R * 0.95),
			Transparency = ns(0, 0.15, 0.6, 0.55, 1, 1),
			Rotation = nr(0, 360),
			RotSpeed = nr(-20, 20),
			WindAffectsDrag = true,
		}),
		smoke = emitter(part, "Smoke", {
			Lifetime = k.smokeLife,
			Speed = nr(2, 6),
			SpreadAngle = Vector2.new(180, 180),
			Drag = 1,
			Acceleration = Vector3.new(0, 2.8, 0),
			Color = cs(k.smokeColor, k.smokeColor:Lerp(rgb(140, 138, 134), 0.5)),
			Size = ns(0, R * 0.4, 1, R * 1.35),
			Transparency = ns(0, 0.4, 0.3, 0.45, 1, 1),
			Rotation = nr(0, 360),
			RotSpeed = nr(-12, 12),
			WindAffectsDrag = true,
		}),
		ring = emitter(part, "GroundRing", {
			Lifetime = nr(0.7, 1.3),
			Speed = nr(R * 2, R * 3.2),
			EmissionDirection = Enum.NormalId.Top,
			SpreadAngle = Vector2.new(88, 88),
			Drag = 4,
			Color = cs(rgb(130, 116, 96)),
			Size = ns(0, R * 0.2, 1, R * 0.55),
			Transparency = ns(0, 0.3, 1, 1),
			Rotation = nr(0, 360),
		}),
		splash = emitter(part, "Splash", {
			Lifetime = nr(1.2, 2),
			Speed = nr(R * 2, R * 3.4),
			EmissionDirection = Enum.NormalId.Top,
			SpreadAngle = Vector2.new(14, 14),
			Acceleration = Vector3.new(0, -60, 0),
			Color = cs(rgb(226, 234, 238)),
			Size = ns(0, R * 0.15, 0.5, R * 0.4, 1, R * 0.5),
			Transparency = ns(0, 0.1, 0.7, 0.4, 1, 1),
			Rotation = nr(0, 360),
		}),
	}
	part.CFrame = HIDDEN
	part.Parent = fxFolder
	return rig
end

local function buildExplosions()
	for kind, spec in KINDS do
		explosionRigs[kind] = buildExplosionRig(kind, spec)
	end
	flashPool = makePool(6, function()
		local p = newPart("ExplosionFlash", Vector3.one)
		p.Shape = Enum.PartType.Ball
		p.Material = Enum.Material.Neon
		p.Color = rgb(255, 170, 80)
		return p
	end)
	shockPool = makePool(6, function()
		local p = newPart("Shockwave", Vector3.new(0.2, 1, 1))
		p.Shape = Enum.PartType.Cylinder
		p.Material = Enum.Material.Glass
		p.Color = rgb(220, 214, 200)
		return p
	end)
	scorchPool = makePool(16, function()
		local p = newPart("Scorch", Vector3.new(0.05, 1, 1))
		p.Shape = Enum.PartType.Cylinder
		p.Color = rgb(22, 20, 18)
		return p
	end)
	debrisPool = makePool(32, function()
		local p = newPart("Debris", Vector3.one)
		p.Material = Enum.Material.Slate
		p.Massless = false
		pcall(function()
			p.CollisionGroup = DEBRIS_GROUP
		end)
		return p
	end)
	lightPool = makePool(6, function()
		local p = newPart("ExplosionLight", Vector3.new(0.2, 0.2, 0.2))
		local l = Instance.new("PointLight")
		l.Name = "Light"
		l.Color = rgb(255, 160, 80)
		l.Shadows = false
		l.Enabled = false
		l.Parent = p
		return p
	end)
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.IgnoreWater = false

local function groundBelow(position: Vector3, depth: number): RaycastResult?
	local exclude: { Instance } = { fxFolder }
	for _, plr in game:GetService("Players"):GetPlayers() do
		if plr.Character then
			table.insert(exclude, plr.Character)
		end
	end
	groundParams.FilterDescendantsInstances = exclude
	return workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -(depth + 2), 0), groundParams)
end

local function flashLight(position: Vector3, range: number, brightness: number, duration: number)
	local it = take(lightPool)
	local gen = it.gen
	local p = it.part
	p.CFrame = CFrame.new(position + Vector3.new(0, 2, 0))
	local light = p:FindFirstChild("Light") :: PointLight
	light.Range = math.min(range, 60)
	light.Brightness = brightness
	light.Enabled = true
	animate(duration, function(alpha)
		if it.gen == gen then
			light.Brightness = brightness * (1 - alpha) ^ 2
		end
	end, function()
		if it.gen == gen then
			light.Enabled = false
			release(it, gen)
		end
	end)
end

local function flashSphere(position: Vector3, radius: number)
	local it = take(flashPool)
	local gen = it.gen
	local p = it.part
	p.CFrame = CFrame.new(position)
	animate(0.16, function(alpha)
		if it.gen == gen then
			local d = radius * (0.35 + 0.85 * alpha)
			p.Size = Vector3.new(d, d, d)
			p.Transparency = 0.15 + 0.85 * alpha
			p.Color = rgb(255, 210, 140):Lerp(rgb(220, 90, 30), alpha)
		end
	end, function()
		release(it, gen)
	end)
end

local function shockwave(position: Vector3, normal: Vector3, radius: number)
	local it = take(shockPool)
	local gen = it.gen
	local p = it.part
	local cf = lookAlong(position + normal * 0.5, normal) * CFrame.Angles(0, math.pi / 2, 0)
	p.CFrame = cf
	animate(0.35, function(alpha)
		if it.gen == gen then
			local d = radius * (0.4 + 2.6 * alpha)
			p.Size = Vector3.new(0.2, d, d)
			p.Transparency = 0.55 + 0.45 * alpha
		end
	end, function()
		release(it, gen)
	end)
end

local function scorch(position: Vector3, normal: Vector3, radius: number)
	local it = take(scorchPool)
	local gen = it.gen
	local p = it.part
	local d = radius * rng:NextNumber(0.6, 0.85)
	p.Size = Vector3.new(0.05, d, d)
	p.CFrame = lookAlong(position + normal * 0.03, normal)
		* CFrame.Angles(0, math.pi / 2, 0)
		* CFrame.Angles(rng:NextNumber(0, math.pi * 2), 0, 0)
	p.Transparency = 0.15
	animate(SCORCH_LIFE, function(alpha)
		if it.gen == gen and alpha > 0.8 then
			p.Transparency = 0.15 + (alpha - 0.8) / 0.2 * 0.85
		end
	end, function()
		release(it, gen)
	end)
end

local function debris(position: Vector3, n: number, radius: number, metal: boolean?, color: Color3)
	for _ = 1, n do
		local it = take(debrisPool)
		local gen = it.gen
		local p = it.part
		local s = rng:NextNumber(0.3, 1.1) * math.clamp(radius / 14, 0.6, 1.6)
		p.Size = Vector3.new(s, s * rng:NextNumber(0.4, 0.9), s * rng:NextNumber(0.5, 1.2))
		p.Material = if metal then Enum.Material.CorrodedMetal else Enum.Material.Slate
		p.Color = if metal then rgb(52, 50, 48) else color
		p.CFrame = CFrame.new(position + Vector3.new(0, 1.5, 0))
			* CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), 0)
		p.Transparency = 0
		p.CanCollide = true
		p.Anchored = false
		local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(1.2, 2.4), rng:NextNumber(-1, 1)).Unit
		p.AssemblyLinearVelocity = dir * rng:NextNumber(35, 75)
		p.AssemblyAngularVelocity =
			Vector3.new(rng:NextNumber(-15, 15), rng:NextNumber(-15, 15), rng:NextNumber(-15, 15))
		animate(3.5, function(alpha)
			if it.gen == gen and alpha > 0.8 then
				p.Transparency = (alpha - 0.8) / 0.2
			end
		end, function()
			if it.gen == gen then
				p.CanCollide = false
				release(it, gen)
			end
		end)
	end
end

function EffectsController.Explosion(position: Vector3, radius: number, kind: string)
	if not started or typeof(position) ~= "Vector3" then
		return
	end
	if kind == "smoke" then
		EffectsController.Smoke(position, if type(radius) == "number" and radius > 0 then radius else 22, 32)
		return
	end
	local spec = KINDS[kind] or KINDS.grenade
	local rig = explosionRigs[kind] or explosionRigs.grenade
	if explosionsThisFrame >= MAX_EXPLOSIONS_PER_FRAME then
		return
	end
	explosionsThisFrame += 1
	local r = if type(radius) == "number" and radius > 0 then math.clamp(radius, 3, 60) else spec.R
	local scale = math.clamp(r / spec.R, 0.5, 2)
	local dist = (position - camPos()).Magnitude

	-- Always: flash (readable at any range).
	flashSphere(position, r * 0.9)
	if dist > 1600 then
		return
	end
	flashLight(position, spec.light * scale, 7, 0.35)
	local lod = if dist > 600 then 0.45 elseif dist > 250 then 0.75 else 1

	local hit = groundBelow(position, r * 0.6)
	local onWater = hit ~= nil and hit.Material == Enum.Material.Water
	local normal = if hit then hit.Normal else Vector3.yAxis
	local groundPos = if hit then hit.Position else position

	rig.part.Size = Vector3.new(r * 0.25, r * 0.15, r * 0.25)
	rig.part.CFrame = CFrame.new(position)
	emit(rig.core, spec.core)
	emit(rig.fire, count(spec.fire * scale, lod))
	emit(rig.sparks, count(spec.sparks, lod))
	emit(rig.smoke, count(spec.smoke * scale, lod))

	if hit then
		rig.part.CFrame = lookAlong(groundPos, normal) * CFrame.Angles(-math.pi / 2, 0, 0)
		if onWater then
			emit(rig.splash, count(spec.dirt * 0.8 * scale, lod))
			emit(rig.ring, count(spec.ring * 0.6, lod))
		else
			emit(rig.dirt, count(spec.dirt * scale, lod))
			emit(rig.column, count(spec.column * scale, lod))
			emit(rig.ring, count(spec.ring, lod))
			if dist < 400 then
				shockwave(groundPos, normal, r)
			end
			if spec.scorch and dist < 500 then
				scorch(groundPos, normal, r)
			end
		end
	end
	if dist < 300 and quality >= 2 then
		local color = rgb(60, 50, 40)
		if hit then
			local base = hit.Instance.Color
			if hit.Instance:IsA("Terrain") then
				local ok, c = pcall(hit.Instance.GetMaterialColor, hit.Instance, hit.Material)
				if ok then
					base = c
				end
			end
			color = base:Lerp(color, 0.4)
		end
		debris(groundPos, count(spec.debris * scale, lod), r, spec.metalDebris, color)
	end
end

---------------------------------------------------------------------------------------------------
-- Smoke screens (vision-blocking)
---------------------------------------------------------------------------------------------------

type SmokeRig = {
	part: Part,
	cloud: ParticleEmitter,
	base: ParticleEmitter,
	active: boolean,
	gen: number,
	position: Vector3,
	radius: number,
	startedAt: number,
	endsAt: number,
	clearsAt: number,
}
local smokeRigs: { SmokeRig } = {}
local smokeVeil: ColorCorrectionEffect? = nil

local function buildSmoke()
	for i = 1, 6 do
		local part = newPart("SmokeScreen" .. i, Vector3.new(4, 2, 4))
		local rig: SmokeRig = {
			part = part,
			cloud = emitter(part, "Cloud", {
				Lifetime = nr(7, 10),
				Speed = nr(2, 5),
				SpreadAngle = Vector2.new(180, 180),
				Drag = 1.2,
				Acceleration = Vector3.new(0, 0.5, 0),
				Color = cs(rgb(214, 214, 208), rgb(188, 188, 182)),
				Size = ns(0, 6, 0.25, 16, 1, 20),
				Transparency = ns(0, 0.6, 0.12, 0.08, 0.75, 0.15, 1, 1),
				Rotation = nr(0, 360),
				RotSpeed = nr(-10, 10),
				WindAffectsDrag = true,
			}),
			base = emitter(part, "Base", {
				Lifetime = nr(1.2, 2),
				Speed = nr(6, 10),
				EmissionDirection = Enum.NormalId.Top,
				SpreadAngle = Vector2.new(25, 25),
				Drag = 2,
				Color = cs(rgb(230, 230, 224)),
				Size = ns(0, 1, 1, 5),
				Transparency = ns(0, 0.3, 1, 1),
				Rotation = nr(0, 360),
			}),
			active = false,
			gen = 0,
			position = Vector3.zero,
			radius = 0,
			startedAt = 0,
			endsAt = 0,
			clearsAt = 0,
		}
		part.CFrame = HIDDEN
		part.Parent = fxFolder
		table.insert(smokeRigs, rig)
	end
	local veil = Instance.new("ColorCorrectionEffect")
	veil.Name = "WW2_SmokeVeil"
	veil.Enabled = false
	veil.Parent = Lighting
	smokeVeil = veil
end

function EffectsController.Smoke(position: Vector3, radius: number, duration: number)
	if not started or typeof(position) ~= "Vector3" then
		return
	end
	local r = math.clamp(if type(radius) == "number" then radius else 22, 8, 60)
	local dur = math.clamp(if type(duration) == "number" then duration else 30, 3, 90)
	-- Free rig, else the one closest to finishing.
	local chosen = smokeRigs[1]
	for _, rig in smokeRigs do
		if not rig.active then
			chosen = rig
			break
		end
		if rig.clearsAt < chosen.clearsAt then
			chosen = rig
		end
	end
	local rig = chosen
	rig.gen += 1
	local gen = rig.gen
	local now = os.clock()
	rig.active = true
	rig.position = position
	rig.radius = r
	rig.startedAt = now
	rig.endsAt = now + dur
	rig.clearsAt = now + dur + 10
	-- Fewer particles at low quality, but each one bigger so the screen still blocks sight.
	local sizeMult = (r / 22) * (if quality == 1 then 1.3 else 1)
	rig.cloud.Size = ns(0, 6 * sizeMult, 0.25, 16 * sizeMult, 1, 20 * sizeMult)
	rig.part.Size = Vector3.new(r * 0.9, r * 0.35, r * 0.9)
	rig.part.CFrame = CFrame.new(position + Vector3.new(0, r * 0.2, 0))
	rig.cloud.Rate = ({ 5, 8, 11 })[quality] * (r / 22)
	rig.cloud.Enabled = true
	rig.cloud:Emit(count(14))
	rig.base.Rate = 6
	rig.base.Enabled = true
	animate(dur, nil, function()
		if rig.gen == gen then
			rig.cloud.Enabled = false
			rig.base.Enabled = false
		end
	end)
	animate(dur + 10, nil, function()
		if rig.gen == gen then
			rig.active = false
			rig.part.CFrame = HIDDEN
		end
	end)
end

-- Grey veil when the camera is inside an active screen (particles do the real occlusion).
local veilAmount = 0
local function stepSmokeVeil(dt: number)
	local veil = smokeVeil
	if not veil then
		return
	end
	local cam = camPos()
	local now = os.clock()
	local target = 0
	for _, rig in smokeRigs do
		if rig.active then
			-- Density ramps in over ~2 s and thins out during the clear-out phase.
			local density = math.clamp((now - rig.startedAt) * 0.5, 0, 1)
			if now > rig.endsAt then
				density = math.clamp(1 - (now - rig.endsAt) / 8, 0, 1)
			end
			local d = (cam - rig.position).Magnitude
			local inside = math.clamp(1 - d / (rig.radius * 1.15), 0, 1)
			target = math.max(target, math.clamp(inside * 1.6, 0, 1) * density)
		end
	end
	veilAmount += (target - veilAmount) * math.clamp(dt * 3, 0, 1)
	if veilAmount < 0.01 then
		veil.Enabled = false
		return
	end
	veil.Enabled = true
	veil.Brightness = 0.12 * veilAmount
	veil.Contrast = -0.45 * veilAmount
	veil.Saturation = -0.6 * veilAmount
	veil.TintColor = Color3.new(1, 1, 1):Lerp(rgb(200, 200, 196), veilAmount)
end

---------------------------------------------------------------------------------------------------
-- Fire (burning wrecks)
---------------------------------------------------------------------------------------------------

type FireRig = {
	part: Part,
	flames: ParticleEmitter,
	smoke: ParticleEmitter,
	embers: ParticleEmitter,
	light: PointLight,
	active: boolean,
	gen: number,
	target: BasePart?,
	position: Vector3,
	baseBrightness: number,
}
local fireRigs: { FireRig } = {}

local function buildFire()
	for i = 1, 6 do
		local part = newPart("Fire" .. i, Vector3.new(4, 1, 4))
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 140, 60)
		light.Range = 20
		light.Brightness = 2
		light.Shadows = false
		light.Enabled = false
		light.Parent = part
		local rig: FireRig = {
			part = part,
			flames = emitter(part, "Flames", {
				Texture = TEX_FIRE,
				Lifetime = nr(0.6, 1.1),
				Speed = nr(4, 9),
				EmissionDirection = Enum.NormalId.Top,
				SpreadAngle = Vector2.new(12, 12),
				Acceleration = Vector3.new(0, 4, 0),
				LightEmission = 0.8,
				LightInfluence = 0,
				Brightness = 2,
				Color = cs(rgb(255, 190, 100), rgb(220, 70, 20)),
				Size = ns(0, 1.6, 0.4, 3, 1, 0.6),
				Transparency = ns(0, 0.2, 0.7, 0.4, 1, 1),
				Rotation = nr(0, 360),
				RotSpeed = nr(-60, 60),
				WindAffectsDrag = true,
			}),
			smoke = emitter(part, "Smoke", {
				Lifetime = nr(5, 8),
				Speed = nr(6, 10),
				EmissionDirection = Enum.NormalId.Top,
				SpreadAngle = Vector2.new(10, 10),
				Drag = 0.4,
				Acceleration = Vector3.new(0, 1.5, 0),
				Color = cs(rgb(36, 34, 32), rgb(90, 88, 84)),
				Size = ns(0, 3, 1, 14),
				Transparency = ns(0, 0.35, 0.6, 0.55, 1, 1),
				Rotation = nr(0, 360),
				RotSpeed = nr(-12, 12),
				WindAffectsDrag = true,
			}),
			embers = emitter(part, "Embers", {
				Texture = TEX_SPARK,
				Lifetime = nr(1.2, 2.4),
				Speed = nr(5, 12),
				EmissionDirection = Enum.NormalId.Top,
				SpreadAngle = Vector2.new(30, 30),
				Acceleration = Vector3.new(0, 2, 0),
				LightEmission = 1,
				LightInfluence = 0,
				Brightness = 3,
				Color = cs(rgb(255, 170, 70)),
				Size = ns(0, 0.18, 1, 0.05),
				Transparency = ns(0, 0, 1, 1),
				WindAffectsDrag = true,
			}),
			light = light,
			active = false,
			gen = 0,
			target = nil,
			position = Vector3.zero,
			baseBrightness = 2,
		}
		part.CFrame = HIDDEN
		part.Parent = fxFolder
		table.insert(fireRigs, rig)
	end
end

function EffectsController.Fire(target: any, duration: number?, scale: number?): () -> ()
	local noop = function() end
	if not started then
		return noop
	end
	local rig: FireRig? = nil
	for _, r in fireRigs do
		if not r.active then
			rig = r
			break
		end
	end
	if not rig then
		-- Steal the most distant fire from the camera.
		local cam = camPos()
		local far = -1
		for _, r in fireRigs do
			local d = (r.part.Position - cam).Magnitude
			if d > far then
				far = d
				rig = r
			end
		end
	end
	local f = rig :: FireRig
	f.gen += 1
	local gen = f.gen
	local s = math.clamp(scale or 1, 0.3, 3)
	f.active = true
	f.target = if typeof(target) == "Instance" and target:IsA("BasePart") then target else nil
	f.position = if typeof(target) == "Vector3" then target elseif f.target then f.target.Position else Vector3.zero
	f.part.Size = Vector3.new(4 * s, 1, 4 * s)
	f.part.CFrame = CFrame.new(f.position)
	f.flames.Size = ns(0, 1.6 * s, 0.4, 3 * s, 1, 0.6 * s)
	f.flames.Rate = ({ 12, 20, 30 })[quality] * s
	f.smoke.Rate = ({ 3, 5, 7 })[quality] * s
	f.embers.Rate = if quality >= 2 then 6 * s else 0
	f.flames.Enabled = true
	f.smoke.Enabled = true
	f.embers.Enabled = quality >= 2
	f.baseBrightness = 2 * s
	f.light.Range = math.min(14 + 8 * s, 40)
	f.light.Enabled = true

	local function stop()
		if f.gen ~= gen or not f.active then
			return
		end
		f.gen += 1
		f.active = false
		f.target = nil
		f.flames.Enabled = false
		f.smoke.Enabled = false
		f.embers.Enabled = false
		f.light.Enabled = false
		task.delay(8, function()
			if not f.active then
				f.part.CFrame = HIDDEN
			end
		end)
	end
	if duration and duration > 0 then
		animate(duration, nil, stop)
	end
	return stop
end

local function stepFires(now: number)
	for _, f in fireRigs do
		if f.active then
			local t = f.target
			if t then
				if t.Parent == nil then
					f.target = nil
				else
					f.position = t.Position
					f.part.CFrame = CFrame.new(f.position + Vector3.new(0, t.Size.Y * 0.5, 0))
				end
			end
			f.light.Brightness = f.baseBrightness * (0.75 + 0.25 * math.noise(now * 6, f.gen))
		end
	end
end

-- Automatic wreck fires for destroyed vehicles.
local wreckFires: { [Model]: () -> () } = {}
local function watchVehicle(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local function update()
		local destroyed = model:GetAttribute("Destroyed") == true
		if destroyed and not wreckFires[model] then
			local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
			if primary then
				wreckFires[model] = EffectsController.Fire(primary, nil, 1.4)
			end
		elseif not destroyed and wreckFires[model] then
			wreckFires[model]()
			wreckFires[model] = nil
		end
	end
	model:GetAttributeChangedSignal("Destroyed"):Connect(update)
	update()
end

---------------------------------------------------------------------------------------------------
-- Preset-dependent tints (dust colour follows the map's environment)
---------------------------------------------------------------------------------------------------

local function applyEnvironmentTint()
	local preset = LightingPresets.get(GameState.get("LightingPreset"))
	local dust = preset.weather.dustColor
	for _, rig in explosionRigs do
		rig.column.Color = cs(dust:Lerp(rgb(90, 76, 60), 0.35))
		rig.ring.Color = cs(dust)
		rig.dirt.Color = cs(dust:Lerp(rgb(40, 32, 24), 0.6))
	end
end

---------------------------------------------------------------------------------------------------
-- Remotes & lifecycle
---------------------------------------------------------------------------------------------------

local function onRemote(name: string, fn: (...any) -> ())
	local folder = ReplicatedStorage:WaitForChild("Remotes")
	local function hook(r: Instance)
		if r:IsA("RemoteEvent") then
			r.OnClientEvent:Connect(fn)
		elseif r:IsA("UnreliableRemoteEvent") then
			r.OnClientEvent:Connect(fn)
		end
	end
	local existing = folder:FindFirstChild(name)
	if existing then
		hook(existing)
		return
	end
	local conn: RBXScriptConnection
	conn = folder.ChildAdded:Connect(function(child)
		if child.Name == name then
			conn:Disconnect()
			hook(child)
		end
	end)
end

function EffectsController:Init()
	local folder = Instance.new("Folder")
	folder.Name = "ClientFX"
	folder.Parent = workspace
	fxFolder = folder

	buildMuzzle()
	buildTracers()
	buildImpacts()
	buildShells()
	buildExplosions()
	buildSmoke()
	buildFire()
	started = true
end

function EffectsController:Start()
	refreshQuality()
	Bus.connect("SettingsChanged", refreshQuality)
	applyEnvironmentTint()
	GameState.changed("LightingPreset"):Connect(applyEnvironmentTint)

	onRemote("FX_Explosion", function(payload: any)
		if type(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
			return
		end
		local kind = if type(payload.kind) == "string" then payload.kind else "grenade"
		local radius = tonumber(payload.radius) or 0
		if kind == "smoke" then
			EffectsController.Smoke(
				payload.position,
				if radius > 0 then radius else 22,
				tonumber(payload.duration) or 32
			)
		else
			EffectsController.Explosion(payload.position, radius, kind)
		end
	end)
	onRemote("FX_Smoke", function(payload: any)
		if type(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
			return
		end
		EffectsController.Smoke(payload.position, tonumber(payload.radius) or 22, tonumber(payload.duration) or 32)
	end)

	for _, v in CollectionService:GetTagged(Constants.TAGS.Vehicle) do
		watchVehicle(v)
	end
	CollectionService:GetInstanceAddedSignal(Constants.TAGS.Vehicle):Connect(watchVehicle)
	CollectionService:GetInstanceRemovedSignal(Constants.TAGS.Vehicle):Connect(function(model)
		local stop = wreckFires[model :: Model]
		if stop then
			stop()
			wreckFires[model :: Model] = nil
		end
	end)

	local lastQualityPoll = 0
	RunService.RenderStepped:Connect(function(dt)
		local now = os.clock()
		impactsThisFrame = 0
		explosionsThisFrame = 0
		stepTracers(now)
		stepAnims(now)
		stepFires(now)
		stepSmokeVeil(dt)
		if now - lastQualityPoll > 3 then
			lastQualityPoll = now
			refreshQuality()
		end
	end)
end

return EffectsController
