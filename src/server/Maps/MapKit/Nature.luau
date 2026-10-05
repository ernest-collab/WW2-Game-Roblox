--[[
	MapKit.Nature — vegetation.

	Foliage parts are CanCollide = false and CanQuery = false (bullets and players pass through
	leaves; they still block sight). Trunks are solid. Tree builders take a ground position
	(Vector3, Y ignored) and return the Model.

	  Tree(ctx, pos, kind, scale)   kind: "Oak" | "Birch" | "Apple" | "Poplar" | "Pine" | "Fir" |
	                                      "Palm" | "Dead" | "Burnt"
	  Bush(ctx, pos, size)          Hedgerow(ctx, points, opts)   (Norman bocage: earth bank + hedge)
	  Forest(ctx, area, opts)       Orchard(ctx, cf, opts)        WheatField(ctx, cf, sx, sz, opts)
	  Rock(ctx, pos, size)          GrassTufts(ctx, area, count)
]]

local Geo = require(script.Parent.Geo)
local Terrain = require(script.Parent.Terrain)

local M = Enum.Material
local rgb = Color3.fromRGB

local Nature = {}

local LEAF_GREENS = { rgb(70, 92, 48), rgb(62, 84, 44), rgb(82, 100, 52), rgb(58, 78, 42), rgb(92, 104, 56) }
local PINE_GREENS = { rgb(44, 64, 44), rgb(38, 58, 40), rgb(50, 70, 46) }
local BARK = rgb(72, 58, 44)

local function trunk(
	ctx: any,
	model: Model,
	base: Vector3,
	height: number,
	radius: number,
	color: Color3?,
	lean: number?
): CFrame
	local tilt = CFrame.Angles(ctx:Range(-1, 1) * (lean or 0.05), ctx:Range(0, 6.28), ctx:Range(-1, 1) * (lean or 0.05))
	local cf = CFrame.new(base) * tilt
	ctx:Part({
		Name = "Trunk",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(height + 1, radius * 2, radius * 2),
		CFrame = cf * CFrame.new(0, height / 2 - 0.5, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = M.Wood,
		Color = color or BARK,
		Jitter = 0.08,
		CastShadow = true,
	})
	return cf * CFrame.new(0, height, 0)
end

local function blob(ctx: any, model: Model, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material?)
	ctx:Part({
		Name = "Leaves",
		Parent = model,
		Size = size,
		CFrame = cf,
		Mesh = if size.X == size.Y and size.Y == size.Z then nil else "Sphere",
		Shape = if size.X == size.Y and size.Y == size.Z then "Ball" else nil,
		Material = material or M.LeafyGrass,
		Color = color,
		Jitter = 0.08,
		CanCollide = false,
		CanQuery = false,
		CastShadow = true,
	})
end

--[[
	Nature.Tree(ctx, pos, kind, scale) -> Model
	scale ~1 (Oak ~26 studs tall). Trees are placed on the analytic ground (ctx:GroundY).
]]
function Nature.Tree(ctx: any, pos: Vector3, kind: string?, scale: number?, parent: Instance?): Model
	local k = kind or "Oak"
	local s = (scale or 1) * ctx:Range(0.85, 1.15)
	local y = ctx:GroundY(pos.X, pos.Z)
	local base = Vector3.new(pos.X, y - 0.5, pos.Z)
	local model = ctx:Model(k .. "Tree", parent or ctx:Folder("Nature"))
	local green = ctx:Pick(LEAF_GREENS)

	if k == "Oak" or k == "Apple" or k == "Birch" then
		local h = (if k == "Apple" then 6 elseif k == "Birch" then 16 else 12) * s
		local r = (if k == "Apple" then 0.6 elseif k == "Birch" then 0.6 else 1.1) * s
		local barkColor = if k == "Birch" then rgb(196, 192, 182) else BARK
		local top = trunk(ctx, model, base, h, r, barkColor, 0.06)
		local crown = (if k == "Apple" then 9 elseif k == "Birch" then 9 else 16) * s
		local n = if k == "Apple" then 2 else 3
		blob(ctx, model, top * CFrame.new(0, crown * 0.15, 0), Vector3.new(crown, crown * 0.8, crown), green)
		for _ = 2, n do
			local off = Vector3.new(
				ctx:Range(-0.35, 0.35) * crown,
				ctx:Range(-0.1, 0.3) * crown,
				ctx:Range(-0.35, 0.35) * crown
			)
			local c = crown * ctx:Range(0.55, 0.75)
			blob(ctx, model, top * CFrame.new(off), Vector3.new(c, c * 0.85, c), ctx:Jitter(green, 0.1))
		end
		if k == "Apple" and ctx:Chance(0.6) then
			blob(
				ctx,
				model,
				top * CFrame.new(0, crown * 0.1, 0),
				Vector3.new(crown * 1.02, crown * 0.6, crown * 1.02),
				rgb(150, 60, 40),
				M.Grass
			)
		end
	elseif k == "Poplar" then
		local top = trunk(ctx, model, base, 6 * s, 0.7 * s, BARK, 0.02)
		blob(ctx, model, top * CFrame.new(0, 10 * s, 0), Vector3.new(7 * s, 26 * s, 7 * s), green)
	elseif k == "Pine" or k == "Fir" then
		local h = (if k == "Pine" then 26 else 20) * s
		local cf = trunk(ctx, model, base, h, 0.8 * s, rgb(84, 62, 46), 0.03) * CFrame.new(0, -h, 0)
		local col = ctx:Pick(PINE_GREENS)
		local tiers = if k == "Pine" then 3 else 4
		local startY = if k == "Pine" then h * 0.55 else h * 0.2
		for i = 0, tiers - 1 do
			local t = i / tiers
			local w = (if k == "Pine" then 10 else 13) * s * (1 - t * 0.65)
			local ty = startY + (h - startY) * t
			blob(
				ctx,
				model,
				cf * CFrame.new(0, ty + w * 0.3, 0),
				Vector3.new(w, w * 0.9, w),
				ctx:Jitter(col, 0.06),
				M.Grass
			)
		end
	elseif k == "Palm" then
		local h = 22 * s
		local lean = ctx:Range(0.1, 0.3)
		local yaw = ctx:Range(0, 6.28)
		local segs = 3
		local cf = CFrame.new(base) * CFrame.Angles(0, yaw, 0)
		for i = 1, segs do
			local segH = h / segs
			cf = cf * CFrame.Angles(lean / segs * i * 0.6, 0, 0)
			ctx:Part({
				Name = "Trunk",
				Parent = model,
				Shape = "Cylinder",
				Size = Vector3.new(segH + 0.6, (1.3 - i * 0.15) * s, (1.3 - i * 0.15) * s),
				CFrame = cf * CFrame.new(0, segH / 2, 0) * CFrame.Angles(0, 0, math.pi / 2),
				Material = M.Wood,
				Color = rgb(120, 100, 76),
				Jitter = 0.05,
			})
			cf = cf * CFrame.new(0, segH, 0)
		end
		for i = 0, 6 do
			local a = i * math.pi * 2 / 7 + ctx:Range(-0.2, 0.2)
			local frond = cf
				* CFrame.Angles(0, a, 0)
				* CFrame.Angles(math.rad(ctx:Range(15, 35)), 0, 0)
				* CFrame.new(0, 0, -5 * s)
			ctx:Part({
				Name = "Frond",
				Parent = model,
				Size = Vector3.new(2.6 * s, 0.2, 10 * s),
				CFrame = frond,
				Material = M.Grass,
				Color = ctx:Jitter(rgb(84, 112, 50), 0.1),
				CanCollide = false,
				CanQuery = false,
				CastShadow = true,
			})
		end
	else -- Dead / Burnt: bare trunk with a few broken branches
		local burnt = k == "Burnt"
		local h = 14 * s
		local col = if burnt then rgb(36, 32, 30) else rgb(96, 84, 70)
		local top = trunk(ctx, model, base, h * (if burnt then ctx:Range(0.5, 1) else 1), 0.9 * s, col, 0.12)
		for _ = 1, ctx:Int(2, 4) do
			local yOff = -ctx:Range(1, h * 0.5)
			local len = ctx:Range(3, 7) * s
			ctx:Part({
				Name = "Branch",
				Parent = model,
				Size = Vector3.new(0.4 * s, len, 0.4 * s),
				CFrame = top
					* CFrame.new(0, yOff, 0)
					* CFrame.Angles(ctx:Range(0.5, 1.1), ctx:Range(0, 6.28), 0)
					* CFrame.new(0, len / 2, 0),
				Material = M.Wood,
				Color = col,
				CastShadow = false,
			})
		end
	end
	ctx:Step(2)
	return model
end

-- Leafy bush (1-2 blobs). size ~4..8
function Nature.Bush(ctx: any, pos: Vector3, size: number?, parent: Instance?): Model
	local s = size or ctx:Range(4, 7)
	local y = ctx:GroundY(pos.X, pos.Z)
	local model = ctx:Model("Bush", parent or ctx:Folder("Nature"))
	local green = ctx:Pick(LEAF_GREENS)
	blob(ctx, model, CFrame.new(pos.X, y + s * 0.3, pos.Z), Vector3.new(s, s * 0.75, s * 1.2), green)
	if s > 5 and ctx:Chance(0.6) then
		blob(
			ctx,
			model,
			CFrame.new(pos.X + s * 0.4, y + s * 0.2, pos.Z + ctx:Range(-1, 1)),
			Vector3.new(s * 0.7, s * 0.6, s * 0.7),
			ctx:Jitter(green, 0.1)
		)
	end
	return model
end

--[[
	Nature.Hedgerow(ctx, points, opts) -> Model — Norman bocage.
	An earth bank (terrain berm) topped by a dense hedge wall with an irregular crown and the odd tree.
	Bocage hedges are thick: the hedge body blocks movement and bullets (only the crown blobs are
	non-colliding). Use `gaps` to cut openings for lanes and field gates.
	opts: height (9), width (5), bank (true), bankHeight (2.5), treeChance (0.12), gapChance (0.04),
	      gaps = { {x, z, radius} } hard openings, skip = function(x, z) -> boolean (e.g. near roads),
	      minimap (true)
]]
function Nature.Hedgerow(ctx: any, points: { any }, opts: { [string]: any }?): Model
	local o = opts or {}
	local h = o.height or 9
	local w = o.width or 5
	local bankH = if o.bank == false then 0 else (o.bankHeight or 2.5)
	local model = ctx:Model("Hedgerow", o.parent or ctx:Folder("Nature"))
	local seg = o.segment or 14
	local gaps = o.gaps or {}
	local function inGap(x, z)
		for _, g in gaps do
			if (x - g[1]) ^ 2 + (z - g[2]) ^ 2 < g[3] * g[3] then
				return true
			end
		end
		return false
	end
	local base = ctx:Pick(LEAF_GREENS):Lerp(rgb(40, 56, 34), 0.35)
	for i = 1, #points - 1 do
		local ax, az = Geo.xz(points[i])
		local bx, bz = Geo.xz(points[i + 1])
		local len = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
		local steps = math.max(1, math.ceil(len / seg))
		for s = 0, steps - 1 do
			local t0, t1 = s / steps, (s + 1) / steps
			local x0, z0 = Geo.lerp(ax, bx, t0), Geo.lerp(az, bz, t0)
			local x1, z1 = Geo.lerp(ax, bx, t1), Geo.lerp(az, bz, t1)
			local mx, mz = (x0 + x1) / 2, (z0 + z1) / 2
			if inGap(mx, mz) or (o.skip and o.skip(mx, mz)) or ctx:Chance(o.gapChance or 0.04) then
				continue
			end
			if bankH > 0 then
				Terrain.Berm(
					ctx,
					{ Vector3.new(x0, 0, z0), Vector3.new(x1, 0, z1) },
					w + 4,
					bankH,
					o.bankMaterial or M.LeafyGrass
				)
			end
			local y = math.min(ctx:GroundY(x0, z0), ctx:GroundY(x1, z1)) + bankH * 0.6
			local hh = h * ctx:Range(0.85, 1.15)
			local cf = CFrame.lookAt(Vector3.new(mx, y + hh / 2 - 1, mz), Vector3.new(x1, y + hh / 2 - 1, z1))
			ctx:Part({
				Name = "Hedge",
				Parent = model,
				Size = Vector3.new(w * ctx:Range(0.85, 1.1), hh, len / steps + 1.5),
				CFrame = cf,
				Material = M.LeafyGrass,
				Color = ctx:Jitter(base, 0.12),
				Jitter = 0,
				CastShadow = true,
			})
			-- irregular crown blob
			if ctx:Chance(0.7) then
				local c = w * ctx:Range(1.1, 1.6)
				blob(
					ctx,
					model,
					cf * CFrame.new(ctx:Range(-0.5, 0.5), hh / 2, ctx:Range(-3, 3)),
					Vector3.new(c, c * 0.7, len / steps * 0.8),
					ctx:Jitter(base, 0.15)
				)
			end
			if ctx:Chance(o.treeChance or 0.12) then
				Nature.Tree(
					ctx,
					Vector3.new(mx, 0, mz),
					ctx:Pick({ "Oak", "Oak", "Poplar" }),
					ctx:Range(0.9, 1.2),
					model
				)
			end
		end
	end
	if o.minimap ~= false then
		ctx:AddMinimapPath("forest", points, w + 2)
	end
	return model
end

--[[
	Nature.Forest(ctx, area, opts) -> Model
	area: { center = Vector3, size = Vector2, rot = degrees } (rectangle) or { polygon = {points} }
	opts: kinds = {"Oak","Pine"} (weighted list), spacing (14), count (auto from area/spacing),
	      bushes (0.5 = bushes per tree), avoid = { {x, z, r} }, filter(x, z) -> boolean, scale (1),
	      minimap (true)
]]
function Nature.Forest(ctx: any, area: { [string]: any }, opts: { [string]: any }?): Model
	local o = opts or {}
	local Layout = require(script.Parent.Layout) :: any
	local model = ctx:Model(o.name or "Forest", o.parent or ctx:Folder("Nature"))
	local kinds = o.kinds or { "Oak", "Oak", "Birch" }
	local spacing = o.spacing or 14
	local points = Layout.Scatter(ctx, area, { spacing = spacing, count = o.count, avoid = o.avoid, filter = o.filter })
	for _, p in points do
		Nature.Tree(ctx, p, ctx:Pick(kinds), o.scale, model)
		if ctx:Chance(o.bushes or 0.5) then
			Nature.Bush(ctx, p + Vector3.new(ctx:Range(-6, 6), 0, ctx:Range(-6, 6)), nil, model)
		end
	end
	if o.minimap ~= false then
		if area.polygon then
			local pth = Geo.path(area.polygon)
			ctx:AddMinimap(
				"forest",
				(pth.minX + pth.maxX) / 2,
				(pth.minZ + pth.maxZ) / 2,
				pth.maxX - pth.minX,
				pth.maxZ - pth.minZ,
				0
			)
		else
			ctx:AddMinimap("forest", area.center.X, area.center.Z, area.size.X, area.size.Y, area.rot or 0)
		end
	end
	return model
end

--[[
	Nature.Orchard(ctx, cf, opts) -> Model — rows of apple trees (Normandy cider orchards).
	cf = centre on the ground, rows along cf local X. opts: rows (4), cols (6), spacing (14), kind ("Apple")
]]
function Nature.Orchard(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local rows, cols = o.rows or 4, o.cols or 6
	local sp = o.spacing or 14
	local model = ctx:Model("Orchard", o.parent or ctx:Folder("Nature"))
	for r = 1, rows do
		for c = 1, cols do
			if ctx:Chance(o.missing or 0.1) then
				continue
			end
			local p = cf
				* Vector3.new(
					(c - (cols + 1) / 2) * sp + ctx:Range(-1.5, 1.5),
					0,
					(r - (rows + 1) / 2) * sp + ctx:Range(-1.5, 1.5)
				)
			Nature.Tree(ctx, p, o.kind or "Apple", ctx:Range(0.9, 1.15), model)
		end
	end
	ctx:AddMinimapCF("forest", cf, cols * sp, rows * sp)
	return model
end

--[[
	Nature.WheatField(ctx, cf, sx, sz, opts) -> Model
	Tall crop rows as long low strips (players can walk/go prone through them; they block sight).
	Rows run along cf local Z; strips are split into ~32-stud pieces that follow the terrain.
	opts: rowSpacing (5), height (3.2), color, harvested (false: short stubble strips instead),
	      minimap (true)
]]
function Nature.WheatField(ctx: any, cf: CFrame, sx: number, sz: number, opts: { [string]: any }?): Model
	local o = opts or {}
	local model = ctx:Model("WheatField", o.parent or ctx:Folder("Nature"))
	local rowSpacing = o.rowSpacing or 5
	local h = if o.harvested then 0.8 else (o.height or 3.2)
	local color = o.color or (if o.harvested then rgb(160, 140, 96) else rgb(196, 168, 96))
	local piece = o.piece or 32
	local nRows = math.floor(sx / rowSpacing)
	local nPieces = math.max(1, math.ceil(sz / piece))
	local pl = sz / nPieces
	for r = 0, nRows - 1 do
		local lx = -sx / 2 + (r + 0.5) * rowSpacing
		for p = 0, nPieces - 1 do
			if ctx:Chance(o.gapChance or 0.04) then
				continue
			end
			local z0, z1 = -sz / 2 + p * pl, -sz / 2 + (p + 1) * pl
			local a, b = cf * Vector3.new(lx, 0, z0), cf * Vector3.new(lx, 0, z1)
			local ya, yb = ctx:GroundY(a.X, a.Z), ctx:GroundY(b.X, b.Z)
			local pa, pb = Vector3.new(a.X, ya + h / 2 - 0.3, a.Z), Vector3.new(b.X, yb + h / 2 - 0.3, b.Z)
			ctx:Part({
				Name = "Crop",
				Parent = model,
				Size = Vector3.new(rowSpacing * 0.7, h, (pb - pa).Magnitude + 0.5),
				CFrame = CFrame.lookAt((pa + pb) / 2, pb),
				Material = M.Grass,
				Color = color,
				Jitter = 0.05,
				CanCollide = false,
				CanQuery = false,
				CastShadow = false,
			})
		end
	end
	if o.minimap ~= false then
		ctx:AddMinimapCF("field", cf, sx, sz)
	end
	return model
end

-- Boulder: terrain rock ball + optional part rock for a crisp silhouette.
function Nature.Rock(ctx: any, pos: Vector3, size: number?, material: Enum.Material?)
	local s = size or ctx:Range(3, 8)
	local y = ctx:GroundY(pos.X, pos.Z)
	workspace.Terrain:FillBall(Vector3.new(pos.X, y + s * 0.15, pos.Z), s * 0.6, material or M.Rock)
	ctx:Step(1)
end

-- Grass/weed tufts (very cheap clutter, non-colliding).
function Nature.GrassTufts(ctx: any, center: Vector3, radius: number, count: number, color: Color3?)
	local model = ctx:Model("Tufts", ctx:Folder("Nature"))
	for _ = 1, count do
		local a, d = ctx:Range(0, 6.28), ctx:Range(0, radius)
		local x, z = center.X + math.cos(a) * d, center.Z + math.sin(a) * d
		local y = ctx:GroundY(x, z)
		local s = ctx:Range(1.5, 3)
		ctx:Part({
			Name = "Tuft",
			Parent = model,
			Size = Vector3.new(s, s * 0.7, s),
			CFrame = CFrame.new(x, y + s * 0.2, z),
			Mesh = "Sphere",
			Material = M.Grass,
			Color = color or rgb(110, 116, 66),
			Jitter = 0.1,
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		})
	end
	return model
end

return Nature
