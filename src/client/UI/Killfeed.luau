--[[
	Killfeed: top-right list of recent kills from the `Combat_Kill` remote.

	  Killer  [WEAPON]  (HS)  Victim
	Names are tinted by side; rows involving the local player get a brass outline. Rows are pooled
	(MAX_ROWS) and recycled oldest-first; each fades out after LIFETIME seconds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Data = require(UI.Data)
local Remotes = require(UI.Remotes)
local Theme = require(UI.Theme)

local Killfeed = {}
Killfeed.__index = Killfeed

local MAX_ROWS = 6
local LIFETIME = 7
local LOCAL_PLAYER = Players.LocalPlayer

function Killfeed.new(ctx)
	local self = setmetatable({}, Killfeed)
	self.ctx = ctx
	self.trove = Trove.new()
	self.rows = {}
	self.counter = 0

	local frame = Theme.new("Frame", {
		Name = "Killfeed",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = ctx.isTouch and UDim2.new(1, -14, 0, 64) or UDim2.new(1, -14, 0, 24),
		Size = UDim2.fromOffset(420, MAX_ROWS * 26),
		Visible = false,
		Parent = ctx.hudRoot,
	})
	Theme.list(frame, Enum.FillDirection.Vertical, 3, Enum.HorizontalAlignment.Right)
	self.frame = frame

	for i = 1, MAX_ROWS do
		self.rows[i] = self:_buildRow(i)
	end

	Remotes.onEvent("Combat_Kill", function(payload)
		if type(payload) == "table" then
			self:Push(payload)
		end
	end, self.trove)
	return self
end

function Killfeed:_buildRow(i: number)
	local row = Theme.new("Frame", {
		Name = "Row" .. i,
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 23),
		Visible = false,
		Parent = self.frame,
	})
	Theme.corner(row, 3)
	local stroke = Theme.stroke(row, Theme.Colors.Accent, 1, 1)
	Theme.padding(row, 0, 8)
	Theme.list(row, Enum.FillDirection.Horizontal, 6, nil, Enum.VerticalAlignment.Center)
	local function text(order: number, kind: string, size: number): TextLabel
		return Theme.label({
			Kind = kind,
			Text = "",
			TextSize = size,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 23),
			LayoutOrder = order,
			Parent = row,
		})
	end
	local killer = text(1, "bold", 15)
	local weapon = text(2, "type", 13)
	weapon.TextColor3 = Theme.Colors.Khaki
	local hs = Theme.label({
		Kind = "title",
		Text = "HS",
		TextSize = 11,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		BackgroundTransparency = 0,
		BackgroundColor3 = Theme.Colors.Accent,
		Size = UDim2.fromOffset(22, 15),
		LayoutOrder = 3,
		Parent = row,
	})
	Theme.corner(hs, 2)
	local victim = text(4, "bold", 15)
	return { frame = row, stroke = stroke, killer = killer, weapon = weapon, hs = hs, victim = victim, serial = 0 }
end

local function nameOf(p: any): string
	if typeof(p) == "Instance" and p:IsA("Player") then
		return p.DisplayName
	end
	return ""
end

--[[
	Adds an entry. payload = {killer: Player?, victim: Player, weaponId, headshot, killerSide,
	victimSide, distance, vehicleId?}
]]
function Killfeed:Push(payload)
	self.counter += 1
	-- Oldest row = smallest serial (or a hidden one).
	local row = self.rows[1]
	for _, r in self.rows do
		if not r.frame.Visible then
			row = r
			break
		end
		if r.serial < row.serial then
			row = r
		end
	end
	row.serial = self.counter
	row.frame.LayoutOrder = -self.counter -- newest on top

	local killer, victim = payload.killer, payload.victim
	local suicide = killer == nil or killer == victim
	row.killer.Visible = not suicide
	row.killer.Text = suicide and "" or nameOf(killer)
	row.killer.TextColor3 = Theme.sideColor(payload.killerSide)
	local weaponText
	if payload.vehicleId then
		weaponText = Data.vehicleName(payload.vehicleId)
	elseif suicide and not payload.weaponId then
		weaponText = "KIA"
	else
		weaponText = Data.weaponName(payload.weaponId)
	end
	row.weapon.Text = "[" .. string.upper(weaponText) .. "]"
	row.hs.Visible = payload.headshot == true
	row.victim.Text = nameOf(victim)
	row.victim.TextColor3 = Theme.sideColor(payload.victimSide)

	local involved = killer == LOCAL_PLAYER or victim == LOCAL_PLAYER
	row.stroke.Transparency = involved and 0 or 1
	row.frame.BackgroundColor3 = killer == LOCAL_PLAYER and Theme.Colors.PanelLight or Theme.Colors.PanelDark

	row.frame.BackgroundTransparency = 0.3
	for _, label in { row.killer, row.weapon, row.victim } do
		label.TextTransparency = 0
	end
	row.frame.Visible = true

	local serial = row.serial
	task.delay(LIFETIME, function()
		if row.serial ~= serial then
			return
		end
		Theme.tween(row.frame, 0.5, { BackgroundTransparency = 1 })
		for _, label in { row.killer, row.weapon, row.victim } do
			Theme.tween(label, 0.5, { TextTransparency = 1 })
		end
		task.delay(0.5, function()
			if row.serial == serial then
				row.frame.Visible = false
			end
		end)
	end)
end

function Killfeed:SetVisible(visible: boolean)
	self.frame.Visible = visible
end

function Killfeed:Destroy()
	self.trove:Clean()
	self.frame:Destroy()
end

return Killfeed
