# Development Log: how WW2 Frontlines was built

The game was built by a team of specialised AI agents, coordinated by a Lead agent. Each agent
owned a separate set of files and built against one shared contract (`docs/ARCHITECTURE.md`).
Later passes reviewed and fixed each other's work.

Nothing here has been run inside Roblox yet. Every result below comes from static checks
(`scripts/check.sh`: StyLua, luau-lsp type-checking against the Roblox API, and a Rojo build),
the contract cross-checker, the balance model, and a mock-Roblox harness running under the
Luau CLI. The first real playtest in Roblox Studio is the next milestone.

Size at the end of the build: **111 Luau modules, ~56,000 lines.**

| Area | Lines |
|---|---|
| Shared (configs, weapon/vehicle models, utilities) | ~12,000 |
| Server services | ~11,700 |
| Maps (MapKit + 7 maps) | ~12,500 |
| Client (controllers + UI) | ~20,100 |

## Phase 0: Foundation (Lead)
- Rojo project, toolchain (`rokit.toml`), formatting, type-check config, and the `scripts/check.sh` quality gate.
- Shared utilities: `Signal`, `Trove`, `Bus` (in-process events), `Net` (named remotes plus rate limiting), and `GameState` (replicated match state).
- Design data: 7 factions, 6 classes, 3 game modes, the 7-map registry, and keybinds.
- Server and client bootstraps (Init/Start lifecycle) and collision groups.
- `ARCHITECTURE.md`: file ownership, every remote, Bus event, attribute, public API and config schema.

## Phase 1: Specialist build (7 agents in parallel, then Monetization)

| Agent | Delivered |
|---|---|
| **Combat** | 145 weapons across all factions and categories. Server-authoritative shooting: hit validation, falloff, hit zones, penetration. Grenades, rockets, satchels, smoke, melee, health regen. Client weapon handling: recoil, spread, ADS, fire modes, reloads, mobile buttons. |
| **Vehicle** | 46 vehicles (a tank, light vehicle, jeep and transport per faction, plus AT guns). Procedural models. Raycast-suspension physics. Armor by facing (ricochet / non-penetration / penetration). Turrets, shells, MGs, crews, wrecks, respawns. Vehicle HUD and gunner sight. |
| **Map Design** | MapKit, a procedural terrain and building library. MapService, DestructionService (destructible walls, craters). Maps: Saint-Laurent (Normandy), Red October Ruins (Stalingrad), Prokhorovka Fields (Kursk). |
| **Gameplay** | Round state machine. Conquest, Frontline and TDM rules. Teams, squads with squad spawning, spawn points, capture logic, scoring, DataStore progression with session locking. Medic, support, engineer and recon gadgets, revives, spotting. |
| **UI** | HUD, minimap, big map, compass, objectives bar, kill feed, score popups, crosshair, hitmarkers, damage indicators, scope overlay. Deploy screen with team, class, loadout and spawn selection. Scoreboard, settings, round-end screen, notifications. Phone and tablet layouts. |
| **Animation & Models** | Procedural weapon models (22 archetypes). First-person viewmodel with IK, ADS, sway, recoil, reload, throw and melee animations. Camera (recoil, shake, death cam). Movement (sprint, crouch, prone). Third-person character posing. Faction uniforms and helmets. Ragdolls. |
| **Sound & Atmosphere** | 7 lighting presets and per-map ambience. Pooled effects: muzzle flash, tracers, impacts by material, explosions, smoke screens, fire, shell casings. Pooled 3D audio with distance delay and indoor reverb. Weather: rain, snow, fog, ash, lightning, distant artillery. |
| **Monetization** (added on request) | Game passes (VIP, Double XP, Camo Collection, Uniform Pack, Extra Loadout Presets). Developer products (XP boosts, instant weapon unlock, supporter tips) with idempotent receipt processing. In-game store. Nothing pay-to-win and no paid random items. |

Lead integration: aligned the sound keys between the weapon code and the sound config, and committed.

## Phase 2: Content, testing, balance and performance

| Agent | Delivered |
|---|---|
| **Map Design B** | Atlantic Wall (beach landing), Ardennes Forest, Coral Atoll (Pacific), Sicilian Hills, each fuzz-tested in the mock harness, with HQ sightline analysis. |
| **Testing** | Fixed 10 runtime bugs at system seams: squad spawn data lost, dead crews keeping vehicle control, spawning into unstreamed areas, deploy/equip race, legitimate shots rejected by fire-rate jitter, vehicle sight FOV, a seat-switch unlock bypass, and others. Added `scripts/contracts_check.py`, which cross-checks remotes, Bus events, attributes and APIs between client and server. |
| **Balancing** | Added `scripts/balance_report.py`, which models time-to-kill, shots-to-kill, tank and AT duels, mode length and unlock pacing. It tuned the configs until every target was met. See `docs/BALANCE.md`. |
| **Optimization** | Character-animation level of detail and caching, event-driven vehicle sets, network payload caps and distance culling, minimap redraw throttling, write-on-change UI and effects, a map post-build audit, and mobile graphics defaults. See `docs/PERFORMANCE.md`. |

Lead fix: AT rifles dealt no damage to armored vehicles. A cover-penetration factor was being passed
where an armor rating was expected; they now carry a separate `armorPenetration` rating.

## Phase 3: Cross-review
Two fresh reviewers each re-audited one half of the game, server and client, including everything changed after the Testing pass.
- **Server (3 fixes):**
  - Shutdown now waits for all in-flight progression saves (prevents data loss).
  - The purchase store never falls back to memory on a live server, so a purchase is never confirmed without being saved.
  - The vehicle hit marker uses the damage actually applied.
- **Client (7 fixes):**
  - The death cam could leave players stuck without a deploy screen.
  - Touch players had no vehicle controls; on-screen buttons and thumbstick driving were added.
  - A gamepad couldn't deploy on first join.
  - Gamepad B both closed a menu and crouched.
  - Enter deployed while the store or settings was open.
  - Settings opened behind the store.
  - The "Killed in action" card never showed.
- Known gaps (features, not bugs): no on-screen touch buttons for crouch, prone, sprint, gadgets or spotting; no gamepad shortcut to the store or settings while in game.

## What needs a human next
1. **Playtest in Roblox Studio**, solo and then with Test → Clients and Servers. Check vehicle handling, animation poses, camera feel, map visuals and spawn placement.
2. **Create the game passes and developer products** on the Creator Dashboard and paste their IDs into `src/shared/Config/Monetization.luau` (see `docs/MONETIZATION.md`).
3. **Optionally upload licensed audio** and paste the IDs into `src/shared/Config/Sounds.luau` (see `docs/AUDIO.md`). Until then the game uses Roblox's built-in placeholder sounds.
