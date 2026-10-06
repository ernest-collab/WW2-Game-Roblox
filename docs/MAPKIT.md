# MapKit — procedural map building guide

MapKit (`src/server/Maps/MapKit/`) is the shared library every map builder uses. It builds
terrain, buildings, fortifications, props, vegetation and gameplay structures (HQs and capture
points) from Terrain voxels and Parts only. It uses no asset IDs. Reference maps:
`Maps/Normandy.luau`, `Maps/Stalingrad.luau`, `Maps/Kursk.luau`.

## 1. Builder contract

A map is a ModuleScript `src/server/Maps/<Builder>.luau` that `Config/Maps.luau` names as `builder`:

```lua
local MapKit = require(script.Parent.MapKit)
local MyMap = {}
function MyMap.Build(parent: Folder, def) -- parent = workspace.Map (MapService creates it)
    local ctx = MapKit.new(parent, { seed = 1234 })   -- the same seed gives the same map
    ... build ...
    return MapKit.Finish(ctx, {
        id = "MyMap",
        bounds = { center = Vector3.new(0, 50, 0), size = Vector3.new(1600, 700, 1600) },
        hq = { Allies = {CFrame...}, Axis = {CFrame...} },             -- ≥ 2 each (SpawnArea gives 10)
        objectives = { Layout.CapturePoint(ctx, {...}), ... },          -- order 1 = Allied end
        vehicleSpawns = { Allies = {{cframe=, class="Tank"}}, Axis = {...} },
        outOfBounds = 10,
    })
end
return MyMap
```
`MapKit.Finish` adds `minimap` (collected automatically) and prints the part count. MapService
validates and normalises the result: it fills in missing radii and orders, sorts objectives,
and gives at least 2 HQ spawns per side. It then publishes the public subset.

## 2. Recommended build order

1. `MapKit.new(parent, {seed})` → `ctx`, then `Terrain.ApplyPalette({...}, {decoration=, color=})`.
2. **Describe the ground analytically**. Do this before writing any voxels:
   ```lua
   local hm = Terrain.HeightModel({ baseY = 0, seed = SEED })
   hm:Noise(8, 300, 3)                         -- amplitude, feature size, octaves
   hm:Hill(x, z, radius, height) ; hm:Ridge(points, width, height)
   hm:River(points, {width, bank, bedY, waterY, frozen}) ; hm:Pond(...) ; hm:Sea(level)
   hm:Channel(points, width, depth, bank, "U"|"V")   -- gullies (U), anti-tank ditches (V)
   hm:Flatten(x, z, r, y?, blend) ; hm:FlattenRect(cx, cz, sx, sz, rot, y?, blend)
   Layout.PrepareHQ(hm, hqCFrame)              -- flat pad for each HQ
   hm:Road(points, width, blend)               -- levels the road's cross-section
   hm:Embankment(points, topWidth, height)     -- railway dykes
   hm:Custom(function(x, z, h) return h end)   -- escape hatch (e.g. raise the map border)
   ```
   Ops are applied in order. Flatten/Road/Embankment read the terrain as it stands *at that
   point*, so add them after the noise and hills.
3. **Materials**: the last matching rule wins.
   ```lua
   local mm = Terrain.MaterialModel({ base = M.Grass, subsurface = M.Ground })
   mm:Patches(M.LeafyGrass, scale, threshold) ; mm:Rect(cx, cz, sx, sz, rot, mat, edgeNoise)
   mm:Circle(...) ; mm:Path(points, width, mat, edge) ; mm:Polygon(points, mat)
   mm:Slope(M.Rock, 1.0) ; mm:Below(y, M.Mud) ; mm:Above(y, M.Snow) ; mm:Custom(mat, fn)
   ```
   Paint roads this way: Ground, Cobblestone and Asphalt are cheap and need zero parts.
4. `Terrain.Generate(ctx, hm, mm, { center, size })`. This writes smooth voxels in chunks with
   yields between them, and registers `hm` so that `ctx:GroundY(x, z)` is analytic and fast.
   Make `size` about 200–400 studs larger than the bounds so the horizon is not a cliff.
5. Carve and sculpt: `Terrain.Crater`, `Fortifications.Trench`, `Terrain.Berm`, `Terrain.Mound`,
   `Terrain.RubbleMound`.
6. Place buildings, fortifications, props and nature.
7. Build HQs with `Layout.SpawnArea`, then objectives with `Layout.CapturePoint`. Do objectives
   last, because their auto-spawns raycast to avoid roofs and props.

## 3. Context (`ctx`) API

| Call | Purpose |
|---|---|
| `ctx.rng`, `ctx:Range(a,b)`, `ctx:Int(a,b)`, `ctx:Chance(p)`, `ctx:Pick(list)`, `ctx:Jitter(color, amt)` | deterministic randomness |
| `ctx:Part{Size, CFrame, Material, Color, Shape?, Mesh?, Destructible?, Health?, NoPenetration?, CanCollide?, CanQuery?, CastShadow?, Jitter?, Parent?, Tags?}` | part factory: anchored, CanTouch=false, auto CastShadow (big parts only), colour jitter, auto-yield |
| `ctx:Folder(name)`, `ctx:Model(name, parent)` | hierarchy (`Buildings`, `Props`, `Nature`, `Fortifications`, `HQ`, `Effects`, `Objectives`) |
| `ctx:GroundY(x,z)` / `ctx:SurfaceY(x,z)` | analytic height (ignores carving) / terrain raycast (includes craters) |
| `ctx:GroundCF(x, z, yawDeg)` | ground-snapped CFrame. Yaw 0 faces −Z, 180 faces +Z, 90 faces −X, −90 faces +X |
| `ctx:AddMinimap(kind, cx, cz, sx, sz, rot)`, `AddMinimapCF`, `AddMinimapPath` | minimap shapes (buildings, bridges, forests, fields and trenches add their own) |

**Facing convention:** a structure's front faces `cf.LookVector`. For fortifications, that is
the direction toward the enemy. Paths are lists of `Vector3` (Y is ignored) or `Vector2`.
"Right of travel" is `cf.RightVector` of a CFrame looking along the path. Travelling +X, right
is +Z. Travelling +Z, right is −X.

## 4. Library reference (all calls take `ctx` first)

**Buildings** (`cf` = ground centre of the footprint, front = LookVector). Common opts:
`style`, `ruin` (0..1), `enterable`, `width`, `depth`, `floors`.
Styles: `Norman`, `NormanStone`, `Brick`, `Soviet`, `SovietBrick`, `Mediterranean`, `Timber`,
`Log` (thatch), `Farm`.
- `House(cf, opts)`: 1–3 floors with gable or flat roof. Enterable houses get open doors and
  windows, floors, stair ramps and furniture. Non-enterable houses use solid walls with panes,
  which is cheaper.
- `StoneHouse` (Mediterranean), `Farmhouse` (with a lean-to shed), `Barn` (big doors, hayloft
  with a ladder).
- `Church(cf, {width, length, towerH})`: the tower has ladder-linked levels, and its belfry is a
  sniper perch.
- `Apartment(cf, {width, depth, floors})` and `FactoryHall(cf, {width, depth, height, bay})`:
  the factory hall has trusses, a crane and machines.
- `Chimney(pos, {height, ruin})`, `Hut(cf, {style, stilts})`, `Shed`, `Windmill(cf, {ruin})`.
- `RuinedWall(cf, length, height)`: free-standing facade remnant.
- `Wall(...)`: low-level wall with openings.
- Walls are chunked about 4–8 studs wide and tagged `Destructible`.

**Fortifications**
- `Sandbags(cf, {length, courses, arc})`
- `BarbedWire(points)`: has an invisible 2.6-stud blocker that players jump over.
- `Hedgehog(pos)`, `DragonTooth(pos)`, `TankTraps(points, {kind="hedgehog"|"teeth"|"mixed"})`
- `Bunker(cf, {width, depth, slits, sunk})`: concrete, NoBulletPenetration, interior carved.
- `LogBunker(cf)`, `MGNest(cf)`, `MGProp(cf)`, `ATGun(cf)`, `Foxhole(cf)`
- `Barricade(cf, {kind="wood"|"debris"})`
- `Trench(points, {width, depth, parapet="left"|"right"|"both"|"none", revetment, duckboards, fireSteps, sandbags, ramps})`:
  carved terrain with plank revetments, duckboards, fire steps (to shoot out and climb out),
  earth parapet and exit ramps at both ends. Use `Layout.Zigzag(points, 3.5, 13)` for
  traversed lines.
- `Watchtower(cf, {height})`

**Props**
- `FlagPole(pos, {name, owner, height})`: the model has a BasePart named **`Flag`**.
- `Crate(at, {kind="wood"|"ammo"|"medical"})`: ammo crates are tagged `ResupplyPoint`, medical
  crates `MedicalPoint`.
- `CrateStack`, `AmmoCache`, `Barrel`, `BarrelGroup`, `Cart`, `Haystack`, `HayBales`, `Well`
- `Fence(points, {kind})`, `StoneWall(points)`, `TelegraphLine(points)`, `LampPost(at, {lit})`
- `Bench`, `Signpost`, `Fountain`, `Tent`
- `Wreck(at, {kind="tank"|"truck"|"car"|"halftrack", burning})`
- `Fire(pos, {size})`: Fire, Smoke and PointLight. Use these sparingly, roughly ≤ 6 per map.
- `RubblePile(pos)`: terrain heap plus a few parts. `Debris(pos)`.
- `StoneBridge(a, b, {width, arches})`, `WoodBridge(a, b)`, `Railway(points, {sleeper, broken})`

**Nature**
- `Tree(pos, kind, scale)`, where kind is `Oak`, `Birch`, `Apple`, `Poplar`, `Pine`, `Fir`,
  `Palm`, `Dead` or `Burnt`. Foliage is non-colliding and non-queryable.
- `Bush`, `Rock`, `GrassTufts`
- `Hedgerow(points, {height, skip(x, z), gaps})`: bocage, an earth bank plus a dense hedge.
- `Forest(area, {kinds, spacing, filter})`, `Orchard(cf, {rows, cols})`
- `WheatField(cf, sx, sz, {rowSpacing, harvested})`: tall crop strips players can go prone in.

**Layout**
- `Scatter(area, {spacing, count, avoid, filter})`
- `AlongPath(points, spacing, fn(cf, i), {offset, jitter})`
- `Zigzag`, `Offset`, `Smooth`
- `PlanGrid(origin, {...})` returns streets and lots for planning before generation.
- `PrepareHQ(hm, cf)`
- `SpawnArea(ctx, cf, side, {spawnCount, vehicleCount, width, bermHeight})` returns
  `{spawns, vehicles}`. It builds earth berms with a vehicle gap, a baffle berm, tents, ammo and
  medical points and the HQ flag.
- `CapturePoint(ctx, {id, name, position, flagPosition?, radius, order, initialOwner, spawns?})`
  returns an objective entry and creates `workspace.Map.Objectives.<id>` (a FlagPole model
  containing the `Flag` part). It auto-generates spawns on open ground around the point.

## 5. Contracts with other teams

- **Objective flags:** `workspace.Map.Objectives.<id>` is a Model with a direct child BasePart
  `Flag`. ObjectiveService recolours it by owner. The model also has the attributes
  `ObjectiveId` and `Radius`.
- **Destruction:** BaseParts (or Models) tagged `Destructible` under `workspace.Map` break from
  Bus `Explosion`. An optional `Health` attribute overrides toughness. Debris uses the
  `Debris` collision group under `workspace.Map.Debris`.
- **Minimap shapes:** `{kind, cx, cz, sx, sz, rot}`. `rot` is a yaw in **degrees**, using the
  same convention as `CFrame.Angles(0, math.rad(rot), 0)`. `sx` is the local X extent and `sz`
  the local Z extent.
- **Tags:** `ResupplyPoint` (HQ ammo caches), `MedicalPoint` (HQ medical crate),
  `NoBulletPenetration` (bunkers, wrecks, machinery, bridge decks).

## 6. Performance rules of thumb

- Aim for 6–9k parts per map. `ctx:Stats()` and `MapKit.Finish` print the count.
- Use Terrain for ground, hills, water, rubble heaps, berms and roads.
- Use `enterable = false` for background buildings. It roughly halves their part count.
- Never place craters, trenches or HQ berms where a building foundation will go. Foundations use
  the analytic `GroundY`.
- Keep `Fire` and `PointLight` sources few. Lighting presets belong to the Atmosphere team.
