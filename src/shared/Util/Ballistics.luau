--[[
	Ballistics: pure math shared by CombatService (server) and WeaponController (client) so both
	sides agree on damage falloff, hit-zone multipliers, spread and explosion falloff.

	Owner: Combat team. No state, no instances created; safe to call in hot paths.

		local dmg, head = Ballistics.damageAt(def, distance, hitPart.Name)
		local dir = Ballistics.spreadDirection(lookVector, spreadDeg, rng)
]]

local CollectionService = game:GetService("CollectionService")

local Constants = require(script.Parent.Parent.Config.Constants)

local Ballistics = {}

local HEAD_NAMES = Constants.HEADSHOT_PART_NAMES
local LIMB_NAMES = Constants.LIMB_PART_NAMES
local VEHICLE_TAG = Constants.TAGS.Vehicle
local RAD = math.pi / 180

-- Damage multiplier for a given travel distance. `damageFalloff` is an ascending list of
-- {range, multiplier} points; values are linearly interpolated between points and clamped
-- to the first/last point outside the list.
function Ballistics.falloff(def: any, distance: number): number
	local curve = def.damageFalloff
	if not curve or #curve == 0 then
		return 1
	end
	local first = curve[1]
	if distance <= first.range then
		return first.multiplier
	end
	for i = 2, #curve do
		local b = curve[i]
		if distance <= b.range then
			local a = curve[i - 1]
			local span = b.range - a.range
			local alpha = if span > 0 then (distance - a.range) / span else 1
			return a.multiplier + (b.multiplier - a.multiplier) * alpha
		end
	end
	return curve[#curve].multiplier
end

-- Hit-zone multiplier for a body part name. Returns (multiplier, isHeadshot).
function Ballistics.partMultiplier(def: any, partName: string): (number, boolean)
	if HEAD_NAMES[partName] then
		return def.headshotMultiplier or 1.5, true
	elseif LIMB_NAMES[partName] then
		return def.limbMultiplier or 0.9, false
	end
	return 1, false
end

-- Final per-bullet damage (before armor/friendly-fire rules). Returns (damage, isHeadshot).
function Ballistics.damageAt(def: any, distance: number, partName: string): (number, boolean)
	local zone, head = Ballistics.partMultiplier(def, partName)
	return (def.damage or 0) * Ballistics.falloff(def, distance) * zone, head
end

-- Explosion damage at `distance` from the centre. Full damage inside the inner 20% core,
-- then a smooth (quadratic-ish) falloff to 0 at the radius edge.
function Ballistics.explosionDamage(maxDamage: number, distance: number, radius: number): number
	if radius <= 0 or distance >= radius then
		return 0
	end
	local core = radius * 0.2
	if distance <= core then
		return maxDamage
	end
	local t = 1 - (distance - core) / (radius - core)
	return maxDamage * (t * (0.35 + 0.65 * t))
end

-- Random direction inside a cone of half-angle `spreadDeg` around `dir` (unit vector).
-- Uses sqrt(u) radial distribution so shots are evenly spread across the cone area.
function Ballistics.spreadDirection(dir: Vector3, spreadDeg: number, rng: Random): Vector3
	if spreadDeg <= 0 then
		return dir
	end
	local cf = CFrame.lookAt(Vector3.zero, dir)
	local r = math.tan(spreadDeg * RAD) * math.sqrt(rng:NextNumber())
	local theta = rng:NextNumber() * math.pi * 2
	return (cf.LookVector + cf.RightVector * (math.cos(theta) * r) + cf.UpVector * (math.sin(theta) * r)).Unit
end

export type SpreadParams = {
	aimAlpha: number, -- 0 hip .. 1 fully aimed
	moving: boolean,
	sprinting: boolean,
	airborne: boolean,
	stance: string, -- "Stand" | "Crouch" | "Prone" | "Sprint"
	bloom: number, -- accumulated sustained-fire bloom in degrees
}

-- Effective cone half-angle (degrees) for the next shot.
function Ballistics.computeSpread(def: any, p: SpreadParams): number
	local hip = def.hipSpread or 2
	local ads = def.adsSpread or 0.5
	local base = hip + (ads - hip) * math.clamp(p.aimAlpha, 0, 1)
	local stanceMult = 1
	if p.stance == "Crouch" then
		stanceMult = 0.8
	elseif p.stance == "Prone" then
		stanceMult = 0.6
	end
	local moveMult = 1
	if p.airborne then
		moveMult = 2.5
	elseif p.sprinting then
		moveMult = 2.2
	elseif p.moving then
		-- moving hurts hip fire much more than ADS
		local m = def.moveSpreadMult or 1.5
		moveMult = 1 + (m - 1) * (1 - 0.6 * p.aimAlpha)
	end
	return (base + p.bloom) * stanceMult * moveMult
end

-- Camera recoil for one shot. `shotIndex` is 1 for the first shot of a string of fire.
-- Returns (pitchDegrees, yawDegrees). The yaw follows a smooth per-weapon drift so sustained fire
-- has a learnable pattern, plus a small random component.
function Ballistics.recoilFor(
	def: any,
	shotIndex: number,
	aimAlpha: number,
	stance: string,
	rng: Random
): (number, number)
	local r = def.recoil
	if not r then
		return 0, 0
	end
	local mult = 1 - 0.25 * math.clamp(aimAlpha, 0, 1)
	if stance == "Crouch" then
		mult *= 0.85
	elseif stance == "Prone" then
		mult *= 0.6
	end
	local first = if shotIndex <= 1 then (r.firstShotMult or 1) else 1
	-- Vertical climb eases slightly after the first few shots (the shooter "fights" the gun).
	local climb = if shotIndex > 6 then 0.85 else 1
	local pitch = r.vertical * mult * first * climb * (0.9 + rng:NextNumber() * 0.2)
	local seed = #def.id
	local drift = math.sin(shotIndex * 0.55 + seed) * 0.6
	local yaw = r.horizontal * mult * (drift + (rng:NextNumber() * 2 - 1) * 0.6)
	return pitch, yaw
end

-- Walks up from a hit instance to a character model with a living Humanoid.
function Ballistics.findCharacter(inst: Instance?): (Model?, Humanoid?)
	local node = inst
	for _ = 1, 6 do
		if not node or node == workspace then
			return nil, nil
		end
		if node:IsA("Model") then
			local hum = node:FindFirstChildOfClass("Humanoid")
			if hum then
				return node, hum
			end
		end
		node = node.Parent
	end
	return nil, nil
end

-- Walks up from a hit instance to a vehicle model (tagged `Vehicle`).
function Ballistics.findVehicle(inst: Instance?): Model?
	local node = inst
	for _ = 1, 12 do
		if not node or node == workspace then
			return nil
		end
		if node:IsA("Model") and CollectionService:HasTag(node, VEHICLE_TAG) then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- Position-in-box distance: 0 when inside, else distance to nearest face (oriented box).
function Ballistics.distanceToBox(point: Vector3, boxCFrame: CFrame, boxSize: Vector3): number
	local rel = boxCFrame:PointToObjectSpace(point)
	local h = boxSize * 0.5
	local dx = math.max(math.abs(rel.X) - h.X, 0)
	local dy = math.max(math.abs(rel.Y) - h.Y, 0)
	local dz = math.max(math.abs(rel.Z) - h.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Validates a Vector3 coming from the network (finite components).
function Ballistics.isFiniteVector(v: any): boolean
	if typeof(v) ~= "Vector3" then
		return false
	end
	local x, y, z = v.X, v.Y, v.Z
	return x == x and y == y and z == z and math.abs(x) < 1e6 and math.abs(y) < 1e6 and math.abs(z) < 1e6
end

return Ballistics
