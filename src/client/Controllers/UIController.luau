--[[
	UIController: root of every menu and HUD element.

	Screen flow (re-evaluated on every relevant event, never per frame):
	  Phase Waiting/Intermission/Loading -> Intermission screen (next map / mode / timer)
	  Phase InRound, not deployed         -> Deploy screen (team, class, loadout, spawn, countdown)
	  Phase InRound, deployed & alive     -> HUD (+ overlays: Scoreboard, BigMap, Settings, Loadout)
	  just died                           -> 2 s "death cam" (HUD hidden), then Deploy screen
	  Round_Ended / Phase PostRound       -> Round end debrief

	Public API
	  UIController.IsMenuOpen() -> boolean   -- true while any menu wants the mouse / blocks input
	  UIController.OpenMenu(name) / CloseMenu(name) / ToggleMenu(name)   ("Settings"|"BigMap"|"Loadout")
	  UIController.ToggleScoreboard()
	  UIController.GetProgression() -> ProgressionData?    UIController.GetUnlocked() -> {[id]=true}
	  UIController.RequestDeploy(classId, loadout, spawnId)
	  UIController.Notify(text, kind?, duration?)          -- local toast
	Bus fired: MenuOpened(name) / MenuClosed(name), Deployed(character).
	Menus: "Deploy", "Intermission", "RoundEnd", "Settings", "BigMap", "Loadout".

	ScreenGuis (DisplayOrder): WW2_FX 2 (crosshair, hitmarker, damage, vignette, scope; full screen),
	WW2_HUD 5 (safe area), WW2_Backdrop 9 (menu dimmers), WW2_Menus 10, WW2_Overlay 15.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Constants = require(Shared.Config.Constants)
local GameState = require(Shared.GameState)
local Trove = require(Shared.Util.Trove)

local UIFolder = script.Parent.Parent:WaitForChild("UI")
local Remotes = require(UIFolder:WaitForChild("Remotes"))
local Theme = require(UIFolder:WaitForChild("Theme"))

local UIController = {}

local LOCAL_PLAYER = Players.LocalPlayer
local DEATH_CAM_TIME = 2
local MOUSE_STEP = "WW2_UIMouseUnlock"
local OVERLAY_MENUS = { Settings = true, BigMap = true, Loadout = true }

local trove = Trove.new()
local ctx: any = nil
local components: { [string]: any } = {}
local openMenus: { [string]: boolean } = {}
local mouseBound = false

local state = {
	base = "",
	deployed = false,
	deployedCharacter = nil :: Model?,
	deathCamUntil = 0,
	results = nil :: any,
	progression = nil :: any,
	lastLevel = 0,
	scoreboardHeld = false,
	scoreboardToggled = false,
}

------------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------------

-- Stub used if SettingsController failed to load, so every component still works.
local SETTINGS_STUB = {
	Schema = {},
	Get = function(_key: string): any
		return nil
	end,
	Set = function(_key: string, _value: any) end,
	Save = function() end,
	ResetDefaults = function() end,
}

local function safeNew(name: string, ...: any): any
	local module = UIFolder:FindFirstChild(name)
	if not module then
		warn(`[UI] missing UI module {name}`)
		return nil
	end
	local ok, result = pcall(function(...)
		return require(module :: ModuleScript).new(...)
	end, ...)
	if not ok then
		warn(`[UI] failed to create {name}: {result}`)
		return nil
	end
	return result
end

-- Calls component:method(...) if the component exists and implements it.
local function call(name: string, method: string, ...: any): any
	local c = components[name]
	if c and type(c[method]) == "function" then
		local ok, result = pcall(c[method], c, ...)
		if not ok then
			warn(`[UI] {name}:{method} failed: {result}`)
			return nil
		end
		return result
	end
	return nil
end

local function hideCoreGui()
	task.spawn(function()
		for _ = 1, 20 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
			end)
			if ok then
				return
			end
			task.wait(0.5)
		end
	end)
end

local function isAlive(): boolean
	if LOCAL_PLAYER:GetAttribute("Alive") == false then
		return false
	end
	local char = LOCAL_PLAYER.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function inVehicle(): boolean
	local uid = LOCAL_PLAYER:GetAttribute("VehicleUid")
	return type(uid) == "string" and uid ~= ""
end

------------------------------------------------------------------------------------------------
-- Menus & mouse
------------------------------------------------------------------------------------------------

local function updateMouse()
	local want = UIController.IsMenuOpen()
	if want and not mouseBound then
		mouseBound = true
		-- Runs after the camera each frame so a camera controller that locks the mouse is overridden.
		RunService:BindToRenderStep(MOUSE_STEP, Enum.RenderPriority.Last.Value, function()
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end)
	elseif not want and mouseBound then
		mouseBound = false
		RunService:UnbindFromRenderStep(MOUSE_STEP)
	end
end

local refreshVisibility: () -> ()

local function setMenu(name: string, open: boolean)
	if (openMenus[name] == true) == open then
		return
	end
	openMenus[name] = open or nil
	Bus.fire(open and "MenuOpened" or "MenuClosed", name)
	updateMouse()
end

function UIController.IsMenuOpen(): boolean
	return next(openMenus) ~= nil
end

function UIController.OpenMenu(name: string)
	if not OVERLAY_MENUS[name] or openMenus[name] then
		return
	end
	if name == "BigMap" or name == "Loadout" then
		if state.base ~= "HUD" then
			return
		end
	end
	-- Only one overlay at a time (Settings may stack on top of the others).
	for other in OVERLAY_MENUS do
		if other ~= name and openMenus[other] and name ~= "Settings" then
			UIController.CloseMenu(other)
		end
	end
	if name == "Settings" then
		call("settings", "SetVisible", true)
	elseif name == "BigMap" then
		call("bigMap", "SetVisible", true)
	elseif name == "Loadout" then
		call("deploy", "Open", "edit")
	end
	setMenu(name, true)
	refreshVisibility()
end

function UIController.CloseMenu(name: string)
	if not openMenus[name] then
		return
	end
	if name == "Settings" then
		call("settings", "SetVisible", false)
	elseif name == "BigMap" then
		call("bigMap", "SetVisible", false)
	elseif name == "Loadout" then
		call("deploy", "Close")
	end
	setMenu(name, false)
	refreshVisibility()
end

function UIController.ToggleMenu(name: string)
	if openMenus[name] then
		UIController.CloseMenu(name)
	else
		UIController.OpenMenu(name)
	end
end

function UIController.ToggleScoreboard()
	state.scoreboardToggled = not state.scoreboardToggled
	refreshVisibility()
end

------------------------------------------------------------------------------------------------
-- Data accessors used by components
------------------------------------------------------------------------------------------------

function UIController.GetProgression(): any
	return state.progression
end

function UIController.GetUnlocked(): { [string]: any }
	local p = state.progression
	return type(p) == "table" and type(p.unlocked) == "table" and p.unlocked or {}
end

function UIController.RequestDeploy(classId: string, loadout: { [string]: string }, spawnId: string)
	Remotes.fire("Spawn_Request", { classId = classId, loadout = loadout, spawnId = spawnId })
end

function UIController.Notify(text: string, kind: string?, duration: number?)
	call("notifications", "Toast", text, kind, duration)
end

------------------------------------------------------------------------------------------------
-- Screen flow
------------------------------------------------------------------------------------------------

local function computeBase(): string
	local phase = GameState.get("Phase")
	if phase == "PostRound" or (state.results ~= nil and phase == "InRound") then
		return "RoundEnd"
	end
	if phase ~= "InRound" then
		return "Intermission"
	end
	if state.deployed and isAlive() then
		return "HUD"
	end
	if os.clock() < state.deathCamUntil then
		return "DeathCam"
	end
	return "Deploy"
end

-- Shows/hides HUD-layer components based on the base screen + open overlays.
function refreshVisibility()
	local base = state.base
	local hud = base == "HUD"
	local menuOver = UIController.IsMenuOpen()
	local vehicle = inVehicle()
	local combat = hud and not menuOver

	call("hud", "SetVisible", hud)
	call("hud", "SetInfantry", not vehicle)
	call("minimap", "SetVisible", hud)
	call("compass", "SetVisible", hud)
	call("objectives", "SetVisible", hud)
	call("killfeed", "SetVisible", hud or base == "DeathCam")
	call("scorePopups", "SetVisible", hud or base == "DeathCam")
	call("crosshair", "SetVisible", combat and not vehicle)
	call("scope", "SetVisible", combat and not vehicle)
	call("hitmarker", "SetVisible", hud)
	call("damage", "SetVisible", hud)
	call("notifications", "SetHudActive", hud)
	local scoreboard = (state.scoreboardHeld or state.scoreboardToggled)
		and (hud or base == "DeathCam" or base == "Deploy")
		and not openMenus.Settings
	call("scoreboard", "SetVisible", scoreboard)
end

local function updateScreens()
	local base = computeBase()
	local previous = state.base
	state.base = base

	-- Overlays that only make sense in-game close when leaving the HUD.
	if base ~= "HUD" then
		if openMenus.BigMap then
			UIController.CloseMenu("BigMap")
		end
		if openMenus.Loadout then
			UIController.CloseMenu("Loadout")
		end
		state.scoreboardToggled = false
	end

	-- Deploy screen
	if base == "Deploy" then
		local deploy = components.deploy
		if deploy and (not deploy:IsOpen() or deploy:GetMode() ~= "deploy") then
			call("deploy", "Open", "deploy")
		end
	elseif not openMenus.Loadout then
		call("deploy", "Close")
	end
	setMenu("Deploy", base == "Deploy")

	-- Round end / intermission
	if base == "RoundEnd" then
		if call("roundEnd", "GetView") ~= "Results" then
			call("roundEnd", "ShowResults", state.results, call("scorePopups", "GetRoundPoints"))
		end
	elseif base == "Intermission" then
		if call("roundEnd", "GetView") ~= "Intermission" then
			call("roundEnd", "ShowIntermission")
		end
	else
		call("roundEnd", "Hide")
	end
	setMenu("RoundEnd", base == "RoundEnd")
	setMenu("Intermission", base == "Intermission")

	if base ~= previous and base == "DeathCam" then
		task.delay(DEATH_CAM_TIME + 0.05, updateScreens)
	end
	refreshVisibility()
end

------------------------------------------------------------------------------------------------
-- Life cycle of the local character
------------------------------------------------------------------------------------------------

local charTrove = Trove.new()

local function evaluateLife()
	local alive = isAlive()
	local char = LOCAL_PLAYER.Character
	if alive and char and not state.deployed and GameState.get("Phase") == "InRound" then
		state.deployed = true
		if char ~= state.deployedCharacter then
			state.deployedCharacter = char
			call("hud", "SetCharacter", char)
			Bus.fire("Deployed", char)
		end
	elseif not alive and state.deployed then
		state.deployed = false
		state.deathCamUntil = os.clock() + DEATH_CAM_TIME
	end
	updateScreens()
end

local function onCharacter(char: Model?)
	charTrove:Clean()
	if not char then
		evaluateLife()
		return
	end
	task.spawn(function()
		local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
		if hum and hum:IsA("Humanoid") and char.Parent then
			charTrove:Add(hum.Died:Connect(evaluateLife))
			charTrove:Add(hum.HealthChanged:Connect(function(h)
				if h <= 0 then
					evaluateLife()
				end
			end))
		end
		evaluateLife()
	end)
end

------------------------------------------------------------------------------------------------
-- Progression
------------------------------------------------------------------------------------------------

local function checkLevelUp(level: number?)
	if type(level) ~= "number" then
		return
	end
	if state.lastLevel > 0 and level > state.lastLevel then
		call("notifications", "Banner", "PROMOTED", string.format("You have reached level %d", level), nil, 4)
		call("notifications", "Toast", string.format("Level %d — new equipment may be available", level), "info", 5)
	end
	state.lastLevel = math.max(state.lastLevel, level)
end

local function setProgression(data: any)
	if type(data) ~= "table" then
		return
	end
	state.progression = data
	checkLevelUp(tonumber(data.level))
	if call("roundEnd", "GetView") == "Results" then
		call("roundEnd", "RenderProgress", data)
	end
end

------------------------------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------------------------------

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if UserInputService:GetFocusedTextBox() then
		return
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.Tab then
		state.scoreboardHeld = true
		refreshVisibility()
		return
	elseif key == Enum.KeyCode.ButtonSelect then
		UIController.ToggleScoreboard()
		return
	end
	if gameProcessed then
		return
	end
	if key == Enum.KeyCode.M then
		UIController.ToggleMenu("BigMap")
	elseif key == Enum.KeyCode.P then
		UIController.ToggleMenu("Settings")
	elseif key == Enum.KeyCode.L then
		UIController.ToggleMenu("Loadout")
	elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
		if state.base == "Deploy" or openMenus.Loadout then
			call("deploy", "TryDeploy")
		end
	elseif key == Enum.KeyCode.Space then
		if call("deploy", "IsAwaitingRevive") then
			call("deploy", "DismissRevive")
		end
	elseif key == Enum.KeyCode.ButtonB or key == Enum.KeyCode.Backspace then
		for _, name in { "Settings", "BigMap", "Loadout" } do
			if openMenus[name] then
				UIController.CloseMenu(name)
				break
			end
		end
	end
end

local function onInputEnded(input: InputObject)
	if input.KeyCode == Enum.KeyCode.Tab then
		state.scoreboardHeld = false
		refreshVisibility()
	end
end

------------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------------

function UIController:Init()
	local playerGui = LOCAL_PLAYER:WaitForChild("PlayerGui")
	hideCoreGui()

	local okSettings, settings = pcall(function()
		return require(script.Parent:WaitForChild("SettingsController", 5) :: ModuleScript)
	end)
	if not okSettings or type(settings) ~= "table" then
		warn("[UI] SettingsController unavailable; using defaults")
		settings = SETTINGS_STUB
	end

	local fxGui = trove:Add(Theme.screenGui("WW2_FX", 2, false, playerGui))
	local hudGui = trove:Add(Theme.screenGui("WW2_HUD", 5, true, playerGui))
	local backdropGui = trove:Add(Theme.screenGui("WW2_Backdrop", 9, false, playerGui))
	local menuGui = trove:Add(Theme.screenGui("WW2_Menus", 10, true, playerGui))
	local overlayGui = trove:Add(Theme.screenGui("WW2_Overlay", 15, true, playerGui))

	local fxRoot, c1 = Theme.scaledRoot(fxGui)
	local hudRoot, c2 = Theme.scaledRoot(hudGui)
	local menuRoot, c3 = Theme.scaledRoot(menuGui)
	local overlayRoot, c4 = Theme.scaledRoot(overlayGui)
	trove:Add(c1)
	trove:Add(c2)
	trove:Add(c3)
	trove:Add(c4)

	ctx = {
		player = LOCAL_PLAYER,
		ui = UIController,
		settings = settings,
		isTouch = Theme.isTouch(),
		fxGui = fxGui,
		fxRoot = fxRoot,
		hudRoot = hudRoot,
		backdropRoot = backdropGui,
		menuRoot = menuRoot,
		overlayRoot = overlayRoot,
	}

	-- Order matters only for draw order inside a shared root (later = on top).
	components.hud = safeNew("HUD", ctx)
	components.minimap = safeNew("Minimap", ctx)
	components.compass = safeNew("Compass", ctx)
	components.objectives = safeNew("Objectives", ctx)
	components.killfeed = safeNew("Killfeed", ctx)
	components.scorePopups = safeNew("ScorePopups", ctx)
	components.damage = safeNew("DamageIndicator", ctx)
	components.scope = safeNew("ScopeOverlay", ctx)
	components.crosshair = safeNew("Crosshair", ctx)
	components.hitmarker = safeNew("Hitmarker", ctx)
	components.deploy = safeNew("DeployScreen", ctx)
	components.roundEnd = safeNew("RoundEnd", ctx)
	components.bigMap = safeNew("BigMap", ctx)
	components.settings = safeNew("SettingsMenu", ctx)
	components.scoreboard = safeNew("Scoreboard", ctx)
	components.notifications = safeNew("Notifications", ctx)
end

function UIController:Start()
	if not ctx then
		return
	end

	-- Game state
	trove:Add(GameState.changed("Phase"):Connect(function()
		local phase = GameState.get("Phase")
		if phase ~= "InRound" and phase ~= "PostRound" then
			state.results = nil -- debrief over
		end
		if phase == "InRound" then
			state.results = nil
			-- New round: everyone was despawned; deploy from scratch.
			state.deployed = false
			state.deathCamUntil = 0
			call("scorePopups", "ResetRound")
			call("deploy", "SetRespawnDelay", 0)
		end
		evaluateLife()
	end))

	-- Player state
	for _, attr in { "Alive", "Side" } do
		trove:Add(LOCAL_PLAYER:GetAttributeChangedSignal(attr):Connect(evaluateLife))
	end
	trove:Add(LOCAL_PLAYER:GetAttributeChangedSignal("VehicleUid"):Connect(refreshVisibility))
	trove:Add(LOCAL_PLAYER:GetAttributeChangedSignal("Level"):Connect(function()
		checkLevelUp(tonumber(LOCAL_PLAYER:GetAttribute("Level")))
	end))
	trove:Add(Bus.connect("VehicleEntered", refreshVisibility))
	trove:Add(Bus.connect("VehicleExited", refreshVisibility))
	trove:Add(LOCAL_PLAYER.CharacterAdded:Connect(onCharacter))
	trove:Add(LOCAL_PLAYER.CharacterRemoving:Connect(function()
		task.defer(evaluateLife)
	end))

	-- Settings fan-out
	trove:Add(Bus.connect("SettingsChanged", function()
		for _, c in components do
			if type(c.OnSettingsChanged) == "function" then
				pcall(c.OnSettingsChanged, c)
			end
		end
	end))

	-- Remotes
	Remotes.onEvent("Player_Died", function(payload)
		payload = type(payload) == "table" and payload or {}
		local respawn = tonumber(payload.respawnTime) or Constants.RESPAWN_TIME
		call("deploy", "SetDeathInfo", payload.killer, payload.weaponId, respawn)
		if state.deployed then
			state.deployed = false
		end
		state.deathCamUntil = os.clock() + DEATH_CAM_TIME
		updateScreens()
	end, trove)
	Remotes.onEvent("Spawn_Result", function(payload)
		payload = type(payload) == "table" and payload or {}
		call("deploy", "OnSpawnResult", payload.ok == true, payload.error)
		if payload.ok then
			evaluateLife()
		end
	end, trove)
	Remotes.onEvent("Round_Ended", function(payload)
		state.results = type(payload) == "table" and payload or {}
		call("roundEnd", "Hide") -- force a fresh render with the payload
		updateScreens()
	end, trove)
	Remotes.onEvent("Progression_Updated", setProgression, trove)

	-- Input
	trove:Add(UserInputService.InputBegan:Connect(onInputBegan))
	trove:Add(UserInputService.InputEnded:Connect(onInputEnded))

	-- Initial state
	onCharacter(LOCAL_PLAYER.Character)
	state.lastLevel = tonumber(LOCAL_PLAYER:GetAttribute("Level")) or 0
	updateScreens()

	task.spawn(function()
		local ok, data = Remotes.invoke("Progression_Get", 20)
		if ok then
			setProgression(data)
			if call("deploy", "IsOpen") then
				call("deploy", "Refresh")
			end
		end
	end)
end

return UIController
