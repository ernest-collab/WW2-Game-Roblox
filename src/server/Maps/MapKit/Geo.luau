--[[
	MapKit.Geo — pure 2D math used across MapKit (no Instances, no randomness).

	Paths are lists of points. A point may be a Vector3 (Y ignored) or a Vector2 (X, Y = world X, Z).
	`Geo.path(points)` prepares a polyline for fast repeated distance queries.
]]

local Geo = {}

export type Path = {
	n: number,
	x: { number },
	z: { number },
	cum: { number }, -- cumulative length at each vertex
	length: number,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
}

function Geo.xz(p: any): (number, number)
	if typeof(p) == "Vector2" then
		return p.X, p.Y
	end
	return p.X, p.Z
end

function Geo.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function Geo.smoothstep(e0: number, e1: number, x: number): number
	local t = math.clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Fractal noise in roughly [-1, 1].
function Geo.fbm(x: number, z: number, scale: number, octaves: number?, seed: number?): number
	local total, amp, freq, norm = 0, 1, 1 / scale, 0
	local s = (seed or 0) * 17.31
	for _ = 1, octaves or 3 do
		total += math.noise(x * freq + s, z * freq - s, s * 0.37) * amp
		norm += amp
		amp *= 0.5
		freq *= 2
	end
	return math.clamp(total / norm * 2.2, -1, 1)
end

function Geo.path(points: { any }): Path
	local p: Path = {
		n = #points,
		x = {},
		z = {},
		cum = {},
		length = 0,
		minX = math.huge,
		maxX = -math.huge,
		minZ = math.huge,
		maxZ = -math.huge,
	}
	local total = 0
	for i, pt in points do
		local x, z = Geo.xz(pt)
		p.x[i] = x
		p.z[i] = z
		if i > 1 then
			total += math.sqrt((x - p.x[i - 1]) ^ 2 + (z - p.z[i - 1]) ^ 2)
		end
		p.cum[i] = total
		p.minX = math.min(p.minX, x)
		p.maxX = math.max(p.maxX, x)
		p.minZ = math.min(p.minZ, z)
		p.maxZ = math.max(p.maxZ, z)
	end
	p.length = total
	return p
end

--[[
	Distance from (x, z) to the polyline.
	Returns dist, projected x, projected z, distance-along-path of the projection.
]]
function Geo.distToPath(p: Path, x: number, z: number): (number, number, number, number)
	local best, bx, bz, ba = math.huge, p.x[1], p.z[1], 0
	if p.n == 1 then
		return math.sqrt((x - bx) ^ 2 + (z - bz) ^ 2), bx, bz, 0
	end
	for i = 1, p.n - 1 do
		local ax, az, cx, cz = p.x[i], p.z[i], p.x[i + 1], p.z[i + 1]
		-- cheap bbox reject
		local lox, hix = math.min(ax, cx), math.max(ax, cx)
		local loz, hiz = math.min(az, cz), math.max(az, cz)
		local ddx = math.max(lox - x, 0, x - hix)
		local ddz = math.max(loz - z, 0, z - hiz)
		if ddx * ddx + ddz * ddz < best * best then
			local dx, dz = cx - ax, cz - az
			local l2 = dx * dx + dz * dz
			local t = if l2 > 0 then math.clamp(((x - ax) * dx + (z - az) * dz) / l2, 0, 1) else 0
			local px, pz = ax + dx * t, az + dz * t
			local d = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
			if d < best then
				best, bx, bz = d, px, pz
				ba = p.cum[i] + t * math.sqrt(l2)
			end
		end
	end
	return best, bx, bz, ba
end

-- Point and unit direction at distance `d` along the path.
function Geo.sample(p: Path, d: number): (number, number, number, number)
	if p.n == 1 then
		return p.x[1], p.z[1], 0, 1
	end
	d = math.clamp(d, 0, p.length)
	for i = 1, p.n - 1 do
		if d <= p.cum[i + 1] or i == p.n - 1 then
			local segLen = p.cum[i + 1] - p.cum[i]
			local t = if segLen > 0 then (d - p.cum[i]) / segLen else 0
			local dx, dz = p.x[i + 1] - p.x[i], p.z[i + 1] - p.z[i]
			local l = math.max(math.sqrt(dx * dx + dz * dz), 1e-6)
			return p.x[i] + dx * t, p.z[i] + dz * t, dx / l, dz / l
		end
	end
	return p.x[p.n], p.z[p.n], 0, 1
end

-- Is (x, z) inside a rectangle centred at (cx, cz), size (sx, sz), rotated rotDeg about Y?
function Geo.inRect(x: number, z: number, cx: number, cz: number, sx: number, sz: number, rotDeg: number?): boolean
	local dx, dz = x - cx, z - cz
	if rotDeg and rotDeg ~= 0 then
		local r = math.rad(rotDeg)
		local c, s = math.cos(r), math.sin(r)
		-- inverse of CFrame.Angles(0, r, 0): local = R^T * world
		dx, dz = dx * c - dz * s, dx * s + dz * c
	end
	return math.abs(dx) <= sx / 2 and math.abs(dz) <= sz / 2
end

-- Signed distance-ish to the inside of a rotated rect (negative inside), using the same convention.
function Geo.rectDist(x: number, z: number, cx: number, cz: number, sx: number, sz: number, rotDeg: number?): number
	local dx, dz = x - cx, z - cz
	if rotDeg and rotDeg ~= 0 then
		local r = math.rad(rotDeg)
		local c, s = math.cos(r), math.sin(r)
		dx, dz = dx * c - dz * s, dx * s + dz * c
	end
	local qx, qz = math.abs(dx) - sx / 2, math.abs(dz) - sz / 2
	local outside = math.sqrt(math.max(qx, 0) ^ 2 + math.max(qz, 0) ^ 2)
	return outside + math.min(math.max(qx, qz), 0)
end

function Geo.pointInPolygon(x: number, z: number, poly: { any }): boolean
	local inside = false
	local n = #poly
	local jx, jz = Geo.xz(poly[n])
	for i = 1, n do
		local ix, iz = Geo.xz(poly[i])
		if (iz > z) ~= (jz > z) and x < (jx - ix) * (z - iz) / (jz - iz) + ix then
			inside = not inside
		end
		jx, jz = ix, iz
	end
	return inside
end

-- Polyline helpers that return new point lists (Vector3, Y = 0).

-- Inserts sideways zig-zag offsets every `segment` studs (classic WWI/WWII fire-trench traverse).
function Geo.zigzag(points: { any }, amplitude: number, segment: number): { Vector3 }
	local p = Geo.path(points)
	local out = {}
	local count = math.max(1, math.floor(p.length / segment))
	for i = 0, count do
		local d = p.length * i / count
		local x, z, dx, dz = Geo.sample(p, d)
		local side = if i == 0 or i == count then 0 elseif i % 2 == 0 then 1 else -1
		table.insert(out, Vector3.new(x - dz * amplitude * side, 0, z + dx * amplitude * side))
	end
	return out
end

-- Offsets a polyline sideways by `offset` studs (positive = right of travel direction).
function Geo.offsetPath(points: { any }, offset: number): { Vector3 }
	local out = {}
	local n = #points
	for i = 1, n do
		local x, z = Geo.xz(points[i])
		local px, pz = Geo.xz(points[math.max(1, i - 1)])
		local nx, nz = Geo.xz(points[math.min(n, i + 1)])
		local dx, dz = nx - px, nz - pz
		local l = math.max(math.sqrt(dx * dx + dz * dz), 1e-6)
		dx, dz = dx / l, dz / l
		table.insert(out, Vector3.new(x - dz * offset, 0, z + dx * offset))
	end
	return out
end

-- Chaikin smoothing: rounds corners of a polyline (iterations 1..3).
function Geo.smooth(points: { any }, iterations: number?): { Vector3 }
	local pts = {}
	for _, pt in points do
		local x, z = Geo.xz(pt)
		table.insert(pts, Vector3.new(x, 0, z))
	end
	for _ = 1, iterations or 2 do
		local out = { pts[1] }
		for i = 1, #pts - 1 do
			local a, b = pts[i], pts[i + 1]
			table.insert(out, a:Lerp(b, 0.25))
			table.insert(out, a:Lerp(b, 0.75))
		end
		table.insert(out, pts[#pts])
		pts = out
	end
	return pts
end

return Geo
