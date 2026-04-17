--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ProfileService = require(script.Parent:WaitForChild("ProfileService"))
local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local PlacementService = require(script.Parent:WaitForChild("PlacementService"))
local CharacterService = require(script.Parent:WaitForChild("CharacterService"))
local WeaponToolService = require(script.Parent:WaitForChild("WeaponToolService"))

local DataPersistenceService = {}

local DATASTORE_NAME = "PlayerProfiles_V1"

export type PersistedPlacedMonster = {
	MonsterLevel: number,
	Value: number,
	GoldPerSec: number,
	UnclaimedGold: number,
	LastTickUnix: number,
	-- [修改内容] 新增怪物强化升级相关的存档数据结构声明
	UpgradeLevel: number?,
	BaseValue: number?,
	BaseGoldPerSec: number?,
}

export type PersistedSlot = {
	Unlocked: boolean,
	Placed: PersistedPlacedMonster?,
}

export type PersistedInventoryMonsterItem = {
	ItemId: string,
	MonsterLevel: number,
	Value: number,
	GoldPerSec: number,
}

export type PersistedPlayerData = {
	Gold: number,
	SpeedLevel: number,
	AttackLevel: number,
	HealthLevel: number,
	CarryLevel: number,
	HomeLevel: number,
	WeaponLevel: number,
	EquippedWeaponLevel: number,
	OwnedWeaponLevels: {number},
}

export type PersistedProfileData = {
	PlayerData: PersistedPlayerData,
	Inventory: {
		MonsterItems: {PersistedInventoryMonsterItem},
	},
	Placement: {
		Slots: {PersistedSlot},
	},
}

local PROFILE_TEMPLATE: PersistedProfileData = {
	PlayerData = {
		Gold = 0,
		SpeedLevel = 0,
		AttackLevel = 0,
		HealthLevel = 0,
		CarryLevel = 0,
		HomeLevel = 1,
		WeaponLevel = 1,
		EquippedWeaponLevel = 1,
		OwnedWeaponLevels = { 1 },
	},
	Inventory = {
		MonsterItems = {},
	},
	Placement = {
		Slots = (function()
			local slots: {PersistedSlot} = {}
			for i = 1, 30 do
				slots[i] = {
					Unlocked = (i == 1),
					Placed = nil,
				}
			end
			return slots
		end)(),
	},
}

local function deepCopy<T>(t: T): T
	if type(t) ~= "table" then
		return t
	end
	local out: any = {}
	for k, v in pairs(t :: any) do
		out[k] = deepCopy(v)
	end
	return out
end

local profileStore = ProfileService.GetProfileStore(DATASTORE_NAME, PROFILE_TEMPLATE)

local profilesByUserId: {[number]: any?} = {}
local isDirtyByUserId: {[number]: boolean?} = {}
local nextSaveAtByUserId: {[number]: number?} = {}
local lastSavedAtByUserId: {[number]: number?} = {}

-- 为了缩短玩家退出时的“卡顿感”，我们把清理逻辑延后到 Profile 真正 Release 完成后再做。
-- PlayerRemoving 里只负责写回 + 发起 Release，不在同一帧里做大量清理。
local pendingCleanupByUserId: {[number]: boolean?} = {}

local function getProfileKey(userId: number): string
	-- Requirement: key uses UserId
	return tostring(userId)
end

local function writeBack(player: Player, profile: any)
	-- Update profile.Data from current in-memory services
	local data = profile.Data :: any
	data.PlayerData = PlayerData.Export(player)
	data.Inventory = {
		MonsterItems = InventoryService.Export(player),
	}
	data.Placement = {
		Slots = PlacementService.Export(player),
	}
end

local function saveNowForUserId(userId: number)
	local profile = profilesByUserId[userId]
	if not profile then
		return
	end

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end

	writeBack(player, profile)
	profile:Save()
	lastSavedAtByUserId[userId] = os.clock()
	isDirtyByUserId[userId] = false
	nextSaveAtByUserId[userId] = nil
end

local function markDirty(userId: number, saveSoonSeconds: number?)
	isDirtyByUserId[userId] = true

	-- Trailing debounce: after the *last* important operation
	if saveSoonSeconds ~= nil then
		local target = os.clock() + saveSoonSeconds
		local cur = nextSaveAtByUserId[userId]
		if cur == nil or target > cur then
			nextSaveAtByUserId[userId] = target
		end
	end
end

local function applyLoadedData(player: Player, data: PersistedProfileData)
	-- 1) PlayerData (gold/levels/weapon list)
	PlayerData.ApplyLoaded(player, data.PlayerData)

	-- 2) Inventory (monster items)
	InventoryService.ApplyLoaded(player, data.Inventory.MonsterItems)

	-- 3) Placement (unlocks + placed monsters + offline production)
	PlacementService.ApplyLoaded(player, data.Placement.Slots)

	-- 4) Rebuild weapon tools (depends on PlayerData)
	WeaponToolService.Sync(player, true)

	-- Ensure current level stats are applied to character, and join starts with full health
	CharacterService.Refresh(player, true)
end

local function onPlayerAdded(player: Player)
	task.spawn(function()
		local key = getProfileKey(player.UserId)
		local profile = profileStore:LoadProfileAsync(key, "ForceLoad")
		if not profile then
			player:Kick("数据加载失败，请重试")
			return
		end

		profile:AddUserId(player.UserId)
		profile:Reconcile()

		profile:ListenToRelease(function()
			profilesByUserId[player.UserId] = nil
			isDirtyByUserId[player.UserId] = nil
			nextSaveAtByUserId[player.UserId] = nil
			lastSavedAtByUserId[player.UserId] = nil

			-- 释放完成后清理缓存（玩家离开时执行；或异常 ForceLoad/Kick 时也执行）
			if pendingCleanupByUserId[player.UserId] == true or player.Parent == nil then
				pendingCleanupByUserId[player.UserId] = nil
				PlayerData.Cleanup(player)
				InventoryService.Cleanup(player)
				PlacementService.Cleanup(player)
			end

			if player.Parent then
				player:Kick("数据在其它服务器被加载，请重进")
			end
		end)

		profilesByUserId[player.UserId] = profile
		lastSavedAtByUserId[player.UserId] = os.clock()

		local data = profile.Data :: any
		applyLoadedData(player, data)

		player:SetAttribute("__DataLoaded", true)
	end)
end

local function onPlayerRemoving(player: Player)
	local profile = profilesByUserId[player.UserId]
	if not profile then
		return
	end

	-- 标记：让清理工作在 Release 完成后进行（避免 PlayerRemoving 阶段等待存档）
	pendingCleanupByUserId[player.UserId] = true

	-- 退出时不再参与 dirty loop
	isDirtyByUserId[player.UserId] = false
	nextSaveAtByUserId[player.UserId] = nil

	-- Force save current state before releasing (HomeService / others may destroy instances after this)
	writeBack(player, profile)

	-- Release triggers a saving UpdateAsync in ProfileService
	local prof = profile :: any

	-- 立即从活跃表移除，进一步减少退出阶段的额外工作
	profilesByUserId[player.UserId] = nil
	lastSavedAtByUserId[player.UserId] = nil

	task.spawn(function()
		local ok, err = pcall(function()
			prof:Release()
		end)
		if not ok then
			warn("[DataPersistenceService] Release failed:", err)
		end
	end)

	-- 注意：这里不立刻 Cleanup 各服务缓存，等待 ListenToRelease 里执行。
end

function DataPersistenceService.Init()
	DataDirtyService.Bind(function(userId: number, saveSoonSeconds: number?)
		markDirty(userId, saveSoonSeconds)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, p in ipairs(Players:GetPlayers()) do
		onPlayerAdded(p)
	end

	-- Dirty flush loop
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			for userId, profile in pairs(profilesByUserId) do
				if profile and profile:IsActive() then
					local dirty = isDirtyByUserId[userId] == true
					if dirty then
						local last = lastSavedAtByUserId[userId] or 0
						local duePeriodic = (now - last) >= 30
						local dueSoon = (nextSaveAtByUserId[userId] ~= nil and now >= (nextSaveAtByUserId[userId] :: number))
						if duePeriodic or dueSoon then
							saveNowForUserId(userId)
						end
					end
				end
			end
		end
	end)
end

function DataPersistenceService.ClearPlayerData(player: Player)
	-- For testing only
	if RunService:IsStudio() == false then
		return
	end

	local profile = profilesByUserId[player.UserId]
	if not profile then
		return
	end

	-- Reset profile data to template
	profile.Data = deepCopy(PROFILE_TEMPLATE)
	applyLoadedData(player, profile.Data)
	player:SetAttribute("__DataLoaded", true)

	-- Save immediately so next join starts clean
	local ok, err = pcall(function()
		profile:Save()
	end)
	if not ok then
		warn("[DataPersistenceService] ClearPlayerData save failed:", err)
	end
end

function DataPersistenceService.GetProfile(player: Player): any?
	return profilesByUserId[player.UserId]
end

return DataPersistenceService

