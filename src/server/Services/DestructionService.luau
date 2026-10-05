--[[
	DestructionService (Map team)

	Listens to Bus "Explosion"(position, radius, power, attacker) and:
	  * damages parts under workspace.Map tagged "Destructible" (or inside a Model tagged so).
	    Each part has health (attribute "Health", else derived from material and size); when it
	    reaches 0 the part is replaced by a few physics debris chunks (CollisionGroup "Debris",
	    non-queryable) that settle, then despawn. Parts resting on a broken part may collapse too.
	  * leaves small persistent terrain rubble heaps at the foot of broken walls (cover!).
	  * carves small scorched craters into terrain for big blasts.
	Everything is capped (per explosion and globally) so spam cannot tank the server.
	Debris lives in workspace.Map.Debris, so it is cleared with the map; craters/rubble vanish with
	Terrain:Clear() on map reload.

	Attribute contract: a destructible part may set "Health" (number) to override its toughness.
	Power semantics: `power` is the explosion's max damage (grenade ~100, tank shell ~200-400,
	satchel ~600). Damage to a part = power * falloff(distance / radius).

	API: DestructionService.BreakPart(part, origin?) -- break a destructible part immediately.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Constants = require(Shared.Config.Constants)

local DestructionService = {}

local TAG = Constants.TAGS.Destructible
local DEBRIS_GROUP = Constants.COLLISION_GROUPS.Debris

local MAX_BREAKS_PER_EXPLOSION = 14
local MAX_PIECES_PER_PART = 6
local MAX_PIECES_PER_EXPLOSION = 40
local MAX_LIVE_DEBRIS = 260
local SETTLE_TIME = 4
local DEBRIS_LIFETIME = 25
local MAX_RUBBLE_PER_MAP = 400
local MAX_CRATERS_PER_MAP = 220
local CRATER_MIN_POWER = 150
local CASCADE_DEPTH = 3

local MATERIAL_HEALTH: { [Enum.Material]: number } = {
	[Enum.Material.Glass] = 20,
	[Enum.Material.WoodPlanks] = 140,
	[Enum.Material.Wood] = 180,
	[Enum.Material.Fabric] = 260,
	[Enum.Material.Grass] = 120,
	[Enum.Material.Plaster] = 260,
	[Enum.Material.RoofShingles] = 160,
	[Enum.Material.ClayRoofTiles] = 160,
	[Enum.Material.Slate] = 260,
	[Enum.Material.Brick] = 380,
	[Enum.Material.Cobblestone] = 420,
	[Enum.Material.Limestone] = 400,
	[Enum.Material.Sandstone] = 380,
	[Enum.Material.Concrete] = 600,
	[Enum.Material.CorrodedMetal] = 700,
	[Enum.Material.Metal] = 800,
	[Enum.Material.DiamondPlate] = 900,
}

-- Terrain material used for the rubble left by a broken part.
local RUBBLE_MATERIAL: { [Enum.Material]: Enum.Material } = {
	[Enum.Material.Brick] = Enum.Material.Brick,
	[Enum.Material.Concrete] = Enum.Material.Concrete,
	[Enum.Material.Plaster] = Enum.Material.Concrete,
	[Enum.Material.Cobblestone] = Enum.Material.Cobblestone,
	[Enum.Material.Limestone] = Enum.Material.Limestone,
	[Enum.Material.Sandstone] = Enum.Material.Sandstone,
	[Enum.Material.Slate] = Enum.Material.Slate,
	[Enum.Material.WoodPlanks] = Enum.Material.WoodPlanks,
	[Enum.Material.Wood] = Enum.Material.WoodPlanks,
}

local liveDebris: { BasePart } = {}
local rubbleCount = 0
local craterCount = 0
local lastCrater = 0

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include

local terrainRay = RaycastParams.new()
terrainRay.FilterType = Enum.RaycastFilterType.Include
terrainRay.IgnoreWater = false

local function mapFolder(): Instance?
	return Workspace:FindFirstChild("Map")
end

local function debrisFolder(map: Instance): Folder
	local f = map:FindFirstChild("Debris")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Debris"
		f.Parent = map
	end
	return f :: Folder
end

local function isDestructible(part: BasePart): boolean
	if CollectionService:HasTag(part, TAG) then
		return true
	end
	local parent = part.Parent
	for _ = 1, 3 do
		if not parent or not parent:IsA("Model") then
			return false
		end
		if CollectionService:HasTag(parent, TAG) then
			return true
		end
		parent = parent.Parent
	end
	return false
end

local function baseHealth(part: BasePart): number
	local attr = part:GetAttribute("Health")
	if type(attr) == "number" then
		return attr
	end
	local s = part.Size
	local volume = s.X * s.Y * s.Z
	local mat = MATERIAL_HEALTH[part.Material] or 300
	return mat * math.clamp(math.sqrt(volume) / 6, 0.4, 2.5)
end

-- Distance from a point to the surface of an (unrotated-box approximated) part.
local function distanceToPart(part: BasePart, point: Vector3): number
	local rel = part.CFrame:PointToObjectSpace(point)
	local h = part.Size / 2
	local clamped =
		Vector3.new(math.clamp(rel.X, -h.X, h.X), math.clamp(rel.Y, -h.Y, h.Y), math.clamp(rel.Z, -h.Z, h.Z))
	return (rel - clamped).Magnitude
end

---------------------------------------------------------------------------------------------------
-- Debris
---------------------------------------------------------------------------------------------------

local function trimDebris()
	while #liveDebris > MAX_LIVE_DEBRIS do
		local oldest = table.remove(liveDebris, 1)
		if oldest and oldest.Parent then
			oldest:Destroy()
		end
	end
end

local function spawnPiece(map: Instance, cf: CFrame, size: Vector3, source: BasePart, origin: Vector3)
	local piece = Instance.new("Part")
	piece.Name = "Debris"
	piece.Size = size
	piece.CFrame = cf
	piece.Material = source.Material
	piece.Color = source.Color
	piece.TopSurface = Enum.SurfaceType.Smooth
	piece.BottomSurface = Enum.SurfaceType.Smooth
	piece.CanQuery = false
	piece.CanTouch = false
	piece.CastShadow = false
	piece.CollisionGroup = DEBRIS_GROUP
	piece.Anchored = false
	local away = cf.Position - origin
	local dir = if away.Magnitude > 0.01 then away.Unit else Vector3.yAxis
	piece.AssemblyLinearVelocity = dir * math.random(18, 40) + Vector3.new(0, math.random(10, 26), 0)
	piece.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 12
	piece.Parent = debrisFolder(map)
	table.insert(liveDebris, piece)
	task.delay(SETTLE_TIME, function()
		if piece.Parent then
			piece.Anchored = true
		end
	end)
	task.delay(DEBRIS_LIFETIME + math.random() * 5, function()
		if piece.Parent then
			piece:Destroy()
		end
		local idx = table.find(liveDebris, piece)
		if idx then
			table.remove(liveDebris, idx)
		end
	end)
end

local function leaveRubble(part: BasePart)
	if rubbleCount >= MAX_RUBBLE_PER_MAP then
		return
	end
	local s = part.Size
	if s.X * s.Y * s.Z < 12 then
		return
	end
	local mat = RUBBLE_MATERIAL[part.Material]
	if not mat then
		return
	end
	terrainRay.FilterDescendantsInstances = { Workspace.Terrain }
	local hit = Workspace:Raycast(part.Position, Vector3.new(0, -(s.Y / 2 + 6), 0), terrainRay)
	if not hit or hit.Material == Enum.Material.Water then
		return
	end
	rubbleCount += 1
	local r = math.clamp(math.max(s.X, s.Z) * 0.3, 1.2, 2.6)
	Workspace.Terrain:FillBall(hit.Position - Vector3.new(0, r * 0.4, 0), r, mat)
end

---------------------------------------------------------------------------------------------------
-- Breaking
---------------------------------------------------------------------------------------------------

type Budget = { breaks: number, pieces: number }

local breakPart: (part: BasePart, origin: Vector3, budget: Budget, depth: number) -> ()

local function collapseAbove(part: BasePart, origin: Vector3, budget: Budget, depth: number)
	if depth >= CASCADE_DEPTH then
		return
	end
	local map = mapFolder()
	if not map then
		return
	end
	local top = part.Position.Y + part.Size.Y / 2
	local bb = part.CFrame * CFrame.new(0, part.Size.Y / 2 + 0.4, 0)
	overlap.FilterDescendantsInstances = { map }
	local above = Workspace:GetPartBoundsInBox(bb, Vector3.new(part.Size.X * 0.9, 0.8, part.Size.Z * 0.9), overlap)
	for _, other in above do
		if other ~= part and other.Anchored and isDestructible(other) then
			local bottom = other.Position.Y - other.Size.Y / 2
			-- only parts resting on (not merely touching) the broken one
			if math.abs(bottom - top) < 0.8 and other.Size.Y < 16 then
				task.delay(0.08 * (depth + 1), function()
					if other.Parent then
						breakPart(other, origin, budget, depth + 1)
					end
				end)
			end
		end
	end
end

breakPart = function(part: BasePart, origin: Vector3, budget: Budget, depth: number)
	if budget.breaks <= 0 or not part.Parent then
		return
	end
	budget.breaks -= 1
	local map = mapFolder()
	if not map then
		part:Destroy()
		return
	end
	local s = part.Size
	local nx = math.clamp(math.ceil(s.X / 2.5), 1, 3)
	local ny = math.clamp(math.ceil(s.Y / 2.5), 1, 3)
	local nz = math.clamp(math.ceil(s.Z / 2.5), 1, 3)
	local cells = {}
	for i = 0, nx - 1 do
		for j = 0, ny - 1 do
			for k = 0, nz - 1 do
				table.insert(cells, { i, j, k })
			end
		end
	end
	local pieces = math.min(#cells, MAX_PIECES_PER_PART, budget.pieces)
	local cellSize = Vector3.new(s.X / nx, s.Y / ny, s.Z / nz)
	for _ = 1, pieces do
		local c = table.remove(cells, math.random(1, #cells))
		local offset = Vector3.new(
			-s.X / 2 + (c[1] + 0.5) * cellSize.X,
			-s.Y / 2 + (c[2] + 0.5) * cellSize.Y,
			-s.Z / 2 + (c[3] + 0.5) * cellSize.Z
		)
		local pieceSize = Vector3.new(
			math.max(0.3, cellSize.X * (0.6 + math.random() * 0.3)),
			math.max(0.3, cellSize.Y * (0.6 + math.random() * 0.3)),
			math.max(0.3, cellSize.Z * (0.6 + math.random() * 0.3))
		)
		spawnPiece(map, part.CFrame * CFrame.new(offset), pieceSize, part, origin)
	end
	budget.pieces -= pieces
	trimDebris()
	leaveRubble(part)
	collapseAbove(part, origin, budget, depth)
	-- Children such as Fire/lights die with the part; models left empty are cleaned up.
	local parentModel = part.Parent
	part:Destroy()
	if parentModel and parentModel:IsA("Model") and #parentModel:GetChildren() == 0 then
		parentModel:Destroy()
	end
end

function DestructionService.BreakPart(part: BasePart, origin: Vector3?)
	if typeof(part) == "Instance" and part:IsA("BasePart") and part.Parent then
		breakPart(
			part,
			origin or part.Position,
			{ breaks = MAX_BREAKS_PER_EXPLOSION, pieces = MAX_PIECES_PER_EXPLOSION },
			0
		)
	end
end

---------------------------------------------------------------------------------------------------
-- Craters
---------------------------------------------------------------------------------------------------

local SCORCHABLE = {
	Enum.Material.Grass,
	Enum.Material.LeafyGrass,
	Enum.Material.Snow,
	Enum.Material.Sand,
	Enum.Material.Ground,
}

local function nearHQ(pos: Vector3): boolean
	local ok, info = pcall(function()
		local ms = script.Parent:FindFirstChild("MapService")
		return ms and (require(ms) :: any).GetMapInfo()
	end)
	if not ok or type(info) ~= "table" or type(info.hq) ~= "table" then
		return false
	end
	for _, side in { "Allies", "Axis" } do
		for _, cf in info.hq[side] or {} do
			if typeof(cf) == "CFrame" and (cf.Position - pos).Magnitude < 70 then
				return true
			end
		end
	end
	return false
end

local function carveCrater(position: Vector3, radius: number, power: number)
	if power < CRATER_MIN_POWER or craterCount >= MAX_CRATERS_PER_MAP then
		return
	end
	local now = os.clock()
	if now - lastCrater < 0.25 then
		return
	end
	terrainRay.FilterDescendantsInstances = { Workspace.Terrain }
	local hit = Workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -8, 0), terrainRay)
	if not hit or hit.Material == Enum.Material.Water or hit.Material == Enum.Material.Ice then
		return
	end
	if nearHQ(hit.Position) then
		return
	end
	lastCrater = now
	craterCount += 1
	local r = math.clamp(radius * 0.3 * math.clamp(power / 250, 0.7, 1.4), 2, 6)
	local terrain = Workspace.Terrain
	terrain:FillBall(hit.Position + Vector3.new(0, r * 0.55, 0), r, Enum.Material.Air)
	local box = CFrame.new(hit.Position)
	for _, src in SCORCHABLE do
		terrain:ReplaceMaterialInTransform(box, Vector3.new(r * 2.4, r * 2, r * 2.4), src, Enum.Material.Mud)
	end
end

---------------------------------------------------------------------------------------------------
-- Explosion handler
---------------------------------------------------------------------------------------------------

local function onExplosion(position: any, radius: any, power: any, _attacker: any)
	if typeof(position) ~= "Vector3" or type(radius) ~= "number" then
		return
	end
	radius = math.clamp(radius, 0.5, 60)
	local p: number = if type(power) == "number" then math.clamp(power, 0, 5000) else 100
	local map = mapFolder()
	if not map then
		return
	end

	overlap.FilterDescendantsInstances = { map }
	local parts = Workspace:GetPartBoundsInRadius(position, radius * 1.15, overlap)
	local hits = {}
	for _, part in parts do
		if part.Anchored and isDestructible(part) and not part:IsDescendantOf(debrisFolder(map)) then
			local d = distanceToPart(part, position)
			if d <= radius then
				table.insert(hits, { part = part, d = d })
			end
		end
	end
	table.sort(hits, function(a, b)
		return a.d < b.d
	end)

	local budget: Budget = { breaks = MAX_BREAKS_PER_EXPLOSION, pieces = MAX_PIECES_PER_EXPLOSION }
	for _, h in hits do
		if budget.breaks <= 0 then
			break
		end
		local part = h.part
		if not part.Parent then
			continue
		end
		local falloff = 1 - math.clamp(h.d / radius, 0, 1) ^ 1.5 * 0.85
		local damage = p * falloff
		local hp = part:GetAttribute("CurrentHealth")
		if type(hp) ~= "number" then
			hp = baseHealth(part)
		end
		hp -= damage
		if hp <= 0 then
			breakPart(part, position, budget, 0)
		else
			part:SetAttribute("CurrentHealth", hp)
		end
	end

	carveCrater(position, radius, p)
end

local function resetState()
	table.clear(liveDebris)
	rubbleCount = 0
	craterCount = 0
end

function DestructionService:Init() end

function DestructionService:Start()
	Bus.connect("Explosion", function(...)
		local ok, err = pcall(onExplosion, ...)
		if not ok then
			warn(`[DestructionService] explosion error: {err}`)
		end
	end)
	Bus.connect("MapUnloading", resetState)
	Bus.connect("MapLoaded", resetState)
end

return DestructionService
