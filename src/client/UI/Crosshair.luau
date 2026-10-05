--[[
	Crosshair: four bars + centre dot. The gap follows Bus SpreadChanged(spreadDegrees) projected to
	screen space with the current camera FOV; it kicks slightly on Bus Fired. Hidden while aiming
	(Bus AimChanged), scoped (Bus ScopeChanged), in vehicles or menus (via SetVisible).
	Colour from SettingsController "CrosshairColor".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Theme = require(UI.Theme)

local Crosshair = {}
Crosshair.__index = Crosshair

local BAR_LENGTH = 9
local BAR_WIDTH = 2
local MIN_GAP = 4
local MAX_GAP = 90

function Crosshair.new(ctx)
	local self = setmetatable({}, Crosshair)
	self.ctx = ctx
	self.trove = Trove.new()
	self.allowed = false
	self.aiming = false
	self.scoped = false
	self.equipped = false
	self.spread = 2

	local root = Theme.new("Frame", {
		Name = "Crosshair",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		Visible = false,
		Parent = ctx.fxRoot,
	})
	self.root = root
	self.group = Theme.new("CanvasGroup", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(2 * (MAX_GAP + BAR_LENGTH) + 4, 2 * (MAX_GAP + BAR_LENGTH) + 4),
		Parent = root,
	})

	local function bar(name: string, horizontal: boolean): Frame
		local f = Theme.new("Frame", {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			BorderSizePixel = 0,
			Size = horizontal and UDim2.fromOffset(BAR_LENGTH, BAR_WIDTH) or UDim2.fromOffset(BAR_WIDTH, BAR_LENGTH),
			Parent = self.group,
		})
		Theme.new("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.5, Thickness = 1, Parent = f })
		return f
	end
	self.bars = {
		top = bar("Top", false),
		bottom = bar("Bottom", false),
		left = bar("Left", true),
		right = bar("Right", true),
	}
	self.dot = Theme.new("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(2, 2),
		BorderSizePixel = 0,
		Parent = self.group,
	})
	Theme.new("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.5, Parent = self.dot })

	self.trove:Add(Bus.connect("SpreadChanged", function(spread: number)
		if type(spread) == "number" then
			self.spread = spread
			self:_layout(0.08)
		end
	end))
	self.trove:Add(Bus.connect("AimChanged", function(aiming: boolean)
		self.aiming = aiming == true
		self:_refresh()
	end))
	self.trove:Add(Bus.connect("ScopeChanged", function(scoped: boolean)
		self.scoped = scoped == true
		self:_refresh()
	end))
	self.trove:Add(Bus.connect("WeaponEquipped", function()
		self.equipped = true
		self:_refresh()
	end))
	self.trove:Add(Bus.connect("WeaponUnequipped", function()
		self.equipped = false
		self:_refresh()
	end))
	self.trove:Add(Bus.connect("Fired", function()
		if not self.root.Visible then
			return
		end
		-- small visual kick: open, then settle back to the current spread
		self:_layout(0.03, 1.35)
		task.delay(0.05, function()
			self:_layout(0.12)
		end)
	end))
	self:OnSettingsChanged()
	self:_layout(0)
	return self
end

-- Spread (degrees, half-angle) -> logical pixels from the centre.
function Crosshair:_gapPixels(mult: number?): number
	local cam = Workspace.CurrentCamera
	local root = self.ctx.fxRoot
	local height = root.AbsoluteSize.Y / (root:GetAttribute("Scale") or 1)
	if height <= 0 then
		height = Theme.REFERENCE.Y
	end
	local fov = cam and cam.FieldOfView or 70
	local px = math.tan(math.rad(self.spread)) / math.tan(math.rad(fov / 2)) * (height / 2)
	return math.clamp(px * (mult or 1) + MIN_GAP, MIN_GAP, MAX_GAP)
end

function Crosshair:_layout(time: number, mult: number?)
	local gap = self:_gapPixels(mult)
	local half = BAR_LENGTH / 2
	local targets = {
		top = UDim2.new(0.5, 0, 0.5, -(gap + half)),
		bottom = UDim2.new(0.5, 0, 0.5, gap + half),
		left = UDim2.new(0.5, -(gap + half), 0.5, 0),
		right = UDim2.new(0.5, gap + half, 0.5, 0),
	}
	for key, f in self.bars do
		if time <= 0 then
			f.Position = targets[key]
		else
			Theme.tween(f, time, { Position = targets[key] })
		end
	end
end

function Crosshair:_refresh()
	local show = self.allowed and self.equipped and not self.aiming and not self.scoped
	if show and not self.root.Visible then
		self.group.GroupTransparency = 1
		Theme.tween(self.group, 0.12, { GroupTransparency = 0 })
	end
	self.root.Visible = show
end

function Crosshair:SetVisible(visible: boolean)
	self.allowed = visible
	self:_refresh()
end

function Crosshair:OnSettingsChanged()
	local name = self.ctx.settings.Get("CrosshairColor")
	local color = Theme.CrosshairColors[name] or Theme.CrosshairColors.White
	for _, f in self.bars do
		f.BackgroundColor3 = color
	end
	self.dot.BackgroundColor3 = color
end

function Crosshair:Destroy()
	self.trove:Clean()
	self.root:Destroy()
end

return Crosshair
