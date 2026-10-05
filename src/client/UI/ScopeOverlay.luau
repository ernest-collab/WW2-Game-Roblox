--[[
	ScopeOverlay: sniper scope on Bus ScopeChanged(isScoped, weaponId) (fired by the Combat team).

	Built without images: a transparent circle whose huge black UIStroke blacks out everything
	outside the lens, a soft inner vignette, and a thin reticle (post + crosshair lines).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Theme = require(UI.Theme)

local ScopeOverlay = {}
ScopeOverlay.__index = ScopeOverlay

function ScopeOverlay.new(ctx)
	local self = setmetatable({}, ScopeOverlay)
	self.ctx = ctx
	self.trove = Trove.new()
	self.allowed = false
	self.scoped = false

	-- Plain Frame (not a CanvasGroup) to avoid a full-screen render texture.
	local root = Theme.new("Frame", {
		Name = "Scope",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 50,
		Parent = ctx.fxGui,
	})
	self.root = root

	-- Lens: square (by height) circle; the stroke covers the rest of the screen.
	local lens = Theme.new("Frame", {
		Name = "Lens",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.92, 0.92),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		BackgroundTransparency = 1,
		Parent = root,
	})
	Theme.round(lens)
	Theme.new("UIStroke", {
		Color = Color3.new(0, 0, 0),
		Thickness = 3000,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = lens,
	})
	-- Inner vignette ring.
	local ring = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = lens,
	})
	Theme.round(ring)
	Theme.new("UIStroke", {
		Color = Color3.new(0, 0, 0),
		Thickness = 26,
		Transparency = 0.35,
		Parent = ring,
	})

	local function line(props)
		props.BackgroundColor3 = Color3.new(0, 0, 0)
		props.BorderSizePixel = 0
		props.Parent = lens
		return Theme.new("Frame", props)
	end
	-- Horizontal crosshair (thick outer, thin centre).
	line({ AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(0.4, 0, 0, 4) })
	line({ AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(1, 0.5), Size = UDim2.new(0.4, 0, 0, 4) })
	line({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0.2, 0, 0, 1) })
	-- German-style post from below + thin top line.
	line({ AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.new(0, 5, 0.5, 0) })
	line({ AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, 1, 0.42, 0) })
	-- Post tip
	local tip = line({ AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(2, 10) })
	tip.BackgroundColor3 = Color3.fromRGB(30, 30, 30)

	self.trove:Add(Bus.connect("ScopeChanged", function(isScoped: boolean, _weaponId: string?)
		self.scoped = isScoped == true
		self:_refresh()
	end))
	self.trove:Add(Bus.connect("WeaponUnequipped", function()
		self.scoped = false
		self:_refresh()
	end))
	return self
end

function ScopeOverlay:_refresh()
	local show = self.allowed and self.scoped
	self.root.Visible = show
end

function ScopeOverlay:IsScoped(): boolean
	return self.scoped and self.allowed
end

function ScopeOverlay:SetVisible(visible: boolean)
	self.allowed = visible
	self:_refresh()
end

function ScopeOverlay:Destroy()
	self.trove:Clean()
	self.root:Destroy()
end

return ScopeOverlay
