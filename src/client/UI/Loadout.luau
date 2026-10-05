--[[
	Loadout: per-slot weapon picker for the selected class / faction / level.

	  [PRIMARY    M1 Garand          ]   <- slot buttons (click to choose that slot)
	  [SIDEARM    M1911              ]
	  [EQUIPMENT 1  Mk 2 Grenade      ]
	  [EQUIPMENT 2  Smoke Grenade     ]
	  ┌ weapon list for active slot ┐  ┌ stats ┐
	  │ name · category · LVL lock   │  │ bars  │

	Weapons come from Config/Weapons (Combat team) through Data.weaponsFor. If the config is not
	available the slots read "STANDARD ISSUE" and the server picks defaults.

	  local lo = Loadout.new(parent, onChanged)
	  lo:SetContext(classId, factionId, level, unlocked, preferred?)
	  lo:Get() -> {primary, secondary, gadget1, gadget2}
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Classes = require(Shared.Config.Classes)

local UI = script.Parent
local Data = require(UI.Data)
local Theme = require(UI.Theme)

local Loadout = {}
Loadout.__index = Loadout

function Loadout.new(parent: GuiObject, onChanged: (loadout: { [string]: string }) -> ())
	local self = setmetatable({}, Loadout)
	self.onChanged = onChanged
	self.classId = "Rifleman"
	self.factionId = nil :: string?
	self.level = 1
	self.unlocked = {} :: { [string]: any }
	self.loadout = {} :: { [string]: string }
	self.activeSlot = "primary"
	self.slotButtons = {} :: { [string]: any }
	self.listButtons = {} :: { TextButton }

	local root = Theme.new("Frame", {
		Name = "Loadout",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	self.root = root

	self.className = Theme.label({
		Kind = "title",
		Text = "",
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = root,
	})
	self.classDesc = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 13,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, 30),
		Size = UDim2.new(1, 0, 0, 32),
		Parent = root,
	})

	-- Slot buttons
	local slots = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 66),
		Size = UDim2.new(1, 0, 0, 4 * 44),
		Parent = root,
	})
	Theme.list(slots, Enum.FillDirection.Vertical, 4)
	for i, slot in Data.SLOTS do
		local btn = Theme.button({
			Name = slot,
			Text = "",
			Size = UDim2.new(1, 0, 0, 40),
			LayoutOrder = i,
			Parent = slots,
		})
		Theme.label({
			Kind = "type",
			Text = Data.SLOT_LABELS[slot],
			TextSize = 12,
			TextColor3 = Theme.Colors.Khaki,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(10, 2),
			Size = UDim2.new(1, -20, 0, 14),
			Parent = btn,
		})
		local name = Theme.label({
			Kind = "heading",
			Text = "",
			TextSize = 17,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(10, 16),
			Size = UDim2.new(1, -20, 0, 22),
			Parent = btn,
		})
		btn.Activated:Connect(function()
			self.activeSlot = slot
			self:_renderSlots()
			self:_renderList()
		end)
		self.slotButtons[slot] = { button = btn, name = name }
	end

	-- Weapon list + stats
	local lower = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 66 + 4 * 44 + 8),
		Size = UDim2.new(1, 0, 1, -(66 + 4 * 44 + 8)),
		Parent = root,
	})
	local listPanel = Theme.panel({
		Style = "dark",
		Size = UDim2.new(0.56, -4, 1, 0),
		Parent = lower,
	})
	local list = Theme.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(4, 4),
		Size = UDim2.new(1, -8, 1, -8),
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.Colors.Khaki,
		Parent = listPanel,
	})
	Theme.list(list, Enum.FillDirection.Vertical, 3)
	self.list = list

	local stats = Theme.panel({
		Style = "dark",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.44, -4, 1, 0),
		Parent = lower,
	})
	Theme.padding(stats, 8)
	self.statName = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, 20),
		Parent = stats,
	})
	self.statDesc = Theme.label({
		Kind = "body",
		Text = "",
		TextSize = 12,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, 20),
		Size = UDim2.new(1, 0, 0, 44),
		Parent = stats,
	})
	self.statRows = {}
	for i = 1, 5 do
		local y = 68 + (i - 1) * 24
		local label = Theme.label({
			Kind = "type",
			Text = "",
			TextSize = 11,
			TextColor3 = Theme.Colors.Khaki,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, 12),
			Parent = stats,
		})
		local bar, fill = Theme.bar({
			Position = UDim2.fromOffset(0, y + 13),
			Size = UDim2.new(1, 0, 0, 6),
		}, Theme.Colors.Khaki)
		bar.Parent = stats
		self.statRows[i] = { label = label, bar = bar, fill = fill }
	end
	self.statFoot = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 12,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 16),
		Parent = stats,
	})
	return self
end

------------------------------------------------------------------------------------------------

function Loadout:_available(slot: string): { any }
	return Data.weaponsFor(self.classId, slot, self.factionId)
end

function Loadout:_isUnlocked(def): boolean
	return Data.isUnlocked(def, self.level, self.unlocked)
end

-- Ensures every slot holds a valid, unlocked weapon (keeping `preferred` choices when possible).
function Loadout:_validate(preferred: { [string]: string }?)
	local result = {}
	for _, slot in Data.SLOTS do
		local options = self:_available(slot)
		local want = (preferred and preferred[slot]) or self.loadout[slot]
		local chosen = nil
		for _, def in options do
			if def.id == want and self:_isUnlocked(def) then
				chosen = def.id
				break
			end
		end
		if not chosen then
			for _, def in options do
				if self:_isUnlocked(def) then
					chosen = def.id
					break
				end
			end
		end
		result[slot] = chosen
	end
	self.loadout = result
end

function Loadout:SetContext(
	classId: string,
	factionId: string?,
	level: number,
	unlocked: { [string]: any }?,
	preferred: { [string]: string }?
)
	local changedClass = classId ~= self.classId
	self.classId = classId
	self.factionId = factionId
	self.level = level
	self.unlocked = unlocked or {}
	if changedClass then
		self.loadout = {}
		self.activeSlot = "primary"
	end
	self:_validate(preferred)
	local class = Classes.byId[classId]
	self.className.Text = class and string.upper(class.name) or ""
	self.classDesc.Text = class and class.description or ""
	self:_renderSlots()
	self:_renderList()
end

function Loadout:Get(): { [string]: string }
	return table.clone(self.loadout)
end

function Loadout:GetFirstButton(): GuiObject?
	return self.slotButtons.primary.button
end

function Loadout:_renderSlots()
	for slot, s in self.slotButtons do
		local id = self.loadout[slot]
		s.name.Text = id and string.upper(Data.weaponName(id)) or "STANDARD ISSUE"
		local active = slot == self.activeSlot
		Theme.setButtonColor(s.button, active and Theme.Colors.Olive or Theme.Colors.PanelLight)
		s.name.TextColor3 = active and Theme.Colors.Accent or Theme.Colors.Text
	end
end

function Loadout:_showStats(def)
	if not def then
		self.statName.Text = ""
		self.statDesc.Text = "No weapon data available. The quartermaster will issue standard equipment."
		self.statFoot.Text = ""
		for _, row in self.statRows do
			row.label.Visible = false
			row.bar.Visible = false
		end
		return
	end
	self.statName.Text = string.upper(def.name or def.id)
	self.statDesc.Text = def.description or ""
	local stats = Data.stats(def) or {}
	for i, row in self.statRows do
		local s = stats[i]
		row.label.Visible = s ~= nil
		row.bar.Visible = s ~= nil
		if s then
			row.label.Text = s.label
			row.fill.Size = UDim2.fromScale(s.value, 1)
		end
	end
	local foot = {}
	if def.magazine then
		table.insert(foot, string.format("MAG %d", def.magazine))
	end
	if def.rpm then
		table.insert(foot, string.format("%d RPM", def.rpm))
	end
	if type(def.fireModes) == "table" and #def.fireModes > 0 then
		table.insert(foot, string.upper(table.concat(def.fireModes, "/")))
	end
	self.statFoot.Text = table.concat(foot, "  ·  ")
end

function Loadout:_renderList()
	for _, b in self.listButtons do
		b:Destroy()
	end
	self.listButtons = {}
	local options = self:_available(self.activeSlot)
	local selectedId = self.loadout[self.activeSlot]
	for i, def in options do
		local unlocked = self:_isUnlocked(def)
		local selected = def.id == selectedId
		local btn = Theme.button({
			Name = def.id,
			Text = "",
			Size = UDim2.new(1, -6, 0, 34),
			LayoutOrder = i,
			Variant = if selected then nil else "ghost",
			Parent = self.list,
		})
		if selected then
			Theme.setButtonColor(btn, Theme.Colors.Olive)
		end
		Theme.label({
			Kind = "heading",
			Text = string.upper(def.name or def.id),
			TextSize = 15,
			TextColor3 = unlocked and (selected and Theme.Colors.Accent or Theme.Colors.Text) or Theme.Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(8, 0),
			Size = UDim2.new(1, -70, 0, 20),
			Parent = btn,
		})
		Theme.label({
			Kind = "type",
			Text = string.upper(def.category or ""),
			TextSize = 10,
			TextColor3 = Theme.Colors.Khaki,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(8, 19),
			Size = UDim2.new(1, -70, 0, 12),
			Parent = btn,
		})
		if not unlocked then
			local lock = Theme.label({
				Kind = "title",
				Text = "LVL " .. tostring(def.unlockLevel or 1),
				TextSize = 11,
				TextColor3 = Theme.Colors.Ink,
				TextStrokeTransparency = 1,
				BackgroundTransparency = 0,
				BackgroundColor3 = Theme.Colors.Locked,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6, 0.5, 0),
				Size = UDim2.fromOffset(48, 18),
				Parent = btn,
			})
			Theme.corner(lock, 2)
		end
		btn.MouseEnter:Connect(function()
			self:_showStats(def)
		end)
		btn.SelectionGained:Connect(function()
			self:_showStats(def)
		end)
		btn.MouseLeave:Connect(function()
			self:_showStats(Data.weapon(self.loadout[self.activeSlot]))
		end)
		btn.Activated:Connect(function()
			if not unlocked then
				return
			end
			self.loadout[self.activeSlot] = def.id
			self:_renderSlots()
			self:_renderList()
			self.onChanged(self:Get())
		end)
		table.insert(self.listButtons, btn)
	end
	if #options == 0 then
		local empty = Theme.label({
			Kind = "type",
			Text = "STANDARD ISSUE",
			TextSize = 14,
			TextColor3 = Theme.Colors.TextDim,
			Size = UDim2.new(1, 0, 0, 30),
			Parent = self.list,
		})
		table.insert(self.listButtons, empty :: any)
	end
	self:_showStats(Data.weapon(selectedId))
end

function Loadout:Destroy()
	self.root:Destroy()
end

return Loadout
