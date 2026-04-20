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
local promptInteractionRemote = ensureRemoteEvent(remotesFolder, "RequestPromptInteraction")
ensureRemoteEvent(remotesFolder, "PlayWeaponHitVFX")
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
-- [修改内容] 自动创建清空数据事件
local clearDataRemote = remotes:FindFirstChild("RequestClearPlayerData")
if not clearDataRemote then
	clearDataRemote = Instance.new("RemoteEvent")
	clearDataRemote.Name = "RequestClearPlayerData"
	clearDataRemote.Parent = remotes
end
local requestPromptInteractionRemote = remotes:WaitForChild("RequestPromptInteraction") :: RemoteEvent
-- [修改内容] 引用装备武器事件
local requestEquipWeaponRemote = remotes:WaitForChild("RequestEquipWeapon") :: RemoteEvent

local function debugPromptPath(instance: Instance?): string
	if not instance then
		return "nil"
	end

	local ok, fullName = pcall(function()
		return instance:GetFullName()
	end)
	return ok and fullName or instance.Name
end

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
--引入新的守护者系统模块
local GuardianService = require(script.Parent:WaitForChild("Modules"):WaitForChild("GuardianService"))

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
--  启动守护者系统的全局初始化（生成待机的守护者并开启追踪循环）
GuardianService.Init()





-- [修改内容] 客户端背包 UI：请求装备武器
local PlayerData = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerData"))
requestEquipWeaponRemote.OnServerEvent:Connect(function(player: Player, weaponLevel: any)
	if type(weaponLevel) ~= "number" then
		return
	end
	-- 1. 更新玩家数据属性（这会自动触发客户端 UI 的 GetAttributeChangedSignal，使按钮变成“已装备”）
	PlayerData.SetEquippedWeaponLevel(player, weaponLevel)
	-- 2. 强制同步玩家背包里的 Tool，并让玩家把新武器拿在手上
	WeaponToolService.Sync(player, true)
end)

-- 客户端背包 UI：拿出一只怪到 Tool 栏

takeOutRemote.OnServerEvent:Connect(function(player: Player, itemId: any)
	if type(itemId) ~= "string" then
		return
	end
	InventoryService.TakeOutToTool(player, itemId)
end)

-- 测试：清空玩家数据（仅 Studio）
-- [修改内容] 处理玩家清空数据的请求（终极防崩溃版）
clearDataRemote.OnServerEvent:Connect(function(player: Player)
	warn(string.format("玩家 %s 正在执行删档清空...", player.Name))
	
	-- 1. 重置金币和等级（带防错检测）
	if PlayerData.ResetData then PlayerData.ResetData(player) end
	
	-- 2. 清理放置在房子里的怪物
	local PlacementService = require(script.Parent.Modules.PlacementService)
	if PlacementService.Clear then PlacementService.Clear(player) end
	
	-- 3. 清理背包里的所有东西
	local InventoryService = require(script.Parent.Modules.InventoryService)
	if InventoryService.Clear then InventoryService.Clear(player) end
	
	-- 4. 强制标记大保存
	local DataDirtyService = require(script.Parent.Modules.DataDirtyService)
	DataDirtyService.MarkDirty(player)
	
	-- 5. 必须踢出玩家！只有踢出才能阻断旧金币增加，并瞬间将空数据写入云端
	player:Kick("\n数据已成功清空！\n请重新进入游戏，开始新旅程。")
end)

-- 普通攻击：客户端请求对某个怪造成一次伤害
-- 注意：服务端会做距离与对象合法性校验

damageRemote.OnServerEvent:Connect(function(player: Player, monsterPart: Instance)
	MonsterService.DamageMonster(player, monsterPart)
end)

requestPromptInteractionRemote.OnServerEvent:Connect(function(player: Player, promptInstance: Instance)
	print(string.format(
		"[PromptDebug][Server] OnServerEvent player=%s prompt=%s class=%s parent=%s",
		player.Name,
		debugPromptPath(promptInstance),
		promptInstance and promptInstance.ClassName or "nil",
		promptInstance and debugPromptPath(promptInstance.Parent) or "nil"
	))

	if PlacementService.TryHandlePromptInteraction(player, promptInstance) then
		print(string.format(
			"[PromptDebug][Server] handled_by=PlacementService player=%s prompt=%s",
			player.Name,
			debugPromptPath(promptInstance)
		))
		return
	end

	if MonsterService.TryHandlePromptInteraction(player, promptInstance) then
		print(string.format(
			"[PromptDebug][Server] handled_by=MonsterService player=%s prompt=%s",
			player.Name,
			debugPromptPath(promptInstance)
		))
		return
	end

	print(string.format(
		"[PromptDebug][Server] rejected_by_all player=%s prompt=%s",
		player.Name,
		debugPromptPath(promptInstance)
	))
end)

print("[Game] Server initialized")
