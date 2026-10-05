# WW2 Frontlines (Roblox)

A large-scale WWII team shooter for Roblox: seven nations, combined-arms infantry and tank combat,
capture-point and frontline objectives, squads and classes, and progression. The whole game is
**code-first**. It lives in this repo as Luau and is synced into Roblox Studio with [Rojo](https://rojo.space).

> Inspiration: the gameplay loop and presentation quality of large Roblox military shooters such as
> *Cold War*. No assets or content from other games are used. Everything here (maps, weapon and
> vehicle models, effects, UI) is generated procedurally.

## Quick start

1. Install the toolchain with [Rokit](https://github.com/rojo-rbx/rokit): `rokit install` (Rojo, StyLua, luau-lsp).
2. Build a place file: `rojo build default.project.json -o WW2-Frontlines.rbxl`, then open it in Studio.
   Or run `rojo serve` and connect from the Rojo Studio plugin for live sync.
3. Enable **Game Settings → Security → Enable Studio Access to API Services** if you want DataStore
   progression saving in Studio. Without it, progression falls back to in-memory storage.
4. Press **Play**. A solo player can play immediately: the round starts with one player.

### Quality gate
```
scripts/check.sh        # StyLua format check + luau-lsp type check (Roblox API) + Rojo build
FIX=1 scripts/check.sh  # also auto-format
```

## Content

| | |
|---|---|
| **Factions** | United States, United Kingdom, Soviet Union, France (Allies) · Germany, Japan, Italy (Axis) |
| **Modes** | Conquest (tickets + capture points), Frontline (tug-of-war push), Team Deathmatch |
| **Classes** | Rifleman, Assault, Support, Medic, Engineer, Recon |
| **Maps** | Saint-Laurent (Normandy village), Red October Ruins (Stalingrad), Prokhorovka Fields (Kursk), Atlantic Wall (beach landing), Ardennes Forest, Coral Atoll (Pacific), Sicilian Hills |

See `docs/` for details:
* `docs/ARCHITECTURE.md`: system layout, ownership and every cross-module contract
* `docs/MAPKIT.md`: the procedural level-building library
* `docs/AUDIO.md`: the sound system, and how to plug in licensed audio assets
* `docs/BALANCE.md`: weapon, vehicle and faction balance notes
* `docs/DEVELOPMENT_LOG.md`: how the game was built by a team of specialised AI agents

## Controls (keyboard / mouse)

| Action | Key | Action | Key |
|---|---|---|---|
| Fire / Aim | LMB / RMB | Reload | R |
| Sprint | Shift | Crouch / Prone | C / Z |
| Weapons & gadgets | 1–4 | Melee / Quick grenade | V / G |
| Fire mode | B | Interact / enter vehicle | E |
| Spot enemy | Q | Scoreboard / Map | Tab / M |
| Settings | P | Vehicle: exit / switch seat | F / X |

Gamepad is supported for core actions (see `src/shared/Config/Keybinds.luau`).
