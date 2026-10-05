--[[
	DamageIndicator: red arcs around the screen centre pointing toward the source of damage
	(`Combat_Damaged` {amount, fromPosition?, weaponId}) plus a brief red edge flash.

	Indicators are pooled (POOL_SIZE); their rotation is updated per frame only while at least one
	is active, so they keep pointing at the world position as the camera turns.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Data = require(UI.Data)
local Remotes = require(UI.Remotes)
local Theme = require(UI.Theme)

local DamageIndicator = {}
DamageIndicator.__index = DamageIndicator

local POOL_SIZE = 5
local LIFETIME = 1.6
local RADIUS = 120

function DamageIndicator.new(ctx)
	local self = setmetatable({}, DamageIndicator)
	self.ctx = ctx
	self.trove = Trove.new()
	self.allowed = false
	self.pool = {}
	self.active = 0

	local root = Theme.new("Frame", {
		Name = "DamageIndicator",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = ctx.fxRoot,
	})
	self.root = root

	-- Edge flash: red frame with a radial-ish transparency (two crossed gradients approximated).
	self.flash = Theme.new("Frame", {
		BackgroundColor3 = Color3.fromRGB(150, 10, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = root,
	})
	Theme.new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(0.25, 1),
			NumberSequenceKeypoint.new(0.75, 1),
			NumberSequenceKeypoint.new(1, 0.4),
		}),
		Parent = self.flash,
	})

	for i = 1, POOL_SIZE do
		local pivot = Theme.new("Frame", {
			Name = "Indicator" .. i,
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(0, 0),
			Visible = false,
			Parent = root,
		})
		local arc = Theme.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(0, -RADIUS),
			Size = UDim2.fromOffset(110, 12),
			BackgroundColor3 = Color3.fromRGB(220, 30, 20),
			BorderSizePixel = 0,
			Parent = pivot,
		})
		Theme.round(arc)
		local grad = Theme.new("UIGradient", {
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0.1),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = arc,
		})
		self.pool[i] = { pivot = pivot, arc = arc, grad = grad, source = nil, expires = 0 }
	end

	Remotes.onEvent("Combat_Damaged", function(payload)
		if type(payload) == "table" then
			self:Hit(tonumber(payload.amount) or 10, payload.fromPosition)
		end
	end, self.trove)

	self.trove:Add(RunService.RenderStepped:Connect(function()
		if self.active > 0 then
			self:_update()
		end
	end))
	return self
end

function DamageIndicator:Hit(amount: number, fromPosition: any)
	if not self.allowed then
		return
	end
	-- Edge flash scaled by damage
	self.flash.BackgroundTransparency = math.clamp(1 - amount / 60, 0.45, 0.85)
	Theme.tween(self.flash, 0.5, { BackgroundTransparency = 1 })

	if typeof(fromPosition) ~= "Vector3" then
		return
	end
	-- Reuse an indicator already pointing nearby, otherwise the oldest.
	local slot = self.pool[1]
	for _, s in self.pool do
		if s.source and (s.source - fromPosition).Magnitude < 8 then
			slot = s
			break
		end
		if s.expires < slot.expires then
			slot = s
		end
	end
	if not slot.source or slot.expires <= os.clock() then
		self.active += 1
	end
	slot.source = fromPosition
	slot.expires = os.clock() + LIFETIME
	slot.arc.BackgroundTransparency = 0
	slot.arc.Size = UDim2.fromOffset(math.clamp(70 + amount * 1.5, 80, 170), 12)
	slot.pivot.Visible = true
	self:_update()
end

function DamageIndicator:_update()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local camHeading = Data.heading(cam.CFrame.LookVector)
	local camPos = cam.CFrame.Position
	local now = os.clock()
	local active = 0
	for _, s in self.pool do
		if s.source then
			local left = s.expires - now
			if left <= 0 then
				s.source = nil
				s.pivot.Visible = false
			else
				active += 1
				local d = s.source - camPos
				local bearing = Data.heading(Vector3.new(d.X, 0, d.Z))
				s.pivot.Rotation = bearing - camHeading
				s.arc.BackgroundTransparency = left < 0.6 and (1 - left / 0.6) or 0
			end
		end
	end
	self.active = active
end

function DamageIndicator:SetVisible(visible: boolean)
	self.allowed = visible
	self.root.Visible = visible
	if not visible then
		for _, s in self.pool do
			s.source = nil
			s.pivot.Visible = false
		end
		self.active = 0
	end
end

function DamageIndicator:Destroy()
	self.trove:Clean()
	self.root:Destroy()
end

return DamageIndicator
