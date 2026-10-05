--[[
	MapKit.Buildings — procedural WWII-era buildings.

	Every builder takes (ctx, cf, opts) where `cf` is a CFrame on the ground at the centre of the
	footprint; the building FRONT faces cf.LookVector (local -Z). Buildings are snapped to the
	terrain (floor placed on the highest footprint corner, foundation sunk below the lowest), add a
	"building" minimap shape and return the Model.

	Common opts:
	  style     : key of Buildings.Styles ("Norman", "NormanStone", "Brick", "Soviet", "SovietBrick",
	              "Mediterranean", "Timber", "Log", "Farm") or a style table
	  ruin      : 0 (intact) .. 1 (shell). Jagged wall tops, holes, collapsed floors/roof, rubble.
	  enterable : true => open doors/windows, floors with stair ramps, furniture.
	              false => solid walls with window panes (cheaper; use for background buildings).
	  snap      : default true — snap to terrain height.

	Walls are built in chunks tagged "Destructible" so DestructionService can blow holes in them.

	Builders: House, Farmhouse, Barn, Church, Apartment, FactoryHall, Chimney, Hut, Shed,
	          Windmill, RuinedWall, StoneHouse (Mediterranean preset), Wall (low-level).
]]

local Core = require(script.Parent.Core)
local Geo = require(script.Parent.Geo)
local Terrain = require(script.Parent.Terrain)

local M = Enum.Material
local rgb = Color3.fromRGB

local Buildings = {}

---------------------------------------------------------------------------------------------------
-- Styles
---------------------------------------------------------------------------------------------------

export type Style = {
	wall: Enum.Material,
	wallColors: { Color3 },
	base: Enum.Material,
	baseColor: Color3,
	trim: Enum.Material,
	trimColor: Color3,
	roof: Enum.Material,
	roofColors: { Color3 },
	pitch: number, -- roof pitch degrees
	floor: Enum.Material,
	floorColor: Color3,
	pane: Color3,
	shutterColors: { Color3 }?,
	rubble: { Enum.Material },
}

Buildings.Styles = {
	Norman = {
		wall = M.Plaster,
		wallColors = { rgb(204, 194, 168), rgb(190, 180, 156), rgb(184, 172, 150), rgb(198, 186, 160) },
		base = M.Cobblestone,
		baseColor = rgb(112, 106, 96),
		trim = M.Wood,
		trimColor = rgb(72, 54, 38),
		roof = M.Slate,
		roofColors = { rgb(72, 74, 78), rgb(62, 64, 70), rgb(84, 80, 78) },
		pitch = 42,
		floor = M.WoodPlanks,
		floorColor = rgb(112, 86, 60),
		pane = rgb(36, 40, 44),
		shutterColors = { rgb(72, 92, 72), rgb(96, 62, 50), rgb(78, 88, 108), rgb(110, 100, 80) },
		rubble = { M.Slate, M.Cobblestone, M.Concrete, M.Ground },
	},
	NormanStone = {
		wall = M.Limestone,
		wallColors = { rgb(170, 160, 138), rgb(156, 146, 124), rgb(176, 166, 146) },
		base = M.Cobblestone,
		baseColor = rgb(104, 98, 90),
		trim = M.Wood,
		trimColor = rgb(66, 50, 36),
		roof = M.Slate,
		roofColors = { rgb(66, 68, 72), rgb(78, 76, 74) },
		pitch = 45,
		floor = M.WoodPlanks,
		floorColor = rgb(104, 80, 56),
		pane = rgb(34, 38, 40),
		shutterColors = { rgb(70, 84, 70), rgb(92, 70, 52) },
		rubble = { M.Limestone, M.Cobblestone, M.Rock, M.Ground },
	},
	Brick = {
		wall = M.Brick,
		wallColors = { rgb(140, 84, 66), rgb(124, 74, 58), rgb(150, 96, 74) },
		base = M.Concrete,
		baseColor = rgb(110, 106, 100),
		trim = M.Concrete,
		trimColor = rgb(170, 162, 146),
		roof = M.ClayRoofTiles,
		roofColors = { rgb(122, 64, 48), rgb(108, 58, 44) },
		pitch = 38,
		floor = M.WoodPlanks,
		floorColor = rgb(104, 80, 56),
		pane = rgb(34, 38, 42),
		rubble = { M.Brick, M.Concrete, M.Ground },
	},
	Soviet = {
		wall = M.Plaster,
		wallColors = { rgb(176, 158, 118), rgb(160, 150, 134), rgb(150, 140, 126), rgb(182, 168, 140) },
		base = M.Concrete,
		baseColor = rgb(96, 94, 90),
		trim = M.Concrete,
		trimColor = rgb(130, 126, 118),
		roof = M.Concrete,
		roofColors = { rgb(90, 88, 84) },
		pitch = 0,
		floor = M.Concrete,
		floorColor = rgb(118, 114, 108),
		pane = rgb(30, 32, 34),
		rubble = { M.Concrete, M.Brick, M.Slate, M.Rock },
	},
	SovietBrick = {
		wall = M.Brick,
		wallColors = { rgb(128, 72, 58), rgb(112, 66, 54), rgb(136, 86, 68) },
		base = M.Concrete,
		baseColor = rgb(94, 92, 88),
		trim = M.Concrete,
		trimColor = rgb(140, 134, 124),
		roof = M.Concrete,
		roofColors = { rgb(84, 82, 80) },
		pitch = 0,
		floor = M.Concrete,
		floorColor = rgb(112, 108, 102),
		pane = rgb(30, 32, 34),
		rubble = { M.Brick, M.Concrete, M.Rock },
	},
	Mediterranean = {
		wall = M.Plaster,
		wallColors = { rgb(216, 200, 164), rgb(224, 212, 184), rgb(200, 176, 136), rgb(210, 190, 150) },
		base = M.Sandstone,
		baseColor = rgb(170, 142, 106),
		trim = M.Wood,
		trimColor = rgb(92, 66, 44),
		roof = M.ClayRoofTiles,
		roofColors = { rgb(168, 92, 62), rgb(152, 84, 58), rgb(176, 104, 70) },
		pitch = 22,
		floor = M.CeramicTiles,
		floorColor = rgb(160, 110, 80),
		pane = rgb(40, 40, 40),
		shutterColors = { rgb(64, 96, 84), rgb(70, 92, 120), rgb(110, 84, 56) },
		rubble = { M.Sandstone, M.Limestone, M.Ground },
	},
	Timber = {
		wall = M.WoodPlanks,
		wallColors = { rgb(104, 80, 56), rgb(92, 72, 52), rgb(116, 90, 62) },
		base = M.Cobblestone,
		baseColor = rgb(100, 96, 90),
		trim = M.Wood,
		trimColor = rgb(60, 46, 34),
		roof = M.RoofShingles,
		roofColors = { rgb(70, 62, 56), rgb(82, 72, 62) },
		pitch = 40,
		floor = M.WoodPlanks,
		floorColor = rgb(100, 78, 54),
		pane = rgb(30, 30, 30),
		rubble = { M.WoodPlanks, M.Ground },
	},
	Log = {
		wall = M.Wood,
		wallColors = { rgb(98, 74, 50), rgb(88, 66, 46), rgb(108, 82, 56) },
		base = M.Rock,
		baseColor = rgb(96, 92, 88),
		trim = M.Wood,
		trimColor = rgb(70, 52, 36),
		roof = M.Grass, -- thatch
		roofColors = { rgb(150, 128, 82), rgb(138, 118, 76), rgb(126, 110, 74) },
		pitch = 45,
		floor = M.WoodPlanks,
		floorColor = rgb(100, 76, 52),
		pane = rgb(34, 34, 32),
		shutterColors = { rgb(70, 96, 120), rgb(96, 120, 92) },
		rubble = { M.WoodPlanks, M.Ground, M.Mud },
	},
	Farm = {
		wall = M.Cobblestone,
		wallColors = { rgb(150, 140, 120), rgb(138, 128, 110), rgb(160, 150, 128) },
		base = M.Rock,
		baseColor = rgb(100, 96, 90),
		trim = M.Wood,
		trimColor = rgb(70, 52, 36),
		roof = M.Slate,
		roofColors = { rgb(76, 76, 78), rgb(90, 82, 76) },
		pitch = 44,
		floor = M.WoodPlanks,
		floorColor = rgb(104, 80, 56),
		pane = rgb(34, 36, 38),
		shutterColors = { rgb(84, 64, 50), rgb(70, 88, 70) },
		rubble = { M.Cobblestone, M.Rock, M.Ground },
	},
}

local function resolveStyle(style: any): Style
	if type(style) == "table" then
		return style
	end
	return Buildings.Styles[style or "Norman"] or Buildings.Styles.Norman
end

---------------------------------------------------------------------------------------------------
-- Ruin field: max standing height at building-local (x, z)
---------------------------------------------------------------------------------------------------

type RuinField = (x: number, z: number) -> number

local function makeRuinField(ctx: any, w: number, d: number, fullH: number, ruin: number): RuinField?
	if ruin <= 0 then
		return nil
	end
	local seed = ctx:Int(1, 100000)
	local zones = {}
	if ruin > 0.25 then
		for _ = 1, ctx:Int(1, 1 + math.floor(ruin * 2.5)) do
			table.insert(zones, {
				x = ctx:Range(-w / 2, w / 2),
				z = ctx:Range(-d / 2, d / 2),
				r = ctx:Range(4, 5 + math.max(w, d) * 0.4 * ruin),
			})
		end
	end
	return function(x, z)
		local f = 0.4 + 0.5 * Geo.fbm(x, z, 7, 2, seed)
		for _, zn in zones do
			local dd = math.sqrt((x - zn.x) ^ 2 + (z - zn.z) ^ 2)
			if dd < zn.r then
				f += (1 - dd / zn.r) * 1.3
			end
		end
		return fullH * (1 - ruin * math.clamp(f, 0, 1))
	end
end

---------------------------------------------------------------------------------------------------
-- Wall (low-level)
---------------------------------------------------------------------------------------------------

export type Opening = {
	x: number, -- centre along the wall (wall-local X)
	w: number,
	y0: number, -- bottom (0 = doors)
	y1: number, -- top
	fill: string?, -- nil = open hole | "pane" | "shutter" | "door" | "boarded"
}

export type WallOpts = {
	thickness: number?,
	material: Enum.Material?,
	color: Color3?,
	openings: { Opening }?,
	solid: boolean?, -- openings drawn as panes on a solid wall (cheap, not enterable)
	chunk: number?, -- max piece width (destruction granularity), default 8
	destructible: boolean?,
	clip: ((x: number) -> number)?, -- max top height at wall-local x (ruins)
	style: Style?,
	sills: boolean?,
	shutters: boolean?,
	noPenetration: boolean?,
}

--[[
	Buildings.Wall(ctx, parent, cf, length, height, opts)
	cf = base centre of the wall; wall spans local X (-length/2..length/2), Y (0..height),
	thickness along local Z, outer face toward cf.LookVector (-Z).
]]
function Buildings.Wall(ctx: any, parent: Instance, cf: CFrame, length: number, height: number, opts: WallOpts?)
	local o: WallOpts = opts or {} :: any
	local t = o.thickness or 1
	local mat = o.material or M.Concrete
	local color = o.color or rgb(160, 156, 150)
	local chunk = o.chunk or 8
	local destructible = o.destructible ~= false
	local clip = o.clip
	local style = o.style
	local openings = table.clone(o.openings or {})
	table.sort(openings, function(a, b)
		return a.x < b.x
	end)

	local function piece(x0: number, x1: number, y0: number, y1: number)
		local width = x1 - x0
		if width < 0.15 or y1 - y0 < 0.15 then
			return
		end
		local n = math.max(1, math.ceil(width / chunk))
		local pw = width / n
		for i = 0, n - 1 do
			local a = x0 + i * pw
			local top = y1
			if clip then
				top = math.min(y1, clip(a + pw / 2) + ctx:Range(-1.2, 1.2))
			end
			if top - y0 > 0.4 then
				ctx:Part({
					Name = "Wall",
					Parent = parent,
					Size = Vector3.new(pw, top - y0, t),
					CFrame = cf * CFrame.new(a + pw / 2, (y0 + top) / 2, 0),
					Material = mat,
					Color = color,
					Jitter = 0.025,
					Destructible = destructible,
					NoPenetration = o.noPenetration,
				})
			end
		end
	end

	local function standing(x: number, y: number): boolean
		return clip == nil or clip(x) > y
	end

	if o.solid then
		piece(-length / 2, length / 2, 0, height)
		for _, op in openings do
			local yTop = op.y1
			if not standing(op.x, yTop - 0.5) then
				continue
			end
			local fillColor = if style then style.pane else rgb(36, 40, 44)
			local fillMat = M.Glass
			if op.fill == "door" then
				fillColor = if style then style.trimColor else rgb(70, 52, 36)
				fillMat = M.Wood
			elseif op.fill == "shutter" then
				fillColor = if style and style.shutterColors then ctx:Pick(style.shutterColors) else rgb(80, 70, 60)
				fillMat = M.WoodPlanks
			end
			ctx:Part({
				Name = "Pane",
				Parent = parent,
				Size = Vector3.new(op.w, op.y1 - op.y0, 0.2),
				CFrame = cf * CFrame.new(op.x, (op.y0 + op.y1) / 2, -t / 2 - 0.08),
				Material = fillMat,
				Color = fillColor,
				Jitter = 0.04,
				CastShadow = false,
			})
		end
		return
	end

	local cursor = -length / 2
	for _, op in openings do
		local l, r = op.x - op.w / 2, op.x + op.w / 2
		piece(cursor, l, 0, height)
		piece(l, r, 0, op.y0) -- sill / below
		piece(l, r, op.y1, height) -- lintel / above
		cursor = r
		if standing(op.x, op.y1) then
			-- Fill (closed shutters, doors, boards) or decorations
			if op.fill == "door" or op.fill == "shutter" or op.fill == "pane" then
				local isDoor = op.fill == "door"
				ctx:Part({
					Name = if isDoor then "Door" else "Shutter",
					Parent = parent,
					Size = Vector3.new(op.w, op.y1 - op.y0, 0.3),
					CFrame = cf * CFrame.new(op.x, (op.y0 + op.y1) / 2, 0),
					Material = if op.fill == "pane" then M.Glass else M.WoodPlanks,
					Color = if op.fill == "pane"
						then (if style then style.pane else rgb(36, 40, 44))
						elseif isDoor then (if style then style.trimColor else rgb(70, 52, 36))
						else (if style and style.shutterColors
							then ctx:Pick(style.shutterColors)
							else rgb(90, 76, 60)),
					Destructible = true,
					CastShadow = false,
				})
			elseif op.fill == "boarded" then
				for k = -1, 1, 2 do
					ctx:Part({
						Name = "Board",
						Parent = parent,
						Size = Vector3.new(op.w + 0.6, 0.5, 0.2),
						CFrame = cf
							* CFrame.new(op.x, (op.y0 + op.y1) / 2, -t / 2 - 0.12)
							* CFrame.Angles(0, 0, math.rad(28 * k)),
						Material = M.WoodPlanks,
						Color = rgb(110, 92, 70),
						Destructible = true,
						CastShadow = false,
					})
				end
			end
			if o.sills and op.y0 > 0.5 then
				ctx:Part({
					Name = "Sill",
					Parent = parent,
					Size = Vector3.new(op.w + 0.6, 0.3, t + 0.5),
					CFrame = cf * CFrame.new(op.x, op.y0 - 0.15, -0.25),
					Material = if style then style.trim else M.Wood,
					Color = if style then style.trimColor else rgb(80, 60, 44),
					CastShadow = false,
				})
			end
			if o.shutters and op.y0 > 0.5 and style and style.shutterColors and ctx:Chance(0.45) then
				local sc = ctx:Pick(style.shutterColors)
				for k = -1, 1, 2 do
					ctx:Part({
						Name = "Shutter",
						Parent = parent,
						Size = Vector3.new(op.w / 2, op.y1 - op.y0, 0.15),
						CFrame = cf * CFrame.new(op.x + k * (op.w * 0.75 + 0.05), (op.y0 + op.y1) / 2, -t / 2 - 0.1),
						Material = M.WoodPlanks,
						Color = sc,
						CastShadow = false,
						CanQuery = false,
					})
				end
			end
		end
	end
	piece(cursor, length / 2, 0, height)
end

---------------------------------------------------------------------------------------------------
-- Site preparation
---------------------------------------------------------------------------------------------------

-- Returns the building CFrame at floor level and creates the foundation plinth.
local function prepareSite(
	ctx: any,
	model: Model,
	cf: CFrame,
	w: number,
	d: number,
	opts: { [string]: any },
	style: Style
): CFrame
	local base = cf
	if opts.snap ~= false then
		local lo, hi = ctx:FootprintMinY(cf, w, d)
		local floorY = hi + (opts.plinth or 0.6)
		local rot = cf - cf.Position
		base = CFrame.new(cf.Position.X, floorY, cf.Position.Z) * rot
		local depth = floorY - lo + 3
		local foundation = ctx:Part({
			Name = "Foundation",
			Parent = model,
			Size = Vector3.new(w + 0.8, depth, d + 0.8),
			CFrame = base * CFrame.new(0, -depth / 2, 0),
			Material = style.base,
			Color = style.baseColor,
			Jitter = 0.03,
		})
		model.PrimaryPart = foundation
	end
	return base
end

---------------------------------------------------------------------------------------------------
-- Roofs
---------------------------------------------------------------------------------------------------

--[[
	Gable roof over a span. `cf` = centre of the wall tops; ridge runs along local X.
	lengthX = ridge length (wall span along X), spanZ = span across the ridge.
]]
local function gableRoof(
	ctx: any,
	parent: Instance,
	cf: CFrame,
	lengthX: number,
	spanZ: number,
	style: Style,
	opts: { [string]: any }
)
	local pitch = math.rad(opts.pitch or style.pitch)
	local oh = opts.overhang or 1.2
	local t = opts.wallT or 1
	local ruin = opts.ruin or 0
	local roofColor = ctx:Pick(style.roofColors)
	local half = spanZ / 2
	local rise = half * math.tan(pitch)
	local slabT = 0.7

	-- Gable end triangles (wedge pairs) on top of the end walls
	local keepGable = { ruin < 0.55 or ctx:Chance(0.4), ruin < 0.55 or ctx:Chance(0.4) }
	for gi, sx in { -1, 1 } do
		if keepGable[gi] then
			for _, sz in { -1, 1 } do
				local riseDir = cf:VectorToWorldSpace(Vector3.new(0, 0, -sz))
				local centre = cf * Vector3.new(sx * (lengthX / 2 - t / 2), rise / 2, sz * half / 2)
				ctx:Part({
					Name = "Gable",
					Parent = parent,
					Shape = "Wedge",
					Size = Vector3.new(t, rise, half),
					CFrame = Core.WedgeCF(centre, riseDir),
					Material = opts.gableMaterial or style.wall,
					Color = opts.gableColor or ctx:Pick(style.wallColors),
					Jitter = 0.02,
					Destructible = true,
				})
			end
		end
	end

	-- Roof slabs: split into segments along the ridge; ruined roofs lose segments.
	local segs = if ruin > 0 then math.max(2, math.floor(lengthX / 6)) else 1
	local slabLen = (half + oh) / math.cos(pitch)
	local totalX = lengthX + oh * 2
	for _, sz in { -1, 1 } do
		for s = 1, segs do
			local segW = totalX / segs
			local x = -totalX / 2 + (s - 0.5) * segW
			local missing = ruin > 0 and ctx:Chance(ruin * 0.85)
			local ridge = Vector3.new(x, rise + slabT / 2, 0)
			local eave = Vector3.new(x, rise - (half + oh) * math.tan(pitch) + slabT / 2, sz * (half + oh))
			if not missing then
				local a, b = cf * ridge, cf * eave
				local frame = CFrame.lookAt((a + b) / 2, b, cf.UpVector)
				ctx:Part({
					Name = "Roof",
					Parent = parent,
					Size = Vector3.new(segW + 0.02, slabT, slabLen),
					CFrame = frame,
					Material = style.roof,
					Color = roofColor,
					Jitter = 0.02,
					Destructible = true,
				})
			elseif ruin < 0.9 then
				-- exposed rafters where the tiles are gone
				for r = -1, 1, 2 do
					if ctx:Chance(0.7) then
						local rx = x + r * segW * 0.3
						local a = cf * Vector3.new(rx, rise - 0.2, 0)
						local b = cf * Vector3.new(rx, rise - half * math.tan(pitch) - 0.2, sz * half)
						local rcf, len = Core.Between(a, b)
						ctx:Part({
							Name = "Rafter",
							Parent = parent,
							Size = Vector3.new(0.5, 0.6, len * ctx:Range(0.6, 1)),
							CFrame = rcf,
							Material = M.Wood,
							Color = rgb(60, 46, 34),
							CastShadow = false,
						})
					end
				end
			end
		end
	end

	-- Ridge cap
	if ruin < 0.4 then
		ctx:Part({
			Name = "Ridge",
			Parent = parent,
			Size = Vector3.new(totalX, 0.6, 1.2),
			CFrame = cf * CFrame.new(0, rise + slabT * 0.9, 0),
			Material = style.roof,
			Color = roofColor:Lerp(rgb(40, 40, 40), 0.3),
			CastShadow = false,
		})
	end
	return rise
end

-- Flat roof with a parapet. cf = centre of wall tops.
local function flatRoof(
	ctx: any,
	parent: Instance,
	cf: CFrame,
	w: number,
	d: number,
	style: Style,
	opts: { [string]: any }
)
	local ruinField: RuinField? = opts.ruinField
	local topY = opts.topY or 0
	local stripW = 12
	local n = math.max(1, math.ceil(w / stripW))
	for i = 0, n - 1 do
		local sw = w / n
		local x = -w / 2 + (i + 0.5) * sw
		local keep = ruinField == nil or ruinField(x, 0) >= topY - 0.5
		if keep then
			ctx:Part({
				Name = "Roof",
				Parent = parent,
				Size = Vector3.new(sw, 0.8, d),
				CFrame = cf * CFrame.new(x, -0.4, 0),
				Material = style.roof,
				Color = ctx:Pick(style.roofColors),
				Jitter = 0.02,
				Destructible = true,
			})
		end
	end
	if opts.parapet ~= false then
		local ph = opts.parapetHeight or 1.6
		local t = 0.8
		for _, e in
			{
				{ CFrame.new(0, 0, -d / 2 + t / 2), w },
				{ CFrame.new(0, 0, d / 2 - t / 2) * CFrame.Angles(0, math.pi, 0), w },
				{ CFrame.new(-w / 2 + t / 2, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), d - 2 * t },
				{ CFrame.new(w / 2 - t / 2, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), d - 2 * t },
			}
		do
			local wcf = cf * e[1]
			Buildings.Wall(ctx, parent, wcf, e[2], ph, {
				thickness = t,
				material = style.wall,
				color = ctx:Pick(style.wallColors),
				chunk = 10,
				clip = if ruinField
					then function(x)
						local p = e[1] * Vector3.new(x, 0, 0)
						return ruinField(p.X, p.Z) - topY
					end
					else nil,
			})
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Generic multi-storey shell
---------------------------------------------------------------------------------------------------

-- Splits rect (centre 0,0 size w,d) minus an axis-aligned hole into up to 4 rects {cx, cz, sx, sz}.
local function rectMinusHole(w: number, d: number, hx: number, hz: number, hw: number, hd: number)
	local out = {}
	local x0, x1, z0, z1 = -w / 2, w / 2, -d / 2, d / 2
	local hx0, hx1, hz0, hz1 = hx - hw / 2, hx + hw / 2, hz - hd / 2, hz + hd / 2
	local function add(a, b, c, e)
		if b - a > 0.1 and e - c > 0.1 then
			table.insert(out, { (a + b) / 2, (c + e) / 2, b - a, e - c })
		end
	end
	add(x0, hx0, z0, z1) -- left full depth
	add(hx1, x1, z0, z1) -- right full depth
	add(hx0, hx1, z0, hz0) -- middle front
	add(hx0, hx1, hz1, z1) -- middle back
	return out
end

type ShellSpec = {
	width: number,
	depth: number,
	floors: number,
	floorH: number,
	wallT: number,
	style: Style,
	enterable: boolean,
	ruin: number,
	windowSpacing: number,
	windowW: number,
	sillY: number,
	windowTop: number,
	doorW: number,
	doorH: number,
	backDoor: boolean,
	sills: boolean,
	shutters: boolean,
	stairs: boolean,
	extraTop: number, -- extra wall height above the last floor (parapet for flat roofs)
	openingsFn: ((wall: string, floor: number, length: number) -> { Opening })?,
	wallColor: Color3?,
	noPenetration: boolean?,
}

local function defaultOpenings(ctx: any, spec: ShellSpec, wall: string, floor: number, length: number): { Opening }
	local list = {}
	local usable = length - 3
	local n = math.max(0, math.floor(usable / spec.windowSpacing))
	if n == 0 and length > 6 then
		n = 1
	end
	local doorIndex = -1
	if floor == 1 and (wall == "front" or (wall == "back" and spec.backDoor)) then
		doorIndex = if n <= 1 then 1 else math.ceil(n / 2)
		if n == 0 then
			n = 1
		end
	end
	for i = 1, n do
		local x = -length / 2 + length * (i - 0.5) / n
		if i == doorIndex then
			table.insert(list, {
				x = x,
				w = spec.doorW,
				y0 = 0,
				y1 = spec.doorH,
				fill = if spec.enterable then nil else "door",
			})
		else
			local fill = nil
			if not spec.enterable then
				local r = ctx.rng:NextNumber()
				fill = if r < 0.55 then "pane" elseif r < 0.85 then "shutter" else "boarded"
			elseif spec.ruin < 0.3 and ctx:Chance(0.12) then
				fill = "boarded"
			end
			table.insert(list, { x = x, w = spec.windowW, y0 = spec.sillY, y1 = spec.windowTop, fill = fill })
		end
	end
	return list
end

-- Builds walls, floors, stairs. `base` = CFrame at ground-floor level. Returns wall-top height.
local function buildShell(ctx: any, model: Model, base: CFrame, spec: ShellSpec, ruinField: RuinField?): number
	local w, d, t = spec.width, spec.depth, spec.wallT
	local style = spec.style
	local wallColor = spec.wallColor or ctx:Pick(style.wallColors)
	local totalH = spec.floors * spec.floorH + spec.extraTop

	-- Walls: {name, local cframe, length}
	local walls = {
		{ "front", CFrame.new(0, 0, -d / 2 + t / 2), w },
		{ "back", CFrame.new(0, 0, d / 2 - t / 2) * CFrame.Angles(0, math.pi, 0), w },
		{ "left", CFrame.new(-w / 2 + t / 2, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), d - 2 * t },
		{ "right", CFrame.new(w / 2 - t / 2, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), d - 2 * t },
	}
	local solid = not spec.enterable
	for f = 1, spec.floors do
		local y = (f - 1) * spec.floorH
		local h = spec.floorH + (if f == spec.floors then spec.extraTop else 0)
		for _, wd in walls do
			local name, lcf, len = wd[1], wd[2], wd[3]
			local openings = if spec.openingsFn
				then spec.openingsFn(name, f, len)
				else defaultOpenings(ctx, spec, name, f, len)
			local clip = nil
			if ruinField then
				clip = function(x)
					local p = lcf * Vector3.new(x, 0, 0)
					return ruinField(p.X, p.Z) - y
				end
				if clip(0) < 0.5 and clip(-len / 3) < 0.5 and clip(len / 3) < 0.5 then
					continue
				end
			end
			Buildings.Wall(ctx, model, base * lcf * CFrame.new(0, y, 0), len, h, {
				thickness = t,
				material = style.wall,
				color = wallColor,
				openings = openings,
				solid = solid,
				clip = clip,
				chunk = if ruinField then 4 else 8,
				style = style,
				sills = spec.sills and name == "front",
				shutters = spec.shutters and name ~= "back",
				noPenetration = spec.noPenetration,
			})
		end
	end

	-- Floors
	local inW, inD = w - 2 * t, d - 2 * t
	local stairW = 4
	local run = math.min(spec.floorH * 1.3, inD - 3)
	if spec.enterable then
		for f = 1, spec.floors do
			local y = (f - 1) * spec.floorH
			local rects
			local hasStairsHere = spec.stairs and f > 1 and run > 6
			local side = if f % 2 == 0 then -1 else 1
			local hx = side * (inW / 2 - stairW / 2)
			local hz = inD / 2 - run / 2
			if hasStairsHere then
				rects = rectMinusHole(inW, inD, hx, hz, stairW, run)
			else
				rects = { { 0, 0, inW, inD } }
			end
			for _, r in rects do
				-- split along X into strips so ruins can drop parts of a floor
				local n = math.max(1, math.ceil(r[3] / 12))
				for s = 0, n - 1 do
					local sw = r[3] / n
					local cx = r[1] - r[3] / 2 + (s + 0.5) * sw
					if f > 1 and ruinField and ruinField(cx, r[2]) < y + 1.5 then
						continue
					end
					ctx:Part({
						Name = "Floor",
						Parent = model,
						Size = Vector3.new(sw, 0.8, r[4]),
						CFrame = base * CFrame.new(cx, y - 0.4, r[2]),
						Material = style.floor,
						Color = style.floorColor,
						Jitter = 0.03,
						Destructible = f > 1,
					})
				end
			end
			if hasStairsHere then
				-- Ramp from floor f-1 up to f, rising toward the back wall
				local prevY = y - spec.floorH
				local centre = base * Vector3.new(hx, prevY + spec.floorH / 2, hz)
				ctx:Part({
					Name = "Stairs",
					Parent = model,
					Shape = "Wedge",
					Size = Vector3.new(stairW - 0.2, spec.floorH, run),
					CFrame = Core.WedgeCF(centre, base:VectorToWorldSpace(Vector3.zAxis)),
					Material = M.WoodPlanks,
					Color = style.floorColor:Lerp(rgb(60, 46, 34), 0.3),
					Jitter = 0.02,
				})
			end
		end
	end
	return totalH
end

---------------------------------------------------------------------------------------------------
-- Interior clutter & ruin dressing
---------------------------------------------------------------------------------------------------

local function furnish(
	ctx: any,
	model: Model,
	base: CFrame,
	w: number,
	d: number,
	floors: number,
	floorH: number,
	ruinField: RuinField?
)
	local wood = rgb(92, 70, 48)
	for f = 1, floors do
		local y = (f - 1) * floorH
		local count = ctx:Int(1, 3)
		for _ = 1, count do
			local x = ctx:Range(-w / 2 + 3, w / 2 - 3)
			local z = ctx:Range(-d / 2 + 3, d / 2 - 6)
			if ruinField and ruinField(x, z) < y + 2 then
				continue
			end
			local kind = ctx.rng:NextNumber()
			local yaw = ctx:Range(0, 360)
			local at = base * CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw), 0)
			if kind < 0.4 then
				-- table
				ctx:Part({
					Name = "Table",
					Parent = model,
					Size = Vector3.new(4, 0.3, 2.6),
					CFrame = at * CFrame.new(0, 2.8, 0),
					Material = M.Wood,
					Color = wood,
					CastShadow = false,
				})
				for _, lx in { -1.5, 1.5 } do
					ctx:Part({
						Name = "TableLeg",
						Parent = model,
						Size = Vector3.new(0.4, 2.65, 2),
						CFrame = at * CFrame.new(lx, 1.33, 0),
						Material = M.Wood,
						Color = wood:Lerp(rgb(0, 0, 0), 0.2),
						CastShadow = false,
					})
				end
			elseif kind < 0.7 then
				ctx:Part({
					Name = "Crate",
					Parent = model,
					Size = Vector3.new(2.6, 2.6, 2.6),
					CFrame = at * CFrame.new(0, 1.3, 0),
					Material = M.WoodPlanks,
					Color = rgb(120, 96, 62),
					Destructible = true,
				})
			else
				-- cupboard / wardrobe against no particular wall (good cover)
				ctx:Part({
					Name = "Cupboard",
					Parent = model,
					Size = Vector3.new(3.6, 6, 1.6),
					CFrame = at * CFrame.new(0, 3, 0),
					Material = M.Wood,
					Color = wood:Lerp(rgb(40, 30, 20), 0.3),
					Destructible = true,
				})
			end
		end
	end
end

local function ruinDressing(
	ctx: any,
	model: Model,
	base: CFrame,
	w: number,
	d: number,
	ruin: number,
	style: Style,
	totalH: number
)
	if ruin <= 0.15 then
		return
	end
	-- Rubble heaps inside and spilling out of the footprint
	local heaps = 1 + math.floor(ruin * 3)
	for _ = 1, heaps do
		local p = base * Vector3.new(ctx:Range(-w / 2, w / 2) * 0.9, 0, ctx:Range(-d / 2, d / 2) * 1.2)
		local r = ctx:Range(4, 4 + math.min(w, d) * 0.35 * ruin)
		Terrain.RubbleMound(ctx, p, r, ctx:Range(1.5, 2 + totalH * 0.18 * ruin), style.rubble)
	end
	-- Fallen beams / slabs
	for _ = 1, math.floor(ruin * 4) do
		local p = base * CFrame.new(ctx:Range(-w / 2, w / 2) * 0.8, 1, ctx:Range(-d / 2, d / 2) * 0.8)
		ctx:Part({
			Name = "Beam",
			Parent = model,
			Size = Vector3.new(0.8, 0.8, ctx:Range(6, 12)),
			CFrame = p * CFrame.Angles(ctx:Range(-0.6, 0.6), ctx:Range(0, 6.28), ctx:Range(-0.3, 0.3)),
			Material = M.Wood,
			Color = rgb(52, 42, 34),
			CastShadow = false,
		})
	end
	if ruin > 0.55 and ctx:Chance(0.6) then
		-- collapsed floor slab leaning diagonally
		local p = base * CFrame.new(ctx:Range(-w / 4, w / 4), totalH * 0.25, ctx:Range(-d / 4, d / 4))
		ctx:Part({
			Name = "CollapsedSlab",
			Parent = model,
			Size = Vector3.new(math.min(w, 12), 0.8, math.min(d * 0.7, 10)),
			CFrame = p * CFrame.Angles(ctx:Range(0.4, 0.8), ctx:Range(0, 6.28), 0),
			Material = style.floor,
			Color = style.floorColor,
			Destructible = true,
		})
	end
end

local function chimneyOnRoof(
	ctx: any,
	model: Model,
	base: CFrame,
	x: number,
	z: number,
	fromY: number,
	toY: number,
	style: Style
)
	ctx:Part({
		Name = "Chimney",
		Parent = model,
		Size = Vector3.new(2, toY - fromY, 2.4),
		CFrame = base * CFrame.new(x, (fromY + toY) / 2, z),
		Material = if style.wall == M.Brick then M.Brick else M.Cobblestone,
		Color = if style.wall == M.Brick then ctx:Pick(style.wallColors) else rgb(118, 108, 98),
		Destructible = true,
	})
end

---------------------------------------------------------------------------------------------------
-- House
---------------------------------------------------------------------------------------------------

--[[
	Buildings.House(ctx, cf, opts) -> Model
	opts: width (X, 22), depth (Z, 16), floors (2), floorH (10), style ("Norman"), enterable (true),
	      ruin (0), roof ("gable" | "flat"), ridge ("x" | "z"), chimney (true), backDoor (true),
	      name, minimap (true)
]]
function Buildings.House(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local style = resolveStyle(o.style)
	local w, d = o.width or 22, o.depth or 16
	local floors = o.floors or 2
	local floorH = o.floorH or 10
	local ruin = o.ruin or 0
	local enterable = o.enterable ~= false
	local roofKind = o.roof or (if style.pitch <= 0 then "flat" else "gable")
	local model = ctx:Model(o.name or "House", o.parent or ctx:Folder("Buildings"))
	local base = prepareSite(ctx, model, cf, w, d, o, style)

	local wallTop = floors * floorH + (if roofKind == "flat" then 1.6 else 0)
	local ruinField = makeRuinField(ctx, w, d, wallTop + (if roofKind == "gable" then w * 0.3 else 0), ruin)

	local spec: ShellSpec = {
		width = w,
		depth = d,
		floors = floors,
		floorH = floorH,
		wallT = o.wallT or 1,
		style = style,
		enterable = enterable,
		ruin = ruin,
		windowSpacing = o.windowSpacing or 6.5,
		windowW = o.windowW or 3,
		sillY = o.sillY or 3,
		windowTop = o.windowTop or math.min(floorH - 2, 7.5),
		doorW = o.doorW or 4,
		doorH = o.doorH or 7.5,
		backDoor = o.backDoor ~= false,
		sills = o.sills ~= false,
		shutters = o.shutters ~= false,
		stairs = true,
		extraTop = if roofKind == "flat" then 1.6 else 0,
		openingsFn = o.openingsFn,
		wallColor = o.wallColor,
	}
	local totalH = buildShell(ctx, model, base, spec, ruinField)

	-- Roof
	local topCF = base * CFrame.new(0, floors * floorH, 0)
	if roofKind == "gable" then
		if ruin < 0.8 then
			local alongZ = o.ridge == "z"
			local rcf = if alongZ then topCF * CFrame.Angles(0, math.pi / 2, 0) else topCF
			local rise = gableRoof(ctx, model, rcf, if alongZ then d else w, if alongZ then w else d, style, {
				ruin = ruin,
				wallT = spec.wallT,
				pitch = o.pitch,
				gableColor = o.wallColor,
			})
			if o.chimney ~= false and ruin < 0.5 then
				chimneyOnRoof(
					ctx,
					model,
					base,
					if alongZ then 0 else w * 0.28,
					if alongZ then d * 0.28 else 0,
					floors * floorH,
					floors * floorH + rise + 2.5,
					style
				)
			end
		end
	else
		flatRoof(ctx, model, topCF, w, d, style, { ruinField = ruinField, topY = floors * floorH, parapet = false })
	end

	if enterable then
		furnish(ctx, model, base, w - 2, d - 2, floors, floorH, ruinField)
	end
	ruinDressing(ctx, model, base, w, d, ruin, style, totalH)
	if o.minimap ~= false then
		ctx:AddMinimapCF("building", base, w, d)
	end
	return model
end

-- Mediterranean stone house preset (flat or low clay-tile roof, small windows, terrace parapet).
function Buildings.StoneHouse(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = table.clone(opts or {})
	o.style = o.style or "Mediterranean"
	o.width = o.width or 18
	o.depth = o.depth or 14
	o.windowW = o.windowW or 2.4
	o.windowSpacing = o.windowSpacing or 7
	o.roof = o.roof or (if ctx:Chance(0.5) then "flat" else "gable")
	o.sills = false
	return Buildings.House(ctx, cf, o)
end

-- Norman/stone farmhouse: long, two floors, stone walls, slate roof and a lean-to shed.
function Buildings.Farmhouse(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = table.clone(opts or {})
	o.style = o.style or "Farm"
	o.width = o.width or 28
	o.depth = o.depth or 16
	o.floors = o.floors or 2
	o.name = o.name or "Farmhouse"
	local model = Buildings.House(ctx, cf, o)
	-- Lean-to shed on the right gable end
	local style = resolveStyle(o.style)
	local w, d = o.width, o.depth
	local ruin = o.ruin or 0
	local shedCF = cf * CFrame.new(w / 2 + 4, 0, 1)
	local gy = ctx:GroundY(shedCF.Position.X, shedCF.Position.Z)
	local sb = CFrame.new(shedCF.Position.X, gy, shedCF.Position.Z) * (cf - cf.Position)
	for _, p in { { -3.5, -6 }, { 3.5, -6 }, { 3.5, 6 } } do
		ctx:Part({
			Name = "Post",
			Parent = model,
			Size = Vector3.new(0.8, 7, 0.8),
			CFrame = sb * CFrame.new(p[1], 3.5, p[2]),
			Material = M.Wood,
			Color = style.trimColor,
		})
	end
	if ruin < 0.6 then
		local roofCF = sb * CFrame.new(0, 7.6, 0) * CFrame.Angles(0, 0, math.rad(-14))
		ctx:Part({
			Name = "ShedRoof",
			Parent = model,
			Size = Vector3.new(9.4, 0.5, 14),
			CFrame = roofCF,
			Material = M.WoodPlanks,
			Color = rgb(80, 66, 52),
			Destructible = true,
		})
	end
	-- firewood stack under the shed
	ctx:Part({
		Name = "Firewood",
		Parent = model,
		Size = Vector3.new(2.5, 3, 8),
		CFrame = sb * CFrame.new(2.2, 1.5, 0),
		Material = M.Wood,
		Color = rgb(110, 84, 58),
	})
	return model
end

---------------------------------------------------------------------------------------------------
-- Barn
---------------------------------------------------------------------------------------------------

-- Large timber barn with big doors at both ends, a hayloft (ladder) and hay bales.
function Buildings.Barn(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local style = resolveStyle(o.style or "Timber")
	local w, d = o.width or 18, o.depth or 30 -- ridge runs along Z (long axis)
	local h = o.height or 13
	local ruin = o.ruin or 0
	local model = ctx:Model(o.name or "Barn", o.parent or ctx:Folder("Buildings"))
	local base = prepareSite(ctx, model, cf, w, d, o, style)
	local ruinField = makeRuinField(ctx, w, d, h + 6, ruin)

	local spec: ShellSpec = {
		width = w,
		depth = d,
		floors = 1,
		floorH = h,
		wallT = 0.8,
		style = style,
		enterable = true,
		ruin = ruin,
		windowSpacing = 9,
		windowW = 2,
		sillY = 6,
		windowTop = 8.5,
		doorW = 9,
		doorH = 10,
		backDoor = true,
		sills = false,
		shutters = false,
		stairs = false,
		extraTop = 0,
		openingsFn = function(wall, _floor, len)
			if wall == "front" or wall == "back" then
				return { { x = 0, w = 9, y0 = 0, y1 = 10 } }
			end
			local list = {}
			for i = 1, 3 do
				table.insert(list, { x = -len / 2 + len * (i - 0.5) / 3, w = 2, y0 = 7, y1 = 9 })
			end
			return list
		end,
	}
	buildShell(ctx, model, base, spec, ruinField)
	-- Packed-earth floor
	ctx:Part({
		Name = "Floor",
		Parent = model,
		Size = Vector3.new(w - 1.6, 0.4, d - 1.6),
		CFrame = base * CFrame.new(0, -0.2, 0),
		Material = M.Ground,
		Color = rgb(96, 82, 60),
	})
	-- Hayloft over the back third + ladder
	local loftD = d * 0.35
	if ruin < 0.7 then
		ctx:Part({
			Name = "Hayloft",
			Parent = model,
			Size = Vector3.new(w - 1.6, 0.6, loftD),
			CFrame = base * CFrame.new(0, 7, d / 2 - 0.8 - loftD / 2),
			Material = M.WoodPlanks,
			Color = style.floorColor,
			Destructible = true,
		})
		ctx:Part({
			Name = "Ladder",
			Parent = model,
			Shape = "Truss",
			Size = Vector3.new(2, 8, 2),
			CFrame = base * CFrame.new(-w / 2 + 3, 4, d / 2 - 0.8 - loftD - 1),
			Color = rgb(90, 70, 50),
		})
		for _ = 1, 4 do
			ctx:Part({
				Name = "HayBale",
				Parent = model,
				Size = Vector3.new(4, 2.2, 2.6),
				CFrame = base
					* CFrame.new(ctx:Range(-w / 2 + 3, w / 2 - 3), 8.4, d / 2 - ctx:Range(2, loftD - 1))
					* CFrame.Angles(0, ctx:Range(-0.3, 0.3), 0),
				Material = M.Grass,
				Color = rgb(176, 152, 92),
				CastShadow = false,
			})
		end
	end
	for _ = 1, 3 do
		ctx:Part({
			Name = "HayBale",
			Parent = model,
			Size = Vector3.new(4, 2.2, 2.6),
			CFrame = base
				* CFrame.new(ctx:Range(-w / 2 + 3, w / 2 - 3), 1.1, ctx:Range(-d / 2 + 4, 0))
				* CFrame.Angles(0, ctx:Range(0, 3), 0),
			Material = M.Grass,
			Color = rgb(170, 146, 88),
		})
	end
	if ruin < 0.8 then
		gableRoof(ctx, model, base * CFrame.new(0, h, 0) * CFrame.Angles(0, math.pi / 2, 0), d, w, style, {
			ruin = ruin,
			wallT = 0.8,
			pitch = 46,
			gableMaterial = style.wall,
		})
	end
	ruinDressing(ctx, model, base, w, d, ruin, style, h)
	ctx:AddMinimapCF("building", base, w, d)
	return model
end

---------------------------------------------------------------------------------------------------
-- Church with bell tower
---------------------------------------------------------------------------------------------------

-- Pyramid spire from 4 corner wedges. cf = centre of the base square.
local function spire(
	ctx: any,
	parent: Instance,
	cf: CFrame,
	size: number,
	height: number,
	mat: Enum.Material,
	color: Color3
)
	local half = size / 2
	for i = 0, 3 do
		local rot = CFrame.Angles(0, i * math.pi / 2, 0)
		ctx:Part({
			Name = "Spire",
			Parent = parent,
			Shape = "CornerWedge",
			Size = Vector3.new(half, height, half),
			CFrame = cf * rot * CFrame.new(half / 2, height / 2, -half / 2),
			Material = mat,
			Color = color,
			Jitter = 0,
		})
	end
end

--[[
	Buildings.Church(ctx, cf, opts) -> Model
	Nave runs along local Z behind the tower; the tower stands at the front (toward cf.LookVector).
	opts: width (24), length (52), naveH (17), towerSize (12), towerH (48), ruin (0), style ("NormanStone")
	The tower has ladder-connected levels; the belfry (top level) is a sniper perch.
]]
function Buildings.Church(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local style = resolveStyle(o.style or "NormanStone")
	local w, len = o.width or 24, o.length or 52
	local naveH = o.naveH or 17
	local ts, th = o.towerSize or 12, o.towerH or 48
	local ruin = o.ruin or 0
	local model = ctx:Model(o.name or "Church", o.parent or ctx:Folder("Buildings"))
	local totalD = len + ts
	-- cf is the centre of the whole footprint (tower in front + nave behind)
	local base0 = prepareSite(ctx, model, cf, w, totalD + 2, o, style)
	local towerBase = base0 * CFrame.new(0, 0, -totalD / 2 + ts / 2)
	local naveBase = base0 * CFrame.new(0, 0, -totalD / 2 + ts + len / 2)

	-- Nave
	local naveRuin = makeRuinField(ctx, w, len, naveH + 8, ruin)
	buildShell(ctx, model, naveBase, {
		width = w,
		depth = len,
		floors = 1,
		floorH = naveH,
		wallT = 1.4,
		style = style,
		enterable = true,
		ruin = ruin,
		windowSpacing = 9,
		windowW = 3,
		sillY = 6,
		windowTop = 14,
		doorW = 6,
		doorH = 11,
		backDoor = true,
		sills = false,
		shutters = false,
		stairs = false,
		extraTop = 0,
		openingsFn = function(wall, _floor, l)
			if wall == "front" then
				return { { x = 0, w = 6, y0 = 0, y1 = 11 } }
			elseif wall == "back" then
				return { { x = 0, w = 4, y0 = 0, y1 = 8 } }
			end
			local list = {}
			local n = math.floor((l - 4) / 9)
			for i = 1, n do
				table.insert(list, { x = -l / 2 + l * (i - 0.5) / n, w = 3, y0 = 6, y1 = 14 })
			end
			return list
		end,
	}, naveRuin)
	ctx:Part({
		Name = "Floor",
		Parent = model,
		Size = Vector3.new(w - 2.8, 0.4, len - 2.8),
		CFrame = naveBase * CFrame.new(0, -0.2, 0),
		Material = M.Slate,
		Color = rgb(110, 106, 100),
	})
	if ruin < 0.85 then
		gableRoof(ctx, model, naveBase * CFrame.new(0, naveH, 0) * CFrame.Angles(0, math.pi / 2, 0), len, w, style, {
			ruin = ruin,
			wallT = 1.4,
			pitch = 50,
		})
	end
	-- Pews (two columns) and altar: cover inside
	local rows = math.floor((len - 16) / 4)
	for r = 1, rows do
		for _, sx in { -1, 1 } do
			if ruin > 0 and ctx:Chance(ruin * 0.4) then
				continue
			end
			ctx:Part({
				Name = "Pew",
				Parent = model,
				Size = Vector3.new(w / 2 - 5, 2.6, 1.4),
				CFrame = naveBase
					* CFrame.new(sx * (w / 4 + 0.6), 1.3, -len / 2 + 6 + r * 4)
					* CFrame.Angles(0, ctx:Range(-0.05, 0.05) + (if ruin > 0.3 then ctx:Range(-0.4, 0.4) else 0), 0),
				Material = M.Wood,
				Color = rgb(82, 60, 42),
				Destructible = true,
				CastShadow = false,
			})
		end
	end
	ctx:Part({
		Name = "Altar",
		Parent = model,
		Size = Vector3.new(8, 3.6, 3),
		CFrame = naveBase * CFrame.new(0, 1.8, len / 2 - 5),
		Material = M.Marble,
		Color = rgb(196, 190, 178),
	})

	-- Tower: levels every 12 studs, ladders (TrussPart), belfry with big openings at the top
	local levelH = 12
	local levels = math.max(2, math.floor(th / levelH))
	local towerTop = levels * levelH
	local towerRuin = if ruin > 0.5 then makeRuinField(ctx, ts, ts, towerTop + 4, (ruin - 0.5) * 0.6) else nil
	local tw = 1.6
	local towerWalls = {
		{ "front", CFrame.new(0, 0, -ts / 2 + tw / 2), ts },
		{ "back", CFrame.new(0, 0, ts / 2 - tw / 2) * CFrame.Angles(0, math.pi, 0), ts },
		{ "left", CFrame.new(-ts / 2 + tw / 2, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), ts - 2 * tw },
		{ "right", CFrame.new(ts / 2 - tw / 2, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), ts - 2 * tw },
	}
	for lv = 1, levels do
		local y = (lv - 1) * levelH
		local isBelfry = lv == levels
		for _, wd in towerWalls do
			local name, lcf, l = wd[1], wd[2], wd[3]
			local openings
			if isBelfry then
				openings = { { x = 0, w = 5, y0 = 2.5, y1 = 9.5 } }
			elseif lv == 1 and (name == "front" or name == "back") then
				openings = { { x = 0, w = 5, y0 = 0, y1 = 9 } }
			else
				openings = { { x = 0, w = 1.2, y0 = 4, y1 = 8.5 } }
			end
			Buildings.Wall(ctx, model, towerBase * lcf * CFrame.new(0, y, 0), l, levelH, {
				thickness = tw,
				material = style.wall,
				color = style.wallColors[1],
				openings = openings,
				chunk = 6,
				clip = if towerRuin
					then function(x)
						local p = lcf * Vector3.new(x, 0, 0)
						return towerRuin(p.X, p.Z) - y
					end
					else nil,
				noPenetration = true,
			})
		end
		-- Level floor with ladder hatch in the back-left corner
		if lv > 1 then
			for _, r in rectMinusHole(ts - 2 * tw, ts - 2 * tw, -(ts / 2 - tw - 1.5), ts / 2 - tw - 1.5, 3, 3) do
				ctx:Part({
					Name = "TowerFloor",
					Parent = model,
					Size = Vector3.new(r[3], 0.8, r[4]),
					CFrame = towerBase * CFrame.new(r[1], y - 0.4, r[2]),
					Material = M.WoodPlanks,
					Color = rgb(96, 74, 52),
				})
			end
			ctx:Part({
				Name = "Ladder",
				Parent = model,
				Shape = "Truss",
				Size = Vector3.new(2, levelH, 2),
				CFrame = towerBase * CFrame.new(-(ts / 2 - tw - 1.5), y - levelH / 2 + 0.6, ts / 2 - tw - 1.5),
				Color = rgb(84, 64, 46),
			})
		end
	end
	-- Bell
	ctx:Part({
		Name = "Bell",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(2.6, 3, 3),
		CFrame = towerBase * CFrame.new(1.5, towerTop - 4, 0) * CFrame.Angles(0, 0, math.pi / 2),
		Material = M.Metal,
		Color = rgb(120, 96, 54),
	})
	-- Roof/spire
	if ruin < 0.5 then
		ctx:Part({
			Name = "TowerRoof",
			Parent = model,
			Size = Vector3.new(ts + 0.6, 1, ts + 0.6),
			CFrame = towerBase * CFrame.new(0, towerTop + 0.5, 0),
			Material = style.wall,
			Color = style.wallColors[1],
		})
		spire(ctx, model, towerBase * CFrame.new(0, towerTop + 1, 0), ts, o.spireH or 20, M.Slate, rgb(60, 64, 68))
	end
	ctx:Part({
		Name = "Steps",
		Parent = model,
		Size = Vector3.new(8, 0.8, 3),
		CFrame = towerBase * CFrame.new(0, -0.2, -ts / 2 - 1.5),
		Material = style.base,
		Color = style.baseColor,
	})
	ruinDressing(ctx, model, naveBase, w, len, ruin, style, naveH)
	ctx:AddMinimapCF("building", base0, w, totalD)
	return model
end

---------------------------------------------------------------------------------------------------
-- Soviet apartment block
---------------------------------------------------------------------------------------------------

--[[
	Buildings.Apartment(ctx, cf, opts) -> Model
	opts: width (48), depth (16), floors (4), floorH (10), style ("Soviet"), ruin (0), enterable (true),
	      balconies (true)
]]
function Buildings.Apartment(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local style = resolveStyle(o.style or "Soviet")
	local w, d = o.width or 48, o.depth or 16
	local floors = o.floors or 4
	local floorH = o.floorH or 10
	local ruin = o.ruin or 0
	local enterable = o.enterable ~= false
	local model = ctx:Model(o.name or "Apartment", o.parent or ctx:Folder("Buildings"))
	local base = prepareSite(ctx, model, cf, w, d, o, style)
	local wallTop = floors * floorH + 1.6
	local ruinField = makeRuinField(ctx, w, d, wallTop, ruin)

	local spec: ShellSpec = {
		width = w,
		depth = d,
		floors = floors,
		floorH = floorH,
		wallT = 1,
		style = style,
		enterable = enterable,
		ruin = ruin,
		windowSpacing = 6,
		windowW = 3.4,
		sillY = 3,
		windowTop = 7.6,
		doorW = 4.5,
		doorH = 8,
		backDoor = true,
		sills = false,
		shutters = false,
		stairs = true,
		extraTop = 1.6,
		wallColor = o.wallColor,
	}
	local totalH = buildShell(ctx, model, base, spec, ruinField)
	flatRoof(ctx, model, base * CFrame.new(0, floors * floorH, 0), w - 0.2, d - 0.2, style, {
		ruinField = ruinField,
		topY = floors * floorH,
		parapet = false,
	})
	-- Horizontal concrete bands between floors (silhouette detail), skipped where collapsed
	for f = 2, floors do
		local y = (f - 1) * floorH
		for _, sz in { -1, 1 } do
			local segs = math.ceil(w / 12)
			for s = 0, segs - 1 do
				local sw = w / segs
				local x = -w / 2 + (s + 0.5) * sw
				if ruinField and ruinField(x, sz * d / 2) < y + 0.5 then
					continue
				end
				ctx:Part({
					Name = "Band",
					Parent = model,
					Size = Vector3.new(sw, 0.6, 0.5),
					CFrame = base * CFrame.new(x, y - 0.3, sz * (d / 2 + 0.2)),
					Material = M.Concrete,
					Color = style.trimColor,
					CastShadow = false,
				})
			end
		end
	end
	-- Balconies on the front
	if o.balconies ~= false then
		for f = 2, floors do
			local y = (f - 1) * floorH
			for x = -w / 2 + 9, w / 2 - 9, 18 do
				if (ruinField and ruinField(x, -d / 2) < y + 2) or ctx:Chance(0.3) then
					continue
				end
				ctx:Part({
					Name = "Balcony",
					Parent = model,
					Size = Vector3.new(7, 0.6, 3),
					CFrame = base * CFrame.new(x, y - 0.3, -d / 2 - 1.5),
					Material = M.Concrete,
					Color = style.trimColor,
					Destructible = true,
				})
				ctx:Part({
					Name = "BalconyRail",
					Parent = model,
					Size = Vector3.new(7, 2.6, 0.3),
					CFrame = base * CFrame.new(x, y + 1.3, -d / 2 - 2.9),
					Material = M.Concrete,
					Color = style.trimColor,
					Destructible = true,
				})
			end
		end
	end
	if enterable then
		furnish(ctx, model, base, w - 2, d - 2, math.min(floors, 2), floorH, ruinField)
	end
	ruinDressing(ctx, model, base, w, d, ruin, style, totalH)
	ctx:AddMinimapCF("building", base, w, d)
	return model
end

---------------------------------------------------------------------------------------------------
-- Factory hall & chimney
---------------------------------------------------------------------------------------------------

--[[
	Buildings.FactoryHall(ctx, cf, opts) -> Model
	opts: width (90, along X), depth (48), height (22), bay (12), ruin (0), style ("SovietBrick"),
	      crane (true), machines (true)
]]
function Buildings.FactoryHall(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local style = resolveStyle(o.style or "SovietBrick")
	local w, d, h = o.width or 90, o.depth or 48, o.height or 22
	local bay = o.bay or 12
	local ruin = o.ruin or 0
	local model = ctx:Model(o.name or "FactoryHall", o.parent or ctx:Folder("Buildings"))
	local base = prepareSite(ctx, model, cf, w, d, o, style)
	local ruinField = makeRuinField(ctx, w, d, h, ruin)
	local metal = rgb(70, 60, 54)

	buildShell(ctx, model, base, {
		width = w,
		depth = d,
		floors = 1,
		floorH = h,
		wallT = 1.6,
		style = style,
		enterable = true,
		ruin = ruin,
		windowSpacing = bay,
		windowW = 6,
		sillY = 5,
		windowTop = h - 4,
		doorW = 12,
		doorH = 14,
		backDoor = true,
		sills = false,
		shutters = false,
		stairs = false,
		extraTop = 0,
		openingsFn = function(wall, _floor, l)
			local list = {}
			local n = math.max(1, math.floor(l / bay))
			for i = 1, n do
				local x = -l / 2 + l * (i - 0.5) / n
				if (wall == "front" or wall == "back" or wall == "left") and i == math.ceil(n / 2) then
					table.insert(list, { x = x, w = 12, y0 = 0, y1 = 14 })
				elseif wall == "right" and i == 1 then
					table.insert(list, { x = x, w = 5, y0 = 0, y1 = 8 })
				else
					table.insert(list, { x = x, w = 6, y0 = 5, y1 = h - 4 })
				end
			end
			return list
		end,
	}, ruinField)
	ctx:Part({
		Name = "Floor",
		Parent = model,
		Size = Vector3.new(w - 3, 0.4, d - 3),
		CFrame = base * CFrame.new(0, -0.2, 0),
		Material = M.Concrete,
		Color = rgb(96, 94, 90),
	})

	-- Steel roof trusses across the depth every bay; roof panels mostly gone when ruined
	local rise = 6
	local nb = math.floor(w / bay)
	for i = 0, nb do
		local x = -w / 2 + i * (w / nb)
		x = math.clamp(x, -w / 2 + 1.5, w / 2 - 1.5)
		local standingH = if ruinField then math.min(ruinField(x, -d / 2), ruinField(x, d / 2)) else h
		if standingH < h - 2 and ctx:Chance(0.7) then
			-- fallen truss
			if ctx:Chance(0.5) then
				ctx:Part({
					Name = "FallenTruss",
					Parent = model,
					Size = Vector3.new(1, 1.6, d * ctx:Range(0.5, 0.9)),
					CFrame = base
						* CFrame.new(x + ctx:Range(-3, 3), ctx:Range(1, 6), 0)
						* CFrame.Angles(ctx:Range(-0.35, 0.35), ctx:Range(-0.3, 0.3), ctx:Range(-0.4, 0.4)),
					Material = M.CorrodedMetal,
					Color = metal,
				})
			end
			continue
		end
		ctx:Part({
			Name = "TieBeam",
			Parent = model,
			Size = Vector3.new(0.8, 1.4, d - 1),
			CFrame = base * CFrame.new(x, h - 0.7, 0),
			Material = M.CorrodedMetal,
			Color = metal,
		})
		for _, sz in { -1, 1 } do
			local a = base * Vector3.new(x, h, sz * (d / 2 - 0.5))
			local b = base * Vector3.new(x, h + rise, 0)
			local rcf, l = Core.Between(a, b)
			ctx:Part({
				Name = "Rafter",
				Parent = model,
				Size = Vector3.new(0.8, 1.2, l),
				CFrame = rcf,
				Material = M.CorrodedMetal,
				Color = metal,
			})
			-- roof panel for this bay & side
			if i < nb and (ruin <= 0 or ctx:Chance(math.max(0, 0.9 - ruin * 1.1))) then
				local x2 = x + w / nb / 2
				local pa = base * Vector3.new(x2, h + 0.6, sz * (d / 2 + 0.6))
				local pb = base * Vector3.new(x2, h + rise + 0.6, 0)
				local pcf, pl = Core.Between(pa, pb)
				ctx:Part({
					Name = "RoofPanel",
					Parent = model,
					Size = Vector3.new(w / nb, 0.4, pl),
					CFrame = pcf,
					Material = M.CorrodedMetal,
					Color = rgb(84, 78, 72),
					Destructible = true,
				})
			end
		end
	end

	-- Overhead crane rail along both long walls + bridge beam
	if o.crane ~= false then
		for _, sz in { -1, 1 } do
			ctx:Part({
				Name = "CraneRail",
				Parent = model,
				Size = Vector3.new(w - 4, 1.2, 1.2),
				CFrame = base * CFrame.new(0, h - 5, sz * (d / 2 - 2.4)),
				Material = M.CorrodedMetal,
				Color = metal,
			})
		end
		local cx = ctx:Range(-w / 3, w / 3)
		ctx:Part({
			Name = "CraneBridge",
			Parent = model,
			Size = Vector3.new(2, 2, d - 4),
			CFrame = base * CFrame.new(cx, h - 4, 0),
			Material = M.CorrodedMetal,
			Color = rgb(110, 92, 50),
		})
		ctx:Part({
			Name = "CraneHook",
			Parent = model,
			Size = Vector3.new(0.3, 8, 0.3),
			CFrame = base * CFrame.new(cx, h - 9, ctx:Range(-d / 4, d / 4)),
			Material = M.Metal,
			Color = rgb(40, 40, 40),
			CanCollide = false,
			CastShadow = false,
		})
	end
	-- Machinery: big blocks = great cover in the open hall
	if o.machines ~= false then
		local rows = { -d / 4, d / 4 }
		for _, z in rows do
			for x = -w / 2 + bay, w / 2 - bay, bay * 1.4 do
				if ctx:Chance(0.3) then
					continue
				end
				local mw, mh, md = ctx:Range(5, 9), ctx:Range(3.5, 6), ctx:Range(3, 5)
				ctx:Part({
					Name = "Machine",
					Parent = model,
					Size = Vector3.new(mw, mh, md),
					CFrame = base * CFrame.new(x + ctx:Range(-2, 2), mh / 2, z + ctx:Range(-2, 2)),
					Material = M.DiamondPlate,
					Color = ctx:Pick({ rgb(66, 74, 66), rgb(76, 70, 62), rgb(58, 62, 66) }),
					NoPenetration = true,
				})
				if ctx:Chance(0.6) then
					ctx:Part({
						Name = "MachineTop",
						Parent = model,
						Shape = "Cylinder",
						Size = Vector3.new(mw * 0.7, 2.2, 2.2),
						CFrame = base * CFrame.new(x, mh + 1, z),
						Material = M.Metal,
						Color = rgb(60, 60, 58),
						CastShadow = false,
					})
				end
			end
		end
	end
	ruinDressing(ctx, model, base, w, d, ruin, style, h)
	ctx:AddMinimapCF("building", base, w, d)
	return model
end

--[[
	Buildings.Chimney(ctx, pos, opts) -> Model — tapered industrial brick chimney.
	opts: height (60), radius (4.5), ruin (0) — ruined chimneys are shorter with a broken top.
]]
function Buildings.Chimney(ctx: any, pos: Vector3, opts: { [string]: any }?): Model
	local o = opts or {}
	local h = o.height or 60
	local r = o.radius or 4.5
	local ruin = o.ruin or 0
	local model = ctx:Model("Chimney", o.parent or ctx:Folder("Buildings"))
	local gy = ctx:GroundY(pos.X, pos.Z)
	local segs = 6
	local standing = h * (1 - ruin * 0.45)
	local brick = rgb(124, 70, 56)
	ctx:Part({
		Name = "ChimneyBase",
		Parent = model,
		Size = Vector3.new(r * 2.6, 8, r * 2.6),
		CFrame = CFrame.new(pos.X, gy + 2, pos.Z),
		Material = M.Brick,
		Color = brick,
		NoPenetration = true,
	})
	for i = 0, segs - 1 do
		local y0 = i * h / segs
		if y0 > standing then
			break
		end
		local segH = math.min(h / segs, standing - y0)
		local rr = r * (1 - 0.35 * i / segs)
		ctx:Part({
			Name = "Chimney",
			Parent = model,
			Shape = "Cylinder",
			Size = Vector3.new(segH + 0.05, rr * 2, rr * 2),
			CFrame = CFrame.new(pos.X, gy + 6 + y0 + segH / 2, pos.Z) * CFrame.Angles(0, 0, math.pi / 2),
			Material = M.Brick,
			Color = ctx:Jitter(brick, 0.04),
			CastShadow = true,
		})
		if i % 2 == 1 and segH > h / segs * 0.9 then
			ctx:Part({
				Name = "Band",
				Parent = model,
				Shape = "Cylinder",
				Size = Vector3.new(0.6, rr * 2 + 0.4, rr * 2 + 0.4),
				CFrame = CFrame.new(pos.X, gy + 6 + y0 + segH, pos.Z) * CFrame.Angles(0, 0, math.pi / 2),
				Material = M.CorrodedMetal,
				Color = rgb(50, 46, 44),
				CastShadow = false,
			})
		end
	end
	if ruin > 0 then
		Terrain.RubbleMound(ctx, Vector3.new(pos.X + r * 2, 0, pos.Z), r * 2.2, 3, { M.Brick, M.Rock })
	end
	return model
end

---------------------------------------------------------------------------------------------------
-- Huts & sheds
---------------------------------------------------------------------------------------------------

--[[
	Buildings.Hut(ctx, cf, opts) -> Model — one-room wooden hut (izba, forest hut, Pacific hut).
	opts: width (12), depth (9), height (8), style ("Log" | "Timber" | table), stilts (false), ruin (0)
]]
function Buildings.Hut(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local style = resolveStyle(o.style or "Log")
	local w, d, h = o.width or 12, o.depth or 9, o.height or 8
	local ruin = o.ruin or 0
	local model = ctx:Model(o.name or "Hut", o.parent or ctx:Folder("Buildings"))
	local stilt = if o.stilts then 5 else 0
	local siteOpts = table.clone(o)
	siteOpts.plinth = 0.4 + stilt
	local base = prepareSite(ctx, model, cf, w, d, if o.stilts then { snap = false } else siteOpts, style)
	if o.stilts then
		local lo, hi = ctx:FootprintMinY(cf, w, d)
		base = CFrame.new(cf.Position.X, hi + stilt, cf.Position.Z) * (cf - cf.Position)
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local top = base.Position.Y
				local bottom = lo - 1
				ctx:Part({
					Name = "Stilt",
					Parent = model,
					Size = Vector3.new(0.9, top - bottom, 0.9),
					CFrame = base * CFrame.new(sx * (w / 2 - 0.6), -(top - bottom) / 2, sz * (d / 2 - 0.6)),
					Material = M.Wood,
					Color = style.trimColor,
				})
			end
		end
		ctx:Part({
			Name = "Ladder",
			Parent = model,
			Shape = "Truss",
			Size = Vector3.new(2, stilt + 2, 2),
			CFrame = base * CFrame.new(0, -stilt / 2 + 0.6, -d / 2 - 1.2),
			Color = style.trimColor,
		})
	end
	local ruinField = makeRuinField(ctx, w, d, h + 3, ruin)
	buildShell(ctx, model, base, {
		width = w,
		depth = d,
		floors = 1,
		floorH = h,
		wallT = 0.8,
		style = style,
		enterable = o.enterable ~= false,
		ruin = ruin,
		windowSpacing = 6,
		windowW = 2.4,
		sillY = 3,
		windowTop = 5.8,
		doorW = 3.6,
		doorH = 6.6,
		backDoor = false,
		sills = false,
		shutters = style.shutterColors ~= nil,
		stairs = false,
		extraTop = 0,
	}, ruinField)
	if o.enterable ~= false then
		ctx:Part({
			Name = "Floor",
			Parent = model,
			Size = Vector3.new(w - 1.6, 0.4, d - 1.6),
			CFrame = base * CFrame.new(0, -0.2, 0),
			Material = style.floor,
			Color = style.floorColor,
		})
	end
	if ruin < 0.75 then
		gableRoof(ctx, model, base * CFrame.new(0, h, 0), w, d, style, {
			ruin = ruin,
			wallT = 0.8,
			overhang = 1.5,
		})
	end
	if style.wall == M.Wood and ruin < 0.5 and o.chimney ~= false then
		chimneyOnRoof(ctx, model, base, w * 0.25, d * 0.15, h - 1, h + d * 0.5 + 1.5, style)
	end
	ruinDressing(ctx, model, base, w, d, ruin * 0.6, style, h)
	ctx:AddMinimapCF("building", base, w, d)
	return model
end

-- Small plank shed (not enterable by default, cheap filler).
function Buildings.Shed(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = table.clone(opts or {})
	o.style = o.style or "Timber"
	o.width = o.width or 8
	o.depth = o.depth or 6
	o.height = o.height or 6.5
	o.name = o.name or "Shed"
	o.chimney = false
	return Buildings.Hut(ctx, cf, o)
end

---------------------------------------------------------------------------------------------------
-- Windmill
---------------------------------------------------------------------------------------------------

--[[
	Buildings.Windmill(ctx, cf, opts) -> Model — wooden tower windmill on a stone base.
	The base room is enterable with a ladder to the lookout floor. Sails face cf.LookVector.
	opts: ruin (0) — ruined mills lose sails and part of the upper body.
]]
function Buildings.Windmill(ctx: any, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local ruin = o.ruin or 0
	local style = resolveStyle(o.style or "Farm")
	local model = ctx:Model(o.name or "Windmill", o.parent or ctx:Folder("Buildings"))
	local s = 12
	local base = prepareSite(ctx, model, cf, s, s, o, style)
	local ruinField = makeRuinField(ctx, s, s, 20, ruin * 0.5)
	buildShell(ctx, model, base, {
		width = s,
		depth = s,
		floors = 2,
		floorH = 9,
		wallT = 1.2,
		style = style,
		enterable = true,
		ruin = ruin * 0.5,
		windowSpacing = 6,
		windowW = 1.6,
		sillY = 3.5,
		windowTop = 7,
		doorW = 4,
		doorH = 7,
		backDoor = true,
		sills = false,
		shutters = false,
		stairs = false,
		extraTop = 0,
	}, ruinField)
	ctx:Part({
		Name = "Floor2",
		Parent = model,
		Size = Vector3.new(s - 2.4, 0.6, s - 5),
		CFrame = base * CFrame.new(0, 8.7, -1.3),
		Material = M.WoodPlanks,
		Color = rgb(96, 74, 52),
	})
	ctx:Part({
		Name = "Ladder",
		Parent = model,
		Shape = "Truss",
		Size = Vector3.new(2, 9, 2),
		CFrame = base * CFrame.new(-2, 4.5, s / 2 - 2.4),
		Color = rgb(84, 64, 46),
	})
	-- Tapered wooden body: two stacked boxes
	local wood = rgb(96, 78, 58)
	local bodyKeep = 1 - ruin * 0.6
	local y = 18
	for i, size in { 10, 8 } do
		if i == 2 and ruin > 0.5 then
			break
		end
		local hh = 7 * (if i == 2 then bodyKeep else 1)
		ctx:Part({
			Name = "Body",
			Parent = model,
			Size = Vector3.new(size, hh, size),
			CFrame = base * CFrame.new(0, y + hh / 2, 0) * CFrame.Angles(0, math.rad(45 * (i - 1)), 0),
			Material = M.WoodPlanks,
			Color = ctx:Jitter(wood, 0.05),
			Destructible = true,
		})
		y += hh
	end
	-- Cap and sails
	local hub = base * CFrame.new(0, y + 1, -5.5)
	if ruin < 0.8 then
		ctx:Part({
			Name = "Cap",
			Parent = model,
			Shape = "Wedge",
			Size = Vector3.new(7, 3, 6),
			CFrame = base * CFrame.new(0, y + 1.5, 0),
			Material = M.WoodPlanks,
			Color = rgb(70, 58, 46),
		})
	end
	ctx:Part({
		Name = "Hub",
		Parent = model,
		Shape = "Cylinder",
		Size = Vector3.new(3, 1.6, 1.6),
		CFrame = hub * CFrame.Angles(0, math.pi / 2, 0),
		Material = M.Wood,
		Color = rgb(60, 48, 38),
	})
	local spin = ctx:Range(0, math.pi / 2)
	for i = 0, 3 do
		local broken = ruin > 0 and ctx:Chance(ruin * 0.6)
		local len = if broken then ctx:Range(4, 8) else 18
		local arm = hub * CFrame.Angles(0, 0, spin + i * math.pi / 2) * CFrame.new(0, len / 2 + 0.8, -0.6)
		ctx:Part({
			Name = "SailArm",
			Parent = model,
			Size = Vector3.new(0.7, len, 0.5),
			CFrame = arm,
			Material = M.Wood,
			Color = rgb(78, 62, 46),
			CastShadow = false,
		})
		if not broken then
			ctx:Part({
				Name = "Sail",
				Parent = model,
				Size = Vector3.new(4, len - 3, 0.2),
				CFrame = arm * CFrame.new(2.3, 1.2, 0),
				Material = M.WoodPlanks,
				Color = rgb(126, 110, 88),
				Transparency = 0.15,
				CastShadow = false,
				CanQuery = false,
			})
		else
			-- fallen sail lying at the foot of the mill
			local p = base * CFrame.new(ctx:Range(-10, 10), 0.5, ctx:Range(-14, -8))
			ctx:Part({
				Name = "FallenSail",
				Parent = model,
				Size = Vector3.new(4, 0.4, 14),
				CFrame = p * CFrame.Angles(ctx:Range(-0.2, 0.2), ctx:Range(0, 6.28), ctx:Range(-0.15, 0.15)),
				Material = M.WoodPlanks,
				Color = rgb(110, 96, 76),
			})
		end
	end
	ruinDressing(ctx, model, base, s, s, ruin * 0.5, style, 18)
	ctx:AddMinimapCF("building", base, s, s)
	return model
end

---------------------------------------------------------------------------------------------------
-- Free-standing ruined wall fragment
---------------------------------------------------------------------------------------------------

--[[
	Buildings.RuinedWall(ctx, cf, length, height, opts) -> Model
	A jagged remnant of a building facade (with window holes) — city clutter and cover.
	opts: material, color, thickness (1.2), windows (true), ruin (0.6), floorH (10)
]]
function Buildings.RuinedWall(ctx: any, cf: CFrame, length: number, height: number, opts: { [string]: any }?): Model
	local o = opts or {}
	local style = resolveStyle(o.style or "Soviet")
	local model = ctx:Model("RuinedWall", o.parent or ctx:Folder("Buildings"))
	local gy = ctx:GroundY(cf.Position.X, cf.Position.Z)
	local base = CFrame.new(cf.Position.X, gy - 0.5, cf.Position.Z) * (cf - cf.Position)
	local ruin = o.ruin or 0.6
	local field = makeRuinField(ctx, length, 2, height, ruin)
	local floorH = o.floorH or 10
	local floors = math.max(1, math.ceil(height / floorH))
	local color = o.color or ctx:Pick(style.wallColors)
	for f = 1, floors do
		local y = (f - 1) * floorH
		local openings = {}
		if o.windows ~= false then
			local n = math.floor((length - 3) / 6)
			for i = 1, n do
				table.insert(openings, { x = -length / 2 + length * (i - 0.5) / n, w = 3.2, y0 = 3, y1 = 7.5 })
			end
		end
		Buildings.Wall(ctx, model, base * CFrame.new(0, y, 0), length, math.min(floorH, height - y), {
			thickness = o.thickness or 1.2,
			material = o.material or style.wall,
			color = color,
			openings = openings,
			chunk = 4,
			clip = if field
				then function(x)
					return field(x, 0) - y
				end
				else nil,
		})
	end
	Terrain.RubbleMound(
		ctx,
		(base * CFrame.new(ctx:Range(-length / 3, length / 3), 0, ctx:Range(-5, 5))).Position,
		ctx:Range(3, 6),
		2,
		style.rubble
	)
	return model
end

return Buildings
