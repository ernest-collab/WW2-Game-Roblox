--[[
	Scoreboard (hold Tab / toggle Select on gamepad / SCORE button on touch).

	Two columns (Allies | Axis) sorted by score. Columns: LVL, NAME (squad tag, leader star),
	CLASS, K, D, A, SCORE. Squad-mates tinted green, own row highlighted brass, dead players dimmed.
	Rows are pooled per side and refreshed at 2 Hz while visible (plus once on open).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Classes = require(Shared.Config.Classes)
local GameModes = require(Shared.Config.GameModes)
local GameState = require(Shared.GameState)
local Maps = require(Shared.Config.Maps)

local UI = script.Parent
local Theme = require(UI.Theme)

local Scoreboard = {}
Scoreboard.__index = Scoreboard

local LOCAL_PLAYER = Players.LocalPlayer
local ROW_HEIGHT = 24
local COLUMNS = {
	{ key = "lvl", title = "LVL", width = 36, align = Enum.TextXAlignment.Center },
	{ key = "name", title = "NAME", width = -1, align = Enum.TextXAlignment.Left },
	{ key = "class", title = "CLASS", width = 44, align = Enum.TextXAlignment.Center },
	{ key = "k", title = "K", width = 34, align = Enum.TextXAlignment.Center },
	{ key = "d", title = "D", width = 34, align = Enum.TextXAlignment.Center },
	{ key = "a", title = "A", width = 34, align = Enum.TextXAlignment.Center },
	{ key = "score", title = "SCORE", width = 58, align = Enum.TextXAlignment.Right },
}
local FIXED_WIDTH = 0
for _, c in COLUMNS do
	if c.width > 0 then
		FIXED_WIDTH += c.width
	end
end

local function num(p: Player, attr: string): number
	return tonumber(p:GetAttribute(attr)) or 0
end

function Scoreboard.new(ctx)
	local self = setmetatable({}, Scoreboard)
	self.ctx = ctx
	self.visible = false
	self.rows = { Allies = {}, Axis = {} }

	local panel = Theme.panel({
		Name = "Scoreboard",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -80, 1, -120),
		Visible = false,
		Parent = ctx.overlayRoot,
	})
	Theme.new("UISizeConstraint", { MaxSize = Vector2.new(1120, 680), Parent = panel })
	self.panel = panel

	self.title = Theme.label({
		Kind = "title",
		Text = "",
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(18, 8),
		Size = UDim2.new(0.6, 0, 0, 30),
		Parent = panel,
	})
	self.subtitle = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 14,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -18, 0, 14),
		Size = UDim2.new(0.4, 0, 0, 20),
		Parent = panel,
	})

	self.columns = {
		Allies = self:_column("Allies", UDim2.new(0, 14, 0, 46)),
		Axis = self:_column("Axis", UDim2.new(0.5, 6, 0, 46)),
	}

	local acc = 0
	self.conn = RunService.Heartbeat:Connect(function(dt)
		if not self.visible then
			return
		end
		acc += dt
		if acc >= 0.5 then
			acc = 0
			self:Refresh()
		end
	end)
	return self
end

function Scoreboard:_column(side: string, position: UDim2)
	local col = Theme.new("Frame", {
		Name = side,
		BackgroundColor3 = Theme.Colors.PanelDark,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Position = position,
		Size = UDim2.new(0.5, -20, 1, -60),
		Parent = self.panel,
	})
	Theme.corner(col, 3)

	-- Header band
	local header = Theme.new("Frame", {
		BackgroundColor3 = Theme.sideColor(side),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 40),
		Parent = col,
	})
	Theme.corner(header, 3)
	local flag = Theme.flag({
		Position = UDim2.fromOffset(8, 7),
		Size = UDim2.fromOffset(38, 26),
		Parent = header,
	}, nil)
	local name = Theme.label({
		Kind = "title",
		Text = string.upper(side),
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(54, 0),
		Size = UDim2.new(1, -150, 1, 0),
		Parent = header,
	})
	local score = Theme.label({
		Kind = "number",
		Text = "",
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 0),
		Size = UDim2.fromOffset(110, 40),
		Parent = header,
	})

	-- Column titles
	local titles = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 44),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = col,
	})
	self:_cells(titles, true)

	local list = Theme.new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 64),
		Size = UDim2.new(1, 0, 1, -66),
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Theme.Colors.Khaki,
		Parent = col,
	})
	Theme.list(list, Enum.FillDirection.Vertical, 2)
	return { frame = col, flag = flag, name = name, score = score, list = list }
end

-- Builds the cell labels of a row (or the title row). Returns {[key] = TextLabel}.
function Scoreboard:_cells(parent: Instance, isTitle: boolean): { [string]: TextLabel }
	local cells = {}
	local x = 6
	for _, c in COLUMNS do
		local width = c.width > 0 and UDim.new(0, c.width) or UDim.new(1, -(FIXED_WIDTH + 12))
		cells[c.key] = Theme.label({
			Kind = isTitle and "heading" or (c.key == "name" and "bold" or "number"),
			Text = isTitle and c.title or "",
			TextSize = isTitle and 12 or 15,
			TextColor3 = isTitle and Theme.Colors.TextDim or Theme.Colors.Text,
			TextXAlignment = c.align,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.new(0, x, 0, 0),
			Size = UDim2.new(width.Scale, width.Offset, 1, 0),
			Parent = parent,
		})
		if c.width > 0 then
			x += c.width
		else
			-- the flexible name column: following columns are positioned from the right
			x = -1
			break
		end
	end
	-- Columns after the flexible one, laid out from the right edge.
	local right = 6
	for i = #COLUMNS, 1, -1 do
		local c = COLUMNS[i]
		if c.width < 0 then
			break
		end
		right += c.width
		if not cells[c.key] then
			cells[c.key] = Theme.label({
				Kind = isTitle and "heading" or "number",
				Text = isTitle and c.title or "",
				TextSize = isTitle and 12 or 15,
				TextColor3 = isTitle and Theme.Colors.TextDim or Theme.Colors.Text,
				TextXAlignment = c.align,
				Position = UDim2.new(1, -right, 0, 0),
				Size = UDim2.new(0, c.width, 1, 0),
				Parent = parent,
			})
		end
	end
	return cells
end

function Scoreboard:_row(side: string, index: number)
	local pool = self.rows[side]
	local row = pool[index]
	if row then
		return row
	end
	local frame = Theme.new("Frame", {
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -6, 0, ROW_HEIGHT),
		LayoutOrder = index,
		Parent = self.columns[side].list,
	})
	Theme.corner(frame, 2)
	local stroke = Theme.stroke(frame, Theme.Colors.Accent, 1, 1)
	row = { frame = frame, stroke = stroke, cells = self:_cells(frame, false) }
	pool[index] = row
	return row
end

function Scoreboard:Refresh()
	local map = Maps.byId[GameState.get("MapId") or ""]
	local mode = GameModes.byId[GameState.get("ModeId") or ""]
	self.title.Text = (map and string.upper(map.name) or "BATTLEFIELD") .. (mode and ("  ·  " .. string.upper(mode.name)) or "")
	self.subtitle.Text = "TIME " .. Theme.formatTime(GameState.get("TimeLeft"))

	local mySquad = LOCAL_PLAYER:GetAttribute("Squad") or 0
	local mySide = LOCAL_PLAYER:GetAttribute("Side")
	local bySide = { Allies = {}, Axis = {} }
	for _, p in Players:GetPlayers() do
		local side = p:GetAttribute("Side")
		if bySide[side] then
			table.insert(bySide[side], p)
		end
	end
	local tdm = mode ~= nil and not mode.usesObjectives
	for side, list in bySide do
		table.sort(list, function(a, b)
			local sa, sb = num(a, "Score"), num(b, "Score")
			if sa ~= sb then
				return sa > sb
			end
			return a.Name < b.Name
		end)
		local col = self.columns[side]
		local factionId = GameState.get(side .. "Faction")
		Theme.setFlag(col.flag, factionId)
		local f = Theme.faction(factionId)
		col.name.Text = string.upper(f and f.name or side) .. string.format("  (%d)", #list)
		local value = tdm and GameState.get(side .. "Score") or GameState.get(side .. "Tickets")
		col.score.Text = tostring(math.floor(tonumber(value) or 0)) .. (tdm and " KILLS" or " TICKETS")
		col.frame.BackgroundColor3 = side == mySide and Theme.Colors.PanelLight or Theme.Colors.PanelDark

		for i, p in list do
			local row = self:_row(side, i)
			local cells = row.cells
			local squad = p:GetAttribute("Squad") or 0
			local leader = p:GetAttribute("SquadLeader") == true
			local class = Classes.byId[p:GetAttribute("Class") or ""]
			cells.lvl.Text = tostring(num(p, "Level") > 0 and num(p, "Level") or 1)
			local tag = squad ~= 0 and string.format("[%d] ", squad) or ""
			cells.name.Text = tag .. (leader and "★ " or "") .. p.DisplayName
			cells.class.Text = class and class.icon or "—"
			cells.k.Text = tostring(num(p, "Kills"))
			cells.d.Text = tostring(num(p, "Deaths"))
			cells.a.Text = tostring(num(p, "Assists"))
			cells.score.Text = tostring(num(p, "Score"))
			local isMe = p == LOCAL_PLAYER
			local squadMate = not isMe and mySquad ~= 0 and squad == mySquad and side == mySide
			cells.name.TextColor3 = isMe and Theme.Colors.Accent or (squadMate and Theme.Colors.Squad or Theme.Colors.Text)
			row.stroke.Transparency = isMe and 0 or 1
			row.frame.BackgroundColor3 = isMe and Theme.Colors.OliveLight or Theme.Colors.Panel
			local alive = p:GetAttribute("Alive") ~= false
			for _, cell in cells do
				cell.TextTransparency = alive and 0 or 0.45
			end
			row.frame.Visible = true
		end
		for i = #list + 1, #self.rows[side] do
			self.rows[side][i].frame.Visible = false
		end
	end
end

function Scoreboard:SetVisible(visible: boolean)
	if visible == self.visible then
		return
	end
	self.visible = visible
	self.panel.Visible = visible
	if visible then
		self:Refresh()
	end
end

function Scoreboard:IsVisible(): boolean
	return self.visible
end

function Scoreboard:Destroy()
	self.conn:Disconnect()
	self.panel:Destroy()
end

return Scoreboard
