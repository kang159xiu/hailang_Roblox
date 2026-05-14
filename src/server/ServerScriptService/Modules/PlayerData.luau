--!strict
-- ServerScriptService.Modules.PlayerData

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))
local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))

export type PlayerStats = {
	Gold: number,
	RebirthCount: number,
	SpeedLevel: number,
	AttackLevel: number,
	-- 兼容旧存档键：HealthLevel 现在代表“跳跃升级等级”，不再提升玩家血量。
	HealthLevel: number,

	-- 携带怪升级：每级 +1 最大携带数量（默认 1，最多 5）
	CarryLevel: number,

	-- 家园等级：1~3（对应 1级房屋 / 2级房屋 / 3级房屋）
	HomeLevel: number,

	-- WeaponLevel：已拥有的最高武器等级（用于商店解锁/显示）
	WeaponLevel: number,
	-- EquippedWeaponLevel：当前装备的武器等级（用于伤害/技能/外观）
	EquippedWeaponLevel: number,
	-- OwnedWeaponLevels：拥有的武器列表（用于生成多个 Tool 图标）
	OwnedWeaponLevels: {number},
}

export type PersistedPlayerData = {
	Gold: number,
	RebirthCount: number?,
	SpeedLevel: number,
	AttackLevel: number,
	HealthLevel: number,
	CarryLevel: number,
	HomeLevel: number,
	WeaponLevel: number,
	EquippedWeaponLevel: number,
	OwnedWeaponLevels: {number},
}

local PlayerData = {}

local data: {[number]: PlayerStats} = {}

local function hasOwnedLevel(list: {number}, level: number): boolean
	for _, v in ipairs(list) do
		if v == level then
			return true
		end
	end
	return false
end

local function getOrCreate(player: Player): PlayerStats
	local stats = data[player.UserId]
	if stats then
		return stats
	end
	stats = {
		Gold = (type(Config.PLAYER_START_GOLD) == "number" and math.floor(Config.PLAYER_START_GOLD) or 0),
		RebirthCount = 0,
		SpeedLevel = 0,
		AttackLevel = 0,
		HealthLevel = 0,
		CarryLevel = 0,

		HomeLevel = 1,

		WeaponLevel = 1, -- 已拥有最高武器等级
		EquippedWeaponLevel = 1, -- 当前装备
		OwnedWeaponLevels = { 1 },
	}
	data[player.UserId] = stats
	return stats
end

local function resetRebirthUpgradeableStats(stats: PlayerStats)
	-- 重生后把战斗/移动成长重置为基础数值。
	-- HealthLevel 是旧存档键，现在语义代表“跳跃升级等级”。
	stats.SpeedLevel = 0
	stats.AttackLevel = 0
	stats.HealthLevel = 0
end

function PlayerData.Get(player: Player): PlayerStats
	return getOrCreate(player)
end

function PlayerData.AddGold(player: Player, amount: number): number
	local stats = getOrCreate(player)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return 0
	end

	local rebirthCount = math.max(0, math.floor(tonumber(stats.RebirthCount) or 0))
	stats.RebirthCount = rebirthCount

	local multiplier = math.max(1, math.floor(tonumber(Config.GetRebirthCashMultiplier(rebirthCount)) or 1))
	local beforeGold = stats.Gold
	local added = math.floor(amount * multiplier)
	stats.Gold += added

	warn(string.format(
		"[RebirthGoldDebug] source=PlayerData.AddGold player=%s base=%d rebirth=%d multiplier=x%d added=%d gold=%d->%d",
		player.Name,
		amount,
		rebirthCount,
		multiplier,
		added,
		beforeGold,
		stats.Gold
	))

	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
	return added
end

function PlayerData.AddRawGold(player: Player, amount: number): number
	local stats = getOrCreate(player)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then
		return 0
	end

	stats.Gold += amount
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
	return amount
end

function PlayerData.GetRebirthCost(player: Player): number
	local stats = getOrCreate(player)
	return Config.GetRebirthCost(stats.RebirthCount)
end

function PlayerData.GetRebirthMultiplier(player: Player): number
	local stats = getOrCreate(player)
	return Config.GetRebirthCashMultiplier(stats.RebirthCount)
end

function PlayerData.PerformGoldRebirth(player: Player): boolean
	local stats = getOrCreate(player)
	stats.RebirthCount = math.max(0, math.floor(tonumber(stats.RebirthCount) or 0))
	local cost = Config.GetRebirthCost(stats.RebirthCount)
	if stats.Gold < cost then
		return false
	end

	stats.Gold -= cost
	stats.RebirthCount += 1
	resetRebirthUpgradeableStats(stats)
	local multiplier = math.max(1, math.floor(tonumber(Config.GetRebirthCashMultiplier(stats.RebirthCount)) or 1))
	local nextCost = Config.GetRebirthCost(stats.RebirthCount)
	warn(string.format(
		"[RebirthDebug] GoldRebirth player=%s rebirth=%d multiplier=x%d nextCost=%d gold=%d",
		player.Name,
		stats.RebirthCount,
		multiplier,
		nextCost,
		stats.Gold
	))
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player, 5)
	return true
end

function PlayerData.PerformRobuxRebirth(player: Player): boolean
	local stats = getOrCreate(player)
	stats.RebirthCount = math.max(0, math.floor(tonumber(stats.RebirthCount) or 0))
	stats.RebirthCount += 1
	resetRebirthUpgradeableStats(stats)
	local multiplier = math.max(1, math.floor(tonumber(Config.GetRebirthCashMultiplier(stats.RebirthCount)) or 1))
	local nextCost = Config.GetRebirthCost(stats.RebirthCount)
	warn(string.format(
		"[RebirthDebug] RobuxRebirth player=%s rebirth=%d multiplier=x%d nextCost=%d gold=%d",
		player.Name,
		stats.RebirthCount,
		multiplier,
		nextCost,
		stats.Gold
	))
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player, 5)
	return true
end

function PlayerData.SetGold(player: Player, amount: number)
	local stats = getOrCreate(player)
	amount = math.floor(amount)
	if amount < 0 then
		amount = 0
	end
	stats.Gold = amount
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
end

function PlayerData.TrySpendGold(player: Player, amount: number): boolean
	local stats = getOrCreate(player)
	if stats.Gold < amount then
		return false
	end
	stats.Gold -= amount
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
	return true
end

function PlayerData.GetHomeLevel(player: Player): number
	local stats = getOrCreate(player)
	local lvl = stats.HomeLevel
	if type(lvl) ~= "number" then
		lvl = 1
	end
	lvl = math.floor(lvl)
	if lvl < 1 then lvl = 1 end
	if lvl > 3 then lvl = 3 end
	return lvl
end

function PlayerData.SetHomeLevel(player: Player, homeLevel: number)
	local stats = getOrCreate(player)
	homeLevel = math.floor(homeLevel)
	if homeLevel < 1 then
		homeLevel = 1
	elseif homeLevel > 3 then
		homeLevel = 3
	end
	stats.HomeLevel = homeLevel
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
end

function PlayerData.AddOwnedWeaponLevel(player: Player, weaponLevel: number)
	local stats = getOrCreate(player)
	weaponLevel = math.floor(weaponLevel)
	if weaponLevel < 1 then
		weaponLevel = 1
	end

	if not hasOwnedLevel(stats.OwnedWeaponLevels, weaponLevel) then
		table.insert(stats.OwnedWeaponLevels, weaponLevel)
		table.sort(stats.OwnedWeaponLevels)
	end

	if weaponLevel > stats.WeaponLevel then
		stats.WeaponLevel = weaponLevel
	end

	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
end

-- WeaponLevel：已拥有最高等级（商店进度）
function PlayerData.SetWeaponLevel(player: Player, weaponLevel: number)
	local stats = getOrCreate(player)
	stats.WeaponLevel = weaponLevel
	if weaponLevel > stats.EquippedWeaponLevel then
		-- 默认：新最高武器也同步为当前装备（保持老版本行为）
		stats.EquippedWeaponLevel = weaponLevel
	end
	PlayerData.AddOwnedWeaponLevel(player, weaponLevel)
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
end

function PlayerData.SetEquippedWeaponLevel(player: Player, weaponLevel: number)
	local stats = getOrCreate(player)
	weaponLevel = math.floor(weaponLevel)
	if weaponLevel < 1 then
		weaponLevel = 1
	end

	-- 只能装备已拥有的武器（防止客户端作弊）
	if not hasOwnedLevel(stats.OwnedWeaponLevels, weaponLevel) then
		return
	end

	stats.EquippedWeaponLevel = weaponLevel
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
end

function PlayerData.AddSpeedLevel(player: Player, amount: number)
	local stats = getOrCreate(player)
	stats.SpeedLevel += amount
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
end

function PlayerData.AddAttackLevel(player: Player, amount: number)
	local stats = getOrCreate(player)
	stats.AttackLevel += amount
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
end

function PlayerData.AddHealthLevel(player: Player, amount: number)
	local stats = getOrCreate(player)
	stats.HealthLevel += amount
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
end

-- 语义别名：底层仍写入 HealthLevel，保证旧存档和旧客户端类型兼容。
function PlayerData.AddJumpLevel(player: Player, amount: number)
	PlayerData.AddHealthLevel(player, amount)
end

function PlayerData.AddCarryLevel(player: Player, amount: number)
	local stats = getOrCreate(player)
	stats.CarryLevel += amount
	if stats.CarryLevel < 0 then
		stats.CarryLevel = 0
	end
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player)
end

-- leaderstats（左上角金币显示我们会用 UI；leaderstats 也保留，方便调试）
local function setupLeaderstats(player: Player)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	folder.Parent = player

	local gold = Instance.new("IntValue")
	gold.Name = "Gold"
	gold.Value = getOrCreate(player).Gold
	gold.Parent = folder
end

local function syncLeaderstatsAndAttributes(player: Player)
	local stats = getOrCreate(player)

	local ls = player:FindFirstChild("leaderstats")
	if ls then
		local gold = ls:FindFirstChild("Gold")
		if gold and gold:IsA("IntValue") then
			gold.Value = stats.Gold
		end
	end

	player:SetAttribute("Gold", stats.Gold)
	player:SetAttribute("RebirthCount", stats.RebirthCount)
	player:SetAttribute("RebirthMultiplier", Config.GetRebirthCashMultiplier(stats.RebirthCount))
	player:SetAttribute("NextRebirthCost", Config.GetRebirthCost(stats.RebirthCount))
	player:SetAttribute("SpeedLevel", stats.SpeedLevel)
	player:SetAttribute("AttackLevel", stats.AttackLevel)
	player:SetAttribute("HealthLevel", stats.HealthLevel)
	player:SetAttribute("CarryLevel", stats.CarryLevel)
	player:SetAttribute("HomeLevel", stats.HomeLevel)
	player:SetAttribute("WeaponLevel", stats.WeaponLevel)
	player:SetAttribute("EquippedWeaponLevel", stats.EquippedWeaponLevel)
end

Players.PlayerAdded:Connect(function(player)
	getOrCreate(player)
	setupLeaderstats(player)
	syncLeaderstatsAndAttributes(player)
end)

-- IMPORTANT:
-- Do not clear cached data on PlayerRemoving.
-- DataPersistenceService needs access to the latest in-memory state during PlayerRemoving.
function PlayerData.Cleanup(player: Player)
	data[player.UserId] = nil
end

function PlayerData.Sync(player: Player)
	syncLeaderstatsAndAttributes(player)
end

function PlayerData.Export(player: Player): PersistedPlayerData
	local stats = getOrCreate(player)
	return {
		Gold = math.floor(stats.Gold),
		RebirthCount = math.floor(stats.RebirthCount),
		SpeedLevel = math.floor(stats.SpeedLevel),
		AttackLevel = math.floor(stats.AttackLevel),
		HealthLevel = math.floor(stats.HealthLevel),
		CarryLevel = math.floor(stats.CarryLevel),
		HomeLevel = math.floor(stats.HomeLevel),
		WeaponLevel = math.floor(stats.WeaponLevel),
		EquippedWeaponLevel = math.floor(stats.EquippedWeaponLevel),
		OwnedWeaponLevels = table.clone(stats.OwnedWeaponLevels),
	}
end

local function normalizeOwnedWeaponLevels(listAny: any): {number}
	local out: {number} = {}
	if type(listAny) == "table" then
		for _, v in ipairs(listAny) do
			local n = tonumber(v)
			if n then
				n = math.max(1, math.floor(n))
				if table.find(out, n) == nil then
					table.insert(out, n)
				end
			end
		end
	end
	if #out == 0 then
		out = { 1 }
	end
	table.sort(out)
	return out
end

function PlayerData.ApplyLoaded(player: Player, loaded: PersistedPlayerData)
	local stats = getOrCreate(player)

	stats.Gold = math.max(0, math.floor(tonumber(loaded.Gold) or stats.Gold))
	stats.RebirthCount = math.max(0, math.floor(tonumber((loaded :: any).RebirthCount) or stats.RebirthCount))
	stats.SpeedLevel = math.max(0, math.floor(tonumber(loaded.SpeedLevel) or stats.SpeedLevel))
	stats.AttackLevel = math.max(0, math.floor(tonumber(loaded.AttackLevel) or stats.AttackLevel))
	stats.HealthLevel = math.max(0, math.floor(tonumber(loaded.HealthLevel) or stats.HealthLevel))
	stats.CarryLevel = math.max(0, math.floor(tonumber((loaded :: any).CarryLevel) or stats.CarryLevel))

	local hl = math.floor(tonumber(loaded.HomeLevel) or stats.HomeLevel)
	stats.HomeLevel = math.clamp(hl, 1, 3)

	stats.OwnedWeaponLevels = normalizeOwnedWeaponLevels(loaded.OwnedWeaponLevels)
	stats.WeaponLevel = math.max(1, math.floor(tonumber(loaded.WeaponLevel) or stats.OwnedWeaponLevels[#stats.OwnedWeaponLevels]))

	local eq = math.max(1, math.floor(tonumber(loaded.EquippedWeaponLevel) or stats.WeaponLevel))
	if table.find(stats.OwnedWeaponLevels, eq) == nil then
		eq = stats.OwnedWeaponLevels[#stats.OwnedWeaponLevels]
	end
	stats.EquippedWeaponLevel = eq

	-- Ensure WeaponLevel is at least max owned
	stats.WeaponLevel = math.max(stats.WeaponLevel, stats.OwnedWeaponLevels[#stats.OwnedWeaponLevels])

	PlayerData.Sync(player)
end

-- 强制重置玩家所有基础属性为 0 或 1 级
function PlayerData.ResetData(player: Player)
	local stats = data[player.UserId]
	if not stats then return end
	
	stats.Gold = 10
	stats.RebirthCount = 0
	stats.SpeedLevel = 0
	stats.AttackLevel = 0
	stats.HealthLevel = 0
	stats.CarryLevel = 0
	stats.HomeLevel = 1
	stats.WeaponLevel = 1
	stats.EquippedWeaponLevel = 1
	stats.OwnedWeaponLevels = { 1 }
	
	PlayerData.Sync(player)
	local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))
	DataDirtyService.MarkDirty(player)
end


return PlayerData
