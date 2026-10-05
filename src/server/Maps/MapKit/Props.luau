--[[
	MapKit.Props — human-scale clutter and set dressing.

	All functions take (ctx, cf_or_pos, opts?) and snap to the terrain unless opts.snap == false
	(or a CFrame with an explicit height is wanted: pass opts.snap = false).
	`cf` faces cf.LookVector. Returns the created Model (or Part for single-part props).

	  FlagPole        capture-point flag (contains a BasePart named "Flag" — see ObjectiveService)
	  Crate, CrateStack, AmmoCache, Barrel, BarrelGroup, Cart, Haystack, HayBales
	  Fence, StoneWall, TelegraphLine, LampPost, Well, Bench, Tent, Wreck,
	  Fire, RubblePile, Debris, StoneBridge, WoodBridge, Signpost, Fountain
]]

local Core = require(script.Parent.Core)
local Geo = require(script.Parent.Geo)
local Terrain = require(script.Parent.Terrain)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"):WaitForChild("Constants"))

local M = Enum.Material
local rgb = Color3.fromRGB

local Props = {}

local WOOD = rgb(110, 86, 58)
local DARK_WOOD = rgb(70, 54, 40)
local OLIVE = rgb(78, 84, 58)
local RUST = rgb(86, 62, 48)

-- Resolve a placement CFrame on the ground.
local function place(ctx: any, at: any, opts: { [string]: any }?): CFrame
	local cf: CFrame = if typeof(at) == "Vector3" then CFrame.new(at) else at
	if opts and opts.snap == false then
		return cf
	end
	local p = cf.Position
	local y = if opts and opts.surface then ctx:SurfaceY(p.X, p.Z) else ctx:GroundY(p.X, p.Z)
	return CFrame.new(p.X, y, p.Z) * (cf - p)
end

local function folder(ctx: any, opts: { [string]: any }?, name: string?): Instance
	return (opts and opts.parent) or ctx:Folder(name or "Props")
end

---------------------------------------------------------------------------------------------------
-- Flag pole (objective marker)
---------------------------------------------------------------------------------------------------

--[[
	Props.FlagPole(ctx, pos, opts) -> Model
	opts: name (model name, e.g. objective id), owner ("Allies"|"Axis"|"Neutral"), height (22), parent
	The model contains: "Pole", "Base" and a BasePart named "Flag" (recoloured by ObjectiveService).
	Use Layout.CapturePoint to create objective flags in workspace.Map.Objectives.<id>.
]]
function Props.FlagPole(ctx: any, pos: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, pos, o)
	local h = o.height or 22
	local model = ctx:Model(o.name or "FlagPole", folder(ctx, o))
	local color = Constants.SIDE_COLORS[o.owner or "Neutral"] or Constants.SIDE_COLORS.Neutral
	local stand = ctx:Part({
		Name = "Base",
		Parent = model,
		Size = Vector3.new(3.2, 1.6, 3.2),
		CFrame = base * CFrame.new(0, 0.3, 0),
		Material = M.Concrete,
		Color = rgb(110, 108, 102),
	})
	ctx:Part({
		Name = "Pole",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(h, 0.45, 0.45),
		CFrame = base * CFrame.new(0, h / 2 + 1, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = M.Metal,
		Color = rgb(70, 70, 68),
		Jitter = 0,
	})
	ctx:Part({
		Name = "Finial",
		Parent = model,
		Shape = "Ball",
		Size = Vector3.new(0.8, 0.8, 0.8),
		CFrame = base * CFrame.new(0, h + 1.2, 0),
		Material = M.Metal,
		Color = rgb(150, 130, 70),
		Jitter = 0,
	})
	ctx:Part({
		Name = "Flag",
		Parent = model,
		Size = Vector3.new(0.12, 3.6, 6),
		CFrame = base * CFrame.new(0, h - 1.4, 3.2),
		Material = M.Fabric,
		Color = color,
		Jitter = 0,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
	model.PrimaryPart = stand
	return model
end

---------------------------------------------------------------------------------------------------
-- Crates, barrels, ammo
---------------------------------------------------------------------------------------------------

-- Wooden crate. opts.size (Vector3), opts.color, opts.kind = "wood" | "ammo" | "medical"
function Props.Crate(ctx: any, at: any, opts: { [string]: any }?): BasePart
	local o = opts or {}
	local size: Vector3 = o.size or Vector3.new(3, 2.4, 2.2)
	local cf = place(ctx, at, o)
	local kind = o.kind or "wood"
	local color = o.color
		or (if kind == "ammo" then OLIVE elseif kind == "medical" then rgb(200, 196, 184) else rgb(124, 98, 64))
	local crate = ctx:Part({
		Name = if kind == "ammo" then "AmmoCrate" elseif kind == "medical" then "MedicalCrate" else "Crate",
		Parent = folder(ctx, o),
		Size = size,
		CFrame = cf * CFrame.new(0, size.Y / 2, 0),
		Material = if kind == "wood" then M.WoodPlanks else M.Wood,
		Color = color,
		Destructible = kind == "wood",
		CastShadow = size.Magnitude > 4,
	})
	if kind == "ammo" then
		ctx:Tag(crate, Constants.TAGS.ResupplyPoint)
	elseif kind == "medical" then
		ctx:Tag(crate, Constants.TAGS.MedicalPoint)
		ctx:Part({
			Name = "Cross",
			Parent = crate,
			Size = Vector3.new(1.2, 0.3, size.Z + 0.06),
			CFrame = crate.CFrame,
			Material = M.SmoothPlastic,
			Color = rgb(170, 30, 30),
			Jitter = 0,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		})
	end
	return crate
end

-- Small random pile of crates (good waist-high cover).
function Props.CrateStack(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("CrateStack", folder(ctx, o))
	local n = o.count or ctx:Int(2, 5)
	for i = 1, n do
		local layer = if i > 3 then 1 else 0
		local s = Vector3.new(ctx:Range(2.6, 3.6), ctx:Range(2, 2.8), ctx:Range(2.2, 3))
		local cf = base
			* CFrame.new(ctx:Range(-2.5, 2.5), layer * 2.5, ctx:Range(-2, 2))
			* CFrame.Angles(0, ctx:Range(-0.4, 0.4), 0)
		Props.Crate(ctx, cf, { size = s, parent = model, snap = false, kind = o.kind })
	end
	return model
end

-- HQ / map resupply point: ammo crates tagged ResupplyPoint.
function Props.AmmoCache(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("AmmoCache", folder(ctx, o))
	for i = 0, 2 do
		Props.Crate(ctx, base * CFrame.new((i - 1) * 2.6, 0, 0) * CFrame.Angles(0, ctx:Range(-0.1, 0.1), 0), {
			size = Vector3.new(2.4, 1.4, 1.6),
			kind = "ammo",
			parent = model,
			snap = false,
		})
	end
	Props.Crate(ctx, base * CFrame.new(-1.3, 1.4, 0), {
		size = Vector3.new(2.4, 1.4, 1.6),
		kind = "ammo",
		parent = model,
		snap = false,
	})
	return model
end

-- Oil/fuel drum. opts.tipped = true lays it on its side.
function Props.Barrel(ctx: any, at: any, opts: { [string]: any }?): BasePart
	local o = opts or {}
	local cf = place(ctx, at, o)
	local color = o.color or ctx:Pick({ RUST, rgb(64, 72, 58), rgb(92, 40, 34), rgb(60, 60, 60) })
	if o.tipped then
		return ctx:Part({
			Name = "Barrel",
			Parent = folder(ctx, o),
			Shape = "Cylinder",
			Size = Vector3.new(3.4, 2.3, 2.3),
			CFrame = cf * CFrame.new(0, 1.15, 0) * CFrame.Angles(0, ctx:Range(0, 6.28), 0),
			Material = M.CorrodedMetal,
			Color = color,
		})
	end
	return ctx:Part({
		Name = "Barrel",
		Parent = folder(ctx, o),
		Shape = "Cylinder",
		Size = Vector3.new(3.4, 2.3, 2.3),
		CFrame = cf * CFrame.new(0, 1.7, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = M.CorrodedMetal,
		Color = color,
	})
end

function Props.BarrelGroup(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("Barrels", folder(ctx, o))
	for _ = 1, o.count or ctx:Int(2, 5) do
		local p = base * CFrame.new(ctx:Range(-3, 3), 0, ctx:Range(-3, 3))
		local y = ctx:GroundY(p.Position.X, p.Position.Z)
		Props.Barrel(ctx, CFrame.new(p.Position.X, y, p.Position.Z), {
			parent = model,
			snap = false,
			tipped = ctx:Chance(0.25),
		})
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Farm props
---------------------------------------------------------------------------------------------------

-- Two-wheeled farm cart. opts.broken tips it over.
function Props.Cart(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("Cart", folder(ctx, o))
	local tilt = if o.broken then CFrame.Angles(0, 0, math.rad(18)) else CFrame.Angles(math.rad(-8), 0, 0)
	local body = base * CFrame.new(0, 2.6, 0) * tilt
	ctx:Part({
		Name = "Bed",
		Parent = model,
		Size = Vector3.new(5, 0.4, 8),
		CFrame = body,
		Material = M.WoodPlanks,
		Color = WOOD,
		Destructible = true,
	})
	for _, sx in { -1, 1 } do
		ctx:Part({
			Name = "Side",
			Parent = model,
			Size = Vector3.new(0.3, 1.4, 8),
			CFrame = body * CFrame.new(sx * 2.4, 0.9, 0),
			Material = M.WoodPlanks,
			Color = WOOD,
			Destructible = true,
			CastShadow = false,
		})
		if not (o.broken and sx == 1) then
			ctx:Part({
				Name = "Wheel",
				Parent = model,
				Shape = "Cylinder",
				Size = Vector3.new(0.4, 4.4, 4.4),
				CFrame = base * CFrame.new(sx * 2.9, 2.2, 0.5),
				Material = M.Wood,
				Color = DARK_WOOD,
				CastShadow = false,
			})
		end
	end
	ctx:Part({
		Name = "Shaft",
		Parent = model,
		Size = Vector3.new(0.4, 0.4, 7),
		CFrame = body * CFrame.new(0, -0.2, -7) * CFrame.Angles(math.rad(-10), 0, 0),
		Material = M.Wood,
		Color = DARK_WOOD,
		CastShadow = false,
	})
	if o.hay ~= false and ctx:Chance(0.5) then
		ctx:Part({
			Name = "Load",
			Parent = model,
			Size = Vector3.new(4.4, 2, 7),
			CFrame = body * CFrame.new(0, 1.2, 0),
			Material = M.Grass,
			Color = rgb(176, 150, 92),
			CastShadow = false,
		})
	end
	return model
end

-- Round haystack (ellipsoid heap) — soft cover, blocks sight.
function Props.Haystack(ctx: any, at: any, opts: { [string]: any }?): BasePart
	local o = opts or {}
	local cf = place(ctx, at, o)
	local s = o.size or ctx:Range(6, 9)
	return ctx:Part({
		Name = "Haystack",
		Parent = folder(ctx, o, "Nature"),
		Size = Vector3.new(s, s * 0.85, s),
		CFrame = cf * CFrame.new(0, s * 0.25, 0),
		Mesh = "Sphere",
		Material = M.Grass,
		Color = o.color or rgb(178, 152, 92),
		Jitter = 0.06,
		CanQuery = true,
		CastShadow = true,
	})
end

-- Line/pile of rectangular hay bales.
function Props.HayBales(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("HayBales", folder(ctx, o, "Nature"))
	local n = o.count or ctx:Int(3, 6)
	for i = 1, n do
		local layer = if i > n - 2 and n > 3 then 1 else 0
		ctx:Part({
			Name = "HayBale",
			Parent = model,
			Size = Vector3.new(4, 2.2, 2.6),
			CFrame = base * CFrame.new((i - n / 2) * 3.4 * 0.75 + layer * 1.5, 1.1 + layer * 2.2, ctx:Range(-0.4, 0.4)) * CFrame.Angles(
				0,
				ctx:Range(-0.15, 0.15),
				0
			),
			Material = M.Grass,
			Color = rgb(176, 152, 92),
			Jitter = 0.06,
		})
	end
	return model
end

function Props.Well(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("Well", folder(ctx, o))
	for i = 0, 5 do
		local a = i * math.pi / 3
		ctx:Part({
			Name = "WellStone",
			Parent = model,
			Size = Vector3.new(2.4, 3, 1),
			CFrame = base * CFrame.Angles(0, a, 0) * CFrame.new(0, 1.5, -2),
			Material = M.Cobblestone,
			Color = rgb(120, 114, 104),
		})
	end
	for _, sx in { -1, 1 } do
		ctx:Part({
			Name = "Post",
			Parent = model,
			Size = Vector3.new(0.5, 6, 0.5),
			CFrame = base * CFrame.new(sx * 2.2, 4, 0),
			Material = M.Wood,
			Color = DARK_WOOD,
			CastShadow = false,
		})
	end
	ctx:Part({
		Name = "Roof",
		Parent = model,
		Size = Vector3.new(5.6, 0.4, 3.4),
		CFrame = base * CFrame.new(0, 7.1, 0),
		Material = M.RoofShingles,
		Color = rgb(70, 62, 56),
	})
	return model
end

---------------------------------------------------------------------------------------------------
-- Linear props: fences, walls, telegraph lines
---------------------------------------------------------------------------------------------------

--[[
	Props.Fence(ctx, points, opts) -> Model
	opts.kind: "rail" (posts + 2 rails, default) | "picket" | "wire" (farm wire)
	opts.gapChance: probability a span is broken/missing (default 0.1)
]]
function Props.Fence(ctx: any, points: { any }, opts: { [string]: any }?): Model
	local o = opts or {}
	local kind = o.kind or "rail"
	local spacing = o.spacing or 8
	local model = ctx:Model("Fence", folder(ctx, o))
	local p = Geo.path(points)
	local n = math.max(1, math.floor(p.length / spacing))
	local prev: Vector3? = nil
	for i = 0, n do
		local x, z = Geo.sample(p, p.length * i / n)
		local y = ctx:GroundY(x, z)
		local top = Vector3.new(x, y, z)
		ctx:Part({
			Name = "Post",
			Parent = model,
			Size = Vector3.new(0.5, 4.2, 0.5),
			CFrame = CFrame.new(x, y + 1.6, z) * CFrame.Angles(ctx:Range(-0.08, 0.08), ctx:Range(0, 3), ctx:Range(-0.08, 0.08)),
			Material = M.Wood,
			Color = DARK_WOOD,
			CastShadow = false,
		})
		if prev and not ctx:Chance(o.gapChance or 0.1) then
			local heights = if kind == "picket" then { 1.6 } elseif kind == "wire" then { 1.4, 2.6 } else { 1.3, 2.8 }
			for _, hy in heights do
				local a, b = prev + Vector3.new(0, hy, 0), top + Vector3.new(0, hy, 0)
				local cf, len = Core.Between(a, b)
				if kind == "picket" then
					ctx:Part({
						Name = "Pickets",
						Parent = model,
						Size = Vector3.new(0.2, 3.2, len),
						CFrame = cf,
						Material = M.WoodPlanks,
						Color = rgb(150, 140, 120),
						Destructible = true,
						CastShadow = false,
					})
				else
					ctx:Part({
						Name = if kind == "wire" then "Wire" else "Rail",
						Parent = model,
						Size = if kind == "wire" then Vector3.new(0.08, 0.08, len) else Vector3.new(0.3, 0.45, len),
						CFrame = cf,
						Material = if kind == "wire" then M.Metal else M.Wood,
						Color = if kind == "wire" then rgb(60, 58, 56) else WOOD,
						Destructible = kind ~= "wire",
						CanCollide = kind ~= "wire",
						CastShadow = false,
					})
				end
			end
		end
		prev = top
	end
	return model
end

--[[
	Props.StoneWall(ctx, points, opts) -> Model — dry-stone field / garden wall following the terrain.
	opts: height (3.4), thickness (2), material (Cobblestone), color, gapChance (0.06), destructible (true)
]]
function Props.StoneWall(ctx: any, points: { any }, opts: { [string]: any }?): Model
	local o = opts or {}
	local h = o.height or 3.4
	local t = o.thickness or 2
	local model = ctx:Model("StoneWall", folder(ctx, o))
	local seg = o.segment or 10
	local color = o.color or rgb(122, 116, 104)
	for i = 1, #points - 1 do
		local ax, az = Geo.xz(points[i])
		local bx, bz = Geo.xz(points[i + 1])
		local len = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
		local steps = math.max(1, math.ceil(len / seg))
		for s = 0, steps - 1 do
			if ctx:Chance(o.gapChance or 0.06) then
				continue
			end
			local t0, t1 = s / steps, (s + 1) / steps
			local x0, z0 = Geo.lerp(ax, bx, t0), Geo.lerp(az, bz, t0)
			local x1, z1 = Geo.lerp(ax, bx, t1), Geo.lerp(az, bz, t1)
			local mx, mz = (x0 + x1) / 2, (z0 + z1) / 2
			local y = math.min(ctx:GroundY(x0, z0), ctx:GroundY(x1, z1), ctx:GroundY(mx, mz))
			local hh = h * ctx:Range(0.85, 1.1)
			local cf = CFrame.lookAt(Vector3.new(mx, y + hh / 2 - 0.8, mz), Vector3.new(x1, y + hh / 2 - 0.8, z1))
			ctx:Part({
				Name = "Wall",
				Parent = model,
				Size = Vector3.new(t, hh + 0.8, len / steps + 0.3),
				CFrame = cf,
				Material = o.material or M.Cobblestone,
				Color = color,
				Jitter = 0.04,
				Destructible = o.destructible ~= false,
			})
		end
	end
	return model
end

--[[
	Props.TelegraphLine(ctx, points, opts) -> Model
	Wooden poles every `spacing` (40) studs with a cross-arm and sagging wires. opts.leanChance tilts some.
]]
function Props.TelegraphLine(ctx: any, points: { any }, opts: { [string]: any }?): Model
	local o = opts or {}
	local spacing = o.spacing or 40
	local h = o.height or 18
	local model = ctx:Model("TelegraphLine", folder(ctx, o))
	local p = Geo.path(points)
	local n = math.max(1, math.floor(p.length / spacing))
	local prevTops: { Vector3 }? = nil
	for i = 0, n do
		local x, z, dx, dz = Geo.sample(p, p.length * i / n)
		local y = ctx:GroundY(x, z)
		local lean = if ctx:Chance(o.leanChance or 0.15) then ctx:Range(-0.25, 0.25) else ctx:Range(-0.03, 0.03)
		local downed = ctx:Chance(o.downChance or 0)
		local yaw = math.atan2(-dx, -dz)
		local base = CFrame.new(x, y, z) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, if downed then 1.45 else lean)
		ctx:Part({
			Name = "Pole",
			Parent = model,
			Shape = "Cylinder",
			Size = Vector3.new(h, 0.8, 0.8),
			CFrame = base * CFrame.new(0, h / 2 - 1, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Material = M.Wood,
			Color = rgb(82, 66, 50),
		})
		if downed then
			prevTops = nil
			continue
		end
		ctx:Part({
			Name = "CrossArm",
			Parent = model,
			Size = Vector3.new(5, 0.4, 0.4),
			CFrame = base * CFrame.new(0, h - 2.4, 0),
			Material = M.Wood,
			Color = rgb(82, 66, 50),
			CastShadow = false,
		})
		local tops = { (base * CFrame.new(-2.1, h - 2.1, 0)).Position, (base * CFrame.new(2.1, h - 2.1, 0)).Position }
		if prevTops then
			for k = 1, 2 do
				local a, b = prevTops[k], tops[k]
				-- two-segment sag
				local mid = (a + b) / 2 - Vector3.new(0, 1.4, 0)
				for _, pair in { { a, mid }, { mid, b } } do
					local cf, len = Core.Between(pair[1], pair[2])
					ctx:Part({
						Name = "Wire",
						Parent = model,
						Size = Vector3.new(0.08, 0.08, len),
						CFrame = cf,
						Material = M.Metal,
						Color = rgb(40, 40, 40),
						Jitter = 0,
						CanCollide = false,
						CanQuery = false,
						CastShadow = false,
					})
				end
			end
		end
		prevTops = tops
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Street furniture
---------------------------------------------------------------------------------------------------

-- Cast-iron street lamp. opts.lit adds a dim warm PointLight (use sparingly).
function Props.LampPost(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("LampPost", folder(ctx, o))
	local iron = rgb(40, 42, 40)
	ctx:Part({
		Name = "Post",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(11, 0.5, 0.5),
		CFrame = base * CFrame.new(0, 5.5, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = M.Metal,
		Color = iron,
	})
	ctx:Part({
		Name = "Arm",
		Parent = model,
		Size = Vector3.new(0.3, 0.3, 2.2),
		CFrame = base * CFrame.new(0, 10.6, -1),
		Material = M.Metal,
		Color = iron,
		CastShadow = false,
	})
	local lamp = ctx:Part({
		Name = "Lamp",
		Parent = model,
		Size = Vector3.new(1, 1.3, 1),
		CFrame = base * CFrame.new(0, 10, -2),
		Material = if o.lit then M.Neon else M.Glass,
		Color = if o.lit then rgb(255, 200, 130) else rgb(60, 60, 54),
		Jitter = 0,
		CastShadow = false,
	})
	if o.lit then
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 190, 120)
		light.Range = 18
		light.Brightness = 0.8
		light.Shadows = false
		light.Parent = lamp
	end
	return model
end

function Props.Bench(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("Bench", folder(ctx, o))
	ctx:Part({
		Name = "Seat",
		Parent = model,
		Size = Vector3.new(6, 0.3, 1.6),
		CFrame = base * CFrame.new(0, 1.8, 0),
		Material = M.WoodPlanks,
		Color = WOOD,
		Destructible = true,
	})
	ctx:Part({
		Name = "Back",
		Parent = model,
		Size = Vector3.new(6, 1.4, 0.25),
		CFrame = base * CFrame.new(0, 2.9, 0.8) * CFrame.Angles(math.rad(-10), 0, 0),
		Material = M.WoodPlanks,
		Color = WOOD,
		Destructible = true,
		CastShadow = false,
	})
	for _, sx in { -1, 1 } do
		ctx:Part({
			Name = "Leg",
			Parent = model,
			Size = Vector3.new(0.3, 1.8, 1.4),
			CFrame = base * CFrame.new(sx * 2.6, 0.9, 0),
			Material = M.Metal,
			Color = rgb(40, 40, 40),
			CastShadow = false,
		})
	end
	return model
end

function Props.Signpost(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("Signpost", folder(ctx, o))
	ctx:Part({
		Name = "Post",
		Parent = model,
		Size = Vector3.new(0.4, 8, 0.4),
		CFrame = base * CFrame.new(0, 4, 0),
		Material = M.Wood,
		Color = DARK_WOOD,
		CastShadow = false,
	})
	for i = 1, o.arms or 2 do
		ctx:Part({
			Name = "Sign",
			Parent = model,
			Size = Vector3.new(4.5, 0.8, 0.15),
			CFrame = base * CFrame.Angles(0, ctx:Range(0, 6.28), 0) * CFrame.new(2, 7.4 - i, 0),
			Material = M.WoodPlanks,
			Color = rgb(200, 190, 160),
			CastShadow = false,
		})
	end
	return model
end

-- Town-square fountain with a basin of water (ruined fountains are dry and cracked).
function Props.Fountain(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local model = ctx:Model("Fountain", folder(ctx, o))
	local r = o.radius or 7
	local stone = o.color or rgb(150, 144, 132)
	for i = 0, 7 do
		local a = i * math.pi / 4
		if o.ruined and ctx:Chance(0.3) then
			continue
		end
		ctx:Part({
			Name = "Rim",
			Parent = model,
			Size = Vector3.new(r * 0.8, 2.4, 1.2),
			CFrame = base * CFrame.Angles(0, a, 0) * CFrame.new(0, 1.2, -r + 0.6),
			Material = M.Limestone,
			Color = stone,
			Destructible = true,
		})
	end
	ctx:Part({
		Name = "Basin",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(0.6, r * 2 - 1, r * 2 - 1),
		CFrame = base * CFrame.new(0, 0.3, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = M.Limestone,
		Color = stone:Lerp(rgb(60, 60, 60), 0.2),
	})
	if not o.ruined then
		ctx:Part({
			Name = "Water",
			Parent = model,
			Shape = "Cylinder",
			Size = Vector3.new(0.2, r * 2 - 2, r * 2 - 2),
			CFrame = base * CFrame.new(0, 1.6, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Material = M.Glass,
			Color = rgb(60, 80, 80),
			Transparency = 0.35,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		})
	end
	ctx:Part({
		Name = "Column",
		Parent = model,
		Size = Vector3.new(1.6, if o.ruined then 3.5 else 7, 1.6),
		CFrame = base * CFrame.new(0, if o.ruined then 1.75 else 3.5, 0),
		Material = M.Limestone,
		Color = stone,
	})
	if not o.ruined then
		ctx:Part({
			Name = "Bowl",
			Parent = model,
			Shape = "Cylinder",
			Size = Vector3.new(0.8, 4, 4),
			CFrame = base * CFrame.new(0, 6, 0) * CFrame.Angles(0, 0, math.pi / 2),
			Material = M.Limestone,
			Color = stone,
		})
	end
	return model
end

-- Canvas tent (HQ, field hospital). opts.size Vector3 (10, 7, 14), opts.color
function Props.Tent(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local size: Vector3 = o.size or Vector3.new(10, 7, 14)
	local model = ctx:Model("Tent", folder(ctx, o))
	local canvas = o.color or ctx:Pick({ rgb(96, 98, 70), rgb(110, 104, 80), rgb(86, 90, 66) })
	local half = size.X / 2
	local slope = math.sqrt(half * half + size.Y * size.Y)
	local ang = math.atan2(size.Y, half)
	for _, sx in { -1, 1 } do
		ctx:Part({
			Name = "Canvas",
			Parent = model,
			Size = Vector3.new(slope, 0.2, size.Z),
			CFrame = base * CFrame.new(sx * half / 2, size.Y / 2, 0) * CFrame.Angles(0, 0, -sx * ang),
			Material = M.Fabric,
			Color = canvas,
			Jitter = 0.03,
		})
	end
	-- Back wall (two wedges)
	for _, sx in { -1, 1 } do
		ctx:Part({
			Name = "TentEnd",
			Parent = model,
			Shape = "Wedge",
			Size = Vector3.new(0.2, size.Y, half),
			CFrame = Core.WedgeCF((base * CFrame.new(sx * half / 2, size.Y / 2, size.Z / 2)).Position, base:VectorToWorldSpace(Vector3.new(-sx, 0, 0))),
			Material = M.Fabric,
			Color = canvas,
			CastShadow = false,
		})
	end
	ctx:Part({
		Name = "Ridgepole",
		Parent = model,
		Size = Vector3.new(0.3, 0.3, size.Z + 1),
		CFrame = base * CFrame.new(0, size.Y, 0),
		Material = M.Wood,
		Color = DARK_WOOD,
		CastShadow = false,
	})
	if o.table ~= false then
		ctx:Part({
			Name = "FieldTable",
			Parent = model,
			Size = Vector3.new(3, 2.8, 5),
			CFrame = base * CFrame.new(0, 1.4, 2),
			Material = M.Wood,
			Color = WOOD,
		})
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Wrecks
---------------------------------------------------------------------------------------------------

--[[
	Props.Wreck(ctx, cf, opts) -> Model — burnt-out vehicle hull (hard cover, NoBulletPenetration).
	opts.kind: "tank" (default) | "truck" | "car" | "halftrack"; opts.burning adds a small fire.
]]
function Props.Wreck(ctx: any, at: any, opts: { [string]: any }?): Model
	local o = opts or {}
	local base = place(ctx, at, o)
	local kind = o.kind or "tank"
	local model = ctx:Model("Wreck_" .. kind, folder(ctx, o))
	local burnt = ctx:Pick({ rgb(52, 46, 42), rgb(66, 54, 44), rgb(58, 56, 50) })
	local paint = o.color or ctx:Pick({ rgb(70, 74, 58), rgb(92, 88, 70), rgb(62, 66, 60) })
	local hullColor = burnt:Lerp(paint, 0.35)
	local tilt = CFrame.Angles(ctx:Range(-0.06, 0.06), 0, ctx:Range(-0.08, 0.08))
	local function box(name, size, offset, color, mat)
		return ctx:Part({
			Name = name,
			Parent = model,
			Size = size,
			CFrame = base * tilt * offset,
			Material = mat or M.CorrodedMetal,
			Color = color or hullColor,
			NoPenetration = true,
		})
	end
	if kind == "tank" then
		box("Hull", Vector3.new(9, 3, 17), CFrame.new(0, 2.6, 0))
		box("Glacis", Vector3.new(8.6, 2, 4), CFrame.new(0, 3.2, -8.4) * CFrame.Angles(math.rad(-35), 0, 0))
		for _, sx in { -1, 1 } do
			box("Track", Vector3.new(2.4, 3.2, 18), CFrame.new(sx * 5.3, 1.6, 0), rgb(40, 38, 36), M.DiamondPlate)
		end
		if not o.noTurret then
			local yaw = ctx:Range(-1.2, 1.2)
			local turretOff = if ctx:Chance(0.3) then CFrame.new(ctx:Range(-6, 6), 0.8, ctx:Range(6, 10)) else CFrame.new(0, 0, 0)
			local tcf = CFrame.new(0, 5.4, 1) * turretOff * CFrame.Angles(0, yaw, 0)
			box("Turret", Vector3.new(6.4, 2.6, 7), tcf)
			box("Gun", Vector3.new(0.6, 0.6, 9), tcf * CFrame.new(0, 0.2, -7.4) * CFrame.Angles(ctx:Range(-0.2, 0.05), 0, 0), rgb(40, 38, 36), M.Metal)
		end
	elseif kind == "truck" or kind == "halftrack" then
		box("Chassis", Vector3.new(6.4, 1.2, 18), CFrame.new(0, 2, 0), rgb(40, 38, 36))
		box("Cab", Vector3.new(6.4, 4.2, 5), CFrame.new(0, 4.6, -5.5))
		box("Bonnet", Vector3.new(5, 2.6, 4), CFrame.new(0, 3.8, -9.5))
		box("Bed", Vector3.new(6.8, 2.2, 10), CFrame.new(0, 3.6, 3.8), burnt)
		if kind == "halftrack" then
			for _, sx in { -1, 1 } do
				box("Track", Vector3.new(1.8, 2.6, 9), CFrame.new(sx * 3, 1.3, 3), rgb(40, 38, 36), M.DiamondPlate)
			end
		else
			for _, z in { -8, 5 } do
				for _, sx in { -1, 1 } do
					if ctx:Chance(0.75) then
						ctx:Part({
							Name = "Wheel",
							Parent = model,
							Shape = "Cylinder",
							Size = Vector3.new(1.2, 3.4, 3.4),
							CFrame = base * tilt * CFrame.new(sx * 3.2, 1.6, z),
							Material = M.Rubber,
							Color = rgb(30, 30, 30),
							CastShadow = false,
						})
					end
				end
			end
		end
	else -- car
		box("Body", Vector3.new(5.6, 2.2, 12), CFrame.new(0, 2, 0))
		box("Cabin", Vector3.new(5, 2, 6), CFrame.new(0, 4, 1))
	end
	if o.burning then
		Props.Fire(ctx, (base * CFrame.new(0, 3, 0)).Position, { size = 4, snap = false, parent = model, light = false })
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Fire & smoke (use sparingly: each adds particles + an optional light)
---------------------------------------------------------------------------------------------------

--[[
	Props.Fire(ctx, pos, opts) -> Part (invisible anchor with Fire, Smoke and PointLight)
	opts: size (6), smoke (true), light (true), snap (true)
]]
function Props.Fire(ctx: any, at: any, opts: { [string]: any }?): BasePart
	local o = opts or {}
	local cf = place(ctx, at, o)
	local size = o.size or 6
	local anchor = ctx:Part({
		Name = "FireSource",
		Parent = folder(ctx, o, "Effects"),
		Size = Vector3.new(size * 0.6, 0.4, size * 0.6),
		CFrame = cf * CFrame.new(0, 0.3, 0),
		Material = M.Basalt,
		Color = rgb(30, 26, 24),
		Transparency = 0,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	})
	local fire = Instance.new("Fire")
	fire.Size = size
	fire.Heat = size * 1.5
	fire.Color = rgb(255, 130, 50)
	fire.SecondaryColor = rgb(255, 60, 20)
	fire.Parent = anchor
	if o.smoke ~= false then
		local smoke = Instance.new("Smoke")
		smoke.Color = rgb(40, 38, 36)
		smoke.Opacity = 0.18
		smoke.RiseVelocity = 6
		smoke.Size = size * 1.6
		smoke.Parent = anchor
	end
	if o.light ~= false then
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 140, 70)
		light.Range = size * 4
		light.Brightness = 1.2
		light.Shadows = false
		light.Parent = anchor
	end
	return anchor
end

---------------------------------------------------------------------------------------------------
-- Rubble & debris
---------------------------------------------------------------------------------------------------

--[[
	Props.RubblePile(ctx, pos, opts) -> Model
	Terrain rubble mound (zero parts) plus a few brick/plank/slab parts on top for detail.
	opts: radius (6), height (3), materials (terrain), pieces (5), color
]]
function Props.RubblePile(ctx: any, pos: Vector3, opts: { [string]: any }?): Model
	local o = opts or {}
	local r = o.radius or 6
	Terrain.RubbleMound(ctx, pos, r, o.height or 3, o.materials)
	local model = ctx:Model("Rubble", folder(ctx, o))
	Props.Debris(ctx, pos, { radius = r * 0.8, count = o.pieces or 5, parent = model, color = o.color })
	return model
end

-- Scatter of loose bricks, planks, broken slabs and beams.
function Props.Debris(ctx: any, pos: Vector3, opts: { [string]: any }?): Instance
	local o = opts or {}
	local parent = o.parent or ctx:Model("Debris", folder(ctx, o))
	local r = o.radius or 5
	for _ = 1, o.count or 6 do
		local a = ctx:Range(0, math.pi * 2)
		local d = ctx:Range(0, r)
		local x, z = pos.X + math.cos(a) * d, pos.Z + math.sin(a) * d
		local y = ctx:SurfaceY(x, z)
		local kind = ctx.rng:NextNumber()
		local size, mat, color
		if kind < 0.35 then
			size = Vector3.new(ctx:Range(1, 2.4), ctx:Range(0.6, 1.2), ctx:Range(1, 2))
			mat, color = M.Brick, o.color or rgb(132, 80, 62)
		elseif kind < 0.6 then
			size = Vector3.new(0.5, 0.5, ctx:Range(4, 9))
			mat, color = M.Wood, rgb(64, 50, 38)
		elseif kind < 0.85 then
			size = Vector3.new(ctx:Range(3, 6), 0.6, ctx:Range(2, 4))
			mat, color = M.Concrete, o.color or rgb(120, 116, 110)
		else
			size = Vector3.new(0.3, 0.3, ctx:Range(4, 8))
			mat, color = M.CorrodedMetal, rgb(70, 56, 48)
		end
		ctx:Part({
			Name = "Debris",
			Parent = parent,
			Size = size,
			CFrame = CFrame.new(x, y + size.Y * 0.3, z) * CFrame.Angles(ctx:Range(-0.5, 0.5), ctx:Range(0, 6.28), ctx:Range(-0.5, 0.5)),
			Material = mat,
			Color = color,
			CastShadow = false,
		})
	end
	return parent
end

---------------------------------------------------------------------------------------------------
-- Bridges
---------------------------------------------------------------------------------------------------

--[[
	Props.StoneBridge(ctx, a, b, opts) -> Model
	Arched stone bridge from a to b (Vector3; Y = deck height, or nil-height snaps to the banks).
	opts: width (16), arches (2), parapet (true), damaged (false — knocks out parapet chunks)
	Note: the deck is drivable; add the road on each bank in the MaterialModel.
]]
function Props.StoneBridge(ctx: any, a: Vector3, b: Vector3, opts: { [string]: any }?): Model
	local o = opts or {}
	local width = o.width or 16
	local model = ctx:Model("StoneBridge", folder(ctx, o, "Buildings"))
	local ya = if o.snap == false then a.Y else ctx:GroundY(a.X, a.Z)
	local yb = if o.snap == false then b.Y else ctx:GroundY(b.X, b.Z)
	local deckY = math.max(ya, yb) + 0.6
	local pa, pb = Vector3.new(a.X, deckY, a.Z), Vector3.new(b.X, deckY, b.Z)
	local cf, len = Core.Between(pa, pb)
	local stone = rgb(132, 126, 114)
	ctx:Part({
		Name = "Deck",
		Parent = model,
		Size = Vector3.new(width, 2.4, len + 6),
		CFrame = cf * CFrame.new(0, -1.2, 0),
		Material = M.Cobblestone,
		Color = rgb(110, 106, 98),
		NoPenetration = true,
	})
	-- Spandrel walls under the deck and piers between arches
	local arches = o.arches or 2
	local span = len / arches
	local depth = o.depth or 14
	for i = 0, arches do
		local z = -len / 2 + i * span
		if i > 0 and i < arches then
			ctx:Part({
				Name = "Pier",
				Parent = model,
				Size = Vector3.new(width - 1, depth, 4),
				CFrame = cf * CFrame.new(0, -2.4 - depth / 2, z),
				Material = M.Cobblestone,
				Color = stone,
				NoPenetration = true,
			})
		end
	end
	for i = 0, arches - 1 do
		local zc = -len / 2 + (i + 0.5) * span
		-- arch ring approximated by a thick band below the deck with a cut look
		for _, sx in { -1, 1 } do
			ctx:Part({
				Name = "Spandrel",
				Parent = model,
				Size = Vector3.new(1, 3, span - 3),
				CFrame = cf * CFrame.new(sx * (width / 2 - 0.5), -3.9, zc),
				Material = M.Cobblestone,
				Color = stone,
				CastShadow = false,
			})
		end
	end
	if o.parapet ~= false then
		for _, sx in { -1, 1 } do
			local segs = math.max(2, math.floor((len + 6) / 6))
			for s = 0, segs - 1 do
				if o.damaged and ctx:Chance(0.25) then
					continue
				end
				local sl = (len + 6) / segs
				ctx:Part({
					Name = "Parapet",
					Parent = model,
					Size = Vector3.new(1.2, 3, sl),
					CFrame = cf * CFrame.new(sx * (width / 2 - 0.6), 1.5, -(len + 6) / 2 + (s + 0.5) * sl),
					Material = M.Cobblestone,
					Color = stone,
					Destructible = true,
				})
			end
		end
	end
	ctx:AddMinimapCF("road", cf, width, len + 6)
	return model
end

-- Simple timber footbridge/vehicle bridge from a to b on log piles.
function Props.WoodBridge(ctx: any, a: Vector3, b: Vector3, opts: { [string]: any }?): Model
	local o = opts or {}
	local width = o.width or 8
	local model = ctx:Model("WoodBridge", folder(ctx, o, "Buildings"))
	local deckY = math.max(ctx:GroundY(a.X, a.Z), ctx:GroundY(b.X, b.Z)) + 0.8
	local cf, len = Core.Between(Vector3.new(a.X, deckY, a.Z), Vector3.new(b.X, deckY, b.Z))
	ctx:Part({
		Name = "Deck",
		Parent = model,
		Size = Vector3.new(width, 0.8, len + 4),
		CFrame = cf * CFrame.new(0, -0.4, 0),
		Material = M.WoodPlanks,
		Color = WOOD,
		Destructible = o.destructible == true,
	})
	local n = math.max(1, math.floor(len / 14))
	for i = 1, n do
		local z = -len / 2 + i * len / (n + 1)
		for _, sx in { -1, 1 } do
			ctx:Part({
				Name = "Pile",
				Parent = model,
				Shape = "Cylinder",
				Size = Vector3.new(14, 1, 1),
				CFrame = cf * CFrame.new(sx * (width / 2 - 0.5), -7, z) * CFrame.Angles(0, 0, math.pi / 2),
				Material = M.Wood,
				Color = DARK_WOOD,
				CastShadow = false,
			})
			ctx:Part({
				Name = "Rail",
				Parent = model,
				Size = Vector3.new(0.3, 3, 0.3),
				CFrame = cf * CFrame.new(sx * (width / 2 - 0.2), 1.5, z),
				Material = M.Wood,
				Color = DARK_WOOD,
				CastShadow = false,
			})
		end
	end
	for _, sx in { -1, 1 } do
		ctx:Part({
			Name = "Handrail",
			Parent = model,
			Size = Vector3.new(0.3, 0.3, len + 4),
			CFrame = cf * CFrame.new(sx * (width / 2 - 0.2), 3, 0),
			Material = M.Wood,
			Color = WOOD,
			CastShadow = false,
		})
	end
	ctx:AddMinimapCF("road", cf, width, len + 4)
	return model
end

return Props
