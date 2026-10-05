--[[
	RagdollService (Animation/Models team, server)

	When a player's Humanoid dies (characters are spawned with BreakJointsOnDeath = false):
	  * every Motor6D except Root is replaced by a limited BallSocketConstraint (elbows/knees use
	    HingeConstraints so they only bend the natural way) and disabled,
	  * adjacent limbs get NoCollisionConstraints, body parts collide (CollisionGroup "Debris", which
	    does not collide with Players), the invisible HumanoidRootPart stops colliding,
	  * the body is simulated by the server (network owner nil) and receives an impulse away from
	    the killer (Bus PlayerDamaged / PlayerKilled) or from a recent explosion (Bus Explosion),
	  * after it settles the body is anchored to stop simulation cost; SpawnService replaces or
	    destroys the character on respawn, and anything left is removed after BODY_LIFETIME.

	Public: RagdollService.Ragdoll(character) (idempotent) for other systems (e.g. vehicle deaths).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Constants = require(Shared.Config.Constants)

local RagdollService = {}

local SETTLE_TIME = 7 -- seconds before anchoring the body
local BODY_LIFETIME = 45 -- hard cleanup if nothing respawned the player
local HIT_MEMORY = 1.0 -- seconds a damage direction stays relevant
local DEBRIS_GROUP = Constants.COLLISION_GROUPS.Debris

-- name -> {kind, cone/upper, twist/lower}
--   ball:  UpperAngle cone + symmetric twist limit
--   hinge: LowerAngle/UpperAngle around the joint's X axis (+ = limb swings forward)
local JOINTS: { [string]: { kind: string, a: number, b: number, up: boolean? } } = {
	Neck = { kind = "ball", a = 35, b = 40, up = true },
	Waist = { kind = "ball", a = 25, b = 20, up = true },
	LeftShoulder = { kind = "ball", a = 80, b = 45 },
	RightShoulder = { kind = "ball", a = 80, b = 45 },
	LeftElbow = { kind = "hinge", a = -5, b = 130 },
	RightElbow = { kind = "hinge", a = -5, b = 130 },
	LeftWrist = { kind = "ball", a = 30, b = 20 },
	RightWrist = { kind = "ball", a = 30, b = 20 },
	LeftHip = { kind = "ball", a = 55, b = 20 },
	RightHip = { kind = "ball", a = 55, b = 20 },
	LeftKnee = { kind = "hinge", a = -120, b = 5 },
	RightKnee = { kind = "hinge", a = -120, b = 5 },
	LeftAnkle = { kind = "ball", a = 25, b = 10 },
	RightAnkle = { kind = "ball", a = 25, b = 10 },
}

type Hit = { t: number, from: Vector3?, strength: number, explosion: Vector3? }
local lastHit: { [Player]: Hit } = {}
local ragdolled: { [Model]: boolean } = {}

-- Attachment frame whose X axis points along the limb (down for limbs, up for neck/waist),
-- so a BallSocket cone opens around the limb's rest direction.
local LIMB_ROT = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, -1, 0), Vector3.new(1, 0, 0))
local UP_ROT = CFrame.fromMatrix(Vector3.zero, Vector3.new(0, 1, 0), Vector3.new(-1, 0, 0))

local function makeAttachment(part: BasePart, cf: CFrame, name: string): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = cf
	a.Parent = part
	return a
end

local function convertJoint(motor: Motor6D, folder: Folder)
	local spec = JOINTS[motor.Name]
	local p0, p1 = motor.Part0, motor.Part1
	if not (spec and p0 and p1) then
		return
	end
	local rot = if spec.kind == "hinge" then CFrame.identity else (if spec.up then UP_ROT else LIMB_ROT)
	local a0 = makeAttachment(p0, CFrame.new(motor.C0.Position) * rot, "RagdollA0_" .. motor.Name)
	local a1 = makeAttachment(p1, CFrame.new(motor.C1.Position) * rot, "RagdollA1_" .. motor.Name)

	if spec.kind == "hinge" then
		local h = Instance.new("HingeConstraint")
		h.Name = motor.Name
		h.Attachment0 = a0
		h.Attachment1 = a1
		h.LimitsEnabled = true
		h.LowerAngle = spec.a
		h.UpperAngle = spec.b
		h.Restitution = 0
		h.Parent = folder
	else
		local s = Instance.new("BallSocketConstraint")
		s.Name = motor.Name
		s.Attachment0 = a0
		s.Attachment1 = a1
		s.LimitsEnabled = true
		s.UpperAngle = spec.a
		s.TwistLimitsEnabled = true
		s.TwistLowerAngle = -spec.b
		s.TwistUpperAngle = spec.b
		s.Restitution = 0
		s.MaxFrictionTorque = 4
		s.Parent = folder
	end

	local nc = Instance.new("NoCollisionConstraint")
	nc.Part0 = p0
	nc.Part1 = p1
	nc.Parent = folder

	motor.Enabled = false
end

local function isBodyPart(part: BasePart, character: Model): boolean
	-- R15 limbs are direct children; outfit/weapon parts live inside sub-models.
	return part.Parent == character and part.Name ~= "HumanoidRootPart"
end

local function applyImpulse(character: Model, player: Player?)
	local hit = player and lastHit[player]
	if not hit or os.clock() - hit.t > HIT_MEMORY then
		return
	end
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("HumanoidRootPart")
	if not (torso and torso:IsA("BasePart")) then
		return
	end
	if hit.explosion then
		-- outward + upward on every limb
		for _, part in character:GetChildren() do
			if part:IsA("BasePart") and isBodyPart(part, character) then
				local away = part.Position - hit.explosion
				local dist = math.max(away.Magnitude, 1)
				local dir = (away.Unit + Vector3.new(0, 0.9, 0)).Unit
				local speed = math.clamp(70 * hit.strength / math.sqrt(dist), 15, 90)
				part:ApplyImpulse(dir * part:GetMass() * speed)
			end
		end
	elseif hit.from then
		local away = torso.Position - hit.from
		away = Vector3.new(away.X, 0, away.Z)
		if away.Magnitude < 1e-3 then
			return
		end
		local dir = (away.Unit + Vector3.new(0, 0.25, 0)).Unit
		local speed = 14 + 10 * math.clamp(hit.strength, 0, 1)
		torso:ApplyImpulse(dir * torso:GetMass() * speed)
		local head = character:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			head:ApplyImpulse(dir * head:GetMass() * speed * 0.8)
		end
	end
end

function RagdollService.Ragdoll(character: Model)
	if ragdolled[character] or not character.Parent then
		return
	end
	ragdolled[character] = true
	local player = Players:GetPlayerFromCharacter(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.BreakJointsOnDeath = false
		humanoid.RequiresNeck = false
		humanoid.PlatformStand = true
		humanoid.AutoRotate = false
	end

	local folder = Instance.new("Folder")
	folder.Name = "Ragdoll"
	folder.Parent = character
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") and d.Name ~= "Root" and JOINTS[d.Name] then
			convertJoint(d, folder)
		end
	end

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			if part.Name == "HumanoidRootPart" then
				part.CanCollide = false
				part.Massless = true
			elseif isBodyPart(part, character) then
				part.CanCollide = true
				part.CollisionGroup = DEBRIS_GROUP
			end
			if not part.Anchored then
				pcall(part.SetNetworkOwner, part, nil)
			end
		end
	end

	-- Let the joint swap take effect, then push.
	task.defer(applyImpulse, character, player)

	task.delay(SETTLE_TIME, function()
		if character.Parent then
			for _, part in character:GetDescendants() do
				if part:IsA("BasePart") then
					part.Anchored = true
				end
			end
		end
	end)
	task.delay(BODY_LIFETIME, function()
		ragdolled[character] = nil
		if character.Parent and (not player or player.Character ~= character or not player.Parent) then
			character:Destroy()
		end
	end)
	character.Destroying:Connect(function()
		ragdolled[character] = nil
	end)
end

local function watchCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not (humanoid and humanoid:IsA("Humanoid")) then
		return
	end
	humanoid.BreakJointsOnDeath = false
	humanoid.Died:Connect(function()
		RagdollService.Ragdoll(character)
	end)
end

local function characterPosition(player: Player?): Vector3?
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

function RagdollService:Start()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(watchCharacter)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(watchCharacter)
		if player.Character then
			task.spawn(watchCharacter, player.Character)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		lastHit[player] = nil
	end)

	Bus.connect("PlayerDamaged", function(victim: Player, attacker: Player?, amount: number, _weaponId: string)
		if typeof(victim) ~= "Instance" then
			return
		end
		local from = characterPosition(attacker)
		local prev = lastHit[victim]
		if prev and prev.explosion and os.clock() - prev.t < 0.2 then
			return -- keep the explosion as the dominant cause
		end
		lastHit[victim] = {
			t = os.clock(),
			from = from,
			strength = math.clamp((tonumber(amount) or 30) / 60, 0.2, 1.5),
		}
	end)

	Bus.connect("PlayerKilled", function(victim: Player, killer: Player?, _weaponId: string, headshot: boolean)
		if typeof(victim) ~= "Instance" then
			return
		end
		local hit = lastHit[victim]
		if hit and not hit.explosion then
			hit.from = hit.from or characterPosition(killer)
			if headshot then
				hit.strength = math.max(hit.strength, 1)
			end
		elseif not hit then
			lastHit[victim] = { t = os.clock(), from = characterPosition(killer), strength = 0.8 }
		end
	end)

	Bus.connect("Explosion", function(position: Vector3, radius: number, power: number, _attacker: Player?)
		if typeof(position) ~= "Vector3" then
			return
		end
		local r = math.max(tonumber(radius) or 10, 1)
		for _, player in Players:GetPlayers() do
			local pos = characterPosition(player)
			if pos and (pos - position).Magnitude <= r * 1.2 then
				local proximity = 1 - math.clamp((pos - position).Magnitude / (r * 1.2), 0, 1)
				lastHit[player] = {
					t = os.clock(),
					explosion = position,
					strength = math.clamp((tonumber(power) or 1) * (0.5 + proximity), 0.3, 2),
				}
			end
		end
	end)
end

return RagdollService
