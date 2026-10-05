--[[
	Vehicle FX (client): cosmetic only, never authoritative.
	  * shell tracers: pooled neon slugs simulated with the same ballistic drop as the server shell
	  * main-gun blast: EffectsController.MuzzleFlash (if present) + pooled dust/smoke burst
	  * MG tracers / impacts via EffectsController (fallback: short pooled beam)
	  * armor impacts: sparks; ricochet / penetration accents
	Sounds go through SoundController (keys from Config/Sounds: Tank_Cannon, HMG, LMG, Ricochet,
	Bullet_Impact). Every external call is guarded so the game runs without those controllers.
]]

local Workspace = game:GetService("Workspace")

local FX = {}

type Shell = { part: BasePart, pos: Vector3, vel: Vector3, gravity: number, age: number, ignore: Instance? }

local POOL_SIZE = 12
local MAX_AGE = 4

local folder: Folder
local pool: { BasePart } = {}
local active: { Shell } = {}
local dustAttachment: Attachment
local dust: ParticleEmitter
local smoke: ParticleEmitter
local sparks: ParticleEmitter
local rayParams = RaycastParams.new()
local getController: (string) -> any = function()
	return nil
end

local function call(controllerName: string, method: string, ...: any)
	local c = getController(controllerName)
	local fn = c and c[method]
	if type(fn) == "function" then
		local ok = pcall(fn, ...)
		return ok
	end
	return false
end

local function makeEmitter(name: string, texture: string, color: Color3, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Texture = texture
	e.Color = ColorSequence.new(color)
	e.Rate = 0
	e.Enabled = true
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = dustAttachment
	return e
end

function FX.Init(getter: (string) -> any)
	getController = getter
	folder = Instance.new("Folder")
	folder.Name = "VehicleFX"
	folder.Parent = Workspace
	for _ = 1, POOL_SIZE do
		local p = Instance.new("Part")
		p.Name = "ShellTracer"
		p.Size = Vector3.new(0.35, 0.35, 3.2)
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(255, 190, 110)
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Transparency = 1
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 170, 90)
		light.Range = 10
		light.Brightness = 1.5
		light.Enabled = false
		light.Parent = p
		p.Parent = folder
		table.insert(pool, p)
	end
	dustAttachment = Instance.new("Attachment")
	dustAttachment.Name = "VehicleDust"
	dustAttachment.Parent = Workspace.Terrain
	dust = makeEmitter("Dust", "rbxasset://textures/particles/smoke_main.dds", Color3.fromRGB(170, 150, 120), {
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 10) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(1.5, 2.5),
		Speed = NumberRange.new(10, 22),
		SpreadAngle = Vector2.new(80, 20),
		Drag = 3,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
	})
	smoke = makeEmitter("Blast", "rbxasset://textures/particles/smoke_main.dds", Color3.fromRGB(110, 105, 100), {
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 7) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(1, 1.8),
		Speed = NumberRange.new(8, 25),
		SpreadAngle = Vector2.new(15, 15),
		Drag = 4,
	})
	sparks = makeEmitter("Sparks", "rbxasset://textures/particles/sparkles_main.dds", Color3.fromRGB(255, 200, 120), {
		Size = NumberSequence.new(0.35, 0),
		LightEmission = 1,
		Lifetime = NumberRange.new(0.2, 0.5),
		Speed = NumberRange.new(25, 50),
		SpreadAngle = Vector2.new(60, 60),
		Acceleration = Vector3.new(0, -80, 0),
	})
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { folder }
end

local function burst(emitter: ParticleEmitter, position: Vector3, direction: Vector3?, count: number)
	dustAttachment.WorldCFrame = if direction and direction.Magnitude > 1e-3
		then CFrame.lookAlong(position, direction) * CFrame.Angles(-math.pi / 2, 0, 0)
		else CFrame.new(position)
	emitter:Emit(count)
end

-- Main gun shot (any vehicle). `chassis` is the firing hull (for ground dust), may be nil.
function FX.MainGunFired(origin: Vector3, velocity: Vector3, gravityScale: number, scale: number, ignore: Instance?)
	local dir = velocity.Unit
	if not call("EffectsController", "MuzzleFlash", CFrame.lookAlong(origin, dir), 3 + scale * 0.4) then
		burst(sparks, origin, dir, 10)
	end
	burst(smoke, origin + dir * 1.5, dir, math.floor(8 + scale * 2))
	-- ground dust kicked up by the blast
	local hit = Workspace:Raycast(origin, Vector3.new(0, -12, 0), rayParams)
	if hit then
		burst(dust, hit.Position, Vector3.yAxis, math.floor(6 + scale * 2))
	end
	call("SoundController", "PlayAt", "Tank_Cannon", origin, { volume = 0.6 + math.min(scale, 7) * 0.08 })

	local part = table.remove(pool)
	if part then
		part.Transparency = 0
		local light = part:FindFirstChildOfClass("PointLight")
		if light then
			light.Enabled = true
		end
		part.CFrame = CFrame.lookAlong(origin, dir)
		table.insert(
			active,
			{ part = part, pos = origin, vel = velocity, gravity = gravityScale, age = 0, ignore = ignore }
		)
	end
end

local function release(s: Shell)
	s.part.Transparency = 1
	local light = s.part:FindFirstChildOfClass("PointLight")
	if light then
		light.Enabled = false
	end
	s.part.CFrame = CFrame.new(0, -1e4, 0)
	table.insert(pool, s.part)
end

function FX.Step(dt: number)
	if #active == 0 then
		return
	end
	local g = Workspace.Gravity
	for i = #active, 1, -1 do
		local s = active[i]
		s.age += dt
		s.vel += Vector3.new(0, -g * s.gravity * dt, 0)
		local step = s.vel * dt
		if s.ignore then
			rayParams.FilterDescendantsInstances = { folder, s.ignore }
		else
			rayParams.FilterDescendantsInstances = { folder }
		end
		local hit = Workspace:Raycast(s.pos, step, rayParams)
		if hit or s.age > MAX_AGE then
			table.remove(active, i)
			release(s)
		else
			s.pos += step
			s.part.CFrame = CFrame.lookAlong(s.pos, s.vel.Unit)
		end
	end
	rayParams.FilterDescendantsInstances = { folder }
end

function FX.MGFired(origin: Vector3, hit: Vector3, normal: Vector3?, material: string?, heavy: boolean)
	local dir = hit - origin
	if dir.Magnitude < 1e-3 then
		return
	end
	call("EffectsController", "MuzzleFlash", CFrame.lookAlong(origin, dir.Unit), if heavy then 1.2 else 0.8)
	call("EffectsController", "Tracer", origin, hit, Color3.fromRGB(255, 200, 120))
	if normal then
		if not call("EffectsController", "Impact", hit, normal, material or "Concrete") then
			burst(sparks, hit, normal, 3)
		end
	end
	call("SoundController", "PlayAt", if heavy then "HMG" else "LMG", origin, { volume = 0.7 })
end

-- Shell hitting a vehicle. result: "penetration" | "nonpen" | "ricochet".
function FX.ArmorImpact(pos: Vector3, normal: Vector3, result: string)
	burst(sparks, pos, normal, if result == "penetration" then 30 else 18)
	call("EffectsController", "Impact", pos, normal, "Metal")
	if result == "ricochet" then
		call("SoundController", "PlayAt", "Ricochet", pos, { volume = 1.2 })
	else
		call("SoundController", "PlayAt", "Bullet_Impact", pos, { volume = 1.4, pitch = 0.5 })
	end
end

function FX.Destroy()
	for _, s in active do
		release(s)
	end
	table.clear(active)
end

return FX
