--[[
	MonetizationService (Monetization team)

	Game passes, developer products and cosmetics. Nothing sold here adds combat power: see
	Config/Monetization and docs/MONETIZATION.md.

	Persistence
	  Own DataStore "WW2Frontlines_Monetization_v1", key "Player_<UserId>":
	    {version, boostExpires (os.time), weapons {[id]=true}, tokens, receipts {[PurchaseId]=os.time},
	     supportTotal, supportTier, camo, uniform, presets {["1".."8"] = {classId, primary, secondary, gadget1, gadget2}}}
	  EVERY change is an UpdateAsync transform applied to the latest stored value (no session lock and
	  no "save the in-memory copy" step), so concurrent servers can never overwrite each other and a
	  grant is durable the moment the call returns. Mutations per player are serialized by a mutex.

	ProcessReceipt (the only handler in the game — nobody else may assign it)
	  1. Player not in this server / data not loaded / unknown product -> NotProcessedYet (Roblox retries,
	     e.g. when the player rejoins).
	  2. One UpdateAsync both checks `receipts[PurchaseId]` (idempotency) and applies the grant + records
	     the PurchaseId atomically. If the id is already recorded nothing is granted twice.
	  3. PurchaseGranted is returned only after that UpdateAsync succeeded; any failure -> NotProcessedYet.
	  Receipts are pruned to the newest MAX_RECEIPTS ids.

	Weapon unlock flow: client `Shop_RequestUnlock {weaponId}` -> validate (exists, above the player's
	level, not owned) -> spend an Unlock Token if the player has one, otherwise remember the choice
	server-side (pendingUnlock, PENDING_UNLOCK_TTL) and prompt the WeaponUnlock product. The receipt
	grants the pending weapon, or an Unlock Token when there is no valid pending choice.

	Remotes
	  Shop_GetState (RemoteFunction) -> ShopState (see buildState)
	  Shop_Purchase {kind: "pass"|"product", key}      -- server prompts the purchase
	  Shop_RequestUnlock {weaponId}
	  Shop_SetCosmetic {camo: string?, uniform: string?}   -- "" = default; ownership validated
	  Shop_SavePreset {index, classId?, loadout?}          -- classId nil/"" clears the preset
	  Shop_Updated (server -> client) ShopState

	Player attributes: VIP (bool), Supporter (bool), XPMultiplier (number), XPBoostExpires (os.time),
	OwnedPasses (JSON array of pass keys), UniformVariant (string, only when owned), Camo (selected
	camo id, only when owned), CamoUnlocked (bool).

	Public API
	  MonetizationService.GetXPMultiplier(player) -> number
	  MonetizationService.HasPass(player, key) -> boolean
	  MonetizationService.IsWeaponPurchased(player, weaponId) -> boolean
	  MonetizationService.GetPurchasedWeapons(player) -> {[weaponId]: true}
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Monetization = require(Shared.Config.Monetization)
local Classes = require(Shared.Config.Classes)
local Weapons = require(Shared.Config.Weapons)
local Cosmetics = require(Shared.Cosmetics)
local Net = require(Shared.Util.Net)

local MonetizationService = {}

local DATA_VERSION = 1
local KEY_PREFIX = "Player_"
local MAX_RETRIES = 5
local MAX_RECEIPTS = 100
local OWNERSHIP_ATTEMPTS = 3
local OWNERSHIP_RECHECK = 60 -- seconds between re-checks when the ownership query failed
local TICK_INTERVAL = 5
local LOAD_WAIT = 15
local LOCK_WAIT = 30

type Preset = { classId: string, primary: string, secondary: string, gadget1: string, gadget2: string }

type SaveData = {
	version: number,
	boostExpires: number,
	weapons: { [string]: boolean },
	tokens: number,
	receipts: { [string]: number },
	supportTotal: number,
	supportTier: number,
	camo: string,
	uniform: string,
	presets: { [string]: Preset },
}

type Profile = {
	player: Player,
	key: string,
	data: SaveData,
	loaded: boolean,
	failed: boolean,
	busy: boolean,
	passes: { [string]: boolean },
	passCheckFailedAt: number?,
	pendingUnlock: { weaponId: string, at: number }?,
	lastMultiplier: number,
	boostWasActive: boolean,
}

local profiles: { [Player]: Profile } = {}
local store: DataStore? = nil
local memoryMode = false
local memoryStore: { [string]: any } = {}
local inFlight = 0 -- DataStore writes in progress (BindToClose waits for them)

---------------------------------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------------------------------

local serviceCache: { [string]: any } = {}
local function getService(name: string): any
	local cached = serviceCache[name]
	if cached then
		return cached
	end
	local module = script.Parent:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, result = pcall(require, module)
	if ok and type(result) == "table" then
		serviceCache[name] = result
		return result
	end
	return nil
end

local function callService(name: string, fn: string, ...: any): (boolean, any)
	local svc = getService(name)
	local f = svc and svc[fn]
	if type(f) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(f, ...)
	if not ok then
		warn(`[MonetizationService] {name}.{fn} failed: {result}`)
	end
	return ok, result
end

local function studioTest(): boolean
	return Monetization.STUDIO_TEST_GRANTS == true and RunService:IsStudio()
end

-- Item visible / purchasable in this server.
local function available(def: { id: number }?): boolean
	return def ~= nil and (Monetization.isConfigured(def) or studioTest())
end

local function notify(player: Player, text: string, kind: string?, duration: number?)
	if player.Parent then
		Net.event("Notify"):FireClient(player, { text = text, kind = kind or "info", duration = duration })
	end
end

local function playerLevel(player: Player): number
	local ok, level = callService("ProgressionService", "GetLevel", player)
	return if ok and type(level) == "number" then level else 1
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

local function defaultData(): SaveData
	return {
		version = DATA_VERSION,
		boostExpires = 0,
		weapons = {},
		tokens = 0,
		receipts = {},
		supportTotal = 0,
		supportTier = 0,
		camo = "",
		uniform = "",
		presets = {},
	}
end

local function num(v: any, min: number): number
	if type(v) == "number" and v == v and v > -math.huge and v < math.huge then
		return math.max(min, v)
	end
	return min
end

local function str(v: any, maxLen: number): string
	return if type(v) == "string" and #v <= maxLen then v else ""
end

local function sanitizePreset(raw: any): Preset?
	if type(raw) ~= "table" or type(raw.classId) ~= "string" or not Classes.get(raw.classId) then
		return nil
	end
	local preset: Preset = { classId = raw.classId, primary = "", secondary = "", gadget1 = "", gadget2 = "" }
	for _, slot in { "primary", "secondary", "gadget1", "gadget2" } do
		local id = raw[slot]
		if type(id) == "string" and Weapons.get(id) then
			(preset :: any)[slot] = id
		end
	end
	return preset
end

-- Fills missing fields / repairs wrong types in stored data.
local function reconcile(raw: any): SaveData
	local data = defaultData()
	if type(raw) ~= "table" then
		return data
	end
	data.boostExpires = math.floor(num(raw.boostExpires, 0))
	data.tokens = math.floor(num(raw.tokens, 0))
	data.supportTotal = math.floor(num(raw.supportTotal, 0))
	data.supportTier = math.floor(num(raw.supportTier, 0))
	data.camo = str(raw.camo, 32)
	data.uniform = str(raw.uniform, 32)
	if type(raw.weapons) == "table" then
		for id, v in raw.weapons do
			if type(id) == "string" and v == true then
				data.weapons[id] = true
			end
		end
	end
	if type(raw.receipts) == "table" then
		for id, t in raw.receipts do
			if type(id) == "string" and type(t) == "number" then
				data.receipts[id] = t
			end
		end
	end
	if type(raw.presets) == "table" then
		for k, p in raw.presets do
			local index = tonumber(k)
			local clean = sanitizePreset(p)
			if index and index >= 1 and index <= 16 and clean then
				data.presets[tostring(math.floor(index))] = clean
			end
		end
	end
	return data
end

local function pruneReceipts(data: SaveData)
	local list = {}
	for id, t in data.receipts do
		table.insert(list, { id = id, t = t })
	end
	if #list <= MAX_RECEIPTS then
		return
	end
	table.sort(list, function(a, b)
		return a.t > b.t
	end)
	for i = MAX_RECEIPTS + 1, #list do
		data.receipts[list[i].id] = nil
	end
end

---------------------------------------------------------------------------------------------------
-- DataStore access
---------------------------------------------------------------------------------------------------

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
		warn(
			`[MonetizationService] DataStore unavailable ({reason}); using in-memory store (Studio only, not persisted).`
		)
	end
end

local function useMemory(key: string): boolean
	-- Studio local-server test players have negative ids: never touch the real store.
	return memoryMode or string.sub(key, #KEY_PREFIX + 1, #KEY_PREFIX + 1) == "-"
end

local function waitForBudget(requestType: Enum.DataStoreRequestType)
	local deadline = os.clock() + 10
	while os.clock() < deadline do
		local ok, budget = pcall(DataStoreService.GetRequestBudgetForRequestType, DataStoreService, requestType)
		if not ok or budget > 0 then
			return
		end
		task.wait(0.5)
	end
end

-- UpdateAsync with retries. `transform` follows UpdateAsync semantics (nil = cancel write).
local function updateWithRetry(key: string, transform: (any) -> any): (boolean, string?)
	if useMemory(key) then
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
		waitForBudget(Enum.DataStoreRequestType.UpdateAsync)
		local ok, err = pcall(function()
			ds:UpdateAsync(key, function(old)
				return transform(old)
			end)
		end)
		if ok then
			return true, nil
		end
		lastErr = tostring(err)
		if RunService:IsStudio() and isAccessError(err) then
			enableMemoryMode(tostring(err))
			return updateWithRetry(key, transform)
		end
		warn(`[MonetizationService] UpdateAsync {key} failed ({attempt}/{MAX_RETRIES}): {lastErr}`)
		if attempt < MAX_RETRIES then
			task.wait(math.min(2 ^ (attempt - 1), 16) + math.random() * 0.5)
		end
	end
	return false, lastErr
end

local function readWithRetry(key: string): (boolean, any)
	if useMemory(key) then
		return true, deepCopy(memoryStore[key])
	end
	local ds = store
	if not ds then
		return false, "no datastore"
	end
	for attempt = 1, MAX_RETRIES do
		waitForBudget(Enum.DataStoreRequestType.GetAsync)
		local ok, result = pcall(function()
			local options = Instance.new("DataStoreGetOptions")
			options.UseCache = false
			return ds:GetAsync(key, options)
		end)
		if ok then
			return true, result
		end
		if RunService:IsStudio() and isAccessError(result) then
			enableMemoryMode(tostring(result))
			return readWithRetry(key)
		end
		warn(`[MonetizationService] GetAsync {key} failed ({attempt}/{MAX_RETRIES}): {result}`)
		if attempt < MAX_RETRIES then
			task.wait(math.min(2 ^ (attempt - 1), 16) + math.random() * 0.5)
		end
	end
	return false, nil
end

---------------------------------------------------------------------------------------------------
-- Derived state / replication
---------------------------------------------------------------------------------------------------

local function hasPass(profile: Profile?, key: string): boolean
	if studioTest() and Monetization.Passes[key] then
		return true
	end
	return profile ~= nil and profile.passes[key] == true
end

local function isPremium(player: Player): boolean
	return player.MembershipType == Enum.MembershipType.Premium
end

local function boostActive(profile: Profile): boolean
	return profile.data.boostExpires > os.time()
end

local function multiplierFor(player: Player, profile: Profile?): number
	return Monetization.xpMultiplier({
		vip = hasPass(profile, "VIP"),
		doubleXP = hasPass(profile, "DoubleXP"),
		boost = profile ~= nil and boostActive(profile),
		premium = isPremium(player),
	})
end

local function ownsCosmetic(profile: Profile, def: { requires: string? }?): boolean
	if not def then
		return false
	end
	return def.requires == nil or hasPass(profile, def.requires)
end

local function presetLimit(profile: Profile): number
	return Monetization.presetLimit(hasPass(profile, "LoadoutPresets"))
end

local function buildState(profile: Profile)
	local passes = {}
	for _, p in Monetization.passList() do
		if available(p) then
			table.insert(passes, {
				key = p.key,
				name = p.name,
				description = p.description,
				price = p.price,
				perks = table.clone(p.perks),
				icon = p.icon,
				owned = hasPass(profile, p.key),
			})
		end
	end
	local products = {}
	for _, p in Monetization.productList() do
		if available(p) then
			table.insert(products, {
				key = p.key,
				kind = p.kind,
				name = p.name,
				description = p.description,
				price = p.price,
				icon = p.icon,
				boostSeconds = p.boostSeconds,
				tier = p.tier,
			})
		end
	end
	local owned = {}
	for key in Monetization.Passes do
		owned[key] = hasPass(profile, key)
	end
	local weapons = {}
	for id in profile.data.weapons do
		table.insert(weapons, id)
	end
	local camos = {}
	for _, c in Monetization.Camos do
		table.insert(camos, { id = c.id, name = c.name, owned = ownsCosmetic(profile, c), requires = c.requires })
	end
	local uniforms = {}
	for _, u in Monetization.Uniforms do
		table.insert(uniforms, { id = u.id, name = u.name, owned = ownsCosmetic(profile, u), requires = u.requires })
	end
	local limit = presetLimit(profile)
	local presets = {}
	for i = 1, limit do
		local p = profile.data.presets[tostring(i)]
		if p then
			presets[tostring(i)] = table.clone(p)
		end
	end
	return {
		loaded = profile.loaded,
		available = not profile.failed,
		studioTest = studioTest(),
		serverTime = os.time(),
		passes = passes,
		products = products,
		owned = owned,
		boostExpires = profile.data.boostExpires,
		tokens = profile.data.tokens,
		weapons = weapons,
		camo = profile.data.camo,
		uniform = profile.data.uniform,
		camos = camos,
		uniforms = uniforms,
		supporter = profile.data.supportTotal > 0,
		xpMultiplier = multiplierFor(profile.player, profile),
		premium = isPremium(profile.player),
		presets = presets,
		presetLimit = limit,
		pendingUnlock = profile.pendingUnlock and profile.pendingUnlock.weaponId or nil,
	}
end

-- Writes player attributes from the cached state (cheap; safe to call often).
local function writeAttributes(profile: Profile)
	local player = profile.player
	if not player.Parent then
		return
	end
	local ownedKeys = {}
	for _, p in Monetization.passList() do
		if hasPass(profile, p.key) then
			table.insert(ownedKeys, p.key)
		end
	end
	local camo = Monetization.getCamo(profile.data.camo)
	local uniform = Monetization.getUniform(profile.data.uniform)
	local multiplier = multiplierFor(player, profile)
	profile.lastMultiplier = multiplier
	player:SetAttribute("VIP", hasPass(profile, "VIP"))
	player:SetAttribute("Supporter", profile.data.supportTotal > 0)
	player:SetAttribute("XPMultiplier", multiplier)
	player:SetAttribute("XPBoostExpires", profile.data.boostExpires)
	player:SetAttribute("OwnedPasses", HttpService:JSONEncode(ownedKeys))
	player:SetAttribute("Camo", if camo and ownsCosmetic(profile, camo) then camo.id else "")
	player:SetAttribute("UniformVariant", if uniform and ownsCosmetic(profile, uniform) then uniform.id else "")
	player:SetAttribute("CamoUnlocked", hasPass(profile, "CamoCollection") or hasPass(profile, "VIP"))
end

local function publish(profile: Profile)
	writeAttributes(profile)
	if profile.player.Parent and profiles[profile.player] == profile then
		Net.event("Shop_Updated"):FireClient(profile.player, buildState(profile))
	end
end

---------------------------------------------------------------------------------------------------
-- Mutations (serialized per player, each one an atomic UpdateAsync)
---------------------------------------------------------------------------------------------------

local function acquire(profile: Profile): boolean
	local deadline = os.clock() + LOCK_WAIT
	while profile.busy do
		if os.clock() > deadline then
			return false
		end
		task.wait(0.1)
	end
	profile.busy = true
	inFlight += 1
	return true
end

--[[
	Applies `fn` to the latest stored data inside UpdateAsync. `fn(data) -> boolean` mutates `data`
	and returns true to write it (false = nothing to change). `fn` may run more than once (UpdateAsync
	retries), so it must only set outer variables deterministically. Returns success.
]]
local function mutate(profile: Profile, fn: (SaveData) -> boolean): boolean
	if not acquire(profile) then
		return false
	end
	local result: SaveData? = nil
	local ok, err = updateWithRetry(profile.key, function(old)
		local data = reconcile(old)
		local write = fn(data)
		result = data
		if not write then
			return nil
		end
		data.version = DATA_VERSION
		return data
	end)
	profile.busy = false
	inFlight -= 1
	if not ok then
		warn(`[MonetizationService] write failed for {profile.key}: {err}`)
		return false
	end
	if result then
		profile.data = result
		profile.loaded = true
		profile.failed = false
	end
	publish(profile)
	return true
end

local function load(profile: Profile): boolean
	local ok, raw = readWithRetry(profile.key)
	if not ok then
		profile.failed = true
		warn(`[MonetizationService] could not load {profile.key}; purchases will be retried later.`)
		return false
	end
	profile.data = reconcile(raw)
	profile.loaded = true
	profile.failed = false
	return true
end

local function waitLoaded(profile: Profile, timeout: number): boolean
	local deadline = os.clock() + timeout
	while not profile.loaded and os.clock() < deadline and profile.player.Parent do
		if profile.failed then
			-- Retry the load once inline (e.g. a transient DataStore outage at join).
			profile.failed = false
			if load(profile) then
				publish(profile)
				return true
			end
			return false
		end
		task.wait(0.2)
	end
	return profile.loaded
end

---------------------------------------------------------------------------------------------------
-- Game passes
---------------------------------------------------------------------------------------------------

-- (owns, queryOk)
local function queryPass(player: Player, pass: Monetization.Pass): (boolean, boolean)
	if not Monetization.isConfigured(pass) then
		return false, true
	end
	for attempt = 1, OWNERSHIP_ATTEMPTS do
		local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, pass.id)
		if ok then
			return owns == true, true
		end
		warn(`[MonetizationService] UserOwnsGamePassAsync({pass.key}) failed ({attempt}): {owns}`)
		if attempt < OWNERSHIP_ATTEMPTS then
			task.wait(attempt)
		end
	end
	return false, false
end

local function refreshPasses(profile: Profile)
	local anyFailed = false
	for _, pass in Monetization.passList() do
		if not profile.passes[pass.key] then -- ownership never goes away mid-session
			local owns, ok = queryPass(profile.player, pass)
			if owns then
				profile.passes[pass.key] = true
			end
			anyFailed = anyFailed or not ok
		end
	end
	profile.passCheckFailedAt = if anyFailed then os.clock() else nil
end

---------------------------------------------------------------------------------------------------
-- Product grants
---------------------------------------------------------------------------------------------------

local function weaponUnlockError(player: Player, profile: Profile, weaponId: any): string?
	if type(weaponId) ~= "string" or #weaponId == 0 or #weaponId > 64 then
		return "Unknown weapon"
	end
	local def = Weapons.get(weaponId)
	if not def or def.category == "Melee" then
		return "Unknown weapon"
	end
	if profile.data.weapons[weaponId] then
		return "You already own this weapon"
	end
	if (def.unlockLevel or 1) <= playerLevel(player) then
		return "Already unlocked by your level"
	end
	return nil
end

local function thankYou(player: Player, product: Monetization.Product, outcome: string, weaponId: string?)
	if outcome == "boost" then
		notify(player, `{product.name} activated. Double XP is running!`, "objective", 6)
	elseif outcome == "weapon" then
		local def = weaponId and Weapons.get(weaponId)
		notify(player, `{def and def.name or weaponId} unlocked. Find it in your loadout.`, "objective", 6)
	elseif outcome == "token" then
		notify(player, "Weapon Unlock Token added. Spend it in the STORE (K).", "objective", 6)
	elseif outcome == "tip" then
		notify(player, "Thank you for supporting WW2 Frontlines! Supporter badge awarded.", "objective", 7)
	end
end

--[[
	Grants a product exactly once per purchaseId. Returns true when the grant is persisted (or was
	already persisted earlier), false when it must be retried (NotProcessedYet).
]]
local function grantProduct(
	profile: Profile,
	product: Monetization.Product,
	purchaseId: string,
	spent: number?
): boolean
	local player = profile.player
	local pending = profile.pendingUnlock
	local pendingId: string? = nil
	if pending and os.clock() - pending.at <= Monetization.PENDING_UNLOCK_TTL then
		pendingId = pending.weaponId
	end
	local level = playerLevel(player)
	local outcome = "dup"
	local grantedWeapon: string? = nil

	local ok = mutate(profile, function(data)
		grantedWeapon = nil
		if data.receipts[purchaseId] then
			outcome = "dup"
			return false
		end
		if product.kind == "Boost" then
			local now = os.time()
			local secs = product.boostSeconds or 3600
			data.boostExpires = math.min(math.max(data.boostExpires, now) + secs, now + Monetization.MAX_BOOST_SECONDS)
			outcome = "boost"
		elseif product.kind == "WeaponUnlock" then
			local def = pendingId and Weapons.get(pendingId)
			if pendingId and def and not data.weapons[pendingId] and (def.unlockLevel or 1) > level then
				data.weapons[pendingId] = true
				grantedWeapon = pendingId
				outcome = "weapon"
			else
				data.tokens += 1
				outcome = "token"
			end
		elseif product.kind == "Tip" then
			local amount = if type(spent) == "number" and spent > 0 then spent else product.price
			data.supportTotal += math.floor(amount)
			data.supportTier = math.max(data.supportTier, product.tier or 1)
			outcome = "tip"
		end
		data.receipts[purchaseId] = os.time()
		pruneReceipts(data)
		return true
	end)
	if not ok then
		return false
	end
	if outcome ~= "dup" then
		if grantedWeapon then
			if profile.pendingUnlock and profile.pendingUnlock.weaponId == grantedWeapon then
				profile.pendingUnlock = nil
			end
			callService("ProgressionService", "PushUpdate", player)
		end
		thankYou(player, product, outcome, grantedWeapon)
	end
	return true
end

local function handleReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- granted when they rejoin
	end
	local product = Monetization.productById(receiptInfo.ProductId)
	if not product then
		warn(
			`[MonetizationService] receipt for unknown product id {receiptInfo.ProductId}; check Config/Monetization ids`
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local profile = profiles[player]
	if not profile or not waitLoaded(profile, LOAD_WAIT) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if profiles[player] ~= profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if grantProduct(profile, product, tostring(receiptInfo.PurchaseId), receiptInfo.CurrencySpent) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local ok, result = pcall(handleReceipt, receiptInfo)
	if ok then
		return result
	end
	warn(`[MonetizationService] ProcessReceipt error: {result}`)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

-- Studio-only simulated purchase for unconfigured products (STUDIO_TEST_GRANTS).
local function simulateProduct(profile: Profile, product: Monetization.Product)
	local fakeId = "studio-" .. HttpService:GenerateGUID(false)
	if not grantProduct(profile, product, fakeId, product.price) then
		notify(profile.player, "Simulated purchase failed (DataStore).", "warning")
	end
end

local function promptProduct(profile: Profile, product: Monetization.Product)
	if Monetization.isConfigured(product) then
		local ok, err = pcall(MarketplaceService.PromptProductPurchase, MarketplaceService, profile.player, product.id)
		if not ok then
			warn(`[MonetizationService] PromptProductPurchase failed: {err}`)
		end
	elseif studioTest() then
		task.spawn(simulateProduct, profile, product)
	end
end

---------------------------------------------------------------------------------------------------
-- Remote handlers
---------------------------------------------------------------------------------------------------

local function readyProfile(player: Player): Profile?
	local profile = profiles[player]
	if not profile or not profile.loaded then
		notify(player, "Store is still loading your data. Try again in a moment.", "warning")
		return nil
	end
	return profile
end

local function onPurchase(player: Player, payload: any)
	if not Net.rateLimit(player, "Shop_Purchase", 2) or type(payload) ~= "table" then
		return
	end
	local kind, key = payload.kind, payload.key
	if type(key) ~= "string" or #key > 32 then
		return
	end
	local profile = readyProfile(player)
	if not profile then
		return
	end
	if kind == "pass" then
		local pass = Monetization.getPass(key)
		if not pass or not available(pass) then
			return
		end
		if hasPass(profile, key) then
			notify(player, `You already own {pass.name}.`)
			return
		end
		local ok, err = pcall(MarketplaceService.PromptGamePassPurchase, MarketplaceService, player, pass.id)
		if not ok then
			warn(`[MonetizationService] PromptGamePassPurchase failed: {err}`)
		end
	elseif kind == "product" then
		local product = Monetization.getProduct(key)
		if not product or not available(product) then
			return
		end
		if product.kind == "Boost" then
			local remaining = math.max(0, profile.data.boostExpires - os.time())
			if remaining + (product.boostSeconds or 0) > Monetization.MAX_BOOST_SECONDS then
				notify(player, "Your XP Boost bank is full. Use some of it first.", "warning")
				return
			end
		elseif product.kind == "WeaponUnlock" then
			-- Bought from the product card without choosing a weapon: becomes an Unlock Token.
			profile.pendingUnlock = nil
		end
		promptProduct(profile, product)
	end
end

local function onRequestUnlock(player: Player, payload: any)
	if not Net.rateLimit(player, "Shop_RequestUnlock", 2) or type(payload) ~= "table" then
		return
	end
	local profile = readyProfile(player)
	if not profile then
		return
	end
	local weaponId = payload.weaponId
	local err = weaponUnlockError(player, profile, weaponId)
	if err then
		notify(player, err, "warning")
		return
	end
	if profile.data.tokens > 0 then
		local spent = false
		local ok = mutate(profile, function(data)
			spent = false
			if data.tokens <= 0 or data.weapons[weaponId] then
				return false
			end
			data.tokens -= 1
			data.weapons[weaponId] = true
			spent = true
			return true
		end)
		if ok and spent then
			callService("ProgressionService", "PushUpdate", player)
			local def = Weapons.get(weaponId)
			notify(player, `Unlock Token used: {def and def.name or weaponId} unlocked.`, "objective", 6)
			return
		elseif not ok then
			notify(player, "Could not use your Unlock Token right now. Try again.", "warning")
			return
		end
	end
	local product = Monetization.getProduct("WeaponUnlock")
	if not product or not available(product) then
		notify(player, "Weapon unlocks are not available.", "warning")
		return
	end
	profile.pendingUnlock = { weaponId = weaponId, at = os.clock() }
	publish(profile)
	promptProduct(profile, product)
end

local function onSetCosmetic(player: Player, payload: any)
	if not Net.rateLimit(player, "Shop_SetCosmetic", 2) or type(payload) ~= "table" then
		return
	end
	local profile = readyProfile(player)
	if not profile then
		return
	end
	local camoId, uniformId = payload.camo, payload.uniform
	if camoId ~= nil then
		local camo = if type(camoId) == "string" and #camoId <= 32 then Monetization.getCamo(camoId) else nil
		if not camo or not ownsCosmetic(profile, camo) then
			notify(player, "You don't own that camo.", "warning")
			return
		end
	end
	if uniformId ~= nil then
		local uniform = if type(uniformId) == "string" and #uniformId <= 32
			then Monetization.getUniform(uniformId)
			else nil
		if not uniform or not ownsCosmetic(profile, uniform) then
			notify(player, "You don't own that uniform.", "warning")
			return
		end
	end
	if camoId == nil and uniformId == nil then
		return
	end
	local ok = mutate(profile, function(data)
		local changed = false
		if camoId ~= nil and data.camo ~= camoId then
			data.camo = camoId
			changed = true
		end
		if uniformId ~= nil and data.uniform ~= uniformId then
			data.uniform = uniformId
			changed = true
		end
		return changed
	end)
	if not ok then
		notify(player, "Could not save your cosmetic choice. Try again.", "warning")
		return
	end
	-- Apply right away to the living character.
	local character = player.Character
	if character and player:GetAttribute("Alive") == true then
		if camoId ~= nil then
			local model = character:FindFirstChild("EquippedWeaponModel")
			if model then
				local selected = player:GetAttribute("Camo")
				pcall(Cosmetics.applyCamo, model, if type(selected) == "string" then selected else nil)
			end
		end
		if uniformId ~= nil then
			local faction = player:GetAttribute("Faction")
			local classId = player:GetAttribute("Class")
			callService("OutfitService", "Apply", character, faction or "", classId or "Rifleman")
		end
	end
end

local function onSavePreset(player: Player, payload: any)
	if not Net.rateLimit(player, "Shop_SavePreset", 3) or type(payload) ~= "table" then
		return
	end
	local profile = readyProfile(player)
	if not profile then
		return
	end
	local index = payload.index
	if type(index) ~= "number" or index ~= math.floor(index) or index < 1 or index > presetLimit(profile) then
		notify(player, "That preset slot is locked.", "warning")
		return
	end
	local preset: Preset? = nil
	if payload.classId ~= nil and payload.classId ~= "" then
		local raw = type(payload.loadout) == "table" and table.clone(payload.loadout) or {}
		raw.classId = payload.classId
		preset = sanitizePreset(raw)
		if not preset then
			return
		end
	end
	local slotKey = tostring(index)
	local ok = mutate(profile, function(data)
		data.presets[slotKey] = if preset then table.clone(preset) else nil
		return true
	end)
	if not ok then
		notify(player, "Could not save the preset. Try again.", "warning")
	end
end

---------------------------------------------------------------------------------------------------
-- Player lifecycle
---------------------------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if profiles[player] then
		return
	end
	local profile: Profile = {
		player = player,
		key = KEY_PREFIX .. tostring(player.UserId),
		data = defaultData(),
		loaded = false,
		failed = false,
		busy = false,
		passes = {},
		passCheckFailedAt = nil,
		pendingUnlock = nil,
		lastMultiplier = 1,
		boostWasActive = false,
	}
	profiles[player] = profile
	writeAttributes(profile)
	task.spawn(function()
		refreshPasses(profile)
		if profiles[player] == profile then
			publish(profile)
		end
	end)
	load(profile)
	if profiles[player] == profile then
		profile.boostWasActive = boostActive(profile)
		publish(profile)
		callService("ProgressionService", "PushUpdate", player)
	end
end

local function onPlayerRemoving(player: Player)
	profiles[player] = nil
end

---------------------------------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------------------------------

function MonetizationService.GetXPMultiplier(player: Player): number
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return 1
	end
	return multiplierFor(player, profiles[player])
end

function MonetizationService.HasPass(player: Player, key: string): boolean
	return hasPass(profiles[player], key)
end

function MonetizationService.IsWeaponPurchased(player: Player, weaponId: string): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.loaded and type(weaponId) == "string" and profile.data.weapons[weaponId] == true
end

function MonetizationService.GetPurchasedWeapons(player: Player): { [string]: boolean }
	local profile = profiles[player]
	if not profile or not profile.loaded then
		return {}
	end
	return table.clone(profile.data.weapons)
end

---------------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------------

function MonetizationService:Init()
	Net.func("Shop_GetState")
	Net.event("Shop_Purchase")
	Net.event("Shop_RequestUnlock")
	Net.event("Shop_SetCosmetic")
	Net.event("Shop_SavePreset")
	Net.event("Shop_Updated")
	Net.event("Notify")

	if game.PlaceId == 0 then
		enableMemoryMode("place is not published")
	else
		local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, Monetization.DATASTORE_NAME)
		if ok then
			store = result
		elseif RunService:IsStudio() then
			enableMemoryMode(tostring(result))
		else
			-- Live server: never fall back to an unpersisted store (grants would be acknowledged
			-- without being saved). With store = nil every write fails -> NotProcessedYet.
			warn(`[MonetizationService] GetDataStore failed: {result}; purchases will be retried later.`)
		end
	end

	-- The ONE ProcessReceipt handler for the whole game.
	MarketplaceService.ProcessReceipt = processReceipt
end

function MonetizationService:Start()
	Net.func("Shop_GetState").OnServerInvoke = function(player: Player)
		if not Net.rateLimit(player, "Shop_GetState", 4) then
			return nil
		end
		local profile = profiles[player]
		local deadline = os.clock() + 10
		while profile and not profile.loaded and not profile.failed and os.clock() < deadline and player.Parent do
			task.wait(0.25)
			profile = profiles[player]
		end
		return if profile then buildState(profile) else nil
	end
	Net.event("Shop_Purchase").OnServerEvent:Connect(onPurchase)
	Net.event("Shop_RequestUnlock").OnServerEvent:Connect(onRequestUnlock)
	Net.event("Shop_SetCosmetic").OnServerEvent:Connect(onSetCosmetic)
	Net.event("Shop_SavePreset").OnServerEvent:Connect(onSavePreset)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, passId: number, purchased: boolean)
			local pass = Monetization.passById(passId)
			local profile = profiles[player]
			if not pass or not profile then
				return
			end
			if purchased then
				profile.passes[pass.key] = true
				notify(player, `{pass.name} unlocked. Thank you for your support!`, "objective", 6)
				publish(profile)
			elseif not profile.passes[pass.key] then
				-- Cancelled / failed prompt: re-check in case it was bought elsewhere (website, other server).
				task.spawn(function()
					local owns = queryPass(player, pass)
					if owns and profiles[player] == profile then
						profile.passes[pass.key] = true
						publish(profile)
					end
				end)
			end
		end
	)

	Players.PlayerMembershipChanged:Connect(function(player: Player)
		local profile = profiles[player]
		if profile then
			publish(profile)
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	-- Boost expiry / multiplier changes / failed ownership re-checks.
	task.spawn(function()
		while true do
			task.wait(TICK_INTERVAL)
			for player, profile in profiles do
				local active = boostActive(profile)
				if profile.boostWasActive and not active then
					notify(player, "Your XP Boost has ended.", "info", 5)
				end
				profile.boostWasActive = active
				if multiplierFor(player, profile) ~= profile.lastMultiplier then
					publish(profile)
				end
				local failedAt = profile.passCheckFailedAt
				if failedAt and os.clock() - failedAt > OWNERSHIP_RECHECK then
					profile.passCheckFailedAt = nil
					task.spawn(function()
						refreshPasses(profile)
						if profiles[player] == profile then
							publish(profile)
						end
					end)
				end
			end
		end
	end)

	-- Every grant is persisted before it is acknowledged; on shutdown just let in-flight writes finish.
	game:BindToClose(function()
		local deadline = os.clock() + 25
		while inFlight > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return MonetizationService
