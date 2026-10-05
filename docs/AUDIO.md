# Audio guide (Sound & Atmosphere team)

All game audio goes through `SoundController` (client), and every sound key is defined in
`src/shared/Config/Sounds.luau`.

## Adding a real sound (one-line change)

Each key has an `id` slot that starts out as `""`:

```lua
def("SMG", {
	id = "", -- paste uploaded/licensed asset id here
	...
```

Paste the uploaded or licensed asset id, for example `id = "rbxassetid://1234567890"`. Once `id` is set:

* The asset plays as a single sound, using the def's `volume`, `pitch`, `pitchVar` (random variation),
  roll-off distances, `maxVoices` and the optional `duration` cut.
* The `fallback` layers are ignored.

Nothing else changes. Callers keep using the same key.

Only upload audio you own or have a licence for. Do **not** invent asset ids.

## Fallbacks (until real assets exist)

Fallbacks only use sounds that ship with the Roblox client (`rbxasset://sounds/...`):
`Rocket shot.wav`, `collide.wav`, `swordslash.wav`, `electronicpingshort.wav`, `snap.wav`, `button.wav`,
`clickfast.wav`, `action_footsteps_plastic.mp3`, `action_jump.mp3`, `action_falling.mp3`, `impact_water.mp3`.

Several layers are stacked to approximate each sound. Each layer can set `volume`, `pitch`, `delay`,
`start` and `duration`. Some examples:

| Sound | Recipe |
|---|---|
| Rifle shot | `Rocket shot` at pitch 1.55, cut to 0.55 s, plus `collide` at 0.55 (body), plus `snap` at 0.7 (crack) |
| SMG | same recipe but pitched higher and cut shorter (0.22 s) so fast fire does not smear |
| Explosion | `Rocket shot` at 0.3–0.5, plus `collide` at 0.25–0.35, plus an `action_falling` air-rush tail |
| Thunder / artillery | very low-pitched `Rocket shot` and `collide` layers, plus a delayed second roll |
| Wind / rain beds | looped `action_falling` / `impact_water` at different pitches |

These are placeholders and should be replaced with real assets.

## Runtime behaviour

* **SoundGroups:** `SoundService.Master`, `Effects` and `Music` are siblings. SettingsController
  pre-multiplies Effects and Music by Master. Sounds go to `Effects` or `Music` (set by the def's `group`).
* **Pooling:** there are 56 3D voices (an Attachment in Terrain with a Sound and an EQ) and 20 2D voices.
  * When a key reaches its `maxVoices` limit, its oldest voice is reused.
  * At most 28 new voices start per frame.
  * Sounds beyond their `maxDistance` are skipped.
* **Weapon shots** (`PlayWeaponShot`):
  * The local player's own shots play in 2D.
  * Remote shots play the near layers in 3D. These get a progressively stronger low-pass with distance.
  * Shots further than 110 studs also play the def's `distant` key (`Distant_Gunshot_Light` / `_Heavy`).
  * Beyond 150 studs, every layer is delayed by `distance / 1100` (the speed of sound, in studs per second).
* **Bullet whiz:** when an enemy `Combat_ShotFX` segment passes within 9 studs of the camera.
* **Reverb:** `SoundService.AmbientReverb` uses the map's outdoor reverb (`LightingPresets.MapAmbience` or the
  preset's `reverb`). When two roof raycasts hit, it switches to the indoor reverb.
* **Ambience:**
  * Wind and rain beds follow the current weather and are muffled indoors.
  * Birds chirp on calm maps in clear weather, and stop for 15 s after any gunfire or explosion.
  * During a round, procedural distant gunfire bursts play. If `Ambient_Battle` gets a real looping asset,
    it plays as a loop instead.
* **Thunder** (from `FX_Lightning`) and **artillery rumble** (from `FX_DistantArtillery`) are triggered by
  AtmosphereController.

## Key list

* **Weapons:** `Rifle_Bolt`, `Rifle_Semi`, `SMG`, `LMG`, `HMG`, `Pistol`, `Revolver`, `Shotgun`, `Sniper`,
  `Launcher`, `Grenade_Throw`, `Distant_Gunshot_Light`, `Distant_Gunshot_Heavy`
* **Explosives and vehicles:** `Explosion_Small`, `Explosion_Large`, `Smoke_Hiss`, `Tank_Cannon`,
  `Tank_Engine`, `Jeep_Engine` (the engines are loops: use `PlayLoop`)
* **Handling:** `Reload_Mag`, `Reload_Clip`, `Reload_Shell`, `Bolt_Cycle`, `Dry_Fire`, `Melee_Swing`, `Melee_Hit`
* **Bullets:** `Bullet_Whiz`, `Bullet_Impact`, `Ricochet`
* **UI and feedback:** `Hitmarker`, `Kill_Confirm`, `Headshot`, `UI_Click`, `UI_Hover`, `Capture_Tick`,
  `Objective_Captured`, `Objective_Lost`, `Spawn_Whistle`
* **Ambience:** `Ambient_Wind`, `Ambient_Rain`, `Ambient_Birds`, `Ambient_Battle`, `Thunder`, `Artillery_Distant`
* **Footsteps:** `Footstep_Default`, `Footstep_Grass`, `Footstep_Concrete`, `Footstep_Wood`, `Footstep_Snow`,
  `Footstep_Mud`, `Footstep_Sand`, `Footstep_Metal`, `Footstep_Jump`, `Footstep_Land`
* **Music** (silent until an asset is set): `Music_RoundStart`, `Music_Victory`, `Music_Defeat`
