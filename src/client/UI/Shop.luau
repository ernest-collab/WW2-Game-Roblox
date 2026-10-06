--[[
	Shop (Monetization team): the "Quartermaster's Store" overlay (K key / STORE button on the deploy
	screen) + a small XP-multiplier badge on the HUD + VIP chat tag.

	  ┌ QUARTERMASTER'S STORE ·  XP x2.25  · BOOST 0:42:10 ───────────────────── [X] ┐
	  │ [PASSES] [BOOSTS] [WEAPON UNLOCKS] [COSMETICS] [SUPPORT]                    │
	  │  cards / lists for the active tab                                            │
	  └──────────────────────────────────────────────────────────────────────────────┘

	Everything is server-driven: state from `Shop_GetState` / `Shop_Updated` (MonetizationService),
	purchases go through `Shop_Purchase {kind, key}`, early weapon access through
	`Shop_RequestUnlock {weaponId}`, cosmetics through `Shop_SetCosmetic {camo?, uniform?}`.
	Prices are shown with the text "R$" (no image assets). Items without a Creator Dashboard id are
	never sent by the server, so an unconfigured store shows "The store is not open yet".

	  local shop = Shop.new(ctx)
	  shop:SetVisible(bool) / shop:IsVisible() / shop:SetHudVisible(bool) / shop:Destroy()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Factions = require(Shared.Config.Factions)
local Monetization = require(Shared.Config.Monetization)
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Data = require(UI.Data)
local Remotes = require(UI.Remotes)
local Theme = require(UI.Theme)

local Shop = {}
Shop.__index = Shop

local LOCAL_PLAYER = Players.LocalPlayer
local GOLD = Color3.fromRGB(255, 204, 64)
local TABS = {
	{ id = "Passes", label = "PASSES" },
	{ id = "Boosts", label = "BOOSTS" },
	{ id = "Unlocks", label = "WEAPON UNLOCKS" },
	{ id = "Cosmetics", label = "COSMETICS" },
	{ id = "Support", label = "SUPPORT" },
}

local function formatDuration(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local h = s // 3600
	return string.format("%d:%02d:%02d", h, (s % 3600) // 60, s % 60)
end

local function formatMultiplier(m: number): string
	local text = string.format("%.2f", m)
	text = string.gsub(text, "0+$", "")
	text = string.gsub(text, "%.$", "")
	return "x" .. text
end

-- VIP chat tag (only when the experience uses TextChatService and nobody else claimed the callback).
local function installChatTag()
	local ok = pcall(function()
		if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
			return
		end
		TextChatService.OnIncomingMessage = function(message: TextChatMessage)
			local props = Instance.new("TextChatMessageProperties")
			local source = message.TextSource
			local sender = source and Players:GetPlayerByUserId(source.UserId)
			if sender and sender:GetAttribute("VIP") == true then
				props.PrefixText = '<font color="#FFCC40">[VIP]</font> ' .. message.PrefixText
			elseif sender and sender:GetAttribute("Supporter") == true then
				props.PrefixText = '<font color="#BDAC80">[SUPPORTER]</font> ' .. message.PrefixText
			end
			return props
		end
	end)
	if not ok then
		warn("[Shop] could not install chat tags")
	end
end

function Shop.new(ctx)
	local self = setmetatable({}, Shop)
	self.ctx = ctx
	self.trove = Trove.new()
	self.contentTrove = Trove.new()
	self.visible = false
	self.hudVisible = false
	self.tab = "Passes"
	self.state = nil :: any
	self.timeOffset = 0 -- server os.time() - local os.time()
	self.tabButtons = {} :: { [string]: TextButton }
	self.countdowns = {} :: { TextLabel }

	-- Dim backdrop + centred panel (menu layer, above the deploy screen).
	local root = Theme.new("Frame", {
		Name = "Shop",
		BackgroundColor3 = Theme.Colors.Ink,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 40,
		Parent = ctx.menuRoot,
	})
	self.root = root
	local panel = Theme.panel({
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -120, 1, -90),
		Parent = root,
	})
	Theme.new("UISizeConstraint", { MaxSize = Vector2.new(980, 620), Parent = panel })
	Theme.padding(panel, 12, 14)
	self.panel = panel

	-- Title bar
	Theme.label({
		Kind = "title",
		Text = "QUARTERMASTER'S STORE",
		TextSize = 26,
		TextColor3 = Theme.Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(0, 320, 0, 32),
		Parent = panel,
	})
	self.status = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 14,
		TextColor3 = Theme.Colors.Khaki,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(330, 0),
		Size = UDim2.new(1, -390, 0, 32),
		Parent = panel,
	})
	local close = Theme.button({
		Text = "X",
		FontFace = Theme.Fonts.Glyph,
		TextSize = 18,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(40, 32),
		Variant = "ghost",
		Parent = panel,
	})
	close.Activated:Connect(function()
		ctx.ui.CloseMenu("Shop")
	end)
	self.closeButton = close

	-- Tabs
	local tabs = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 0, 34),
		Parent = panel,
	})
	Theme.list(tabs, Enum.FillDirection.Horizontal, 6)
	for i, t in TABS do
		local btn = Theme.button({
			Name = t.id,
			Text = t.label,
			TextSize = 16,
			Size = UDim2.fromOffset(if t.id == "Unlocks" then 170 else 120, 34),
			LayoutOrder = i,
			Parent = tabs,
		})
		btn.Activated:Connect(function()
			self.tab = t.id
			self:Render()
		end)
		self.tabButtons[t.id] = btn
	end

	-- Content
	local content = Theme.panel({
		Style = "dark",
		Position = UDim2.fromOffset(0, 82),
		Size = UDim2.new(1, 0, 1, -82),
		Parent = panel,
	})
	self.content = Theme.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(1, -16, 1, -16),
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Theme.Colors.Khaki,
		Parent = content,
	})

	-- HUD badge: "XP x2  ·  BOOST 0:42:10"
	local badge = Theme.panel({
		Name = "XPBadge",
		Style = "dark",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 54),
		Size = UDim2.fromOffset(150, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Visible = false,
		Parent = ctx.hudRoot,
	})
	Theme.padding(badge, 0, 8)
	self.badgeText = Theme.label({
		Kind = "number",
		Text = "",
		TextSize = 14,
		TextColor3 = GOLD,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.new(0, 0, 1, 0),
		Parent = badge,
	})
	self.badge = badge

	-- Live data
	Remotes.onEvent("Shop_Updated", function(state)
		self:_setState(state)
	end, self.trove)
	self.trove:Add(LOCAL_PLAYER:GetAttributeChangedSignal("XPMultiplier"):Connect(function()
		self:_renderBadge()
	end))
	self.trove:Add(LOCAL_PLAYER:GetAttributeChangedSignal("Level"):Connect(function()
		if self.visible and self.tab == "Unlocks" then
			self:Render()
		end
	end))
	local acc = 0
	self.trove:Add(RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.5 then
			return
		end
		acc = 0
		if self.visible then
			self:_renderStatus()
		end
		if self.hudVisible then
			self:_renderBadge()
		end
	end))
	task.spawn(function()
		self:_fetch()
	end)
	installChatTag()
	return self
end

------------------------------------------------------------------------------------------------
-- Data
------------------------------------------------------------------------------------------------

function Shop:_fetch()
	local ok, state = Remotes.invoke("Shop_GetState", 15)
	if ok and type(state) == "table" then
		self:_setState(state)
	end
end

function Shop:_setState(state: any)
	if type(state) ~= "table" then
		return
	end
	self.state = state
	if type(state.serverTime) == "number" then
		self.timeOffset = state.serverTime - os.time()
	end
	if self.visible then
		self:Render()
	end
	self:_renderBadge()
end

function Shop:_boostRemaining(): number
	local s = self.state
	local expires = if s and type(s.boostExpires) == "number"
		then s.boostExpires
		else tonumber(LOCAL_PLAYER:GetAttribute("XPBoostExpires")) or 0
	return math.max(0, expires - (os.time() + self.timeOffset))
end

function Shop:_multiplier(): number
	return tonumber(LOCAL_PLAYER:GetAttribute("XPMultiplier")) or 1
end

local function purchase(kind: string, key: string)
	Remotes.fire("Shop_Purchase", { kind = kind, key = key })
end

------------------------------------------------------------------------------------------------
-- Rendering helpers
------------------------------------------------------------------------------------------------

function Shop:_renderStatus()
	local parts = { "XP " .. formatMultiplier(self:_multiplier()) }
	local remaining = self:_boostRemaining()
	if remaining > 0 then
		table.insert(parts, "BOOST " .. formatDuration(remaining))
	end
	local s = self.state
	if s and s.studioTest then
		table.insert(parts, "STUDIO TEST MODE (simulated purchases)")
	end
	self.status.Text = table.concat(parts, "   ·   ")
	for _, label in self.countdowns do
		label.Text = if remaining > 0 then "ACTIVE · " .. formatDuration(remaining) .. " LEFT" else "NO BOOST ACTIVE"
		label.TextColor3 = if remaining > 0 then Theme.Colors.Good else Theme.Colors.TextDim
	end
end

function Shop:_renderBadge()
	local m = self:_multiplier()
	local remaining = self:_boostRemaining()
	local show = self.hudVisible and m > 1.001
	self.badge.Visible = show
	if show then
		local text = "XP " .. formatMultiplier(m)
		if remaining > 0 then
			text ..= "  ·  BOOST " .. formatDuration(remaining)
		end
		self.badgeText.Text = text
	end
end

function Shop:_clear()
	self.contentTrove:Clean()
	self.countdowns = {}
	for _, child in self.content:GetChildren() do
		child:Destroy()
	end
end

function Shop:_section(text: string, order: number)
	Theme.header(text, { LayoutOrder = order, Parent = self.content })
end

function Shop:_note(text: string, order: number, color: Color3?)
	return Theme.label({
		Kind = "type",
		Text = text,
		TextSize = 13,
		TextColor3 = color or Theme.Colors.TextDim,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -8, 0, 18),
		LayoutOrder = order,
		Parent = self.content,
	})
end

-- Grid holder for cards (2 columns).
function Shop:_grid(order: number, cellHeight: number): Frame
	local grid = Theme.new("Frame", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -8, 0, 0),
		LayoutOrder = order,
		Parent = self.content,
	})
	Theme.new("UIGridLayout", {
		CellSize = UDim2.new(0.5, -5, 0, cellHeight),
		CellPadding = UDim2.fromOffset(10, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = grid,
	})
	return grid
end

--[[
	A store card: glyph, name, description, perk line and a buy button.
	`buttonText`/`enabled` describe the button; `onBuy` runs on click.
]]
function Shop:_card(
	parent: Instance,
	order: number,
	icon: string,
	name: string,
	description: string,
	perks: string?,
	buttonText: string,
	enabled: boolean,
	onBuy: (() -> ())?
): Frame
	local card = Theme.panel({ LayoutOrder = order, Parent = parent })
	Theme.padding(card, 10)
	Theme.glyphBox(icon, { Size = UDim2.fromOffset(48, 48), Parent = card })
	Theme.label({
		Kind = "heading",
		Text = string.upper(name),
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2.fromOffset(58, 0),
		Size = UDim2.new(1, -58, 0, 22),
		Parent = card,
	})
	Theme.label({
		Kind = "body",
		Text = description,
		TextSize = 13,
		TextColor3 = Theme.Colors.TextDim,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(58, 22),
		Size = UDim2.new(1, -58, 1, -60),
		Parent = card,
	})
	if perks and perks ~= "" then
		Theme.label({
			Kind = "type",
			Text = perks,
			TextSize = 12,
			TextColor3 = Theme.Colors.Khaki,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, -2),
			Size = UDim2.new(1, -130, 0, 30),
			TextWrapped = true,
			Parent = card,
		})
	end
	local btn = Theme.button({
		Text = buttonText,
		TextSize = 17,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(120, 32),
		Variant = if enabled then "primary" else "ghost",
		Parent = card,
	})
	if not enabled then
		btn.TextColor3 = Theme.Colors.Good
	end
	if enabled and onBuy then
		self.contentTrove:Add(btn.Activated:Connect(onBuy))
	end
	return card
end

------------------------------------------------------------------------------------------------
-- Tabs
------------------------------------------------------------------------------------------------

function Shop:_renderPasses(order: number)
	local s = self.state
	self:_section("Game passes · one-time, permanent", order)
	if #s.passes == 0 then
		self:_note("No game passes are on sale yet.", order + 1)
		return
	end
	local grid = self:_grid(order + 2, 150)
	for i, p in s.passes do
		self:_card(
			grid,
			i,
			p.icon,
			p.name,
			p.description,
			table.concat(p.perks or {}, "  ·  "),
			if p.owned then "OWNED" else Monetization.formatPrice(p.price),
			not p.owned,
			function()
				purchase("pass", p.key)
			end
		)
	end
	self:_note(
		"Passes are cosmetic or time-savers only. Every weapon can be unlocked by playing, and no purchase changes damage, health or armor.",
		order + 3
	)
end

function Shop:_renderBoosts(order: number)
	local s = self.state
	self:_section("XP boosts", order)
	local countdown = self:_note("", order + 1, Theme.Colors.Good)
	countdown.FontFace = Theme.Fonts.Number
	countdown.TextSize = 18
	table.insert(self.countdowns, countdown)
	self:_note(
		string.format(
			"Your XP multiplier: %s. Bonuses add up (VIP +25%%, Double XP +100%%, Boost +100%%, Roblox Premium +10%%) up to %s. Buying a boost while one is running extends it. Match score is never multiplied.",
			formatMultiplier(tonumber(s.xpMultiplier) or self:_multiplier()),
			formatMultiplier(Monetization.MAX_XP_MULTIPLIER)
		),
		order + 2
	)
	local grid = self:_grid(order + 3, 130)
	local n = 0
	for _, p in s.products do
		if p.kind == "Boost" then
			n += 1
			self:_card(grid, n, p.icon, p.name, p.description, nil, Monetization.formatPrice(p.price), true, function()
				purchase("product", p.key)
			end)
		end
	end
	if n == 0 then
		self:_note("No boosts are on sale yet.", order + 4)
	end
	self:_renderStatus()
end

local function factionTags(def: any): string
	if type(def.factions) ~= "table" then
		return ""
	end
	local tags = {}
	for _, id in def.factions do
		local f = Factions.byId[id]
		table.insert(tags, f and f.callsign or id)
	end
	return table.concat(tags, " ")
end

function Shop:_renderUnlocks(order: number)
	local s = self.state
	local level = math.max(1, tonumber(LOCAL_PLAYER:GetAttribute("Level")) or 1)
	local tokens = tonumber(s.tokens) or 0
	local product = nil
	for _, p in s.products do
		if p.kind == "WeaponUnlock" then
			product = p
		end
	end
	self:_section("Instant weapon unlocks", order)
	self:_note(
		"Get early access to a weapon above your level. It is the same weapon everyone unlocks by playing — this only saves time. "
			.. (
				if tokens > 0
					then string.format(
						"You have %d Unlock Token%s: unlocking uses a token.",
						tokens,
						tokens == 1 and "" or "s"
					)
					else "Weapons bought this way stay unlocked forever."
			),
		order + 1,
		if tokens > 0 then Theme.Colors.Good else nil
	)
	if not product and tokens <= 0 then
		self:_note("Weapon unlocks are not on sale yet.", order + 2)
		return
	end

	local purchased = {}
	for _, id in s.weapons or {} do
		purchased[id] = true
	end
	local list = {}
	for id, def in Data.weapons() do
		if (def.unlockLevel or 1) > level and not purchased[id] and def.category ~= "Melee" then
			table.insert(list, def)
		end
	end
	table.sort(list, function(a, b)
		if a.unlockLevel ~= b.unlockLevel then
			return a.unlockLevel < b.unlockLevel
		end
		return tostring(a.name) < tostring(b.name)
	end)
	if #list == 0 then
		self:_note("Every weapon is already unlocked. Outstanding, soldier!", order + 2, Theme.Colors.Good)
		return
	end
	local holder = Theme.new("Frame", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -8, 0, 0),
		LayoutOrder = order + 3,
		Parent = self.content,
	})
	Theme.list(holder, Enum.FillDirection.Vertical, 4)
	local pending = s.pendingUnlock
	for i, def in list do
		local row = Theme.panel({ Style = "light", Size = UDim2.new(1, 0, 0, 40), LayoutOrder = i, Parent = holder })
		Theme.label({
			Kind = "heading",
			Text = string.upper(def.name or def.id),
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(10, 2),
			Size = UDim2.new(0.45, -10, 0, 20),
			Parent = row,
		})
		Theme.label({
			Kind = "type",
			Text = string.upper(def.category or "") .. "   " .. factionTags(def),
			TextSize = 11,
			TextColor3 = Theme.Colors.Khaki,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(10, 22),
			Size = UDim2.new(0.6, -10, 0, 14),
			Parent = row,
		})
		local lock = Theme.label({
			Kind = "title",
			Text = "LVL " .. tostring(def.unlockLevel or 1),
			TextSize = 12,
			TextColor3 = Theme.Colors.Ink,
			TextStrokeTransparency = 1,
			BackgroundTransparency = 0,
			BackgroundColor3 = Theme.Colors.Locked,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -178, 0.5, 0),
			Size = UDim2.fromOffset(52, 20),
			Parent = row,
		})
		Theme.corner(lock, 2)
		local text = if tokens > 0
			then "USE TOKEN"
			elseif product then "UNLOCK " .. Monetization.formatPrice(product.price)
			else "UNAVAILABLE"
		if pending == def.id and tokens <= 0 then
			text = "AWAITING PAYMENT"
		end
		local btn = Theme.button({
			Text = text,
			TextSize = 14,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -6, 0.5, 0),
			Size = UDim2.fromOffset(160, 30),
			Variant = "primary",
			Parent = row,
		})
		self.contentTrove:Add(btn.Activated:Connect(function()
			Remotes.fire("Shop_RequestUnlock", { weaponId = def.id })
		end))
	end
end

function Shop:_cosmeticRow(order: number, title: string, items: { any }, selected: string, field: string)
	self:_section(title, order)
	local holder = Theme.new("Frame", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -8, 0, 0),
		LayoutOrder = order + 1,
		Parent = self.content,
	})
	Theme.new("UIGridLayout", {
		CellSize = UDim2.fromOffset(170, 52),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = holder,
	})
	for i, item in items do
		local isSelected = item.id == selected
		local btn = Theme.button({
			Text = "",
			LayoutOrder = i,
			Variant = if isSelected then nil else "ghost",
			Parent = holder,
		})
		if isSelected then
			Theme.setButtonColor(btn, Theme.Colors.Olive)
		end
		Theme.label({
			Kind = "heading",
			Text = string.upper(item.name),
			TextSize = 15,
			TextColor3 = if isSelected
				then Theme.Colors.Accent
				elseif item.owned then Theme.Colors.Text
				else Theme.Colors.TextDim,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(8, 4),
			Size = UDim2.new(1, -16, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = btn,
		})
		local pass = item.requires and Monetization.getPass(item.requires)
		Theme.label({
			Kind = "type",
			Text = if isSelected
				then "EQUIPPED"
				elseif item.owned then "OWNED · CLICK TO EQUIP"
				else "REQUIRES " .. string.upper(pass and pass.name or tostring(item.requires)),
			TextSize = 10,
			TextColor3 = if item.owned then Theme.Colors.Khaki else Theme.Colors.Locked,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(8, 28),
			Size = UDim2.new(1, -16, 0, 14),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = btn,
		})
		self.contentTrove:Add(btn.Activated:Connect(function()
			if item.owned then
				if not isSelected then
					Remotes.fire("Shop_SetCosmetic", { [field] = item.id })
				end
			elseif item.requires then
				-- Only offer the pass if it is actually on sale.
				for _, p in self.state.passes do
					if p.key == item.requires then
						purchase("pass", p.key)
						return
					end
				end
				self.ctx.ui.Notify("That pass is not on sale yet.", "warning")
			end
		end))
	end
end

function Shop:_renderCosmetics(order: number)
	local s = self.state
	self:_note(
		"Cosmetics never change weapon stats. Uniform variants keep the same brightness as your faction's standard uniform, so they never make you harder to spot. Uniforms apply on your next deployment.",
		order
	)
	self:_cosmeticRow(order + 1, "Weapon camo", s.camos or {}, s.camo or "", "camo")
	self:_cosmeticRow(order + 3, "Uniform", s.uniforms or {}, s.uniform or "", "uniform")
end

function Shop:_renderSupport(order: number)
	local s = self.state
	self:_section("Support the developers", order)
	self:_note(
		if s.supporter
			then "You are a Supporter. Thank you! Your name carries the Supporter tag in chat."
			else "Tips keep new maps, vehicles and weapons coming. They have no gameplay effect — just our gratitude and a Supporter tag.",
		order + 1,
		if s.supporter then GOLD else nil
	)
	local grid = self:_grid(order + 2, 130)
	local n = 0
	for _, p in s.products do
		if p.kind == "Tip" then
			n += 1
			self:_card(grid, n, p.icon, p.name, p.description, nil, Monetization.formatPrice(p.price), true, function()
				purchase("product", p.key)
			end)
		end
	end
	if n == 0 then
		self:_note("Tipping is not available yet.", order + 3)
	end
	self:_note(
		"Roblox Premium members automatically earn +10% XP in WW2 Frontlines"
			.. (if s.premium then " (active for you)." else "."),
		order + 4,
		if s.premium then Theme.Colors.Good else nil
	)
end

function Shop:Render()
	for id, btn in self.tabButtons do
		local active = id == self.tab
		Theme.setButtonColor(btn, if active then Theme.Colors.Olive else Theme.Colors.PanelLight)
		btn.TextColor3 = if active then Theme.Colors.Accent else Theme.Colors.Text
	end
	self:_clear()
	Theme.list(self.content, Enum.FillDirection.Vertical, 8)
	local s = self.state
	if not s then
		self:_note("Contacting the quartermaster...", 1)
		self:_renderStatus()
		return
	end
	if s.available == false then
		self:_note(
			"The store is unavailable right now (Roblox data services). Please try again later.",
			1,
			Theme.Colors.Warning
		)
	end
	if #(s.passes or {}) == 0 and #(s.products or {}) == 0 and (tonumber(s.tokens) or 0) <= 0 then
		self:_note("The store is not open yet. Check back soon, soldier.", 2)
		self:_renderStatus()
		return
	end
	if self.tab == "Passes" then
		self:_renderPasses(10)
	elseif self.tab == "Boosts" then
		self:_renderBoosts(10)
	elseif self.tab == "Unlocks" then
		self:_renderUnlocks(10)
	elseif self.tab == "Cosmetics" then
		self:_renderCosmetics(10)
	else
		self:_renderSupport(10)
	end
	self:_renderStatus()
end

------------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------------

function Shop:SetVisible(visible: boolean)
	self.visible = visible
	self.root.Visible = visible
	if visible then
		self:Render()
		task.spawn(function()
			self:_fetch()
		end)
		Theme.selectForGamepad(self.tabButtons[self.tab])
	end
end

function Shop:IsVisible(): boolean
	return self.visible
end

-- Called by UIController when the in-game HUD is (not) showing.
function Shop:SetHudVisible(visible: boolean)
	self.hudVisible = visible
	self:_renderBadge()
end

function Shop:Destroy()
	self.contentTrove:Clean()
	self.trove:Clean()
	self.root:Destroy()
	self.badge:Destroy()
end

return Shop
