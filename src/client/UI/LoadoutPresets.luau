--[[
	LoadoutPresets (Monetization team): a "PRESETS" button for the deploy screen top bar that opens a
	dropdown of saved class + loadout presets (LOAD / SAVE CURRENT / CLEAR per slot).

	Everyone gets Monetization.BASE_PRESETS slots; the "Extra Loadout Presets" pass adds
	Monetization.EXTRA_PRESETS more (locked slots are shown and open the store). Presets are stored
	server-side by MonetizationService (`Shop_SavePreset {index, classId?, loadout?}`, state from
	`Shop_GetState` / `Shop_Updated`); the server re-validates the loadout at deploy time as usual.

	  local presets = LoadoutPresets.new(ctx, buttonParent, popupParent, buttonProps, popupPosition, getCurrent, apply)
	    (the popup is anchored by its top-right corner at `popupPosition` inside `popupParent`)
	    getCurrent() -> (classId, loadout)      apply(classId, loadout)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Classes = require(Shared.Config.Classes)
local Monetization = require(Shared.Config.Monetization)
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Data = require(UI.Data)
local Remotes = require(UI.Remotes)
local Theme = require(UI.Theme)

local LoadoutPresets = {}
LoadoutPresets.__index = LoadoutPresets

local ROW_HEIGHT = 40
local MAX_SLOTS = Monetization.BASE_PRESETS + Monetization.EXTRA_PRESETS

function LoadoutPresets.new(
	ctx,
	buttonParent: Instance,
	popupParent: Instance,
	buttonProps: { [string]: any },
	popupPosition: UDim2,
	getCurrent: () -> (string, { [string]: string }),
	apply: (string, { [string]: string }) -> ()
)
	local self = setmetatable({}, LoadoutPresets)
	self.ctx = ctx
	self.trove = Trove.new()
	self.rowTrove = Trove.new()
	self.getCurrent = getCurrent
	self.apply = apply
	self.presets = {} :: { [string]: any }
	self.limit = Monetization.BASE_PRESETS
	self.open = false

	local props = table.clone(buttonProps)
	props.Text = "PRESETS"
	props.TextSize = props.TextSize or 15
	props.Variant = "ghost"
	props.Parent = buttonParent
	self.button = Theme.button(props)
	self.trove:Add(self.button.Activated:Connect(function()
		self:SetOpen(not self.open)
	end))

	local popup = Theme.panel({
		Name = "PresetsPopup",
		Style = "dark",
		AnchorPoint = Vector2.new(1, 0),
		Position = popupPosition,
		Size = UDim2.fromOffset(420, 36 + MAX_SLOTS * (ROW_HEIGHT + 4)),
		Visible = false,
		ZIndex = 50,
		Parent = popupParent,
	})
	Theme.padding(popup, 8)
	Theme.header("Loadout presets", { Parent = popup })
	local list = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 32),
		Size = UDim2.new(1, 0, 1, -32),
		Parent = popup,
	})
	Theme.list(list, Enum.FillDirection.Vertical, 4)
	self.popup = popup
	self.list = list
	self.trove:Add(popup)

	Remotes.onEvent("Shop_Updated", function(state)
		self:_setState(state)
	end, self.trove)
	task.spawn(function()
		local ok, state = Remotes.invoke("Shop_GetState", 15)
		if ok then
			self:_setState(state)
		end
	end)
	return self
end

function LoadoutPresets:_setState(state: any)
	if type(state) ~= "table" then
		return
	end
	self.presets = type(state.presets) == "table" and state.presets or {}
	self.limit = math.clamp(tonumber(state.presetLimit) or Monetization.BASE_PRESETS, 0, MAX_SLOTS)
	if self.open then
		self:_render()
	end
end

local function describe(preset: any): string
	local class = Classes.get(preset.classId)
	local primary = preset.primary ~= "" and Data.weaponName(preset.primary) or "Standard issue"
	return string.upper(class and class.name or preset.classId) .. "  ·  " .. primary
end

function LoadoutPresets:_render()
	self.rowTrove:Clean()
	for _, child in self.list:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	for i = 1, MAX_SLOTS do
		local key = tostring(i)
		local preset = self.presets[key]
		local locked = i > self.limit
		local row = Theme.panel({
			Style = "light",
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			LayoutOrder = i,
			Parent = self.list,
		})
		Theme.label({
			Kind = "number",
			Text = tostring(i),
			TextSize = 18,
			TextColor3 = Theme.Colors.Accent,
			Size = UDim2.new(0, 26, 1, 0),
			Parent = row,
		})
		Theme.label({
			Kind = if preset then "heading" else "type",
			Text = if locked then "LOCKED · EXTRA PRESETS PASS" elseif preset then describe(preset) else "EMPTY",
			TextSize = if preset and not locked then 14 else 12,
			TextColor3 = if locked
				then Theme.Colors.Locked
				elseif preset then Theme.Colors.Text
				else Theme.Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(28, 0),
			Size = UDim2.new(1, -200, 1, 0),
			Parent = row,
		})
		local function addButton(text: string, x: number, width: number, variant: string?, fn: () -> ())
			local btn = Theme.button({
				Text = text,
				TextSize = 13,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, x, 0.5, 0),
				Size = UDim2.fromOffset(width, 28),
				Variant = variant,
				Parent = row,
			})
			self.rowTrove:Add(btn.Activated:Connect(fn))
		end
		if locked then
			addButton("STORE", -4, 70, "primary", function()
				self:SetOpen(false)
				self.ctx.ui.OpenMenu("Shop")
			end)
		else
			addButton("SAVE", -4, 52, nil, function()
				local classId, loadout = self.getCurrent()
				Remotes.fire("Shop_SavePreset", { index = i, classId = classId, loadout = loadout })
			end)
			if preset then
				addButton("LOAD", -60, 52, "primary", function()
					local loadout = {
						primary = preset.primary,
						secondary = preset.secondary,
						gadget1 = preset.gadget1,
						gadget2 = preset.gadget2,
					}
					self.apply(preset.classId, loadout)
					self:SetOpen(false)
				end)
				addButton("X", -116, 30, "ghost", function()
					Remotes.fire("Shop_SavePreset", { index = i })
				end)
			end
		end
	end
end

function LoadoutPresets:SetOpen(open: boolean)
	self.open = open
	self.popup.Visible = open
	if open then
		self:_render()
	end
end

function LoadoutPresets:Destroy()
	self.rowTrove:Clean()
	self.trove:Clean()
end

return LoadoutPresets
