--[[
	ScorePopups: centre-screen score feedback.

	  * `Score_Event` {reason, points} -> stacked lines "ENEMY KILLED  +100" plus a running total
	    that resets after a short quiet period.
	  * `Combat_Kill` where the local player is the killer -> kill banner "KILLED  <name>" with a
	    headshot tag.
	Lines are pooled (MAX_LINES) and recycled.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Remotes = require(UI.Remotes)
local Theme = require(UI.Theme)

local ScorePopups = {}
ScorePopups.__index = ScorePopups

local MAX_LINES = 5
local LINE_LIFETIME = 2.6
local TOTAL_LIFETIME = 3.2
local LOCAL_PLAYER = Players.LocalPlayer

function ScorePopups.new(ctx)
	local self = setmetatable({}, ScorePopups)
	self.ctx = ctx
	self.trove = Trove.new()
	self.lines = {}
	self.counter = 0
	self.total = 0
	self.totalSerial = 0
	self.roundPoints = 0

	local frame = Theme.new("Frame", {
		Name = "ScorePopups",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.56, 0),
		Size = UDim2.fromOffset(420, 220),
		Visible = false,
		Parent = ctx.hudRoot,
	})
	self.frame = frame

	-- Kill banner
	local banner = Theme.new("Frame", {
		Name = "KillBanner",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(420, 30),
		Visible = false,
		Parent = frame,
	})
	Theme.list(banner, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center)
	self.bannerTitle = Theme.label({
		Kind = "title",
		Text = "KILLED",
		TextSize = 22,
		TextColor3 = Theme.Colors.Danger,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 30),
		LayoutOrder = 1,
		Parent = banner,
	})
	self.bannerName = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 22,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 30),
		LayoutOrder = 2,
		Parent = banner,
	})
	self.bannerHs = Theme.label({
		Kind = "title",
		Text = "HEADSHOT",
		TextSize = 12,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		BackgroundTransparency = 0,
		BackgroundColor3 = Theme.Colors.Accent,
		Size = UDim2.fromOffset(70, 18),
		LayoutOrder = 3,
		Parent = banner,
	})
	Theme.corner(self.bannerHs, 2)
	self.banner = banner
	self.bannerScale = Theme.new("UIScale", { Parent = banner })

	-- Running total
	self.totalLabel = Theme.label({
		Kind = "title",
		Text = "",
		TextSize = 30,
		TextColor3 = Theme.Colors.Accent,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 32),
		Size = UDim2.fromOffset(200, 32),
		Parent = frame,
	})
	self.totalScale = Theme.new("UIScale", { Parent = self.totalLabel })

	local list = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 66),
		Size = UDim2.new(1, 0, 1, -66),
		Parent = frame,
	})
	Theme.list(list, Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Center)
	for i = 1, MAX_LINES do
		local line = Theme.label({
			Kind = "heading",
			Text = "",
			TextSize = 17,
			Size = UDim2.fromOffset(400, 22),
			Visible = false,
			RichText = true,
			Parent = list,
		})
		self.lines[i] = { label = line, serial = 0 }
	end

	Remotes.onEvent("Score_Event", function(payload)
		if type(payload) == "table" then
			self:AddScore(tostring(payload.reason or ""), tonumber(payload.points) or 0)
		end
	end, self.trove)
	Remotes.onEvent("Combat_Kill", function(payload)
		if type(payload) == "table" and payload.killer == LOCAL_PLAYER and payload.victim ~= LOCAL_PLAYER then
			self:ShowKill(payload.victim, payload.headshot == true)
		end
	end, self.trove)
	return self
end

function ScorePopups:AddScore(reason: string, points: number)
	self.roundPoints += points
	self.counter += 1
	local line = self.lines[1]
	for _, l in self.lines do
		if not l.label.Visible then
			line = l
			break
		end
		if l.serial < line.serial then
			line = l
		end
	end
	line.serial = self.counter
	line.label.LayoutOrder = -self.counter
	line.label.Text =
		string.format('%s  <font color="#%s">+%d</font>', string.upper(reason), Theme.Colors.Accent:ToHex(), points)
	line.label.TextTransparency = 0
	line.label.TextStrokeTransparency = 0.75
	line.label.Visible = true
	local serial = line.serial
	task.delay(LINE_LIFETIME, function()
		if line.serial == serial then
			Theme.tween(line.label, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
			task.delay(0.4, function()
				if line.serial == serial then
					line.label.Visible = false
				end
			end)
		end
	end)

	-- Running total with a little punch.
	self.total += points
	self.totalSerial += 1
	local totalSerial = self.totalSerial
	self.totalLabel.Text = "+" .. tostring(self.total)
	self.totalLabel.TextTransparency = 0
	self.totalScale.Scale = 1.3
	Theme.tween(self.totalScale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)
	task.delay(TOTAL_LIFETIME, function()
		if self.totalSerial == totalSerial then
			Theme.tween(self.totalLabel, 0.4, { TextTransparency = 1 })
			task.delay(0.4, function()
				if self.totalSerial == totalSerial then
					self.total = 0
					self.totalLabel.Text = ""
				end
			end)
		end
	end)
end

function ScorePopups:ShowKill(victim: any, headshot: boolean)
	self.bannerName.Text = typeof(victim) == "Instance" and string.upper(victim.DisplayName) or ""
	self.bannerHs.Visible = headshot
	self.banner.Visible = true
	self.bannerScale.Scale = 1.25
	Theme.tween(self.bannerScale, 0.18, { Scale = 1 }, Enum.EasingStyle.Back)
	self.counter += 1
	local serial = self.counter
	self.bannerSerial = serial
	task.delay(2.2, function()
		if self.bannerSerial == serial then
			self.banner.Visible = false
		end
	end)
end

-- Points accumulated since the last ResetRound() (used for the round-end XP summary).
function ScorePopups:GetRoundPoints(): number
	return self.roundPoints
end

function ScorePopups:ResetRound()
	self.roundPoints = 0
end

function ScorePopups:SetVisible(visible: boolean)
	self.frame.Visible = visible
end

function ScorePopups:Destroy()
	self.trove:Clean()
	self.frame:Destroy()
end

return ScorePopups
