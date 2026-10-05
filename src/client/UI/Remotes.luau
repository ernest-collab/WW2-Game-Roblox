--[[
	Remotes: defensive client-side access to ReplicatedStorage.Remotes for the UI.

	Unlike Net.event (which waits forever for a remote), these helpers never block the caller and
	tolerate a subsystem that is missing or failed to load, so the UI keeps working on its own.

	  Remotes.onEvent(name, fn, trove?)      -- connects when (if) the remote appears
	  Remotes.fire(name, payload)           -- fires if the remote exists, otherwise no-op (+warn once)
	  Remotes.invoke(name, timeout, ...)    -- (ok, result) with a timeout; never yields forever
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = {}

local WAIT_TIMEOUT = 60
local warned: { [string]: boolean } = {}

local function folder(): Instance?
	return ReplicatedStorage:FindFirstChild("Remotes")
end

-- Returns the remote if it exists right now.
function Remotes.find(name: string): Instance?
	local f = folder()
	return f and f:FindFirstChild(name) or nil
end

-- Yields up to `timeout` seconds for a remote. Never yields forever.
function Remotes.wait(name: string, timeout: number?): Instance?
	local f = folder() or ReplicatedStorage:WaitForChild("Remotes", timeout or WAIT_TIMEOUT)
	if not f then
		return nil
	end
	return f:FindFirstChild(name) or f:WaitForChild(name, timeout or WAIT_TIMEOUT)
end

--[[
	Connects `fn` to RemoteEvent/UnreliableRemoteEvent `name`.OnClientEvent as soon as the remote
	exists. Returns nothing; the connection is added to `trove` when given.
]]
function Remotes.onEvent(name: string, fn: (...any) -> (), trove: any?)
	local thread = task.spawn(function()
		local remote = Remotes.wait(name)
		if not remote then
			return
		end
		if remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent") then
			local conn = (remote :: any).OnClientEvent:Connect(function(...)
				local ok, err = pcall(fn, ...)
				if not ok then
					warn(`[UI] handler for {name} failed: {err}`)
				end
			end)
			if trove then
				trove:Add(conn)
			end
		end
	end)
	if trove then
		trove:Add(thread)
	end
end

function Remotes.fire(name: string, ...: any): boolean
	local remote = Remotes.find(name)
	if remote and remote:IsA("RemoteEvent") then
		remote:FireServer(...)
		return true
	end
	if not warned[name] then
		warned[name] = true
		warn(`[UI] remote '{name}' is not available`)
	end
	return false
end

--[[
	Invokes RemoteFunction `name` with a timeout. Returns (true, result) or (false, errorString).
	The invoke thread itself may linger if the server never answers, but the caller resumes.
]]
function Remotes.invoke(name: string, timeout: number, ...: any): (boolean, any)
	local remote = Remotes.wait(name, math.min(timeout, 10))
	if not remote or not remote:IsA("RemoteFunction") then
		return false, "missing remote " .. name
	end
	local caller = coroutine.running()
	local done = false
	local args = table.pack(...)
	task.spawn(function()
		local ok, result = pcall(function()
			return (remote :: RemoteFunction):InvokeServer(table.unpack(args, 1, args.n))
		end)
		if not done then
			done = true
			task.spawn(caller, ok, result)
		end
	end)
	task.delay(timeout, function()
		if not done then
			done = true
			task.spawn(caller, false, "timeout")
		end
	end)
	return coroutine.yield()
end

return Remotes
