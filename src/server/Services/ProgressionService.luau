--[[
	ProgressionService (Gameplay team)

	Persistent player progression: XP / level (1..50), per-weapon kill counts, career stats and
	client settings. Stored in the DataStore "WW2Frontlines_v1" under key "Player_<UserId>".

	Robustness
	  * Session locking via UpdateAsync: a profile is locked to this server (JobId) while the player is
	    here. A lock held by another live server is waited on (it normally releases within seconds when
	    the player teleports/rejoins) and stolen once stale or after LOCK_WAIT_ATTEMPTS.
	  * Every DataStore call is wrapped in pcall with exponential backoff retries.
	  * Progress earned before the profile finished loading is buffered and merged after load.
	  * If loading fails completely the profile is marked read-only for this session (we never
	    overwrite good data with defaults).
	  * Saves on leave (and releases the lock), periodic autosave, BindToClose flush.
	  * Studio without API access (or unpublished place): falls back to an in-memory store with a warning.

	Remotes
	  Progression_Get (RemoteFunction) -> ProgressionData
	  Progression_Updated (server -> client) ProgressionData
	  Settings_Save (client -> server) settings table (validated & size-limited)

	Player attributes: Level, XP (xp into current level), XPToNext (contract addition).

	Public API
	  ProgressionService.GetLevel(player) -> number
	  ProgressionService.AddXP(player, amount, reason?)
	  ProgressionService.RecordWeaponKill(player, weaponId)
	  ProgressionService.RecordMatch(player, result: "Win" | "Loss" | "Draw")
	  ProgressionService.GetData(player) -> ProgressionData?
	  ProgressionService.GetSettings(player) -> table
	  ProgressionService.IsUnlocked(player, weaponId) -> boolean
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Progression = require(Shared.Config.Progression)
local Net = require(Shared.Util.Net)

local ProgressionService = {}

local DATA_VERSION = 1
local KEY_PREFIX = "Player_"
local AUTOSAVE_INTERVAL = 120
local LOCK_EXPIRE = 300 -- seconds after which a lock from another server is considered stale
local LOCK_WAIT_ATTEMPTS = 4 -- ~ (attempts * LOCK_RETRY_DELAY) seconds before stealing a live lock
local LOCK_RETRY_DELAY = 6
local MAX_RETRIES = 5
local UPDATE_FLUSH_DELAY = 0.4 -- batch Progression_Updated pushes

type SaveData = {
	version: number,
	xp: number,
	weaponKills: { [string]: number },
	settings: { [string]: any },
	stats: { kills: number, deaths: number, wins: number, losses: number, matches: number },
	lock: { job: string, time: number }?,
}

type Profile = {
	player: Player,
	key: string,
	data: SaveData,
	loaded: boolean,
	readOnly: boolean, -- load failed: never write to the store this session
	dirty: boolean,
	saving: boolean,
	released: boolean,
	pending: { xp: number, weaponKills: { [string]: number } },
	updateQueued: boolean,
}

local profiles: { [Player]: Profile } = {}
local store: DataStore? = nil
local memoryMode = false
local memoryStore: { [string]: SaveData } = {}

local function defaultData(): SaveData
	return {
		version = DATA_VERSION,
		xp = 0,
		weaponKills = {},
		settings = {},
		stats = { kills = 0, deaths = 0, wins = 0, losses = 0, matches = 0 },
	}
end

-- Fills missing fields / repairs wrong types in data loaded from the store.
local function reconcile(raw: any): SaveData
	local data = defaultData()
	if type(raw) ~= "table" then
		return data
	end
	if type(raw.xp) == "number" and raw.xp == raw.xp and raw.xp >= 0 then
		data.xp = math.floor(raw.xp)
	end
	if type(raw.weaponKills) == "table" then
		for k, v in raw.weaponKills do
			if type(k) == "string" and type(v) == "number" then
				data.weaponKills[k] = math.max(0, math.floor(v))
			end
		end
	end
	if type(raw.settings) == "table" then
		data.settings = raw.settings
	end
	if type(raw.stats) == "table" then
		for k, _ in data.stats do
			local v = raw.stats[k]
			if type(v) == "number" then
				(data.stats :: any)[k] = math.max(0, math.floor(v))
			end
		end
	end
	if type(raw.lock) == "table" and type(raw.lock.job) == "string" and type(raw.lock.time) == "number" then
		data.lock = { job = raw.lock.job, time = raw.lock.time }
	end
	return data
end

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local function isAccessError(err: any): boolean
	local s = string.lower(tostring(err))
	return string.find(s, "studioaccesstoapisnotallowed", 1, true) ~= nil
		or string.find(s, "api services", 1, true) ~= nil
		or string.find(s, "publish", 1, true) ~= nil
		or string.find(s, "403", 1, true) ~= nil
end

local function enableMemoryMode(reason: string)
	if not memoryMode then
		memoryMode = true
		warn(`[ProgressionService] DataStore unavailable ({reason}); using in-memory progression (not persisted).`)
	end
end

local function waitForBudget()
	local deadline = os.clock() + 10
	while os.clock() < deadline do
		local ok, budget = pcall(
			DataStoreService.GetRequestBudgetForRequestType,
			DataStoreService,
			Enum.DataStoreRequestType.UpdateAsync
		)
		if not ok or budget > 0 then
			return
		end
		task.wait(0.5)
	end
end

-- UpdateAsync with retries + backoff. `transform` follows UpdateAsync semantics (return nil = cancel).
-- Returns (success, errorMessage).
local function updateWithRetry(key: string, transform: (any) -> any): (boolean, string?)
	if memoryMode then
		local result = transform(deepCopy(memoryStore[key]))
		if result ~= nil then
			memoryStore[key] = deepCopy(result)
		end
		return true, nil
	end
	local ds = store
	if not ds then
		return false, "no datastore"
	end
	local lastErr: string? = nil
	for attempt = 1, MAX_RETRIES do
		waitForBudget()
		local ok, err = pcall(function()
			ds:UpdateAsync(key, function(old)
				return transform(old)
			end)
		end)
		if ok then
			return true, nil
		end
		local message = tostring(err)
		lastErr = message
		if RunService:IsStudio() and isAccessError(err) then
			enableMemoryMode(message)
			return updateWithRetry(key, transform)
		end
		warn(`[ProgressionService] UpdateAsync {key} failed (attempt {attempt}/{MAX_RETRIES}): {message}`)
		if attempt < MAX_RETRIES then
			task.wait(math.min(2 ^ (attempt - 1), 16) + math.random() * 0.5)
		end
	end
	return false, lastErr
end

---------------------------------------------------------------------------------------------------
-- Derived data / replication
---------------------------------------------------------------------------------------------------

local function buildProgressionData(profile: Profile)
	local level, into, toNext = Progression.levelFromXP(profile.data.xp)
	return {
		level = level,
		xp = into,
		xpToNext = toNext,
		totalXP = profile.data.xp,
		unlocked = Progression.unlockedWeapons(level),
		weaponKills = table.clone(profile.data.weaponKills),
		settings = deepCopy(profile.data.settings),
		stats = table.clone(profile.data.stats),
		loaded = profile.loaded,
	}
end

local function writeAttributes(profile: Profile)
	local player = profile.player
	if not player.Parent then
		return
	end
	local level, into, toNext = Progression.levelFromXP(profile.data.xp)
	player:SetAttribute("Level", level)
	player:SetAttribute("XP", into)
	player:SetAttribute("XPToNext", toNext)
end

local function queueUpdate(profile: Profile)
	if profile.updateQueued then
		return
	end
	profile.updateQueued = true
	task.delay(UPDATE_FLUSH_DELAY, function()
		profile.updateQueued = false
		if profile.player.Parent and profiles[profile.player] == profile then
			Net.event("Progression_Updated"):FireClient(profile.player, buildProgressionData(profile))
		end
	end)
end

local function describeUnlocks(level: number): string?
	local u = Progression.unlocksAtLevel(level)
	local names = {}
	for _, list in { u.classes, u.weapons, u.vehicles } do
		for _, def in list do
			table.insert(names, tostring(def.name or def.id))
		end
	end
	if #names == 0 then
		return nil
	end
	if #names > 4 then
		return `{table.concat(names, ", ", 1, 4)} +{#names - 4} more`
	end
	return table.concat(names, ", ")
end

local function applyXP(profile: Profile, amount: number)
	local before = Progression.levelFromXP(profile.data.xp)
	profile.data.xp += amount
	profile.dirty = true
	local after = Progression.levelFromXP(profile.data.xp)
	writeAttributes(profile)
	queueUpdate(profile)
	if after > before and profile.player.Parent then
		for level = before + 1, after do
			local unlocks = describeUnlocks(level)
			local text = if unlocks then `Level {level} reached! Unlocked: {unlocks}` else `Level {level} reached!`
			Net.event("Notify"):FireClient(profile.player, { text = text, kind = "objective", duration = 6 })
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Load / save
---------------------------------------------------------------------------------------------------

local function save(profile: Profile, release: boolean): boolean
	if profile.readOnly or not profile.loaded then
		return false
	end
	if profile.saving then
		-- Wait for the in-flight save; a release still has to be written afterwards.
		local deadline = os.clock() + 30
		while profile.saving and os.clock() < deadline do
			task.wait(0.2)
		end
	end
	if not profile.dirty and not release then
		return true
	end
	profile.saving = true
	local snapshot = deepCopy(profile.data)
	profile.dirty = false
	local lostLock = false
	local ok, err = updateWithRetry(profile.key, function(old)
		local current = reconcile(old)
		if current.lock and current.lock.job ~= game.JobId and os.time() - current.lock.time < LOCK_EXPIRE then
			lostLock = true -- another server stole the session; never overwrite its data
			return nil
		end
		snapshot.version = DATA_VERSION
		snapshot.lock = if release then nil else { job = game.JobId, time = os.time() }
		return snapshot
	end)
	profile.saving = false
	if lostLock then
		warn(`[ProgressionService] session lock for {profile.key} was taken by another server; not saving.`)
		profile.readOnly = true
		return false
	end
	if not ok then
		profile.dirty = true
		warn(`[ProgressionService] save failed for {profile.key}: {err}`)
		return false
	end
	if release then
		profile.released = true
	end
	return true
end

local function load(profile: Profile)
	local loadedData: SaveData? = nil
	for lockAttempt = 1, LOCK_WAIT_ATTEMPTS + 1 do
		local lockedElsewhere = false
		local force = lockAttempt > LOCK_WAIT_ATTEMPTS
		local ok, err = updateWithRetry(profile.key, function(old)
			local current = reconcile(old)
			local lock = current.lock
			if lock and lock.job ~= game.JobId and os.time() - lock.time < LOCK_EXPIRE and not force then
				lockedElsewhere = true
				return nil
			end
			current.lock = { job = game.JobId, time = os.time() }
			loadedData = current
			return current
		end)
		if not ok then
			warn(`[ProgressionService] could not load {profile.key}: {err}. Progress this session will not be saved.`)
			profile.readOnly = true
			break
		end
		if not lockedElsewhere then
			break
		end
		if not profile.player.Parent then
			return
		end
		task.wait(LOCK_RETRY_DELAY)
	end

	if not profile.player.Parent or profiles[profile.player] ~= profile then
		-- Player left while loading: release the lock we may have taken.
		if loadedData and not profile.readOnly then
			profile.data = loadedData
			profile.loaded = true
			save(profile, true)
		end
		return
	end

	local data = loadedData or defaultData()
	data.lock = nil
	-- Merge progress earned before the load completed.
	local pendingXP = profile.pending.xp
	for weaponId, n in profile.pending.weaponKills do
		data.weaponKills[weaponId] = (data.weaponKills[weaponId] or 0) + n
	end
	-- Keep stats/settings accumulated so far (settings saved before load win).
	for k, v in profile.data.stats do
		(data.stats :: any)[k] += v
	end
	if next(profile.data.settings) ~= nil then
		data.settings = profile.data.settings
	end
	profile.data = data
	profile.pending = { xp = 0, weaponKills = {} }
	profile.loaded = true
	profile.dirty = pendingXP > 0
	writeAttributes(profile)
	if pendingXP > 0 then
		applyXP(profile, pendingXP)
	end
	queueUpdate(profile)
end

local function onPlayerAdded(player: Player)
	if profiles[player] then
		return
	end
	local profile: Profile = {
		player = player,
		key = KEY_PREFIX .. tostring(player.UserId),
		data = defaultData(),
		loaded = false,
		readOnly = false,
		dirty = false,
		saving = false,
		released = false,
		pending = { xp = 0, weaponKills = {} },
		updateQueued = false,
	}
	profiles[player] = profile
	writeAttributes(profile)
	-- Guests / test players with negative ids (Studio local server) never touch the real store.
	if player.UserId <= 0 and not memoryMode then
		profile.loaded = true
		profile.readOnly = true
		queueUpdate(profile)
		return
	end
	load(profile)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	profiles[player] = nil
	if profile.loaded and not profile.readOnly then
		save(profile, true)
	end
end

---------------------------------------------------------------------------------------------------
-- Settings validation
---------------------------------------------------------------------------------------------------

local function validValue(v: any): boolean
	local limits = Progression.SETTINGS_LIMITS
	local t = type(v)
	if t == "boolean" then
		return true
	elseif t == "number" then
		return v == v and v > -1e6 and v < 1e6
	elseif t == "string" then
		return #v <= limits.maxStringLength
	elseif t == "table" then
		-- Small arrays of numbers (e.g. an RGB color).
		local n = 0
		for k, x in v do
			n += 1
			if type(k) ~= "number" or type(x) ~= "number" or x ~= x or n > limits.maxArrayLength then
				return false
			end
		end
		return true
	end
	return false
end

local function sanitizeSettings(input: any): { [string]: any }?
	if type(input) ~= "table" then
		return nil
	end
	local limits = Progression.SETTINGS_LIMITS
	local out = {}
	local count = 0
	for k, v in input do
		if type(k) ~= "string" or #k == 0 or #k > limits.maxKeyLength then
			return nil
		end
		if not validValue(v) then
			return nil
		end
		count += 1
		if count > limits.maxKeys then
			return nil
		end
		out[k] = if type(v) == "table" then table.clone(v) else v
	end
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, out)
	if not ok or #encoded > limits.maxEncodedBytes then
		return nil
	end
	return out
end

---------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------

function ProgressionService.GetLevel(player: Player): number
	local profile = profiles[player]
	if not profile then
		return 1
	end
	return (Progression.levelFromXP(profile.data.xp + profile.pending.xp))
end

function ProgressionService.AddXP(player: Player, amount: number, _reason: string?)
	local profile = profiles[player]
	if not profile or type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	amount = math.floor(amount)
	if not profile.loaded then
		profile.pending.xp += amount
		return
	end
	applyXP(profile, amount)
end

function ProgressionService.RecordWeaponKill(player: Player, weaponId: string)
	local profile = profiles[player]
	if not profile or type(weaponId) ~= "string" or weaponId == "" or #weaponId > 64 then
		return
	end
	local target = if profile.loaded then profile.data.weaponKills else profile.pending.weaponKills
	target[weaponId] = (target[weaponId] or 0) + 1
	profile.data.stats.kills += 1
	profile.dirty = true
	queueUpdate(profile)
end

function ProgressionService.RecordDeath(player: Player)
	local profile = profiles[player]
	if profile then
		profile.data.stats.deaths += 1
		profile.dirty = true
	end
end

function ProgressionService.RecordMatch(player: Player, result: string)
	local profile = profiles[player]
	if not profile then
		return
	end
	local stats = profile.data.stats
	stats.matches += 1
	if result == "Win" then
		stats.wins += 1
	elseif result == "Loss" then
		stats.losses += 1
	end
	profile.dirty = true
end

function ProgressionService.GetData(player: Player)
	local profile = profiles[player]
	return if profile then buildProgressionData(profile) else nil
end

function ProgressionService.GetSettings(player: Player): { [string]: any }
	local profile = profiles[player]
	return if profile then deepCopy(profile.data.settings) else {}
end

function ProgressionService.IsUnlocked(player: Player, weaponId: string): boolean
	local def = Progression.getWeapons()[weaponId]
	if not def then
		return false
	end
	local need = if type(def.unlockLevel) == "number" then def.unlockLevel else 1
	return ProgressionService.GetLevel(player) >= need
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

function ProgressionService:Init()
	Net.func("Progression_Get")
	Net.event("Progression_Updated")
	Net.event("Settings_Save")
	Net.event("Notify")

	if game.PlaceId == 0 then
		enableMemoryMode("place is not published")
	else
		local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, Progression.DATASTORE_NAME)
		if ok then
			store = result
		else
			enableMemoryMode(tostring(result))
		end
	end
end

function ProgressionService:Start()
	Net.func("Progression_Get").OnServerInvoke = function(player: Player)
		if not Net.rateLimit(player, "Progression_Get", 4) then
			return nil
		end
		local deadline = os.clock() + 10
		local profile = profiles[player]
		while profile and not profile.loaded and os.clock() < deadline and player.Parent do
			task.wait(0.25)
			profile = profiles[player]
		end
		return if profile then buildProgressionData(profile) else nil
	end

	Net.event("Settings_Save").OnServerEvent:Connect(function(player: Player, payload: any)
		if not Net.rateLimit(player, "Settings_Save", 1) then
			return
		end
		local profile = profiles[player]
		if not profile then
			return
		end
		local clean = sanitizeSettings(payload)
		if not clean then
			Net.event("Notify")
				:FireClient(player, { text = "Settings could not be saved (invalid).", kind = "warning" })
			return
		end
		profile.data.settings = clean
		profile.dirty = true
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Autosave, staggered across players to spread request budget.
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			local list = {}
			for _, profile in profiles do
				if profile.dirty then
					table.insert(list, profile)
				end
			end
			local gap = if #list > 0 then math.min(2, AUTOSAVE_INTERVAL / 2 / #list) else 0
			for _, profile in list do
				if profiles[profile.player] == profile then
					task.spawn(save, profile, false)
					task.wait(gap)
				end
			end
		end
	end)

	game:BindToClose(function()
		local remaining = 0
		for player, profile in profiles do
			if profile.loaded and not profile.readOnly then
				remaining += 1
				task.spawn(function()
					save(profile, true)
					remaining -= 1
				end)
			end
			profiles[player] = nil
		end
		local deadline = os.clock() + 25
		while remaining > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return ProgressionService
