--[[
	Hitmarker: diagonal ticks around the screen centre on `Combat_HitConfirm`
	{damage, headshot, killed, target}. White for hits, brass + larger for headshots, red for kills,
	steel for vehicle hits. Respects SettingsController "Hitmarkers".
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Remotes = require(UI.Remotes)
local Theme = require(UI.Theme)

local Hitmarker = {}
Hitmarker.__index = Hitmarker

local OFFSET = 9
local LENGTH = 10

function Hitmarker.new(ctx)
	local self = setmetatable({}, Hitmarker)
	self.ctx = ctx
	self.trove = Trove.new()
	self.allowed = false
	self.serial = 0

	local root = Theme.new("CanvasGroup", {
		Name = "Hitmarker",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(64, 64),
		GroupTransparency = 1,
		Visible = false,
		Parent = ctx.fxRoot,
	})
	self.root = root
	self.scale = Theme.new("UIScale", { Parent = root })
	self.ticks = {}
	for _, d in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local tick = Theme.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, d[1] * OFFSET, 0.5, d[2] * OFFSET),
			Size = UDim2.fromOffset(LENGTH, 2),
			Rotation = d[1] * d[2] * 45,
			BackgroundColor3 = Theme.Colors.Text,
			BorderSizePixel = 0,
			Parent = root,
		})
		Theme.new("UIStroke", { Color = Color3.new(0, 0, 0), Transparency = 0.4, Parent = tick })
		table.insert(self.ticks, tick)
	end

	Remotes.onEvent("Combat_HitConfirm", function(payload)
		if type(payload) == "table" then
			self:Show(payload.headshot == true, payload.killed == true, payload.target == "vehicle")
		end
	end, self.trove)
	return self
end

function Hitmarker:Show(headshot: boolean, killed: boolean, vehicle: boolean)
	if not self.allowed or self.ctx.settings.Get("Hitmarkers") == false then
		return
	end
	local color = Theme.Colors.Text
	if killed then
		color = Theme.Colors.Danger
	elseif headshot then
		color = Theme.Colors.Accent
	elseif vehicle then
		color = Color3.fromRGB(150, 180, 210)
	end
	for _, t in self.ticks do
		t.BackgroundColor3 = color
		t.Size = UDim2.fromOffset((killed or headshot) and LENGTH + 4 or LENGTH, killed and 3 or 2)
	end
	self.serial += 1
	local serial = self.serial
	self.root.Visible = true
	self.root.GroupTransparency = 0
	self.scale.Scale = (killed or headshot) and 1.5 or 1.25
	Theme.tween(self.scale, 0.1, { Scale = 1 })
	task.delay(killed and 0.32 or 0.16, function()
		if self.serial == serial then
			local tw = Theme.tween(self.root, 0.15, { GroupTransparency = 1 })
			tw.Completed:Once(function()
				if self.serial == serial then
					self.root.Visible = false
				end
			end)
		end
	end)
end

function Hitmarker:SetVisible(visible: boolean)
	self.allowed = visible
	if not visible then
		self.root.Visible = false
	end
end

function Hitmarker:Destroy()
	self.trove:Clean()
	self.root:Destroy()
end

return Hitmarker
