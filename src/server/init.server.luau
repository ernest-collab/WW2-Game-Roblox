--[[
	Server bootstrap. Requires every ModuleScript in ./Services, calls :Init() on all of them
	(synchronously, in alphabetical order; create remotes and state here), then :Start() on all
	of them (each in its own thread; connect events and begin loops here).

	Rule: services must NOT require sibling services at module top level (circular requires
	error in Roblox). Require them inside Init/Start or inside functions.
]]

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local GameState = require(Shared.GameState)

-- Collision groups
local G = Constants.COLLISION_GROUPS
for _, name in { G.Players, G.Vehicles, G.Debris, G.Viewmodel } do
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, name)
end
PhysicsService:CollisionGroupSetCollidable(G.Debris, G.Players, false)
PhysicsService:CollisionGroupSetCollidable(G.Debris, G.Debris, false)
PhysicsService:CollisionGroupSetCollidable(G.Viewmodel, "Default", false)
PhysicsService:CollisionGroupSetCollidable(G.Viewmodel, G.Players, false)
PhysicsService:CollisionGroupSetCollidable(G.Viewmodel, G.Vehicles, false)
PhysicsService:CollisionGroupSetCollidable(G.Viewmodel, G.Debris, false)
PhysicsService:CollisionGroupSetCollidable(G.Viewmodel, G.Viewmodel, false)

GameState.folder() -- create replicated state before any client asks for it

local servicesFolder = script:WaitForChild("Services")
local modules = {}
for _, child in servicesFolder:GetChildren() do
	if child:IsA("ModuleScript") then
		table.insert(modules, child)
	end
end
table.sort(modules, function(a, b)
	return a.Name < b.Name
end)

local loaded = {}
for _, m in modules do
	local ok, result = pcall(require, m)
	if ok then
		table.insert(loaded, { name = m.Name, mod = result })
	else
		warn(`[Server] failed to load {m.Name}: {result}`)
	end
end

for _, entry in loaded do
	if type(entry.mod) == "table" and type(entry.mod.Init) == "function" then
		local ok, err = pcall(entry.mod.Init, entry.mod)
		if not ok then
			warn(`[Server] {entry.name}:Init failed: {err}`)
		end
	end
end

for _, entry in loaded do
	if type(entry.mod) == "table" and type(entry.mod.Start) == "function" then
		task.spawn(function()
			local ok, err = pcall(entry.mod.Start, entry.mod)
			if not ok then
				warn(`[Server] {entry.name}:Start failed: {err}`)
			end
		end)
	end
end

print(`[Server] started {#loaded} services`)
