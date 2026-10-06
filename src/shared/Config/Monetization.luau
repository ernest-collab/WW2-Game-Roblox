--[[
	Monetization (Monetization team): every game pass, developer product and cosmetic in WW2 Frontlines.

	OWNER SETUP: create each pass / product on the Roblox Creator Dashboard and paste its numeric id
	into `id` below (see docs/MONETIZATION.md). Anything with `id = 0` is HIDDEN in the store and its
	perk is unavailable — except in Studio when `STUDIO_TEST_GRANTS = true`, which treats every pass as
	owned and lets you "buy" unconfigured products for free (simulated) to test the flow.

	`price` is informational only (shown in the store as "R$ <price>"); the real price is whatever
	you set on the Creator Dashboard — keep them in sync.

	Fairness rules (binding, see docs/MONETIZATION.md):
	  * Nothing here sells combat power. Weapons bought early are earnable by playing anyway and use
	    the same stats as for everyone else. No random / loot-box items.
	  * Cosmetics never make a player harder to see (uniform palettes are luminance-clamped to the stock
	    uniform, see Cosmetics.uniformColors).

	XP multiplier formula (additive, then capped):
	  multiplier = 1 + VIP 0.25 + Double XP 1.0 + active XP Boost 1.0 + Roblox Premium 0.10
	  clamped to MAX_XP_MULTIPLIER (3.0). Examples: VIP only = 1.25, Double XP + VIP = 2.25,
	  Double XP + VIP + boost = 3.0 (cap). Only XP is multiplied; the in-match Score never is.
]]

export type Pass = {
	key: string,
	id: number,
	name: string,
	description: string,
	price: number, -- display only (R$)
	perks: { string },
	icon: string, -- 2-4 letter glyph for the store card
	order: number,
}

export type Product = {
	key: string,
	id: number,
	kind: "Boost" | "WeaponUnlock" | "Tip",
	name: string,
	description: string,
	price: number, -- display only (R$)
	icon: string,
	order: number,
	boostSeconds: number?, -- kind Boost
	tier: number?, -- kind Tip (1 small .. 3 large)
}

export type Camo = {
	id: string,
	name: string,
	requires: string?, -- pass key that unlocks it (nil = free / default)
	wood: { Color3 }?, -- alternating tints for wooden furniture (camo "blotches")
	metal: { Color3 }?, -- metal parts (barrel, receiver)
	dark: { Color3 }?, -- dark plastic / painted parts
	metalMaterial: Enum.Material?,
	woodMaterial: Enum.Material?,
}

export type Uniform = {
	id: string,
	name: string,
	requires: string?,
	tunic: Color3?,
	trousers: Color3?,
	helmet: Color3?,
	webbing: Color3?,
}

local Monetization = {}

-- Studio only: true = every pass owned + unconfigured products can be test-"bought" for free.
-- Never has any effect in a live server.
Monetization.STUDIO_TEST_GRANTS = false

Monetization.DATASTORE_NAME = "WW2Frontlines_Monetization_v1"

Monetization.XP_BONUS = {
	VIP = 0.25,
	DoubleXP = 1.0,
	Boost = 1.0,
	Premium = 0.10, -- Roblox Premium members (encourages Premium engagement payouts)
}
Monetization.MAX_XP_MULTIPLIER = 3.0

Monetization.BASE_PRESETS = 2 -- loadout presets everyone gets
Monetization.EXTRA_PRESETS = 6 -- added by the Extra Loadout Presets pass
Monetization.MAX_BOOST_SECONDS = 30 * 24 * 3600 -- boost time bank cap (30 days)
Monetization.PENDING_UNLOCK_TTL = 600 -- seconds a "buy this weapon" choice stays pending

------------------------------------------------------------------------------------------------
-- Game passes (one-time purchases, permanent)
------------------------------------------------------------------------------------------------

Monetization.Passes = {
	VIP = {
		key = "VIP",
		id = 0,
		name = "VIP",
		description = "Support the front and stand out: +25% XP, a gold name in the scoreboard and kill feed, a VIP chat tag and the exclusive Brass weapon camo.",
		price = 349,
		perks = { "+25% XP", "Gold name tag", "VIP chat tag", "Exclusive Brass camo" },
		icon = "VIP",
		order = 1,
	},
	DoubleXP = {
		key = "DoubleXP",
		id = 0,
		name = "Double XP",
		description = "Permanently earn double XP. Rank up and unlock weapons twice as fast. Your match score is unaffected.",
		price = 499,
		perks = { "x2 XP forever", "Stacks additively with VIP (x2.25)" },
		icon = "2XP",
		order = 2,
	},
	CamoCollection = {
		key = "CamoCollection",
		id = 0,
		name = "Camo Collection",
		description = "Unlocks every standard weapon camo: Winter, Desert, Jungle, Tiger Stripe, Navy Grey, Blued Steel and Walnut. Purely cosmetic.",
		price = 199,
		perks = { "7 weapon camos", "First and third person" },
		icon = "CAM",
		order = 3,
	},
	UniformPack = {
		key = "UniformPack",
		id = 0,
		name = "Uniform Pack",
		description = "Alternate uniform colour schemes: Winter Smock, Splinter Smock, Desert Drill and Parade Dress. Purely cosmetic.",
		price = 249,
		perks = { "4 uniform variants", "Works with every faction" },
		icon = "UNI",
		order = 4,
	},
	LoadoutPresets = {
		key = "LoadoutPresets",
		id = 0,
		name = "Extra Loadout Presets",
		description = "Save up to 8 class + loadout presets (instead of 2) and swap between them with one click.",
		price = 99,
		perks = { "+6 loadout presets" },
		icon = "PRE",
		order = 5,
	},
} :: { [string]: Pass }

------------------------------------------------------------------------------------------------
-- Developer products (consumable, can be bought repeatedly)
------------------------------------------------------------------------------------------------

Monetization.Products = {
	XPBoost1h = {
		key = "XPBoost1h",
		id = 0,
		kind = "Boost",
		name = "XP Boost (1 hour)",
		description = "Double XP for 1 hour of real time. Buying more extends the timer.",
		price = 49,
		icon = "1H",
		order = 1,
		boostSeconds = 3600,
	},
	XPBoost3h = {
		key = "XPBoost3h",
		id = 0,
		kind = "Boost",
		name = "XP Boost (3 hours)",
		description = "Double XP for 3 hours of real time. Buying more extends the timer.",
		price = 119,
		icon = "3H",
		order = 2,
		boostSeconds = 3 * 3600,
	},
	WeaponUnlock = {
		key = "WeaponUnlock",
		id = 0,
		kind = "WeaponUnlock",
		name = "Instant Weapon Unlock",
		description = "Get early access to one weapon above your level (it unlocks by playing anyway). Bought without a choice it becomes an Unlock Token to spend later.",
		price = 79,
		icon = "UNL",
		order = 3,
	},
	TipSmall = {
		key = "TipSmall",
		id = 0,
		kind = "Tip",
		name = "Buy the Squad a Coffee",
		description = "A small thank-you to the developers. Grants the Supporter badge. No gameplay effect.",
		price = 25,
		icon = "TIP",
		order = 4,
		tier = 1,
	},
	TipMedium = {
		key = "TipMedium",
		id = 0,
		kind = "Tip",
		name = "Supply Drop Donation",
		description = "Helps fund new maps and vehicles. Grants the Supporter badge. No gameplay effect.",
		price = 100,
		icon = "TIP",
		order = 5,
		tier = 2,
	},
	TipLarge = {
		key = "TipLarge",
		id = 0,
		kind = "Tip",
		name = "War Bond",
		description = "A big salute to the team. Grants the Supporter badge. No gameplay effect.",
		price = 500,
		icon = "TIP",
		order = 6,
		tier = 3,
	},
} :: { [string]: Product }

------------------------------------------------------------------------------------------------
-- Cosmetics
------------------------------------------------------------------------------------------------

local RGB = Color3.fromRGB

-- Weapon camos. Tints replace the colour of parts by their stock material class (wood / metal /
-- dark paint); several colours alternate across parts for a blotchy camo look.
Monetization.Camos = {
	{ id = "", name = "Factory Issue" },
	{
		id = "Winter",
		name = "Winter Wash",
		requires = "CamoCollection",
		wood = { RGB(222, 224, 222), RGB(184, 188, 186) },
		dark = { RGB(206, 208, 206), RGB(150, 154, 152) },
	},
	{
		id = "Desert",
		name = "Desert Sand",
		requires = "CamoCollection",
		wood = { RGB(196, 170, 120), RGB(170, 140, 96) },
		dark = { RGB(186, 160, 112) },
		metal = { RGB(150, 132, 100) },
	},
	{
		id = "Jungle",
		name = "Jungle",
		requires = "CamoCollection",
		wood = { RGB(70, 92, 50), RGB(96, 82, 52), RGB(52, 64, 40) },
		dark = { RGB(64, 82, 48), RGB(88, 76, 50) },
	},
	{
		id = "Tiger",
		name = "Tiger Stripe",
		requires = "CamoCollection",
		wood = { RGB(176, 110, 46), RGB(52, 40, 30) },
		dark = { RGB(150, 96, 44), RGB(40, 34, 28) },
	},
	{
		id = "Navy",
		name = "Navy Grey",
		requires = "CamoCollection",
		wood = { RGB(110, 120, 130) },
		dark = { RGB(96, 106, 116) },
		metal = { RGB(120, 128, 136) },
	},
	{
		id = "Blued",
		name = "Blued Steel",
		requires = "CamoCollection",
		metal = { RGB(46, 58, 82) },
		dark = { RGB(40, 48, 66) },
		metalMaterial = Enum.Material.Metal,
	},
	{
		id = "Walnut",
		name = "Walnut & Nickel",
		requires = "CamoCollection",
		wood = { RGB(92, 52, 30) },
		metal = { RGB(176, 178, 180) },
		woodMaterial = Enum.Material.Wood,
	},
	{
		id = "Brass",
		name = "Brass (VIP)",
		requires = "VIP",
		metal = { RGB(196, 160, 72) },
		dark = { RGB(120, 96, 48) },
		wood = { RGB(70, 40, 24) },
		metalMaterial = Enum.Material.Metal,
	},
} :: { Camo }

-- Uniform variants (OutfitService). Colours are luminance-clamped to the faction's stock uniform
-- at apply time (Cosmetics.uniformColors), so a variant never makes a soldier harder to see.
Monetization.Uniforms = {
	{ id = "", name = "Standard Issue" },
	{
		id = "Winter",
		name = "Winter Smock",
		requires = "UniformPack",
		tunic = RGB(214, 214, 206),
		trousers = RGB(190, 190, 184),
		helmet = RGB(220, 220, 214),
	},
	{
		id = "Splinter",
		name = "Splinter Smock",
		requires = "UniformPack",
		tunic = RGB(104, 112, 74),
		trousers = RGB(112, 96, 70),
		helmet = RGB(90, 98, 64),
		webbing = RGB(96, 80, 56),
	},
	{
		id = "Desert",
		name = "Desert Drill",
		requires = "UniformPack",
		tunic = RGB(196, 170, 120),
		trousers = RGB(184, 156, 108),
		helmet = RGB(176, 152, 104),
	},
	{
		id = "Parade",
		name = "Parade Dress",
		requires = "UniformPack",
		tunic = RGB(64, 70, 54),
		trousers = RGB(150, 128, 96),
		webbing = RGB(214, 206, 180),
	},
} :: { Uniform }

------------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------------

local passById: { [number]: Pass } = {}
local productById: { [number]: Product } = {}
for _, p in Monetization.Passes do
	if p.id > 0 then
		passById[p.id] = p
	end
end
for _, p in Monetization.Products do
	if p.id > 0 then
		productById[p.id] = p
	end
end

-- True when the item has a real id on the Creator Dashboard.
function Monetization.isConfigured(def: { id: number }?): boolean
	return def ~= nil and type(def.id) == "number" and def.id > 0
end

function Monetization.getPass(key: string): Pass?
	return Monetization.Passes[key]
end

function Monetization.getProduct(key: string): Product?
	return Monetization.Products[key]
end

function Monetization.passById(id: number): Pass?
	return passById[id]
end

function Monetization.productById(id: number): Product?
	return productById[id]
end

local function sorted<T>(map: { [string]: T }): { T }
	local list = {}
	for _, def in map do
		table.insert(list, def)
	end
	table.sort(list, function(a: any, b: any)
		return a.order < b.order
	end)
	return list
end

function Monetization.passList(): { Pass }
	return sorted(Monetization.Passes)
end

function Monetization.productList(): { Product }
	return sorted(Monetization.Products)
end

function Monetization.getCamo(id: string?): Camo?
	for _, c in Monetization.Camos do
		if c.id == (id or "") then
			return c
		end
	end
	return nil
end

function Monetization.getUniform(id: string?): Uniform?
	for _, u in Monetization.Uniforms do
		if u.id == (id or "") then
			return u
		end
	end
	return nil
end

--[[
	XP multiplier from perks (see header). `perks` = {vip, doubleXP, boost, premium} booleans.
]]
function Monetization.xpMultiplier(
	perks: { vip: boolean?, doubleXP: boolean?, boost: boolean?, premium: boolean? }
): number
	local m = 1
	if perks.vip then
		m += Monetization.XP_BONUS.VIP
	end
	if perks.doubleXP then
		m += Monetization.XP_BONUS.DoubleXP
	end
	if perks.boost then
		m += Monetization.XP_BONUS.Boost
	end
	if perks.premium then
		m += Monetization.XP_BONUS.Premium
	end
	return math.min(m, Monetization.MAX_XP_MULTIPLIER)
end

function Monetization.presetLimit(hasPresetsPass: boolean): number
	return Monetization.BASE_PRESETS + (if hasPresetsPass then Monetization.EXTRA_PRESETS else 0)
end

-- "R$ 349"
function Monetization.formatPrice(price: number): string
	return "R$ " .. tostring(math.floor(price))
end

return Monetization
