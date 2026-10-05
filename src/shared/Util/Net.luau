--[[
	Net: remotes created on demand by name.
	  * Server: Net.event(name) creates (or returns) ReplicatedStorage.Remotes[name].
	  * Client: Net.event(name) waits for it (server creates every remote it uses during Init).

	Naming: "<Area>_<Action>", e.g. "Combat_Fire", "Spawn_Request". See docs/ARCHITECTURE.md.

		-- server
		Net.event("Combat_Kill"):FireAllClients(payload)
		Net.event("Spawn_Request").OnServerEvent:Connect(function(player, payload) end)
		-- client
		Net.event("Combat_Kill").OnClientEvent:Connect(function(payload) end)

	Net.rateLimit(player, key, maxPerSecond) -> boolean  (server-side flood guard)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local Net = {}

local function resolveFolder(): Folder
	if IS_SERVER then
		local existing = ReplicatedStorage:FindFirstChild("Remotes")
		if existing then
			return existing :: Folder
		end
		local created = Instance.new("Folder")
		created.Name = "Remotes"
		created.Parent = ReplicatedStorage
		return created
	end
	return ReplicatedStorage:WaitForChild("Remotes") :: Folder
end
local folder: Folder = resolveFolder()

local function getOrCreate(name: string, className: string): Instance
	local existing = folder:FindFirstChild(name)
	if existing then
		return existing
	end
	if IS_SERVER then
		local r = Instance.new(className)
		r.Name = name
		r.Parent = folder
		return r
	end
	local r = folder:WaitForChild(name, 30)
	if not r then
		warn(`[Net] remote '{name}' was not created by the server within 30s`)
		r = folder:WaitForChild(name)
	end
	return r :: Instance
end

function Net.event(name: string): RemoteEvent
	return getOrCreate(name, "RemoteEvent") :: RemoteEvent
end

-- For high-frequency, loss-tolerant data (aim pitch, cosmetic FX).
function Net.unreliable(name: string): UnreliableRemoteEvent
	return getOrCreate(name, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
end

function Net.func(name: string): RemoteFunction
	return getOrCreate(name, "RemoteFunction") :: RemoteFunction
end

-- Token-bucket rate limiter, server-side.
local buckets: { [Player]: { [string]: { tokens: number, last: number } } } = {}

function Net.rateLimit(player: Player, key: string, maxPerSecond: number): boolean
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local now = os.clock()
	local b = perPlayer[key]
	if not b then
		b = { tokens = maxPerSecond, last = now }
		perPlayer[key] = b
	end
	b.tokens = math.min(maxPerSecond, b.tokens + (now - b.last) * maxPerSecond)
	b.last = now
	if b.tokens >= 1 then
		b.tokens -= 1
		return true
	end
	return false
end

if IS_SERVER then
	game:GetService("Players").PlayerRemoving:Connect(function(p)
		buckets[p] = nil
	end)
end

return Net
