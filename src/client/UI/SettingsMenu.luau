--[[
	SettingsMenu (P key / gear button): one row per SettingsController.Schema entry, grouped by
	category. Sliders (drag, or -/+ buttons for touch & gamepad), toggles and option cyclers.
	Changes apply live through SettingsController.Set; "SAVE & CLOSE" persists immediately.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Theme = require(UI.Theme)

local SettingsMenu = {}
SettingsMenu.__index = SettingsMenu

local ROW_HEIGHT = 40
local CATEGORY_ORDER = { "Controls", "Audio", "Video", "Interface" }

local function formatValue(def, value): string
	if def.kind == "slider" then
		if def.percent then
			return string.format("%d%%", math.floor(value * 100 + 0.5))
		elseif (def.step or 1) >= 1 then
			return tostring(math.floor(value + 0.5))
		end
		return string.format("%.2f", value)
	elseif def.kind == "toggle" then
		return value and "ON" or "OFF"
	elseif def.kind == "choice" then
		local labels = def.optionLabels
		if labels then
			local idx = table.find(def.options, value)
			if idx and labels[idx] then
				return labels[idx]
			end
		end
		return string.upper(tostring(value))
	end
	return tostring(value)
end

function SettingsMenu.new(ctx)
	local self = setmetatable({}, SettingsMenu)
	self.ctx = ctx
	self.trove = Trove.new()
	self.rows = {} :: { [string]: any }
	self.dragging = nil :: any

	local panel = Theme.panel({
		Name = "Settings",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(0, 680, 1, -90),
		Visible = false,
		ZIndex = 45, -- stacks above the deploy screen and the store (ZIndex 40)
		Parent = ctx.menuRoot,
	})
	Theme.new("UISizeConstraint", { MaxSize = Vector2.new(680, 640), Parent = panel })
	self.panel = panel

	Theme.label({
		Kind = "title",
		Text = "FIELD SETTINGS",
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(20, 10),
		Size = UDim2.new(1, -40, 0, 34),
		Parent = panel,
	})
	Theme.label({
		Kind = "type",
		Text = "Form WD-44 · adjust and file with your quartermaster",
		TextSize = 13,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(20, 42),
		Size = UDim2.new(1, -40, 0, 16),
		Parent = panel,
	})

	local list = Theme.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(16, 68),
		Size = UDim2.new(1, -32, 1, -128),
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.Colors.Khaki,
		Parent = panel,
	})
	Theme.list(list, Enum.FillDirection.Vertical, 4)
	Theme.padding(list, 2, 4)
	self.list = list

	local order = 0
	for _, category in CATEGORY_ORDER do
		local any = false
		for _, def in ctx.settings.Schema do
			if def.category == category then
				if not any then
					any = true
					order += 1
					Theme.header(category, { LayoutOrder = order, Parent = list })
				end
				order += 1
				self.rows[def.key] = self:_row(def, order)
			end
		end
	end

	-- Footer buttons
	local footer = Theme.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -12),
		Size = UDim2.new(1, -32, 0, 40),
		Parent = panel,
	})
	Theme.list(footer, Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Right)
	local reset = Theme.button({
		Text = "RESET DEFAULTS",
		TextSize = 16,
		Size = UDim2.fromOffset(170, 40),
		Variant = "ghost",
		LayoutOrder = 1,
		Parent = footer,
	})
	reset.Activated:Connect(function()
		ctx.settings.ResetDefaults()
	end)
	local save = Theme.button({
		Text = "SAVE & CLOSE",
		TextSize = 18,
		Size = UDim2.fromOffset(190, 40),
		Variant = "primary",
		LayoutOrder = 2,
		Parent = footer,
	})
	save.Activated:Connect(function()
		ctx.settings.Save()
		ctx.ui.CloseMenu("Settings")
	end)
	self.saveButton = save

	-- Slider dragging (mouse / touch)
	self.trove:Add(UserInputService.InputChanged:Connect(function(input)
		local drag = self.dragging
		if
			drag
			and (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			self:_dragTo(drag, input.Position.X)
		end
	end))
	self.trove:Add(UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			self.dragging = nil
		end
	end))

	self:Render()
	return self
end

function SettingsMenu:_row(def, order: number)
	local settings = self.ctx.settings
	local frame = Theme.new("Frame", {
		Name = def.key,
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -8, 0, ROW_HEIGHT),
		LayoutOrder = order,
		Parent = self.list,
	})
	Theme.corner(frame, 3)
	Theme.label({
		Kind = "bold",
		Text = string.upper(def.label),
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0.42, -12, 1, 0),
		Parent = frame,
	})
	local controls = Theme.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.new(0.58, -8, 0, 30),
		Parent = frame,
	})
	local row = { def = def, frame = frame }

	local valueLabel = Theme.label({
		Kind = "number",
		Text = "",
		TextSize = 16,
		TextColor3 = Theme.Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 64, 1, 0),
		Parent = controls,
	})
	row.value = valueLabel

	local function smallButton(text: string, pos: UDim2, anchor: Vector2): TextButton
		return Theme.button({
			Text = text,
			TextSize = 18,
			AnchorPoint = anchor,
			Position = pos,
			Size = UDim2.fromOffset(30, 30),
			Variant = "ghost",
			Parent = controls,
		})
	end

	if def.kind == "slider" then
		local minus = smallButton("−", UDim2.fromScale(0, 0), Vector2.new(0, 0))
		local plus = smallButton("+", UDim2.new(1, -70, 0, 0), Vector2.new(1, 0))
		local track = Theme.new("TextButton", {
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = Theme.Colors.Ink,
			BackgroundTransparency = 0.3,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 40, 0.5, 0),
			Size = UDim2.new(1, -150, 0, 8),
			Selectable = false,
			Parent = controls,
		})
		Theme.corner(track, 4)
		local fill = Theme.new("Frame", {
			BackgroundColor3 = Theme.Colors.Khaki,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(0.5, 1),
			Parent = track,
		})
		Theme.corner(fill, 4)
		local knob = Theme.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(16, 16),
			BackgroundColor3 = Theme.Colors.Accent,
			BorderSizePixel = 0,
			Parent = track,
		})
		Theme.round(knob)
		Theme.stroke(knob, Theme.Colors.Ink, 1, 0)
		row.track, row.fill, row.knob = track, fill, knob
		track.InputBegan:Connect(function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				self.dragging = row
				self:_dragTo(row, input.Position.X)
			end
		end)
		local step = def.step or 0.1
		minus.Activated:Connect(function()
			settings.Set(def.key, settings.Get(def.key) - step)
		end)
		plus.Activated:Connect(function()
			settings.Set(def.key, settings.Get(def.key) + step)
		end)
	elseif def.kind == "toggle" then
		local btn = Theme.button({
			Text = "",
			TextSize = 15,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -72, 0, 0),
			Size = UDim2.fromOffset(110, 30),
			Parent = controls,
		})
		btn.Activated:Connect(function()
			settings.Set(def.key, not settings.Get(def.key))
		end)
		row.toggle = btn
	elseif def.kind == "choice" then
		local prev = smallButton("‹", UDim2.new(1, -234, 0, 0), Vector2.new(0, 0))
		local nextBtn = smallButton("›", UDim2.new(1, -98, 0, 0), Vector2.new(0, 0))
		-- The value read-out sits between the arrows for option cyclers.
		valueLabel.AnchorPoint = Vector2.new(0, 0)
		valueLabel.Position = UDim2.new(1, -200, 0, 0)
		valueLabel.Size = UDim2.new(0, 100, 1, 0)
		valueLabel.TextXAlignment = Enum.TextXAlignment.Center
		local swatch = Theme.new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(1, -196, 0.5, 0),
			Size = UDim2.fromOffset(14, 14),
			BorderSizePixel = 0,
			Visible = def.key == "CrosshairColor",
			Parent = controls,
		})
		Theme.round(swatch)
		row.swatch = swatch
		local function cycle(dir: number)
			local opts = def.options
			local idx = table.find(opts, settings.Get(def.key)) or 1
			idx = (idx - 1 + dir) % #opts + 1
			settings.Set(def.key, opts[idx])
		end
		prev.Activated:Connect(function()
			cycle(-1)
		end)
		nextBtn.Activated:Connect(function()
			cycle(1)
		end)
	end
	return row
end

function SettingsMenu:_dragTo(row, screenX: number)
	local track = row.track
	local w = track.AbsoluteSize.X
	if w <= 0 then
		return
	end
	local alpha = math.clamp((screenX - track.AbsolutePosition.X) / w, 0, 1)
	local def = row.def
	self.ctx.settings.Set(def.key, def.min + (def.max - def.min) * alpha)
end

-- Re-renders all controls from the current settings.
function SettingsMenu:Render()
	local settings = self.ctx.settings
	for key, row in self.rows do
		local def = row.def
		local value = settings.Get(key)
		row.value.Text = formatValue(def, value)
		if def.kind == "slider" then
			local alpha = (value - def.min) / math.max(def.max - def.min, 1e-6)
			row.fill.Size = UDim2.fromScale(alpha, 1)
			row.knob.Position = UDim2.fromScale(alpha, 0.5)
		elseif def.kind == "toggle" then
			row.toggle.Text = value and "ENABLED" or "DISABLED"
			Theme.setButtonColor(row.toggle, value and Theme.Colors.Olive or Theme.Colors.PanelDark)
			row.value.Text = ""
		elseif def.kind == "choice" and row.swatch.Visible then
			row.swatch.BackgroundColor3 = Theme.CrosshairColors[value] or Theme.Colors.Text
		end
	end
end

function SettingsMenu:OnSettingsChanged()
	if self.panel.Visible then
		self:Render()
	end
end

function SettingsMenu:SetVisible(visible: boolean)
	self.panel.Visible = visible
	if visible then
		self:Render()
		Theme.selectForGamepad(self.saveButton)
	else
		self.dragging = nil
	end
end

function SettingsMenu:Destroy()
	self.trove:Clean()
	self.panel:Destroy()
end

return SettingsMenu
