--[[
	RoundEnd: post-round debrief and the intermission / waiting screen.

	  ShowResults(payload, xpGained)  -- `Round_Ended` {winner, mvp?, topPlayers}
	      VICTORY / DEFEAT / STALEMATE banner with the winning faction's flag, MVP dog tag,
	      top players table, your K/D/A/score, XP earned + level progress, next battle countdown.
	  ShowIntermission()
	      Next operation: map name, theatre, mode + description, countdown (GameState TimeLeft)
	      or "WAITING FOR PLAYERS".
	Countdown text updates from the GameState TimeLeft attribute (event-driven).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared.Config.GameModes)
local GameState = require(Shared.GameState)
local Maps = require(Shared.Config.Maps)
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Data = require(UI.Data)
local Theme = require(UI.Theme)

local RoundEnd = {}
RoundEnd.__index = RoundEnd

local LOCAL_PLAYER = Players.LocalPlayer
local MAX_TOP = 8

function RoundEnd.new(ctx)
	local self = setmetatable({}, RoundEnd)
	self.ctx = ctx
	self.trove = Trove.new()
	self.view = nil :: string?

	self.backdrop = Theme.new("Frame", {
		Name = "RoundEndBackdrop",
		BackgroundColor3 = Theme.Colors.Ink,
		BackgroundTransparency = 0.12,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = ctx.backdropRoot,
	})
	Theme.grain(self.backdrop, 90)

	self:_buildResults()
	self:_buildIntermission()

	self.trove:Add(GameState.changed("TimeLeft"):Connect(function()
		self:_renderTimers()
	end))
	for _, attr in { "MapId", "ModeId", "Phase" } do
		self.trove:Add(GameState.changed(attr):Connect(function()
			if self.view == "Intermission" then
				self:_renderIntermission()
			end
		end))
	end
	return self
end

------------------------------------------------------------------------------------------------
-- Results
------------------------------------------------------------------------------------------------

function RoundEnd:_buildResults()
	local root = Theme.new("Frame", {
		Name = "Results",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = self.ctx.menuRoot,
	})
	self.results = root

	-- Banner
	local banner = Theme.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 30),
		Size = UDim2.fromOffset(760, 120),
		Parent = root,
	})
	self.bannerScale = Theme.new("UIScale", { Parent = banner })
	self.winFlag = Theme.flag({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(84, 54),
		Parent = banner,
	}, nil)
	self.resultTitle = Theme.label({
		Kind = "title",
		Text = "",
		TextSize = 64,
		TextStrokeTransparency = 0.4,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 52),
		Size = UDim2.new(1, 0, 0, 66),
		Parent = banner,
	})
	self.resultSub = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 18,
		TextColor3 = Theme.Colors.Khaki,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 160),
		Size = UDim2.fromOffset(760, 24),
		Parent = root,
	})

	local body = Theme.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 196),
		Size = UDim2.new(1, -60, 1, -270),
		Parent = root,
	})
	Theme.new("UISizeConstraint", { MaxSize = Vector2.new(1080, 460), Parent = body })

	-- Left: MVP + your performance
	local left = Theme.panel({
		Size = UDim2.new(0.42, -8, 1, 0),
		Parent = body,
	})
	Theme.padding(left, 12)
	Theme.header("Most valuable soldier", { Parent = left })
	local tag = Theme.new("Frame", {
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 70),
		BackgroundColor3 = Color3.fromRGB(180, 182, 174),
		BorderSizePixel = 0,
		Parent = left,
	})
	Theme.corner(tag, 16)
	Theme.stroke(tag, Theme.Colors.Ink, 1, 0.3)
	Theme.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(165, 165, 160)),
		Parent = tag,
	})
	self.mvpName = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 24,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(18, 8),
		Size = UDim2.new(1, -36, 0, 30),
		Parent = tag,
	})
	self.mvpScore = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 16,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(18, 38),
		Size = UDim2.new(1, -36, 0, 22),
		Parent = tag,
	})

	Theme.header("Your service record", { Position = UDim2.fromOffset(0, 120), Parent = left })
	self.myStats = Theme.label({
		Kind = "number",
		Text = "",
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 152),
		Size = UDim2.new(1, 0, 0, 26),
		Parent = left,
	})
	self.xpLabel = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 22,
		TextColor3 = Theme.Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 184),
		Size = UDim2.new(1, 0, 0, 28),
		Parent = left,
	})
	self.levelLabel = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 14,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 216),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = left,
	})
	local xpBar, xpFill = Theme.bar({
		Position = UDim2.fromOffset(0, 238),
		Size = UDim2.new(1, 0, 0, 8),
	}, Theme.Colors.Accent)
	xpBar.Parent = left
	self.xpFill = xpFill

	-- Right: top players
	local right = Theme.panel({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.58, -8, 1, 0),
		Parent = body,
	})
	Theme.padding(right, 12)
	Theme.header("Commendations", { Parent = right })
	local list = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 1, -34),
		Parent = right,
	})
	Theme.list(list, Enum.FillDirection.Vertical, 3)
	self.topRows = {}
	for i = 1, MAX_TOP do
		local row = Theme.new("Frame", {
			BackgroundColor3 = Theme.Colors.PanelDark,
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 28),
			LayoutOrder = i,
			Visible = false,
			Parent = list,
		})
		Theme.corner(row, 3)
		local rank = Theme.label({
			Kind = "title",
			Text = tostring(i),
			TextSize = 16,
			TextColor3 = i <= 3 and Theme.Colors.Accent or Theme.Colors.TextDim,
			Size = UDim2.fromOffset(30, 28),
			Parent = row,
		})
		local side = Theme.new("Frame", {
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(32, 6),
			Size = UDim2.fromOffset(4, 16),
			Parent = row,
		})
		local name = Theme.label({
			Kind = "bold",
			Text = "",
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(44, 0),
			Size = UDim2.new(1, -220, 1, 0),
			Parent = row,
		})
		local kd = Theme.label({
			Kind = "number",
			Text = "",
			TextSize = 15,
			TextColor3 = Theme.Colors.TextDim,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -80, 0, 0),
			Size = UDim2.fromOffset(90, 28),
			Parent = row,
		})
		local score = Theme.label({
			Kind = "number",
			Text = "",
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 0),
			Size = UDim2.fromOffset(70, 28),
			Parent = row,
		})
		local _ = rank
		self.topRows[i] = { frame = row, side = side, name = name, kd = kd, score = score }
	end

	self.nextLabel = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 20,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(600, 28),
		Parent = root,
	})
end

function RoundEnd:ShowResults(payload: any, xpGained: number?)
	payload = type(payload) == "table" and payload or {}
	local winner = payload.winner or GameState.get("Winner") or "Draw"
	local mySide = Data.localSide()
	local title, color
	if winner == "Draw" or winner == "" then
		title, color = "STALEMATE", Theme.Colors.Khaki
	elseif winner == mySide then
		title, color = "VICTORY", Theme.Colors.Accent
	elseif mySide == "" then
		title, color = string.upper(winner) .. " WIN", Theme.sideColor(winner)
	else
		title, color = "DEFEAT", Theme.Colors.Danger
	end
	self.resultTitle.Text = title
	self.resultTitle.TextColor3 = color
	local winFaction = (winner == "Allies" or winner == "Axis") and GameState.get(winner .. "Faction") or nil
	Theme.setFlag(self.winFlag, winFaction)
	self.winFlag.Visible = winFaction ~= nil
	local f = Theme.faction(winFaction)
	self.resultSub.Text = f and string.format("%s forces hold the field", string.upper(f.adjective))
		or "Neither side could claim the field"

	local mvp = payload.mvp
	if type(mvp) == "table" and mvp.name then
		self.mvpName.Text = string.upper(tostring(mvp.name))
		self.mvpScore.Text = string.format("SCORE %d", tonumber(mvp.score) or 0)
	else
		self.mvpName.Text = "—"
		self.mvpScore.Text = ""
	end

	local k = tonumber(LOCAL_PLAYER:GetAttribute("Kills")) or 0
	local d = tonumber(LOCAL_PLAYER:GetAttribute("Deaths")) or 0
	local a = tonumber(LOCAL_PLAYER:GetAttribute("Assists")) or 0
	local s = tonumber(LOCAL_PLAYER:GetAttribute("Score")) or 0
	self.myStats.Text = string.format("K %d   D %d   A %d   SCORE %d", k, d, a, s)
	self.xpLabel.Text = string.format("+%d XP EARNED", math.floor(xpGained or s))
	self:RenderProgress(self.ctx.ui.GetProgression())

	local top = type(payload.topPlayers) == "table" and payload.topPlayers or {}
	for i, row in self.topRows do
		local p = top[i]
		if type(p) == "table" then
			row.frame.Visible = true
			row.name.Text = tostring(p.name or "?")
			row.side.BackgroundColor3 = Theme.sideColor(p.side)
			row.kd.Text = string.format("%d / %d", tonumber(p.kills) or 0, tonumber(p.deaths) or 0)
			row.score.Text = tostring(tonumber(p.score) or 0)
			local isMe = p.name == LOCAL_PLAYER.Name or p.name == LOCAL_PLAYER.DisplayName
			row.name.TextColor3 = isMe and Theme.Colors.Accent or Theme.Colors.Text
		else
			row.frame.Visible = false
		end
	end

	self:_show("Results")
	self.bannerScale.Scale = 1.5
	Theme.tween(self.bannerScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- ProgressionData {level, xp, xpToNext}
function RoundEnd:RenderProgress(data: any)
	local level = tonumber(LOCAL_PLAYER:GetAttribute("Level")) or 1
	local xp, toNext = tonumber(LOCAL_PLAYER:GetAttribute("XP")) or 0, nil
	if type(data) == "table" then
		level = tonumber(data.level) or level
		xp = tonumber(data.xp) or xp
		toNext = tonumber(data.xpToNext)
	end
	if toNext and toNext > 0 then
		self.levelLabel.Text = string.format("LEVEL %d  ·  %d / %d XP", level, xp, toNext)
		self.xpFill.Size = UDim2.fromScale(math.clamp(xp / toNext, 0, 1), 1)
	else
		self.levelLabel.Text = string.format("LEVEL %d", level)
		self.xpFill.Size = UDim2.fromScale(1, 1)
	end
end

------------------------------------------------------------------------------------------------
-- Intermission
------------------------------------------------------------------------------------------------

function RoundEnd:_buildIntermission()
	local root = Theme.new("Frame", {
		Name = "Intermission",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = self.ctx.menuRoot,
	})
	self.intermission = root

	local card = Theme.panel({
		Style = "paper",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.48),
		Size = UDim2.fromOffset(620, 340),
		Parent = root,
	})
	Theme.padding(card, 20, 26)
	local function ink(props)
		props.TextColor3 = props.TextColor3 or Theme.Colors.TextDark
		props.TextStrokeTransparency = 1
		props.Parent = card
		return Theme.label(props)
	end
	ink({
		Kind = "type",
		Text = "OPERATIONAL ORDER — TOP SECRET",
		TextSize = 14,
		TextColor3 = Color3.fromRGB(150, 30, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 18),
	})
	self.imMap = ink({
		Kind = "title",
		Text = "",
		TextSize = 40,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 0, 46),
	})
	self.imTheatre = ink({
		Kind = "type",
		Text = "",
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 72),
		Size = UDim2.new(1, 0, 0, 18),
	})
	self.imDesc = ink({
		Kind = "type",
		Text = "",
		TextSize = 15,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(0, 100),
		Size = UDim2.new(1, 0, 0, 70),
	})
	self.imMode = ink({
		Kind = "heading",
		Text = "",
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(0, 176),
		Size = UDim2.new(1, 0, 0, 24),
	})
	self.imModeDesc = ink({
		Kind = "type",
		Text = "",
		TextSize = 14,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(0, 202),
		Size = UDim2.new(1, 0, 0, 40),
	})
	self.imTimer = ink({
		Kind = "title",
		Text = "",
		TextSize = 26,
		TextColor3 = Color3.fromRGB(150, 30, 26),
		TextXAlignment = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 30),
	})
	-- "Stamp"
	local stamp = Theme.label({
		Kind = "title",
		Text = "",
		TextSize = 22,
		TextColor3 = Color3.fromRGB(150, 30, 26),
		TextStrokeTransparency = 1,
		Rotation = -12,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.fromOffset(170, 40),
		Parent = card,
	})
	Theme.new("UIStroke", {
		Color = Color3.fromRGB(150, 30, 26),
		Thickness = 2,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = stamp,
	})
	self.imStamp = stamp

	local gear = Theme.button({
		Text = "SETTINGS",
		TextSize = 15,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -20, 0, 20),
		Size = UDim2.fromOffset(120, 34),
		Variant = "ghost",
		Parent = root,
	})
	gear.Activated:Connect(function()
		self.ctx.ui.OpenMenu("Settings")
	end)
	self.imGear = gear
end

function RoundEnd:_renderIntermission()
	local map = Maps.byId[GameState.get("MapId") or ""]
	local mode = GameModes.byId[GameState.get("ModeId") or ""]
	self.imMap.Text = map and string.upper(map.name) or "AWAITING ORDERS"
	self.imTheatre.Text = map and string.upper(map.theater .. " theatre · " .. map.environment) or ""
	self.imDesc.Text = map and map.description or "High command is selecting the next objective."
	self.imMode.Text = mode and string.upper(mode.name) or ""
	self.imModeDesc.Text = mode and mode.description or ""
	local phase = GameState.get("Phase")
	self.imStamp.Text = phase == "Loading" and "DEPLOYING" or (phase == "Waiting" and "STANDBY" or "BRIEFING")
	self:_renderTimers()
end

------------------------------------------------------------------------------------------------

function RoundEnd:_renderTimers()
	local t = tonumber(GameState.get("TimeLeft")) or 0
	local phase = GameState.get("Phase")
	if self.view == "Results" then
		self.nextLabel.Text = t > 0 and string.format("NEXT BATTLE IN %d", math.ceil(t)) or "PREPARING NEXT BATTLE"
	elseif self.view == "Intermission" then
		if phase == "Waiting" then
			self.imTimer.Text = "WAITING FOR PLAYERS"
		elseif phase == "Loading" then
			self.imTimer.Text = "MOVING TO THE FRONT…"
		else
			self.imTimer.Text = "BATTLE BEGINS IN " .. Theme.formatTime(t)
		end
	end
end

function RoundEnd:_show(view: string?)
	self.view = view
	self.results.Visible = view == "Results"
	self.intermission.Visible = view == "Intermission"
	self.backdrop.Visible = view ~= nil
	self:_renderTimers()
end

function RoundEnd:ShowIntermission()
	self:_show("Intermission")
	self:_renderIntermission()
	Theme.selectForGamepad(self.imGear)
end

function RoundEnd:Hide()
	self:_show(nil)
end

function RoundEnd:GetView(): string?
	return self.view
end

function RoundEnd:Destroy()
	self.trove:Clean()
	self.results:Destroy()
	self.intermission:Destroy()
	self.backdrop:Destroy()
end

return RoundEnd
