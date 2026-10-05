--[[
	Client bootstrap. Same lifecycle as the server: requires every ModuleScript in ./Controllers,
	calls :Init() on all (alphabetical), then :Start() on all (each in its own thread).
	UI modules live in ./UI and are required by the controllers/UI root that own them.

	Rule: controllers must NOT require sibling controllers at module top level. Require them
	inside Init/Start or inside functions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
ReplicatedStorage:WaitForChild("Shared")
ReplicatedStorage:WaitForChild("Remotes")
ReplicatedStorage:WaitForChild("GameState")

local controllersFolder = script:WaitForChild("Controllers")
local modules = {}
for _, child in controllersFolder:GetChildren() do
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
		warn(`[Client] failed to load {m.Name}: {result}`)
	end
end

for _, entry in loaded do
	if type(entry.mod) == "table" and type(entry.mod.Init) == "function" then
		local ok, err = pcall(entry.mod.Init, entry.mod)
		if not ok then
			warn(`[Client] {entry.name}:Init failed: {err}`)
		end
	end
end

for _, entry in loaded do
	if type(entry.mod) == "table" and type(entry.mod.Start) == "function" then
		task.spawn(function()
			local ok, err = pcall(entry.mod.Start, entry.mod)
			if not ok then
				warn(`[Client] {entry.name}:Start failed: {err}`)
			end
		end)
	end
end
