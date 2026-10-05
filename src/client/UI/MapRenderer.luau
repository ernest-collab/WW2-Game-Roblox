--[[
	MapRenderer: draws the tactical map (terrain shapes, objectives, friendlies, spotted enemies,
	friendly vehicles, local player, optional spawn points) inside any GuiObject.

	Two modes:
	  "mini" -- player-centred, fixed range in studs, optionally rotating with the camera; clipped by
	            a CanvasGroup (rotated content clips correctly).
	  "full" -- whole map fitted to the container, north-up (big map / deploy spawn map).

	Cost model: shapes are built once per map. Markers are pooled and refreshed by Refresh() (call at
	~15 Hz). Only UpdateView() runs per frame in mini mode (two property writes + the self arrow).

	  local r = MapRenderer.new(parent, {mode = "mini", rangeStuds = 260, size = 230})
	  r:Refresh()      -- markers
	  r:UpdateView()   -- per-frame (mini)
	  r:SetSpawnOptions(options, selectedId, onClick)  -- full mode, deploy screen
	  r:Destroy()
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Config.Constants)
local GameState = require(Shared.GameState)

local UI = script.Parent
local Data = require(UI.Data)
local Theme = require(UI.Theme)

local MapRenderer = {}
MapRenderer.__index = MapRenderer

local LOCAL_PLAYER = Players.LocalPlayer

export type Options = {
	mode: "mini" | "full",
	rangeStuds: number?, -- mini: radius shown
	size: number?, -- mini: logical pixel size of the (square) viewport
	rotate: boolean?,
	showLabels: boolean?,
	showPlayers: boolean?,
}

local function newMarker(parent: Instance, kind: string): Frame
	local f = Theme.new("Frame", {
		Name = kind,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 5,
		Parent = parent,
	})
	if kind == "friend" or kind == "squad" then
		f.Size = UDim2.fromOffset(8, 8)
		Theme.round(f)
		Theme.stroke(f, Theme.Colors.Ink, 1, 0.1)
	elseif kind == "enemy" then
		f.Size = UDim2.fromOffset(8, 8)
		f.Rotation = 45
		f.BackgroundColor3 = Constants.SIDE_COLORS.Axis
		Theme.stroke(f, Theme.Colors.Ink, 1, 0.1)
	elseif kind == "vehicle" then
		f.Size = UDim2.fromOffset(14, 10)
		Theme.corner(f, 2)
		Theme.stroke(f, Theme.Colors.Ink, 1, 0.1)
		Theme.label({
			Name = "Glyph",
			Kind = "title",
			Text = "V",
			TextSize = 9,
			TextColor3 = Theme.Colors.Ink,
			TextStrokeTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = f,
		})
	end
	return f
end

function MapRenderer.new(parent: GuiObject, opts: Options)
	local self = setmetatable({}, MapRenderer)
	self.opts = opts
	self.mode = opts.mode
	self.rotate = opts.rotate == true
	self.range = opts.rangeStuds or 260
	self.size = opts.size or 230
	self.info = nil :: Data.MapInfo?
	self.pools = { friend = {}, squad = {}, enemy = {}, vehicle = {} }
	self.objectiveMarkers = {} :: { [string]: any }
	self.spawnButtons = {} :: { [string]: TextButton }
	self.blink = false

	-- Viewport: CanvasGroup clips rotated descendants correctly.
	local viewport = Theme.new(self.mode == "mini" and "CanvasGroup" or "Frame", {
		Name = "MapViewport",
		BackgroundColor3 = Theme.MapColors.background,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		Parent = parent,
	})
	if self.mode == "mini" then
		Theme.round(viewport)
	else
		Theme.corner(viewport, 4)
	end
	Theme.grain(viewport, 35)
	self.viewport = viewport

	local content = Theme.new("Frame", {
		Name = "Content",
		BackgroundColor3 = Theme.MapColors.background,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
	})
	Theme.grain(content, 120)
	if self.mode == "mini" then
		-- Size-0 pivot at the viewport centre: rotating it rotates the map around the player.
		self.pivot = Theme.new("Frame", {
			Name = "Pivot",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(0, 0),
			Position = UDim2.fromScale(0.5, 0.5),
			Parent = viewport,
		})
		content.Parent = self.pivot
	else
		content.AnchorPoint = Vector2.new(0.5, 0.5)
		content.Position = UDim2.fromScale(0.5, 0.5)
		content.Size = UDim2.fromScale(1, 1)
		self.aspect = Theme.new("UIAspectRatioConstraint", {
			AspectType = Enum.AspectType.FitWithinMaxSize,
			AspectRatio = 1,
			Parent = content,
		})
		content.Parent = viewport
	end
	self.content = content

	local function layer(name: string, z: number): Frame
		return Theme.new("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = z,
			Parent = content,
		})
	end
	self.shapeLayer = layer("Shapes", 1)
	self.objectiveLayer = layer("Objectives", 3)
	self.markerLayer = layer("Markers", 4)
	self.spawnLayer = layer("Spawns", 6)

	-- Grid lines (map squares) for the full map.
	if self.mode == "full" then
		for i = 1, 7 do
			for _, vertical in { true, false } do
				Theme.new("Frame", {
					BackgroundColor3 = Theme.Colors.Ink,
					BackgroundTransparency = 0.82,
					BorderSizePixel = 0,
					Size = vertical and UDim2.new(0, 1, 1, 0) or UDim2.new(1, 0, 0, 1),
					Position = vertical and UDim2.fromScale(i / 8, 0) or UDim2.fromScale(0, i / 8),
					ZIndex = 2,
					Parent = self.shapeLayer,
				})
			end
		end
	end

	-- Local player arrow.
	local arrow = Theme.label({
		Name = "Self",
		Kind = "glyph",
		Text = "▲",
		TextSize = self.mode == "mini" and 18 or 16,
		TextColor3 = Theme.Colors.Accent,
		TextStrokeTransparency = 0.2,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(20, 20),
		ZIndex = 8,
		Visible = false,
	})
	if self.mode == "mini" then
		arrow.Position = UDim2.fromScale(0.5, 0.5)
		arrow.Parent = viewport
	else
		arrow.Parent = self.markerLayer
	end
	self.selfArrow = arrow

	-- Placeholder when no map is loaded.
	self.emptyLabel = Theme.label({
		Kind = "type",
		Text = "NO MAP DATA",
		TextSize = 14,
		TextColor3 = Theme.Colors.TextDim,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 9,
		Parent = viewport,
	})

	self:SetMapInfo(Data.mapInfo())
	return self
end

------------------------------------------------------------------------------------------------
-- Map shapes
------------------------------------------------------------------------------------------------

function MapRenderer:SetMapInfo(info: Data.MapInfo?)
	if info == self.info then
		return
	end
	self.info = info
	for _, child in self.shapeLayer:GetChildren() do
		if child:GetAttribute("Shape") then
			child:Destroy()
		end
	end
	for _, m in self.objectiveMarkers do
		m.frame:Destroy()
	end
	self.objectiveMarkers = {}
	self.emptyLabel.Visible = info == nil
	if not info then
		return
	end

	local b = info.bounds
	if self.mode == "mini" then
		local pxPerStud = (self.size / 2) / self.range
		self.content.Size = UDim2.fromOffset(b.sx * pxPerStud, b.sz * pxPerStud)
	else
		self.aspect.AspectRatio = b.sx / b.sz
	end

	for _, shape in info.minimap do
		local kind = shape.kind or "field"
		local u, v = Data.toUV(info, tonumber(shape.cx) or 0, tonumber(shape.cz) or 0)
		local f = Theme.new("Frame", {
			BackgroundColor3 = Theme.MapColors[kind] or Theme.MapColors.field,
			BackgroundTransparency = kind == "field" and 0.35 or 0.05,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(u, v),
			Size = UDim2.fromScale((tonumber(shape.sx) or 4) / b.sx, (tonumber(shape.sz) or 4) / b.sz),
			-- World yaw (degrees, CCW seen from above) -> GUI rotation (CW).
			Rotation = -(tonumber(shape.rot) or 0),
			ZIndex = kind == "building" and 2 or 1,
			Parent = self.shapeLayer,
		})
		f:SetAttribute("Shape", true)
		if kind == "building" then
			Theme.stroke(f, Theme.Colors.Ink, 1, 0.5)
		end
	end

	-- HQ markers
	for side, hq in info.hq do
		if type(hq) == "table" and hq.x and hq.z then
			local u, v = Data.toUV(info, hq.x, hq.z)
			local f = Theme.label({
				Kind = "title",
				Text = "HQ",
				TextSize = 11,
				TextColor3 = Theme.sideColor(side),
				TextStrokeTransparency = 0.3,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(u, v),
				Size = UDim2.fromOffset(26, 14),
				ZIndex = 3,
				Parent = self.shapeLayer,
			})
			f:SetAttribute("Shape", true)
		end
	end
end

------------------------------------------------------------------------------------------------
-- Markers
------------------------------------------------------------------------------------------------

function MapRenderer:_objectiveMarker(id: string)
	local m = self.objectiveMarkers[id]
	if m then
		return m
	end
	local frame = Theme.new("Frame", {
		Name = "Obj_" .. id,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(self.mode == "mini" and 18 or 24, self.mode == "mini" and 18 or 24),
		BackgroundColor3 = Constants.SIDE_COLORS.Neutral,
		BorderSizePixel = 0,
		ZIndex = 4,
		Parent = self.objectiveLayer,
	})
	Theme.round(frame)
	local stroke = Theme.stroke(frame, Theme.Colors.Ink, 2, 0)
	local label = Theme.label({
		Kind = "title",
		Text = id,
		TextSize = self.mode == "mini" and 12 or 15,
		TextColor3 = Theme.Colors.Ink,
		TextStrokeTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 5,
		Parent = frame,
	})
	local radius = Theme.new("Frame", {
		Name = "Radius",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundTransparency = 0.85,
		BorderSizePixel = 0,
		ZIndex = 3,
		Visible = self.mode == "full",
		Parent = self.objectiveLayer,
	})
	Theme.round(radius)
	local nameLabel = nil
	if self.mode == "full" and self.opts.showLabels ~= false then
		nameLabel = Theme.label({
			Kind = "bold",
			Text = "",
			TextSize = 12,
			AnchorPoint = Vector2.new(0.5, 0),
			Size = UDim2.fromOffset(140, 14),
			ZIndex = 5,
			Parent = self.objectiveLayer,
		})
	end
	m = { frame = frame, stroke = stroke, label = label, radius = radius, nameLabel = nameLabel }
	self.objectiveMarkers[id] = m
	return m
end

local function acquire(pool: { Frame }, index: number, parent: Instance, kind: string): Frame
	local f = pool[index]
	if not f then
		f = newMarker(parent, kind)
		pool[index] = f
	end
	return f
end

local function hideFrom(pool: { Frame }, fromIndex: number)
	for i = fromIndex, #pool do
		pool[i].Visible = false
	end
end

--[[
	Refreshes every dynamic marker. Cheap enough at 15–20 Hz with a full server.
]]
function MapRenderer:Refresh()
	local info = Data.mapInfo()
	if info ~= self.info then
		self:SetMapInfo(info)
	end
	info = self.info
	if not info then
		return
	end
	self.blink = (os.clock() % 0.8) < 0.4
	local mySide = Data.localSide()
	local mySquad = LOCAL_PLAYER:GetAttribute("Squad") or 0
	local counterRot = self.mode == "mini" and self.rotate and -self.pivot.Rotation or 0

	-- Objectives (hidden in modes without objectives)
	local objFolder = GameState.folder():FindFirstChild("Objectives")
	local seen = {}
	if objFolder then
		for _, obj in objFolder:GetChildren() do
			local pos = obj:GetAttribute("Position")
			if typeof(pos) == "Vector3" then
				local m = self:_objectiveMarker(obj.Name)
				seen[obj.Name] = true
				local u, v = Data.toUV(info, pos.X, pos.Z)
				local owner = obj:GetAttribute("Owner") or "Neutral"
				local contested = obj:GetAttribute("Contested") == true
				local locked = obj:GetAttribute("Locked") == true
				m.frame.Position = UDim2.fromScale(u, v)
				m.frame.BackgroundColor3 = Theme.sideColor(owner)
				m.frame.BackgroundTransparency = locked and 0.55 or 0
				m.frame.Rotation = counterRot
				m.frame.Visible = true
				m.stroke.Color = contested and (self.blink and Theme.Colors.Danger or Theme.Colors.Text)
					or Theme.Colors.Ink
				local radius = tonumber(obj:GetAttribute("Radius")) or 20
				m.radius.Position = m.frame.Position
				m.radius.Size = UDim2.fromScale(radius * 2 / info.bounds.sx, radius * 2 / info.bounds.sz)
				m.radius.BackgroundColor3 = Theme.sideColor(owner)
				if m.nameLabel then
					m.nameLabel.Position = UDim2.new(u, 0, v, 14)
					m.nameLabel.Text = string.upper(tostring(obj:GetAttribute("DisplayName") or obj.Name))
				end
			end
		end
	end
	for id, m in self.objectiveMarkers do
		if not seen[id] then
			m.frame.Visible = false
			m.radius.Visible = false
			if m.nameLabel then
				m.nameLabel.Visible = false
			end
		else
			m.radius.Visible = self.mode == "full"
			if m.nameLabel then
				m.nameLabel.Visible = true
			end
		end
	end

	-- Players
	local nFriend, nSquad, nEnemy = 0, 0, 0
	if self.opts.showPlayers ~= false and mySide ~= "" then
		for _, p in Players:GetPlayers() do
			if p ~= LOCAL_PLAYER and p:GetAttribute("Alive") ~= false then
				local root = Data.rootPart(p)
				if root then
					local pos = root.Position
					local u, v = Data.toUV(info, pos.X, pos.Z)
					local side = p:GetAttribute("Side")
					if side == mySide then
						local squad = p:GetAttribute("Squad") or 0
						local f
						if mySquad ~= 0 and squad == mySquad then
							nSquad += 1
							f = acquire(self.pools.squad, nSquad, self.markerLayer, "squad")
							f.BackgroundColor3 = Theme.Colors.Squad
						else
							nFriend += 1
							f = acquire(self.pools.friend, nFriend, self.markerLayer, "friend")
							f.BackgroundColor3 = Theme.sideColor(side)
						end
						f.Position = UDim2.fromScale(u, v)
						f.Visible = true
					elseif side == "Allies" or side == "Axis" then
						if Data.isSpotted(p) then
							nEnemy += 1
							local f = acquire(self.pools.enemy, nEnemy, self.markerLayer, "enemy")
							f.BackgroundColor3 = Theme.sideColor(side)
							f.Position = UDim2.fromScale(u, v)
							f.Visible = true
						end
					end
				end
			end
		end
	end
	hideFrom(self.pools.friend, nFriend + 1)
	hideFrom(self.pools.squad, nSquad + 1)
	hideFrom(self.pools.enemy, nEnemy + 1)

	-- Friendly vehicles
	local nVeh = 0
	if mySide ~= "" then
		for _, vehicle in CollectionService:GetTagged(Constants.TAGS.Vehicle) do
			if
				vehicle:IsA("Model")
				and vehicle:GetAttribute("Side") == mySide
				and vehicle:GetAttribute("Destroyed") ~= true
				and vehicle:IsDescendantOf(Workspace)
			then
				local ok, pivot = pcall(vehicle.GetPivot, vehicle)
				if ok then
					nVeh += 1
					local f = acquire(self.pools.vehicle, nVeh, self.markerLayer, "vehicle")
					local u, v = Data.toUV(info, pivot.Position.X, pivot.Position.Z)
					f.Position = UDim2.fromScale(u, v)
					f.BackgroundColor3 = Theme.sideColor(mySide):Lerp(Color3.new(1, 1, 1), 0.25)
					f.Rotation = Data.heading(pivot.LookVector)
					f.Visible = true
				end
			end
		end
	end
	hideFrom(self.pools.vehicle, nVeh + 1)

	if self.mode == "full" then
		self:_updateSelfFull()
	end
end

function MapRenderer:_updateSelfFull()
	local info = self.info
	local root = Data.rootPart(LOCAL_PLAYER)
	if not info or not root or LOCAL_PLAYER:GetAttribute("Alive") == false then
		self.selfArrow.Visible = false
		return
	end
	local u, v = Data.toUV(info, root.Position.X, root.Position.Z)
	self.selfArrow.Position = UDim2.fromScale(u, v)
	self.selfArrow.Rotation = Data.heading(root.CFrame.LookVector)
	self.selfArrow.Visible = true
end

--[[
	Per-frame view update for the minimap: centres on the local player and rotates with the
	camera when rotation is enabled.
]]
function MapRenderer:UpdateView()
	if self.mode ~= "mini" then
		return
	end
	local info = self.info
	local root = Data.rootPart(LOCAL_PLAYER)
	local cam = Workspace.CurrentCamera
	if not info or not cam then
		self.selfArrow.Visible = false
		return
	end
	local focus = root and root.Position or cam.Focus.Position
	local u, v = Data.toUV(info, focus.X, focus.Z)
	local size = self.content.Size
	self.content.Position = UDim2.fromOffset(-u * size.X.Offset, -v * size.Y.Offset)
	local camHeading = Data.heading(cam.CFrame.LookVector)
	self.pivot.Rotation = self.rotate and -camHeading or 0
	if root then
		local charHeading = Data.heading(root.CFrame.LookVector)
		self.selfArrow.Rotation = self.rotate and (charHeading - camHeading) or charHeading
		self.selfArrow.Visible = true
	else
		self.selfArrow.Visible = false
	end
end

function MapRenderer:SetRotate(rotate: boolean)
	self.rotate = rotate
end

------------------------------------------------------------------------------------------------
-- Spawn points (deploy screen)
------------------------------------------------------------------------------------------------

--[[
	options: Spawn_GetOptions list {id, name, position, kind, available}
	onClick(id) is called when an available spawn is clicked.
]]
function MapRenderer:SetSpawnOptions(options: { any }?, selectedId: string?, onClick: ((string) -> ())?)
	local info = self.info
	local keep = {}
	for _, opt in options or {} do
		if type(opt) == "table" and type(opt.id) == "string" and typeof(opt.position) == "Vector3" and info then
			keep[opt.id] = true
			local btn = self.spawnButtons[opt.id]
			if not btn then
				btn = Theme.new("TextButton", {
					Name = "Spawn_" .. opt.id,
					AnchorPoint = Vector2.new(0.5, 0.5),
					Size = UDim2.fromOffset(30, 30),
					AutoButtonColor = false,
					BorderSizePixel = 0,
					FontFace = Theme.Fonts.Title,
					TextSize = 13,
					ZIndex = 7,
					Parent = self.spawnLayer,
				})
				Theme.corner(btn, 4)
				Theme.new("UIStroke", {
					Name = "Ring",
					Thickness = 2,
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Parent = btn,
				})
				btn.Activated:Connect(function()
					local cb = self.spawnClick
					local id = btn:GetAttribute("SpawnId")
					if cb and btn:GetAttribute("Available") and type(id) == "string" then
						cb(id)
					end
				end)
				self.spawnButtons[opt.id] = btn
			end
			local u, v = Data.toUV(info, opt.position.X, opt.position.Z)
			btn.Position = UDim2.fromScale(u, v)
			btn:SetAttribute("SpawnId", opt.id)
			btn:SetAttribute("Available", opt.available ~= false)
			local short = opt.kind == "HQ" and "HQ" or (opt.kind == "Squad" and "SQ" or opt.id)
			btn.Text = short
			local selected = opt.id == selectedId
			local mySide = Data.localSide()
			btn.BackgroundColor3 = opt.available == false and Theme.Colors.Locked
				or (selected and Theme.Colors.Accent or Theme.sideColor(mySide))
			btn.TextColor3 = Theme.Colors.Ink
			btn.BackgroundTransparency = opt.available == false and 0.4 or 0
			local ring = btn:FindFirstChild("Ring") :: UIStroke
			ring.Color = selected and Theme.Colors.Text or Theme.Colors.Ink
			ring.Thickness = selected and 3 or 1.5
			btn.Size = selected and UDim2.fromOffset(36, 36) or UDim2.fromOffset(30, 30)
			btn.Visible = true
		end
	end
	for id, btn in self.spawnButtons do
		if not keep[id] then
			btn.Visible = false
		end
	end
	self.spawnClick = onClick
end

function MapRenderer:SetVisible(visible: boolean)
	self.viewport.Visible = visible
end

function MapRenderer:Destroy()
	self.viewport:Destroy()
	self.objectiveMarkers = {}
	self.spawnButtons = {}
end

return MapRenderer
