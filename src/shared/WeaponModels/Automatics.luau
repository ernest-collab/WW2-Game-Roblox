--[[
	Automatic weapon archetypes: SMG, LMG, HMG.

	Variants:
	  SMG: thompson (finned barrel, vertical foregrip, stick/drum) | mp40 (folding stock, bakelite,
	       long bottom mag) | sten (tube body, side mag, skeletal stock) | ppsh (wood stock, drum,
	       perforated jacket, slanted brake) | m3 (grease gun) | generic
	  LMG: bar (bottom box mag, long wood) | bren (top curved mag, carry handle, offset sights) |
	       dp (top pan mag, perforated jacket) | type96 (top mag, sights offset right) | generic
	  HMG: mg42 (square perforated jacket, belt box) | mg34 (round jacket) | m1919 | generic
]]

local Builder = require(script.Parent.Builder)
local Parts = require(script.Parent.Parts)

type B = Builder.Builder

local M = Builder.Mat
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local Automatics = {}

local BAKELITE = Color3.fromRGB(58, 40, 30)

local function trigger(b: B, z: number, y: number?)
	local p = b.p
	local ty = y or -0.12
	b:box("TriggerGuard", V3(0.035, 0.03, 0.22), CF(0, ty - 0.06, z + 0.03), p.metal, M.Metal)
	b:box("Trigger", V3(0.025, 0.08, 0.03), CF(0, ty, z), p.dark, M.Metal)
end

--------------------------------------------------------------------------------------------------
-- SMG
--------------------------------------------------------------------------------------------------

local function thompson(b: B)
	local p = b.p
	local L = p.length
	local zB = L * 0.4
	local zM = zB - L
	local wood, metal = p.wood, p.metal
	b:box("Receiver", V3(0.16, 0.2, 0.85), CF(0, 0.03, -0.08), metal, M.Metal)
	local barrelLen = -zM - 0.5
	b:cylZ("Barrel", barrelLen, 0.085, CF(0, 0.05, -0.5 - barrelLen / 2), metal, M.Metal)
	for i = 1, 4 do
		b:cylZ(`Fin{i}`, 0.035, 0.12, CF(0, 0.05, -0.55 - i * 0.07), p.dark, M.Metal)
	end
	b:box("Compensator", V3(0.11, 0.11, 0.15), CF(0, 0.05, zM + 0.07), p.dark, M.Metal)
	b:box("Grip", V3(0.12, 0.3, 0.15), CF(0, -0.2, 0.17) * ANG(0.22, 0, 0), wood, M.Wood)
	b:box("Foregrip", V3(0.11, 0.3, 0.13), CF(0, -0.15, -0.68) * ANG(0.12, 0, 0), wood, M.Wood)
	b:ball("ForegripKnob", 0.13, CF(0, -0.31, -0.66), wood, M.Wood)
	local buttLen = zB - 0.32
	b:box("Butt", V3(0.14, 0.26, buttLen), CF(0, -0.08, 0.32 + buttLen / 2), wood, M.Wood)
	b:wedge(
		"ButtToe",
		V3(0.13, 0.12, buttLen * 0.5),
		CF(0, -0.27, zB - buttLen * 0.25) * ANG(0, 0, math.pi),
		wood,
		M.Wood
	)
	b:box("ButtPlate", V3(0.145, 0.38, 0.03), CF(0, -0.13, zB), p.dark, M.Metal)
	b:ball("Bolt", 0.075, CF(0, 0.16, -0.12), metal, M.Metal)
	b:box("RearSight", V3(0.08, 0.06, 0.08), CF(0, 0.15, 0.2), p.dark, M.Metal)
	b:box("FrontSight", V3(0.02, 0.06, 0.03), CF(0, 0.12, zM + 0.16), p.dark, M.Metal)
	trigger(b, 0.05)
	local kind = p.magazine == "drum" and "drum" or "stick"
	local out = Parts.magazine(b, kind, CF(0, -0.07, -0.33), kind == "drum" and 0.5 or 0.38)
	b:standard(V3(0, 0.05, zM), V3(0, -0.17, 0.18), V3(0, -0.2, -0.68), V3(0, 0.18, 0.2), V3(0.09, 0.08, -0.15))
	b:meta("Rifle", 0.42, out, "slide")
end

local function mp40(b: B)
	local p = b.p
	local L = p.length
	local zB = L * 0.42
	local zM = zB - L
	local metal = p.metal
	b:cylZ("Receiver", 0.85, 0.13, CF(0, 0.05, -0.08), metal, M.Metal)
	b:box("Frame", V3(0.12, 0.13, 0.58), CF(0, -0.07, 0.1), BAKELITE, M.Plastic)
	b:box("Grip", V3(0.11, 0.3, 0.14), CF(0, -0.26, 0.25) * ANG(0.2, 0, 0), BAKELITE, M.Plastic)
	local barrelLen = -zM - 0.5
	b:cylZ("Barrel", barrelLen, 0.07, CF(0, 0.03, -0.5 - barrelLen / 2), metal, M.Metal)
	b:box("BarrelRest", V3(0.07, 0.07, 0.18), CF(0, -0.05, -0.62), p.dark, M.Metal)
	b:box("MagHousing", V3(0.12, 0.16, 0.15), CF(0, -0.15, -0.36), metal, M.Metal)
	-- Folding stock: twin rails and a hinged butt plate
	local railLen = zB - 0.38
	for i, x in { -0.065, 0.065 } do
		b:box(`StockRail{i}`, V3(0.025, 0.04, railLen), CF(x, -0.04, 0.38 + railLen / 2), p.dark, M.Metal)
	end
	b:box("ButtPlate", V3(0.16, 0.26, 0.04), CF(0, -0.1, zB), p.dark, M.Metal)
	b:box("Bolt", V3(0.12, 0.04, 0.04), CF(-0.1, 0.06, -0.12), metal, M.Metal)
	b:box("FrontHood", V3(0.06, 0.08, 0.06), CF(0, 0.11, zM + 0.06), p.dark, M.Metal)
	b:box("RearSight", V3(0.08, 0.05, 0.06), CF(0, 0.14, 0.05), p.dark, M.Metal)
	trigger(b, 0.13, -0.17)
	local out = Parts.magazine(b, "stick", CF(0, -0.22, -0.36), 0.45)
	b:standard(V3(0, 0.03, zM), V3(0, -0.24, 0.25), V3(0, -0.2, -0.36), V3(0, 0.17, 0.05), V3(0.09, 0.08, -0.15))
	b:meta("Rifle", 0.42, out, "slide")
end

local function sten(b: B)
	local p = b.p
	local L = p.length
	local zB = L * 0.44
	local zM = zB - L
	local metal = p.metal
	b:cylZ("Body", 1.0, 0.15, CF(0, 0.03, 0.02), metal, M.Metal)
	b:cylZ("Shroud", 0.38, 0.11, CF(0, 0.03, -0.66), p.dark, M.Metal)
	local barrelLen = math.max(0.1, -zM - 0.85)
	b:cylZ("Barrel", barrelLen, 0.06, CF(0, 0.03, -0.85 - barrelLen / 2), metal, M.Metal)
	b:box("TriggerHousing", V3(0.1, 0.13, 0.26), CF(0, -0.1, 0.12), metal, M.Metal)
	-- Skeletal stock: top tube, angled lower strut and T-plate
	local stockLen = zB - 0.5
	b:cylZ("StockTube", stockLen, 0.05, CF(0, 0.0, 0.5 + stockLen / 2), metal, M.Metal)
	b:box(
		"StockStrut",
		V3(0.04, 0.04, stockLen + 0.05),
		CF(0, -0.14, 0.45 + stockLen / 2) * ANG(-0.15, 0, 0),
		metal,
		M.Metal
	)
	b:box("ButtPlate", V3(0.07, 0.32, 0.05), CF(0, -0.1, zB), metal, M.Metal)
	b:box("Bolt", V3(0.1, 0.04, 0.04), CF(0.1, 0.06, 0.05), metal, M.Metal)
	b:box("RearSight", V3(0.05, 0.08, 0.04), CF(0, 0.13, 0.45), p.dark, M.Metal)
	b:box("FrontSight", V3(0.02, 0.07, 0.03), CF(0, 0.11, -0.55), p.dark, M.Metal)
	trigger(b, 0.1, -0.16)
	local out = Parts.magazine(b, "side", CF(0, 0.03, -0.36), 0.42)
	b:standard(V3(0, 0.03, zM), V3(0, -0.06, 0.38), V3(-0.15, -0.02, -0.36), V3(0, 0.16, 0.45), V3(0.09, 0.08, -0.1))
	b:meta("Rifle", 0.36, out, "slide")
end

local function ppsh(b: B)
	local p = b.p
	local L = p.length
	local zB = L * 0.44
	local zM = zB - L
	local wood, metal = p.wood, p.metal
	b:box("Receiver", V3(0.15, 0.15, 0.7), CF(0, 0.08, -0.12), metal, M.Metal)
	b:box("Stock", V3(0.16, 0.17, 0.85), CF(0, -0.06, 0.22), wood, M.Wood)
	local buttLen = zB - 0.62
	b:box("Butt", V3(0.15, 0.3, buttLen), CF(0, -0.14, 0.62 + buttLen / 2), wood, M.Wood)
	b:wedge("ButtToe", V3(0.14, 0.12, 0.35), CF(0, -0.23, 0.45) * ANG(0, 0, math.pi), wood, M.Wood)
	b:box("ButtPlate", V3(0.155, 0.31, 0.03), CF(0, -0.14, zB), p.dark, M.Metal)
	local jacketLen = -zM - 0.55
	Parts.perforatedJacket(b, CF(0, 0.07, -0.47 - jacketLen / 2), jacketLen, 0.14, true, 3)
	b:box("MuzzleBrake", V3(0.15, 0.15, 0.08), CF(0, 0.07, zM + 0.04) * ANG(-0.45, 0, 0), metal, M.Metal)
	b:box("Bolt", V3(0.1, 0.04, 0.05), CF(0.1, 0.08, -0.1), metal, M.Metal)
	b:box("RearSight", V3(0.07, 0.05, 0.08), CF(0, 0.18, -0.02), p.dark, M.Metal)
	b:box("FrontHood", V3(0.05, 0.07, 0.05), CF(0, 0.17, zM + 0.14), p.dark, M.Metal)
	trigger(b, 0.08, -0.17)
	local kind = (p.magazine == "box" or p.magazine == "stick") and "curved" or "drum"
	local out = Parts.magazine(b, kind, CF(0, -0.12, -0.36), kind == "drum" and 0.5 or 0.45)
	b:standard(V3(0, 0.07, zM), V3(0, -0.12, 0.38), V3(0, -0.05, -0.6), V3(0, 0.2, -0.02), V3(0.09, 0.1, -0.15))
	b:meta("Rifle", 0.45, out, "slide")
end

local function m3(b: B)
	local p = b.p
	local L = p.length
	local zB = L * 0.44
	local zM = zB - L
	local metal = p.metal
	b:cylZ("Body", 0.8, 0.22, CF(0, 0.02, -0.12), metal, M.Metal)
	b:box("Grip", V3(0.11, 0.3, 0.14), CF(0, -0.24, 0.22) * ANG(0.25, 0, 0), metal, M.Metal)
	local barrelLen = math.max(0.15, -zM - 0.52)
	b:cylZ("Barrel", barrelLen, 0.07, CF(0, 0.02, -0.52 - barrelLen / 2), metal, M.Metal)
	local wireLen = zB - 0.3
	for i, x in { -0.06, 0.06 } do
		b:box(`Wire{i}`, V3(0.025, 0.025, wireLen), CF(x, -0.03, 0.3 + wireLen / 2), metal, M.Metal)
	end
	b:box("ButtPlate", V3(0.15, 0.2, 0.03), CF(0, -0.08, zB), metal, M.Metal)
	b:box("Bolt", V3(0.08, 0.05, 0.08), CF(0.1, -0.05, 0.08), p.dark, M.Metal)
	b:box("RearSight", V3(0.05, 0.06, 0.04), CF(0, 0.15, 0.2), p.dark, M.Metal)
	trigger(b, 0.12, -0.16)
	local out = Parts.magazine(b, "stick", CF(0, -0.08, -0.3), 0.45)
	b:standard(V3(0, 0.02, zM), V3(0, -0.22, 0.22), V3(0, -0.25, -0.3), V3(0, 0.17, 0.2), V3(0.12, 0.05, -0.1))
	b:meta("Rifle", 0.38, out, "slide")
end

function Automatics.SMG(b: B)
	local v = b.p.variant
	if v == "mp40" then
		mp40(b)
	elseif v == "sten" then
		sten(b)
	elseif v == "ppsh" then
		ppsh(b)
	elseif v == "m3" then
		m3(b)
	elseif v == "thompson" then
		thompson(b)
	else
		-- generic: choose by magazine layout
		local mag = b.p.magazine
		if mag == "side" then
			sten(b)
		elseif mag == "drum" then
			ppsh(b)
		else
			thompson(b)
		end
	end
end

--------------------------------------------------------------------------------------------------
-- LMG
--------------------------------------------------------------------------------------------------

function Automatics.LMG(b: B)
	local p = b.p
	local v = p.variant
	if v == "generic" then
		local mag = p.magazine
		v = (mag == "top") and "bren" or (mag == "drum" and "dp" or "bar")
	end
	local L = p.length
	local zB = L * 0.36
	local zM = zB - L
	local wood, metal = p.wood, p.metal

	b:box("Receiver", V3(0.17, 0.22, 1.05), CF(0, 0.03, -0.08), metal, M.Metal)
	trigger(b, 0.12, -0.13)

	local barrelY = 0.06
	local magOut: Vector3
	local sight = V3(0, 0.2, 0.25)
	local support = V3(0, -0.06, -0.95)
	local grip = V3(0, -0.12, 0.42)

	if v == "bren" or v == "type96" then
		local barrelLen = -zM - 0.6
		b:cylZ("Barrel", barrelLen, 0.08, CF(0, barrelY, -0.6 - barrelLen / 2), metal, M.Metal)
		b:cylZ("FlashHider", 0.18, 0.12, CF(0, barrelY, zM + 0.09), p.dark, M.Metal)
		b:cylZ("GasCylinder", barrelLen * 0.55, 0.07, CF(0, -0.04, -0.6 - barrelLen * 0.3), metal, M.Metal)
		b:box("CarryHandle", V3(0.04, 0.16, 0.3), CF(0.1, 0.17, -0.85) * ANG(0, 0, -0.3), wood, M.Wood)
		b:box("PistolGrip", V3(0.11, 0.3, 0.15), CF(0, -0.22, 0.2) * ANG(0.2, 0, 0), wood, M.Wood)
		local buttLen = zB - 0.45
		b:box("Butt", V3(0.13, 0.26, buttLen), CF(0, -0.04, 0.45 + buttLen / 2), wood, M.Wood)
		b:box("ButtStrap", V3(0.05, 0.05, buttLen), CF(0, 0.11, 0.45 + buttLen / 2), p.dark, M.Metal)
		b:box("ButtPlate", V3(0.14, 0.3, 0.04), CF(0, -0.04, zB), p.dark, M.Metal)
		Parts.bipod(b, CF(0, -0.02, -0.6 - barrelLen * 0.55), 0.75)
		magOut = Parts.magazine(b, "top", CF(0, 0.14, -0.3), 0.5)
		-- Offset sights clear the top magazine (Bren: left, Type 96/99: right)
		local x = (v == "bren") and -0.17 or 0.17
		b:box("SightArm", V3(0.15, 0.03, 0.05), CF(x / 2, 0.14, 0.3), p.dark, M.Metal)
		b:cylX("RearDrum", 0.06, 0.09, CF(x, 0.17, 0.3), p.dark, M.Metal)
		b:box("FrontSightArm", V3(0.15, 0.025, 0.04), CF(x / 2, 0.1, zM + 0.4), p.dark, M.Metal)
		b:box("FrontSight", V3(0.02, 0.1, 0.03), CF(x, 0.16, zM + 0.4), p.dark, M.Metal)
		sight = V3(x, 0.2, 0.3)
		grip = V3(0, -0.2, 0.2)
		support = V3(0, 0.1, 0.55) -- left hand on top of the butt (classic Bren hold)
	elseif v == "dp" then
		local jacketLen = (-zM - 0.55) * 0.7
		Parts.perforatedJacket(b, CF(0, barrelY, -0.55 - jacketLen / 2), jacketLen, 0.16, true, 4)
		local rest = -zM - 0.55 - jacketLen
		b:cylZ("Barrel", rest, 0.07, CF(0, barrelY, zM + rest / 2), metal, M.Metal)
		b:cylZ("FlashHider", 0.16, 0.11, CF(0, barrelY, zM + 0.08), p.dark, M.Metal)
		local buttLen = zB - 0.3
		b:box("Butt", V3(0.14, 0.3, buttLen), CF(0, -0.1, 0.3 + buttLen / 2), wood, M.Wood)
		b:wedge("ButtToe", V3(0.13, 0.12, 0.35), CF(0, -0.27, 0.48) * ANG(0, 0, math.pi), wood, M.Wood)
		b:box("ButtPlate", V3(0.15, 0.31, 0.03), CF(0, -0.1, zB), p.dark, M.Metal)
		Parts.bipod(b, CF(0, -0.03, zM + 0.4), 0.75)
		magOut = Parts.magazine(b, "pan", CF(0, 0.14, -0.2), 0.5)
		b:box("FrontSight", V3(0.02, 0.28, 0.03), CF(0, 0.2, zM + 0.25), p.dark, M.Metal)
		b:box("RearSight", V3(0.07, 0.12, 0.06), CF(0, 0.21, 0.32), p.dark, M.Metal)
		sight = V3(0, 0.3, 0.33)
		support = V3(0, -0.05, -0.75)
	else -- bar
		local barrelLen = -zM - 0.6
		b:cylZ("Barrel", barrelLen, 0.075, CF(0, barrelY, -0.6 - barrelLen / 2), metal, M.Metal)
		b:cylZ("FlashHider", 0.16, 0.11, CF(0, barrelY, zM + 0.08), p.dark, M.Metal)
		b:cylZ("GasCylinder", barrelLen * 0.6, 0.08, CF(0, -0.05, -0.6 - barrelLen * 0.32), metal, M.Metal)
		b:box("Forend", V3(0.16, 0.16, 0.6), CF(0, -0.04, -0.95), wood, M.Wood)
		local wristLen = 0.45
		b:box("Wrist", V3(0.13, 0.17, wristLen), CF(0, -0.07, 0.48 + wristLen / 2) * ANG(0.08, 0, 0), wood, M.Wood)
		local buttLen = zB - 0.48 - wristLen
		b:box("Butt", V3(0.15, 0.33, buttLen), CF(0, -0.15, zB - buttLen / 2), wood, M.Wood)
		b:box("ButtPlate", V3(0.155, 0.34, 0.035), CF(0, -0.15, zB), p.dark, M.Metal)
		Parts.bipod(b, CF(0, 0.0, zM + 0.25), 0.8)
		magOut = Parts.magazine(b, p.magazine == "top" and "box" or p.magazine, CF(0, -0.08, -0.3), 0.3)
		b:box("RearSight", V3(0.08, 0.07, 0.08), CF(0, 0.17, 0.32), p.dark, M.Metal)
		b:box("FrontSight", V3(0.02, 0.07, 0.03), CF(0, 0.13, zM + 0.12), p.dark, M.Metal)
		sight = V3(0, 0.2, 0.32)
		grip = V3(0, -0.13, 0.48)
	end
	b:box("Bolt", V3(0.1, 0.05, 0.06), CF(0.12, 0.0, -0.35), p.dark, M.Metal)

	b:standard(V3(0, barrelY, zM), grip, support, sight, V3(0.1, -0.05, -0.2))
	b:meta("MG", 0.5, magOut, "slide")
end

--------------------------------------------------------------------------------------------------
-- HMG (bipod GPMG: MG42 / MG34 / M1919)
--------------------------------------------------------------------------------------------------

function Automatics.HMG(b: B)
	local p = b.p
	local v = p.variant
	local L = p.length
	local zB = L * 0.3
	local zM = zB - L
	local metal = p.metal
	local stockColor = (v == "m1919") and p.wood or BAKELITE

	b:box("Receiver", V3(0.2, 0.22, 1.0), CF(0, 0.04, 0.0), metal, M.Metal)
	b:box("Lid", V3(0.19, 0.05, 0.5), CF(0, 0.175, -0.1), Builder.shade(metal, 0.85), M.Metal)
	trigger(b, 0.18, -0.13)
	b:box("PistolGrip", V3(0.11, 0.3, 0.15), CF(0, -0.25, 0.24) * ANG(0.2, 0, 0), stockColor, M.Plastic)

	local jacketLen = (-zM - 0.5) * 0.85
	local round = v == "mg34" or v == "m1919"
	Parts.perforatedJacket(b, CF(0, 0.05, -0.5 - jacketLen / 2), jacketLen, round and 0.17 or 0.19, round, 5)
	local rest = -zM - 0.5 - jacketLen
	b:cylZ("MuzzleBooster", rest, 0.14, CF(0, 0.05, zM + rest / 2), p.dark, M.Metal)

	local buttLen = zB - 0.5
	b:box("Butt", V3(0.14, 0.24, buttLen), CF(0, -0.04, 0.5 + buttLen / 2), stockColor, M.Plastic)
	b:wedge(
		"ButtToe",
		V3(0.13, 0.12, buttLen * 0.5),
		CF(0, -0.22, zB - buttLen * 0.25) * ANG(0, 0, math.pi),
		stockColor,
		M.Plastic
	)
	b:box("ButtPlate", V3(0.145, 0.38, 0.03), CF(0, -0.1, zB), p.dark, M.Metal)

	Parts.bipod(b, CF(0, -0.07, -0.65), 0.8, true)
	b:box("Bolt", V3(0.1, 0.06, 0.08), CF(0.13, 0.0, -0.3), p.dark, M.Metal)

	-- Belt box + belt on the left side
	local can = Color3.fromRGB(78, 84, 60)
	b:box("Mag", V3(0.22, 0.32, 0.42), CF(-0.27, -0.2, -0.3), can, M.Metal)
	b:box("Belt", V3(0.2, 0.035, 0.13), CF(-0.13, 0.05, -0.3) * ANG(0, 0, 0.6), Color3.fromRGB(176, 140, 70), M.Metal)

	b:box("RearSight", V3(0.06, 0.1, 0.06), CF(0, 0.24, -0.38), p.dark, M.Metal)
	b:box("FrontSight", V3(0.02, 0.12, 0.03), CF(0, 0.19, zM + jacketLen * 0.15 + rest), p.dark, M.Metal)

	b:standard(V3(0, 0.05, zM), V3(0, -0.22, 0.24), V3(0, -0.06, 0.62), V3(0, 0.27, -0.38), V3(0.11, -0.05, -0.15))
	b:meta("MG", 0.55, V3(-1, 0, 0), "slide")
end

return Automatics
