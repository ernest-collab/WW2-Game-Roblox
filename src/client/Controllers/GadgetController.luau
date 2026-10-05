--[[
	GadgetController (Gameplay team, client)

	Client side of the teamwork gadgets. The server (GadgetService) is authoritative; this controller
	only picks targets / positions, sends `Gadget_Use`, and drives local feedback.

	Public API (called by WeaponController, which owns slot switching and fire input):
	  GadgetController.Use(category: string)
	      Primary action of the equipped gadget ("Medkit" | "AmmoBox" | "Repair" | "Binoculars"), or
	      "Spot" (quick spot, also bound to Keybinds.keyboard.Spot here).
	        Medkit     -> heal the damaged teammate in front of you, otherwise drop a medical pouch
	        AmmoBox    -> drop an ammo crate in front of you
	        Binoculars -> spot enemies around the aim point
	        Repair     -> starts repairing (same as SetHolding("Repair", true)); stops automatically
	                      when the fire button is released or SetHolding("Repair", false) is called
	  GadgetController.SetHolding(category: string, holding: boolean)
	      Hold actions: "Repair" (continuous vehicle repair), "Medkit" (keep healing the teammate in front).

	Client Bus (contract addition):
	  GadgetProgress(fraction: number?, label: string?)   -- nil fraction hides the hold-progress UI

	Also:
	  * Revive prompts (ProximityPrompt tagged "RevivePrompt") are enabled locally only for medics of
	    the same side; holding one reports GadgetProgress("Reviving <name>").
	  * Spotted enemies (player/vehicle `Spotted` attribute > server time) get a red outline Highlight.
	  * Medics see a "+" marker over downed revivable teammates.
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local Keybinds = require(Shared.Config.Keybinds)
local Progression = require(Shared.Config.Progression)
local Bus = require(Shared.Util.Bus)
local Net = require(Shared.Util.Net)
local Trove = require(Shared.Util.Trove)

local GadgetController = {}

local player = Players.LocalPlayer

local HEAL_RANGE = 9
local DROP_DISTANCE = 3.5
local REPAIR_RANGE = 9
local REPAIR_INTERVAL = 0.25
local MEDKIT_HOLD_INTERVAL = 1.1
local SPOT_CLIENT_COOLDOWN = 0.5
local MAX_HIGHLIGHTS = 24
local REVIVE_PROMPT_TAG = "RevivePrompt"
local VEHICLE_TAG = Constants.TAGS.Vehicle

local gadgetRemote: RemoteEvent? = nil
local holding: { [string]: boolean } = {}
local holdThreads: { [string]: thread } = {}
local lastSpot = 0
local progressOwner: string? = nil

local highlights: { [Instance]: Highlight } = {}
local markers: { [Player]: BillboardGui } = {}
local promptTrove = Trove.new()

local controllerCache: { [string]: any } = {}
local function getController(name: string): any
	local cached = controllerCache[name]
	if cached then
		return cached
	end
	local module = script.Parent:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		controllerCache[name] = result
		return result
	end
	return nil
end

local function menuOpen(): boolean
	local ui = getController("UIController")
	if ui and type(ui.IsMenuOpen) == "function" then
		local ok, result = pcall(ui.IsMenuOpen)
		return ok and result == true
	end
	return false
end

local function send(payload: { [string]: any })
	if gadgetRemote then
		gadgetRemote:FireServer(payload)
	end
end

local function setProgress(owner: string, fraction: number?, label: string?)
	if fraction == nil then
		if progressOwner == owner then
			progressOwner = nil
			Bus.fire("GadgetProgress", nil, nil)
		end
		return
	end
	progressOwner = owner
	Bus.fire("GadgetProgress", math.clamp(fraction, 0, 1), label)
end

local function sideOf(p: Player): string
	local s = p:GetAttribute("Side")
	return if type(s) == "string" then s else ""
end

local function myCharacter(): (Model?, BasePart?)
	if player:GetAttribute("Alive") ~= true then
		return nil, nil
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil, nil
	end
	return character, root
end

local function myLoadout(): any
	local raw = player:GetAttribute("Loadout")
	if type(raw) ~= "string" or raw == "" then
		return nil
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	return if ok then decoded else nil
end

local function hasGadget(category: string): boolean
	local classId = player:GetAttribute("Class")
	if type(classId) ~= "string" then
		return false
	end
	return Progression.hasGadgetCategory(classId, myLoadout(), category)
end

-- Camera-center ray (excluding the local character). Returns hit result and aim point.
local function aimRay(maxDistance: number): (RaycastResult?, Vector3)
	local camera = workspace.CurrentCamera
	local character = player.Character
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if character then { character } else {}
	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
	local result = workspace:Raycast(ray.Origin, ray.Direction * maxDistance, params)
	local point = if result then result.Position else ray.Origin + ray.Direction * maxDistance
	return result, point
end

local function playerFromInstance(inst: Instance?): Player?
	local current = inst
	while current and current ~= workspace do
		local p = Players:GetPlayerFromCharacter(current)
		if p then
			return p
		end
		current = current.Parent
	end
	return nil
end

local function vehicleFromInstance(inst: Instance?): Model?
	local current = inst
	while current and current ~= workspace do
		if current:IsA("Model") and CollectionService:HasTag(current, VEHICLE_TAG) then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Damaged teammate in front of us: the one under the crosshair, else the closest within a cone.
local function findHealTarget(root: BasePart): (Player?, Humanoid?)
	local result = aimRay(HEAL_RANGE + 6)
	local mySide = sideOf(player)
	local function eligible(p: Player?): (Player?, Humanoid?)
		if not p or p == player or sideOf(p) ~= mySide or p:GetAttribute("Alive") ~= true then
			return nil, nil
		end
		local character = p.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local theirRoot = character and character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not theirRoot or not theirRoot:IsA("BasePart") then
			return nil, nil
		end
		if humanoid.Health <= 0 or humanoid.Health >= humanoid.MaxHealth then
			return nil, nil
		end
		if (theirRoot.Position - root.Position).Magnitude > HEAL_RANGE then
			return nil, nil
		end
		return p, humanoid
	end
	local direct, directHumanoid = eligible(playerFromInstance(result and result.Instance))
	if direct then
		return direct, directHumanoid
	end
	local look = workspace.CurrentCamera.CFrame.LookVector
	local best, bestHumanoid, bestScore = nil, nil, -math.huge
	for _, p in Players:GetPlayers() do
		local candidate, humanoid = eligible(p)
		if candidate and humanoid then
			local theirRoot = (candidate.Character :: Model):FindFirstChild("HumanoidRootPart") :: BasePart
			local to = theirRoot.Position - root.Position
			local dot = if to.Magnitude > 0.01 then to.Unit:Dot(look) else 1
			if dot > 0.6 and dot - to.Magnitude * 0.02 > bestScore then
				best, bestHumanoid, bestScore = candidate, humanoid, dot - to.Magnitude * 0.02
			end
		end
	end
	return best, bestHumanoid
end

local function findRepairTarget(root: BasePart): Model?
	local result = aimRay(REPAIR_RANGE + 8)
	local vehicle = vehicleFromInstance(result and result.Instance)
	local mySide = sideOf(player)
	local function ok(v: Model?): boolean
		if not v or v:GetAttribute("Destroyed") == true then
			return false
		end
		local side = v:GetAttribute("Side")
		return side == nil or side == "" or side == mySide
	end
	if ok(vehicle) then
		return vehicle
	end
	-- Otherwise the nearest friendly vehicle we are touching-distance from.
	local best, bestDist = nil, math.huge
	for _, v in CollectionService:GetTagged(VEHICLE_TAG) do
		if v:IsA("Model") and ok(v) then
			local cf, size = v:GetBoundingBox()
			local dist = (cf.Position - root.Position).Magnitude - size.Magnitude / 2
			if dist < REPAIR_RANGE and dist < bestDist then
				best, bestDist = v, dist
			end
		end
	end
	return best
end

local function groundInFront(root: BasePart): Vector3
	local look = workspace.CurrentCamera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.01 then
		flat = root.CFrame.LookVector
	end
	return root.Position + flat.Unit * DROP_DISTANCE
end

---------------------------------------------------------------------------------------------------
-- Hold actions
---------------------------------------------------------------------------------------------------

local function stopHold(category: string)
	holding[category] = false
	local thread = holdThreads[category]
	holdThreads[category] = nil
	if thread and thread ~= coroutine.running() then
		pcall(task.cancel, thread)
	end
	setProgress(category, nil)
end

local function repairLoop()
	while holding.Repair do
		local _, root = myCharacter()
		if not root then
			break
		end
		-- When started via Use(), stop as soon as the fire button is released.
		if
			GadgetController._repairFromClick
			and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
			and not UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Keybinds.gamepad.Fire)
		then
			break
		end
		local vehicle = findRepairTarget(root)
		if vehicle then
			send({ gadget = "Repair", target = vehicle })
			local health, maxHealth = vehicle:GetAttribute("Health"), vehicle:GetAttribute("MaxHealth")
			if type(health) == "number" and type(maxHealth) == "number" and maxHealth > 0 then
				local name = vehicle:GetAttribute("VehicleId") or vehicle.Name
				local label = if health >= maxHealth then `{name} fully repaired` else `Repairing {name}`
				setProgress("Repair", health / maxHealth, label)
			end
		else
			setProgress("Repair", nil)
		end
		task.wait(REPAIR_INTERVAL)
	end
	holding.Repair = false
	holdThreads.Repair = nil
	GadgetController._repairFromClick = false
	setProgress("Repair", nil)
end

local function medkitLoop()
	while holding.Medkit do
		local _, root = myCharacter()
		if not root then
			break
		end
		local target, humanoid = findHealTarget(root)
		if target and humanoid then
			send({ gadget = "Medkit", target = target.Character })
			setProgress("Medkit", humanoid.Health / humanoid.MaxHealth, `Healing {target.DisplayName}`)
		else
			setProgress("Medkit", nil)
		end
		task.wait(MEDKIT_HOLD_INTERVAL)
	end
	holding.Medkit = false
	holdThreads.Medkit = nil
	setProgress("Medkit", nil)
end

GadgetController._repairFromClick = false

function GadgetController.SetHolding(category: string, isHolding: boolean)
	if type(category) ~= "string" then
		return
	end
	if not isHolding then
		stopHold(category)
		return
	end
	if holding[category] then
		return
	end
	if category == "Repair" then
		if not hasGadget("Repair") then
			return
		end
		holding.Repair = true
		holdThreads.Repair = task.spawn(repairLoop)
	elseif category == "Medkit" then
		if not hasGadget("Medkit") then
			return
		end
		holding.Medkit = true
		holdThreads.Medkit = task.spawn(medkitLoop)
	end
end

---------------------------------------------------------------------------------------------------
-- Primary use
---------------------------------------------------------------------------------------------------

function GadgetController.Use(category: string)
	if type(category) ~= "string" or menuOpen() then
		return
	end
	local _, root = myCharacter()
	if not root then
		return
	end
	if category == "Medkit" then
		if not hasGadget("Medkit") then
			return
		end
		local target = findHealTarget(root)
		if target then
			send({ gadget = "Medkit", target = target.Character })
		else
			send({ gadget = "Medkit", position = groundInFront(root) })
		end
	elseif category == "AmmoBox" then
		if not hasGadget("AmmoBox") then
			return
		end
		send({ gadget = "AmmoBox", position = groundInFront(root) })
	elseif category == "Repair" then
		GadgetController._repairFromClick = true
		GadgetController.SetHolding("Repair", true)
	elseif category == "Binoculars" or category == "Spot" then
		local now = os.clock()
		if now - lastSpot < SPOT_CLIENT_COOLDOWN then
			return
		end
		lastSpot = now
		local _, point = aimRay(1000)
		send({ gadget = category, position = point })
	end
end

---------------------------------------------------------------------------------------------------
-- Revive prompts (local filtering + progress)
---------------------------------------------------------------------------------------------------

local function promptVisible(prompt: ProximityPrompt): boolean
	if prompt:GetAttribute("Side") ~= sideOf(player) then
		return false
	end
	if prompt:GetAttribute("VictimUserId") == player.UserId then
		return false
	end
	return player:GetAttribute("Alive") == true and hasGadget("Medkit")
end

local function refreshPrompt(prompt: Instance)
	if prompt:IsA("ProximityPrompt") then
		prompt.Enabled = promptVisible(prompt)
	end
end

local function refreshAllPrompts()
	for _, prompt in CollectionService:GetTagged(REVIVE_PROMPT_TAG) do
		refreshPrompt(prompt)
	end
end

local reviveHoldToken = 0
local function onHoldBegan(prompt: ProximityPrompt)
	if not CollectionService:HasTag(prompt, REVIVE_PROMPT_TAG) then
		return
	end
	reviveHoldToken += 1
	local token = reviveHoldToken
	local started = os.clock()
	local duration = math.max(prompt.HoldDuration, 0.05)
	local label = `Reviving {prompt.ObjectText}`
	task.spawn(function()
		while reviveHoldToken == token do
			local fraction = (os.clock() - started) / duration
			setProgress("Revive", fraction, label)
			if fraction >= 1 then
				break
			end
			RunService.RenderStepped:Wait()
		end
	end)
end

local function onHoldEnded(prompt: ProximityPrompt)
	if not CollectionService:HasTag(prompt, REVIVE_PROMPT_TAG) then
		return
	end
	reviveHoldToken += 1
	setProgress("Revive", nil)
end

---------------------------------------------------------------------------------------------------
-- Spotted highlights & downed-teammate markers
---------------------------------------------------------------------------------------------------

local function ensureHighlight(target: Instance)
	if highlights[target] then
		return
	end
	local count = 0
	for _ in highlights do
		count += 1
	end
	if count >= MAX_HIGHLIGHTS then
		return
	end
	local h = Instance.new("Highlight")
	h.Name = "SpottedHighlight"
	h.FillTransparency = 1
	h.OutlineColor = Color3.fromRGB(255, 60, 50)
	h.OutlineTransparency = 0.15
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Adornee = target
	h.Parent = target
	highlights[target] = h
end

local function makeMarker(): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "DownedMarker"
	gui.Size = UDim2.fromOffset(28, 28)
	gui.StudsOffset = Vector3.new(0, 2.5, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 150
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
	label.BackgroundTransparency = 0.1
	label.Text = "+"
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(200, 30, 30)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = label
	label.Parent = gui
	return gui
end

local function updateVisuals()
	local now = workspace:GetServerTimeNow()
	local mySide = sideOf(player)
	local wanted: { [Instance]: boolean } = {}

	for _, p in Players:GetPlayers() do
		if p ~= player then
			local side = sideOf(p)
			local character = p.Character
			-- Spotted enemies
			local spotted = p:GetAttribute("Spotted")
			if
				character
				and side ~= ""
				and side ~= mySide
				and type(spotted) == "number"
				and spotted > now
				and p:GetAttribute("Alive") == true
			then
				wanted[character] = true
			end
			-- Downed teammates (medics only)
			local revivable = p:GetAttribute("Revivable")
			local showMarker = side == mySide
				and type(revivable) == "number"
				and revivable > now
				and character ~= nil
				and player:GetAttribute("Alive") == true
				and hasGadget("Medkit")
			local marker = markers[p]
			if showMarker and character then
				local adornee = character:FindFirstChild("HumanoidRootPart")
					or character:FindFirstChild("UpperTorso")
					or character:FindFirstChild("Head")
				if adornee and adornee:IsA("BasePart") then
					if not marker then
						marker = makeMarker()
						markers[p] = marker
					end
					local gui = marker :: BillboardGui
					gui.Adornee = adornee
					if gui.Parent == nil then
						gui.Parent = player:FindFirstChildOfClass("PlayerGui")
					end
				end
			elseif marker then
				marker:Destroy()
				markers[p] = nil
			end
		end
	end
	for _, vehicle in CollectionService:GetTagged(VEHICLE_TAG) do
		local spotted = vehicle:GetAttribute("Spotted")
		local side = vehicle:GetAttribute("Side")
		if
			type(spotted) == "number"
			and spotted > now
			and side ~= mySide
			and vehicle:GetAttribute("Destroyed") ~= true
		then
			wanted[vehicle] = true
		end
	end

	for target, h in highlights do
		if not wanted[target] or not target.Parent then
			h:Destroy()
			highlights[target] = nil
		end
	end
	for target in wanted do
		ensureHighlight(target)
	end
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

function GadgetController:Init()
	gadgetRemote = Net.event("Gadget_Use")
end

function GadgetController:Start()
	-- Quick spot (every class).
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or menuOpen() then
			return
		end
		if input.KeyCode == Keybinds.keyboard.Spot then
			GadgetController.Use("Spot")
		end
	end)

	-- Revive prompts
	CollectionService:GetInstanceAddedSignal(REVIVE_PROMPT_TAG):Connect(refreshPrompt)
	for _, attr in { "Side", "Class", "Loadout", "Alive" } do
		promptTrove:Add(player:GetAttributeChangedSignal(attr):Connect(refreshAllPrompts))
	end
	refreshAllPrompts()
	ProximityPromptService.PromptButtonHoldBegan:Connect(onHoldBegan)
	ProximityPromptService.PromptButtonHoldEnded:Connect(onHoldEnded)
	ProximityPromptService.PromptTriggered:Connect(onHoldEnded)

	-- Stop hold actions on death / despawn.
	player:GetAttributeChangedSignal("Alive"):Connect(function()
		if player:GetAttribute("Alive") ~= true then
			stopHold("Repair")
			stopHold("Medkit")
			reviveHoldToken += 1
			setProgress("Revive", nil)
		end
	end)

	Players.PlayerRemoving:Connect(function(p)
		local marker = markers[p]
		if marker then
			marker:Destroy()
			markers[p] = nil
		end
	end)

	task.spawn(function()
		while true do
			local ok, err = pcall(updateVisuals)
			if not ok then
				warn(`[GadgetController] visuals update failed: {err}`)
			end
			task.wait(0.25)
		end
	end)
end

return GadgetController
