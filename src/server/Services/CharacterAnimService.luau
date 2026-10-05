--[[
	CharacterAnimService (Animation/Models team, server)

	* Receives `Anim_State` (UnreliableRemoteEvent, client -> server, <= 15 Hz) = {pitch, stance}
	  and replicates it as character attributes `AimPitch` (radians) and `Stance`
	  ("Stand" | "Crouch" | "Prone" | "Sprint"). Clients pose every character from these
	  (CharacterAnimController).
	* Removes the default `Animate` script from spawned characters: all character animation is
	  procedural, so the stock walk/idle tracks would fight the Motor6D poses.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Util.Net)

local CharacterAnimService = {}

local VALID_STANCE = { Stand = true, Crouch = true, Prone = true, Sprint = true }
local MAX_PITCH = math.rad(85)
local PITCH_QUANTUM = 0.01 -- radians; smaller changes are not re-replicated
local RATE_PER_SECOND = 20 -- client sends <= 15 Hz; leave headroom for jitter

local function prepareCharacter(character: Model)
	character:SetAttribute("AimPitch", 0)
	character:SetAttribute("Stance", "Stand")
	local function strip(child: Instance)
		if child.Name == "Animate" and (child:IsA("LocalScript") or child:IsA("Script")) then
			task.defer(function()
				if child.Parent then
					child:Destroy()
				end
			end)
		end
	end
	for _, child in character:GetChildren() do
		strip(child)
	end
	-- Animate is inserted from StarterCharacterScripts slightly after CharacterAdded.
	local conn
	conn = character.ChildAdded:Connect(strip)
	task.delay(5, function()
		conn:Disconnect()
	end)
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(prepareCharacter)
	if player.Character then
		prepareCharacter(player.Character)
	end
end

local function onAnimState(player: Player, payload: any)
	if type(payload) ~= "table" then
		return
	end
	if not Net.rateLimit(player, "Anim_State", RATE_PER_SECOND) then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local pitch = payload.pitch
	if type(pitch) == "number" and pitch == pitch and math.abs(pitch) < math.huge then
		pitch = math.clamp(math.round(pitch / PITCH_QUANTUM) * PITCH_QUANTUM, -MAX_PITCH, MAX_PITCH)
		local old = character:GetAttribute("AimPitch")
		if type(old) ~= "number" or math.abs(old - pitch) >= PITCH_QUANTUM * 0.5 then
			character:SetAttribute("AimPitch", pitch)
		end
	end

	local stance = payload.stance
	if type(stance) == "string" and VALID_STANCE[stance] then
		if character:GetAttribute("Stance") ~= stance then
			character:SetAttribute("Stance", stance)
		end
	end
end

function CharacterAnimService:Init()
	Net.unreliable("Anim_State")
end

function CharacterAnimService:Start()
	Net.unreliable("Anim_State").OnServerEvent:Connect(onAnimState)
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return CharacterAnimService
