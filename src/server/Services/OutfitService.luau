--[[
	OutfitService (Animation/Models team, server)

		OutfitService.Apply(character, factionId, classId)

	Dresses an R15 character procedurally (no clothing assets):
	  * removes accessories / Shirt / Pants / BodyColors / CharacterMeshes,
	  * colours body parts directly (tunic on torso + arms, trousers on legs, boots on feet,
	    jackboots / puttees / leggings on the shins depending on faction, varied skin tones),
	  * builds the faction helmet from Parts (M1, Brodie, SSh40, Adrian + crest, Stahlhelm with flared
	    skirt, Type 90 with star, M33) - Recon wears a soft field cap instead,
	  * adds webbing (belt, braces, pouches, backpack + bedroll, canteen) and class gear
	    (Medic armband + aid bag, Support bandolier + ammo can, Engineer tool bag + wrench,
	    Recon binocular case, Assault magazine pouches, Rifleman ammo pouches + grenade).

	All extra parts (<= ~25) are Massless, CanCollide/CanQuery/CanTouch=false, welded to the body,
	and live in a Model named "Outfit" under the character. Apply is idempotent (rebuilds).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Factions = require(Shared.Config.Factions)

local OutfitService = {}

local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local FABRIC = Enum.Material.Fabric
local METAL = Enum.Material.Metal
local LEATHER = Enum.Material.Leather
local PLASTIC = Enum.Material.SmoothPlastic

local SKIN_TONES = {
	Color3.fromRGB(234, 192, 158),
	Color3.fromRGB(222, 176, 140),
	Color3.fromRGB(204, 156, 118),
	Color3.fromRGB(176, 128, 92),
	Color3.fromRGB(140, 96, 66),
	Color3.fromRGB(104, 70, 48),
	Color3.fromRGB(240, 206, 176),
}

-- Shin wraps per faction: "boots" (jackboots), "puttees", "leggings" (US canvas), "anklets"
local SHIN_STYLE = {
	US = "leggings",
	UK = "anklets",
	USSR = "boots",
	FR = "puttees",
	DE = "boots",
	JP = "puttees",
	IT = "puttees",
}

local REMOVE_CLASSES = {
	Accessory = true,
	Hat = true,
	Shirt = true,
	Pants = true,
	ShirtGraphic = true,
	BodyColors = true,
	CharacterMesh = true,
}

type Ctx = { model: Model, count: number }

local function shade(c: Color3, k: number): Color3
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

-- Creates a part welded to `body` at `offset` (body space).
local function add(
	ctx: Ctx,
	body: BasePart?,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): Part?
	if not body then
		return nil
	end
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	if shape then
		part.Shape = shape
	end
	part.Color = color
	part.Material = material or FABRIC
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = size.Magnitude > 0.5
	part.CFrame = body.CFrame * offset
	local weld = Instance.new("Weld")
	weld.Part0 = body
	weld.Part1 = part
	weld.C0 = offset
	weld.Parent = part
	part.Parent = ctx.model
	ctx.count += 1
	return part
end

-- Ellipsoid (helmet domes, caps): a Part with a Sphere SpecialMesh.
local function dome(ctx: Ctx, body: BasePart?, name: string, size: Vector3, offset: CFrame, color: Color3): Part?
	local part = add(ctx, body, name, size, offset, color, METAL)
	if part then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	end
	return part
end

local function disc(ctx: Ctx, body: BasePart?, name: string, d: number, h: number, offset: CFrame, color: Color3): Part?
	return add(ctx, body, name, V3(h, d, d), offset * ANG(0, 0, math.pi / 2), color, METAL, Enum.PartType.Cylinder)
end

--------------------------------------------------------------------------------------------------
-- Headgear (all offsets relative to the Head centre, scaled by head height)
--------------------------------------------------------------------------------------------------

local function buildHelmet(ctx: Ctx, head: BasePart, style: string, color: Color3, accent: Color3)
	local k = head.Size.Y / 1.2
	local w = head.Size.X / 1.2
	local dark = shade(color, 0.75)
	if style == "Brodie" then
		disc(ctx, head, "HelmetBrim", 1.95 * w, 0.05 * k, CF(0, 0.34 * k, 0), color)
		dome(ctx, head, "HelmetDome", V3(1.3 * w, 0.62 * k, 1.36 * w), CF(0, 0.45 * k, 0), color)
		add(ctx, head, "HelmetStrap", V3(1.24 * w, 0.06 * k, 0.06), CF(0, -0.45 * k, -0.1), shade(color, 0.6), LEATHER)
	elseif style == "Stahlhelm" then
		dome(ctx, head, "HelmetDome", V3(1.44 * w, 1.0 * k, 1.5 * w), CF(0, 0.38 * k, 0.02), color)
		add(
			ctx,
			head,
			"HelmetVisor",
			V3(1.2 * w, 0.06 * k, 0.2),
			CF(0, 0.28 * k, -0.66 * w) * ANG(0.25, 0, 0),
			color,
			METAL
		)
		add(
			ctx,
			head,
			"HelmetNeck",
			V3(1.25 * w, 0.4 * k, 0.12),
			CF(0, 0.05 * k, 0.66 * w) * ANG(-0.4, 0, 0),
			color,
			METAL
		)
		add(
			ctx,
			head,
			"HelmetFlareL",
			V3(0.12, 0.4 * k, 1.0 * w),
			CF(-0.66 * w, 0.08 * k, 0.12) * ANG(0, 0, -0.35),
			color,
			METAL
		)
		add(
			ctx,
			head,
			"HelmetFlareR",
			V3(0.12, 0.4 * k, 1.0 * w),
			CF(0.66 * w, 0.08 * k, 0.12) * ANG(0, 0, 0.35),
			color,
			METAL
		)
	elseif style == "SSh40" then
		dome(ctx, head, "HelmetDome", V3(1.42 * w, 1.05 * k, 1.5 * w), CF(0, 0.35 * k, 0.02), color)
		disc(ctx, head, "HelmetRim", 1.52 * w, 0.06 * k, CF(0, 0.26 * k, 0.05), dark)
		add(
			ctx,
			head,
			"HelmetNeck",
			V3(1.1 * w, 0.28 * k, 0.1),
			CF(0, 0.12 * k, 0.68 * w) * ANG(-0.2, 0, 0),
			color,
			METAL
		)
	elseif style == "Adrian" then
		dome(ctx, head, "HelmetDome", V3(1.36 * w, 0.95 * k, 1.42 * w), CF(0, 0.38 * k, 0), color)
		add(
			ctx,
			head,
			"HelmetVisor",
			V3(1.1 * w, 0.05 * k, 0.32),
			CF(0, 0.28 * k, -0.74 * w) * ANG(0.3, 0, 0),
			color,
			METAL
		)
		add(
			ctx,
			head,
			"HelmetBack",
			V3(1.1 * w, 0.05 * k, 0.3),
			CF(0, 0.26 * k, 0.74 * w) * ANG(-0.35, 0, 0),
			color,
			METAL
		)
		add(ctx, head, "HelmetCrest", V3(0.1, 0.22 * k, 1.1 * w), CF(0, 0.88 * k, 0.02), dark, METAL)
		add(ctx, head, "HelmetBadge", V3(0.22, 0.2, 0.04), CF(0, 0.55 * k, -0.7 * w), accent, METAL)
	elseif style == "Type90" then
		dome(ctx, head, "HelmetDome", V3(1.38 * w, 0.88 * k, 1.44 * w), CF(0, 0.4 * k, 0), color)
		disc(ctx, head, "HelmetRim", 1.5 * w, 0.05 * k, CF(0, 0.3 * k, 0), dark)
		local star = add(
			ctx,
			head,
			"HelmetStar",
			V3(0.16, 0.16, 0.04),
			CF(0, 0.58 * k, -0.69 * w) * ANG(0, 0, math.pi / 4),
			Color3.fromRGB(220, 180, 40),
			METAL
		)
		if star then
			star.CastShadow = false
		end
	elseif style == "M33" then
		dome(ctx, head, "HelmetDome", V3(1.4 * w, 0.98 * k, 1.48 * w), CF(0, 0.37 * k, 0.02), color)
		add(
			ctx,
			head,
			"HelmetVisor",
			V3(1.05 * w, 0.05 * k, 0.18),
			CF(0, 0.3 * k, -0.7 * w) * ANG(0.15, 0, 0),
			color,
			METAL
		)
		add(
			ctx,
			head,
			"HelmetSkirt",
			V3(1.3 * w, 0.22 * k, 0.1),
			CF(0, 0.16 * k, 0.7 * w) * ANG(-0.25, 0, 0),
			color,
			METAL
		)
	else -- "M1" (default)
		dome(ctx, head, "HelmetDome", V3(1.46 * w, 0.98 * k, 1.52 * w), CF(0, 0.38 * k, 0.02), color)
		disc(ctx, head, "HelmetRim", 1.62 * w, 0.06 * k, CF(0, 0.24 * k, 0.04), dark)
		add(ctx, head, "HelmetNet", V3(1.0 * w, 0.06, 1.1 * w), CF(0, 0.86 * k, 0.02), shade(color, 0.85), FABRIC)
	end
	-- chin strap (all helmets except Brodie, which has its own)
	if style ~= "Brodie" then
		add(ctx, head, "ChinStrap", V3(1.22 * w, 0.06, 0.06), CF(0, -0.45 * k, -0.12), shade(color, 0.55), LEATHER)
	end
end

local function buildCap(ctx: Ctx, head: BasePart, color: Color3, accent: Color3)
	local k = head.Size.Y / 1.2
	local w = head.Size.X / 1.2
	dome(ctx, head, "CapCrown", V3(1.3 * w, 0.55 * k, 1.36 * w), CF(0, 0.52 * k, 0), color)
	disc(ctx, head, "CapBand", 1.28 * w, 0.18 * k, CF(0, 0.42 * k, 0), shade(color, 0.85))
	add(
		ctx,
		head,
		"CapVisor",
		V3(0.9 * w, 0.05, 0.36),
		CF(0, 0.36 * k, -0.72 * w) * ANG(0.2, 0, 0),
		shade(color, 0.5),
		LEATHER
	)
	add(ctx, head, "CapBadge", V3(0.14, 0.14, 0.04), CF(0, 0.45 * k, -0.66 * w), accent, METAL)
end

--------------------------------------------------------------------------------------------------
-- Webbing + class gear
--------------------------------------------------------------------------------------------------

local function buildWebbing(ctx: Ctx, character: Model, f: Factions.Faction)
	local ut = character:FindFirstChild("UpperTorso") :: BasePart?
	local lt = character:FindFirstChild("LowerTorso") :: BasePart?
	if not (ut and lt) then
		return
	end
	local web = f.colors.webbing
	local ts, ls = ut.Size, lt.Size
	add(ctx, lt, "Belt", V3(ls.X + 0.08, 0.26, ls.Z + 0.08), CF(0, 0.08, 0), web, FABRIC)
	add(ctx, lt, "Buckle", V3(0.22, 0.18, 0.04), CF(0, 0.08, -ls.Z / 2 - 0.05), Color3.fromRGB(150, 140, 110), METAL)
	-- braces over the shoulders (front + back in one part each)
	for i, x in { -ts.X * 0.25, ts.X * 0.25 } do
		add(ctx, ut, `Brace{i}`, V3(0.16, ts.Y + 0.02, ts.Z + 0.06), CF(x, 0, 0), shade(web, 0.95), FABRIC)
	end
	-- pack + bedroll
	add(ctx, ut, "Pack", V3(ts.X * 0.6, ts.Y * 0.62, 0.42), CF(0, 0.05, ts.Z / 2 + 0.2), shade(web, 0.9), FABRIC)
	add(
		ctx,
		ut,
		"Bedroll",
		V3(ts.X * 0.75, 0.32, 0.32),
		CF(0, ts.Y * 0.36, ts.Z / 2 + 0.2),
		shade(f.colors.trousers, 0.8),
		FABRIC,
		Enum.PartType.Cylinder
	)
	-- canteen on the right hip
	add(
		ctx,
		lt,
		"Canteen",
		V3(0.3, 0.42, 0.42),
		CF(ls.X / 2 - 0.15, -0.15, ls.Z / 2 + 0.12) * ANG(0, 0, math.pi / 2),
		shade(web, 0.75),
		FABRIC,
		Enum.PartType.Cylinder
	)
	if f.id == "DE" then
		-- gas mask canister (ribbed cylinder) on the back hip
		add(
			ctx,
			lt,
			"GasMaskCan",
			V3(0.75, 0.32, 0.32),
			CF(-ls.X / 2 + 0.3, -0.25, ls.Z / 2 + 0.2) * ANG(0, 0, math.pi / 2),
			Color3.fromRGB(86, 92, 78),
			METAL,
			Enum.PartType.Cylinder
		)
	end
end

local function pouchRow(ctx: Ctx, lt: BasePart, n: number, size: Vector3, color: Color3, prefix: string)
	local spacing = size.X + 0.06
	local start = -(n - 1) * spacing / 2
	for i = 1, n do
		local x = start + (i - 1) * spacing
		if math.abs(x) < 0.15 then
			x += if x < 0 then -0.2 else 0.2 -- keep the buckle visible
		end
		add(
			ctx,
			lt,
			`{prefix}{i}`,
			size,
			CF(x, 0.08 - size.Y * 0.15, -lt.Size.Z / 2 - size.Z / 2 - 0.03),
			color,
			FABRIC
		)
	end
end

local function buildClassGear(ctx: Ctx, character: Model, f: Factions.Faction, classId: string)
	local ut = character:FindFirstChild("UpperTorso") :: BasePart?
	local lt = character:FindFirstChild("LowerTorso") :: BasePart?
	local rua = character:FindFirstChild("RightUpperArm") :: BasePart?
	local lua = character:FindFirstChild("LeftUpperArm") :: BasePart?
	if not (ut and lt) then
		return
	end
	local web = shade(f.colors.webbing, 0.9)
	local ts, ls = ut.Size, lt.Size

	if classId == "Assault" then
		pouchRow(ctx, lt, 3, V3(0.28, 0.5, 0.16), web, "MagPouch")
		add(ctx, ut, "ChestPouch", V3(0.5, 0.36, 0.14), CF(-ts.X * 0.25, -0.15, -ts.Z / 2 - 0.08), web, FABRIC)
	elseif classId == "Support" then
		add(
			ctx,
			ut,
			"Bandolier",
			V3(0.28, ts.Y * 1.35, ts.Z + 0.1),
			CF(0, 0, 0) * ANG(0, 0, 0.62),
			Color3.fromRGB(150, 120, 60),
			LEATHER
		)
		add(ctx, lt, "AmmoCan", V3(0.4, 0.5, 0.3), CF(-ls.X / 2 - 0.1, -0.35, 0.1), Color3.fromRGB(78, 84, 60), METAL)
		pouchRow(ctx, lt, 2, V3(0.34, 0.34, 0.16), web, "Pouch")
	elseif classId == "Medic" then
		local band =
			add(ctx, lua or rua, "Armband", V3(1.04, 0.3, 1.04), CF(0, 0.15, 0), Color3.fromRGB(235, 235, 230), FABRIC)
		if band and (lua or rua) then
			add(
				ctx,
				lua or rua,
				"ArmbandCross",
				V3(0.16, 0.2, 1.06),
				CF(0, 0.15, 0),
				Color3.fromRGB(190, 30, 30),
				PLASTIC
			)
		end
		add(
			ctx,
			lt,
			"AidBag",
			V3(0.55, 0.5, 0.3),
			CF(-ls.X / 2 - 0.12, -0.35, 0),
			Color3.fromRGB(196, 190, 170),
			FABRIC
		)
		add(
			ctx,
			lt,
			"AidBagCross",
			V3(0.32, 0.1, 0.02),
			CF(-ls.X / 2 - 0.12, -0.35, -0.16),
			Color3.fromRGB(190, 30, 30),
			PLASTIC
		)
		pouchRow(ctx, lt, 2, V3(0.3, 0.3, 0.14), web, "Pouch")
	elseif classId == "Engineer" then
		add(
			ctx,
			lt,
			"ToolBag",
			V3(0.6, 0.48, 0.3),
			CF(ls.X / 2 + 0.1, -0.35, -0.05),
			Color3.fromRGB(120, 96, 60),
			LEATHER
		)
		add(
			ctx,
			lt,
			"WrenchHandle",
			V3(0.08, 0.7, 0.06),
			CF(ls.X / 2 + 0.25, -0.05, -0.15) * ANG(0, 0, -0.2),
			Color3.fromRGB(110, 110, 115),
			METAL
		)
		add(ctx, ut, "Shovel", V3(0.4, 0.5, 0.06), CF(0, -0.35, ts.Z / 2 + 0.45), Color3.fromRGB(80, 84, 70), METAL)
		pouchRow(ctx, lt, 2, V3(0.3, 0.32, 0.15), web, "Pouch")
	elseif classId == "Recon" then
		add(
			ctx,
			ut,
			"BinocularCase",
			V3(0.42, 0.38, 0.22),
			CF(ts.X * 0.22, -0.25, -ts.Z / 2 - 0.12),
			Color3.fromRGB(70, 50, 34),
			LEATHER
		)
		add(
			ctx,
			ut,
			"CaseStrap",
			V3(0.1, ts.Y * 1.3, ts.Z + 0.06),
			ANG(0, 0, -0.6),
			Color3.fromRGB(70, 50, 34),
			LEATHER
		)
		add(
			ctx,
			lt,
			"MapCase",
			V3(0.5, 0.4, 0.06),
			CF(-ls.X / 2 + 0.1, -0.35, -ls.Z / 2 - 0.05),
			Color3.fromRGB(90, 70, 46),
			LEATHER
		)
	else -- Rifleman (default)
		pouchRow(ctx, lt, 4, V3(0.26, 0.3, 0.16), web, "AmmoPouch")
		if f.id == "DE" then
			add(
				ctx,
				lt,
				"StickGrenade",
				V3(0.12, 0.85, 0.12),
				CF(-0.2, 0.15, -ls.Z / 2 - 0.12) * ANG(0, 0, 0.2),
				Color3.fromRGB(112, 72, 42),
				Enum.Material.Wood
			)
		else
			add(
				ctx,
				ut,
				"Grenade",
				V3(0.26, 0.26, 0.26),
				CF(ts.X * 0.25, -0.35, -ts.Z / 2 - 0.12),
				Color3.fromRGB(78, 86, 56),
				METAL,
				Enum.PartType.Ball
			)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- Body colours
--------------------------------------------------------------------------------------------------

local function paint(character: Model, name: string, color: Color3, material: Enum.Material?)
	local part = character:FindFirstChild(name)
	if part and part:IsA("BasePart") then
		part.Color = color
		if material then
			part.Material = material
		end
	end
end

local function skinFor(character: Model): Color3
	local player = Players:GetPlayerFromCharacter(character)
	local seed = player and player.UserId or #character.Name * 7
	return SKIN_TONES[(math.abs(seed) % #SKIN_TONES) + 1]
end

local function paintBody(character: Model, f: Factions.Faction, skin: Color3)
	local c = f.colors
	paint(character, "Head", skin)
	paint(character, "LeftHand", skin)
	paint(character, "RightHand", skin)
	paint(character, "UpperTorso", c.tunic, FABRIC)
	paint(character, "LowerTorso", shade(c.tunic, 0.95), FABRIC)
	for _, side in { "Left", "Right" } do
		paint(character, side .. "UpperArm", c.tunic, FABRIC)
		paint(character, side .. "LowerArm", shade(c.tunic, 0.97), FABRIC)
		paint(character, side .. "UpperLeg", c.trousers, FABRIC)
		local style = SHIN_STYLE[f.id] or "puttees"
		local shin = c.trousers
		local shinMat = FABRIC
		if style == "boots" then
			shin, shinMat = c.boots, LEATHER
		elseif style == "leggings" then
			shin = shade(c.webbing, 0.95)
		elseif style == "puttees" then
			shin = shade(c.trousers, 0.85)
		end
		paint(character, side .. "LowerLeg", shin, shinMat)
		paint(character, side .. "Foot", c.boots, LEATHER)
	end
end

--------------------------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------------------------

function OutfitService.Apply(character: Model, factionId: string, classId: string)
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return
	end
	local f = Factions.get(factionId) or Factions.get("US")
	if not f then
		return
	end
	classId = if type(classId) == "string" then classId else "Rifleman"

	-- strip stock appearance
	for _, child in character:GetChildren() do
		if REMOVE_CLASSES[child.ClassName] or (child.Name == "Outfit" and child:IsA("Model")) then
			child:Destroy()
		end
	end

	paintBody(character, f, skinFor(character))

	local model = Instance.new("Model")
	model.Name = "Outfit"
	local ctx: Ctx = { model = model, count = 0 }

	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		if classId == "Recon" then
			buildCap(ctx, head, shade(f.colors.tunic, 0.9), f.colors.accent)
		else
			buildHelmet(ctx, head, f.helmet, f.colors.helmet, f.colors.accent)
		end
	end
	buildWebbing(ctx, character, f)
	buildClassGear(ctx, character, f, classId)

	model.Parent = character
	character:SetAttribute("OutfitFaction", f.id)
	character:SetAttribute("OutfitClass", classId)
end

return OutfitService
