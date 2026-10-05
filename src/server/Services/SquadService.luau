--[[
	SquadService (Gameplay team)

	* Automatically groups the players of each side into squads of Constants.SQUAD_SIZE.
	* Writes player attributes `Squad` (number, 0 = none, unique per side) and `SquadLeader` (bool).
	* Re-elects a leader (highest score) when the leader leaves / switches side.
	* Squad spawning: a player may deploy on their squad leader (or, if they ARE the leader, on any
	  squadmate) when the target is alive, not in a vehicle and not in combat (not damaged within
	  COMBAT_LOCKOUT seconds).

	Public API
	  SquadService.GetSquadMembers(player) -> {Player}       (includes player)
	  SquadService.GetLeader(player) -> Player?
	  SquadService.IsInCombat(player) -> boolean
	  SquadService.GetSquadSpawn(player) -> (CFrame?, Player?, string?)   -- cframe, target, reason-if-unavailable
	  SquadService.SQUAD_NAMES  -- display names indexed by squad number (UI may use them)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)

local SquadService = {}

SquadService.COMBAT_LOCKOUT = 5 -- seconds since last damage before a squadmate can be spawned on
SquadService.SQUAD_NAMES = {
	"Able",
	"Baker",
	"Charlie",
	"Dog",
	"Easy",
	"Fox",
	"George",
	"How",
	"Item",
	"Jig",
	"King",
	"Love",
}

type Squad = { id: number, side: string, members: { Player }, leader: Player? }

local squads: { [string]: { [number]: Squad } } = { Allies = {}, Axis = {} }
local membership: { [Player]: Squad } = {}
local lastDamaged: { [Player]: number } = {}

local function squadName(id: number): string
	return SquadService.SQUAD_NAMES[id] or `Squad {id}`
end

local function notify(player: Player, text: string)
	Net.event("Notify"):FireClient(player, { text = text, kind = "info", duration = 4 })
end

local function writeAttributes(squad: Squad)
	for _, m in squad.members do
		m:SetAttribute("Squad", squad.id)
		m:SetAttribute("SquadLeader", m == squad.leader)
	end
end

local function electLeader(squad: Squad)
	local best: Player? = nil
	for _, m in squad.members do
		if not best or (m:GetAttribute("Score") or 0) > (best:GetAttribute("Score") or 0) then
			best = m
		end
	end
	local changed = squad.leader ~= best
	squad.leader = best
	writeAttributes(squad)
	if changed and best then
		notify(best, `You are now the leader of {squadName(squad.id)} squad.`)
	end
end

local function removeFromSquad(player: Player)
	local squad = membership[player]
	membership[player] = nil
	if player.Parent then
		player:SetAttribute("Squad", 0)
		player:SetAttribute("SquadLeader", false)
	end
	if not squad then
		return
	end
	local idx = table.find(squad.members, player)
	if idx then
		table.remove(squad.members, idx)
	end
	if #squad.members == 0 then
		squads[squad.side][squad.id] = nil
	elseif squad.leader == player then
		squad.leader = nil
		electLeader(squad)
	end
end

local function addToSquad(player: Player, side: string)
	local sideSquads = squads[side]
	if not sideSquads then
		return
	end
	-- Fill the lowest-numbered squad that has room, otherwise open the lowest unused number.
	local target: Squad? = nil
	local id = 1
	while true do
		local s = sideSquads[id]
		if not s then
			break
		end
		if #s.members < Constants.SQUAD_SIZE then
			target = s
			break
		end
		id += 1
	end
	local squad: Squad = target or { id = id, side = side, members = {}, leader = nil }
	sideSquads[squad.id] = squad
	table.insert(squad.members, player)
	membership[player] = squad
	if not squad.leader then
		squad.leader = player
	end
	writeAttributes(squad)
	notify(player, `Joined {squadName(squad.id)} squad.`)
end

local function onSideChanged(player: Player, side: string)
	if not player.Parent then
		return
	end
	local current = membership[player]
	if current and current.side == side then
		return
	end
	removeFromSquad(player)
	if side == "Allies" or side == "Axis" then
		addToSquad(player, side)
	end
end

function SquadService.GetSquadMembers(player: Player): { Player }
	local squad = membership[player]
	return if squad then table.clone(squad.members) else { player }
end

function SquadService.GetLeader(player: Player): Player?
	local squad = membership[player]
	return squad and squad.leader
end

function SquadService.IsInCombat(player: Player): boolean
	local t = lastDamaged[player]
	return t ~= nil and os.clock() - t < SquadService.COMBAT_LOCKOUT
end

local function liveRoot(player: Player): BasePart?
	if player:GetAttribute("Alive") ~= true then
		return nil
	end
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

-- Checks whether `target` is a valid squad spawn beacon; returns its root or a reason.
local function beaconStatus(target: Player): (BasePart?, string?)
	local root = liveRoot(target)
	if not root then
		return nil, "Squadmate is not deployed"
	end
	local vehicleUid = target:GetAttribute("VehicleUid")
	if type(vehicleUid) == "string" and vehicleUid ~= "" then
		return nil, "Squadmate is in a vehicle"
	end
	if SquadService.IsInCombat(target) then
		return nil, "Squadmate is in combat"
	end
	local outOfBounds = target:GetAttribute("OutOfBounds")
	if type(outOfBounds) == "number" and outOfBounds > 0 then
		return nil, "Squadmate is out of bounds"
	end
	return root, nil
end

-- Finds a free spot next to the beacon: behind/beside it, on the ground, with line of sight from it.
local function spotNear(root: BasePart): CFrame
	local character = root.Parent
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character :: Instance }
	params.RespectCanCollide = true
	local base = root.CFrame
	local offsets = {
		Vector3.new(0, 0, 3.5),
		Vector3.new(3, 0, 2),
		Vector3.new(-3, 0, 2),
		Vector3.new(2.5, 0, 0),
		Vector3.new(-2.5, 0, 0),
	}
	for _, offset in offsets do
		local worldOffset = base:VectorToWorldSpace(offset)
		worldOffset = Vector3.new(worldOffset.X, 0, worldOffset.Z)
		-- blocked by a wall between beacon and spot?
		if not workspace:Raycast(base.Position, worldOffset, params) then
			local candidate = base.Position + worldOffset
			local down = workspace:Raycast(candidate + Vector3.new(0, 2, 0), Vector3.new(0, -8, 0), params)
			if down then
				local pos = down.Position + Vector3.new(0, 3, 0)
				local flat = Vector3.new(base.LookVector.X, 0, base.LookVector.Z)
				if flat.Magnitude < 0.01 then
					flat = Vector3.new(0, 0, -1)
				end
				return CFrame.lookAlong(pos, flat)
			end
		end
	end
	return base + Vector3.new(0, 0.5, 0)
end

function SquadService.GetSquadSpawn(player: Player): (CFrame?, Player?, string?)
	local squad = membership[player]
	if not squad then
		return nil, nil, "No squad"
	end
	local leader = squad.leader
	if leader and leader ~= player then
		local root, reason = beaconStatus(leader)
		if root then
			return spotNear(root), leader, nil
		end
		return nil, leader, reason
	end
	-- The leader (or a leaderless squad) may deploy on any eligible squadmate.
	local lastReason = "No squadmate available"
	for _, m in squad.members do
		if m ~= player then
			local root, reason = beaconStatus(m)
			if root then
				return spotNear(root), m, nil
			end
			lastReason = reason or lastReason
		end
	end
	return nil, nil, lastReason
end

function SquadService:Init()
	Net.event("Notify")
end

function SquadService:Start()
	Bus.connect("PlayerSideChanged", function(player: Player, side: string)
		onSideChanged(player, side)
	end)
	Bus.connect("PlayerDamaged", function(victim: Player, _attacker: Player?, amount: number)
		if typeof(victim) == "Instance" and victim:IsA("Player") and type(amount) == "number" and amount > 0 then
			lastDamaged[victim] = os.clock()
		end
	end)
	Bus.connect("PlayerSpawned", function(player: Player)
		lastDamaged[player] = nil
	end)
	Players.PlayerAdded:Connect(function(player)
		-- Defaults only: TeamService may already have placed the player in a squad.
		if player:GetAttribute("Squad") == nil then
			player:SetAttribute("Squad", 0)
			player:SetAttribute("SquadLeader", false)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		removeFromSquad(player)
		lastDamaged[player] = nil
	end)
	-- Players whose side was assigned before we connected.
	for _, p in Players:GetPlayers() do
		local side = p:GetAttribute("Side")
		if type(side) == "string" and side ~= "" then
			onSideChanged(p, side)
		end
	end
end

return SquadService
