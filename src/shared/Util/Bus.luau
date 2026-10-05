--[[
	Bus: lazily-created, named in-process signals for decoupled communication between
	services (on the server) or controllers (on the client). Each Luau VM gets its own
	Bus, so server and client buses are independent.

		Bus.get("PlayerKilled"):Connect(function(victim, killer, weaponId, headshot) end)
		Bus.fire("PlayerKilled", victim, killer, weaponId, headshot)

	The canonical event names and payloads are documented in docs/ARCHITECTURE.md.
]]

local Signal = require(script.Parent.Signal)

local Bus = {}
local signals: { [string]: Signal.Signal } = {}

function Bus.get(name: string): Signal.Signal
	local s = signals[name]
	if not s then
		s = Signal.new()
		signals[name] = s
	end
	return s
end

function Bus.fire(name: string, ...: any)
	Bus.get(name):Fire(...)
end

function Bus.connect(name: string, fn: (...any) -> ())
	return Bus.get(name):Connect(fn)
end

return Bus
