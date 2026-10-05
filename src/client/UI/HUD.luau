--[[
	HUD: infantry heads-up display.

	  * Health bar with delayed "damage ghost", spawn-protection tag, low-health red vignette pulse.
	  * Stance figure (Stand / Crouch / Prone / Sprint) from Bus StanceChanged + character attribute.
	  * Ammo panel: weapon name, fire mode, magazine / reserve, reload bar, equipment counts
	    (Bus WeaponEquipped / AmmoChanged / FireModeChanged / ReloadStarted). Hidden in vehicles.
	  * Squad roster with health (players sharing your `Squad` attribute), refreshed at 4 Hz.
	  * Gadget hold progress (Bus GadgetProgress(fraction|nil, label)).
	  * FPS counter (setting ShowFPS) and touch shortcut buttons (map / scoreboard / settings).

	All updates are event-driven except the 4 Hz squad refresh, the 2 Hz FPS label and the
	vignette pulse which only runs while health is low.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Bus = require(Shared.Util.Bus)
local Classes = require(Shared.Config.Classes)
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Data = require(UI.Data)
local Theme = require(UI.Theme)

local HUD = {}
HUD.__index = HUD

local LOW_HEALTH = 0.35

local STANCE_SHAPES = {
	Stand = { size = UDim2.fromOffset(8, 26), rot = 0, text = "STANDING" },
	Crouch = { size = UDim2.fromOffset(10, 17), rot = 0, text = "CROUCHED" },
	Prone = { size = UDim2.fromOffset(26, 7), rot = 0, text = "PRONE" },
	Sprint = { size = UDim2.fromOffset(8, 24), rot = 18, text = "SPRINTING" },
}

local function decodeLoadout(player: Player): { [string]: string }
	local raw = player:GetAttribute("Loadout")
	if type(raw) ~= "string" or raw == "" then
		return {}
	end
	local ok, t = pcall(HttpService.JSONDecode, HttpService, raw)
	return ok and type(t) == "table" and t or {}
end

function HUD.new(ctx)
	local self = setmetatable({}, HUD)
	self.ctx = ctx
	self.trove = Trove.new()
	self.charTrove = Trove.new()
	self.visible = false
	self.infantry = true
	self.ammo = {} :: { [string]: { mag: number, reserve: number } }
	self.weaponId = nil :: string?
	self.lowHealth = false

	local root = Theme.new("Frame", {
		Name = "HUD",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = ctx.hudRoot,
	})
	self.root = root

	self:_buildHealth()
	self:_buildAmmo()
	self:_buildSquad()
	self:_buildGadgetProgress()
	self:_buildMisc()
	self:_buildVignette()
	self:_connect()
	return self
end

------------------------------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------------------------------

function HUD:_buildHealth()
	local touch = self.ctx.isTouch
	local panel = Theme.panel({
		Name = "Health",
		AnchorPoint = touch and Vector2.new(0, 0) or Vector2.new(0, 1),
		Position = touch and UDim2.fromOffset(16, 242) or UDim2.new(0, 14, 1, -10),
		Size = UDim2.fromOffset(250, 30),
		Style = "dark",
		Parent = self.root,
	})
	self.healthPanel = panel

	-- Stance figure
	local stanceBox = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.fromOffset(30, 30),
		Parent = panel,
	})
	self.stanceFigure = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -3),
		Size = STANCE_SHAPES.Stand.size,
		BackgroundColor3 = Theme.Colors.Khaki,
		BorderSizePixel = 0,
		Parent = stanceBox,
	})
	Theme.corner(self.stanceFigure, 3)

	local bar, fill = Theme.bar({
		Name = "Bar",
		Position = UDim2.fromOffset(38, 8),
		Size = UDim2.new(1, -86, 0, 14),
	}, Theme.Colors.Text)
	bar.Parent = panel
	self.healthFill = fill
	self.healthGhost = Theme.new("Frame", {
		Name = "Ghost",
		BackgroundColor3 = Theme.Colors.Danger,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 0,
		Parent = bar,
	})
	Theme.corner(self.healthGhost, 2)
	fill.ZIndex = 2
	-- Segment ticks every 25 hp
	for i = 1, 3 do
		Theme.new("Frame", {
			BackgroundColor3 = Theme.Colors.Ink,
			BackgroundTransparency = 0.4,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(i / 4, 0),
			Size = UDim2.new(0, 1, 1, 0),
			ZIndex = 3,
			Parent = bar,
		})
	end

	self.healthText = Theme.label({
		Kind = "number",
		Text = "100",
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(40, 26),
		Parent = panel,
	})
	self.protectedTag = Theme.label({
		Kind = "type",
		Text = "SPAWN PROTECTED",
		TextSize = 12,
		TextColor3 = Theme.Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 38, 0, -2),
		Size = UDim2.fromOffset(200, 14),
		Visible = false,
		Parent = panel,
	})
	self.stanceText = Theme.label({
		Kind = "type",
		Text = "STANDING",
		TextSize = 12,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -4, 0, -2),
		Size = UDim2.fromOffset(110, 14),
		Parent = panel,
	})
end

function HUD:_buildAmmo()
	local touch = self.ctx.isTouch
	local panel = Theme.panel({
		Name = "Ammo",
		AnchorPoint = Vector2.new(1, 1),
		Position = touch and UDim2.new(1, -16, 1, -230) or UDim2.new(1, -18, 1, -16),
		Size = UDim2.fromOffset(250, 104),
		Style = "dark",
		Parent = self.root,
	})
	self.ammoPanel = panel
	-- brass strip on the left edge
	Theme.new("Frame", {
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 3, 1, -12),
		Position = UDim2.fromOffset(6, 6),
		Parent = panel,
	})

	self.weaponName = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(14, 4),
		Size = UDim2.new(1, -24, 0, 22),
		Parent = panel,
	})
	self.fireMode = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 13,
		TextColor3 = Theme.Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(16, 6),
		Size = UDim2.fromOffset(80, 18),
		Parent = panel,
	})
	self.magText = Theme.label({
		Kind = "number",
		Text = "—",
		TextSize = 44,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -78, 0, 22),
		Size = UDim2.fromOffset(110, 46),
		Parent = panel,
	})
	self.reserveText = Theme.label({
		Kind = "number",
		Text = "",
		TextSize = 22,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 38),
		Size = UDim2.fromOffset(66, 26),
		Parent = panel,
	})
	Theme.label({
		Kind = "number",
		Text = "/",
		TextSize = 22,
		TextColor3 = Theme.Colors.TextDim,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -66, 0, 38),
		Size = UDim2.fromOffset(12, 26),
		Parent = panel,
	})
	self.reloadHint = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 13,
		TextColor3 = Theme.Colors.Danger,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(16, 46),
		Size = UDim2.fromOffset(90, 16),
		Parent = panel,
	})
	local reloadBar, reloadFill = Theme.bar({
		Position = UDim2.new(0, 16, 0, 70),
		Size = UDim2.new(1, -26, 0, 3),
		Visible = false,
	}, Theme.Colors.Accent)
	reloadBar.Parent = panel
	self.reloadBar, self.reloadFill = reloadBar, reloadFill

	-- Equipment counts (gadget1 / gadget2)
	local equip = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 14, 1, -28),
		Size = UDim2.new(1, -24, 0, 22),
		Parent = panel,
	})
	Theme.list(equip, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center)
	self.equipChips = {}
	for i, slot in { "gadget1", "gadget2" } do
		local chip = Theme.new("Frame", {
			BackgroundColor3 = Theme.Colors.PanelLight,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(110, 20),
			LayoutOrder = i,
			Parent = equip,
		})
		Theme.corner(chip, 3)
		local key = Theme.label({
			Kind = "title",
			Text = tostring(i + 2),
			TextSize = 12,
			TextColor3 = Theme.Colors.Ink,
			TextStrokeTransparency = 1,
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Colors.Khaki,
			Size = UDim2.fromOffset(16, 20),
			Parent = chip,
		})
		Theme.corner(key, 3)
		local name = Theme.label({
			Kind = "bold",
			Text = "",
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(20, 0),
			Size = UDim2.new(1, -46, 1, 0),
			Parent = chip,
		})
		local count = Theme.label({
			Kind = "number",
			Text = "",
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -4, 0, 0),
			Size = UDim2.fromOffset(26, 20),
			Parent = chip,
		})
		self.equipChips[slot] = { frame = chip, name = name, count = count }
	end
end

function HUD:_buildSquad()
	local touch = self.ctx.isTouch
	local panel = Theme.new("Frame", {
		Name = "Squad",
		BackgroundTransparency = 1,
		AnchorPoint = touch and Vector2.new(0, 0) or Vector2.new(0, 1),
		Position = touch and UDim2.fromOffset(16, 282) or UDim2.new(0, 14, 1, -280),
		Size = UDim2.fromOffset(200, 120),
		Parent = self.root,
	})
	Theme.list(
		panel,
		Enum.FillDirection.Vertical,
		3,
		nil,
		touch and Enum.VerticalAlignment.Top or Enum.VerticalAlignment.Bottom
	)
	self.squadHeader = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 14,
		TextColor3 = Theme.Colors.Squad,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 0,
		Parent = panel,
	})
	self.squadRows = {}
	for i = 1, 5 do
		local row = Theme.new("Frame", {
			BackgroundColor3 = Theme.Colors.PanelDark,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 20),
			LayoutOrder = i,
			Visible = false,
			Parent = panel,
		})
		Theme.corner(row, 3)
		local class = Theme.label({
			Kind = "title",
			Text = "",
			TextSize = 10,
			TextColor3 = Theme.Colors.Ink,
			TextStrokeTransparency = 1,
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Colors.Squad,
			Size = UDim2.fromOffset(28, 20),
			Parent = row,
		})
		Theme.corner(class, 3)
		local name = Theme.label({
			Kind = "bold",
			Text = "",
			TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(32, 0),
			Size = UDim2.new(1, -96, 1, 0),
			Parent = row,
		})
		local bar, fill = Theme.bar({
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(54, 5),
		}, Theme.Colors.Squad)
		bar.Parent = row
		self.squadRows[i] = { frame = row, class = class, name = name, fill = fill, bar = bar }
	end
	self.squadPanel = panel
end

function HUD:_buildGadgetProgress()
	local panel = Theme.panel({
		Name = "GadgetProgress",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.7),
		Size = UDim2.fromOffset(260, 46),
		Style = "dark",
		Visible = false,
		Parent = self.root,
	})
	self.gadgetLabel = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 15,
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = panel,
	})
	local bar, fill = Theme.bar({
		Position = UDim2.new(0, 12, 0, 28),
		Size = UDim2.new(1, -24, 0, 8),
	}, Theme.Colors.Accent)
	bar.Parent = panel
	self.gadgetPanel, self.gadgetFill = panel, fill
end

function HUD:_buildMisc()
	self.fpsLabel = Theme.label({
		Name = "FPS",
		Kind = "number",
		Text = "",
		TextSize = 13,
		TextColor3 = Theme.Colors.Good,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 4),
		Size = UDim2.fromOffset(80, 16),
		Visible = false,
		Parent = self.root,
	})

	-- Touch shortcuts (phones / tablets have no Tab / M / P keys).
	if self.ctx.isTouch then
		local row = Theme.new("Frame", {
			Name = "TouchButtons",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -14, 0, 22),
			Size = UDim2.fromOffset(190, 34),
			Parent = self.root,
		})
		Theme.list(row, Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right)
		local function btn(text: string, order: number, fn: () -> ())
			local b = Theme.button({
				Text = text,
				TextSize = 13,
				Size = UDim2.fromOffset(58, 34),
				LayoutOrder = order,
				Variant = "ghost",
				Parent = row,
			})
			b.Activated:Connect(fn)
		end
		btn("MAP", 1, function()
			self.ctx.ui.ToggleMenu("BigMap")
		end)
		btn("SCORE", 2, function()
			self.ctx.ui.ToggleScoreboard()
		end)
		btn("MENU", 3, function()
			self.ctx.ui.ToggleMenu("Settings")
		end)
	end
end

function HUD:_buildVignette()
	-- Four edge frames with transparency gradients form a red vignette (no image assets).
	local vignette = Theme.new("Frame", {
		Name = "LowHealthVignette",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = self.ctx.fxRoot,
	})
	local edges = {
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(1, 0.3), rot = 90 },
		{ pos = UDim2.fromScale(0, 0.7), size = UDim2.fromScale(1, 0.3), rot = -90 },
		{ pos = UDim2.fromScale(0, 0), size = UDim2.fromScale(0.25, 1), rot = 0 },
		{ pos = UDim2.fromScale(0.75, 0), size = UDim2.fromScale(0.25, 1), rot = 180 },
	}
	self.vignetteGradients = {}
	for _, e in edges do
		local f = Theme.new("Frame", {
			BackgroundColor3 = Color3.fromRGB(140, 10, 6),
			BorderSizePixel = 0,
			Position = e.pos,
			Size = e.size,
			Parent = vignette,
		})
		local g = Theme.new("UIGradient", {
			Rotation = e.rot,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.2),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = f,
		})
		table.insert(self.vignetteGradients, f)
		local _ = g
	end
	self.vignette = vignette
end

------------------------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------------------------

function HUD:_connect()
	local t = self.trove
	t:Add(Bus.connect("WeaponEquipped", function(weaponId: string, _slot: string)
		self.weaponId = weaponId
		self:_renderWeapon()
	end))
	t:Add(Bus.connect("WeaponUnequipped", function()
		self.weaponId = nil
		self:_renderWeapon()
	end))
	t:Add(Bus.connect("AmmoChanged", function(weaponId: string, mag: number, reserve: number)
		self.ammo[weaponId] = { mag = mag, reserve = reserve }
		if weaponId == self.weaponId then
			self:_renderAmmo()
		end
		self:_renderEquipment()
	end))
	t:Add(Bus.connect("FireModeChanged", function(mode: string)
		self.fireMode.Text = string.upper(tostring(mode or ""))
	end))
	t:Add(Bus.connect("ReloadStarted", function(weaponId: string, duration: number)
		if weaponId ~= self.weaponId then
			return
		end
		self.reloadBar.Visible = true
		self.reloadFill.Size = UDim2.fromScale(0, 1)
		local tw = Theme.tween(
			self.reloadFill,
			math.max(duration or 1, 0.05),
			{ Size = UDim2.fromScale(1, 1) },
			Enum.EasingStyle.Linear
		)
		tw.Completed:Once(function()
			self.reloadBar.Visible = false
		end)
		self.reloadHint.Text = "RELOADING"
		self.reloadHint.TextColor3 = Theme.Colors.Accent
	end))
	t:Add(Bus.connect("StanceChanged", function(stance: string)
		self:_renderStance(stance)
	end))
	t:Add(Bus.connect("GadgetProgress", function(fraction: number?, label: string?)
		if type(fraction) ~= "number" then
			self.gadgetPanel.Visible = false
			return
		end
		self.gadgetPanel.Visible = self.visible
		self.gadgetLabel.Text = string.upper(label or "")
		self.gadgetFill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	end))
	t:Add(self.ctx.player:GetAttributeChangedSignal("Loadout"):Connect(function()
		self:_renderEquipment()
	end))
	t:Add(self.ctx.player:GetAttributeChangedSignal("Squad"):Connect(function()
		self:_renderSquad()
	end))

	-- Low-frequency updates: squad roster (4 Hz), FPS (2 Hz), vignette pulse (only when low).
	local squadAcc, fpsAcc, frames = 0, 0, 0
	t:Add(RunService.RenderStepped:Connect(function(dt)
		if not self.visible then
			return
		end
		squadAcc += dt
		if squadAcc >= 0.25 then
			squadAcc = 0
			self:_renderSquad()
		end
		if self.showFps then
			frames += 1
			fpsAcc += dt
			if fpsAcc >= 0.5 then
				self.fpsLabel.Text = string.format("%d FPS", math.floor(frames / fpsAcc + 0.5))
				frames, fpsAcc = 0, 0
			end
		end
		if self.lowHealth then
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * 5)
			local alpha = 0.15 + pulse * 0.35 + self.healthFraction * 0.9
			for _, f in self.vignetteGradients do
				f.BackgroundTransparency = math.clamp(alpha, 0, 1)
			end
		end
	end))
	self:OnSettingsChanged()
end

------------------------------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------------------------------

function HUD:_renderWeapon()
	local def = Data.weapon(self.weaponId)
	self.weaponName.Text = self.weaponId and string.upper(Data.weaponName(self.weaponId)) or ""
	if def and type(def.fireModes) == "table" and def.fireModes[1] and self.fireMode.Text == "" then
		self.fireMode.Text = string.upper(def.fireModes[1])
	end
	if not self.weaponId then
		self.fireMode.Text = ""
	end
	self.reloadBar.Visible = false
	self:_renderAmmo()
end

function HUD:_renderAmmo()
	local a = self.weaponId and self.ammo[self.weaponId]
	if not a then
		self.magText.Text = self.weaponId and "—" or ""
		self.reserveText.Text = ""
		self.reloadHint.Text = ""
		return
	end
	self.magText.Text = tostring(a.mag)
	self.reserveText.Text = tostring(a.reserve)
	local def = Data.weapon(self.weaponId)
	local magSize = def and tonumber(def.magazine) or nil
	local low = magSize and magSize > 1 and a.mag <= math.max(1, math.floor(magSize * 0.25))
	self.magText.TextColor3 = (a.mag == 0 or low) and Theme.Colors.Danger or Theme.Colors.Text
	self.reserveText.TextColor3 = a.reserve == 0 and Theme.Colors.Danger or Theme.Colors.TextDim
	if a.mag == 0 and a.reserve == 0 then
		self.reloadHint.Text = "NO AMMO"
		self.reloadHint.TextColor3 = Theme.Colors.Danger
	elseif low or a.mag == 0 then
		local key = UserInputService:GetLastInputType().Name:find("Gamepad") and "[X]" or "[R]"
		self.reloadHint.Text = self.ctx.isTouch and "RELOAD" or ("RELOAD " .. key)
		self.reloadHint.TextColor3 = Theme.Colors.Danger
	else
		self.reloadHint.Text = ""
	end
end

function HUD:_renderEquipment()
	local loadout = decodeLoadout(self.ctx.player)
	for slot, chip in self.equipChips do
		local id = loadout[slot]
		if type(id) == "string" and id ~= "" then
			chip.frame.Visible = true
			chip.name.Text = string.upper(Data.weaponName(id))
			local a = self.ammo[id]
			chip.count.Text = a and ("×" .. tostring(a.mag + a.reserve)) or ""
			chip.frame.BackgroundTransparency = (a and a.mag + a.reserve == 0) and 0.6 or 0.2
		else
			chip.frame.Visible = false
		end
	end
end

function HUD:_renderStance(stance: string?)
	local shape = STANCE_SHAPES[stance or "Stand"] or STANCE_SHAPES.Stand
	Theme.tween(self.stanceFigure, 0.15, { Size = shape.size, Rotation = shape.rot })
	self.stanceText.Text = shape.text
end

function HUD:_renderHealth(health: number, maxHealth: number, instant: boolean?)
	local frac = maxHealth > 0 and math.clamp(health / maxHealth, 0, 1) or 0
	local previous = self.healthFraction or 1
	self.healthFraction = frac
	self.healthText.Text = tostring(math.ceil(health))
	local color = frac <= LOW_HEALTH and Theme.Colors.Danger or Theme.Colors.Text
	self.healthFill.BackgroundColor3 = color
	self.healthText.TextColor3 = color
	if instant then
		self.healthFill.Size = UDim2.fromScale(frac, 1)
		self.healthGhost.Size = UDim2.fromScale(frac, 1)
	else
		Theme.tween(self.healthFill, 0.12, { Size = UDim2.fromScale(frac, 1) })
		if frac < previous then
			-- ghost lingers, then drains
			task.delay(0.45, function()
				Theme.tween(self.healthGhost, 0.4, { Size = UDim2.fromScale(self.healthFraction, 1) })
			end)
		else
			self.healthGhost.Size = UDim2.fromScale(frac, 1)
		end
	end
	self.lowHealth = frac > 0 and frac <= LOW_HEALTH
	self.vignette.Visible = self.lowHealth and self.visible
end

function HUD:_renderSquad()
	local me = self.ctx.player
	local squad = me:GetAttribute("Squad") or 0
	local side = me:GetAttribute("Side")
	local members = {}
	if squad ~= 0 then
		for _, p in Players:GetPlayers() do
			if p ~= me and p:GetAttribute("Squad") == squad and p:GetAttribute("Side") == side then
				table.insert(members, p)
			end
		end
		table.sort(members, function(a, b)
			return a.Name < b.Name
		end)
	end
	self.squadHeader.Text = squad ~= 0 and string.format("SQUAD %d", squad) or ""
	self.squadHeader.Visible = squad ~= 0
	for i, row in self.squadRows do
		local p = members[i]
		if p then
			row.frame.Visible = true
			local leader = p:GetAttribute("SquadLeader") == true
			row.name.Text = (leader and "★ " or "") .. p.DisplayName
			local class = Classes.byId[p:GetAttribute("Class") or ""]
			row.class.Text = class and class.icon or "—"
			local alive = p:GetAttribute("Alive") ~= false
			local hum = alive and Data.humanoid(p) or nil
			local frac = hum and hum.MaxHealth > 0 and math.clamp(hum.Health / hum.MaxHealth, 0, 1) or 0
			row.fill.Size = UDim2.fromScale(frac, 1)
			row.fill.BackgroundColor3 = frac <= LOW_HEALTH and Theme.Colors.Danger or Theme.Colors.Squad
			row.name.TextColor3 = alive and Theme.Colors.Text or Theme.Colors.TextDim
			row.class.BackgroundColor3 = alive and Theme.Colors.Squad or Theme.Colors.Locked
			if not alive then
				row.name.Text ..= "  · KIA"
			end
		else
			row.frame.Visible = false
		end
	end
end

------------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------------

function HUD:SetCharacter(character: Model?)
	self.charTrove:Clean()
	self.ammo = {}
	self.weaponId = nil
	self.fireMode.Text = ""
	self:_renderWeapon()
	self:_renderEquipment()
	if not character then
		self:_renderHealth(0, 100, true)
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end
	local hum = humanoid :: Humanoid
	self:_renderHealth(hum.Health, hum.MaxHealth, true)
	self.charTrove:Add(hum.HealthChanged:Connect(function(h)
		self:_renderHealth(h, hum.MaxHealth)
	end))
	self.charTrove:Add(hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
		self:_renderHealth(hum.Health, hum.MaxHealth, true)
	end))
	local function stance()
		local s = character:GetAttribute("Stance")
		self:_renderStance(type(s) == "string" and s or "Stand")
	end
	stance()
	self.charTrove:Add(character:GetAttributeChangedSignal("Stance"):Connect(stance))
	local function protected()
		self.protectedTag.Visible = character:GetAttribute("SpawnProtected") == true
	end
	protected()
	self.charTrove:Add(character:GetAttributeChangedSignal("SpawnProtected"):Connect(protected))
end

-- Infantry-only elements (ammo / equipment) are hidden while in a vehicle (Vehicle team owns that HUD).
function HUD:SetInfantry(infantry: boolean)
	self.infantry = infantry
	self.ammoPanel.Visible = infantry
end

function HUD:SetVisible(visible: boolean)
	self.visible = visible
	self.root.Visible = visible
	self.vignette.Visible = visible and self.lowHealth
	if not visible then
		self.gadgetPanel.Visible = false
	end
end

function HUD:OnSettingsChanged()
	self.showFps = self.ctx.settings.Get("ShowFPS") == true
	self.fpsLabel.Visible = self.showFps
end

function HUD:Destroy()
	self.trove:Clean()
	self.charTrove:Clean()
	self.root:Destroy()
	self.vignette:Destroy()
end

return HUD
