--[[
	Signal: lightweight pure-Luau signal (no BindableEvent overhead, no value copying).

		local s = Signal.new()
		local conn = s:Connect(function(a, b) end)
		s:Fire(1, 2)
		conn:Disconnect()
]]

export type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }
export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	Once: (self: Signal, fn: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	DisconnectAll: (self: Signal) -> (),
}

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local handlers = self._signal._handlers
	local idx = table.find(handlers, self)
	if idx then
		table.remove(handlers, idx)
	end
end

function Signal.new(): Signal
	return setmetatable({ _handlers = {} }, Signal) :: any
end

function Signal:Connect(fn)
	local conn = setmetatable({ Connected = true, _signal = self, _fn = fn }, Connection)
	table.insert(self._handlers, conn)
	return conn
end

function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Fire(...)
	-- Snapshot so handlers may disconnect during dispatch.
	local snapshot = table.clone(self._handlers)
	for _, conn in snapshot do
		if conn.Connected then
			task.spawn(conn._fn, ...)
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	for _, conn in table.clone(self._handlers) do
		conn:Disconnect()
	end
end

return Signal
