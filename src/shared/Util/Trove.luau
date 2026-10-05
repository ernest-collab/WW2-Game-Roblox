--[[
	Trove: collects cleanup tasks (connections, instances, functions, threads) and cleans them all at once.
	Use one per equipped weapon / vehicle session / UI screen to avoid leaks.

		local trove = Trove.new()
		trove:Add(part.Touched:Connect(...))
		trove:Add(someInstance)
		trove:Add(function() ... end)
		trove:Clean()
]]

local Trove = {}
Trove.__index = Trove

export type Trove = typeof(setmetatable({} :: { _items: { any } }, Trove))

function Trove.new(): Trove
	return setmetatable({ _items = {} }, Trove)
end

function Trove:Add<T>(item: T): T
	table.insert(self._items, item)
	return item
end

function Trove:Connect(signal: any, fn: (...any) -> ())
	return self:Add(signal:Connect(fn))
end

local function cleanItem(item: any)
	local t = typeof(item)
	if t == "RBXScriptConnection" then
		item:Disconnect()
	elseif t == "Instance" then
		item:Destroy()
	elseif t == "function" then
		item()
	elseif t == "thread" then
		pcall(task.cancel, item)
	elseif t == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		elseif type(item.Clean) == "function" then
			item:Clean()
		end
	end
end

function Trove:Clean()
	local items = self._items
	self._items = {}
	for i = #items, 1, -1 do
		cleanItem(items[i])
	end
end

Trove.Destroy = Trove.Clean

return Trove
