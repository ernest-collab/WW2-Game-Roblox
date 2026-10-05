--[[
	Long-gun archetypes: BoltRifle, SemiRifle, SniperRifle, Shotgun, AssaultRifle.

	Layout (handle space): the Handle sits at the trigger. The butt extends toward +Z, the barrel
	toward -Z. `p.length` is the overall length in studs; `zB` is the butt plate, `zM` the muzzle.
	Variants (from Config visual.variant or the weapon id) change silhouettes:
	  BoltRifle/SniperRifle: kar98 | mosin | enfield | springfield | arisaka | carcano | generic
	  SemiRifle:             garand | svt | g43 | carbine | generic
	  AssaultRifle:          stg44 | fg42 | generic
]]

local Builder = require(script.Parent.Builder)
local Parts = require(script.Parent.Parts)

type B = Builder.Builder

local M = Builder.Mat
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local Rifles = {}

-- Stock from the trigger group back to the butt plate. Returns nothing; adds ~5 parts.
local function stock(b: B, zStart: number, zEnd: number, wood: Color3, opts: { pistolGrip: boolean? }?)
	local p = b.p
	local span = zEnd - zStart
	local wristLen = span * 0.38
	local buttLen = span - wristLen
	if opts and opts.pistolGrip then
		b:box("PistolGrip", V3(0.12, 0.3, 0.15), CF(0, -0.2, zStart + 0.1) * ANG(0.3, 0, 0), wood, M.Wood)
	end
	b:box("Wrist", V3(0.13, 0.16, wristLen + 0.05), CF(0, -0.05, zStart + wristLen / 2) * ANG(0.08, 0, 0), wood, M.Wood)
	b:box("Butt", V3(0.15, 0.32, buttLen), CF(0, -0.15, zEnd - buttLen / 2), wood, M.Wood)
	b:wedge(
		"ButtToe",
		V3(0.14, 0.18, math.min(0.4, wristLen)),
		CF(0, -0.22, zEnd - buttLen - math.min(0.4, wristLen) / 2 + 0.01) * ANG(0, 0, math.pi),
		wood,
		M.Wood
	)
	b:box("ButtPlate", V3(0.155, 0.33, 0.035), CF(0, -0.15, zEnd), p.dark, M.Metal)
end

local function triggerGroup(b: B, z: number)
	local p = b.p
	b:box("TriggerGuard", V3(0.035, 0.03, 0.24), CF(0, -0.17, z + 0.02), p.metal, M.Metal)
	b:box("Trigger", V3(0.025, 0.09, 0.03), CF(0, -0.12, z), p.dark, M.Metal)
end

-- Bolt with handle + knob. style: "bent" (Kar98k/sniper), "straight" (Mosin/Springfield), "enfield".
local function bolt(b: B, z: number, y: number, style: string)
	local p = b.p
	local body = b:cylZ("Bolt", 0.5, 0.075, CF(0, y, z), p.metal, M.Metal)
	if style == "bent" then
		b:box("BoltArm", V3(0.2, 0.035, 0.035), CF(0.12, y - 0.04, z + 0.18) * ANG(0, 0, -0.55), p.metal, M.Metal, body)
		b:ball("BoltKnob", 0.085, CF(0.22, y - 0.1, z + 0.18), p.metal, M.Metal, body)
	elseif style == "enfield" then
		b:box("BoltArm", V3(0.18, 0.035, 0.035), CF(0.11, y - 0.02, z + 0.24) * ANG(0, 0, -0.3), p.metal, M.Metal, body)
		b:ball("BoltKnob", 0.08, CF(0.2, y - 0.05, z + 0.24), p.dark, M.Metal, body)
	else
		b:box("BoltArm", V3(0.2, 0.035, 0.035), CF(0.12, y, z + 0.16), p.metal, M.Metal, body)
		b:ball("BoltKnob", 0.08, CF(0.22, y, z + 0.16), p.metal, M.Metal, body)
	end
end

local function bayonet(b: B, zM: number, y: number)
	local p = b.p
	b:box("BayonetMount", V3(0.06, 0.08, 0.14), CF(0, y - 0.07, zM + 0.06), p.dark, M.Metal)
	b:box("BayonetBlade", V3(0.025, 0.06, 0.95), CF(0, y - 0.08, zM - 0.45), Color3.fromRGB(150, 150, 155), M.Metal)
	b:wedge("BayonetTip", V3(0.025, 0.06, 0.12), CF(0, y - 0.08, zM - 0.98), Color3.fromRGB(150, 150, 155), M.Metal)
end

-- Scope on top of the receiver. Returns the sight line height.
local function scope(b: B, z: number, y: number): number
	local p = b.p
	local black = Color3.fromRGB(28, 28, 30)
	b:box("ScopeMountF", V3(0.06, y - 0.1, 0.08), CF(0, (y + 0.1) / 2, z - 0.3), p.dark, M.Metal)
	b:box("ScopeMountR", V3(0.06, y - 0.1, 0.08), CF(0, (y + 0.1) / 2, z + 0.25), p.dark, M.Metal)
	b:cylZ("ScopeTube", 0.95, 0.1, CF(0, y, z), black, M.Metal)
	b:cylZ("ScopeObjective", 0.22, 0.16, CF(0, y, z - 0.55), black, M.Metal)
	b:cylZ("ScopeOcular", 0.16, 0.135, CF(0, y, z + 0.52), black, M.Metal)
	b:cylY("ScopeTurret", 0.09, 0.07, CF(0, y + 0.07, z - 0.02), black, M.Metal)
	b:cylX("ScopeWindage", 0.09, 0.07, CF(0.07, y, z - 0.02), black, M.Metal)
	b:cylZ("ScopeLens", 0.01, 0.13, CF(0, y, z - 0.665), Color3.fromRGB(60, 90, 120), Enum.Material.Glass)
	return y
end

--------------------------------------------------------------------------------------------------
-- Bolt-action rifle (also the base for SniperRifle)
--------------------------------------------------------------------------------------------------

function Rifles.BoltRifle(b: B, withScope: boolean?)
	local p = b.p
	local v = p.variant
	local L = p.length
	local zB = L * 0.36
	local zM = zB - L
	local wood, metal = p.wood, p.metal
	local barrelY = 0.07

	-- Receiver + barrel
	b:box("Receiver", V3(0.14, 0.16, 0.85), CF(0, 0.05, -0.12), metal, M.Metal)
	local barrelLen = -zM - 0.5
	b:cylZ("Barrel", barrelLen, 0.07, CF(0, barrelY, -0.5 - barrelLen / 2), metal, M.Metal)
	b:cylZ("MuzzleCrown", 0.06, 0.085, CF(0, barrelY, zM + 0.03), p.dark, M.Metal)

	-- Forend: Enfield/Arisaka wood runs almost to the muzzle; others stop short.
	local woodReach = (v == "enfield") and 0.95 or (v == "mosin" and 0.84 or 0.8)
	local fl = barrelLen * woodReach
	b:box("Forend", V3(0.16, 0.14, fl), CF(0, -0.02, -0.3 - fl / 2), wood, M.Wood)
	local hg = fl * (v == "enfield" and 0.9 or 0.55)
	b:box("Handguard", V3(0.12, 0.06, hg), CF(0, 0.125, -0.62 - hg / 2), wood, M.Wood)

	-- Barrel bands (Mosin has two tight bands, Kar98k a nose cap + band)
	for i, f in { 0.45, 0.9 } do
		b:box(`Band{i}`, V3(0.17, 0.19, 0.05), CF(0, 0.02, -0.3 - fl * f), p.dark, M.Metal)
	end
	if v == "enfield" then
		b:box("NoseCap", V3(0.12, 0.12, 0.12), CF(0, 0.03, -0.3 - fl - 0.04), p.dark, M.Metal)
	elseif v == "kar98" then
		b:cylZ("CleaningRod", 0.45, 0.025, CF(0, -0.03, zM + 0.3), metal, M.Metal)
	end

	triggerGroup(b, 0.03)
	stock(b, 0.18, zB, wood)

	-- Magazine: internal floorplate or protruding box (Enfield)
	local magKind = p.magazine
	if magKind == "box" or v == "enfield" then
		b:box("Mag", V3(0.11, 0.26, 0.3), CF(0, -0.2, -0.22), p.dark, M.Metal)
	else
		b:box("Mag", V3(0.11, 0.05, 0.36), CF(0, -0.11, -0.2), metal, M.Metal)
	end

	-- Bolt
	local boltStyle = (v == "kar98" or withScope) and "bent" or (v == "enfield" and "enfield" or "straight")
	bolt(b, 0.2, 0.12, boltStyle)
	if v == "arisaka" then
		b:box(
			"DustCover",
			V3(0.13, 0.04, 0.42),
			CF(0, 0.17, 0.12),
			metal,
			M.Metal,
			b.model:FindFirstChild("Bolt") :: BasePart
		)
	end

	-- Iron sights
	local sightY = 0.185
	local rearZ = (v == "enfield") and 0.1 or -0.62
	b:box("RearSight", V3(0.1, 0.05, 0.12), CF(0, sightY - 0.04, rearZ), p.dark, M.Metal)
	b:box("FrontSight", V3(0.02, 0.07, 0.03), CF(0, sightY - 0.03, zM + 0.1), p.dark, M.Metal)
	if v == "kar98" or v == "mosin" then
		b:box("FrontHood", V3(0.07, 0.015, 0.06), CF(0, sightY + 0.02, zM + 0.1), p.dark, M.Metal)
	end

	if p.bayonet then
		bayonet(b, zM, barrelY)
	end

	local eye = (v == "enfield") and 0.35 or 0.62
	local sightPos = V3(0, sightY, rearZ)
	if withScope then
		local y = scope(b, -0.05, 0.36)
		sightPos = V3(0, y, 0.6)
		eye = 0.3
	end

	b:standard(V3(0, barrelY, zM), V3(0, -0.11, 0.32), V3(0, -0.07, -0.3 - fl * 0.24), sightPos, V3(0.09, 0.12, 0.0))
	b:meta("Rifle", eye, V3(0, -1, 0), "bolt")
end

function Rifles.SniperRifle(b: B)
	local v = b.p.variant
	if v == "svt" or v == "g43" or v == "garand" then
		Rifles.SemiRifle(b, true)
	else
		Rifles.BoltRifle(b, true)
	end
end

--------------------------------------------------------------------------------------------------
-- Semi-automatic rifle
--------------------------------------------------------------------------------------------------

function Rifles.SemiRifle(b: B, withScope: boolean?)
	local p = b.p
	local v = p.variant
	local L = p.length
	local zB = L * 0.37
	local zM = zB - L
	local wood, metal = p.wood, p.metal
	local barrelY = 0.07

	b:box("Receiver", V3(0.15, 0.17, 0.95), CF(0, 0.05, -0.12), metal, M.Metal)
	local barrelLen = -zM - 0.55
	b:cylZ("Barrel", barrelLen, 0.075, CF(0, barrelY, -0.55 - barrelLen / 2), metal, M.Metal)

	local fl = barrelLen * ((v == "garand") and 0.82 or 0.68)
	b:box("Forend", V3(0.16, 0.15, fl), CF(0, -0.02, -0.35 - fl / 2), wood, M.Wood)
	b:box("Handguard", V3(0.13, 0.07, fl * 0.7), CF(0, 0.13, -0.6 - fl * 0.35), wood, M.Wood)
	b:box("Band", V3(0.17, 0.2, 0.05), CF(0, 0.03, -0.35 - fl * 0.55), p.dark, M.Metal)

	if v == "garand" or v == "generic" then
		-- Gas cylinder under the muzzle + front sight ears
		b:cylZ("GasCylinder", 0.32, 0.11, CF(0, 0.02, zM + 0.2), p.dark, M.Metal)
		b:box("FrontEarL", V3(0.02, 0.08, 0.05), CF(-0.035, 0.15, zM + 0.08), p.dark, M.Metal)
		b:box("FrontEarR", V3(0.02, 0.08, 0.05), CF(0.035, 0.15, zM + 0.08), p.dark, M.Metal)
	elseif v == "svt" then
		b:cylZ("MuzzleBrake", 0.16, 0.1, CF(0, barrelY, zM + 0.08), p.dark, M.Metal)
		b:box("BrakePorts", V3(0.11, 0.03, 0.1), CF(0, barrelY, zM + 0.08), Color3.fromRGB(20, 20, 20), M.Metal)
		b:cylZ("GasTube", 0.5, 0.05, CF(0, 0.13, -0.3 - fl - 0.05), metal, M.Metal)
	else
		b:cylZ("MuzzleCrown", 0.06, 0.085, CF(0, barrelY, zM + 0.03), p.dark, M.Metal)
	end
	b:box("FrontSight", V3(0.02, 0.07, 0.03), CF(0, 0.15, zM + 0.08), p.dark, M.Metal)

	triggerGroup(b, 0.05)
	stock(b, 0.2, zB, wood)

	-- Operating rod handle (animated as "Bolt")
	b:box("Bolt", V3(0.05, 0.05, 0.14), CF(0.1, 0.07, -0.25), metal, M.Metal)

	-- Magazine: Garand en-bloc (internal) vs detachable box (G43, SVT, Carbine)
	if p.magazine == "box" or v == "svt" or v == "g43" or v == "carbine" then
		b:box("Mag", V3(0.11, 0.26, 0.24), CF(0, -0.2, -0.3) * ANG(0.08, 0, 0), p.dark, M.Metal)
	else
		b:box("Mag", V3(0.1, 0.035, 0.3), CF(0, 0.145, -0.2), Color3.fromRGB(176, 140, 70), M.Metal)
	end

	-- Rear aperture sight with protective ears
	local sightY = 0.2
	b:box("RearSight", V3(0.06, 0.07, 0.06), CF(0, sightY - 0.04, 0.22), p.dark, M.Metal)
	b:box("RearEarL", V3(0.02, 0.06, 0.08), CF(-0.05, sightY - 0.03, 0.22), p.dark, M.Metal)
	b:box("RearEarR", V3(0.02, 0.06, 0.08), CF(0.05, sightY - 0.03, 0.22), p.dark, M.Metal)

	if p.bayonet then
		bayonet(b, zM, barrelY)
	end

	local sightPos = V3(0, sightY - 0.01, 0.22)
	local eye = 0.38
	if withScope then
		local y = scope(b, -0.1, 0.38)
		sightPos = V3(0, y, 0.55)
		eye = 0.3
	end
	b:standard(V3(0, barrelY, zM), V3(0, -0.11, 0.34), V3(0, -0.07, -0.35 - fl * 0.22), sightPos, V3(0.09, 0.13, -0.15))
	b:meta("Rifle", eye, V3(0, -1, 0), withScope and "bolt" or "slide")
end

--------------------------------------------------------------------------------------------------
-- Pump shotgun (Winchester 1897/1912 style, trench variant with heat shield when bayonet=true)
--------------------------------------------------------------------------------------------------

function Rifles.Shotgun(b: B)
	local p = b.p
	local L = p.length
	local zB = L * 0.38
	local zM = zB - L
	local wood, metal = p.wood, p.metal
	local barrelY = 0.09

	b:box("Receiver", V3(0.16, 0.22, 0.62), CF(0, 0.02, -0.08), metal, M.Metal)
	b:box("Hammer", V3(0.04, 0.08, 0.05), CF(0, 0.15, 0.2) * ANG(-0.4, 0, 0), p.dark, M.Metal)
	local barrelLen = -zM - 0.38
	b:cylZ("Barrel", barrelLen, 0.1, CF(0, barrelY, -0.38 - barrelLen / 2), metal, M.Metal)
	local tubeLen = barrelLen * 0.82
	b:cylZ("MagTube", tubeLen, 0.085, CF(0, -0.03, -0.38 - tubeLen / 2), metal, M.Metal)
	b:box("TubeClamp", V3(0.09, 0.2, 0.05), CF(0, 0.03, -0.38 - tubeLen + 0.03), p.dark, M.Metal)

	local pump = b:box("Pump", V3(0.15, 0.14, 0.5), CF(0, -0.035, -0.75), wood, M.Wood)
	for i = 1, 3 do
		b:box(
			`PumpRib{i}`,
			V3(0.155, 0.02, 0.03),
			CF(0, -0.04, -0.6 - i * 0.09),
			Builder.shade(wood, 0.6),
			M.Wood,
			pump
		)
	end
	b:ball("Bead", 0.035, CF(0, barrelY + 0.055, zM + 0.04), Color3.fromRGB(200, 190, 160), M.Metal)

	triggerGroup(b, 0.08)
	stock(b, 0.22, zB, wood)
	b:box("Mag", V3(0.07, 0.07, 0.12), CF(0, -0.1, -0.2), Color3.fromRGB(150, 40, 30), M.Plastic) -- loading port shell

	if p.bayonet or p.variant == "trench" then
		local shieldLen = barrelLen * 0.6
		b:box("HeatShield", V3(0.14, 0.05, shieldLen), CF(0, barrelY + 0.06, -0.45 - shieldLen / 2), p.dark, M.Metal)
		for i = 1, 3 do
			b:box(
				`ShieldVent{i}`,
				V3(0.145, 0.02, 0.05),
				CF(0, barrelY + 0.07, -0.5 - i * shieldLen / 4),
				Color3.fromRGB(15, 15, 15),
				M.Metal
			)
		end
		if p.bayonet then
			bayonet(b, zM, barrelY - 0.02)
		end
	end

	b:standard(V3(0, barrelY, zM), V3(0, -0.11, 0.36), V3(0, -0.09, -0.75), V3(0, 0.17, 0.05), V3(0.09, 0.08, -0.1))
	b:meta("Rifle", 0.55, V3(0, -1, 0), "pump")
end

--------------------------------------------------------------------------------------------------
-- Assault rifle (StG44: stamped receiver, gas tube, curved magazine, wooden butt)
--------------------------------------------------------------------------------------------------

function Rifles.AssaultRifle(b: B)
	local p = b.p
	local L = p.length
	local zB = L * 0.36
	local zM = zB - L
	local wood, metal = p.wood, p.metal
	local barrelY = 0.05

	b:box("Receiver", V3(0.15, 0.18, 1.05), CF(0, 0.06, -0.18), metal, M.Metal)
	b:box("TriggerHousing", V3(0.13, 0.12, 0.42), CF(0, -0.08, 0.06), p.dark, M.Metal)
	b:box("PistolGrip", V3(0.11, 0.3, 0.15), CF(0, -0.24, 0.2) * ANG(0.25, 0, 0), wood, M.Wood)
	b:cylZ("GasTube", 0.6, 0.11, CF(0, 0.08, -0.98), metal, M.Metal)
	local barrelLen = -zM - 1.25
	b:cylZ("Barrel", barrelLen, 0.065, CF(0, barrelY, -1.25 - barrelLen / 2), metal, M.Metal)
	b:cylZ("MuzzleNut", 0.07, 0.085, CF(0, barrelY, zM + 0.04), p.dark, M.Metal)
	b:box("FrontSight", V3(0.06, 0.09, 0.07), CF(0, 0.15, -1.22), p.dark, M.Metal)
	b:box("RearSight", V3(0.09, 0.05, 0.14), CF(0, 0.17, -0.45), p.dark, M.Metal)
	triggerGroup(b, 0.04)

	-- Butt: wood, slimmer than a bolt rifle
	local buttLen = zB - 0.4
	b:box("Butt", V3(0.13, 0.22, buttLen), CF(0, 0.0, 0.4 + buttLen / 2), wood, M.Wood)
	b:wedge(
		"ButtToe",
		V3(0.13, 0.12, buttLen * 0.6),
		CF(0, -0.17, zB - buttLen * 0.3) * ANG(0, 0, math.pi),
		wood,
		M.Wood
	)
	b:box("ButtPlate", V3(0.14, 0.34, 0.035), CF(0, -0.05, zB), p.dark, M.Metal)

	-- Charging handle (left side)
	b:box("Bolt", V3(0.08, 0.04, 0.05), CF(-0.11, 0.1, -0.5), p.dark, M.Metal)

	local magOut = Parts.magazine(b, p.magazine == "box" and "curved" or p.magazine, CF(0, -0.1, -0.42), 0.55)

	b:standard(V3(0, barrelY, zM), V3(0, -0.2, 0.2), V3(0, -0.04, -0.8), V3(0, 0.2, -0.45), V3(0.09, 0.1, -0.2))
	b:meta("Rifle", 0.5, magOut, "slide")
end

return Rifles
