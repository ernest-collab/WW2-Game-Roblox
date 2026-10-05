--[[
	Handgun archetypes: Pistol (auto: M1911/P38/TT-33 | luger: P08/Nambu toggle-lock) and Revolver.
	The Handle sits at the trigger; "Slide" and "Mag" are animated by the viewmodel.
]]

local Builder = require(script.Parent.Builder)

type B = Builder.Builder

local M = Builder.Mat
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local Handguns = {}

function Handguns.Pistol(b: B)
	local p = b.p
	local s = p.scale
	local metal, grips = p.metal, p.wood
	local luger = p.variant == "luger"
	local gripAngle = luger and 0.45 or 0.22

	local slideLen = 0.82 * s
	local slideZ = -0.28 * s
	local slide
	if luger then
		-- Thin round barrel ahead of a receiver with a toggle knob on top
		slide = b:box("Slide", V3(0.1, 0.12, 0.42), CF(0, 0.1, 0.0), metal, M.Metal)
		b:ball("ToggleL", 0.09, CF(-0.06, 0.17, 0.12), metal, M.Metal, slide)
		b:ball("ToggleR", 0.09, CF(0.06, 0.17, 0.12), metal, M.Metal, slide)
		b:box("ToggleLink", V3(0.12, 0.05, 0.12), CF(0, 0.17, 0.08), metal, M.Metal, slide)
		b:cylZ("Barrel", 0.55 * s, 0.07, CF(0, 0.1, -0.2 - 0.275 * s), metal, M.Metal)
		b:box("FrontSight", V3(0.02, 0.05, 0.03), CF(0, 0.155, -0.18 - 0.53 * s), p.dark, M.Metal)
		b:box("RearSight", V3(0.06, 0.03, 0.04), CF(0, 0.2, 0.1), p.dark, M.Metal, slide)
	else
		slide = b:box("Slide", V3(0.11, 0.14, slideLen), CF(0, 0.12, slideZ), metal, M.Metal)
		b:box(
			"SlideSerrations",
			V3(0.115, 0.08, 0.12),
			CF(0, 0.12, slideZ + slideLen / 2 - 0.08),
			p.dark,
			M.Metal,
			slide
		)
		b:cylZ("Bushing", 0.04, 0.08, CF(0, 0.1, slideZ - slideLen / 2 - 0.01), p.dark, M.Metal, slide)
		b:box("RearSight", V3(0.09, 0.035, 0.04), CF(0, 0.205, slideZ + slideLen / 2 - 0.03), p.dark, M.Metal, slide)
		b:box("FrontSight", V3(0.02, 0.05, 0.03), CF(0, 0.205, slideZ - slideLen / 2 + 0.04), p.dark, M.Metal, slide)
		b:box(
			"Hammer",
			V3(0.035, 0.07, 0.04),
			CF(0, 0.16, slideZ + slideLen / 2 + 0.02) * ANG(-0.4, 0, 0),
			p.dark,
			M.Metal
		)
	end

	b:box("Frame", V3(0.1, 0.08, 0.62 * s), CF(0, 0.02, -0.2 * s), Builder.shade(metal, 0.9), M.Metal)
	local gripCF = CF(0, -0.21, 0.12) * ANG(gripAngle, 0, 0)
	b:box("GripFrame", V3(0.1, 0.44, 0.19), gripCF, Builder.shade(metal, 0.9), M.Metal)
	b:box("GripPanels", V3(0.115, 0.36, 0.15), gripCF * CF(0, 0.02, 0), grips, M.Wood)
	b:box("TriggerGuard", V3(0.035, 0.03, 0.2), CF(0, -0.08, -0.12), metal, M.Metal)
	b:box("TriggerGuardFront", V3(0.035, 0.1, 0.03), CF(0, -0.04, -0.21), metal, M.Metal)
	b:box("Trigger", V3(0.025, 0.07, 0.025), CF(0, -0.04, -0.08), p.dark, M.Metal)
	-- Magazine sits inside the grip (only the base plate shows until it is pulled)
	b:box("Mag", V3(0.08, 0.42, 0.13), gripCF * CF(0, -0.03, 0.0), p.dark, M.Metal)

	local muzzleZ = luger and (-0.2 - 0.55 * s) or (slideZ - slideLen / 2 - 0.03)
	b:standard(
		V3(0, 0.1, muzzleZ),
		V3(0, -0.17, 0.1),
		V3(-0.02, -0.26, 0.03),
		V3(0, 0.215, luger and 0.1 or (slideZ + slideLen / 2 - 0.03)),
		V3(0.07, 0.15, -0.15)
	)
	b:meta("Pistol", 1.35, V3(0, -1, 0), "slide")
end

function Handguns.Revolver(b: B)
	local p = b.p
	local s = p.scale
	local metal, grips = p.metal, p.wood

	local barrelLen = 0.6 * s
	b:cylZ("Barrel", barrelLen, 0.09, CF(0, 0.12, -0.32 - barrelLen / 2), metal, M.Metal)
	b:box("BarrelRib", V3(0.05, 0.05, barrelLen), CF(0, 0.17, -0.32 - barrelLen / 2), metal, M.Metal)
	b:cylZ("EjectorRod", barrelLen * 0.6, 0.04, CF(0, 0.05, -0.32 - barrelLen * 0.3), p.dark, M.Metal)
	b:box("Frame", V3(0.1, 0.24, 0.45), CF(0, 0.05, -0.08), metal, M.Metal)
	b:box("TopStrap", V3(0.08, 0.05, 0.35), CF(0, 0.19, -0.1), metal, M.Metal)
	local cyl = b:cylZ("Mag", 0.3, 0.26, CF(0, 0.08, -0.12), Builder.shade(metal, 1.1), M.Metal)
	for i = 0, 2 do
		local a = i * math.pi / 3
		b:box(`Flute{i}`, V3(0.28, 0.025, 0.2), CF(0, 0.08, -0.12) * ANG(0, 0, a), p.dark, M.Metal, cyl)
	end
	b:box("Hammer", V3(0.035, 0.09, 0.06), CF(0, 0.2, 0.15) * ANG(-0.5, 0, 0), p.dark, M.Metal)
	local gripCF = CF(0, -0.17, 0.2) * ANG(0.45, 0, 0)
	b:box("Grip", V3(0.11, 0.38, 0.17), gripCF, grips, M.Wood)
	b:ball("GripButt", 0.17, gripCF * CF(0, -0.18, 0.02), grips, M.Wood)
	b:box("TriggerGuard", V3(0.035, 0.03, 0.2), CF(0, -0.1, 0.0), metal, M.Metal)
	b:box("Trigger", V3(0.025, 0.08, 0.025), CF(0, -0.05, 0.02), p.dark, M.Metal)
	b:box("FrontSight", V3(0.02, 0.05, 0.03), CF(0, 0.2, -0.3 - barrelLen), p.dark, M.Metal)

	b:standard(
		V3(0, 0.12, -0.32 - barrelLen),
		V3(0, -0.15, 0.18),
		V3(-0.02, -0.24, 0.12),
		V3(0, 0.225, 0.08),
		V3(0, 0.08, -0.12)
	)
	b:meta("Pistol", 1.35, V3(-1, 0, 0), "none")
end

return Handguns
