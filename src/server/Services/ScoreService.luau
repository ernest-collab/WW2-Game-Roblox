--[[
	ScoreService (Gameplay team)

	Maintains per-round player stats and awards score (+ equal XP through ProgressionService).

	Player attributes: Kills, Deaths, Assists, Score, Captures (reset every round).
	Roblox leaderstats: Score, Kills, Deaths (IntValues).

	Listens to (server Bus):
	  PlayerKilled(victim, killer, weaponId, headshot)  -> kill / headshot / assists / weapon kill stats
	  PlayerDied(victim, killer?, weaponId?)            -> deaths (fired by SpawnService for EVERY death,
	                                                        incl. falls / out-of-bounds; contract addition)
	  PlayerDamaged(victim, attacker, amount, weaponId)  -> damage log used to compute assists
	  ObjectiveCaptured(id, side, capturers)            -> Captures + "Objective Captured"
	  VehicleDestroyed(vehicle, killer)                 -> "Vehicle Destroyed"
	Assists are computed here (>= ASSIST_MIN_DAMAGE within ASSIST_WINDOW seconds before the kill);
	CombatService does not need to fire any assist event.

	Public API
	  ScoreService.Award(player, reason, points)   -- Score attr + leaderstats + Score_Event + XP + Bus ScoreAwarded
	  ScoreService.AddStat(player, stat, delta)    -- "Kills" | "Deaths" | "Assists" | "Captures"
	  ScoreService.ResetRound()                    -- zero round stats for everyone
	  ScoreService.GetTopPlayers(n) -> {{player, name, side, score, kills, deaths, userId}}
	  ScoreService.POINTS                          -- = Config/Progression.SCORE
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Progression = require(Shared.Config.Progression)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)

local ScoreService = {}

ScoreService.POINTS = Progression.SCORE

local STATS = { "Kills", "Deaths", "Assists", "Score", "Captures" }
local LEADERSTATS = { "Score", "Kills", "Deaths" }
local ASSIST_MIN_DAMAGE = 20
local ASSIST_WINDOW = 20

-- damageLog[victim][attacker] = {amount, last}
local damageLog: { [Player]: { [Player]: { amount: number, last: number } } } = {}

local serviceCache: { [string]: any } = {}
local function getService(name: string): any
	local cached = serviceCache[name]
	if cached then
		return cached
	end
	local module = script.Parent:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		serviceCache[name] = result
		return result
	end
	return nil
end

local function isPlayer(v: any): boolean
	return typeof(v) == "Instance" and v:IsA("Player") and v.Parent ~= nil
end

local function sideOf(player: Player): string
	local s = player:GetAttribute("Side")
	return if type(s) == "string" then s else ""
end

local function areEnemies(a: Player, b: Player): boolean
	local sa, sb = sideOf(a), sideOf(b)
	return sa ~= "" and sb ~= "" and sa ~= sb
end

local function setLeaderstat(player: Player, stat: string, value: number)
	local folder = player:FindFirstChild("leaderstats")
	local v = folder and folder:FindFirstChild(stat)
	if v and v:IsA("IntValue") then
		v.Value = math.floor(value)
	end
end

local function setStat(player: Player, stat: string, value: number)
	player:SetAttribute(stat, value)
	if table.find(LEADERSTATS, stat) then
		setLeaderstat(player, stat, value)
	end
end

function ScoreService.AddStat(player: Player, stat: string, delta: number)
	if not isPlayer(player) or not table.find(STATS, stat) then
		return
	end
	local current = player:GetAttribute(stat)
	setStat(player, stat, (if type(current) == "number" then current else 0) + delta)
end

function ScoreService.Award(player: Player, reason: string, points: number)
	if not isPlayer(player) or type(reason) ~= "string" or type(points) ~= "number" or points ~= points then
		return
	end
	points = math.floor(points)
	if points == 0 then
		return
	end
	ScoreService.AddStat(player, "Score", points)
	Net.event("Score_Event"):FireClient(player, { reason = reason, points = points })
	if points > 0 then
		local progression = getService("ProgressionService")
		if progression and progression.AddXP then
			pcall(progression.AddXP, player, points, reason)
		end
	end
	Bus.fire("ScoreAwarded", player, reason, points)
end

function ScoreService.ResetRound()
	for _, p in Players:GetPlayers() do
		for _, stat in STATS do
			setStat(p, stat, 0)
		end
	end
	table.clear(damageLog)
end

function ScoreService.GetTopPlayers(n: number?)
	local list = {}
	for _, p in Players:GetPlayers() do
		if sideOf(p) ~= "" then
			table.insert(list, {
				player = p,
				name = p.DisplayName,
				userId = p.UserId,
				side = sideOf(p),
				score = p:GetAttribute("Score") or 0,
				kills = p:GetAttribute("Kills") or 0,
				deaths = p:GetAttribute("Deaths") or 0,
			})
		end
	end
	table.sort(list, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		if a.kills ~= b.kills then
			return a.kills > b.kills
		end
		return a.deaths < b.deaths
	end)
	if n and #list > n then
		local trimmed = {}
		for i = 1, n do
			trimmed[i] = list[i]
		end
		return trimmed
	end
	return list
end

---------------------------------------------------------------------------------------------------
-- Event handlers
---------------------------------------------------------------------------------------------------

local function onPlayerDamaged(victim: any, attacker: any, amount: any)
	if not isPlayer(victim) or not isPlayer(attacker) or victim == attacker or type(amount) ~= "number" then
		return
	end
	local log = damageLog[victim]
	if not log then
		log = {}
		damageLog[victim] = log
	end
	local entry = log[attacker]
	local now = os.clock()
	if not entry or now - entry.last > ASSIST_WINDOW then
		entry = { amount = 0, last = now }
		log[attacker] = entry
	end
	entry.amount += math.max(0, amount)
	entry.last = now
end

local function onPlayerKilled(victim: any, killer: any, weaponId: any, headshot: any)
	if not isPlayer(victim) then
		return
	end
	local log = damageLog[victim]
	damageLog[victim] = nil

	if isPlayer(killer) and killer ~= victim and areEnemies(killer, victim) then
		ScoreService.AddStat(killer, "Kills", 1)
		ScoreService.Award(killer, "Enemy Killed", Progression.SCORE.Kill)
		if headshot == true then
			ScoreService.Award(killer, "Headshot", Progression.SCORE.Headshot)
		end
		local progression = getService("ProgressionService")
		if progression and progression.RecordWeaponKill and type(weaponId) == "string" then
			pcall(progression.RecordWeaponKill, killer, weaponId)
		end
	end

	-- Assists: enemies of the victim (other than the killer) who dealt enough recent damage.
	if log then
		local now = os.clock()
		for attacker, entry in log do
			if
				attacker ~= killer
				and isPlayer(attacker)
				and areEnemies(attacker, victim)
				and entry.amount >= ASSIST_MIN_DAMAGE
				and now - entry.last <= ASSIST_WINDOW
			then
				ScoreService.AddStat(attacker, "Assists", 1)
				ScoreService.Award(attacker, "Kill Assist", Progression.SCORE.Assist)
			end
		end
	end
end

local function onPlayerDied(victim: any)
	if not isPlayer(victim) then
		return
	end
	ScoreService.AddStat(victim, "Deaths", 1)
	local progression = getService("ProgressionService")
	if progression and progression.RecordDeath then
		pcall(progression.RecordDeath, victim)
	end
end

local function onObjectiveCaptured(_objectiveId: any, side: any, capturers: any)
	if type(capturers) ~= "table" then
		return
	end
	for _, p in capturers do
		if isPlayer(p) and sideOf(p) == side then
			ScoreService.AddStat(p, "Captures", 1)
			ScoreService.Award(p, "Objective Captured", Progression.SCORE.Capture)
		end
	end
end

local function onVehicleDestroyed(vehicle: any, killer: any)
	if not isPlayer(killer) then
		return
	end
	local vehicleSide = if typeof(vehicle) == "Instance" then vehicle:GetAttribute("Side") else nil
	if vehicleSide == sideOf(killer) then
		return -- no points for destroying friendly / own vehicles
	end
	ScoreService.Award(killer, "Vehicle Destroyed", Progression.SCORE.VehicleDestroyed)
end

local function onPlayerAdded(player: Player)
	for _, stat in STATS do
		if player:GetAttribute(stat) == nil then
			player:SetAttribute(stat, 0)
		end
	end
	if not player:FindFirstChild("leaderstats") then
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		for _, stat in LEADERSTATS do
			local v = Instance.new("IntValue")
			v.Name = stat
			v.Value = player:GetAttribute(stat) or 0
			v.Parent = folder
		end
		folder.Parent = player
	end
end

function ScoreService:Init()
	Net.event("Score_Event")
end

function ScoreService:Start()
	Bus.connect("PlayerDamaged", onPlayerDamaged)
	Bus.connect("PlayerKilled", onPlayerKilled)
	Bus.connect("PlayerDied", onPlayerDied)
	Bus.connect("ObjectiveCaptured", onObjectiveCaptured)
	Bus.connect("VehicleDestroyed", onVehicleDestroyed)
	Bus.connect("PlayerSpawned", function(player)
		damageLog[player] = nil
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	Players.PlayerRemoving:Connect(function(player)
		damageLog[player] = nil
		for _, log in damageLog do
			log[player] = nil
		end
	end)
end

return ScoreService
