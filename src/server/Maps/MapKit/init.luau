--[[
	MapKit — reusable procedural level-building library for WW2 Frontlines.
	Full usage guide: docs/MAPKIT.md

		local MapKit = require(script.Parent.MapKit)
		local ctx = MapKit.new(parent, { seed = 1944 })      -- build Context (rng, part factory, minimap)
		local hm = MapKit.Terrain.HeightModel({ baseY = 0 })  -- describe the ground...
		local mm = MapKit.Terrain.MaterialModel({ base = Enum.Material.Grass })
		MapKit.Terrain.Generate(ctx, hm, mm, { center = Vector3.zero, size = Vector2.new(1600, 1600) })
		MapKit.Buildings.House(ctx, ctx:GroundCF(0, 0, 90), { floors = 2, ruin = 0.4 })
		...
		return MapKit.Finish(ctx, { id = ..., bounds = ..., hq = ..., objectives = ..., vehicleSpawns = ... })

	Submodules:
	  Core           Context type, part factory, ground queries, minimap
	  Geo            pure 2D math (paths, distances, zigzags, noise)
	  Terrain        HeightModel / MaterialModel / Generate / craters / mounds / berms / carving
	  Buildings      houses, farms, barns, church, apartments, factory, chimney, huts, windmill, ruins
	  Fortifications sandbags, wire, hedgehogs, bunkers, MG nests, AT guns, trenches, foxholes...
	  Props          flag poles, crates, barrels, carts, fences, walls, poles, wrecks, fires, bridges...
	  Nature         trees, bushes, bocage hedgerows, forests, orchards, wheat fields, rocks
	  Layout         scatter, along-path, street grids, HQ spawn areas, capture points
]]

local Core = require(script.Core)

local MapKit = {}

MapKit.Core = Core
MapKit.Geo = require(script.Geo)
MapKit.Terrain = require(script.Terrain)
MapKit.Buildings = require(script.Buildings)
MapKit.Props = require(script.Props)
MapKit.Fortifications = require(script.Fortifications)
MapKit.Nature = require(script.Nature)
MapKit.Layout = require(script.Layout)

-- Creates a build Context. See Core.new.
function MapKit.new(parent: Instance, opts: { seed: number?, yieldEvery: number? }?)
	return Core.new(parent, opts)
end

--[[
	MapKit.Finish(ctx, info) -> MapInfo
	Fills `minimap` from the context, rounds nothing else, prints build stats.
	info must contain id, bounds, hq, objectives, vehicleSpawns (see ARCHITECTURE.md §8).
]]
function MapKit.Finish(ctx: any, info: { [string]: any }): { [string]: any }
	info.minimap = info.minimap or ctx.minimap
	info.outOfBounds = info.outOfBounds or 10
	ctx:Stats(info.id)
	return info
end

return MapKit
