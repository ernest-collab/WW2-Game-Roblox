--[[
	Sounds: every sound key the game plays, with a slot for a real asset and a procedural fallback.

	Owned by the Sound & Atmosphere team; played through SoundController (client).
	See docs/AUDIO.md for the full guide.

	ADDING A REAL SOUND IS A ONE-LINE CHANGE:
	    SMG = def({ id = "rbxassetid://1234567890", ... })
	                ^^ paste your uploaded / licensed asset id here.
	When `id` is non-empty it is played as a single sound (with the def's volume/pitch/variation)
	and the `fallback` layers are ignored. When `id` is "" the fallback layers are played instead.

	FALLBACKS only use sounds that ship inside the Roblox client (`rbxasset://sounds/...`). They are
	layered, pitched and trimmed to approximate the real thing (e.g. a pitched-down rocket launch
	layered with a collision thud reads as a rifle shot). They are placeholders: replace them.

	Layer fields:
	  sound     rbxasset path (or any content id)
	  volume    multiplier (default 1)
	  pitch     PlaybackSpeed multiplier (default 1)
	  delay     seconds after the trigger (default 0)
	  start     TimePosition to start from (default 0)
	  duration  hard cut after N seconds (short fade). nil = play to the end
	  looped    loop this layer (only for looped defs / PlayLoop)
]]

export type Layer = {
	sound: string,
	volume: number?,
	pitch: number?,
	delay: number?,
	start: number?,
	duration: number?,
	looped: boolean?,
}

export type SoundDef = {
	key: string,
	id: string, -- paste uploaded/licensed asset id here ("" = use fallback layers)
	volume: number,
	pitch: number,
	pitchVar: number, -- random +/- PlaybackSpeed variation (fraction)
	minDistance: number, -- RollOffMinDistance (3D)
	maxDistance: number, -- RollOffMaxDistance (3D)
	group: string, -- SoundGroup name: "Effects" | "Music"
	maxVoices: number, -- concurrent voices for this key before the oldest is stolen
	looped: boolean,
	duration: number?, -- cut for the real asset (`id`) as well
	fallback: { Layer },
	distant: string?, -- weapons: key of the distant "boom" layer
	heavy: boolean?, -- weapons: louder, carries further
}

-- Built-in client sounds (these ship with every Roblox client).
local ROCKET = "rbxasset://sounds/Rocket shot.wav"
local COLLIDE = "rbxasset://sounds/collide.wav"
local SLASH = "rbxasset://sounds/swordslash.wav"
local PING = "rbxasset://sounds/electronicpingshort.wav"
local STEPS = "rbxasset://sounds/action_footsteps_plastic.mp3"
local JUMP = "rbxasset://sounds/action_jump.mp3"
local FALLING = "rbxasset://sounds/action_falling.mp3"
local WATER = "rbxasset://sounds/impact_water.mp3"
local BUTTON = "rbxasset://sounds/button.wav"
local CLICK = "rbxasset://sounds/clickfast.wav"
local SNAP = "rbxasset://sounds/snap.wav"

local function L(sound: string, volume: number?, pitch: number?, extra: { [string]: any }?): Layer
	local layer: { [string]: any } = { sound = sound, volume = volume or 1, pitch = pitch or 1 }
	if extra then
		for k, v in extra do
			layer[k] = v
		end
	end
	return layer :: any
end

local Sounds: { [string]: SoundDef } = {}

local function def(key: string, t: { [string]: any })
	local d: { [string]: any } = {
		key = key,
		id = "",
		volume = 1,
		pitch = 1,
		pitchVar = 0.04,
		minDistance = 8,
		maxDistance = 400,
		group = "Effects",
		maxVoices = 6,
		looped = false,
		fallback = {},
	}
	for k, v in t do
		d[k] = v
	end
	Sounds[key] = d :: any
end

---------------------------------------------------------------------------------------------------
-- Weapons (key = Config/Weapons `sound` field). Near layers; `distant` is played additionally
-- (delayed by distance / speed of sound, low-passed) for shots further than ~150 studs.
---------------------------------------------------------------------------------------------------
def("Rifle_Bolt", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 1,
	minDistance = 14,
	maxDistance = 700,
	maxVoices = 6,
	distant = "Distant_Gunshot_Heavy",
	heavy = true,
	fallback = {
		L(ROCKET, 0.8, 1.55, { duration = 0.55 }),
		L(COLLIDE, 0.9, 0.55),
		L(SNAP, 0.55, 0.7),
	},
})
def("Rifle_Semi", {
	id = "", -- paste uploaded/licensed asset id here
	minDistance = 12,
	maxDistance = 650,
	distant = "Distant_Gunshot_Heavy",
	fallback = {
		L(ROCKET, 0.7, 1.7, { duration = 0.45 }),
		L(COLLIDE, 0.85, 0.62),
		L(SNAP, 0.5, 0.8),
	},
})
def("SMG", {
	id = "", -- paste uploaded/licensed asset id here
	minDistance = 10,
	maxDistance = 450,
	maxVoices = 10,
	pitchVar = 0.05,
	distant = "Distant_Gunshot_Light",
	fallback = {
		L(ROCKET, 0.5, 2.1, { duration = 0.22 }),
		L(COLLIDE, 0.65, 0.85, { duration = 0.25 }),
		L(SNAP, 0.3, 1.05),
	},
})
def("LMG", {
	id = "", -- paste uploaded/licensed asset id here
	minDistance = 14,
	maxDistance = 700,
	maxVoices = 10,
	distant = "Distant_Gunshot_Heavy",
	heavy = true,
	fallback = {
		L(ROCKET, 0.65, 1.75, { duration = 0.3 }),
		L(COLLIDE, 0.8, 0.62, { duration = 0.3 }),
		L(SNAP, 0.35, 0.85),
	},
})
def("HMG", {
	id = "", -- paste uploaded/licensed asset id here
	minDistance = 16,
	maxDistance = 800,
	maxVoices = 12,
	distant = "Distant_Gunshot_Heavy",
	heavy = true,
	fallback = {
		L(ROCKET, 0.7, 1.6, { duration = 0.28 }),
		L(COLLIDE, 0.85, 0.5, { duration = 0.3 }),
		L(SNAP, 0.3, 0.75),
	},
})
def("Pistol", {
	id = "", -- paste uploaded/licensed asset id here
	minDistance = 8,
	maxDistance = 350,
	distant = "Distant_Gunshot_Light",
	fallback = {
		L(SNAP, 0.6, 0.8),
		L(COLLIDE, 0.7, 1),
		L(ROCKET, 0.35, 2.4, { duration = 0.18 }),
	},
})
def("Revolver", {
	id = "", -- paste uploaded/licensed asset id here
	minDistance = 9,
	maxDistance = 400,
	distant = "Distant_Gunshot_Light",
	fallback = {
		L(SNAP, 0.6, 0.65),
		L(COLLIDE, 0.8, 0.8),
		L(ROCKET, 0.45, 2, { duration = 0.3 }),
	},
})
def("Shotgun", {
	id = "", -- paste uploaded/licensed asset id here
	minDistance = 12,
	maxDistance = 550,
	distant = "Distant_Gunshot_Heavy",
	heavy = true,
	fallback = {
		L(ROCKET, 0.85, 1.2, { duration = 0.55 }),
		L(COLLIDE, 1, 0.45),
		L(SNAP, 0.5, 0.6),
	},
})
def("Sniper", {
	id = "", -- paste uploaded/licensed asset id here
	minDistance = 16,
	maxDistance = 900,
	distant = "Distant_Gunshot_Heavy",
	heavy = true,
	fallback = {
		L(ROCKET, 0.9, 1.35, { duration = 0.8 }),
		L(COLLIDE, 1, 0.45),
		L(SNAP, 0.6, 0.55),
		L(ROCKET, 0.25, 0.75, { delay = 0.22, duration = 1 }), -- valley echo
	},
})
def("Launcher", {
	id = "", -- paste uploaded/licensed asset id here
	minDistance = 14,
	maxDistance = 600,
	distant = "Distant_Gunshot_Heavy",
	heavy = true,
	fallback = { L(ROCKET, 1, 1), L(SLASH, 0.4, 0.5) },
})
def("Grenade_Throw", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.6,
	maxDistance = 120,
	fallback = { L(SLASH, 0.7, 0.75), L(CLICK, 0.4, 0.7) },
})
def("Distant_Gunshot_Light", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.9,
	minDistance = 60,
	maxDistance = 1800,
	maxVoices = 8,
	pitchVar = 0.08,
	fallback = { L(ROCKET, 0.6, 1.2, { duration = 0.45 }), L(COLLIDE, 0.6, 0.45) },
})
def("Distant_Gunshot_Heavy", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 1,
	minDistance = 80,
	maxDistance = 2500,
	maxVoices = 8,
	pitchVar = 0.08,
	fallback = { L(ROCKET, 0.8, 0.85, { duration = 0.9 }), L(COLLIDE, 0.7, 0.35) },
})

---------------------------------------------------------------------------------------------------
-- Explosions & vehicles
---------------------------------------------------------------------------------------------------
def("Explosion_Small", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 1.2,
	minDistance = 30,
	maxDistance = 1500,
	maxVoices = 6,
	pitchVar = 0.08,
	fallback = {
		L(ROCKET, 1, 0.5),
		L(COLLIDE, 1, 0.35),
		L(SNAP, 0.5, 0.4),
		L(FALLING, 0.25, 0.5, { delay = 0.05, duration = 1.4 }), -- debris/air rush tail
	},
})
def("Explosion_Large", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 1.4,
	minDistance = 50,
	maxDistance = 2500,
	maxVoices = 6,
	pitchVar = 0.06,
	fallback = {
		L(ROCKET, 1, 0.32),
		L(COLLIDE, 1, 0.25),
		L(ROCKET, 0.6, 0.5, { delay = 0.06 }),
		L(FALLING, 0.35, 0.35, { delay = 0.05, duration = 2.2 }),
	},
})
def("Smoke_Hiss", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.5,
	maxDistance = 150,
	fallback = { L(CLICK, 0.4, 0.5), L(FALLING, 0.5, 1.6, { duration = 2.5 }) },
})
def("Tank_Cannon", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 1.5,
	minDistance = 40,
	maxDistance = 2500,
	maxVoices = 4,
	distant = "Artillery_Distant",
	heavy = true,
	fallback = { L(ROCKET, 1, 0.55), L(COLLIDE, 1, 0.3), L(SNAP, 0.6, 0.45) },
})
def("Tank_Engine", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.8,
	minDistance = 20,
	maxDistance = 450,
	maxVoices = 12,
	looped = true,
	pitchVar = 0,
	fallback = {
		L(STEPS, 0.9, 0.3, { looped = true }),
		L(FALLING, 0.35, 0.35, { looped = true }),
	},
})
def("Jeep_Engine", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.6,
	minDistance = 12,
	maxDistance = 300,
	maxVoices = 12,
	looped = true,
	pitchVar = 0,
	fallback = {
		L(STEPS, 0.7, 0.6, { looped = true }),
		L(FALLING, 0.2, 0.6, { looped = true }),
	},
})

---------------------------------------------------------------------------------------------------
-- Weapon handling
---------------------------------------------------------------------------------------------------
def("Reload_Mag", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.6,
	maxDistance = 60,
	fallback = { L(CLICK, 0.8, 0.75), L(BUTTON, 0.7, 0.6, { delay = 0.35 }), L(CLICK, 0.6, 1, { delay = 0.6 }) },
})
def("Reload_Clip", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.6,
	maxDistance = 60,
	fallback = { L(CLICK, 0.7, 1.1), L(SNAP, 0.5, 1.3, { delay = 0.2 }), L(BUTTON, 0.5, 0.7, { delay = 0.45 }) },
})
def("Reload_Shell", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.6,
	maxDistance = 60,
	fallback = { L(BUTTON, 0.7, 0.8), L(CLICK, 0.5, 0.9, { delay = 0.08 }) },
})
def("Bolt_Cycle", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.6,
	maxDistance = 60,
	fallback = { L(CLICK, 0.8, 0.7), L(BUTTON, 0.6, 0.5, { delay = 0.14 }) },
})
def("Dry_Fire", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.45,
	maxDistance = 30,
	fallback = { L(BUTTON, 0.6, 1.4) },
})
def("Melee_Swing", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.6,
	maxDistance = 60,
	fallback = { L(SLASH, 0.8, 0.9) },
})
def("Melee_Hit", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.8,
	maxDistance = 80,
	fallback = { L(COLLIDE, 0.9, 0.8), L(SNAP, 0.5, 0.7) },
})

---------------------------------------------------------------------------------------------------
-- Bullets
---------------------------------------------------------------------------------------------------
def("Bullet_Whiz", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.7,
	minDistance = 2,
	maxDistance = 40,
	maxVoices = 6,
	pitchVar = 0.15,
	fallback = { L(SLASH, 0.7, 1.7, { duration = 0.3 }), L(SNAP, 0.45, 1.8) },
})
def("Bullet_Impact", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.45,
	minDistance = 4,
	maxDistance = 90,
	maxVoices = 8,
	pitchVar = 0.15,
	fallback = { L(COLLIDE, 0.6, 1.8, { duration = 0.25 }) },
})
def("Ricochet", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.5,
	minDistance = 4,
	maxDistance = 120,
	maxVoices = 4,
	pitchVar = 0.2,
	fallback = { L(SLASH, 0.6, 2.3, { duration = 0.35 }), L(PING, 0.12, 2.6) },
})

---------------------------------------------------------------------------------------------------
-- Feedback / UI (2D)
---------------------------------------------------------------------------------------------------
def("Hitmarker", { id = "", volume = 0.5, pitchVar = 0.02, maxVoices = 4, fallback = { L(BUTTON, 0.8, 1.8) } })
def("Kill_Confirm", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.55,
	pitchVar = 0,
	maxVoices = 2,
	fallback = { L(PING, 0.6, 1), L(BUTTON, 0.5, 0.9) },
})
def("Headshot", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.55,
	pitchVar = 0,
	maxVoices = 2,
	fallback = { L(PING, 0.5, 1.45), L(SNAP, 0.5, 1.5) },
})
def("UI_Click", { id = "", volume = 0.5, pitchVar = 0, maxVoices = 3, fallback = { L(BUTTON, 1, 1) } })
def("UI_Hover", { id = "", volume = 0.2, pitchVar = 0, maxVoices = 3, fallback = { L(CLICK, 0.6, 1.5) } })
def("Capture_Tick", { id = "", volume = 0.3, pitchVar = 0, maxVoices = 2, fallback = { L(PING, 0.5, 0.8) } })
def("Objective_Captured", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.6,
	pitchVar = 0,
	maxVoices = 2,
	fallback = { L(PING, 0.7, 0.9), L(PING, 0.7, 1.2, { delay = 0.14 }) },
})
def("Objective_Lost", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.6,
	pitchVar = 0,
	maxVoices = 2,
	fallback = { L(PING, 0.7, 0.75), L(PING, 0.7, 0.55, { delay = 0.16 }) },
})
def("Spawn_Whistle", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.45,
	pitchVar = 0,
	maxVoices = 1,
	fallback = { L(PING, 0.6, 1.9), L(PING, 0.6, 1.9, { delay = 0.18 }) },
})

---------------------------------------------------------------------------------------------------
-- Ambience
---------------------------------------------------------------------------------------------------
def("Ambient_Wind", {
	id = "", -- paste uploaded/licensed asset id here (seamless loop)
	volume = 0.22,
	looped = true,
	pitchVar = 0,
	maxVoices = 1,
	fallback = { L(FALLING, 1, 0.45, { looped = true }), L(FALLING, 0.5, 0.3, { looped = true }) },
})
def("Ambient_Rain", {
	id = "", -- paste uploaded/licensed asset id here (seamless loop)
	volume = 0.25,
	looped = true,
	pitchVar = 0,
	maxVoices = 1,
	fallback = {
		L(WATER, 0.6, 1.9, { looped = true }),
		L(WATER, 0.5, 1.35, { looped = true, start = 0.1 }),
		L(STEPS, 0.15, 2.6, { looped = true }), -- patter
	},
})
def("Ambient_Birds", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 0.07,
	minDistance = 20,
	maxDistance = 300,
	pitchVar = 0.08,
	maxVoices = 3,
	fallback = { L(PING, 1, 2.6), L(PING, 0.8, 2.9, { delay = 0.09 }), L(PING, 0.6, 2.75, { delay = 0.2 }) },
})
def("Ambient_Battle", {
	id = "", -- paste uploaded/licensed asset id here (optional loop; if empty, SoundController synthesises bursts)
	volume = 0.3,
	minDistance = 80,
	maxDistance = 2500,
	pitchVar = 0.1,
	maxVoices = 4,
	fallback = { L(ROCKET, 0.5, 1.1, { duration = 0.4 }), L(COLLIDE, 0.4, 0.4) },
})
def("Thunder", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 1,
	pitchVar = 0.1,
	maxVoices = 2,
	fallback = {
		L(ROCKET, 0.9, 0.25),
		L(COLLIDE, 0.8, 0.2),
		L(FALLING, 0.6, 0.25, { delay = 0.1 }),
		L(ROCKET, 0.5, 0.2, { delay = 0.45 }),
	},
})
def("Artillery_Distant", {
	id = "", -- paste uploaded/licensed asset id here
	volume = 1,
	minDistance = 150,
	maxDistance = 4000,
	pitchVar = 0.1,
	maxVoices = 4,
	fallback = { L(ROCKET, 0.9, 0.35), L(COLLIDE, 0.8, 0.28), L(FALLING, 0.3, 0.3, { duration = 1.6 }) },
})

---------------------------------------------------------------------------------------------------
-- Footsteps (MovementController). Each plays a single trimmed step.
---------------------------------------------------------------------------------------------------
local function footstep(key: string, layers: { Layer }, volume: number?)
	def(key, {
		id = "", -- paste uploaded/licensed asset id here
		volume = volume or 0.35,
		minDistance = 5,
		maxDistance = 70,
		maxVoices = 10,
		pitchVar = 0.1,
		fallback = layers,
	})
end
footstep("Footstep_Default", { L(STEPS, 1, 1, { duration = 0.25 }) })
footstep("Footstep_Grass", { L(STEPS, 0.8, 0.85, { duration = 0.25 }) }, 0.3)
footstep("Footstep_Concrete", { L(STEPS, 1, 1.1, { duration = 0.22 }), L(CLICK, 0.08, 0.6) })
footstep("Footstep_Wood", { L(STEPS, 1, 0.8, { duration = 0.25 }), L(COLLIDE, 0.12, 1.6) })
footstep("Footstep_Snow", { L(STEPS, 0.8, 0.65, { duration = 0.3 }), L(SLASH, 0.05, 0.5, { duration = 0.2 }) }, 0.3)
footstep("Footstep_Mud", { L(STEPS, 0.8, 0.6, { duration = 0.3 }), L(WATER, 0.12, 2, { duration = 0.25 }) })
footstep("Footstep_Sand", { L(STEPS, 0.8, 0.75, { duration = 0.28 }) }, 0.3)
footstep("Footstep_Metal", { L(STEPS, 1, 1.2, { duration = 0.22 }), L(CLICK, 0.2, 0.55), L(PING, 0.03, 0.5) })
footstep("Footstep_Jump", { L(JUMP, 0.8, 1) })
footstep("Footstep_Land", { L(STEPS, 1, 0.7, { duration = 0.3 }), L(COLLIDE, 0.15, 0.8) })

---------------------------------------------------------------------------------------------------
-- Music stingers (Music group). Silent until real assets are provided: beeps make poor music.
---------------------------------------------------------------------------------------------------
for _, key in { "Music_RoundStart", "Music_Victory", "Music_Defeat" } do
	def(key, {
		id = "", -- paste uploaded/licensed asset id here
		volume = 0.6,
		pitchVar = 0,
		maxVoices = 1,
		group = "Music",
		fallback = {},
	})
end

local Module = {
	byId = Sounds,
	-- Families considered "heavy" for distance falloff/delay purposes.
	SPEED_OF_SOUND = 1100, -- studs / second (approx. 343 m/s at 0.28 m per stud, rounded for feel)
}

function Module.get(key: string): SoundDef?
	return Sounds[key]
end

-- Every distinct content id referenced (for ContentProvider preloading).
function Module.allContent(): { string }
	local seen: { [string]: boolean } = {}
	local out = {}
	for _, d in Sounds do
		if d.id ~= "" and not seen[d.id] then
			seen[d.id] = true
			table.insert(out, d.id)
		end
		for _, layer in d.fallback do
			if not seen[layer.sound] then
				seen[layer.sound] = true
				table.insert(out, layer.sound)
			end
		end
	end
	return out
end

return Module
