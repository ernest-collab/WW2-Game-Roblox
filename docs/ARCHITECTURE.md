# WW2 Frontlines — Architecture & Cross-Team Contracts

This document is the **source of truth** shared by every developer (human or AI agent).
If you need something from another subsystem, use the API/event listed here. If what you need
is missing, implement it in **your own** files and note it under "Contract additions" at the
bottom of this doc (append-only, one line per addition).

## 1. Project layout (Rojo)

```
default.project.json
src/shared  -> ReplicatedStorage.Shared          (ModuleScripts used by server + client)
  Config/      game data: Constants, Factions, Classes, GameModes, Maps, Keybinds,
               Weapons, Vehicles, Sounds, LightingPresets, Progression
  Util/        Signal, Trove, Bus, Net (+ any pure helpers)
  GameState    replicated match state accessor
  WeaponModels/ procedural weapon model builder (Animation/Models team)
  VehicleModels/ procedural vehicle model builder (Vehicle team)
src/server  -> ServerScriptService.Server        (init.server.luau = bootstrap Script)
  Services/    one ModuleScript per service, auto-loaded (Init then Start)
  Maps/        MapKit/ (shared building primitives) + one builder module per map
src/client  -> StarterPlayer.StarterPlayerScripts.Client (init.client.luau = bootstrap)
  Controllers/ one ModuleScript per controller, auto-loaded (Init then Start)
  UI/          UI component modules (required by UI controllers, NOT auto-loaded)
```

All content is **procedural** (built from Parts, Terrain, ParticleEmitters, built-in
`rbxasset://` content and Roblox engine features) because this repo has no binary assets.
Anything that would benefit from real uploaded assets (meshes, animations, audio) must be
configurable by ID in a Config file and degrade gracefully when the ID is empty.

## 2. Conventions

* Luau, `.luau` extension, tabs, StyLua formatted (`FIX=1 scripts/check.sh`).
* **Quality gate:** `scripts/check.sh` must report `ALL CHECKS PASSED` (StyLua, luau-lsp type check
  against Roblox API definitions, Rojo build). Never leave type errors.
* Services/controllers are tables with optional `:Init()` and `:Start()`.
  **Never require a sibling service/controller at module top level** — require inside
  `Init`/`Start`/functions (circular requires throw in Roblox). Config/Util/Shared modules may be
  required at top level anywhere.
* Server is authoritative for: damage, health, ammo counts (server tracks reserve ammo), score,
  captures, vehicles health, spawning, progression. Clients predict visuals only.
* Validate every remote payload on the server (types, ranges, distance, rate limits via
  `Net.rateLimit`). Never trust client-supplied damage.
* Clean up connections with `Trove`. No per-frame `Instance.new` in hot paths; pool effects.
* Use `task.*` APIs, never `wait/spawn/delay`. No `while true do wait() end` loops without exit.
* Strings for sides are exactly `"Allies"` and `"Axis"`. Roblox `Teams` named `Allies` / `Axis`.

## 3. Ownership (who writes what)

| Team | Owns |
|---|---|
| Lead | `default.project.json`, bootstraps, `Util/*`, `GameState`, `Config/{Constants,Factions,Classes,GameModes,Maps,Keybinds}`, this doc |
| Combat | `Config/Weapons`, `Services/CombatService`, `Services/BallisticsService`(opt), `Controllers/WeaponController`, `Controllers/ProjectileController`(opt), shared `Util/Ballistics`(opt) |
| Vehicle | `Config/Vehicles`, `VehicleModels/*`, `Services/VehicleService`, `Controllers/VehicleController` |
| Map | `Maps/MapKit/*`, `Maps/<MapId>`, `Services/MapService`, `Services/DestructionService` |
| Gameplay | `Config/Progression`, `Services/{RoundService,TeamService,SpawnService,ObjectiveService,ScoreService,ProgressionService,GadgetService,SquadService}`, `Controllers/GadgetController` |
| UI | `Controllers/{UIController,SettingsController}`, everything in `src/client/UI/` |
| Animation/Models | `WeaponModels/*`, `Services/{OutfitService,RagdollService,CharacterAnimService}`, `Controllers/{ViewmodelController,CameraController,MovementController,CharacterAnimController}` |
| Sound/Atmosphere | `Config/{Sounds,LightingPresets}`, `Services/AtmosphereService`, `Controllers/{EffectsController,SoundController,AtmosphereController}` |
| Monetization | `Config/Monetization`, shared `Cosmetics`, `Services/MonetizationService`, `UI/{Shop,LoadoutPresets}`, `docs/MONETIZATION.md` (sole owner of `MarketplaceService.ProcessReceipt`) |

## 4. Replicated state

### GameState (ReplicatedStorage.GameState attributes) — see `src/shared/GameState.luau`
Written by Gameplay (RoundService/ObjectiveService), MapService writes `MapInfoJson`.

### Player attributes (written by server, read by everyone)
| Attribute | Type | Writer |
|---|---|---|
| `Side` | "Allies"/"Axis"/"" | TeamService |
| `Faction` | Factions id | TeamService |
| `Class` | Classes id | SpawnService |
| `Squad` | number (0 = none) | SquadService |
| `SquadLeader` | bool | SquadService |
| `Alive` | bool | SpawnService |
| `Kills`, `Deaths`, `Assists`, `Score`, `Captures` | number | ScoreService |
| `Level`, `XP` | number | ProgressionService |
| `Loadout` | JSON string `{primary,secondary,gadget1,gadget2}` | SpawnService |
| `EquippedWeapon` | Weapons id | CombatService |
| `VehicleUid` | string ("" when on foot) | VehicleService |
| `Spotted` | number (os.clock-style server time until which the player is spotted; compare with `workspace:GetServerTimeNow()`) | GadgetService |

### Character attributes
| Attribute | Type | Writer |
|---|---|---|
| `AimPitch` | number (radians) | CharacterAnimService (from client unreliable remote) |
| `Stance` | "Stand"/"Crouch"/"Prone"/"Sprint" | CharacterAnimService (from client) |
| `SpawnProtected` | bool | SpawnService |

### Vehicle model attributes (Model tagged `Vehicle`)
`VehicleId` (Vehicles config id), `Uid` (string), `Side`, `Health`, `MaxHealth`, `Destroyed` (bool),
`Driver` (UserId or 0), `Faction`.

### Objectives
`ReplicatedStorage.GameState.Objectives.<id>` folders, attributes documented in GameState.luau.

## 5. Remotes (`Net.event(name)` etc.). Payloads are tables unless noted.

Client → Server
| Name | Payload | Owner (server handler) |
|---|---|---|
| `Team_Request` | `{side: "Allies"|"Axis"|"Auto"}` | TeamService |
| `Spawn_Request` | `{classId, loadout={primary,secondary,gadget1,gadget2}, spawnId}` (`spawnId` = "HQ", an objective id, or "Squad") | SpawnService |
| `Combat_Equip` | `{slot: "primary"|"secondary"|"gadget1"|"gadget2"|"melee"}` | CombatService |
| `Combat_Fire` | `{weaponId, origin: Vector3, shots: {{dir: Vector3, hit: Instance?, pos: Vector3?, normal: Vector3?}}, t: number}` | CombatService |
| `Combat_Reload` | `{weaponId}` | CombatService |
| `Combat_Throw` | `{weaponId, origin, velocity: Vector3}` (grenades/explosives/AT rockets) | CombatService |
| `Combat_Melee` | `{target: Model}` | CombatService |
| `Gadget_Use` | `{gadget: string, target: Instance?, position: Vector3?}` | GadgetService |
| `Vehicle_Request` | `{action:"enter"|"exit"|"switchSeat", uid, seat?}` | VehicleService |
| `Vehicle_Fire` | `{uid, weapon:"main"|"coax"|"hullMG", aim: Vector3}` | VehicleService |
| `Anim_State` (unreliable) | `{pitch: number, stance: string}` (≤ 15 Hz) | CharacterAnimService |
| `Settings_Save` | settings table | ProgressionService |

Server → Client
| Name | Payload | Consumers |
|---|---|---|
| `Combat_Kill` (all) | `{killer: Player?, victim: Player, weaponId, headshot: bool, killerSide, victimSide, distance, vehicleId?}` | UI killfeed |
| `Combat_HitConfirm` | `{damage, headshot, killed, target: "player"|"vehicle"}` | UI hitmarker, Sound |
| `Combat_Damaged` | `{amount, fromPosition: Vector3?, weaponId}` | UI damage indicator, CameraController shake |
| `Combat_ShotFX` (unreliable, all but shooter) | `{shooter: Player, weaponId, origin, hits: {{pos, normal, material: string}}}` | WeaponController → Effects/Sound |
| `Combat_Ammo` | `{weaponId, mag, reserve}` (authoritative correction) | WeaponController |
| `FX_Explosion` (all) | `{position, radius, kind: "grenade"|"shell"|"rocket"|"satchel"|"vehicle"}` | EffectsController, SoundController, CameraController |
| `Player_Died` | `{killer: Player?, weaponId?, respawnTime}` | UI deploy screen |
| `Spawn_Result` | `{ok: bool, error: string?}` | UI |
| `Score_Event` | `{reason: string, points: number}` e.g. "Enemy Killed", "Objective Captured", "Revive", "Resupply", "Repair", "Spot Assist", "Headshot" | UI score popups |
| `Progression_Updated` | ProgressionData | UI |
| `Round_Ended` (all) | `{winner, mvp: {name, score}?, topPlayers: {{name, side, score, kills, deaths}}}` | UI |
| `Vehicle_State` | `{uid, seat, inVehicle: bool}` | VehicleController, UI |
| `Notify` | `{text, kind: "info"|"warning"|"objective", duration?}` | UI toast |

RemoteFunctions
| Name | Returns | Owner |
|---|---|---|
| `Progression_Get` | ProgressionData = `{level, xp, xpToNext, unlocked: {[weaponId]: true}, weaponKills: {[weaponId]: number}, settings: table}` | ProgressionService |
| `Spawn_GetOptions` | `{ {id, name, position: Vector3, kind: "HQ"|"Objective"|"Squad", available: bool} }` | SpawnService |

## 6. Bus events (in-process, `Bus.fire/connect`)

Server bus
| Event | Args | Fired by |
|---|---|---|
| `PlayerKilled` | `victim: Player, killer: Player?, weaponId: string, headshot: boolean` | CombatService |
| `PlayerDamaged` | `victim: Player, attacker: Player?, amount: number, weaponId: string` | CombatService |
| `PlayerSpawned` | `player: Player, character: Model, classId: string` | SpawnService |
| `ObjectiveCaptured` | `objectiveId, side, capturers: {Player}` | ObjectiveService |
| `RoundStarted` | `modeId, mapId` | RoundService |
| `RoundEnded` | `winner: string` | RoundService |
| `MapLoaded` | `mapInfo: MapInfo (server form)` | MapService |
| `MapUnloading` | — | MapService |
| `Explosion` | `position: Vector3, radius: number, power: number, attacker: Player?` | CombatService, VehicleService |
| `VehicleDestroyed` | `vehicle: Model, killer: Player?` | VehicleService |
| `ScoreAwarded` | `player, reason, points` | ScoreService |

Client bus
| Event | Args | Fired by |
|---|---|---|
| `WeaponEquipped` | `weaponId: string, slot: string` | WeaponController |
| `WeaponUnequipped` | — | WeaponController |
| `AmmoChanged` | `weaponId, mag, reserve` | WeaponController |
| `AimChanged` | `isAiming: boolean` | WeaponController |
| `Fired` | `weaponId` | WeaponController |
| `ReloadStarted` | `weaponId, duration, empty: boolean` | WeaponController |
| `FireModeChanged` | `mode: "Auto"|"Semi"|"Bolt"|"Burst"` | WeaponController |
| `SpreadChanged` | `spreadDegrees: number` (for crosshair) | WeaponController |
| `StanceChanged` | `stance` | MovementController |
| `Deployed` | `character` | UIController (after Spawn_Result ok and character added) |
| `VehicleEntered` | `uid, vehicleId, seat` | VehicleController |
| `VehicleExited` | — | VehicleController |
| `SettingsChanged` | `settings: table` | SettingsController |
| `MenuOpened` / `MenuClosed` | `menuName` | UIController (input controllers ignore input while a menu is open) |

## 7. Public module APIs

### Server
```lua
CombatService.ApplyPlayerDamage(victim: Player, amount: number, attacker: Player?, weaponId: string,
    opts: {headshot: boolean?, fromPosition: Vector3?, ignoreFriendlyFire: boolean?}?) -> (boolean) -- returns killed
CombatService.Explode(position: Vector3, radius: number, maxDamage: number, attacker: Player?, weaponId: string,
    opts: {vehicleDamage: number?, kind: string?}?) -- damages players (LOS-checked) + vehicles, fires FX_Explosion & Bus "Explosion"
CombatService.GiveLoadout(player: Player, loadout: {primary, secondary, gadget1, gadget2}) -- (re)initialises ammo
CombatService.Resupply(player: Player, fraction: number) -> boolean -- refill ammo, returns true if anything refilled
CombatService.Heal(player: Player, amount: number, healer: Player?) -> number -- hp actually healed

VehicleService.ApplyDamage(vehicle: Model, amount: number, attacker: Player?, weaponId: string,
    hitPosition: Vector3?, opts: {penetration: number?, explosive: boolean?}?)
VehicleService.Repair(vehicle: Model, amount: number, repairer: Player?) -> number
VehicleService.SpawnTeamVehicles(mapInfo) / VehicleService.ClearAll()
VehicleService.GetVehicleOf(player) -> Model?

MapService.LoadMap(mapId: string) -> MapInfo   -- builds map, writes GameState.MapInfoJson, fires Bus MapLoaded
MapService.UnloadMap()
MapService.GetMapInfo() -> MapInfo?

ScoreService.Award(player: Player, reason: string, points: number) -- also fires Score_Event + XP
SpawnService.KillAndDespawnAll() / SpawnService.SetSpawningEnabled(bool)
OutfitService.Apply(character: Model, factionId: string, classId: string)
AtmosphereService.ApplyPreset(presetId: string, weather: string) -- usually driven by GameState attributes
```

### Shared
```lua
WeaponModels.Build(weaponId: string) -> Model
  -- PrimaryPart "Handle"; Attachments on Handle: "Muzzle", "Grip" (right hand), "Support" (left hand),
  -- "Sight" (eye position for ADS, looking down -Z... i.e. Handle LookVector is the barrel direction),
  -- "Eject" (shell ejection). All parts Anchored=false, CanCollide=false, Massless=true, welded to Handle.
VehicleModels.Build(vehicleId: string) -> Model   -- see Vehicle team docs
```

### Client
```lua
ViewmodelController.Equip(weaponId) / .Unequip()
ViewmodelController.SetAiming(aiming: boolean)
ViewmodelController.PlayFire(kick: number)          -- visual recoil kick (0..1 typical)
ViewmodelController.PlayReload(duration: number, empty: boolean)
ViewmodelController.PlayEquip(duration) / .PlayThrow() / .PlayMelee() / .PlayBolt(duration)
ViewmodelController.GetMuzzleWorldCFrame() -> CFrame?
ViewmodelController.GetAimAlpha() -> number          -- 0 hip .. 1 fully aimed
CameraController.AddRecoil(pitchDeg: number, yawDeg: number)
CameraController.Shake(magnitude: number, duration: number)
CameraController.SetFovOffset(key: string, delta: number)   -- e.g. ADS zoom, sprint
CameraController.SetFirstPerson(enabled: boolean)
MovementController.GetStance() -> string / .IsSprinting() -> boolean / .SetSprintBlocked(bool)
EffectsController.MuzzleFlash(cframe: CFrame, scale: number?)
EffectsController.Tracer(from: Vector3, to: Vector3, color: Color3?)
EffectsController.Impact(position: Vector3, normal: Vector3, material: Enum.Material | string)
EffectsController.Explosion(position: Vector3, radius: number, kind: string)
EffectsController.Smoke(position: Vector3, radius: number, duration: number)
EffectsController.ShellEject(cframe: CFrame, kind: string?)
SoundController.PlayAt(key: string, position: Vector3, opts: {volume: number?, pitch: number?}?)
SoundController.Play2D(key: string, opts?)
SoundController.PlayWeaponShot(weaponId: string, position: Vector3, isLocal: boolean)
SettingsController.Get(key: string) -> any   -- keys: "MouseSensitivity","AimSensitivity","FieldOfView",
  -- "MasterVolume","EffectsVolume","MusicVolume","GraphicsQuality"(1-3),"ShowFPS","CrosshairColor","Hitmarkers"
UIController.IsMenuOpen() -> boolean
```

## 8. Config schemas

### Weapons (`Config/Weapons.luau`, Combat team)
```lua
{
  id: string, name: string, category: string, -- see Classes.luau categories
  factions: {string}, unlockLevel: number, description: string,
  -- firearms
  damage: number, headshotMultiplier: number, limbMultiplier: number,
  damageFalloff: { {range: number, multiplier: number} }, -- ascending ranges
  rpm: number, fireModes: {"Auto"|"Semi"|"Bolt"|"Burst"},
  magazine: number, reserve: number, reloadTime: number, emptyReloadTime: number?,
  reloadType: "magazine"|"clip"|"single", -- single = shell-by-shell
  pellets: number?, -- shotguns
  hipSpread: number, adsSpread: number, moveSpreadMult: number, -- degrees
  recoil: { vertical: number, horizontal: number, recovery: number, firstShotMult: number }, -- degrees
  adsTime: number, adsZoom: number, -- FOV multiplier, e.g. 0.8; scoped snipers ~0.3 with scope=true
  scope: boolean?, bulletVelocity: number, -- studs/s (hitscan below ~0.05s travel is fine)
  range: number, -- max effective range (studs)
  equipTime: number, walkSpeedMult: number, penetration: number, -- 0..1 vs cover (optional use)
  suppression: number?, -- 0..1
  -- throwables / launchers
  fuse: number?, blastRadius: number?, blastDamage: number?, vehicleDamage: number?, throwSpeed: number?,
  -- presentation
  visual: { archetype: string, magazine: "box"|"drum"|"stick"|"side"|"top"|"internal"|"none",
            length: number?, woodColor: Color3?, metalColor: Color3?, scope: boolean?, bayonet: boolean? },
  sound: string, -- Sounds.luau key family, e.g. "Rifle_Bolt", "SMG", "LMG", "Pistol"
}
```
Archetypes (WeaponModels must support all): `BoltRifle`, `SemiRifle`, `AssaultRifle`, `SMG`,
`LMG`, `HMG`(bipod MG42-like), `Pistol`, `Revolver`, `Shotgun`, `SniperRifle`, `Bazooka`(tube),
`Panzerfaust`, `PIAT`, `StickGrenade`, `FragGrenade`, `SmokeGrenade`, `Satchel`, `Knife`,
`Medkit`, `AmmoBox`, `Wrench`, `Binoculars`.

### MapInfo (MapService ↔ map builders)
```lua
MapBuilder.Build(parent: Folder, mapDef) -> MapInfo
MapInfo = {
  id: string,
  bounds: { center: Vector3, size: Vector3 },
  hq: { Allies: {CFrame}, Axis: {CFrame} },                -- infantry spawn CFrames per side
  objectives: { {id: "A".."G", name: string, position: Vector3, radius: number, order: number,
                 initialOwner: "Allies"|"Axis"|"Neutral",
                 spawns: {CFrame} } },                       -- order = frontline position (1 = Allies end)
  vehicleSpawns: { Allies: { {cframe: CFrame, class: "Tank"|"Light"|"Transport"|"Jeep"|"AT"} }, Axis: {...} },
  minimap: { {kind: "building"|"road"|"water"|"trench"|"forest"|"field", cx, cz, sx, sz, rot} },
  outOfBounds: number?,                                     -- seconds before death outside bounds
}
```
`GameState.MapInfoJson` = `HttpService:JSONEncode` of the public subset:
`{id, bounds={cx,cy,cz,sx,sy,sz}, objectives={{id,name,x,y,z,radius,order}}, hq={Allies={x,z},Axis={x,z}}, minimap=...}`.

### Vehicles (`Config/Vehicles.luau`, Vehicle team)
`{id, name, class: "Tank"|"Light"|"Transport"|"Jeep"|"AT", factions, maxHealth, armor: {front, side, rear},
  speed, reverseSpeed, turnRate, turretTraverse, gunElevation: {min,max}, weapons: {...}, seats: {...},
  respawnTime, unlockLevel, description}`.

## 9. Contract additions
(append below: `- <team>: <what> — <where>`)
- Sound/Atmosphere: remotes `FX_Lightning` {position, intensity} and `FX_DistantArtillery` {position, count, spacing} (AtmosphereService → AtmosphereController); EffectsController also listens to optional `FX_Smoke` {position, radius?, duration?} and adds `EffectsController.TracerFor(weaponId, from, to, color?)` (1-in-3 for automatics) + `EffectsController.Fire(target: BasePart|Vector3, duration?, scale?) -> stop()`; `SoundController.PlayLoop(key, parent?, opts?) -> handle{SetVolume,SetPitch,SetLowpass,Stop,IsActive}` (vehicle engines), `.IsIndoors()`; PlayAt/Play2D opts also take `delay`, `lowpass` (0..1); extra Sounds keys `Footstep_Jump`,`Footstep_Land`,`Smoke_Hiss`,`Music_*` — src/client/Controllers/{EffectsController,SoundController}.luau, src/server/Services/AtmosphereService.luau
- Gameplay: Bus `PlayerDied(victim, killer?, weaponId)` for EVERY death incl. fall/out-of-bounds (weaponId "OutOfBounds"/"Environment" when no killer) + `PlayerSideChanged(player, side, oldSide)`; player attrs `Revivable` (server-time deadline, 0=no), `OutOfBounds` (server-time deadline, 0=inside), `XPToNext`; character attr `SpeedMultiplier`; `Gadget_Use.gadget` ∈ Medkit|AmmoBox|Repair|Binoculars|Spot (Repair sent ~4 Hz while held); client `GadgetController.Use(category)` / `.SetHolding(category, holding)`, client Bus `GadgetProgress(fraction?, label?)`; revive = ProximityPrompt tagged "RevivePrompt" (attr Side) on the body; `Score_Event.xpOnly` (round XP popups, not score); RoundService calls `VehicleService.SpawnTeamVehicles(mapInfo)` at round start / `ClearAll()` at round end and uses `MapService.GetAvailableMaps()` (ids or MapDefs); ScoreService computes assists itself (no PlayerAssist needed); APIs `RoundService.GetMapInfo/GetMode/AdjustTickets`, `SpawnService.Revive/GetOptions`, `ProgressionService.GetLevel/AddXP/RecordWeaponKill`, `TeamService.GetSide/GetPlayers`, `SquadService.GetSquadSpawn`, `ObjectiveService.GetOwnedCount/GetObjectiveSpawns` — src/server/Services/*, src/client/Controllers/GadgetController.luau
- Combat: Bus `PlayerKilled` 5th arg `assisters: {Player}` + Bus `PlayerAssist(assister, victim, killer?)`; `Combat_Kill.assist: Player?`; remote `FX_Smoke {position, radius, duration}` + server marker parts tagged "SmokeScreen" (attrs Radius, ExpiresAt) in workspace.SmokeScreens; projectiles in workspace.CombatProjectiles; `Combat_Throw.cook: number?` (seconds cooked); `Combat_Reload.cancel: true` cancels a reload; `ApplyPlayerDamage` opts also take `vehicleId`, `noHitConfirm` (sends Combat_HitConfirm by default); `Explode` opts also take `directVehicle`, `penetration`; `CombatService.GetEquipped/GetAmmo/Unequip/TimeSinceDamaged`; third-person weapon = character child Model "EquippedWeaponModel" (Motor6D "WeaponGrip" RightHand→Handle); firing cancels character `SpawnProtected`; CombatService removes the default "Health" script (it owns regen); client Bus `ScopeChanged(scoped, weaponId)`; `WeaponController.GetEquipped/IsAiming/IsReloading/GetSpread/GetAmmo/GetMoveSpeedMultiplier`; Weapons helpers `available(classId, slot, factionId, level?)`, `isAllowed`, `defaultLoadout(classId, factionId)`, `isFirearm/isLauncher/isThrown/isGadget`, `MELEE_ID`, extra fields `projectile, cookable, burstCount, pelletSpread, gravityScale, smokeRadius, smokeDuration, meleeRange, meleeCooldown` — src/shared/Config/Weapons.luau, src/shared/Util/Ballistics.luau, src/server/Services/CombatService.luau, src/client/Controllers/WeaponController.luau
- UI: SettingsController creates SoundGroups `Master`/`Effects`/`Music` directly under SoundService in its Init (Effects/Music volumes pre-multiplied by Master — parent your Sounds' SoundGroup to Effects or Music); extra settings keys `MinimapRotate` (bool), `LastClass`, `Loadouts` ({[classId]={primary,secondary,gadget1,gadget2}}, persisted flat as `LO_<classId>`="p|s|g1|g2"), `CrosshairColor` is a preset name (White|Green|Yellow|Cyan|Red), `GraphicsQuality` 1..3, `AimSensitivity` is an ADS multiplier, `MouseSensitivity` is applied to UserInputService.MouseDeltaSensitivity; `SettingsController.Set/GetAll/Save/ResetDefaults/Schema`; `UIController.OpenMenu/CloseMenu/ToggleMenu(name)` (Settings|BigMap|Loadout), `.ToggleScoreboard()`, `.Notify(text, kind?, duration?)`, `.GetProgression()`; menu names fired on MenuOpened/MenuClosed: Deploy|Intermission|RoundEnd|Settings|BigMap|Loadout; while any menu is open UIController forces MouseBehavior.Default each frame (RenderPriority.Last) — CameraController should also skip mouse-lock when `UIController.IsMenuOpen()`; UI ScreenGuis WW2_FX(2)/WW2_HUD(5)/WW2_Backdrop(9)/WW2_Menus(10)/WW2_Overlay(15) — Vehicle HUD should use DisplayOrder 4–6; minimap shape `rot` assumed in degrees (world yaw) — src/client/Controllers/{UIController,SettingsController}.luau, src/client/UI/*
- Animation/Models: extra APIs `CameraController.IsFirstPerson()/GetBaseFov()`, `ViewmodelController.PlayInspect()/IsVisible()/GetEquippedId()`, `MovementController.GetStamina()/IsSliding()/GetBaseStance()/SetStance(s)`, `RagdollService.Ragdoll(character)`, `WeaponModels.GetConfig(id)/Preload(ids)/GetArchetype(id)`; ViewmodelController sets FOV key "ADS" only when no WeaponController exists, hides while Bus ScopeChanged(true), treats PlayReload(duration<=0) as cancel, and auto-calls its own API from Bus WeaponEquipped/WeaponUnequipped/AimChanged/Fired/ReloadStarted when the API was not called within 0.1 s; CharacterAnimController drives the `WeaponGrip` Motor6D.Transform of CombatService's `EquippedWeaponModel`; weapon model attrs Hold/EyeRelief/MagOut/Action/RearZ/FrontZ + optional `visual.variant`; render order CameraController Camera±1, Viewmodel Camera+2; shared `WeaponModels/Spring` — src/shared/WeaponModels, src/client/Controllers
- Vehicle: remotes `Vehicle_Aim` (unreliable C→S `{uid, yaw, pitch}` hull-relative radians, ≤30 Hz; driver→turret, gunner→MG), `Vehicle_Weapon` (S→occupant `{uid, weapon, ammo?, ammoIndex?, mag, heat?, overheated?, reloading, readyAt: server time}`), `Vehicle_FX` (unreliable S→all `{kind:"fire"|"mg"|"impact"|"hit", uid, shooter?, ...}`); `Vehicle_Request.action` also `"ammo"` (`ammo`: index or "AP"/"HE", costs a reload); `Vehicle_State` adds `vehicleId`; `Combat_HitConfirm.result?` ("penetration"|"nonpen"|"ricochet") for tank shells; vehicle model attrs also `TurretYaw, GunPitch, MGYaw, MGPitch, Critical, Class, DisplayName`; seats carry attr `SeatId`; `ApplyDamage` returns applied damage and treats `opts.penetration <= 1` as "no armor penetration"; vehicle kills use weaponId = Vehicles id (look up `Vehicles.get(weaponId)` for killfeed names) and pass `vehicleId`; `VehicleService.Eject(player)`; shared `VehicleModels.Physics`, `VehicleModels.MuzzleCFrame/HullMGCFrame/GunAttachmentCFrame/JointCFrame`; `Vehicles.getSeat(def, seatId)`, `Vehicles.seatInstanceName(seatId)`, `Vehicles.DAMAGE`; collision group "VehicleRays"; vehicles live in workspace.Vehicles; ScreenGui "VehicleHUD" (DisplayOrder 6); Sounds keys used: Tank_Cannon, Tank_Engine, Jeep_Engine, HMG, LMG, Ricochet, Bullet_Impact, UI_Click — src/shared/Config/Vehicles.luau, src/shared/VehicleModels/*, src/server/Services/VehicleService.luau, src/client/Controllers/VehicleController/*
- Map: objective flag = `workspace.Map.Objectives.<id>` Model (attrs ObjectiveId, Radius) with direct child BasePart `Flag` (ObjectiveService recolours; `MapKit.Props.FlagPole`); minimap `rot` = yaw degrees (CFrame.Angles(0, math.rad(rot), 0)), sx/sz = local X/Z extents; `MapService.IsLoading()`; MapService OOB is a fallback only when SpawnService is absent; destructibles = parts/models tagged `Destructible` under workspace.Map with optional attr `Health` (runtime attr `CurrentHealth`), debris in workspace.Map.Debris, `DestructionService.BreakPart(part, origin?)`; Explosion `power` treated as max damage (grenade ~100, shell 200–400, satchel ~600; ≥150 carves terrain craters); HQ ammo crates tagged `ResupplyPoint`, HQ medical crate `MedicalPoint` — src/server/Maps/MapKit/*, src/server/Services/{MapService,DestructionService}.luau, docs/MAPKIT.md
- Monetization: remotes `Shop_GetState` (RF → ShopState), `Shop_Purchase {kind:"pass"|"product", key}`, `Shop_RequestUnlock {weaponId}`, `Shop_SetCosmetic {camo?, uniform?}`, `Shop_SavePreset {index, classId?, loadout?}`, `Shop_Updated` (S→C ShopState); player attrs `VIP`, `Supporter`, `XPMultiplier`, `XPBoostExpires` (os.time), `OwnedPasses` (JSON), `Camo`, `UniformVariant`, `CamoUnlocked`; weapon model attr `Camo` via `Cosmetics.applyCamo(model, camoId)` (CombatService/ViewmodelController), `Cosmetics.uniformColors(colors, variant)` (OutfitService); APIs `MonetizationService.GetXPMultiplier/HasPass/IsWeaponPurchased/GetPurchasedWeapons`, `ProgressionService.PushUpdate(player)`; ProgressionService.AddXP multiplies XP (never Score) and `Progression_Get().unlocked` includes purchased weapons; SpawnService accepts purchased weapons past the level check; UIController menu "Shop" (K key) + `Shop:SetHudVisible`; DeployScreen STORE + PRESETS buttons — src/shared/Config/Monetization.luau, src/shared/Cosmetics.luau, src/server/Services/MonetizationService.luau, src/client/UI/{Shop,LoadoutPresets}.luau
