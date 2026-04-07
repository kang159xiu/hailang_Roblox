--!strict
-- ServerScriptService.Server
-- 入口脚本：初始化各个服务，并绑定 RemoteEvents

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPack = game:GetService("StarterPack")

-- =========
-- Remotes（若你没提前在 Studio 放 RemoteEvent，这里会自动创建，避免脚本 WaitForChild 卡死）
-- =========

local function ensureFolder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local newF = Instance.new("Folder")
	newF.Name = name
	newF.Parent = parent
	return newF
end

local function ensureRemoteEvent(folder: Folder, name: string): RemoteEvent
	local ev = folder:FindFirstChild(name)
	if ev and ev:IsA("RemoteEvent") then
		return ev
	end
	local newEv = Instance.new("RemoteEvent")
	newEv.Name = name
	newEv.Parent = folder
	return newEv
end

local remotesFolder = ensureFolder(ReplicatedStorage, "Remotes")
local damageRemote = ensureRemoteEvent(remotesFolder, "RequestDamageMonster")
ensureRemoteEvent(remotesFolder, "RequestUseWeaponSkill")
ensureRemoteEvent(remotesFolder, "RequestPurchaseWeapon")
ensureRemoteEvent(remotesFolder, "RequestEquipWeapon")
ensureRemoteEvent(remotesFolder, "RequestPurchaseUpgrade")
ensureRemoteEvent(remotesFolder, "OpenWeaponShopUI")
ensureRemoteEvent(remotesFolder, "OpenUpgradeShopUI")
ensureRemoteEvent(remotesFolder, "PushClientToast")

-- 怪物背包（自定义 UI）同步与交互
ensureRemoteEvent(remotesFolder, "SyncMonsterInventory")
ensureRemoteEvent(remotesFolder, "RequestTakeOutMonsterItem")

-- 测试：清空玩家数据
ensureRemoteEvent(remotesFolder, "RequestClearPlayerData")

-- 确保 StarterPack.Weapon 有 Handle（Tool.RequiresHandle=true 时必须）
local function ensureWeaponToolHasHandle()
	local weapon = StarterPack:FindFirstChild("Weapon")
	if not weapon or not weapon:IsA("Tool") then
		return
	end

	local handle = weapon:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		handle = Instance.new("Part")
		handle.Name = "Handle"
		handle.Size = Vector3.new(1, 1, 1)
		handle.Transparency = 0 -- 兜底可见，避免外观生成失败时“手里空空如也”
		handle.CanCollide = false
		handle.Massless = true
		handle.Parent = weapon
	end

	weapon:SetAttribute("IsWeaponTool", true)
	weapon:SetAttribute("WeaponLevel", 1)

	weapon.CanBeDropped = false
	weapon.RequiresHandle = true
end
ensureWeaponToolHasHandle()

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local takeOutRemote = remotes:WaitForChild("RequestTakeOutMonsterItem") :: RemoteEvent
local clearDataRemote = remotes:WaitForChild("RequestClearPlayerData") :: RemoteEvent
local DataPersistenceService = require(script.Parent:WaitForChild("Modules"):WaitForChild("DataPersistenceService"))
local AppearanceBootstrapService = require(script.Parent:WaitForChild("Modules"):WaitForChild("AppearanceBootstrapService"))

local CharacterService = require(script.Parent:WaitForChild("Modules"):WaitForChild("CharacterService"))
local InventoryService = require(script.Parent:WaitForChild("Modules"):WaitForChild("InventoryService"))
local HomeService = require(script.Parent:WaitForChild("Modules"):WaitForChild("HomeService"))
local PlacementService = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlacementService"))
local MonsterService = require(script.Parent:WaitForChild("Modules"):WaitForChild("MonsterService"))
local LavaService = require(script.Parent:WaitForChild("Modules"):WaitForChild("LavaService"))
local MerchantService = require(script.Parent:WaitForChild("Modules"):WaitForChild("MerchantService"))
local WeaponToolService = require(script.Parent:WaitForChild("Modules"):WaitForChild("WeaponToolService"))
local WeaponAppearanceService = require(script.Parent:WaitForChild("Modules"):WaitForChild("WeaponAppearanceService"))
local WeaponService = require(script.Parent:WaitForChild("Modules"):WaitForChild("WeaponService"))

AppearanceBootstrapService.Init()
WeaponToolService.Init()
WeaponAppearanceService.Init()

-- MUST init persistence before HOME/Placement to ensure loaded data is applied first
DataPersistenceService.Init()

CharacterService.Init()
InventoryService.Init()
HomeService.Init()
PlacementService.Init()
MonsterService.Init()
LavaService.Init()
MerchantService.Init()
WeaponService.Init()

-- 客户端背包 UI：拿出一只怪到 Tool 栏

takeOutRemote.OnServerEvent:Connect(function(player: Player, itemId: any)
	if type(itemId) ~= "string" then
		return
	end
	InventoryService.TakeOutToTool(player, itemId)
end)

-- 测试：清空玩家数据（仅 Studio）
clearDataRemote.OnServerEvent:Connect(function(player: Player)
	DataPersistenceService.ClearPlayerData(player)
end)

-- 普通攻击：客户端请求对某个怪造成一次伤害
-- 注意：服务端会做距离与对象合法性校验

damageRemote.OnServerEvent:Connect(function(player: Player, monsterPart: Instance)
	MonsterService.DamageMonster(player, monsterPart)
end)

print("[Game] Server initialized")
