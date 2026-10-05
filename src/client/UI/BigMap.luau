--[[
	BigMap: full-screen tactical map (M key / map button). Reuses MapRenderer in "full" mode with a
	legend and the operation title. Markers refresh at ~10 Hz while open.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared.Config.GameModes)
local GameState = require(Shared.GameState)
local Maps = require(Shared.Config.Maps)

local UI = script.Parent
local MapRenderer = require(UI.MapRenderer)
local Theme = require(UI.Theme)

local BigMap = {}
BigMap.__index = BigMap

function BigMap.new(ctx)
	local self = setmetatable({}, BigMap)
	self.ctx = ctx
	self.visible = false

	local panel = Theme.panel({
		Name = "BigMap",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -120, 1, -80),
		Visible = false,
		Parent = ctx.menuRoot,
	})
	Theme.new("UISizeConstraint", { MaxSize = Vector2.new(1100, 820), Parent = panel })
	self.panel = panel

	self.title = Theme.label({
		Kind = "title",
		Text = "TACTICAL MAP",
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(18, 8),
		Size = UDim2.new(1, -140, 0, 34),
		Parent = panel,
	})
	self.subtitle = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 14,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(18, 40),
		Size = UDim2.new(1, -140, 0, 18),
		Parent = panel,
	})
	local close = Theme.button({
		Text = "CLOSE  [M]",
		TextSize = 15,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.fromOffset(110, 32),
		Parent = panel,
	})
	self.closeButton = close
	close.Activated:Connect(function()
		ctx.ui.CloseMenu("BigMap")
	end)

	local mapHolder = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 66),
		Size = UDim2.new(1, -32, 1, -112),
		Parent = panel,
	})
	self.renderer = MapRenderer.new(mapHolder, { mode = "full", showLabels = true })

	-- Legend
	local legend = Theme.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 18, 1, -10),
		Size = UDim2.new(1, -36, 0, 26),
		Parent = panel,
	})
	Theme.list(legend, Enum.FillDirection.Horizontal, 18, nil, Enum.VerticalAlignment.Center)
	local function legendItem(color: Color3, text: string, diamond: boolean?): Frame
		local item =
			Theme.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(120, 20), Parent = legend })
		local dot = Theme.new("Frame", {
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(10, 10),
			Position = UDim2.fromOffset(2, 5),
			Rotation = diamond and 45 or 0,
			Parent = item,
		})
		if not diamond then
			Theme.round(dot)
		end
		local _ = Theme.label({
			Kind = "bold",
			Text = text,
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(18, 0),
			Size = UDim2.new(1, -18, 1, 0),
			Parent = item,
		})
		return dot
	end
	legendItem(Theme.Colors.Accent, "YOU")
	legendItem(Theme.Colors.Squad, "SQUAD")
	self.friendlyDot = legendItem(Theme.sideColor("Allies"), "FRIENDLY")
	legendItem(Theme.Colors.Danger, "SPOTTED ENEMY", true)
	self.legend = legend

	local acc = 0
	self.conn = RunService.Heartbeat:Connect(function(dt)
		if not self.visible then
			return
		end
		acc += dt
		if acc >= 0.1 then
			acc = 0
			self.renderer:Refresh()
		end
	end)
	return self
end

function BigMap:_updateTitle()
	local map = Maps.byId[GameState.get("MapId") or ""]
	local mode = GameModes.byId[GameState.get("ModeId") or ""]
	self.title.Text = map and string.upper(map.name) or "TACTICAL MAP"
	local parts = {}
	if mode then
		table.insert(parts, string.upper(mode.name))
	end
	if map then
		table.insert(parts, string.upper(map.theater .. " THEATRE"))
	end
	self.subtitle.Text = table.concat(parts, "  ·  ")
	local side = self.ctx.player:GetAttribute("Side")
	self.friendlyDot.BackgroundColor3 = Theme.sideColor(side ~= "" and side or "Allies")
end

function BigMap:SetVisible(visible: boolean)
	self.visible = visible
	self.panel.Visible = visible
	if visible then
		self:_updateTitle()
		self.renderer:Refresh()
		Theme.selectForGamepad(self.closeButton)
	end
end

function BigMap:Destroy()
	self.conn:Disconnect()
	self.renderer:Destroy()
	self.panel:Destroy()
end

return BigMap
