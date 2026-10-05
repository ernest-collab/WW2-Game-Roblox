--[[
	VehicleHUD: the vehicle crew ScreenGui (owned by VehicleController, Vehicle team).

	  * bottom panel: vehicle name, seat, hull health bar, CRITICAL tag, speed, ammo type list,
	    reload / magazine bar, MG heat bar, control hints
	  * aim crosshair (screen centre = where the camera/mouse aims)
	  * gun marker (where the main gun / MG actually points; turns green when on target & ready)
	  * gunner sight overlay (zoom): reticle, stadia chevrons, dark surround
	  * hit result banner ("PENETRATION" / "NON-PENETRATION" / "RICOCHET") and a damage flash

		local hud = HUD.new(playerGui)
		hud:Show(def, seatId, seatDef); hud:Hide()
		hud:SetHealth(h, max, critical); hud:SetSpeed(studsPerSecond); hud:SetAmmo(list, index)
		hud:SetReload(fraction, text); hud:SetHeat(fraction, overheated?); hud:SetSight(on)
		hud:SetGunMarker(screenPos?, ready, aligned); hud:ShowResult(text, color); hud:Flash(strength)
]]

local TweenService = game:GetService("TweenService")

local HUD = {}
HUD.__index = HUD

local FONT = Enum.Font.GothamBold
local FONT_REG = Enum.Font.Gotham
local WHITE = Color3.fromRGB(235, 235, 225)
local DIM = Color3.fromRGB(150, 150, 140)
local GREEN = Color3.fromRGB(120, 220, 120)
local AMBER = Color3.fromRGB(240, 180, 70)
local RED = Color3.fromRGB(230, 70, 60)
local PANEL = Color3.fromRGB(16, 18, 16)

export type HUD = typeof(setmetatable(
	{} :: {
		gui: ScreenGui,
		panel: Frame,
		nameLabel: TextLabel,
		seatLabel: TextLabel,
		healthFill: Frame,
		healthText: TextLabel,
		critical: TextLabel,
		speed: TextLabel,
		ammo: TextLabel,
		reloadFill: Frame,
		reloadBack: Frame,
		reloadText: TextLabel,
		heatFill: Frame,
		heatRow: Frame,
		hints: TextLabel,
		crosshair: Frame,
		gunMarker: Frame,
		sight: Frame,
		result: TextLabel,
		flash: Frame,
		resultTween: Tween?,
	},
	HUD
))

local function new(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(parent: Instance, radius: number)
	new("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local base = {
		BackgroundTransparency = 1,
		Font = FONT,
		TextColor3 = WHITE,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in props do
		base[k] = v
	end
	return new("TextLabel", base, parent)
end

local function bar(parent: Instance, pos: UDim2, size: UDim2, color: Color3): (Frame, Frame)
	local back = new("Frame", {
		Position = pos,
		Size = size,
		BackgroundColor3 = Color3.fromRGB(40, 42, 38),
		BorderSizePixel = 0,
	}, parent)
	corner(back, 3)
	local fill = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, back)
	corner(fill, 3)
	return back, fill
end

local function line(parent: Instance, pos: UDim2, size: UDim2, color: Color3?, transparency: number?): Frame
	return new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = pos,
		Size = size,
		BackgroundColor3 = color or Color3.fromRGB(20, 20, 20),
		BackgroundTransparency = transparency or 0,
		BorderSizePixel = 0,
	}, parent)
end

function HUD.new(playerGui: Instance): HUD
	local gui = new("ScreenGui", {
		Name = "VehicleHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 6,
		Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, playerGui)

	-- Gunner sight overlay (below everything else)
	local sight = new("Frame", {
		Name = "Sight",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
	}, gui)
	-- dark surround: four panels leaving a square window in the middle
	local w = 0.36
	for _, spec in
		{
			{ UDim2.fromScale(0.5, 0), UDim2.fromScale(1, 0.5 - w / 2), Vector2.new(0.5, 0) },
			{ UDim2.fromScale(0.5, 1), UDim2.fromScale(1, 0.5 - w / 2), Vector2.new(0.5, 1) },
			{ UDim2.fromScale(0, 0.5), UDim2.fromScale(0.5 - w * 0.75, 1), Vector2.new(0, 0.5) },
			{ UDim2.fromScale(1, 0.5), UDim2.fromScale(0.5 - w * 0.75, 1), Vector2.new(1, 0.5) },
		}
	do
		new("Frame", {
			AnchorPoint = spec[3],
			Position = spec[1],
			Size = spec[2],
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
		}, sight)
	end
	local ink = Color3.fromRGB(15, 15, 15)
	line(sight, UDim2.fromScale(0.5, 0.5), UDim2.new(0.25, 0, 0, 2), ink) -- horizontal
	line(sight, UDim2.new(0.5, 0, 0.5, 60), UDim2.new(0, 2, 0, 90), ink) -- lower post
	for i = -3, 3 do
		if i ~= 0 then
			-- range chevrons / stadia ticks
			line(sight, UDim2.new(0.5, i * 34, 0.5, 0), UDim2.new(0, 2, 0, if i % 2 == 0 then 18 else 10), ink)
		end
	end
	for i = 1, 4 do
		local chevron = label(sight, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0.5, 4 + i * 16),
			Size = UDim2.fromOffset(40, 16),
			Text = "^",
			TextColor3 = ink,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextSize = 20,
		})
		label(sight, {
			AnchorPoint = Vector2.new(0, 0),
			Position = UDim2.new(0.5, 16, 0.5, 4 + i * 16),
			Size = UDim2.fromOffset(40, 16),
			Text = tostring(i * 200),
			TextColor3 = ink,
			TextSize = 11,
			Font = FONT_REG,
		})
		chevron.ZIndex = 2
	end

	-- Crosshair (aim point = screen centre)
	local crosshair = new("Frame", {
		Name = "Crosshair",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(26, 26),
		BackgroundTransparency = 1,
	}, gui)
	local ring = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, crosshair)
	corner(ring, 13)
	new("UIStroke", { Color = WHITE, Thickness = 1.5, Transparency = 0.25 }, ring)
	line(crosshair, UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(3, 3), WHITE)

	-- Gun marker (where the bore actually points)
	local gunMarker = new("Frame", {
		Name = "GunMarker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(16, 16),
		BackgroundTransparency = 1,
		Visible = false,
	}, gui)
	new("UIStroke", { Color = AMBER, Thickness = 2, Name = "Stroke" }, gunMarker)

	-- Hit result banner + damage flash
	local result = label(gui, {
		Name = "HitResult",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -60),
		Size = UDim2.fromOffset(320, 30),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextSize = 22,
		TextTransparency = 1,
		TextStrokeTransparency = 1,
		Text = "",
	})
	local flash = new("Frame", {
		Name = "DamageFlash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = RED,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 0,
	}, gui)

	-- Bottom panel
	local panel = new("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(380, 112),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
	}, gui)
	corner(panel, 6)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
	}, panel)
	local nameLabel = label(panel, { Size = UDim2.new(0.65, 0, 0, 18), TextSize = 16, Text = "" })
	local seatLabel = label(panel, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.35, 0, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = DIM,
		Font = FONT_REG,
		Text = "",
	})
	local _, healthFill = bar(panel, UDim2.fromOffset(0, 24), UDim2.new(1, -90, 0, 10), GREEN)
	local healthText = label(panel, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 20),
		Size = UDim2.fromOffset(84, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 13,
		Text = "",
	})
	local critical = label(panel, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 0, -10),
		Size = UDim2.fromOffset(200, 20),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = RED,
		TextSize = 18,
		Text = "CRITICAL DAMAGE",
		Visible = false,
	})
	local speed = label(panel, {
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.fromOffset(110, 20),
		TextSize = 15,
		Text = "0 km/h",
	})
	local ammo = label(panel, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 40),
		Size = UDim2.fromOffset(240, 20),
		TextXAlignment = Enum.TextXAlignment.Right,
		RichText = true,
		TextSize = 14,
		Text = "",
	})
	local reloadBack, reloadFill = bar(panel, UDim2.fromOffset(0, 64), UDim2.new(1, -90, 0, 6), WHITE)
	local reloadText = label(panel, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 58),
		Size = UDim2.fromOffset(84, 16),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextSize = 12,
		Font = FONT_REG,
		Text = "",
	})
	local heatRow, heatFill = bar(panel, UDim2.fromOffset(0, 76), UDim2.new(1, -90, 0, 4), AMBER)
	local hints = label(panel, {
		Position = UDim2.fromOffset(0, 84),
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = 11,
		Font = FONT_REG,
		TextColor3 = DIM,
		Text = "",
	})

	return setmetatable({
		gui = gui,
		panel = panel,
		nameLabel = nameLabel,
		seatLabel = seatLabel,
		healthFill = healthFill,
		healthText = healthText,
		critical = critical,
		speed = speed,
		ammo = ammo,
		reloadFill = reloadFill,
		reloadBack = reloadBack,
		reloadText = reloadText,
		heatFill = heatFill,
		heatRow = heatRow,
		hints = hints,
		crosshair = crosshair,
		gunMarker = gunMarker,
		sight = sight,
		result = result,
		flash = flash,
		resultTween = nil,
	}, HUD)
end

function HUD.Show(self: HUD, def: any, seatId: string, seatDef: any, gamepad: boolean)
	self.nameLabel.Text = def.name
	self.seatLabel.Text = if seatDef.role == "driver" and def.turretTraverse > 0
		then "Commander / Driver"
		elseif seatDef.role == "driver" then "Driver"
		elseif seatDef.role == "gunner" then "Machine Gunner"
		else seatId
	local weapons = seatDef.weapons or {}
	local hasMain = table.find(weapons, "main") ~= nil
	local hasMG = #weapons > (if hasMain then 1 else 0)
	self.heatRow.Visible = hasMG
	self.ammo.Visible = #weapons > 0
	self.reloadBack.Visible = #weapons > 0
	self.reloadText.Visible = #weapons > 0
	self.crosshair.Visible = #weapons > 0 or seatDef.role == "driver"
	local hint
	if gamepad then
		hint = "R2 Fire  R1 MG  L2 Sight  Y Ammo  X Seat  D-Pad Down Exit"
	else
		hint = "LMB Fire  Space MG  RMB Sight  R Ammo  X Seat  F Exit  Alt Free look"
	end
	self.hints.Text = hint
	self.gui.Enabled = true
end

function HUD.Hide(self: HUD)
	self.gui.Enabled = false
	self.sight.Visible = false
	self.gunMarker.Visible = false
end

function HUD.SetHealth(self: HUD, health: number, maxHealth: number, critical: boolean)
	local f = math.clamp(health / math.max(maxHealth, 1), 0, 1)
	self.healthFill.Size = UDim2.fromScale(f, 1)
	self.healthFill.BackgroundColor3 = if f > 0.5 then GREEN elseif f > 0.25 then AMBER else RED
	self.healthText.Text = `{math.ceil(health)} / {maxHealth}`
	self.critical.Visible = critical
end

function HUD.SetSpeed(self: HUD, studsPerSecond: number)
	-- 1 stud ~ 0.28 m  ->  studs/s * 1.0 ~ km/h
	self.speed.Text = `{math.floor(math.abs(studsPerSecond) * 1.0 + 0.5)} km/h`
end

-- list: {"AP", "HE"}; selected index highlighted.
function HUD.SetAmmo(self: HUD, list: { string }, index: number, magText: string?)
	local parts = {}
	for i, name in list do
		if i == index then
			table.insert(parts, `<font color="#F0B446"><b>[{i}] {name}</b></font>`)
		else
			table.insert(parts, `<font color="#8C8C82">[{i}] {name}</font>`)
		end
	end
	local text = table.concat(parts, "   ")
	if magText then
		text ..= `   {magText}`
	end
	self.ammo.Text = text
end

function HUD.SetReload(self: HUD, fraction: number, text: string)
	self.reloadFill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	self.reloadFill.BackgroundColor3 = if fraction >= 1 then GREEN else WHITE
	self.reloadText.Text = text
end

function HUD.SetHeat(self: HUD, fraction: number, overheated: boolean)
	self.heatFill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	self.heatFill.BackgroundColor3 = if overheated then RED else AMBER
end

function HUD.SetSight(self: HUD, on: boolean)
	self.sight.Visible = on
end

function HUD.SetGunMarker(self: HUD, screenPos: Vector2?, ready: boolean, aligned: boolean)
	local m = self.gunMarker
	if not screenPos then
		m.Visible = false
		return
	end
	m.Visible = true
	m.Position = UDim2.fromOffset(screenPos.X, screenPos.Y)
	local stroke = m:FindFirstChild("Stroke") :: UIStroke?
	if stroke then
		stroke.Color = if not ready then RED elseif aligned then GREEN else AMBER
	end
end

function HUD.ShowResult(self: HUD, text: string, color: Color3)
	local r = self.result
	if self.resultTween then
		self.resultTween:Cancel()
	end
	r.Text = text
	r.TextColor3 = color
	r.TextTransparency = 0
	r.TextStrokeTransparency = 0.4
	local tween = TweenService:Create(
		r,
		TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.6),
		{ TextTransparency = 1, TextStrokeTransparency = 1 }
	)
	self.resultTween = tween
	tween:Play()
end

function HUD.Flash(self: HUD, strength: number)
	local f = self.flash
	f.BackgroundTransparency = 1 - math.clamp(strength, 0, 0.45)
	TweenService:Create(f, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()
end

function HUD.Destroy(self: HUD)
	self.gui:Destroy()
end

HUD.COLORS = { WHITE = WHITE, GREEN = GREEN, AMBER = AMBER, RED = RED }

return HUD
