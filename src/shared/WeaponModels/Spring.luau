--[[
	Spring: analytic damped harmonic spring (Animation/Models team utility).

	Works on numbers and Vector3 (any type supporting +, -, * number). The update is the exact
	closed-form solution of a damped spring, so it is frame-rate independent and never explodes
	at low FPS (unlike naive Euler integration).

		local s = Spring.new(Vector3.zero, 18, 0.75) -- (initial, angular frequency, damping ratio)
		s.Target = Vector3.new(1, 0, 0)
		s:Impulse(Vector3.new(0, 4, 0))
		local pos = s:Update(dt)

	Damping >= 1 is treated as critically damped.
]]

local Spring = {}
Spring.__index = Spring

export type Spring<T> = {
	Position: T,
	Velocity: T,
	Target: T,
	Speed: number,
	Damping: number,
	Update: (self: Spring<T>, dt: number) -> T,
	Impulse: (self: Spring<T>, velocity: T) -> (),
	Reset: (self: Spring<T>, value: T) -> (),
}

function Spring.new<T>(initial: T, speed: number?, damping: number?): Spring<T>
	local zero = (initial :: any) * 0
	local self = setmetatable({
		Position = initial,
		Velocity = zero,
		Target = initial,
		Speed = speed or 12,
		Damping = damping or 0.8,
	}, Spring)
	return self :: any
end

function Spring:Impulse(velocity)
	self.Velocity += velocity
end

function Spring:Reset(value)
	self.Position = value
	self.Target = value
	self.Velocity = value * 0
end

function Spring:Update(dt: number)
	if dt <= 0 then
		return self.Position
	end
	local w = self.Speed
	local z = math.min(self.Damping, 1)
	local x0 = self.Position - self.Target
	local v0 = self.Velocity
	local e = math.exp(-z * w * dt)
	local x, v
	if z >= 0.9999 then
		-- critically damped
		local b = v0 + x0 * w
		x = (x0 + b * dt) * e
		v = (v0 - b * (w * dt)) * e
	else
		local wd = w * math.sqrt(1 - z * z)
		local c, s = math.cos(wd * dt), math.sin(wd * dt)
		local b = (v0 + x0 * (z * w)) / wd
		x = (x0 * c + b * s) * e
		v = (v0 * c - (b * (z * w) + x0 * wd) * s) * e
	end
	self.Position = self.Target + x
	self.Velocity = v
	return self.Position
end

return Spring
