--[[
	Notifications: toasts, banners and warnings that may appear on any screen.

	  * `Notify` remote {text, kind: "info"|"warning"|"objective", duration?} -> stacked toasts
	    (objective toasts are larger brass banners).
	  * Notifications:Banner(title, subtitle, color) -> big centre banner (level-up, round start).
	  * Out-of-bounds warning: big red countdown while the local character is outside the map
	    bounds from GameState.MapInfoJson (checked at 4 Hz; uses mapInfo.outOfBounds or 10 s).
	Toast frames are pooled.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameState = require(Shared.GameState)
local Trove = require(Shared.Util.Trove)

local UI = script.Parent
local Data = require(UI.Data)
local Remotes = require(UI.Remotes)
local Theme = require(UI.Theme)

local Notifications = {}
Notifications.__index = Notifications

local MAX_TOASTS = 4
local LOCAL_PLAYER = Players.LocalPlayer
local DEFAULT_OOB_TIME = 10

local KIND_STYLE = {
	info = { color = Theme.Colors.PanelLight, text = Theme.Colors.Text, accent = Theme.Colors.Khaki },
	warning = { color = Color3.fromRGB(96, 30, 24), text = Theme.Colors.Text, accent = Theme.Colors.Danger },
	objective = { color = Theme.Colors.Panel, text = Theme.Colors.Text, accent = Theme.Colors.Accent },
}

function Notifications.new(ctx)
	local self = setmetatable({}, Notifications)
	self.ctx = ctx
	self.trove = Trove.new()
	self.toasts = {}
	self.counter = 0
	self.hudActive = false
	self.oobStart = nil :: number?

	local stack = Theme.new("Frame", {
		Name = "Toasts",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 190),
		Size = UDim2.fromOffset(520, 200),
		Parent = ctx.overlayRoot,
	})
	Theme.list(stack, Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center)
	self.stack = stack
	for i = 1, MAX_TOASTS do
		self.toasts[i] = self:_buildToast(i)
	end

	-- Big centre banner
	local banner = Theme.new("Frame", {
		Name = "Banner",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.fromOffset(640, 90),
		Visible = false,
		Parent = ctx.overlayRoot,
	})
	local band = Theme.panel({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, 70),
		Style = "dark",
		Parent = banner,
	})
	self.bannerStripe = Theme.new("Frame", {
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 3),
		Parent = band,
	})
	self.bannerTitle = Theme.label({
		Kind = "title",
		Text = "",
		TextSize = 34,
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(1, 0, 0, 38),
		Parent = band,
	})
	self.bannerSub = Theme.label({
		Kind = "type",
		Text = "",
		TextSize = 15,
		TextColor3 = Theme.Colors.Khaki,
		Position = UDim2.fromOffset(0, 42),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = band,
	})
	self.banner = banner
	self.bannerScale = Theme.new("UIScale", { Parent = banner })

	-- Out-of-bounds warning
	local oob = Theme.new("Frame", {
		Name = "OutOfBounds",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(620, 150),
		Visible = false,
		Parent = ctx.overlayRoot,
	})
	Theme.label({
		Kind = "title",
		Text = "RETURN TO THE BATTLEFIELD",
		TextSize = 32,
		TextColor3 = Theme.Colors.Danger,
		TextStrokeTransparency = 0.3,
		Size = UDim2.new(1, 0, 0, 40),
		Parent = oob,
	})
	self.oobCount = Theme.label({
		Kind = "title",
		Text = "10",
		TextSize = 72,
		TextColor3 = Theme.Colors.Danger,
		TextStrokeTransparency = 0.3,
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(1, 0, 0, 76),
		Parent = oob,
	})
	Theme.label({
		Kind = "type",
		Text = "Deserters will be shot.",
		TextSize = 15,
		TextColor3 = Theme.Colors.Text,
		Position = UDim2.fromOffset(0, 118),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = oob,
	})
	self.oob = oob

	Remotes.onEvent("Notify", function(payload)
		if type(payload) == "table" and type(payload.text) == "string" then
			self:Toast(payload.text, payload.kind, tonumber(payload.duration))
		end
	end, self.trove)

	local acc = 0
	self.trove:Add(RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.25 then
			acc = 0
			self:_checkBounds()
		end
	end))
	return self
end

function Notifications:_buildToast(i: number)
	local frame = Theme.panel({
		Name = "Toast" .. i,
		Size = UDim2.fromOffset(440, 34),
		Visible = false,
		Parent = self.stack,
	})
	local accent = Theme.new("Frame", {
		BackgroundColor3 = Theme.Colors.Khaki,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 4, 1, 0),
		Parent = frame,
	})
	local label = Theme.label({
		Kind = "heading",
		Text = "",
		TextSize = 16,
		TextWrapped = true,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -20, 1, 0),
		Parent = frame,
	})
	local scale = Theme.new("UIScale", { Parent = frame })
	return { frame = frame, accent = accent, label = label, scale = scale, serial = 0 }
end

--[[
	Shows a toast. kind: "info" | "warning" | "objective". duration defaults to 4 s.
]]
function Notifications:Toast(text: string, kind: string?, duration: number?)
	local style = KIND_STYLE[kind or "info"] or KIND_STYLE.info
	self.counter += 1
	local toast = self.toasts[1]
	for _, t in self.toasts do
		if not t.frame.Visible then
			toast = t
			break
		end
		if t.serial < toast.serial then
			toast = t
		end
	end
	toast.serial = self.counter
	toast.frame.LayoutOrder = self.counter
	toast.frame.BackgroundColor3 = style.color
	toast.accent.BackgroundColor3 = style.accent
	toast.label.Text = string.upper(text)
	toast.label.TextColor3 = style.text
	local big = kind == "objective"
	toast.label.TextSize = big and 20 or 16
	toast.frame.Size = UDim2.fromOffset(big and 500 or 440, big and 42 or 34)
	toast.frame.BackgroundTransparency = 0.08
	toast.label.TextTransparency = 0
	toast.frame.Visible = true
	toast.scale.Scale = 0.85
	Theme.tween(toast.scale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back)

	local serial = toast.serial
	task.delay(duration or 4, function()
		if toast.serial ~= serial then
			return
		end
		Theme.tween(toast.frame, 0.35, { BackgroundTransparency = 1 })
		Theme.tween(toast.label, 0.35, { TextTransparency = 1 })
		task.delay(0.35, function()
			if toast.serial == serial then
				toast.frame.Visible = false
			end
		end)
	end)
end

--[[
	Big centre banner (e.g. "PROMOTED" / "LEVEL 5").
]]
function Notifications:Banner(title: string, subtitle: string?, color: Color3?, duration: number?)
	self.bannerTitle.Text = string.upper(title)
	self.bannerSub.Text = string.upper(subtitle or "")
	self.bannerStripe.BackgroundColor3 = color or Theme.Colors.Accent
	self.bannerTitle.TextColor3 = color or Theme.Colors.Accent
	self.banner.Visible = true
	self.bannerScale.Scale = 1.4
	Theme.tween(self.bannerScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	self.counter += 1
	local serial = self.counter
	self.bannerSerial = serial
	task.delay(duration or 3.5, function()
		if self.bannerSerial == serial then
			self.banner.Visible = false
		end
	end)
end

-- The out-of-bounds check only runs while the HUD is active (deployed and alive).
function Notifications:SetHudActive(active: boolean)
	self.hudActive = active
	if not active then
		self.oobStart = nil
		self.oob.Visible = false
	end
end

function Notifications:_checkBounds()
	local info = self.hudActive and Data.mapInfo() or nil
	local root = info and Data.rootPart(LOCAL_PLAYER)
	if not info or not root or GameState.get("Phase") ~= "InRound" then
		self.oobStart = nil
		self.oob.Visible = false
		return
	end
	local b = info.bounds
	local p = root.Position
	local outside = math.abs(p.X - b.cx) > b.sx / 2 or math.abs(p.Z - b.cz) > b.sz / 2
	if outside then
		if not self.oobStart then
			self.oobStart = os.clock()
		end
		local limit = tonumber(info.outOfBounds) or DEFAULT_OOB_TIME
		local left = math.max(0, limit - (os.clock() - self.oobStart))
		self.oobCount.Text = tostring(math.ceil(left))
		self.oob.Visible = true
	else
		self.oobStart = nil
		self.oob.Visible = false
	end
end

function Notifications:Destroy()
	self.trove:Clean()
	self.stack:Destroy()
	self.banner:Destroy()
	self.oob:Destroy()
end

return Notifications
