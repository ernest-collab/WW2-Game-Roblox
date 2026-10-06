--[[
	Cosmetics (Monetization team): applies purely visual cosmetics. Shared by server + client.

		Cosmetics.applyCamo(model, camoId?)        -- tint a WeaponModels model (third or first person)
		Cosmetics.uniformColors(colors, variantId?) -> colors   -- OutfitService faction colour override

	Camo works on any model built by WeaponModels: every BasePart is classified by its stock material
	(Wood -> "wood", Metal -> "metal", SmoothPlastic/Plastic -> "dark"; Glass lenses, fabric slings,
	leather and invisible parts are left alone). The stock colour/material is remembered in part
	attributes (CamoBaseColor / CamoBaseMaterial) so camos can be switched or removed at any time.
	The model gets the attribute `Camo` (camo id, "" = factory).

	Uniform variants are blended so their brightness matches the faction's stock colours (a variant
	can change hue, never make a soldier harder to see) — see `matchLuminance`.
]]

local Monetization = require(script.Parent.Config.Monetization)

local Cosmetics = {}

local CLASS_BY_MATERIAL: { [Enum.Material]: string } = {
	[Enum.Material.Wood] = "wood",
	[Enum.Material.WoodPlanks] = "wood",
	[Enum.Material.Metal] = "metal",
	[Enum.Material.DiamondPlate] = "metal",
	[Enum.Material.SmoothPlastic] = "dark",
	[Enum.Material.Plastic] = "dark",
}

local function partClass(part: BasePart): string?
	if part.Name == "Handle" or part.Transparency >= 0.95 then
		return nil
	end
	local base = part:GetAttribute("CamoBaseMaterial")
	local material = part.Material
	if type(base) == "string" then
		local ok, m = pcall(function()
			return (Enum.Material :: any)[base]
		end)
		if ok and typeof(m) == "EnumItem" then
			material = m :: any
		end
	end
	return CLASS_BY_MATERIAL[material]
end

-- Cheap deterministic hash so the same part always gets the same camo blotch colour.
local function hashIndex(s: string, n: number): number
	local h = 0
	for i = 1, #s do
		h = (h * 31 + string.byte(s, i)) % 100003
	end
	return (h % n) + 1
end

-- Applies (or with camoId nil/"" removes) a camo on a weapon model. Safe to call repeatedly.
function Cosmetics.applyCamo(model: Instance?, camoId: string?)
	if typeof(model) ~= "Instance" then
		return
	end
	local camo = Monetization.getCamo(camoId)
	if camo == nil or camo.id == "" then
		camo = nil
	end
	local index = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			index += 1
			local class = partClass(d)
			if class then
				local baseColor = d:GetAttribute("CamoBaseColor")
				if typeof(baseColor) ~= "Color3" then
					baseColor = d.Color
					d:SetAttribute("CamoBaseColor", d.Color)
					d:SetAttribute("CamoBaseMaterial", d.Material.Name)
				end
				local baseMaterialName = d:GetAttribute("CamoBaseMaterial")
				local tints = camo and (camo :: any)[class] or nil
				if type(tints) == "table" and #tints > 0 then
					d.Color = tints[hashIndex(d.Name .. tostring(index), #tints)]
					local mat = if class == "metal"
						then camo and camo.metalMaterial
						elseif class == "wood" then camo and camo.woodMaterial
						else nil
					if mat then
						d.Material = mat
					end
				else
					d.Color = baseColor :: Color3
					if type(baseMaterialName) == "string" then
						pcall(function()
							d.Material = (Enum.Material :: any)[baseMaterialName]
						end)
					end
				end
			end
		end
	end
	if model:IsA("Model") then
		model:SetAttribute("Camo", camo and camo.id or "")
	end
end

local function luminance(c: Color3): number
	return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
end

-- Rescales `c` so its luminance stays within `tolerance` of `reference` (keeps hue).
local function matchLuminance(c: Color3, reference: Color3, tolerance: number): Color3
	local lc, lr = luminance(c), luminance(reference)
	local target = math.clamp(lc, lr - tolerance, lr + tolerance)
	if lc < 1e-3 then
		return reference
	end
	local k = target / lc
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

local LUMINANCE_TOLERANCE = 0.08

--[[
	Returns a copy of a faction `colors` table ({tunic, trousers, helmet, webbing, boots, accent}) with
	the uniform variant applied. Unknown / empty variant -> unchanged copy.
]]
function Cosmetics.uniformColors(colors: { [string]: Color3 }, variantId: string?): { [string]: Color3 }
	local out = table.clone(colors)
	local variant = Monetization.getUniform(variantId)
	if not variant or variant.id == "" then
		return out
	end
	for _, key in { "tunic", "trousers", "helmet", "webbing" } do
		local c = (variant :: any)[key]
		local stock = colors[key]
		if typeof(c) == "Color3" and typeof(stock) == "Color3" then
			out[key] = matchLuminance(c, stock, LUMINANCE_TOLERANCE)
		end
	end
	return out
end

return Cosmetics
