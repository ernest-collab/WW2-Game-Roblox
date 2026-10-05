--[[
	Reusable weapon sub-assemblies shared by the archetype builders.
]]

local Builder = require(script.Parent.Builder)

type B = Builder.Builder

local M = Builder.Mat
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local Parts = {}

--[[
	Adds a magazine named "Mag" (animated by the viewmodel reload) and returns the handle-space
	direction it is pulled out along.
	  kind:   "box" | "stick" | "curved" | "drum" | "side" | "top" | "pan" | "internal" | "none"
	  anchor: CFrame of the magazine well opening (handle space)
	  size:   overall magazine length scale (studs)
]]
function Parts.magazine(b: B, kind: string, anchor: CFrame, size: number?): Vector3
	local p = b.p
	local s = size or 0.45
	local col = p.dark
	if kind == "stick" then
		b:box("Mag", V3(0.09, s * 1.15, 0.12), anchor * CF(0, -s * 0.575, 0), col, M.Metal)
		return V3(0, -1, 0)
	elseif kind == "curved" then
		local seg = s * 0.55
		local mag = b:box("Mag", V3(0.09, seg, 0.15), anchor * ANG(0.12, 0, 0) * CF(0, -seg / 2, 0), col, M.Metal)
		b:box(
			"MagLower",
			V3(0.09, seg, 0.15),
			anchor * ANG(0.12, 0, 0) * CF(0, -seg, 0) * ANG(0.35, 0, 0) * CF(0, -seg / 2 + 0.02, 0),
			col,
			M.Metal,
			mag
		)
		return V3(0, -1, -0.3).Unit
	elseif kind == "drum" then
		local mag = b:cylX("Mag", 0.15, s * 1.05, anchor * CF(0, -s * 0.45, 0), col, M.Metal)
		b:cylX("DrumCap", 0.16, s * 0.35, anchor * CF(0, -s * 0.45, 0), p.metal, M.Metal, mag)
		return V3(0, -1, 0)
	elseif kind == "side" then
		b:box("MagWell", V3(0.14, 0.15, 0.16), anchor * CF(-0.1, 0, 0), p.metal, M.Metal)
		b:box("Mag", V3(s * 1.1, 0.085, 0.12), anchor * CF(-0.17 - s * 0.55, 0, 0), col, M.Metal)
		return V3(-1, 0, 0)
	elseif kind == "top" then
		local seg = s * 0.5
		local mag = b:box("Mag", V3(0.09, seg, 0.17), anchor * ANG(-0.15, 0, 0) * CF(0, seg / 2, 0), col, M.Metal)
		b:box(
			"MagUpper",
			V3(0.09, seg, 0.17),
			anchor * ANG(-0.15, 0, 0) * CF(0, seg, 0) * ANG(-0.35, 0, 0) * CF(0, seg / 2 - 0.02, 0),
			col,
			M.Metal,
			mag
		)
		return V3(0, 1, 0)
	elseif kind == "pan" then
		local mag = b:cylY("Mag", 0.1, s * 1.5, anchor * CF(0, 0.05, 0), col, M.Metal)
		b:cylY("PanCap", 0.12, s * 0.4, anchor * CF(0, 0.06, 0), p.metal, M.Metal, mag)
		return V3(0, 1, 0)
	elseif kind == "internal" or kind == "none" then
		b:box("Mag", V3(0.1, 0.04, 0.3), anchor * CF(0, -0.02, 0), p.metal, M.Metal)
		return V3(0, -1, 0)
	end
	-- "box" (default): straight box magazine
	b:box("Mag", V3(0.1, s, 0.16), anchor * CF(0, -s / 2, 0), col, M.Metal)
	return V3(0, -1, 0)
end

-- Folded-down bipod: two splayed legs hanging from a clamp at `at` (handle space).
function Parts.bipod(b: B, at: CFrame, legLen: number, deployed: boolean?)
	local p = b.p
	b:box("BipodClamp", V3(0.12, 0.06, 0.08), at, p.dark, M.Metal)
	for i, side in { -1, 1 } do
		local leg
		if deployed then
			leg = at * ANG(0, 0, side * 0.35) * CF(0, -legLen / 2, 0)
		else
			-- folded back under the barrel, slightly splayed
			leg = at * ANG(-1.35, 0, side * 0.12) * CF(0, -legLen / 2, 0)
		end
		b:box(`BipodLeg{i}`, V3(0.035, legLen, 0.035), leg, p.dark, M.Metal)
	end
end

-- Barrel jacket with dark cooling slots along both sides.
function Parts.perforatedJacket(b: B, center: CFrame, length: number, width: number, round: boolean, slots: number)
	local p = b.p
	if round then
		b:cylZ("Jacket", length, width, center, p.metal, M.Metal)
	else
		b:box("Jacket", V3(width, width, length), center, p.metal, M.Metal)
	end
	local hole = Color3.fromRGB(16, 16, 16)
	local spacing = length / (slots + 1)
	for i = 1, slots do
		local z = -length / 2 + spacing * i
		b:box(`JacketSlot{i}`, V3(width + 0.01, width * 0.42, spacing * 0.55), center * CF(0, 0, z), hole, M.Metal)
	end
end

return Parts
