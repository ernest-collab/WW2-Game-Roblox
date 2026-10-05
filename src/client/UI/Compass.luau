--[[
	Compass: heading strip at the top of the screen with cardinal labels, bearing numbers and
	objective markers (letter in owner colour + distance).

	The strip is built once (ticks from -90° to 450°) and only its X offset moves per frame.
	Objective markers (≤ 7) are positioned per frame from the camera.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameState = require(Shared.GameState)

local UI = script.Parent
local Data = require(UI.Data)
local Theme = require(UI.Theme)

local Compass = {}
Compass.__index = Compass

local WIDTH = 440
local PX_PER_DEG = 3.6 -- visible span = WIDTH / PX_PER_DEG ≈ 122°
local HALF_SPAN = WIDTH / PX_PER_DEG / 2
local MIN_DEG, MAX_DEG = -90, 450

local CARDINALS = { [0] = "N", [45] = "NE", [90] = "E", [135] = "SE", [180] = "S", [225] = "SW", [270] = "W", [315] = "NW" }

function Compass.new(ctx)
	local self = setmetatable({}, Compass)
	self.ctx = ctx
	self.visible = false
	self.markers = {} :: { [string]: any }

	local frame = Theme.new("Frame", {
		Name = "Compass",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(WIDTH, 40),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Visible = false,
		Parent = ctx.hudRoot,
	})
	-- Edge fade
	local bg = Theme.new("Frame", {
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 24),
		Parent = frame,
	})
	Theme.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.18, 0),
			NumberSequenceKeypoint.new(0.82, 0),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = bg,
	})
	self.frame = frame

	local strip = Theme.new("Frame", {
		Name = "Strip",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset((MAX_DEG - MIN_DEG) * PX_PER_DEG, 24),
		Parent = frame,
	})
	for deg = MIN_DEG, MAX_DEG, 5 do
		local x = (deg - MIN_DEG) * PX_PER_DEG
		local norm = deg % 360
		local cardinal = CARDINALS[norm]
		local major = norm % 15 == 0
		Theme.new("Frame", {
			BackgroundColor3 = Theme.Colors.Text,
			BackgroundTransparency = cardinal and 0 or (major and 0.25 or 0.55),
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromOffset(x, 24),
			Size = UDim2.fromOffset(cardinal and 2 or 1, cardinal and 8 or (major and 6 or 3)),
			Parent = strip,
		})
		if cardinal or major then
			Theme.label({
				Kind = cardinal and "title" or "number",
				Text = cardinal or tostring(norm),
				TextSize = cardinal and (#cardinal == 1 and 17 or 13) or 11,
				TextColor3 = norm == 0 and Theme.Colors.Accent or (cardinal and Theme.Colors.Text or Theme.Colors.TextDim),
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.fromOffset(x, 0),
				Size = UDim2.fromOffset(30, 16),
				Parent = strip,
			})
		end
	end
	self.strip = strip

	-- Centre caret + heading readout
	Theme.new("Frame", {
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 22),
		Size = UDim2.fromOffset(2, 6),
		ZIndex = 3,
		Parent = frame,
	})
	self.headingLabel = Theme.label({
		Kind = "number",
		Text = "000",
		TextSize = 12,
		TextColor3 = Theme.Colors.Accent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 27),
		Size = UDim2.fromOffset(40, 13),
		ZIndex = 3,
		Parent = frame,
	})
	self.markerLayer = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = frame,
	})

	self.conn = RunService.RenderStepped:Connect(function()
		if self.visible then
			self:_update()
		end
	end)
	return self
end

function Compass:_marker(id: string)
	local m = self.markers[id]
	if m then
		return m
	end
	local chip = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		Position = UDim2.fromOffset(0, 4),
		BorderSizePixel = 0,
		ZIndex = 5,
		Parent = self.markerLayer,
	})
	Theme.corner(chip, 3)
	Theme.stroke(chip, Theme.Colors.Ink, 1, 0)
	Theme.label({
		Kind = "title",
		Text = id,
		TextSize = 12,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 6,
		Parent = chip,
	})
	local dist = Theme.label({
		Kind = "number",
		Text = "",
		TextSize = 10,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 1),
		Size = UDim2.fromOffset(40, 11),
		ZIndex = 6,
		Parent = chip,
	})
	m = { chip = chip, dist = dist }
	self.markers[id] = m
	return m
end

function Compass:_update()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local heading = Data.heading(cam.CFrame.LookVector)
	self.strip.Position = UDim2.fromOffset(WIDTH / 2 - (heading - MIN_DEG) * PX_PER_DEG, 0)
	self.headingLabel.Text = string.format("%03d", math.floor(heading + 0.5) % 360)

	local origin = cam.CFrame.Position
	local folder = GameState.folder():FindFirstChild("Objectives")
	local seen = {}
	if folder then
		for _, obj in folder:GetChildren() do
			local pos = obj:GetAttribute("Position")
			if typeof(pos) == "Vector3" then
				local m = self:_marker(obj.Name)
				seen[obj.Name] = true
				local delta = pos - origin
				local bearing = Data.heading(Vector3.new(delta.X, 0, delta.Z))
				local rel = (bearing - heading + 540) % 360 - 180
				if math.abs(rel) <= HALF_SPAN then
					m.chip.Visible = true
					m.chip.Position = UDim2.fromOffset(WIDTH / 2 + rel * PX_PER_DEG, 3)
					local owner = obj:GetAttribute("Owner") or "Neutral"
					local contested = obj:GetAttribute("Contested") == true
					local blinkOn = (os.clock() % 0.8) < 0.4
					m.chip.BackgroundColor3 = (contested and blinkOn) and Theme.Colors.Text or Theme.sideColor(owner)
					m.chip.BackgroundTransparency = obj:GetAttribute("Locked") == true and 0.5 or 0
					m.dist.Text = Theme.meters(Vector3.new(delta.X, 0, delta.Z).Magnitude)
				else
					m.chip.Visible = false
				end
			end
		end
	end
	for id, m in self.markers do
		if not seen[id] then
			m.chip.Visible = false
		end
	end
end

function Compass:SetVisible(visible: boolean)
	self.visible = visible
	self.frame.Visible = visible
end

function Compass:Destroy()
	self.conn:Disconnect()
	self.frame:Destroy()
end

return Compass
