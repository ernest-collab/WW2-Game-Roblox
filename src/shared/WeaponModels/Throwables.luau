--[[
	Throwable archetypes: StickGrenade, FragGrenade, SmokeGrenade, Satchel.
	Built upright (+Y) with the Handle in the palm. "Muzzle" marks the release point; "Support"
	is where the off hand pulls the pin / fuse cord. Hold = "Throwable".
]]

local Builder = require(script.Parent.Builder)

type B = Builder.Builder

local M = Builder.Mat
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local Throwables = {}

local function pinRing(b: B, at: CFrame)
	b:cylX("PinRing", 0.02, 0.13, at, Color3.fromRGB(170, 170, 170), M.Metal)
end

function Throwables.StickGrenade(b: B)
	local p = b.p
	local wood = p.wood
	local head = p.accent
	b:cylY("StickHandle", 1.0, 0.12, CF(0, 0.15, 0), wood, M.Wood)
	b:cylY("HeadCan", 0.36, 0.27, CF(0, 0.82, 0), head, M.Metal)
	b:cylY("HeadRim", 0.04, 0.29, CF(0, 0.65, 0), Builder.shade(head, 0.8), M.Metal)
	b:cylY("HeadTop", 0.03, 0.2, CF(0, 1.01, 0), Builder.shade(head, 0.8), M.Metal)
	b:cylY("Cap", 0.06, 0.14, CF(0, -0.37, 0), p.metal, M.Metal)
	b:box("Label", V3(0.005, 0.2, 0.1), CF(0.135, 0.82, 0), Color3.fromRGB(210, 210, 200), M.Plastic)
	b:cylY("FuseCord", 0.08, 0.03, CF(0, -0.43, 0), Color3.fromRGB(220, 220, 220), M.Fabric)
	b:ball("FuseBead", 0.06, CF(0, -0.48, 0), Color3.fromRGB(230, 230, 230), M.Plastic)
	b:standard(V3(0, 1.05, 0), V3(0, 0.05, 0), V3(0, -0.45, 0), V3(0, 0.2, 0.4), V3(0, 0.82, 0))
	b:meta("Throwable", 1.0, V3(0, -1, 0), "none")
end

function Throwables.FragGrenade(b: B)
	local p = b.p
	local body = p.accent
	local cylinderBody = p.variant == "type97"
	if cylinderBody then
		b:cylY("Body", 0.34, 0.26, CF(0, 0.05, 0), body, M.Metal)
		for i = 1, 3 do
			b:cylY(`Rib{i}`, 0.03, 0.28, CF(0, -0.07 + i * 0.07, 0), Builder.shade(body, 0.75), M.Metal)
		end
	else
		b:ball("Body", 0.32, CF(0, 0.02, 0), body, M.Metal)
		b:cylY("BodyMid", 0.18, 0.3, CF(0, 0.04, 0), body, M.Metal)
		b:cylY("Groove1", 0.025, 0.315, CF(0, -0.02, 0), Builder.shade(body, 0.6), M.Metal)
		b:cylY("Groove2", 0.025, 0.315, CF(0, 0.09, 0), Builder.shade(body, 0.6), M.Metal)
		b:box("GrooveV1", V3(0.32, 0.26, 0.02), CF(0, 0.03, 0), Builder.shade(body, 0.6), M.Metal)
		b:box("GrooveV2", V3(0.02, 0.26, 0.32), CF(0, 0.03, 0), Builder.shade(body, 0.6), M.Metal)
	end
	b:cylY("Fuse", 0.12, 0.09, CF(0, 0.25, 0), p.metal, M.Metal)
	local spoon = b:box("Bolt", V3(0.05, 0.26, 0.06), CF(0.11, 0.17, 0) * ANG(0, 0, -0.25), p.metal, M.Metal)
	b:box("SpoonTop", V3(0.12, 0.03, 0.06), CF(0.05, 0.3, 0), p.metal, M.Metal, spoon)
	pinRing(b, CF(-0.08, 0.27, 0))
	b:standard(V3(0, 0.35, 0), V3(0, 0, 0), V3(-0.12, 0.27, 0), V3(0, 0.2, 0.4), V3(0, 0.25, 0))
	b:meta("Throwable", 1.0, V3(0, -1, 0), "none")
end

function Throwables.SmokeGrenade(b: B)
	local p = b.p
	if p.variant == "stick" then
		Throwables.StickGrenade(b)
		b:cylY("SmokeBand", 0.06, 0.28, CF(0, 0.9, 0), Color3.fromRGB(235, 235, 235), M.Plastic)
		return
	end
	local body = p.accent
	b:cylY("Can", 0.55, 0.28, CF(0, 0.08, 0), body, M.Metal)
	b:cylY("Band", 0.07, 0.285, CF(0, 0.2, 0), Color3.fromRGB(220, 200, 80), M.Plastic)
	b:cylY("TopRim", 0.03, 0.29, CF(0, 0.355, 0), Builder.shade(body, 0.8), M.Metal)
	b:cylY("BottomRim", 0.03, 0.29, CF(0, -0.195, 0), Builder.shade(body, 0.8), M.Metal)
	for i = 0, 2 do
		local a = i * math.pi * 2 / 3
		b:box(
			`Vent{i}`,
			V3(0.06, 0.04, 0.02),
			CF(0, -0.12, 0) * ANG(0, a, 0) * CF(0, 0, -0.14),
			Color3.fromRGB(20, 20, 20),
			M.Metal
		)
	end
	b:cylY("Fuse", 0.12, 0.09, CF(0, 0.42, 0), p.metal, M.Metal)
	local spoon = b:box("Bolt", V3(0.05, 0.4, 0.06), CF(0.15, 0.24, 0) * ANG(0, 0, -0.1), p.metal, M.Metal)
	b:box("SpoonTop", V3(0.12, 0.03, 0.06), CF(0.08, 0.46, 0), p.metal, M.Metal, spoon)
	pinRing(b, CF(-0.08, 0.44, 0))
	b:standard(V3(0, 0.5, 0), V3(0, 0, 0), V3(-0.12, 0.44, 0), V3(0, 0.2, 0.4), V3(0, 0.42, 0))
	b:meta("Throwable", 1.0, V3(0, -1, 0), "none")
end

function Throwables.Satchel(b: B)
	local p = b.p
	local canvas = p.accent
	local strap = Builder.shade(canvas, 0.75)
	b:box("Bag", V3(0.75, 0.5, 0.32), CF(0, -0.35, 0), canvas, M.Fabric)
	b:box("Flap", V3(0.77, 0.26, 0.03), CF(0, -0.22, -0.17), Builder.shade(canvas, 0.9), M.Fabric)
	b:box("BuckleL", V3(0.06, 0.07, 0.02), CF(-0.22, -0.34, -0.19), p.metal, M.Metal)
	b:box("BuckleR", V3(0.06, 0.07, 0.02), CF(0.22, -0.34, -0.19), p.metal, M.Metal)
	b:box("StrapL", V3(0.06, 0.38, 0.05), CF(-0.25, -0.0, 0) * ANG(0, 0, -0.45), strap, M.Fabric)
	b:box("StrapR", V3(0.06, 0.38, 0.05), CF(0.25, -0.0, 0) * ANG(0, 0, 0.45), strap, M.Fabric)
	b:box("StrapTop", V3(0.22, 0.06, 0.05), CF(0, 0.15, 0), strap, M.Fabric)
	b:cylY("Igniter", 0.2, 0.06, CF(0.3, -0.02, -0.08), p.metal, M.Metal)
	b:box("FuseCord", V3(0.02, 0.02, 0.3), CF(0.3, -0.12, -0.05) * ANG(0.9, 0, 0), Color3.fromRGB(30, 30, 30), M.Fabric)
	b:standard(V3(0, -0.35, 0), V3(0, 0.12, 0), V3(0.3, 0.06, -0.08), V3(0, 0.2, 0.4), V3(0, -0.35, 0))
	b:meta("Throwable", 1.0, V3(0, -1, 0), "none")
end

return Throwables
