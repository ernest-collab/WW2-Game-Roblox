# WW2 Frontlines — Performance budgets & profiling

Target: 40 players, 60 FPS desktop / 30+ FPS mid-range phones, low server heartbeat cost,
low per-client bandwidth. Numbers below are **budgets** (what new content must fit in) plus
**estimates** from static analysis; there is no Roblox runtime in CI, so verify them in Studio with
the checklist at the bottom.

## 1. Budgets

### Geometry
| Item | Budget | Current (estimate / enforced by) |
|---|---|---|
| Parts per map (`workspace.Map`) | ≤ 25 000 (warn) | MapService logs `[MapService] <map>: N parts (S shadow casters), E emitters, L lights` after every build and warns above budget |
| Shadow-casting parts per map | ≤ 40 % of parts | MapKit `ctx:Part` casts shadows only above 60 studs³; the post-build audit strips shadows from anything under 1 stud³ |
| Map flags | all `Anchored`, `CanTouch=false`; decorative non-collidable clutter `CanQuery=false` | MapKit defaults + MapService `auditMap` (also covers builders that bypass `ctx:Part`) |
| Parts per vehicle | ≤ 150 (tank), ≤ 90 (jeep/truck) | ~60–130 from Kit call sites; only Chassis is massive; detail parts < 0.5 studs³ cast no shadow (`VehicleModels/Kit`) |
| Vehicle streaming | `ModelStreamingMode = Atomic` | VehicleService (set on spawn) |
| Extra outfit parts per character | ≤ 25 | OutfitService (massless, no query/touch, shadows only above 0.5 studs) |
| Third-person weapon | ≤ 30 parts, no query/touch | WeaponModels Builder; shadows only above 0.6 studs |

### Particles / lights (client, per GraphicsQuality LOW / MED / HIGH)
| Source | Budget |
|---|---|
| Rain emitter rate (live ≈ rate × 0.7 s) | 260 / 600 / 1000 per s (+ near rain 0 / 120 / 220) |
| Rain splash raycasts | 60 / 150 / 270 per s |
| Effects particle multiplier | 0.4 / 0.7 / 1.0 |
| Impacts per frame | 6 / 10 / 16; explosions per frame: 3 |
| Bullet-hole decal pool | 20 / 40 / 64 |
| Smoke-grenade cloud rate | 5 / 8 / 11 × radius/22 |
| Fire rigs (pooled) | 6 total, flame rate 12 / 20 / 30 |
| PointLights | all `Shadows=false`; pooled (muzzle, explosion, fire, tank shells) |
| Default quality | LOW on touch-only devices, MEDIUM otherwise (saved setting wins) |

### Character animation (client)
| Distance from camera | Pose rate |
|---|---|
| < 60 studs, on screen | every frame |
| 60–150 studs | every 2nd frame |
| 150–450 studs | every 3rd frame |
| outside ~78° view cone (beyond 60 studs) | every 4th frame |
| > 450 studs | not posed |

### Network
| Remote | Direction | Rate | Payload |
|---|---|---|---|
| `Anim_State` (unreliable) | C→S | ≤ 15 Hz, only on change (pitch ε 0.025 rad) | ~40 B |
| `AimPitch` / `Stance` attrs | S→all | quantised, written only on change | — |
| `Vehicle_Aim` (unreliable) | C→S | ≤ 20 Hz, only on change | ~50 B |
| `TurretYaw/GunPitch/MGYaw/MGPitch` attrs | S→all | ≤ 15 Hz, deadband 0.002–0.004 rad | — |
| `Combat_Fire` | C→S | ≤ weapon RPM (server-capped at 30/s) | ≤ 9 shots |
| `Combat_ShotFX` (unreliable) | S→players within 1200 studs, not shooter | per shot | **≤ 6 hits** (pellets within 1.5 studs merged) → < ~500 B, well under the ~900 B unreliable limit |
| `Vehicle_FX` `mg` (unreliable) | S→players within 1200 studs, not shooter | per MG bullet (~10–20 Hz) | ~120 B |
| `Vehicle_FX` `fire` / `impact` | S→all | per tank shell | ~150 B |
| `FX_Explosion`, `Combat_Kill` | S→all | event | < 150 B |
| Objective folder attrs | S→all | 4 Hz, only on change | — |

Server: all periodic loops are ≤ 4 Hz except CombatService (projectiles, 1 raycast per live
projectile per frame; regen at its own tick) and VehicleService (turret slew + driven-vehicle
checks; parked vehicles are anchored and cost only a field compare).

## 2. Changes made in the optimisation pass

| Area | Change | Estimated impact |
|---|---|---|
| CharacterAnimController | Weapon model / grip joint / Grip & Support attachments / Hold & RearZ attrs cached per weapon model instead of 3 `FindFirstChild` + 2 attachment lookups + 2 `GetAttribute` per character per frame. Added 60–150 stud every-2nd-frame band and off-screen every-4th-frame band; LOD buckets staggered. MicroProfiler label `WW2CharacterAnim`. | 40 players: ~280 instance lookups/frame removed; posing work ≈ −45 % in a typical match (most players are > 60 studs or behind the camera) |
| VehicleController | `CollectionService:GetTagged` (fresh array every physics step) replaced by a set maintained from tag signals; turret/gun/MG `Motor6D.Transform` written only when the angle moved. Label `WW2VehicleAnimate`. | −1 table alloc/step; ~3 joint writes per parked vehicle per step removed (20+ vehicles on big maps) |
| VehicleController/FX | Tank shells get their own `RaycastParams` at fire time instead of rebuilding `FilterDescendantsInstances` (a table + engine copy) per shell per step. | small, removes per-step allocations |
| EffectsController | Fire rigs on static targets (anchored wrecks) no longer re-CFrame every frame; smoke veil `Enabled` only written on change. Label `WW2Effects`. | small |
| AtmosphereController | 7 weather emitters: `Rate`/`Enabled` written only on change (was 14 property writes/frame). | −14 reflection writes/frame |
| SoundController | Voice sweep no longer allocates a `{voices3D, voices2D}` table every frame. | −1 alloc/frame |
| CameraController | Modal button `Visible` written only on change. | trivial |
| MapRenderer / Minimap | Minimap viewport is a `CanvasGroup` (re-rasterised whenever a descendant changes). View offset snapped to whole pixels and rotations to 0.5°, written only on change; north arrow only on change. | Stationary/aiming player: CanvasGroup redraws drop from every frame to ~15 Hz (marker refresh); notable on phones |
| Compass | Strip position snapped to pixels; heading text and per-objective distance strings formatted/written only when the displayed integer changes; `seen` table reused. | −(1 + objectives) `string.format` + text relayouts per frame |
| CombatService | `Combat_ShotFX` hits capped at 6 and merged within 1.5 studs. | 9-pellet shotgun packet ~650–750 B → ≤ ~450 B |
| VehicleService | MG `Vehicle_FX` distance-culled (1200 studs) and not sent to the shooter, instead of `FireAllClients`. | Up to ~60 % fewer MG FX packets on large maps |
| VehicleModels/Kit | Parts < 0.5 studs³ don't cast shadows unless a builder asks. | Fewer shadow-map draws per vehicle |
| SettingsController | Default GraphicsQuality LOW on touch-only devices. | Phones start with 0.4× particles, rain 260/s |
| MapService | Post-build audit: anchors loose parts, `CanTouch=false` on all map parts, strips shadows < 1 stud³, logs counts vs budget. | Robustness for new maps; fewer touch-pairs in broadphase |

Already good before this pass (verified, no change needed): CombatService reuses `RaycastParams`
(world filter rebuilt only when the character list changes); ViewmodelController uses
`BulkMoveTo`; EffectsController pools everything with per-frame budgets; `Anim_State` and vehicle
aim attributes are throttled + quantised; parked vehicles are anchored; DestructionService caps
live debris (260) and destroys it after 25–30 s; all Player-keyed server tables are cleared on
`PlayerRemoving` (incl. `Net.rateLimit` buckets).

## 3. Known remaining costs (not changed)

* **Lighting `Technology = Future`** with `GlobalShadows`: the engine scales it down on low
  quality levels, but it is the most expensive mode. If phones struggle, try `ShadowMap` for
  mobile-heavy experiences (visual change → owner decision).
* **StreamingTargetRadius 1024**: generous for sniping sightlines; the engine lowers it on
  low-memory devices. Lower to ~768 if client memory is high on phones.
* **Minimap CanvasGroup**: still redraws at ~15 Hz while markers move. A Frame +
  `ClipsDescendants` version cannot clip rotated content; acceptable cost.
* **Per-player `FireClient` fan-out** for ShotFX/MG FX serialises the payload once per receiver.
  Roblox has no filtered broadcast; distance culling is the main lever.
* **Debris**: up to 260 unanchored server parts during big explosions (anchored after settling).
  Lower `MAX_LIVE_DEBRIS` if the server physics step spikes.

## 4. Studio profiling checklist (for the owner)

Test with **Test → Clients and Servers → 8+ players** and with the device emulator set to a
mid-range phone. Ideally also one real phone via the Roblox app.

1. **MicroProfiler** (Ctrl+F6, then Ctrl+P to pause a frame)
   * Client frame: look for the custom labels `WW2CharacterAnim`, `WW2VehicleAnimate`,
     `WW2Effects`, plus `RenderStepped`/`Heartbeat` script time. Budget: total script time
     < 4 ms desktop, < 8 ms phone.
   * `Render` → `Shadows`, `Particles` and `UI` (`CanvasGroup` → minimap) bars.
   * Server (Developer Console → MicroProfiler tab on server): heartbeat script time < 6 ms
     with 40 players.
2. **Developer Console (F9)**
   * *Network*: per-remote receive rate on a client during a firefight. Expect
     `Combat_ShotFX` < 15 KB/s, `Vehicle_FX` < 5 KB/s; total client receive < 60 KB/s.
     Check no "UnreliableRemoteEvent payload too large" warnings (shotgun spam test).
   * *Memory*: `PlaceMemory`, `Instances`, `GraphicsParticles`, `GraphicsTexture`. Play 3
     rounds back-to-back; Instances and LuaHeap must return to roughly the same value after each
     round (leak check).
   * *Server Stats / Physics*: contacts and `Physics Step` time after a satchel on a building.
   * *Log*: `[MapService] <map>: N parts ...` line per map — compare with the budget table.
3. **ScriptProfiler** (Developer Console → ScriptProfiler, 10 s capture, client and server):
   top functions should be `poseRig`, `render` (viewmodel), `animateVehicles`, `onFire`,
   `processShot`. Anything else above 5 % of script time is a regression.
4. **Stats overlay** (Shift+F5 / Shift+F2): FPS, draw calls, triangles. Phone targets:
   < 1500 draw calls, 30+ FPS on LOW.
5. **Settings sweep**: switch GraphicsQuality LOW/MED/HIGH in-game during rain + smoke grenades
   + burning wrecks; FPS should scale accordingly.
