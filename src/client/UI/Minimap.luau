--[[
	Minimap: circular player-centred tactical map (bottom-left on PC, top-left on touch devices so
	it does not collide with the thumbstick). Rotates with the camera or stays north-up
	(SettingsController "MinimapRotate", toggled by the small button on its rim).

	Markers refresh at ~15 Hz; the view (centre + rotation) is updated every frame while visible.
]]

local RunService = game:GetService("RunService")

local UI = script.Parent
local MapRenderer = require(UI.MapRenderer)
local Theme = require(UI.Theme)

local Minimap = {}
Minimap.__index = Minimap

local SIZE = 200
local REFRESH_INTERVAL = 1 / 15

function Minimap.new(ctx)
	local self = setmetatable({}, Minimap)
	self.ctx = ctx
	self.visible = false

	local touch = ctx.isTouch
	local holder = Theme.new("Frame", {
		Name = "Minimap",
		BackgroundTransparency = 1,
		AnchorPoint = touch and Vector2.new(0, 0) or Vector2.new(0, 1),
		Position = touch and UDim2.fromOffset(16, 16) or UDim2.new(0, 18, 1, -64),
		Size = UDim2.fromOffset(SIZE, SIZE),
		Visible = false,
		Parent = ctx.hudRoot,
	})
	self.holder = holder

	-- Outer bezel ring.
	local bezel = Theme.new("Frame", {
		Name = "Bezel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 8, 1, 8),
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Parent = holder,
	})
	Theme.round(bezel)
	Theme.stroke(bezel, Theme.Colors.KhakiDark, 2, 0.2)
	Theme.grain(bezel)

	local mapHolder = Theme.new("Frame", {
		Name = "Map",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = holder,
	})
	self.renderer = MapRenderer.new(mapHolder, {
		mode = "mini",
		rangeStuds = 220,
		size = SIZE,
		rotate = ctx.settings.Get("MinimapRotate") ~= false,
	})

	-- North indicator orbiting the rim.
	self.northPivot = Theme.new("Frame", {
		Name = "NorthPivot",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		ZIndex = 10,
		Parent = holder,
	})
	local north = Theme.new("Frame", {
		Name = "North",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(0, -SIZE / 2 - 2),
		Size = UDim2.fromOffset(20, 20),
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
		ZIndex = 10,
		Parent = self.northPivot,
	})
	Theme.round(north)
	Theme.stroke(north, Theme.Colors.Ink, 1, 0)
	self.northLabel = Theme.label({
		Kind = "title",
		Text = "N",
		TextSize = 13,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 11,
		Parent = north,
	})

	-- Rotate / north-up toggle.
	local toggle = Theme.button({
		Name = "RotateToggle",
		Text = "ROT",
		TextSize = 11,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 6, 1, 6),
		Size = UDim2.fromOffset(34, 20),
		ZIndex = 12,
		Variant = "ghost",
		Parent = holder,
	})
	self.toggle = toggle
	toggle.Activated:Connect(function()
		local now = ctx.settings.Get("MinimapRotate") ~= false
		ctx.settings.Set("MinimapRotate", not now)
	end)
	self:_applyRotateSetting()

	local acc = REFRESH_INTERVAL
	self.conn = RunService.RenderStepped:Connect(function(dt)
		if not self.visible then
			return
		end
		acc += dt
		if acc >= REFRESH_INTERVAL then
			acc = 0
			self.renderer:Refresh()
		end
		self.renderer:UpdateView()
		local rot = self.renderer.pivot.Rotation
		if self.northPivot.Rotation ~= rot then
			self.northPivot.Rotation = rot
			self.northLabel.Rotation = -rot
		end
	end)
	return self
end

function Minimap:_applyRotateSetting()
	local rotate = self.ctx.settings.Get("MinimapRotate") ~= false
	self.renderer:SetRotate(rotate)
	self.toggle.Text = rotate and "ROT" or "N-UP"
end

function Minimap:OnSettingsChanged()
	self:_applyRotateSetting()
end

function Minimap:SetVisible(visible: boolean)
	self.visible = visible
	self.holder.Visible = visible
end

function Minimap:Destroy()
	self.conn:Disconnect()
	self.renderer:Destroy()
	self.holder:Destroy()
end

return Minimap
