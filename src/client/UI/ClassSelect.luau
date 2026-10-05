--[[
	ClassSelect: vertical list of the six classes (Classes.order) as dog-tag style cards:
	glyph code, name, short role line and a lock badge when the player's level is too low.

	  local cs = ClassSelect.new(parent, function(classId) ... end)
	  cs:SetLevel(level)
	  cs:SetSelected(classId)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Classes = require(Shared.Config.Classes)

local UI = script.Parent
local Theme = require(UI.Theme)

local ClassSelect = {}
ClassSelect.__index = ClassSelect

local ROLE_LINES = {
	Rifleman = "Rifles · grenades · fast capture",
	Assault = "SMGs · assault rifles · shotguns",
	Support = "Machine guns · ammunition",
	Medic = "Heals · revives",
	Engineer = "Anti-tank · repairs",
	Recon = "Sniper rifles · spotting",
}

function ClassSelect.new(parent: GuiObject, onSelect: (string) -> ())
	local self = setmetatable({}, ClassSelect)
	self.cards = {} :: { [string]: any }
	self.level = 1
	self.selected = nil :: string?
	self.onSelect = onSelect

	local list = Theme.new("ScrollingFrame", {
		Name = "Classes",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.Colors.Khaki,
		Parent = parent,
	})
	Theme.list(list, Enum.FillDirection.Vertical, 5)
	Theme.padding(list, 2, 2)
	self.list = list

	for i, id in Classes.order do
		local def = Classes.byId[id]
		local card = Theme.button({
			Name = id,
			Text = "",
			Size = UDim2.new(1, -6, 0, 52),
			LayoutOrder = i,
			Parent = list,
		})
		Theme.glyphBox(def.icon, {
			Position = UDim2.fromOffset(6, 6),
			Size = UDim2.fromOffset(46, 40),
			Parent = card,
		})
		local name = Theme.label({
			Kind = "heading",
			Text = string.upper(def.name),
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(60, 5),
			Size = UDim2.new(1, -120, 0, 22),
			Parent = card,
		})
		Theme.label({
			Kind = "body",
			Text = ROLE_LINES[id] or def.description,
			TextSize = 13,
			TextColor3 = Theme.Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(60, 27),
			Size = UDim2.new(1, -66, 0, 18),
			Parent = card,
		})
		local lock = Theme.label({
			Kind = "title",
			Text = "LVL " .. tostring(def.unlockLevel),
			TextSize = 12,
			TextColor3 = Theme.Colors.Ink,
			TextStrokeTransparency = 1,
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Colors.Locked,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -6, 0, 6),
			Size = UDim2.fromOffset(48, 18),
			Visible = false,
			Parent = card,
		})
		Theme.corner(lock, 2)
		local marker = Theme.new("Frame", {
			BackgroundColor3 = Theme.Colors.Accent,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, 0, 0.5, 0),
			Size = UDim2.new(0, 4, 1, -10),
			Visible = false,
			Parent = card,
		})
		card.Activated:Connect(function()
			if self:IsUnlocked(id) then
				self.onSelect(id)
			end
		end)
		self.cards[id] = { button = card, name = name, lock = lock, marker = marker }
	end
	return self
end

function ClassSelect:IsUnlocked(classId: string): boolean
	local def = Classes.byId[classId]
	return def ~= nil and (def.unlockLevel or 1) <= self.level
end

function ClassSelect:SetLevel(level: number)
	self.level = level
	self:_render()
end

function ClassSelect:SetSelected(classId: string)
	self.selected = classId
	self:_render()
end

function ClassSelect:GetFirstButton(): GuiObject?
	local first = Classes.order[1]
	return first and self.cards[first].button or nil
end

function ClassSelect:_render()
	for id, card in self.cards do
		local unlocked = self:IsUnlocked(id)
		local selected = id == self.selected
		card.lock.Visible = not unlocked
		card.marker.Visible = selected
		card.name.TextColor3 = unlocked and (selected and Theme.Colors.Accent or Theme.Colors.Text)
			or Theme.Colors.TextDim
		Theme.setButtonColor(card.button, selected and Theme.Colors.Olive or Theme.Colors.PanelLight)
		card.button.BackgroundTransparency = unlocked and 0 or 0.45
	end
end

return ClassSelect
