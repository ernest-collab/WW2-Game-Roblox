--[[
	SoundController (client): pooled 3D/2D audio, weapon shot layering, ambience and reverb.

	Public API (docs/ARCHITECTURE.md section 7 + contract additions):
	    SoundController.PlayAt(key, position, opts?)           -- pooled 3D one-shot
	    SoundController.Play2D(key, opts?)                     -- pooled 2D one-shot
	    SoundController.PlayWeaponShot(weaponId, position, isLocal)
	    SoundController.PlayLoop(key, parent: Instance?, opts?) -> LoopHandle?   (engines, beds)
	    SoundController.IsIndoors() -> boolean
	  opts = {volume: number?, pitch: number?, delay: number?, lowpass: number? (0..1),
	          minDistance: number?, maxDistance: number?}

	Keys come from Config/Sounds.luau (asset id slot + built-in fallback layers).

	Voices: fixed pools of Sound instances (3D voices = Attachment in Terrain + Sound + EQ, 2D voices
	= Sound in SoundService). Per-key voice caps steal the oldest voice; a per-frame budget prevents
	bursts (e.g. 30 players firing) from thrashing. No Instance is created per play.

	Listens to: Combat_ShotFX (bullet whiz near the local camera), Combat_HitConfirm (2D hit/kill/
	headshot), FX_Explosion (explosion/smoke sounds, delayed by distance), Round_Ended + Phase
	(stingers), objective Owner changes (captured/lost), capture ticks while inside a capturing zone.
	Lightning thunder and distant artillery rumble are triggered by AtmosphereController.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Sounds = require(Shared.Config.Sounds)
local LightingPresets = require(Shared.Config.LightingPresets)
local GameState = require(Shared.GameState)

local SoundController = {}

export type PlayOpts = {
	volume: number?,
	pitch: number?,
	delay: number?,
	lowpass: number?,
	minDistance: number?,
	maxDistance: number?,
}

export type LoopHandle = {
	SetVolume: (self: LoopHandle, mult: number) -> (),
	SetPitch: (self: LoopHandle, mult: number) -> (),
	SetLowpass: (self: LoopHandle, amount: number) -> (),
	Stop: (self: LoopHandle) -> (),
	IsActive: (self: LoopHandle) -> boolean,
}

type Voice = {
	sound: Sound,
	eq: EqualizerSoundEffect,
	att: Attachment?,
	busy: boolean,
	key: string,
	startedAt: number,
	stopAt: number,
	baseVolume: number,
	gen: number,
}

local LocalPlayer = Players.LocalPlayer
local rng = Random.new()

local MAX_3D_VOICES = 56
local MAX_2D_VOICES = 20
local MAX_NEW_VOICES_PER_FRAME = 28
local MAX_LOOPS = 32
local MAX_VOICE_LIFE = 10 -- seconds; safety cap for any one-shot
local FADE_TIME = 0.06
local SPEED_OF_SOUND = Sounds.SPEED_OF_SOUND

local voices3D: { Voice } = {}
local voices2D: { Voice } = {}
local newVoicesThisFrame = 0
local groups: { [string]: SoundGroup } = {}
local voiceFolder2D: Folder? = nil
local loopFolder2D: Folder? = nil
local activeLoops = 0
local warnedKeys: { [string]: boolean } = {}
local singleLayerCache: { [string]: { Sounds.Layer } } = {}

local indoors = false
local indoorAlpha = 0
local lastCombatNoise = -math.huge
local started = false

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

local function camera(): Camera?
	return workspace.CurrentCamera
end

local function listenerPosition(): Vector3
	local cam = camera()
	return if cam then cam.CFrame.Position else Vector3.zero
end

-- Connects to a remote by name without blocking (remotes may be created late or never).
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

local function soundGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end
	-- Same flat layout as SettingsController (Effects/Music are siblings of Master and are
	-- pre-multiplied by it there), so whoever runs first creates identical groups.
	local g = Instance.new("SoundGroup")
	g.Name = name
	g.Volume = 1
	g.Parent = SoundService
	return g
end

local function applyLowpass(eq: EqualizerSoundEffect, amount: number)
	if amount <= 0.01 then
		eq.Enabled = false
		return
	end
	amount = math.clamp(amount, 0, 1)
	eq.HighGain = -42 * amount
	eq.MidGain = -14 * amount
	eq.LowGain = 4 * amount
	eq.Enabled = true
end

local function getDef(key: string): Sounds.SoundDef?
	local def = Sounds.get(key)
	if not def and not warnedKeys[key] then
		warnedKeys[key] = true
		warn(`[SoundController] unknown sound key '{key}'`)
	end
	return def
end

-- Layers to play for a def: the real asset if configured, otherwise the fallback layers.
local function layersFor(def: Sounds.SoundDef): { Sounds.Layer }
	if def.id ~= "" then
		local cached = singleLayerCache[def.key]
		if not cached or cached[1].sound ~= def.id then
			cached = { { sound = def.id, volume = 1, pitch = 1, duration = def.duration, looped = def.looped } }
			singleLayerCache[def.key] = cached
		end
		return cached
	end
	return def.fallback
end

---------------------------------------------------------------------------------------------------
-- Voice pool
---------------------------------------------------------------------------------------------------

local function releaseVoice(v: Voice)
	v.busy = false
	v.gen += 1
	v.sound:Stop()
	v.eq.Enabled = false
end

local function makeVoice(is3D: boolean): Voice
	local sound = Instance.new("Sound")
	sound.Name = "Voice"
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	local eq = Instance.new("EqualizerSoundEffect")
	eq.Enabled = false
	eq.Priority = 1
	eq.Parent = sound
	local att: Attachment? = nil
	if is3D then
		local a = Instance.new("Attachment")
		a.Name = "SFXVoice"
		sound.Parent = a
		a.Parent = workspace.Terrain
		att = a
	else
		sound.Parent = voiceFolder2D
	end
	local v: Voice = {
		sound = sound,
		eq = eq,
		att = att,
		busy = false,
		key = "",
		startedAt = 0,
		stopAt = 0,
		baseVolume = 0,
		gen = 0,
	}
	sound.Ended:Connect(function()
		if v.busy then
			releaseVoice(v)
		end
	end)
	return v
end

-- Picks a voice: steals the oldest same-key voice past the key's cap, else a free voice, else
-- the globally oldest voice.
local function acquire(pool: { Voice }, key: string, cap: number): Voice?
	local free: Voice? = nil
	local oldestSame: Voice? = nil
	local oldestAny: Voice? = nil
	local sameCount = 0
	for _, v in pool do
		if not v.busy then
			if not free then
				free = v
			end
		else
			if v.key == key then
				sameCount += 1
				if not oldestSame or v.startedAt < oldestSame.startedAt then
					oldestSame = v
				end
			end
			if not oldestAny or v.startedAt < oldestAny.startedAt then
				oldestAny = v
			end
		end
	end
	local chosen = if sameCount >= cap and oldestSame then oldestSame else (free or oldestAny)
	if chosen and chosen.busy then
		releaseVoice(chosen)
	end
	return chosen
end

local function playLayer(
	def: Sounds.SoundDef,
	layer: Sounds.Layer,
	position: Vector3?,
	opts: PlayOpts?,
	layerCount: number
)
	if newVoicesThisFrame >= MAX_NEW_VOICES_PER_FRAME then
		return
	end
	newVoicesThisFrame += 1
	local pool = if position then voices3D else voices2D
	local v = acquire(pool, def.key, def.maxVoices * layerCount)
	if not v then
		return
	end
	local o = opts or {}
	local s = v.sound
	s.SoundId = layer.sound
	s.Looped = false
	s.TimePosition = layer.start or 0
	local variation = 1 + rng:NextNumber(-def.pitchVar, def.pitchVar)
	s.PlaybackSpeed = math.max(0.05, def.pitch * (layer.pitch or 1) * (o.pitch or 1) * variation)
	local volume = def.volume * (layer.volume or 1) * (o.volume or 1)
	s.Volume = volume
	s.SoundGroup = groups[def.group] or groups.Effects
	if position then
		local att = v.att :: Attachment
		att.Position = position -- Terrain sits at the origin, so local == world
		s.RollOffMinDistance = o.minDistance or def.minDistance
		s.RollOffMaxDistance = o.maxDistance or def.maxDistance
	end
	applyLowpass(v.eq, o.lowpass or 0)
	local now = os.clock()
	v.busy = true
	v.key = def.key
	v.startedAt = now
	v.baseVolume = volume
	v.stopAt = now + math.min(layer.duration or def.duration or MAX_VOICE_LIFE, MAX_VOICE_LIFE)
	s:Play()
end

local function play(key: string, position: Vector3?, opts: PlayOpts?)
	if not started then
		return
	end
	local def = getDef(key)
	if not def then
		return
	end
	if position then
		-- Distance cull: beyond max roll-off the sound is inaudible anyway.
		local maxDist = (opts and opts.maxDistance) or def.maxDistance
		if (position - listenerPosition()).Magnitude > maxDist * 1.05 then
			return
		end
	end
	local layers = layersFor(def)
	local count = #layers
	if count == 0 then
		return
	end
	local baseDelay = (opts and opts.delay) or 0
	for _, layer in layers do
		local d = baseDelay + (layer.delay or 0)
		if d > 0.01 then
			task.delay(d, playLayer, def, layer, position, opts, count)
		else
			playLayer(def, layer, position, opts, count)
		end
	end
end

local function sweep()
	newVoicesThisFrame = 0
	local now = os.clock()
	for _, pool in { voices3D, voices2D } do
		for _, v in pool do
			if v.busy then
				if now >= v.stopAt then
					releaseVoice(v)
				elseif now >= v.stopAt - FADE_TIME then
					v.sound.Volume = v.baseVolume * math.max(0, (v.stopAt - now) / FADE_TIME)
				elseif now - v.startedAt > 0.5 and not v.sound.Playing then
					releaseVoice(v) -- failed to load / stopped externally
				end
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Loops (engines, ambience). Bounded; owned by the caller through the returned handle.
---------------------------------------------------------------------------------------------------

function SoundController.PlayLoop(key: string, parent: Instance?, opts: PlayOpts?): LoopHandle?
	local def = getDef(key)
	if not def or activeLoops >= MAX_LOOPS then
		return nil
	end
	local layers = layersFor(def)
	if #layers == 0 then
		return nil
	end
	local o = opts or {}
	local is3D = parent ~= nil and (parent:IsA("BasePart") or parent:IsA("Attachment"))
	local host = if is3D then parent else loopFolder2D
	local entries: { { sound: Sound, eq: EqualizerSoundEffect, volume: number, pitch: number } } = {}
	local active = true
	activeLoops += 1

	local volumeMult, pitchMult = o.volume or 1, o.pitch or 1
	for _, layer in layers do
		local s = Instance.new("Sound")
		s.Name = `Loop_{key}`
		s.SoundId = layer.sound
		s.Looped = true
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = o.minDistance or def.minDistance
		s.RollOffMaxDistance = o.maxDistance or def.maxDistance
		s.SoundGroup = groups[def.group] or groups.Effects
		s.TimePosition = layer.start or 0
		local eq = Instance.new("EqualizerSoundEffect")
		eq.Enabled = false
		eq.Parent = s
		local entry = {
			sound = s,
			eq = eq,
			volume = def.volume * (layer.volume or 1),
			pitch = def.pitch * (layer.pitch or 1),
		}
		s.Volume = entry.volume * volumeMult
		s.PlaybackSpeed = entry.pitch * pitchMult
		s.Parent = host
		table.insert(entries, entry)
		s:Play()
	end

	local handle = {}
	local function stop()
		if not active then
			return
		end
		active = false
		activeLoops -= 1
		for _, e in entries do
			e.sound:Destroy()
		end
		table.clear(entries)
	end
	-- If the host (e.g. a vehicle part) is destroyed, the sounds go with it: release the slot.
	if #entries > 0 then
		entries[1].sound.AncestryChanged:Connect(function(_, newParent)
			if newParent == nil then
				stop()
			end
		end)
	end
	function handle.SetVolume(_self, mult: number)
		volumeMult = mult
		for _, e in entries do
			e.sound.Volume = e.volume * mult
		end
	end
	function handle.SetPitch(_self, mult: number)
		pitchMult = mult
		for _, e in entries do
			e.sound.PlaybackSpeed = math.max(0.05, e.pitch * mult)
		end
	end
	function handle.SetLowpass(_self, amount: number)
		for _, e in entries do
			applyLowpass(e.eq, amount)
		end
	end
	function handle.Stop(_self)
		stop()
	end
	function handle.IsActive(_self)
		return active
	end
	return handle :: any
end

---------------------------------------------------------------------------------------------------
-- Public one-shots
---------------------------------------------------------------------------------------------------

function SoundController.PlayAt(key: string, position: Vector3, opts: PlayOpts?)
	if typeof(position) ~= "Vector3" then
		return
	end
	play(key, position, opts)
end

function SoundController.Play2D(key: string, opts: PlayOpts?)
	play(key, nil, opts)
end

function SoundController.IsIndoors(): boolean
	return indoors
end

-- Weapon id -> Sounds key (via Config/Weapons `sound`, guarded; category heuristics otherwise).
local CATEGORY_FAMILY = {
	AssaultRifle = "Rifle_Semi",
	SMG = "SMG",
	BoltAction = "Rifle_Bolt",
	SemiAuto = "Rifle_Semi",
	MachineGun = "LMG",
	Pistol = "Pistol",
	Shotgun = "Shotgun",
	Sniper = "Sniper",
	AntiTank = "Launcher",
	Grenade = "Grenade_Throw",
	Smoke = "Grenade_Throw",
	Explosive = "Grenade_Throw",
	Melee = "Melee_Swing",
}
local familyCache: { [string]: string } = {}
local weaponsModule: any = nil
local weaponsTried = false

local function weaponDef(weaponId: string): any
	if not weaponsTried then
		weaponsTried = true
		local m = Shared.Config:FindFirstChild("Weapons")
		if m and m:IsA("ModuleScript") then
			local ok, result = pcall(require, m)
			if ok then
				weaponsModule = result
			end
		end
	end
	local W = weaponsModule
	if type(W) ~= "table" then
		return nil
	end
	if type(W.get) == "function" then
		local ok, d = pcall(W.get, weaponId)
		if ok and type(d) == "table" then
			return d
		end
	end
	if type(W.byId) == "table" and type(W.byId[weaponId]) == "table" then
		return W.byId[weaponId]
	end
	if type(W[weaponId]) == "table" then
		return W[weaponId]
	end
	return nil
end

local function familyFor(weaponId: string): string
	local cached = familyCache[weaponId]
	if cached then
		return cached
	end
	local family = "Rifle_Semi"
	if Sounds.get(weaponId) then
		family = weaponId -- vehicle guns etc. may pass a Sounds key directly ("Tank_Cannon")
	else
		local d = weaponDef(weaponId)
		if d then
			if type(d.sound) == "string" and Sounds.get(d.sound) then
				family = d.sound
			elseif type(d.category) == "string" and CATEGORY_FAMILY[d.category] then
				family = CATEGORY_FAMILY[d.category]
			end
		end
		if weaponsModule == nil then
			return family -- don't cache guesses while Weapons config is unavailable
		end
	end
	familyCache[weaponId] = family
	return family
end

function SoundController.PlayWeaponShot(weaponId: string, position: Vector3, isLocal: boolean)
	if typeof(position) ~= "Vector3" then
		return
	end
	local family = familyFor(tostring(weaponId))
	local def = Sounds.get(family)
	if not def then
		return
	end
	lastCombatNoise = os.clock()
	if isLocal then
		-- First person: dry and in-head, slightly muffled indoors-free. Full volume 2D.
		play(family, nil, { volume = 0.9 })
		return
	end
	local dist = (position - listenerPosition()).Magnitude
	local delay = if dist > 150 then dist / SPEED_OF_SOUND else 0
	-- Near "crack" layers: crisp up close, progressively duller.
	local nearLimit = if def.heavy then 320 else 240
	if dist < nearLimit then
		local lp = math.clamp((dist - 50) / (nearLimit - 50), 0, 1) * 0.7
		play(family, position, { delay = delay, lowpass = lp })
	end
	-- Distant "boom": delayed by the speed of sound, low-passed with distance.
	if def.distant and dist > 110 then
		local farLp = 0.35 + math.clamp((dist - 150) / 1000, 0, 1) * 0.55
		local fade = math.clamp((dist - 110) / 120, 0, 1)
		play(def.distant, position, { delay = delay, lowpass = farLp, volume = fade })
	end
end

---------------------------------------------------------------------------------------------------
-- Event reactions
---------------------------------------------------------------------------------------------------

local function sideOf(player: Player?): string
	if not player then
		return ""
	end
	local s = player:GetAttribute("Side")
	return if type(s) == "string" then s else ""
end

-- Closest point on segment a->b to p, and the segment parameter t.
local function closestOnSegment(a: Vector3, b: Vector3, p: Vector3): (Vector3, number)
	local ab = b - a
	local len2 = ab:Dot(ab)
	if len2 < 1e-6 then
		return a, 0
	end
	local t = math.clamp((p - a):Dot(ab) / len2, 0, 1)
	return a + ab * t, t
end

local lastWhiz = 0
local function onShotFX(payload: any)
	if type(payload) ~= "table" or typeof(payload.origin) ~= "Vector3" or type(payload.hits) ~= "table" then
		return
	end
	local shooter = payload.shooter
	if typeof(shooter) == "Instance" and shooter == LocalPlayer then
		return
	end
	local mySide = sideOf(LocalPlayer)
	if mySide ~= "" and typeof(shooter) == "Instance" and shooter:IsA("Player") and sideOf(shooter) == mySide then
		return -- friendly fire passes silently (crack would be confusing)
	end
	local now = os.clock()
	if now - lastWhiz < 0.08 then
		return
	end
	local listener = listenerPosition()
	local origin: Vector3 = payload.origin
	if (origin - listener).Magnitude < 25 then
		return -- too close to the shooter for a meaningful pass-by
	end
	local checked = 0
	for _, hit in payload.hits do
		checked += 1
		if checked > 4 then
			break
		end
		if type(hit) == "table" and typeof(hit.pos) == "Vector3" then
			local point, t = closestOnSegment(origin, hit.pos, listener)
			local miss = (point - listener).Magnitude
			if miss < 9 and t > 0.02 then
				lastWhiz = now
				local closeness = 1 - miss / 9
				if t < 0.995 then
					play("Bullet_Whiz", point, { volume = 0.5 + closeness * 0.6, pitch = 0.9 + closeness * 0.25 })
				else
					-- Round landed right next to us.
					play("Bullet_Impact", hit.pos, { volume = 0.9 })
				end
				return
			end
		end
	end
end

local function onHitConfirm(payload: any)
	if type(payload) ~= "table" then
		return
	end
	if payload.headshot then
		play("Headshot", nil, nil)
	else
		play("Hitmarker", nil, if payload.target == "vehicle" then { pitch = 0.7 } else nil)
	end
	if payload.killed then
		play("Kill_Confirm", nil, { delay = 0.06 })
	end
end

local function onExplosion(payload: any)
	if type(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end
	local kind = if type(payload.kind) == "string" then payload.kind else "grenade"
	local position: Vector3 = payload.position
	local dist = (position - listenerPosition()).Magnitude
	local delay = if dist > 150 then dist / SPEED_OF_SOUND else 0
	local lp = math.clamp((dist - 120) / 1200, 0, 1) * 0.8
	if kind == "smoke" then
		play("Smoke_Hiss", position, { delay = delay })
		return
	end
	lastCombatNoise = os.clock()
	local key = if kind == "grenade" then "Explosion_Small" else "Explosion_Large"
	local radius = tonumber(payload.radius) or 12
	local sizeVol = math.clamp(0.75 + radius / 60, 0.75, 1.3)
	-- Indoors, explosions outside sound duller.
	if indoors then
		lp = math.max(lp, 0.4)
	end
	play(
		key,
		position,
		{ delay = delay, lowpass = lp, volume = sizeVol, pitch = if kind == "vehicle" then 0.85 else 1 }
	)
end

local function onRoundEnded(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local mySide = sideOf(LocalPlayer)
	if payload.winner == mySide and mySide ~= "" then
		play("Music_Victory", nil, nil)
	elseif payload.winner ~= "Draw" and mySide ~= "" then
		play("Music_Defeat", nil, nil)
	end
end

-- Objective captured/lost stingers for the local player's side.
local function watchObjective(obj: Instance)
	local prevOwner = obj:GetAttribute("Owner")
	obj:GetAttributeChangedSignal("Owner"):Connect(function()
		local owner = obj:GetAttribute("Owner")
		local mySide = sideOf(LocalPlayer)
		if mySide ~= "" and GameState.get("Phase") == "InRound" then
			if owner == mySide then
				play("Objective_Captured", nil, nil)
			elseif prevOwner == mySide then
				play("Objective_Lost", nil, nil)
			end
		end
		prevOwner = owner
	end)
end

local function captureTick()
	local mySide = sideOf(LocalPlayer)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if mySide == "" or not root or not root:IsA("BasePart") then
		return
	end
	local ok, objectives = pcall(GameState.objectives)
	if not ok then
		return
	end
	for _, obj in objectives:GetChildren() do
		local pos = obj:GetAttribute("Position")
		local radius = obj:GetAttribute("Radius")
		if typeof(pos) == "Vector3" and type(radius) == "number" then
			local flat = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
			if
				flat.Magnitude <= radius
				and obj:GetAttribute("Capturing") == mySide
				and obj:GetAttribute("Contested") ~= true
				and obj:GetAttribute("Locked") ~= true
			then
				play("Capture_Tick", nil, nil)
				return
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Environment: indoor detection, reverb and ambient beds
---------------------------------------------------------------------------------------------------

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function detectIndoors(): boolean
	local cam = camera()
	if not cam then
		return false
	end
	local exclude: { Instance } = {}
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
	local origin = cam.CFrame.Position
	local up = workspace:Raycast(origin, Vector3.new(0, 70, 0), rayParams)
	if not up then
		return false
	end
	-- Second, slightly offset ray avoids false positives under a single beam / tree branch.
	local up2 = workspace:Raycast(origin + cam.CFrame.LookVector * 3, Vector3.new(0, 70, 0), rayParams)
	return up2 ~= nil
end

local windLoop: LoopHandle? = nil
local rainLoop: LoopHandle? = nil
local battleLoop: LoopHandle? = nil
local currentReverb = ""

local function ensureBeds()
	if not windLoop or not windLoop:IsActive() then
		windLoop = SoundController.PlayLoop("Ambient_Wind", nil, { volume = 0 })
	end
	if not rainLoop or not rainLoop:IsActive() then
		rainLoop = SoundController.PlayLoop("Ambient_Rain", nil, { volume = 0 })
	end
	local battleDef = Sounds.get("Ambient_Battle")
	if battleDef and battleDef.id ~= "" and (not battleLoop or not battleLoop:IsActive()) then
		battleLoop = SoundController.PlayLoop("Ambient_Battle", nil, { volume = 0 })
	end
end

local function updateEnvironment(dt: number)
	indoors = detectIndoors()
	indoorAlpha += ((if indoors then 1 else 0) - indoorAlpha) * math.clamp(dt * 4, 0, 1)

	local presetId = GameState.get("LightingPreset")
	local preset = LightingPresets.get(presetId)
	local weather = LightingPresets.getWeather(LightingPresets.resolveWeather(presetId, GameState.get("Weather")))
	local ambience = LightingPresets.getAmbience(GameState.get("MapId"))

	-- Reverb: map/outdoor flavour, or a room when roofed.
	local reverbName = if indoors then ambience.indoorReverb else (ambience.reverb or preset.reverb)
	if reverbName ~= currentReverb then
		currentReverb = reverbName
		pcall(function()
			SoundService.AmbientReverb = (Enum.ReverbType :: any)[reverbName]
		end)
	end

	ensureBeds()
	local inRound = GameState.get("Phase") == "InRound"
	if windLoop then
		local wind = 0.55 + weather.windMult * 0.35
		windLoop:SetVolume(wind * (1 - indoorAlpha * 0.6))
		windLoop:SetLowpass(indoorAlpha * 0.7)
	end
	if rainLoop then
		rainLoop:SetVolume(weather.rain * 1.6 * (1 - indoorAlpha * 0.55))
		rainLoop:SetLowpass(indoorAlpha * 0.8)
	end
	if battleLoop then
		battleLoop:SetVolume(if inRound then ambience.battle else 0)
		battleLoop:SetLowpass(0.5 + indoorAlpha * 0.3)
	end
end

-- Procedural distant battle: bursts of far gunfire at random bearings while a round is live.
local nextBattle = 0
local nextBird = 0
local function updateOneShotAmbience()
	local now = os.clock()
	local ambience = LightingPresets.getAmbience(GameState.get("MapId"))
	local inRound = GameState.get("Phase") == "InRound"
	local listener = listenerPosition()

	local battleDef = Sounds.get("Ambient_Battle")
	if inRound and ambience.battle > 0 and battleDef and battleDef.id == "" and now >= nextBattle then
		nextBattle = now + rng:NextNumber(1.5, 5) / ambience.battle
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(350, 900)
		local pos = listener + Vector3.new(math.cos(angle) * dist, rng:NextNumber(0, 40), math.sin(angle) * dist)
		local automatic = rng:NextNumber() < 0.45
		local shots = if automatic then rng:NextInteger(3, 9) else rng:NextInteger(1, 2)
		local interval = if automatic then rng:NextNumber(0.07, 0.12) else rng:NextNumber(0.4, 1.1)
		for i = 0, shots - 1 do
			play("Ambient_Battle", pos, {
				delay = i * interval,
				lowpass = 0.55 + indoorAlpha * 0.3,
				volume = 0.8 + rng:NextNumber(-0.2, 0.2),
			})
		end
	end

	local weatherId = LightingPresets.resolveWeather(GameState.get("LightingPreset"), GameState.get("Weather"))
	local calm = now - lastCombatNoise > 15
	if ambience.birds and (weatherId == "Clear" or weatherId == "Fog") and calm and not indoors and now >= nextBird then
		nextBird = now + rng:NextNumber(5, 14)
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(25, 70)
		play(
			"Ambient_Birds",
			listener + Vector3.new(math.cos(angle) * dist, rng:NextNumber(8, 20), math.sin(angle) * dist),
			{ pitch = rng:NextNumber(0.9, 1.1) }
		)
	end
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

function SoundController:Init()
	groups.Master = soundGroup("Master")
	groups.Effects = soundGroup("Effects")
	groups.Music = soundGroup("Music")

	local f2d = Instance.new("Folder")
	f2d.Name = "SFX2D"
	f2d.Parent = SoundService
	voiceFolder2D = f2d
	local floop = Instance.new("Folder")
	floop.Name = "SFXLoops"
	floop.Parent = SoundService
	loopFolder2D = floop

	for _ = 1, MAX_3D_VOICES do
		table.insert(voices3D, makeVoice(true))
	end
	for _ = 1, MAX_2D_VOICES do
		table.insert(voices2D, makeVoice(false))
	end
	started = true
end

function SoundController:Start()
	-- Preload every referenced sound so first plays are instant.
	task.spawn(function()
		pcall(ContentProvider.PreloadAsync, ContentProvider, Sounds.allContent())
	end)

	RunService.Heartbeat:Connect(sweep)

	onRemote("Combat_ShotFX", onShotFX)
	onRemote("Combat_HitConfirm", onHitConfirm)
	onRemote("FX_Explosion", onExplosion)
	onRemote("Round_Ended", onRoundEnded)

	GameState.changed("Phase"):Connect(function()
		if GameState.get("Phase") == "InRound" then
			play("Spawn_Whistle", nil, nil)
			play("Music_RoundStart", nil, nil)
		end
	end)

	task.spawn(function()
		local objectives = GameState.objectives()
		for _, obj in objectives:GetChildren() do
			watchObjective(obj)
		end
		objectives.ChildAdded:Connect(watchObjective)
	end)

	-- Low-frequency environment loop (4 Hz) + capture ticks (1 Hz).
	task.spawn(function()
		local last = os.clock()
		local tickAcc = 0
		while true do
			task.wait(0.25)
			local now = os.clock()
			local dt = now - last
			last = now
			local ok, err = pcall(updateEnvironment, dt)
			if not ok then
				warn(`[SoundController] environment update failed: {err}`)
			end
			pcall(updateOneShotAmbience)
			tickAcc += dt
			if tickAcc >= 1 then
				tickAcc = 0
				pcall(captureTick)
			end
		end
	end)
end

return SoundController
