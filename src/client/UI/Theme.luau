--[[
	Theme: the visual language of WW2 Frontlines' UI ("field manual" military style) plus small
	instance-building helpers shared by every UI component.

	  * Olive drab / khaki panels with a subtle paper grain (UIGradient), thin dark strokes.
	  * Condensed stencil-like headings (Oswald), typewriter accents (SpecialElite), condensed body
	    text (RobotoCondensed). Built-in fonts only.
	  * Crisp off-white text with a subtle dark stroke for legibility over the 3D world.

	Everything here is pure and stateless except `scaledRoot`, which keeps a UIScale in sync with
	the viewport (returns a cleanup function).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local Factions = require(Shared.Config.Factions)

local Theme = {}

-- Reference resolution the UI is authored against (logical pixels before UIScale).
Theme.REFERENCE = Vector2.new(1280, 720)

Theme.Colors = {
	Ink = Color3.fromRGB(14, 15, 11),
	Panel = Color3.fromRGB(36, 39, 29),
	PanelLight = Color3.fromRGB(56, 60, 43),
	PanelDark = Color3.fromRGB(24, 26, 19),
	Olive = Color3.fromRGB(86, 92, 58),
	OliveLight = Color3.fromRGB(116, 122, 80),
	Khaki = Color3.fromRGB(189, 172, 128),
	KhakiDark = Color3.fromRGB(132, 119, 84),
	Paper = Color3.fromRGB(226, 212, 174),
	Text = Color3.fromRGB(242, 238, 224),
	TextDim = Color3.fromRGB(168, 164, 142),
	TextDark = Color3.fromRGB(30, 30, 24),
	Accent = Color3.fromRGB(216, 178, 74), -- brass
	AccentDark = Color3.fromRGB(150, 118, 40),
	Danger = Color3.fromRGB(206, 60, 46),
	Warning = Color3.fromRGB(230, 160, 50),
	Good = Color3.fromRGB(126, 182, 90),
	Squad = Color3.fromRGB(118, 220, 122),
	Stroke = Color3.fromRGB(0, 0, 0),
	Locked = Color3.fromRGB(90, 90, 84),
}

Theme.SideColors = Constants.SIDE_COLORS

local function weighted(enumFont: Enum.Font, weight: Enum.FontWeight): Font
	return Font.new(Font.fromEnum(enumFont).Family, weight, Enum.FontStyle.Normal)
end

Theme.Fonts = {
	Title = weighted(Enum.Font.Oswald, Enum.FontWeight.Bold),
	Heading = weighted(Enum.Font.Oswald, Enum.FontWeight.Medium),
	Number = weighted(Enum.Font.Oswald, Enum.FontWeight.SemiBold),
	Body = weighted(Enum.Font.RobotoCondensed, Enum.FontWeight.Regular),
	BodyBold = weighted(Enum.Font.RobotoCondensed, Enum.FontWeight.Bold),
	Type = Font.fromEnum(Enum.Font.SpecialElite), -- typewriter, field-manual accents
	Glyph = Font.fromEnum(Enum.Font.GothamBold), -- arrows / symbols
}

-- Crosshair colour presets (SettingsController "CrosshairColor" stores the preset name).
Theme.CrosshairColors = {
	White = Color3.fromRGB(245, 245, 240),
	Green = Color3.fromRGB(110, 235, 110),
	Yellow = Color3.fromRGB(245, 220, 80),
	Cyan = Color3.fromRGB(90, 220, 235),
	Red = Color3.fromRGB(240, 80, 70),
}
Theme.CrosshairOrder = { "White", "Green", "Yellow", "Cyan", "Red" }

Theme.MapColors = {
	background = Color3.fromRGB(74, 78, 54),
	building = Color3.fromRGB(46, 42, 36),
	road = Color3.fromRGB(150, 136, 100),
	water = Color3.fromRGB(58, 84, 104),
	trench = Color3.fromRGB(64, 50, 36),
	forest = Color3.fromRGB(44, 64, 38),
	field = Color3.fromRGB(104, 104, 66),
}

------------------------------------------------------------------------------------------------
-- Instance helpers
------------------------------------------------------------------------------------------------

--[[
	Theme.new(className, props, children?) -> Instance
	Sets every prop (Parent last) and parents `children` to the new instance.
]]
function Theme.new(className: string, props: { [string]: any }?, children: { Instance }?): any
	local inst = Instance.new(className)
	local parent = nil
	if props then
		for k, v in props do
			if k == "Parent" then
				parent = v
			else
				(inst :: any)[k] = v
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

function Theme.corner(parent: Instance, radius: number?): UICorner
	return Theme.new("UICorner", { CornerRadius = UDim.new(0, radius or 4), Parent = parent })
end

function Theme.round(parent: Instance): UICorner
	return Theme.new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = parent })
end

function Theme.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	return Theme.new("UIStroke", {
		Color = color or Theme.Colors.Stroke,
		Thickness = thickness or 1,
		Transparency = transparency or 0.35,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function Theme.textStroke(parent: Instance, transparency: number?): UIStroke
	return Theme.new("UIStroke", {
		Color = Theme.Colors.Stroke,
		Thickness = 1,
		Transparency = transparency or 0.55,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Parent = parent,
	})
end

function Theme.padding(parent: Instance, all: number, horizontal: number?): UIPadding
	local h = horizontal or all
	return Theme.new("UIPadding", {
		PaddingTop = UDim.new(0, all),
		PaddingBottom = UDim.new(0, all),
		PaddingLeft = UDim.new(0, h),
		PaddingRight = UDim.new(0, h),
		Parent = parent,
	})
end

function Theme.list(
	parent: Instance,
	direction: Enum.FillDirection?,
	gap: number?,
	hAlign: Enum.HorizontalAlignment?,
	vAlign: Enum.VerticalAlignment?
): UIListLayout
	return Theme.new("UIListLayout", {
		FillDirection = direction or Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 4),
		HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left,
		VerticalAlignment = vAlign or Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = parent,
	})
end

-- Subtle "paper grain": a many-keypoint near-white gradient that modulates the panel colour.
local GRAIN_SEQUENCE = (function()
	local rng = Random.new(1944)
	local kps = {}
	local n = 18
	for i = 0, n do
		local v = 0.88 + rng:NextNumber() * 0.12
		table.insert(kps, ColorSequenceKeypoint.new(i / n, Color3.new(v, v, v * 0.97)))
	end
	return ColorSequence.new(kps)
end)()

function Theme.grain(parent: Instance, rotation: number?): UIGradient
	return Theme.new("UIGradient", {
		Color = GRAIN_SEQUENCE,
		Rotation = rotation or 78,
		Parent = parent,
	})
end

--[[
	Theme.panel(props) -> Frame
	Olive drab field panel: grain, 4px corners, thin dark stroke. `props.Style` = "dark" | "light" |
	"paper" | nil (default olive).
]]
function Theme.panel(props: { [string]: any }?): Frame
	local p = props and table.clone(props) or {}
	local style = p.Style
	p.Style = nil
	local color = Theme.Colors.Panel
	if style == "dark" then
		color = Theme.Colors.PanelDark
	elseif style == "light" then
		color = Theme.Colors.PanelLight
	elseif style == "paper" then
		color = Theme.Colors.Paper
	end
	if p.BackgroundColor3 == nil then
		p.BackgroundColor3 = color
	end
	if p.BackgroundTransparency == nil then
		p.BackgroundTransparency = 0.08
	end
	p.BorderSizePixel = 0
	local frame = Theme.new("Frame", p)
	Theme.corner(frame, 4)
	Theme.stroke(frame, Theme.Colors.Stroke, 1, 0.4)
	Theme.grain(frame)
	return frame
end

--[[
	Theme.label(props) -> TextLabel with UI defaults (transparent background, body font, light text).
	`props.Kind` = "title" | "heading" | "number" | "body" | "bold" | "type" | "glyph".
]]
function Theme.label(props: { [string]: any }?): TextLabel
	local p = props and table.clone(props) or {}
	local kind = p.Kind or "body"
	p.Kind = nil
	if p.FontFace == nil then
		p.FontFace = ({
			title = Theme.Fonts.Title,
			heading = Theme.Fonts.Heading,
			number = Theme.Fonts.Number,
			body = Theme.Fonts.Body,
			bold = Theme.Fonts.BodyBold,
			type = Theme.Fonts.Type,
			glyph = Theme.Fonts.Glyph,
		})[kind] or Theme.Fonts.Body
	end
	if p.BackgroundTransparency == nil then
		p.BackgroundTransparency = 1
	end
	if p.TextColor3 == nil then
		p.TextColor3 = Theme.Colors.Text
	end
	if p.TextSize == nil then
		p.TextSize = 16
	end
	if p.TextStrokeTransparency == nil then
		p.TextStrokeTransparency = 0.75
	end
	if p.TextStrokeColor3 == nil then
		p.TextStrokeColor3 = Theme.Colors.Stroke
	end
	p.BorderSizePixel = 0
	return Theme.new("TextLabel", p)
end

--[[
	Theme.button(props) -> TextButton with hover / press / gamepad-selection feedback.
	`props.Variant` = "primary" (brass) | "ghost" | "danger" | nil (olive).
]]
function Theme.button(props: { [string]: any }?): TextButton
	local p = props and table.clone(props) or {}
	local variant = p.Variant
	p.Variant = nil
	local base, text = Theme.Colors.PanelLight, Theme.Colors.Text
	if variant == "primary" then
		base, text = Theme.Colors.Accent, Theme.Colors.TextDark
	elseif variant == "danger" then
		base = Theme.Colors.Danger
	elseif variant == "ghost" then
		base = Theme.Colors.PanelDark
	end
	if p.BackgroundColor3 == nil then
		p.BackgroundColor3 = base
	end
	if p.TextColor3 == nil then
		p.TextColor3 = text
	end
	if p.FontFace == nil then
		p.FontFace = Theme.Fonts.Heading
	end
	if p.TextSize == nil then
		p.TextSize = 18
	end
	p.AutoButtonColor = false
	p.BorderSizePixel = 0
	local btn = Theme.new("TextButton", p)
	Theme.corner(btn, 3)
	local stroke = Theme.stroke(btn, Theme.Colors.Stroke, 1, 0.3)
	Theme.grain(btn)

	local baseColor = btn.BackgroundColor3
	local function hover(on: boolean)
		local target = baseColor
		if on then
			target = baseColor:Lerp(Color3.new(1, 1, 1), 0.14)
		end
		Theme.tween(btn, 0.12, { BackgroundColor3 = target })
		stroke.Color = on and Theme.Colors.Accent or Theme.Colors.Stroke
		stroke.Transparency = on and 0 or 0.3
	end
	btn.MouseEnter:Connect(function()
		hover(true)
	end)
	btn.MouseLeave:Connect(function()
		hover(false)
	end)
	btn.SelectionGained:Connect(function()
		hover(true)
	end)
	btn.SelectionLost:Connect(function()
		hover(false)
	end)
	btn.MouseButton1Down:Connect(function()
		Theme.tween(btn, 0.06, { BackgroundColor3 = baseColor:Lerp(Color3.new(0, 0, 0), 0.2) })
	end)
	btn.MouseButton1Up:Connect(function()
		hover(true)
	end)
	-- Allow callers to re-tint (e.g. selected state) while keeping hover feedback correct.
	btn:GetAttributeChangedSignal("BaseColor"):Connect(function()
		local c = btn:GetAttribute("BaseColor")
		if typeof(c) == "Color3" then
			baseColor = c
			btn.BackgroundColor3 = c
		end
	end)
	-- Gamepad selection highlight: a brass outline instead of the default blue box.
	btn.SelectionImageObject = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	}, {
		Theme.new("UIStroke", { Color = Theme.Colors.Accent, Thickness = 2 }),
		Theme.new("UICorner", { CornerRadius = UDim.new(0, 3) }),
	})
	return btn
end

-- Re-tints a Theme.button while keeping hover behaviour consistent.
function Theme.setButtonColor(btn: TextButton, color: Color3)
	btn:SetAttribute("BaseColor", color)
end

function Theme.tween(
	inst: Instance,
	time: number,
	props: { [string]: any },
	style: Enum.EasingStyle?,
	dir: Enum.EasingDirection?
): Tween
	local tw = TweenService:Create(
		inst,
		TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out),
		props
	)
	tw:Play()
	return tw
end

------------------------------------------------------------------------------------------------
-- Faction / side helpers
------------------------------------------------------------------------------------------------

function Theme.sideColor(side: string?): Color3
	return Constants.SIDE_COLORS[side or "Neutral"] or Constants.SIDE_COLORS.Neutral
end

function Theme.faction(factionId: string?): any
	if not factionId or factionId == "" then
		return nil
	end
	return Factions.byId[factionId]
end

-- Builds a hard-edged ColorSequence of equal vertical stripes.
local function stripeSequence(colors: { Color3 }): ColorSequence
	local n = #colors
	if n == 0 then
		return ColorSequence.new(Color3.new(0.5, 0.5, 0.5))
	elseif n == 1 then
		return ColorSequence.new(colors[1])
	end
	local kps = {}
	for i, c in colors do
		local a = (i - 1) / n
		local b = i / n
		if i > 1 then
			a += 0.001
		end
		if i < n then
			b -= 0.001
		end
		table.insert(kps, ColorSequenceKeypoint.new(a, c))
		table.insert(kps, ColorSequenceKeypoint.new(b, c))
	end
	return ColorSequence.new(kps)
end

--[[
	Theme.flag(props, factionId?) -> Frame with simplified flag stripes (one Frame + UIGradient).
	Call Theme.setFlag(frame, factionId) to change it later.
]]
function Theme.flag(props: { [string]: any }?, factionId: string?): Frame
	local p = props and table.clone(props) or {}
	p.BackgroundColor3 = Color3.new(1, 1, 1)
	p.BorderSizePixel = 0
	local frame = Theme.new("Frame", p)
	Theme.corner(frame, 2)
	Theme.stroke(frame, Theme.Colors.Stroke, 1, 0.2)
	Theme.new("UIGradient", { Name = "Stripes", Parent = frame })
	Theme.setFlag(frame, factionId)
	return frame
end

function Theme.setFlag(frame: Frame, factionId: string?)
	local grad = frame:FindFirstChild("Stripes") :: UIGradient?
	if not grad then
		return
	end
	local f = Theme.faction(factionId)
	if f and f.flag then
		grad.Color = stripeSequence(f.flag)
		frame.BackgroundTransparency = 0
	else
		grad.Color = ColorSequence.new(Color3.fromRGB(120, 120, 110))
		frame.BackgroundTransparency = 0.4
	end
end

------------------------------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------------------------------

function Theme.formatTime(seconds: number?): string
	local s = math.max(0, math.floor(seconds or 0))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- Studs -> metres (1 stud ~= 0.28 m), for distance read-outs.
function Theme.meters(studs: number): string
	return string.format("%dm", math.floor(studs * 0.28 + 0.5))
end

------------------------------------------------------------------------------------------------
-- Screen setup
------------------------------------------------------------------------------------------------

function Theme.isTouch(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

function Theme.isGamepad(): boolean
	return UserInputService.GamepadEnabled and not UserInputService.MouseEnabled
end

--[[
	Theme.screenGui(name, displayOrder, safe) -> ScreenGui
	safe = true  -> respects device safe areas (notches); false -> full screen (backdrops / FX).
]]
function Theme.screenGui(name: string, displayOrder: number, safe: boolean, parent: Instance): ScreenGui
	return Theme.new("ScreenGui", {
		Name = name,
		DisplayOrder = displayOrder,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ScreenInsets = safe and Enum.ScreenInsets.DeviceSafeInsets or Enum.ScreenInsets.None,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = parent,
	})
end

--[[
	Theme.scaledRoot(gui) -> (root: Frame, cleanup: () -> ())
	A full-screen frame carrying a UIScale so UI authored at Theme.REFERENCE scales to any viewport.
	The root's logical size is viewport / scale, so children can freely mix scale & offset sizing.
]]
function Theme.scaledRoot(gui: ScreenGui): (Frame, () -> ())
	local root = Theme.new("Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	local uiScale = Theme.new("UIScale", { Parent = root })
	local connections = {}

	local function update()
		local size = gui.AbsoluteSize
		if size.X < 2 or size.Y < 2 then
			local cam = Workspace.CurrentCamera
			size = cam and cam.ViewportSize or Theme.REFERENCE
		end
		local s = math.min(size.X / Theme.REFERENCE.X, size.Y / Theme.REFERENCE.Y)
		if Theme.isTouch() then
			s *= 1.12 -- slightly larger hit targets on phones / tablets
		end
		s = math.clamp(s, 0.5, 1.6)
		uiScale.Scale = s
		root.Size = UDim2.fromOffset(size.X / s, size.Y / s)
		root:SetAttribute("Scale", s)
	end

	table.insert(connections, gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(update))
	task.defer(update)
	update()
	return root, function()
		for _, c in connections do
			c:Disconnect()
		end
	end
end

-- Selects a GuiObject for gamepad navigation (only when a gamepad is the active input).
function Theme.selectForGamepad(obj: GuiObject?)
	if obj and UserInputService.GamepadEnabled then
		local last = UserInputService:GetLastInputType()
		if last.Name:find("Gamepad") then
			GuiService.SelectedObject = obj
		end
	end
end

------------------------------------------------------------------------------------------------
-- Composite widgets
------------------------------------------------------------------------------------------------

--[[
	Theme.bar(props, fillColor) -> (frame, fill)
	A horizontal progress bar. Set fill.Size = UDim2.fromScale(fraction, 1) to update.
]]
function Theme.bar(props: { [string]: any }?, fillColor: Color3?): (Frame, Frame)
	local p = props and table.clone(props) or {}
	if p.BackgroundColor3 == nil then
		p.BackgroundColor3 = Theme.Colors.Ink
	end
	if p.BackgroundTransparency == nil then
		p.BackgroundTransparency = 0.35
	end
	p.BorderSizePixel = 0
	local frame = Theme.new("Frame", p)
	Theme.corner(frame, 2)
	local fill = Theme.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = fillColor or Theme.Colors.Khaki,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})
	Theme.corner(fill, 2)
	return frame, fill
end

-- Section header: brass tick + stencil caption, used in menus.
function Theme.header(text: string, props: { [string]: any }?): Frame
	local p = props and table.clone(props) or {}
	p.BackgroundTransparency = 1
	if p.Size == nil then
		p.Size = UDim2.new(1, 0, 0, 26)
	end
	local frame = Theme.new("Frame", p)
	Theme.new("Frame", {
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 4, 1, -6),
		Position = UDim2.fromOffset(0, 3),
		Parent = frame,
	})
	Theme.label({
		Name = "Text",
		Kind = "heading",
		Text = string.upper(text),
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -12, 1, 0),
		Position = UDim2.fromOffset(12, 0),
		Parent = frame,
	})
	return frame
end

-- Simple glyph icon: bordered square with a 2–4 letter stencil code (no image assets needed).
function Theme.glyphBox(text: string, props: { [string]: any }?): Frame
	local p = props and table.clone(props) or {}
	if p.BackgroundColor3 == nil then
		p.BackgroundColor3 = Theme.Colors.Olive
	end
	p.BorderSizePixel = 0
	local frame = Theme.new("Frame", p)
	Theme.corner(frame, 3)
	Theme.stroke(frame, Theme.Colors.Khaki, 1, 0.5)
	Theme.label({
		Name = "Glyph",
		Kind = "title",
		Text = text,
		TextScaled = true,
		Size = UDim2.fromScale(0.86, 0.7),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Parent = frame,
	})
	return frame
end

return Theme
