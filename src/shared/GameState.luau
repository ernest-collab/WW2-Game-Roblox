--[[
	GameState: the replicated match state, stored as attributes on ReplicatedStorage.GameState
	(a Folder). The server (RoundService and friends) writes; everyone reads.
	UI should listen with folder:GetAttributeChangedSignal(name).

	Attributes (see docs/ARCHITECTURE.md for full semantics):
	  Phase            string   "Waiting" | "Intermission" | "Loading" | "InRound" | "PostRound"
	  ModeId           string   GameModes id ("Conquest" | "Frontline" | "TDM")
	  MapId            string   Maps id
	  TimeLeft         number   seconds remaining in current phase
	  AlliesFaction    string   Factions id   AxisFaction string
	  AlliesTickets    number   AxisTickets number   (Conquest/Frontline)
	  AlliesScore      number   AxisScore number     (TDM kills / generic score)
	  Winner           string   "Allies" | "Axis" | "Draw" | ""
	  LightingPreset   string   LightingPresets id
	  Weather          string   "Clear" | "Rain" | "Snow" | "Fog" | "Storm"
	  MapInfoJson      string   serialized public map info (see MapInfo in ARCHITECTURE.md)

	Children:
	  Objectives (Folder) -> one Folder per objective, named by id, with attributes:
	      DisplayName string, Owner string ("Allies"|"Axis"|"Neutral"), Progress number (-1 Axis .. +1 Allies),
	      Contested bool, Capturing string (side or ""), Position Vector3, Radius number, Order number, Locked bool
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameState = {}

GameState.DEFAULTS = {
	Phase = "Waiting",
	ModeId = "",
	MapId = "",
	TimeLeft = 0,
	AlliesFaction = "US",
	AxisFaction = "DE",
	AlliesTickets = 0,
	AxisTickets = 0,
	AlliesScore = 0,
	AxisScore = 0,
	Winner = "",
	LightingPreset = "Overcast",
	Weather = "Clear",
	MapInfoJson = "",
}

local folder: Folder? = nil

local function ensure(): Folder
	local cached = folder
	if cached then
		return cached
	end
	local result: Folder
	if RunService:IsServer() then
		local f = ReplicatedStorage:FindFirstChild("GameState") :: Folder?
		if not f then
			local newFolder = Instance.new("Folder")
			newFolder.Name = "GameState"
			for k, v in GameState.DEFAULTS do
				newFolder:SetAttribute(k, v)
			end
			local objectives = Instance.new("Folder")
			objectives.Name = "Objectives"
			objectives.Parent = newFolder
			newFolder.Parent = ReplicatedStorage
			f = newFolder
		end
		result = f :: Folder
	else
		result = ReplicatedStorage:WaitForChild("GameState") :: Folder
	end
	folder = result
	return result
end

function GameState.folder(): Folder
	return ensure()
end

function GameState.objectives(): Folder
	return ensure():WaitForChild("Objectives") :: Folder
end

function GameState.get(name: string): any
	return ensure():GetAttribute(name)
end

-- Server only.
function GameState.set(name: string, value: any)
	assert(RunService:IsServer(), "GameState.set is server-only")
	ensure():SetAttribute(name, value)
end

function GameState.changed(name: string): RBXScriptSignal
	return ensure():GetAttributeChangedSignal(name)
end

return GameState
