--[[
	Objectives: top-centre match status.

	  [flag ALLIES tickets ▮▮▮▮]  (A)(B)(C)(D)(E)  [▮▮▮▮ tickets AXIS flag]
	                               12:34
	  * Chips show owner colour, capture progress (bar under the letter), contested blink, locked dim.
	  * Tickets (Conquest / Frontline) or kills vs score limit (TDM).
	  * Capture panel when the local character stands inside an objective radius (checked at 5 Hz).

	Event-driven from GameState attributes and per-objective attribute signals.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared.Config.GameModes)
local GameState = require(Shared.GameState)
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Data = require(UI.Data)
local Theme = require(UI.Theme)

local Objectives = {}
Objectives.__index = Objectives

local LOCAL_PLAYER = Players.LocalPlayer
local CHIP = 30

function Objectives.new(ctx)
	local self = setmetatable({}, Objectives)
	self.ctx = ctx
	self.trove = Trove.new()
	self.objTrove = Trove.new()
	self.visible = false
	self.chips = {} :: { [string]: any }
	self.current = nil :: Instance?

	local root = Theme.new("Frame", {
		Name = "Objectives",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 48),
		Size = UDim2.fromOffset(700, 64),
		Visible = false,
		Parent = ctx.hudRoot,
	})
	self.root = root

	self.teams = {
		Allies = self:_teamBlock("Allies", root),
		Axis = self:_teamBlock("Axis", root),
	}

	self.chipRow = Theme.new("Frame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(300, CHIP + 6),
		Parent = root,
	})
	Theme.list(self.chipRow, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center)

	self.timer = Theme.label({
		Kind = "number",
		Text = "0:00",
		TextSize = 20,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, CHIP + 8),
		Size = UDim2.fromOffset(120, 22),
		Parent = root,
	})
	self.tdmLabel = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 14,
		TextColor3 = Theme.Colors.TextDim,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(260, 20),
		Parent = root,
	})

	self:_buildCapturePanel()
	self:_connect()
	self:_rebuildChips()
	self:_renderScores()
	return self
end

------------------------------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------------------------------

function Objectives:_teamBlock(side: string, parent: Instance)
	local left = side == "Allies"
	local block = Theme.panel({
		Name = side,
		AnchorPoint = left and Vector2.new(0, 0) or Vector2.new(1, 0),
		Position = left and UDim2.fromScale(0, 0) or UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(186, 40),
		Style = "dark",
		Parent = parent,
	})
	local stroke = block:FindFirstChildOfClass("UIStroke")
	local flag = Theme.flag({
		AnchorPoint = left and Vector2.new(0, 0.5) or Vector2.new(1, 0.5),
		Position = left and UDim2.new(0, 6, 0.5, 0) or UDim2.new(1, -6, 0.5, 0),
		Size = UDim2.fromOffset(38, 26),
		Parent = block,
	}, nil)
	local name = Theme.label({
		Kind = "heading",
		Text = string.upper(side),
		TextSize = 13,
		TextColor3 = Theme.sideColor(side),
		TextXAlignment = left and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right,
		Position = left and UDim2.fromOffset(50, 2) or UDim2.fromOffset(8, 2),
		Size = UDim2.new(1, -58, 0, 14),
		Parent = block,
	})
	local value = Theme.label({
		Kind = "number",
		Text = "0",
		TextSize = 22,
		TextXAlignment = left and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left,
		Position = left and UDim2.new(0, 50, 0, 0) or UDim2.new(0, 8, 0, 0),
		Size = UDim2.new(1, -58, 0, 24),
		Parent = block,
	})
	local bar, fill = Theme.bar({
		Position = left and UDim2.new(0, 50, 1, -11) or UDim2.new(0, 8, 1, -11),
		Size = UDim2.new(1, -58, 0, 5),
	}, Theme.sideColor(side))
	bar.Parent = block
	if not left then
		fill.AnchorPoint = Vector2.new(1, 0)
		fill.Position = UDim2.fromScale(1, 0)
	end
	return { frame = block, flag = flag, name = name, value = value, fill = fill, stroke = stroke }
end

function Objectives:_buildCapturePanel()
	local panel = Theme.panel({
		Name = "Capture",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 122),
		Size = UDim2.fromOffset(300, 58),
		Style = "dark",
		Visible = false,
		Parent = self.ctx.hudRoot,
	})
	self.capChip = Theme.new("Frame", {
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.fromOffset(42, 42),
		BorderSizePixel = 0,
		Parent = panel,
	})
	Theme.round(self.capChip)
	Theme.stroke(self.capChip, Theme.Colors.Ink, 2, 0)
	self.capLetter = Theme.label({
		Kind = "title",
		Text = "",
		TextSize = 24,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = self.capChip,
	})
	self.capName = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(58, 6),
		Size = UDim2.new(1, -66, 0, 18),
		Parent = panel,
	})
	self.capStatus = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(58, 24),
		Size = UDim2.new(1, -66, 0, 14),
		Parent = panel,
	})
	local bar, fill = Theme.bar({
		Position = UDim2.new(0, 58, 0, 42),
		Size = UDim2.new(1, -68, 0, 7),
	}, Theme.Colors.Text)
	bar.Parent = panel
	self.capFill = fill
	self.capPanel = panel
end

function Objectives:_chip(obj: Instance)
	local frame = Theme.new("Frame", {
		Name = obj.Name,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(CHIP, CHIP + 6),
		Parent = self.chipRow,
	})
	local disc = Theme.new("Frame", {
		Size = UDim2.fromOffset(CHIP, CHIP),
		BorderSizePixel = 0,
		Parent = frame,
	})
	Theme.round(disc)
	local stroke = Theme.stroke(disc, Theme.Colors.Ink, 2, 0)
	Theme.label({
		Kind = "title",
		Text = obj.Name,
		TextSize = 18,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = disc,
	})
	local bar, fill = Theme.bar({
		Position = UDim2.new(0, 2, 1, -4),
		Size = UDim2.new(1, -4, 0, 4),
	}, Theme.Colors.Text)
	bar.Parent = frame
	return { frame = frame, disc = disc, stroke = stroke, bar = bar, fill = fill, obj = obj }
end

------------------------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------------------------

function Objectives:_connect()
	local t = self.trove
	for _, attr in
		{ "AlliesTickets", "AxisTickets", "AlliesScore", "AxisScore", "ModeId", "AlliesFaction", "AxisFaction" }
	do
		t:Add(GameState.changed(attr):Connect(function()
			self:_renderScores()
		end))
	end
	t:Add(GameState.changed("TimeLeft"):Connect(function()
		self.timer.Text = Theme.formatTime(GameState.get("TimeLeft"))
	end))
	t:Add(LOCAL_PLAYER:GetAttributeChangedSignal("Side"):Connect(function()
		self:_renderScores()
	end))
	local folder = GameState.objectives()
	t:Add(folder.ChildAdded:Connect(function()
		task.defer(function()
			self:_rebuildChips()
		end)
	end))
	t:Add(folder.ChildRemoved:Connect(function()
		self:_rebuildChips()
	end))

	-- Contested blink (2.5 Hz) + capture-zone check (5 Hz).
	local acc, blinkAcc = 0, 0
	t:Add(RunService.Heartbeat:Connect(function(dt)
		if not self.visible then
			return
		end
		blinkAcc += dt
		if blinkAcc >= 0.4 then
			blinkAcc = 0
			self.blinkOn = not self.blinkOn
			for _, chip in self.chips do
				if chip.obj:GetAttribute("Contested") == true then
					chip.stroke.Color = self.blinkOn and Theme.Colors.Danger or Theme.Colors.Text
				end
			end
		end
		acc += dt
		if acc >= 0.2 then
			acc = 0
			self:_checkCapture()
		end
	end))
end

function Objectives:_rebuildChips()
	self.objTrove:Clean()
	for _, chip in self.chips do
		chip.frame:Destroy()
	end
	self.chips = {}
	local list = GameState.objectives():GetChildren()
	table.sort(list, function(a, b)
		local oa, ob = tonumber(a:GetAttribute("Order")) or 0, tonumber(b:GetAttribute("Order")) or 0
		if oa ~= ob then
			return oa < ob
		end
		return a.Name < b.Name
	end)
	for i, obj in list do
		local chip = self:_chip(obj)
		chip.frame.LayoutOrder = i
		self.chips[obj.Name] = chip
		self.objTrove:Add(obj.AttributeChanged:Connect(function()
			self:_renderChip(chip)
		end))
		self:_renderChip(chip)
	end
	self.chipRow.Size = UDim2.fromOffset(math.max(#list, 1) * (CHIP + 6), CHIP + 6)
	self:_renderScores()
end

------------------------------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------------------------------

function Objectives:_renderChip(chip)
	local obj = chip.obj
	local owner = obj:GetAttribute("Owner") or "Neutral"
	local progress = tonumber(obj:GetAttribute("Progress")) or 0
	local locked = obj:GetAttribute("Locked") == true
	local contested = obj:GetAttribute("Contested") == true
	chip.disc.BackgroundColor3 = Theme.sideColor(owner)
	chip.disc.BackgroundTransparency = locked and 0.6 or 0
	if not contested then
		chip.stroke.Color = locked and Theme.Colors.Locked or Theme.Colors.Ink
	end
	local capturing = obj:GetAttribute("Capturing")
	local showBar = math.abs(progress) < 0.999 or (capturing ~= nil and capturing ~= "")
	chip.bar.Visible = showBar
	chip.fill.Size = UDim2.fromScale(math.clamp(math.abs(progress), 0, 1), 1)
	chip.fill.BackgroundColor3 = progress >= 0 and Theme.sideColor("Allies") or Theme.sideColor("Axis")
	if self.current == obj then
		self:_renderCapture(obj)
	end
end

function Objectives:_renderScores()
	local modeId = GameState.get("ModeId")
	local mode = GameModes.byId[modeId or ""]
	local tdm = mode ~= nil and not mode.usesObjectives
	local mySide = Data.localSide()
	self.chipRow.Visible = not tdm
	self.tdmLabel.Visible = tdm
	if tdm and mode then
		self.tdmLabel.Text = string.format("FIRST TO %d KILLS", mode.scoreLimit or 0)
	end
	for side, block in self.teams do
		Theme.setFlag(block.flag, GameState.get(side .. "Faction"))
		local f = Theme.faction(GameState.get(side .. "Faction"))
		block.name.Text = string.upper(f and f.name or side)
		local value, max
		if tdm then
			value = tonumber(GameState.get(side .. "Score")) or 0
			max = mode and mode.scoreLimit or 100
		else
			value = tonumber(GameState.get(side .. "Tickets")) or 0
			max = mode and mode.tickets or math.max(value, 1)
		end
		block.value.Text = tostring(math.floor(value))
		block.fill.Size = UDim2.fromScale(math.clamp(value / math.max(max, 1), 0, 1), 1)
		local mine = side == mySide
		block.stroke.Color = mine and Theme.Colors.Accent or Theme.Colors.Stroke
		block.stroke.Transparency = mine and 0 or 0.4
		block.stroke.Thickness = mine and 2 or 1
	end
	self.timer.Text = Theme.formatTime(GameState.get("TimeLeft"))
end

function Objectives:_checkCapture()
	local root = Data.rootPart(LOCAL_PLAYER)
	local found = nil
	if root and LOCAL_PLAYER:GetAttribute("Alive") ~= false and self.chipRow.Visible then
		for _, chip in self.chips do
			local pos = chip.obj:GetAttribute("Position")
			local radius = tonumber(chip.obj:GetAttribute("Radius")) or 0
			if typeof(pos) == "Vector3" and radius > 0 then
				local d = Vector3.new(pos.X - root.Position.X, 0, pos.Z - root.Position.Z).Magnitude
				if d <= radius then
					found = chip.obj
					break
				end
			end
		end
	end
	if found ~= self.current then
		self.current = found
		if found then
			self.capPanel.Visible = true
			self.capPanel.Position = UDim2.new(0.5, 0, 0, 132)
			Theme.tween(self.capPanel, 0.2, { Position = UDim2.new(0.5, 0, 0, 122) })
			self:_renderCapture(found)
		else
			self.capPanel.Visible = false
		end
	end
end

function Objectives:_renderCapture(obj: Instance)
	local mySide = Data.localSide()
	local owner = obj:GetAttribute("Owner") or "Neutral"
	local progress = tonumber(obj:GetAttribute("Progress")) or 0
	local capturing = obj:GetAttribute("Capturing") or ""
	local contested = obj:GetAttribute("Contested") == true
	local locked = obj:GetAttribute("Locked") == true
	self.capChip.BackgroundColor3 = Theme.sideColor(owner)
	self.capLetter.Text = obj.Name
	self.capName.Text = string.upper(tostring(obj:GetAttribute("DisplayName") or ("Objective " .. obj.Name)))
	self.capFill.Size = UDim2.fromScale(math.clamp(math.abs(progress), 0, 1), 1)
	self.capFill.BackgroundColor3 = progress >= 0 and Theme.sideColor("Allies") or Theme.sideColor("Axis")
	local status, color
	if locked then
		status, color = "LOCKED — PUSH THE FRONTLINE FIRST", Theme.Colors.TextDim
	elseif contested then
		status, color = "CONTESTED — CLEAR THE AREA", Theme.Colors.Danger
	elseif capturing == mySide then
		status, color = owner == mySide and "SECURING" or "CAPTURING", Theme.Colors.Accent
	elseif capturing ~= "" then
		status, color = "LOSING OBJECTIVE", Theme.Colors.Danger
	elseif owner == mySide then
		status, color = "SECURED — DEFEND THE POINT", Theme.Colors.Good
	else
		status, color = "HOLD TO CAPTURE", Theme.Colors.Text
	end
	self.capStatus.Text = status
	self.capStatus.TextColor3 = color
end

function Objectives:SetVisible(visible: boolean)
	self.visible = visible
	self.root.Visible = visible
	if not visible then
		self.capPanel.Visible = false
		self.current = nil
	else
		self:_renderScores()
	end
end

function Objectives:Destroy()
	self.trove:Clean()
	self.objTrove:Clean()
	self.root:Destroy()
	self.capPanel:Destroy()
end

return Objectives
