--[[
	TeamService (Gameplay team)

	* Creates the Roblox Teams "Allies" / "Axis" (AutoAssignable = false).
	* Auto-balances players into a side on join; keeps sides balanced when players leave
	  (moves a dead player of the larger side mid-round, rebalances everyone between rounds).
	* Handles `Team_Request {side = "Allies"|"Axis"|"Auto"}` with balance limits. Switching sides is only
	  allowed while dead/undeployed or outside of the InRound phase.
	* Writes player attributes `Side` and `Faction` (faction follows GameState AlliesFaction/AxisFaction).
	* Fires Bus `PlayerSideChanged(player, newSide, oldSide)` (contract addition).

	Public API
	  TeamService.GetSide(player) -> "Allies" | "Axis" | ""
	  TeamService.GetPlayers(side) -> {Player}
	  TeamService.GetCounts() -> (alliesCount, axisCount)
	  TeamService.SetSide(player, side, force?) -> boolean
	  TeamService.Rebalance()            -- between rounds (RoundService)
	  TeamService.ApplyFactions()        -- re-read GameState factions onto every player
	  TeamService.Enemy(side) -> string
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local GameState = require(Shared.GameState)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)

local TeamService = {}

local SIDES = { "Allies", "Axis" }
local MAX_IMBALANCE = 1 -- a voluntary switch may never leave the target side more than this ahead

local teamObjects: { [string]: Team } = {}
local joinOrder: { [Player]: number } = {}
local joinCounter = 0

local function notify(player: Player, text: string, kind: string?)
	Net.event("Notify"):FireClient(player, { text = text, kind = kind or "info", duration = 4 })
end

function TeamService.Enemy(side: string): string
	if side == "Allies" then
		return "Axis"
	elseif side == "Axis" then
		return "Allies"
	end
	return ""
end

function TeamService.GetSide(player: Player): string
	local side = player:GetAttribute("Side")
	return if type(side) == "string" then side else ""
end

function TeamService.GetPlayers(side: string): { Player }
	local list = {}
	for _, p in Players:GetPlayers() do
		if p:GetAttribute("Side") == side then
			table.insert(list, p)
		end
	end
	return list
end

function TeamService.GetCounts(): (number, number)
	local a, x = 0, 0
	for _, p in Players:GetPlayers() do
		local side = p:GetAttribute("Side")
		if side == "Allies" then
			a += 1
		elseif side == "Axis" then
			x += 1
		end
	end
	return a, x
end

local function factionFor(side: string): string
	if side == "Allies" then
		return GameState.get("AlliesFaction") or "US"
	elseif side == "Axis" then
		return GameState.get("AxisFaction") or "DE"
	end
	return ""
end

local function isDeployed(player: Player): boolean
	return player:GetAttribute("Alive") == true
end

-- Smaller side first; ties broken randomly.
local function smallerSide(exclude: Player?): string
	local a, x = 0, 0
	for _, p in Players:GetPlayers() do
		if p ~= exclude then
			local side = p:GetAttribute("Side")
			if side == "Allies" then
				a += 1
			elseif side == "Axis" then
				x += 1
			end
		end
	end
	if a < x then
		return "Allies"
	elseif x < a then
		return "Axis"
	end
	return SIDES[math.random(1, 2)]
end

-- Assigns a side (no validation unless the caller did it). Returns true if it changed.
function TeamService.SetSide(player: Player, side: string, force: boolean?): boolean
	if side ~= "Allies" and side ~= "Axis" and side ~= "" then
		return false
	end
	local old = TeamService.GetSide(player)
	if old == side and not force then
		return false
	end
	player:SetAttribute("Side", side)
	player:SetAttribute("Faction", factionFor(side))
	local team = teamObjects[side]
	if team then
		player.Neutral = false
		player.Team = team
	else
		(player :: any).Team = nil
		player.Neutral = true
	end
	if old ~= side then
		Bus.fire("PlayerSideChanged", player, side, old)
	end
	return old ~= side
end

function TeamService.ApplyFactions()
	for _, p in Players:GetPlayers() do
		local side = TeamService.GetSide(p)
		if side ~= "" then
			p:SetAttribute("Faction", factionFor(side))
		end
	end
end

-- Between rounds: move players (lowest score, latest joiners first) until sides differ by <= 1.
function TeamService.Rebalance()
	for _ = 1, Constants.MAX_PLAYERS do
		local a, x = TeamService.GetCounts()
		if math.abs(a - x) <= MAX_IMBALANCE then
			return
		end
		local from = if a > x then "Allies" else "Axis"
		local candidates = TeamService.GetPlayers(from)
		table.sort(candidates, function(p1, p2)
			local s1, s2 = p1:GetAttribute("Score") or 0, p2:GetAttribute("Score") or 0
			if s1 ~= s2 then
				return s1 < s2
			end
			return (joinOrder[p1] or 0) > (joinOrder[p2] or 0)
		end)
		local mover = candidates[1]
		if not mover then
			return
		end
		TeamService.SetSide(mover, TeamService.Enemy(from))
		notify(mover, `Auto-balance: you have been moved to the {TeamService.Enemy(from)}.`, "warning")
	end
end

-- Mid-round: only move players that are not deployed (dead / on the deploy screen).
local function rebalanceDeadOnly()
	local a, x = TeamService.GetCounts()
	if math.abs(a - x) <= MAX_IMBALANCE + 1 then
		return
	end
	local from = if a > x then "Allies" else "Axis"
	local best: Player? = nil
	for _, p in TeamService.GetPlayers(from) do
		if not isDeployed(p) then
			if not best or (joinOrder[p] or 0) > (joinOrder[best] or 0) then
				best = p
			end
		end
	end
	if best then
		TeamService.SetSide(best, TeamService.Enemy(from))
		notify(best, `Auto-balance: you have been moved to the {TeamService.Enemy(from)}.`, "warning")
	end
end

local function handleTeamRequest(player: Player, payload: any)
	if not Net.rateLimit(player, "Team_Request", 2) then
		return
	end
	if type(payload) ~= "table" then
		return
	end
	local wanted = payload.side
	if wanted ~= "Allies" and wanted ~= "Axis" and wanted ~= "Auto" then
		return
	end
	local current = TeamService.GetSide(player)
	if GameState.get("Phase") == "InRound" and isDeployed(player) then
		notify(player, "You can only switch sides while dead or between rounds.", "warning")
		return
	end
	if wanted == "Auto" then
		wanted = smallerSide(player)
	end
	if wanted == current then
		return
	end
	-- Balance check computed as if the player had already left their current side.
	local counts = { Allies = 0, Axis = 0 }
	for _, p in Players:GetPlayers() do
		local side = p:GetAttribute("Side")
		if p ~= player and (side == "Allies" or side == "Axis") then
			counts[side] += 1
		end
	end
	local after = counts[wanted] + 1
	local other = counts[TeamService.Enemy(wanted)]
	if after - other > MAX_IMBALANCE then
		notify(player, `The {wanted} are full. Teams must stay balanced.`, "warning")
		return
	end
	TeamService.SetSide(player, wanted)
	notify(player, `You joined the {wanted}.`, "info")
end

local function onPlayerAdded(player: Player)
	joinCounter += 1
	joinOrder[player] = joinCounter
	player:SetAttribute("Side", "")
	player:SetAttribute("Faction", "")
	TeamService.SetSide(player, smallerSide(player), true)
end

function TeamService:Init()
	for _, side in SIDES do
		local team = Teams:FindFirstChild(side)
		if not team or not team:IsA("Team") then
			team = Instance.new("Team")
			team.Name = side
			team.Parent = Teams
		end
		local t = team :: Team
		t.AutoAssignable = false
		t.TeamColor = BrickColor.new(Constants.SIDE_COLORS[side])
		teamObjects[side] = t
	end
	-- Guarantee distinct colors even if BrickColor rounding collides.
	if teamObjects.Allies.TeamColor == teamObjects.Axis.TeamColor then
		teamObjects.Allies.TeamColor = BrickColor.new("Bright blue")
		teamObjects.Axis.TeamColor = BrickColor.new("Bright red")
	end
	Net.event("Team_Request")
	Net.event("Notify")
end

function TeamService:Start()
	Net.event("Team_Request").OnServerEvent:Connect(handleTeamRequest)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	Players.PlayerRemoving:Connect(function(player)
		joinOrder[player] = nil
		task.defer(function()
			if GameState.get("Phase") == "InRound" then
				rebalanceDeadOnly()
			end
		end)
	end)

	GameState.changed("AlliesFaction"):Connect(TeamService.ApplyFactions)
	GameState.changed("AxisFaction"):Connect(TeamService.ApplyFactions)
end

return TeamService
