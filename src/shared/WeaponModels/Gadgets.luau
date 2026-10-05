--[[
	Melee + gadget archetypes: Knife, Wrench, Medkit, AmmoBox, Binoculars.
	Knife/Wrench point down -Z like a barrel (Hold = "Melee"); Medkit/AmmoBox are carried in front
	(Hold = "Gadget"); Binoculars raise to the eyes when "aiming" (Hold = "Binoculars").
]]

local Builder = require(script.Parent.Builder)

type B = Builder.Builder

local M = Builder.Mat
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local Gadgets = {}

function Gadgets.Knife(b: B)
	local p = b.p
	local s = p.scale
	local steel = Color3.fromRGB(160, 162, 168)
	local bladeLen = 0.75 * s
	b:box("Blade", V3(0.03, 0.12, bladeLen), CF(0, 0.02, -0.17 - bladeLen / 2), steel, M.Metal)
	b:wedge("BladeTip", V3(0.03, 0.12, 0.2), CF(0, 0.02, -0.17 - bladeLen - 0.1) * ANG(0, 0, 0), steel, M.Metal)
	b:box(
		"Fuller",
		V3(0.034, 0.025, bladeLen * 0.7),
		CF(0, 0.045, -0.2 - bladeLen * 0.35),
		Builder.shade(steel, 0.7),
		M.Metal
	)
	b:box("Guard", V3(0.06, 0.26, 0.04), CF(0, 0.0, -0.15), p.metal, M.Metal)
	b:box("Handle", V3(0.09, 0.12, 0.4), CF(0, 0.0, 0.07), p.wood, M.Wood)
	b:box("HandleRing1", V3(0.095, 0.125, 0.02), CF(0, 0.0, -0.05), Builder.shade(p.wood, 0.6), M.Leather)
	b:box("HandleRing2", V3(0.095, 0.125, 0.02), CF(0, 0.0, 0.17), Builder.shade(p.wood, 0.6), M.Leather)
	b:box("Pommel", V3(0.1, 0.14, 0.06), CF(0, 0.0, 0.29), p.metal, M.Metal)
	b:standard(V3(0, 0.02, -0.27 - bladeLen), V3(0, 0, 0.07), V3(-0.3, -0.2, 0.2), V3(0, 0.25, 0.3), V3(0, 0, 0))
	b:meta("Melee", 1.0, V3(0, -1, 0), "none")
end

function Gadgets.Wrench(b: B)
	local p = b.p
	local s = p.scale
	local steel = p.metal
	local len = 1.15 * s
	b:box("Shaft", V3(0.07, 0.045, len), CF(0, 0, -len / 2 + 0.25), steel, M.Metal)
	b:box("Grip", V3(0.09, 0.07, 0.4), CF(0, 0, 0.1), Color3.fromRGB(120, 40, 30), M.Plastic)
	local headZ = -len + 0.25
	b:box("Head", V3(0.3, 0.07, 0.14), CF(0.05, 0, headZ), steel, M.Metal)
	b:box("JawFixed", V3(0.06, 0.07, 0.2), CF(0.17, 0, headZ - 0.12), steel, M.Metal)
	b:box("JawMoving", V3(0.06, 0.07, 0.16), CF(-0.05, 0, headZ - 0.11), Builder.shade(steel, 0.85), M.Metal)
	b:cylX("Screw", 0.14, 0.06, CF(0.04, -0.02, headZ + 0.08), Builder.shade(steel, 0.7), M.Metal)
	b:standard(V3(0.05, 0, headZ - 0.2), V3(0, 0, 0.1), V3(0, 0, -0.35), V3(0, 0.25, 0.3), V3(0, 0, 0))
	b:meta("Melee", 1.0, V3(0, -1, 0), "none")
end

function Gadgets.Medkit(b: B)
	local p = b.p
	local bag = p.accent
	local red = Color3.fromRGB(190, 30, 30)
	local white = Color3.fromRGB(235, 235, 230)
	b:box("Bag", V3(0.7, 0.45, 0.3), CF(0, -0.32, 0), bag, M.Fabric)
	b:box("Flap", V3(0.72, 0.18, 0.31), CF(0, -0.12, 0), Builder.shade(bag, 0.9), M.Fabric)
	for i, z in { -0.155, 0.155 } do
		b:box(`CrossBg{i}`, V3(0.24, 0.24, 0.01), CF(0, -0.34, z), white, M.Plastic)
		b:box(`CrossV{i}`, V3(0.06, 0.18, 0.012), CF(0, -0.34, z), red, M.Plastic)
		b:box(`CrossH{i}`, V3(0.18, 0.06, 0.012), CF(0, -0.34, z), red, M.Plastic)
	end
	b:box("StrapL", V3(0.05, 0.25, 0.05), CF(-0.2, 0.02, 0) * ANG(0, 0, -0.5), Builder.shade(bag, 0.7), M.Fabric)
	b:box("StrapR", V3(0.05, 0.25, 0.05), CF(0.2, 0.02, 0) * ANG(0, 0, 0.5), Builder.shade(bag, 0.7), M.Fabric)
	b:box("StrapTop", V3(0.22, 0.05, 0.05), CF(0, 0.12, 0), Builder.shade(bag, 0.7), M.Fabric)
	b:standard(V3(0, -0.3, -0.2), V3(0, 0.1, 0), V3(-0.36, -0.3, 0), V3(0, 0.2, 0.4), V3(0, 0, 0))
	b:meta("Gadget", 1.0, V3(0, -1, 0), "none")
end

function Gadgets.AmmoBox(b: B)
	local p = b.p
	local crate = p.wood
	b:box("Crate", V3(0.85, 0.45, 0.42), CF(0, -0.05, 0), crate, M.Wood)
	b:box("Lid", V3(0.87, 0.06, 0.44), CF(0, 0.2, 0), Builder.shade(crate, 0.85), M.Wood)
	b:box("BandL", V3(0.04, 0.47, 0.44), CF(-0.3, -0.04, 0), Builder.shade(crate, 0.7), M.Wood)
	b:box("BandR", V3(0.04, 0.47, 0.44), CF(0.3, -0.04, 0), Builder.shade(crate, 0.7), M.Wood)
	b:box("Stencil", V3(0.4, 0.08, 0.005), CF(0, 0.0, -0.212), Color3.fromRGB(220, 200, 90), M.Plastic)
	b:box("HandleL", V3(0.04, 0.05, 0.22), CF(-0.45, 0.05, 0), p.metal, M.Metal)
	b:box("HandleR", V3(0.04, 0.05, 0.22), CF(0.45, 0.05, 0), p.metal, M.Metal)
	b:box("Latch", V3(0.08, 0.1, 0.03), CF(0, 0.14, -0.225), p.metal, M.Metal)
	b:standard(V3(0, 0, -0.3), V3(0.46, 0.0, 0), V3(-0.46, 0.0, 0), V3(0, 0.2, 0.4), V3(0, 0, 0))
	b:meta("Gadget", 1.0, V3(0, -1, 0), "none")
end

function Gadgets.Binoculars(b: B)
	local p = b.p
	local body = Color3.fromRGB(32, 32, 34)
	local trim = p.accent
	for i, x in { -0.13, 0.13 } do
		b:cylZ(`Barrel{i}`, 0.42, 0.18, CF(x, 0, -0.05), body, M.Leather)
		b:cylZ(`Objective{i}`, 0.07, 0.21, CF(x, 0, -0.27), trim, M.Metal)
		b:cylZ(`Lens{i}`, 0.01, 0.16, CF(x, 0, -0.31), Color3.fromRGB(70, 100, 130), Enum.Material.Glass)
		b:cylZ(`Eyepiece{i}`, 0.12, 0.12, CF(x, 0, 0.2), body, M.Plastic)
	end
	b:box("Bridge", V3(0.12, 0.08, 0.32), CF(0, 0.02, -0.02), trim, M.Metal)
	b:cylX("FocusWheel", 0.08, 0.1, CF(0, 0.07, 0.08), trim, M.Metal)
	b:box("Strap", V3(0.3, 0.02, 0.04), CF(0, -0.11, 0.1), Color3.fromRGB(70, 50, 34), M.Leather)
	b:standard(V3(0, 0, -0.32), V3(0.18, -0.1, 0.0), V3(-0.18, -0.1, 0.0), V3(0, 0, 0.27), V3(0, 0, 0))
	b:meta("Binoculars", 0.08, V3(0, -1, 0), "none")
end

return Gadgets
