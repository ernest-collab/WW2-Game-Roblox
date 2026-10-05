--[[
	Anti-tank launcher archetypes: Bazooka (M1 / Panzerschreck variant), Panzerfaust, PIAT.
	All use Hold = "Launcher" (shoulder-fired); the "Mag" is the projectile being loaded.
]]

local Builder = require(script.Parent.Builder)

type B = Builder.Builder

local M = Builder.Mat
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local Launchers = {}

function Launchers.Bazooka(b: B)
	local p = b.p
	local L = p.length
	local schreck = p.variant == "panzerschreck"
	local tubeCol = p.metal
	local wood = p.wood
	local zR = 1.45 -- rear end of the tube
	local zF = zR - L
	local tubeY = 0.3
	local d = schreck and 0.34 or 0.3

	b:cylZ("Tube", L, d, CF(0, tubeY, zR - L / 2), tubeCol, M.Metal)
	b:cylZ("FrontRing", 0.08, d + 0.06, CF(0, tubeY, zF + 0.04), Builder.shade(tubeCol, 0.8), M.Metal)
	b:cylZ("RearFlare", 0.12, d + 0.12, CF(0, tubeY, zR - 0.06), Builder.shade(tubeCol, 0.8), M.Metal)
	b:cylZ("MidBand", 0.06, d + 0.04, CF(0, tubeY, zR - L * 0.55), Builder.shade(tubeCol, 0.8), M.Metal)
	b:box("ShoulderRest", V3(0.14, 0.24, 0.55), CF(0, tubeY - d / 2 - 0.1, zR - 0.55), wood, M.Wood)
	b:box("RearGrip", V3(0.12, 0.32, 0.14), CF(0, -0.1, 0) * ANG(0.15, 0, 0), wood, M.Wood)
	b:box("TriggerGuard", V3(0.035, 0.03, 0.18), CF(0, -0.02, -0.13), p.dark, M.Metal)
	b:box("FrontGrip", V3(0.12, 0.3, 0.14), CF(0, -0.08, -0.95), wood, M.Wood)
	b:box("Contact", V3(0.12, 0.12, 0.22), CF(d / 2 + 0.04, tubeY + 0.05, zR - 0.4), p.dark, M.Metal)

	-- Sights on the left side
	local sx = -(d / 2 + 0.06)
	b:box("SightFrontArm", V3(0.06, 0.03, 0.04), CF(sx + 0.03, tubeY + 0.12, zF + 0.6), p.dark, M.Metal)
	b:box("SightFront", V3(0.03, 0.22, 0.03), CF(sx, tubeY + 0.22, zF + 0.6), p.dark, M.Metal)
	b:box("SightRear", V3(0.04, 0.08, 0.04), CF(sx, tubeY + 0.27, 0.35), p.dark, M.Metal)

	if schreck then
		b:box("Shield", V3(0.9, 0.75, 0.03), CF(-0.12, tubeY + 0.15, -0.55), Builder.shade(tubeCol, 0.95), M.Metal)
		b:box(
			"ShieldWindow",
			V3(0.18, 0.14, 0.035),
			CF(sx, tubeY + 0.3, -0.55),
			Color3.fromRGB(80, 100, 110),
			Enum.Material.Glass
		)
	end

	-- Rocket (hidden inside the rear until it is loaded)
	local rocket = b:cylZ("Mag", 0.5, d * 0.75, CF(0, tubeY, zR - 0.3), Color3.fromRGB(70, 74, 60), M.Metal)
	b:cylZ("RocketFins", 0.16, d * 0.85, CF(0, tubeY, zR - 0.02), p.dark, M.Metal, rocket)

	b:standard(
		V3(0, tubeY, zF),
		V3(0, -0.1, 0.02),
		V3(0, -0.1, -0.95),
		V3(sx, tubeY + 0.31, 0.35),
		V3(0, tubeY, zR + 0.1)
	)
	b:meta("Launcher", 0.35, V3(0, 0, 1), "none")
end

function Launchers.Panzerfaust(b: B)
	local p = b.p
	local L = p.length
	local tube = p.metal
	local tubeY = 0.16
	local zR = 1.2
	local zF = zR - L

	b:cylZ("Tube", L - 0.4, 0.16, CF(0, tubeY, zR - (L - 0.4) / 2), tube, M.Metal)
	-- Warhead: fat cylinder + rounded nose + stem
	local head = Color3.fromRGB(70, 72, 52)
	b:cylZ("WarheadStem", 0.22, 0.13, CF(0, tubeY, zF + 0.47), head, M.Metal)
	b:cylZ("Warhead", 0.26, 0.42, CF(0, tubeY, zF + 0.28), head, M.Metal)
	b:ball("WarheadNose", 0.4, CF(0, tubeY, zF + 0.16), head, M.Metal)
	b:cylZ("WarheadTip", 0.08, 0.14, CF(0, tubeY, zF + 0.0), p.dark, M.Metal)
	b:box("SightFlap", V3(0.08, 0.16, 0.02), CF(0, tubeY + 0.16, -0.25), Color3.fromRGB(150, 150, 60), M.Metal)
	b:box("TriggerLever", V3(0.04, 0.04, 0.25), CF(0, tubeY + 0.1, -0.05), p.dark, M.Metal)
	b:box("Label", V3(0.165, 0.12, 0.4), CF(0, tubeY, 0.4), Builder.shade(tube, 1.15), M.Metal)
	b:cylZ("RearRim", 0.05, 0.18, CF(0, tubeY, zR - 0.02), p.dark, M.Metal)
	-- Single shot: "Mag" is a fresh tube's warhead marker (kept small)
	b:box("Mag", V3(0.03, 0.03, 0.03), CF(0, tubeY, zR - 0.2), tube, M.Metal)

	b:standard(
		V3(0, tubeY, zF),
		V3(0, -0.02, 0.15),
		V3(0, 0.0, -0.75),
		V3(0, tubeY + 0.24, -0.25),
		V3(0, tubeY, zR + 0.1)
	)
	b:meta("Launcher", 0.4, V3(0, -1, 0), "none")
end

function Launchers.PIAT(b: B)
	local p = b.p
	local body = p.metal
	local dark = p.dark
	local y = 0.24

	b:box("Body", V3(0.28, 0.32, 1.9), CF(0, y, 0.0), body, M.Metal)
	b:box("BodyTop", V3(0.2, 0.08, 1.6), CF(0, y + 0.19, 0.05), Builder.shade(body, 0.9), M.Metal)
	b:box("TroughBase", V3(0.28, 0.04, 0.7), CF(0, y + 0.0, -1.3), dark, M.Metal)
	b:box("TroughL", V3(0.03, 0.22, 0.7), CF(-0.13, y + 0.1, -1.3), dark, M.Metal)
	b:box("TroughR", V3(0.03, 0.22, 0.7), CF(0.13, y + 0.1, -1.3), dark, M.Metal)
	local bomb = b:cylZ("Mag", 0.38, 0.22, CF(0, y + 0.13, -1.45), Color3.fromRGB(86, 80, 50), M.Metal)
	b:ball("BombNose", 0.22, CF(0, y + 0.13, -1.65), Color3.fromRGB(86, 80, 50), M.Metal, bomb)
	b:cylZ("BombTail", 0.3, 0.09, CF(0, y + 0.13, -1.12), dark, M.Metal, bomb)
	b:box("ShoulderPad", V3(0.16, 0.46, 0.16), CF(0, y - 0.05, 1.05), Color3.fromRGB(50, 40, 32), M.Leather)
	b:box("PadStem", V3(0.08, 0.08, 0.2), CF(0, y, 0.95), dark, M.Metal)
	b:box("TriggerGrip", V3(0.1, 0.32, 0.15), CF(0, -0.1, 0.1) * ANG(0.15, 0, 0), dark, M.Metal)
	b:box("TriggerGuard", V3(0.035, 0.03, 0.18), CF(0, -0.02, -0.05), dark, M.Metal)
	b:box("Monopod", V3(0.04, 0.6, 0.04), CF(0, y - 0.4, -0.95) * ANG(-0.5, 0, 0), dark, M.Metal)
	b:box("SightBracket", V3(0.03, 0.22, 0.04), CF(-0.17, y + 0.2, -0.55), dark, M.Metal)
	b:box("SightRear", V3(0.03, 0.1, 0.06), CF(-0.17, y + 0.26, 0.45), dark, M.Metal)

	b:standard(
		V3(0, y + 0.13, -1.7),
		V3(0, -0.08, 0.12),
		V3(0, y - 0.18, -0.6),
		V3(-0.17, y + 0.31, 0.47),
		V3(0, y, -1.0)
	)
	b:meta("Launcher", 0.35, V3(0, 1, 0), "none")
end

return Launchers
