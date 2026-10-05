--[[
	DeployScreen: join / respawn / loadout screen.

	  ┌ top bar: title · map & mode · level dog-tag · gear ─────────────────────────────┐
	  │ FACTION (Allies/Axis/Auto)  │ LOADOUT (class name, 4 slots,   │ SPAWN MAP          │
	  │ CLASS list                  │ weapon list + stat bars)        │ spawn list, DEPLOY │
	  └──────────────────────────────────────────────────────────────────────────────────┘

	Modes:
	  "deploy" -- normal (on join / after death): respawn countdown, spawn selection, DEPLOY.
	  "edit"   -- opened with L while alive: change class/loadout for the next deploy only.
	Revive overlay: while the `Revivable` player attribute (server-time deadline) is in the future
	a "WOUNDED — WAITING FOR MEDIC" overlay covers the screen with a GIVE UP button (local only:
	deploying normally forfeits the revive on the server).

	Remotes: Team_Request (team buttons), Spawn_GetOptions (polled every 2.5 s while open; falls back
	to HQ + owned objectives from GameState), Spawn_Request via ctx.ui.RequestDeploy.
	Last class / loadout per class are remembered in settings ("LastClass" / "Loadouts").
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Classes = require(Shared.Config.Classes)
local Factions = require(Shared.Config.Factions)
local GameModes = require(Shared.Config.GameModes)
local GameState = require(Shared.GameState)
local Maps = require(Shared.Config.Maps)
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local ClassSelect = require(UI.ClassSelect)
local Data = require(UI.Data)
local Loadout = require(UI.Loadout)
local MapRenderer = require(UI.MapRenderer)
local Remotes = require(UI.Remotes)
local Theme = require(UI.Theme)

local DeployScreen = {}
DeployScreen.__index = DeployScreen

local LOCAL_PLAYER = Players.LocalPlayer
local OPTIONS_INTERVAL = 2.5

function DeployScreen.new(ctx)
	local self = setmetatable({}, DeployScreen)
	self.ctx = ctx
	self.trove = Trove.new()
	self.visible = false
	self.mode = "deploy"
	self.respawnAt = 0 -- os.clock() time when deploying becomes possible
	self.pending = false
	self.spawnOptions = {} :: { any }
	self.spawnId = "HQ"
	self.classId = "Rifleman"
	self.error = ""
	self.reviveDismissed = false

	-- Dimmed backdrop over the world (full-screen gui).
	self.backdrop = Theme.new("Frame", {
		Name = "DeployBackdrop",
		BackgroundColor3 = Theme.Colors.Ink,
		BackgroundTransparency = 0.18,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = ctx.backdropRoot,
	})
	Theme.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Theme.Colors.PanelDark, Theme.Colors.Ink),
		Parent = self.backdrop,
	})

	local root = Theme.new("Frame", {
		Name = "Deploy",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = ctx.menuRoot,
	})
	self.root = root
	Theme.padding(root, 14, 18)

	self:_buildTopBar()
	local body = Theme.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 62),
		Size = UDim2.new(1, 0, 1, -62),
		Parent = root,
	})
	self:_buildLeft(body)
	self:_buildMiddle(body)
	self:_buildRight(body)
	self:_buildRevive()

	-- Live updates while open: countdown text (10 Hz) and spawn options polling.
	local acc, optAcc = 0, OPTIONS_INTERVAL
	self.trove:Add(RunService.Heartbeat:Connect(function(dt)
		if not self.visible then
			return
		end
		acc += dt
		optAcc += dt
		if acc >= 0.1 then
			acc = 0
			self:_renderDeployButton()
			self:_renderRevive()
			self.mapRenderer:Refresh()
		end
		if optAcc >= OPTIONS_INTERVAL and self.mode == "deploy" then
			optAcc = 0
			self:_pollSpawnOptions()
		end
	end))
	for _, attr in { "Side", "Faction", "Level" } do
		self.trove:Add(LOCAL_PLAYER:GetAttributeChangedSignal(attr):Connect(function()
			if self.visible then
				self:Refresh()
			end
		end))
	end
	self.trove:Add(LOCAL_PLAYER:GetAttributeChangedSignal("Revivable"):Connect(function()
		self.reviveDismissed = false
		self:_renderRevive()
	end))
	return self
end

------------------------------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------------------------------

function DeployScreen:_buildTopBar()
	local bar = Theme.panel({
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, 52),
		Style = "dark",
		Parent = self.root,
	})
	Theme.label({
		Kind = "title",
		Text = "WW2 FRONTLINES",
		TextSize = 26,
		TextColor3 = Theme.Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.fromOffset(220, 52),
		Parent = bar,
	})
	self.screenTitle = Theme.label({
		Kind = "type",
		Text = "DEPLOYMENT ORDERS",
		TextSize = 14,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(236, 0),
		Size = UDim2.fromOffset(200, 52),
		Parent = bar,
	})
	self.mapTitle = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 18,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 40, 0, 4),
		Size = UDim2.fromOffset(360, 24),
		Parent = bar,
	})
	self.modeTitle = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 13,
		TextColor3 = Theme.Colors.Khaki,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 40, 0, 28),
		Size = UDim2.fromOffset(360, 18),
		Parent = bar,
	})
	-- Dog tag with level
	local tag = Theme.new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -62, 0.5, 0),
		Size = UDim2.fromOffset(150, 36),
		BackgroundColor3 = Color3.fromRGB(176, 178, 170),
		BorderSizePixel = 0,
		Parent = bar,
	})
	Theme.corner(tag, 10)
	Theme.stroke(tag, Theme.Colors.Ink, 1, 0.3)
	Theme.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(170, 170, 165)),
		Parent = tag,
	})
	self.tagName = Theme.label({
		Kind = "type",
		Text = string.upper(LOCAL_PLAYER.DisplayName),
		TextSize = 12,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(10, 2),
		Size = UDim2.new(1, -20, 0, 16),
		Parent = tag,
	})
	self.tagLevel = Theme.label({
		Kind = "type",
		Text = "LVL 1",
		TextSize = 12,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		Position = UDim2.fromOffset(10, 17),
		Size = UDim2.new(1, -20, 0, 16),
		Parent = tag,
	})
	local gear = Theme.button({
		Text = "⚙",
		FontFace = Theme.Fonts.Glyph,
		TextSize = 22,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(42, 36),
		Variant = "ghost",
		Parent = bar,
	})
	gear.Activated:Connect(function()
		self.ctx.ui.OpenMenu("Settings")
	end)
end

function DeployScreen:_buildLeft(body: Frame)
	local col = Theme.panel({
		Name = "Left",
		Size = UDim2.new(0.25, -8, 1, 0),
		Parent = body,
	})
	Theme.padding(col, 10)
	Theme.header("Faction", { Parent = col })

	local teams = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 112),
		Parent = col,
	})
	Theme.list(teams, Enum.FillDirection.Vertical, 4)
	self.teamButtons = {}
	for i, side in { "Allies", "Axis", "Auto" } do
		local btn = Theme.button({
			Name = side,
			Text = "",
			Size = UDim2.new(1, 0, 0, side == "Auto" and 28 or 38),
			LayoutOrder = i,
			Parent = teams,
		})
		local flag
		if side ~= "Auto" then
			flag = Theme.flag({
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 6, 0.5, 0),
				Size = UDim2.fromOffset(36, 24),
				Parent = btn,
			}, nil)
		end
		local name = Theme.label({
			Kind = "heading",
			Text = side == "Auto" and "AUTO-ASSIGN" or string.upper(side),
			TextSize = side == "Auto" and 14 or 16,
			TextColor3 = side == "Auto" and Theme.Colors.Text or Theme.sideColor(side),
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(side == "Auto" and 10 or 50, side == "Auto" and 0 or 2),
			Size = UDim2.new(1, -110, side == "Auto" and 1 or 0, side == "Auto" and 0 or 18),
			Parent = btn,
		})
		local sub = Theme.label({
			Kind = "body",
			Text = "",
			TextSize = 12,
			TextColor3 = Theme.Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(50, 19),
			Size = UDim2.new(1, -110, 0, 16),
			Visible = side ~= "Auto",
			Parent = btn,
		})
		local count = Theme.label({
			Kind = "number",
			Text = "",
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 0),
			Size = UDim2.new(0, 50, 1, 0),
			Parent = btn,
		})
		btn.Activated:Connect(function()
			Remotes.fire("Team_Request", { side = side })
		end)
		self.teamButtons[side] = { button = btn, flag = flag, name = name, sub = sub, count = count }
	end

	Theme.header("Class", { Position = UDim2.fromOffset(0, 150), Parent = col })
	local classHolder = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 180),
		Size = UDim2.new(1, 0, 1, -180),
		Parent = col,
	})
	self.classSelect = ClassSelect.new(classHolder, function(classId)
		self:_selectClass(classId)
	end)
end

function DeployScreen:_buildMiddle(body: Frame)
	local col = Theme.panel({
		Name = "Middle",
		Position = UDim2.fromScale(0.25, 0),
		Size = UDim2.new(0.36, -8, 1, 0),
		Parent = body,
	})
	Theme.padding(col, 10)
	self.loadout = Loadout.new(col, function(loadout)
		self:_rememberLoadout(loadout)
	end)
end

function DeployScreen:_buildRight(body: Frame)
	local col = Theme.panel({
		Name = "Right",
		Position = UDim2.fromScale(0.61, 0),
		Size = UDim2.fromScale(0.39, 1),
		Parent = body,
	})
	Theme.padding(col, 10)
	self.rightCol = col

	-- Death card ("Killed in action")
	local death = Theme.new("Frame", {
		Name = "DeathCard",
		BackgroundColor3 = Color3.fromRGB(70, 22, 18),
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 46),
		Visible = false,
		Parent = col,
	})
	Theme.corner(death, 3)
	Theme.stroke(death, Theme.Colors.Danger, 1, 0.3)
	Theme.label({
		Kind = "title",
		Text = "KILLED IN ACTION",
		TextSize = 16,
		TextColor3 = Theme.Colors.Danger,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(10, 2),
		Size = UDim2.new(1, -20, 0, 20),
		Parent = death,
	})
	self.deathText = Theme.label({
		Kind = "bold",
		Text = "",
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(10, 22),
		Size = UDim2.new(1, -20, 0, 20),
		Parent = death,
	})
	self.deathCard = death

	self.spawnHeader = Theme.header("Spawn point", { Position = UDim2.fromOffset(0, 0), Parent = col })
	local mapHolder = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 1, -30 - 40 - 110),
		Parent = col,
	})
	self.mapHolder = mapHolder
	self.mapRenderer = MapRenderer.new(mapHolder, { mode = "full", showLabels = true })

	local spawnList = Theme.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -110),
		Size = UDim2.new(1, 0, 0, 36),
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollBarThickness = 3,
		ScrollingDirection = Enum.ScrollingDirection.X,
		Parent = col,
	})
	Theme.list(spawnList, Enum.FillDirection.Horizontal, 4, nil, Enum.VerticalAlignment.Center)
	self.spawnList = spawnList
	self.spawnListButtons = {} :: { [string]: TextButton }

	self.errorLabel = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 13,
		TextColor3 = Theme.Colors.Danger,
		TextWrapped = true,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -70),
		Size = UDim2.new(1, 0, 0, 34),
		Parent = col,
	})
	local deploy = Theme.button({
		Name = "Deploy",
		Text = "DEPLOY",
		TextSize = 26,
		FontFace = Theme.Fonts.Title,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 62),
		Variant = "primary",
		Parent = col,
	})
	deploy.Activated:Connect(function()
		self:TryDeploy()
	end)
	self.deployButton = deploy
end

function DeployScreen:_buildRevive()
	local overlay = Theme.new("Frame", {
		Name = "Revive",
		BackgroundColor3 = Color3.fromRGB(40, 6, 4),
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 20,
		Parent = self.ctx.overlayRoot,
	})
	Theme.label({
		Kind = "title",
		Text = "WOUNDED",
		TextSize = 54,
		TextColor3 = Theme.Colors.Danger,
		TextStrokeTransparency = 0.3,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromOffset(600, 60),
		ZIndex = 21,
		Parent = overlay,
	})
	Theme.label({
		Kind = "type",
		Text = "Hold on, soldier — a medic is on the way.",
		TextSize = 18,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.44),
		Size = UDim2.fromOffset(600, 24),
		ZIndex = 21,
		Parent = overlay,
	})
	self.reviveCount = Theme.label({
		Kind = "number",
		Text = "",
		TextSize = 40,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(200, 44),
		ZIndex = 21,
		Parent = overlay,
	})
	local giveUp = Theme.button({
		Text = "GIVE UP  [SPACE]",
		TextSize = 18,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromOffset(220, 44),
		Variant = "danger",
		ZIndex = 21,
		Parent = overlay,
	})
	giveUp.Activated:Connect(function()
		self:DismissRevive()
	end)
	self.giveUpButton = giveUp
	self.reviveOverlay = overlay
end

------------------------------------------------------------------------------------------------
-- State
------------------------------------------------------------------------------------------------

function DeployScreen:_level(): number
	return math.max(1, tonumber(LOCAL_PLAYER:GetAttribute("Level")) or 1)
end

function DeployScreen:_faction(): string?
	local f = LOCAL_PLAYER:GetAttribute("Faction")
	if type(f) == "string" and f ~= "" then
		return f
	end
	return Data.factionForSide(Data.localSide())
end

function DeployScreen:_rememberLoadout(loadout: { [string]: string })
	local settings = self.ctx.settings
	local all = table.clone(settings.Get("Loadouts") or {})
	all[self.classId] = loadout
	settings.Set("Loadouts", all)
end

function DeployScreen:_selectClass(classId: string)
	if not Classes.byId[classId] then
		classId = "Rifleman"
	end
	self.classId = classId
	self.classSelect:SetSelected(classId)
	local remembered = (self.ctx.settings.Get("Loadouts") or {})[classId]
	self.loadout:SetContext(classId, self:_faction(), self:_level(), self.ctx.ui.GetUnlocked(), remembered)
	self.ctx.settings.Set("LastClass", classId)
end

-- Rebuilds everything that depends on side / faction / level / round.
function DeployScreen:Refresh()
	local level = self:_level()
	self.classSelect:SetLevel(level)
	self.tagLevel.Text = "LVL " .. tostring(level)
	local last = self.ctx.settings.Get("LastClass")
	local classId = self.classSelect:IsUnlocked(last) and last or "Rifleman"
	self:_selectClass(classId)

	local map = Maps.byId[GameState.get("MapId") or ""]
	local mode = GameModes.byId[GameState.get("ModeId") or ""]
	self.mapTitle.Text = map and string.upper(map.name) or "AWAITING ORDERS"
	self.modeTitle.Text = (mode and string.upper(mode.name) or "")
		.. (map and ("  ·  " .. string.upper(map.environment)) or "")
	self.screenTitle.Text = self.mode == "edit" and "CHANGE LOADOUT" or "DEPLOYMENT ORDERS"
	self:_renderTeams()
	self.mapRenderer:SetMapInfo(Data.mapInfo())
	self:_renderSpawns()
	self:_renderDeployButton()
end

function DeployScreen:_renderTeams()
	local mySide = Data.localSide()
	local counts = { Allies = 0, Axis = 0 }
	for _, p in Players:GetPlayers() do
		local s = p:GetAttribute("Side")
		if counts[s] then
			counts[s] += 1
		end
	end
	for side, t in self.teamButtons do
		if side ~= "Auto" then
			local factionId = GameState.get(side .. "Faction")
			Theme.setFlag(t.flag, factionId)
			local f = Factions.byId[factionId or ""]
			t.sub.Text = f and f.name or ""
			t.count.Text = tostring(counts[side])
		end
		local selected = side == mySide
		Theme.setButtonColor(t.button, selected and Theme.Colors.Olive or Theme.Colors.PanelLight)
		local stroke = t.button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = selected and Theme.Colors.Accent or Theme.Colors.Stroke
			stroke.Transparency = selected and 0 or 0.3
		end
	end
end

------------------------------------------------------------------------------------------------
-- Spawn options
------------------------------------------------------------------------------------------------

-- Fallback when Spawn_GetOptions is unavailable: HQ + objectives owned by our side.
local function fallbackOptions(): { any }
	local side = Data.localSide()
	local options = {}
	local info = Data.mapInfo()
	if info and info.hq[side] then
		local hq = info.hq[side]
		table.insert(options, {
			id = "HQ",
			name = "Headquarters",
			position = Vector3.new(hq.x, 0, hq.z),
			kind = "HQ",
			available = true,
		})
	end
	for _, obj in GameState.objectives():GetChildren() do
		local pos = obj:GetAttribute("Position")
		if typeof(pos) == "Vector3" and obj:GetAttribute("Owner") == side then
			table.insert(options, {
				id = obj.Name,
				name = tostring(obj:GetAttribute("DisplayName") or obj.Name),
				position = pos,
				kind = "Objective",
				available = obj:GetAttribute("Contested") ~= true,
			})
		end
	end
	return options
end

function DeployScreen:_pollSpawnOptions()
	if self.polling then
		return
	end
	self.polling = true
	task.spawn(function()
		local ok, result = Remotes.invoke("Spawn_GetOptions", 5)
		self.polling = false
		if ok and type(result) == "table" then
			self.spawnOptions = result
		else
			self.spawnOptions = fallbackOptions()
		end
		self:_renderSpawns()
	end)
end

function DeployScreen:_selectSpawn(id: string)
	self.spawnId = id
	self.error = ""
	self:_renderSpawns()
end

function DeployScreen:_renderSpawns()
	local options = self.spawnOptions
	-- Keep the current selection if still available, else first available (prefer HQ).
	local selectedOk = false
	for _, opt in options do
		if opt.id == self.spawnId and opt.available ~= false then
			selectedOk = true
		end
	end
	if not selectedOk then
		for _, opt in options do
			if opt.available ~= false then
				self.spawnId = opt.id
				break
			end
		end
	end
	self.mapRenderer:SetSpawnOptions(options, self.spawnId, function(id)
		self:_selectSpawn(id)
	end)

	local keep = {}
	for i, opt in options do
		if type(opt) == "table" and type(opt.id) == "string" then
			keep[opt.id] = true
			local btn = self.spawnListButtons[opt.id]
			if not btn then
				btn = Theme.button({
					Text = "",
					TextSize = 13,
					AutomaticSize = Enum.AutomaticSize.X,
					Size = UDim2.fromOffset(60, 30),
					Variant = "ghost",
					Parent = self.spawnList,
				})
				Theme.padding(btn, 0, 10)
				local id = opt.id
				btn.Activated:Connect(function()
					if btn:GetAttribute("Available") then
						self:_selectSpawn(id)
					end
				end)
				self.spawnListButtons[opt.id] = btn
			end
			btn.LayoutOrder = i
			btn.Text = string.upper(
				opt.kind == "Objective" and (opt.id .. " · " .. tostring(opt.name)) or tostring(opt.name or opt.id)
			)
			btn:SetAttribute("Available", opt.available ~= false)
			btn.TextColor3 = opt.available == false and Theme.Colors.TextDim or Theme.Colors.Text
			Theme.setButtonColor(btn, opt.id == self.spawnId and Theme.Colors.Olive or Theme.Colors.PanelDark)
			btn.Visible = true
		end
	end
	for id, btn in self.spawnListButtons do
		if not keep[id] then
			btn.Visible = false
		end
	end
end

------------------------------------------------------------------------------------------------
-- Deploy
------------------------------------------------------------------------------------------------

function DeployScreen:_deployState(): (boolean, string)
	if self.mode == "edit" then
		return true, "CONFIRM LOADOUT"
	end
	if self.pending then
		return false, "DEPLOYING…"
	end
	if Data.localSide() == "" then
		return false, "SELECT A FACTION"
	end
	if GameState.get("Phase") ~= "InRound" then
		return false, "AWAITING ROUND START"
	end
	local left = self.respawnAt - os.clock()
	if left > 0 then
		return false, string.format("DEPLOY IN %d", math.ceil(left))
	end
	local key = self.ctx.isTouch and "" or "  [ENTER]"
	return true, "DEPLOY" .. key
end

function DeployScreen:_renderDeployButton()
	local ok, text = self:_deployState()
	self.deployButton.Text = text
	self.deployButton.AutoButtonColor = false
	Theme.setButtonColor(self.deployButton, ok and Theme.Colors.Accent or Theme.Colors.KhakiDark)
	self.deployButton.TextTransparency = ok and 0 or 0.25
	self.errorLabel.Text = self.error
end

function DeployScreen:TryDeploy()
	local ok = self:_deployState()
	if not ok then
		return
	end
	local loadout = self.loadout:Get()
	self:_rememberLoadout(loadout)
	if self.mode == "edit" then
		self.ctx.settings.Save()
		self.ctx.ui.CloseMenu("Loadout")
		return
	end
	self.pending = true
	self.error = ""
	self.ctx.ui.RequestDeploy(self.classId, loadout, self.spawnId)
	-- Safety: re-enable if the server never answers.
	task.delay(8, function()
		self.pending = false
	end)
end

-- Spawn_Result {ok, error?}
function DeployScreen:OnSpawnResult(ok: boolean, err: string?)
	self.pending = false
	if not ok then
		self.error = string.upper(err or "DEPLOYMENT FAILED")
		self:_pollSpawnOptions()
	end
	self:_renderDeployButton()
end

-- Player_Died {killer?, weaponId?, respawnTime}
function DeployScreen:SetDeathInfo(killer: any, weaponId: string?, respawnTime: number?)
	self.respawnAt = os.clock() + (respawnTime or 0)
	self.pending = false
	if typeof(killer) == "Instance" and killer:IsA("Player") and killer ~= LOCAL_PLAYER then
		self.deathText.Text =
			string.format("by %s  ·  %s", killer.DisplayName, string.upper(Data.weaponName(weaponId)))
	elseif weaponId then
		self.deathText.Text = string.upper(Data.weaponName(weaponId))
	else
		self.deathText.Text = "Casualty of war."
	end
	self.showDeath = true
end

function DeployScreen:SetRespawnDelay(seconds: number)
	self.respawnAt = os.clock() + seconds
end

------------------------------------------------------------------------------------------------
-- Revive overlay
------------------------------------------------------------------------------------------------

function DeployScreen:IsAwaitingRevive(): boolean
	if self.reviveDismissed or self.mode ~= "deploy" then
		return false
	end
	local deadline = LOCAL_PLAYER:GetAttribute("Revivable")
	return LOCAL_PLAYER:GetAttribute("Alive") ~= true
		and type(deadline) == "number"
		and deadline > Workspace:GetServerTimeNow()
end

function DeployScreen:DismissRevive()
	self.reviveDismissed = true
	self:_renderRevive()
end

function DeployScreen:_renderRevive()
	local show = self.visible and self:IsAwaitingRevive()
	if show then
		local deadline = LOCAL_PLAYER:GetAttribute("Revivable")
		self.reviveCount.Text = tostring(math.ceil(math.max(0, deadline - Workspace:GetServerTimeNow())))
		if not self.reviveOverlay.Visible then
			Theme.selectForGamepad(self.giveUpButton)
		end
	end
	self.reviveOverlay.Visible = show
	self.root.Visible = self.visible and not show
	self.backdrop.Visible = self.visible and not show
end

------------------------------------------------------------------------------------------------
-- Visibility
------------------------------------------------------------------------------------------------

function DeployScreen:Open(mode: "deploy" | "edit")
	self.mode = mode
	self.visible = true
	self.error = ""
	self.deathCard.Visible = mode == "deploy" and self.showDeath == true
	local deathOffset = self.deathCard.Visible and 54 or 0
	self.spawnHeader.Position = UDim2.fromOffset(0, deathOffset)
	self.mapHolder.Position = UDim2.fromOffset(0, 30 + deathOffset)
	self.mapHolder.Size = UDim2.new(1, 0, 1, -30 - 40 - 110 - deathOffset)
	self.spawnHeader.Visible = mode == "deploy"
	self.mapHolder.Visible = mode == "deploy"
	self.spawnList.Visible = mode == "deploy"
	self.root.Visible = true
	self.backdrop.Visible = true
	self:Refresh()
	if mode == "deploy" then
		self.spawnOptions = fallbackOptions()
		self:_renderSpawns()
		self:_pollSpawnOptions()
	end
	self:_renderRevive()
	Theme.selectForGamepad(self.deployButton)
end

function DeployScreen:Close()
	self.visible = false
	self.root.Visible = false
	self.backdrop.Visible = false
	self.reviveOverlay.Visible = false
	self.pending = false
	self.showDeath = false
end

function DeployScreen:IsOpen(): boolean
	return self.visible
end

function DeployScreen:GetMode(): string
	return self.mode
end

function DeployScreen:Destroy()
	self.trove:Clean()
	self.loadout:Destroy()
	self.mapRenderer:Destroy()
	self.root:Destroy()
	self.backdrop:Destroy()
	self.reviveOverlay:Destroy()
end

return DeployScreen
