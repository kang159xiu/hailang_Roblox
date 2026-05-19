--!strict
-- ServerScriptService.Server
-- 入口脚本：初始化各个服务，并绑定 RemoteEvents

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPack = game:GetService("StarterPack")
local Players = game:GetService("Players")

-- =========
-- Remotes（若你没提前在 Studio 放 RemoteEvent，这里会自动创建，避免脚本 WaitForChild 卡死）
-- =========

local function ensureFolder(parent: Instance, name: string): Folder
	-- 如果没这个 文件夹，就在这里用代码“自动新建”一个！
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
	-- 如果没这个 RemoteEvent，就在这里用代码“自动新建”一个！
	local ev = folder:FindFirstChild(name)
	if ev and ev:IsA("RemoteEvent") then
		return ev
	end
	-- 如果找不到，就在这里用代码“自动新建”一个！
	local newEv = Instance.new("RemoteEvent")
	newEv.Name = name
	newEv.Parent = folder
	return newEv

end

local remotesFolder = ensureFolder(ReplicatedStorage, "Remotes")
local damageRemote = ensureRemoteEvent(remotesFolder, "RequestDamageMonster")
local promptInteractionRemote = ensureRemoteEvent(remotesFolder, "RequestPromptInteraction")
ensureRemoteEvent(remotesFolder, "PlayWeaponHitVFX")
ensureRemoteEvent(remotesFolder, "PlayPlayerKnockback")
ensureRemoteEvent(remotesFolder, "ShowDamageNumber")
ensureRemoteEvent(remotesFolder, "RequestUseWeaponSkill")
ensureRemoteEvent(remotesFolder, "RequestPurchaseWeapon")
ensureRemoteEvent(remotesFolder, "RequestEquipWeapon")
ensureRemoteEvent(remotesFolder, "RequestPurchaseUpgrade")
ensureRemoteEvent(remotesFolder, "OpenWeaponShopUI")
ensureRemoteEvent(remotesFolder, "OpenUpgradeShopUI")
ensureRemoteEvent(remotesFolder, "PushClientToast")
ensureRemoteEvent(remotesFolder, "SetHomeGlowLocalColor")
ensureRemoteEvent(remotesFolder, "PlayPlacedMonsterJump")
ensureRemoteEvent(remotesFolder, "RequestRebirth")
ensureRemoteEvent(remotesFolder, "RequestStealPlacedGold")
ensureRemoteEvent(remotesFolder, "RequestUpgradePlacedMonster")
ensureRemoteEvent(remotesFolder, "StealGoldAvailability")
ensureRemoteEvent(remotesFolder, "StealGoldOwnerWarning")
ensureRemoteEvent(remotesFolder, "StealGoldResult")
-- [修改原因] 使用统一的 ensureRemoteEvent 函数自动注册客户端到服务端的埋点通讯通道
ensureRemoteEvent(remotesFolder, "Analytics_Remote")

-- 怪物背包（自定义 UI）同步与交互
ensureRemoteEvent(remotesFolder, "SyncMonsterInventory")
ensureRemoteEvent(remotesFolder, "RequestTakeOutMonsterItem")
ensureRemoteEvent(remotesFolder, "RequestDropCarriedMonsters")
ensureRemoteEvent(remotesFolder, "RequestMonsterGift")
ensureRemoteEvent(remotesFolder, "ShowMonsterGiftOffer")
ensureRemoteEvent(remotesFolder, "RespondMonsterGiftOffer")

-- 测试：清空玩家数据
ensureRemoteEvent(remotesFolder, "RequestClearPlayerData")

-- 新手引导
ensureRemoteEvent(remotesFolder, "TutorialUpdate")
ensureRemoteEvent(remotesFolder, "TutorialRequestRetarget")
ensureRemoteEvent(remotesFolder, "TutorialClientReachedTarget")

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
local dropCarriedRemote = remotes:WaitForChild("RequestDropCarriedMonsters") :: RemoteEvent
local requestMonsterGiftRemote = remotes:WaitForChild("RequestMonsterGift") :: RemoteEvent
local showMonsterGiftOfferRemote = remotes:WaitForChild("ShowMonsterGiftOffer") :: RemoteEvent
local respondMonsterGiftOfferRemote = remotes:WaitForChild("RespondMonsterGiftOffer") :: RemoteEvent
-- [修改内容] 自动创建清空数据事件
local clearDataRemote = remotes:FindFirstChild("RequestClearPlayerData")
if not clearDataRemote then
	clearDataRemote = Instance.new("RemoteEvent")
	clearDataRemote.Name = "RequestClearPlayerData"
	clearDataRemote.Parent = remotes
end
local requestPromptInteractionRemote = remotes:WaitForChild("RequestPromptInteraction") :: RemoteEvent
local requestRebirthRemote = remotes:WaitForChild("RequestRebirth") :: RemoteEvent
-- [修改内容] 引用装备武器事件
local requestEquipWeaponRemote = remotes:WaitForChild("RequestEquipWeapon") :: RemoteEvent

local DEBUG_PROMPT_INTERACTION = false
local DEBUG_ANALYTICS = false
local DEBUG_SERVER_STARTUP = false

local function debugPrint(enabled: boolean, message: string)
	if enabled then
		print(message)
	end
end

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
local CashPerSecLeaderboardService = require(script.Parent:WaitForChild("Modules"):WaitForChild("CashPerSecLeaderboardService"))
local MonsterService = require(script.Parent:WaitForChild("Modules"):WaitForChild("MonsterService"))
local MerchantService = require(script.Parent:WaitForChild("Modules"):WaitForChild("MerchantService"))
local ZoneService = require(script.Parent:WaitForChild("Modules"):WaitForChild("ZoneService"))
local WeaponToolService = require(script.Parent:WaitForChild("Modules"):WaitForChild("WeaponToolService"))
local WeaponAppearanceService = require(script.Parent:WaitForChild("Modules"):WaitForChild("WeaponAppearanceService"))
local WeaponService = require(script.Parent:WaitForChild("Modules"):WaitForChild("WeaponService"))
--引入新的守护者系统模块
local GuardianService = require(script.Parent:WaitForChild("Modules"):WaitForChild("GuardianService"))
local TutorialService = require(script.Parent:WaitForChild("Modules"):WaitForChild("TutorialService"))

AppearanceBootstrapService.Init()
WeaponToolService.Init()
WeaponAppearanceService.Init()

-- MUST init persistence before HOME/Placement to ensure loaded data is applied first
DataPersistenceService.Init()

CharacterService.Init()
InventoryService.Init()
HomeService.Init()
PlacementService.Init()
CashPerSecLeaderboardService.Init()
MonsterService.Init()
MerchantService.Init()
TutorialService.Init()
WeaponService.Init()
--  启动守护者系统的全局初始化（生成待机的守护者并开启追踪循环）
GuardianService.Init()





-- [修改内容] 客户端背包 UI：请求装备武器
local PlayerData = require(script.Parent:WaitForChild("Modules"):WaitForChild("PlayerData"))

local function pushToast(player: Player, text: string)
	local toast = remotesFolder:FindFirstChild("PushClientToast")
	if toast and toast:IsA("RemoteEvent") then
		toast:FireClient(player, text)
	end
end

type PendingMonsterGift = {
	OfferId: string,
	Donor: Player,
	Receiver: Player,
	Monster: any,
	CreatedAt: number,
}

local pendingMonsterGiftsByOfferId: {[string]: PendingMonsterGift} = {}
local pendingMonsterGiftByReceiverUserId: {[number]: string} = {}
local lastGiftRequestByUserId: {[number]: number} = {}

local MONSTER_GIFT_MAX_DISTANCE = 4
local MONSTER_GIFT_EXPIRE_SECONDS = 20

local function getHrp(player: Player): BasePart?
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function arePlayersCloseEnough(a: Player, b: Player): boolean
	local aHrp = getHrp(a)
	local bHrp = getHrp(b)
	if not aHrp or not bHrp then
		return false
	end
	return (aHrp.Position - bHrp.Position).Magnitude <= MONSTER_GIFT_MAX_DISTANCE
end

local function sanitizeGiftMonsterPayload(monster: any): any
	return {
		MonsterLevel = math.max(1, math.floor(tonumber(monster.MonsterLevel) or 1)),
		Value = math.floor(tonumber(monster.Value) or 0),
		GoldPerSec = math.floor(tonumber(monster.GoldPerSec) or 0),
		UpgradeLevel = math.max(1, math.floor(tonumber(monster.UpgradeLevel) or 1)),
		BaseValue = math.floor(tonumber(monster.BaseValue) or tonumber(monster.Value) or 0),
		BaseGoldPerSec = math.floor(tonumber(monster.BaseGoldPerSec) or tonumber(monster.GoldPerSec) or 0),
		SourceZoneLevel = math.max(1, math.floor(tonumber(monster.SourceZoneLevel) or 1)),
		ExpireUnix = math.floor(tonumber(monster.ExpireUnix) or 0),
		StorageKind = tostring(monster.StorageKind or "Tool"),
	}
end

local function clearPendingMonsterGift(offerId: string)
	local offer = pendingMonsterGiftsByOfferId[offerId]
	if offer then
		pendingMonsterGiftByReceiverUserId[offer.Receiver.UserId] = nil
	end
	pendingMonsterGiftsByOfferId[offerId] = nil
end

local function pruneExpiredMonsterGifts()
	local now = os.clock()
	for offerId, offer in pairs(pendingMonsterGiftsByOfferId) do
		if now - offer.CreatedAt > MONSTER_GIFT_EXPIRE_SECONDS then
			clearPendingMonsterGift(offerId)
		end
	end
end

local function clearPendingMonsterGiftsForPlayer(player: Player)
	for offerId, offer in pairs(pendingMonsterGiftsByOfferId) do
		if offer.Donor == player or offer.Receiver == player then
			clearPendingMonsterGift(offerId)
		end
	end
	pendingMonsterGiftByReceiverUserId[player.UserId] = nil
	lastGiftRequestByUserId[player.UserId] = nil
end

requestRebirthRemote.OnServerEvent:Connect(function(player: Player)
	if PlayerData.PerformGoldRebirth(player) then
		CharacterService.Refresh(player, true)
		pushToast(player, string.format("Rebirth successful! Cash multiplier is now x%d", PlayerData.GetRebirthMultiplier(player)))
	else
		pushToast(player, string.format("Not enough gold. Need %d", PlayerData.GetRebirthCost(player)))
	end
end)

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

-- 客户端点击“放下怪”：把头顶携带的怪物丢回玩家附近。
-- 清空 CarriedMonsters 后，GuardianService 会在下一次追踪检查中自动停止追踪并返回。
dropCarriedRemote.OnServerEvent:Connect(function(player: Player)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return
	end

	local dropped = InventoryService.DropAllCarried(player, "Dropped carried monsters.")
	if #dropped == 0 then
		return
	end

	local basePosition = hrp.Position + (hrp.CFrame.LookVector * 6)
	for index, item in ipairs(dropped) do
		local angle = ((index - 1) / math.max(#dropped, 1)) * math.pi * 2
		local offset = Vector3.new(math.cos(angle) * 2.5, 0, math.sin(angle) * 2.5)
		local dropPos = basePosition + offset
		MonsterService.SpawnDroppedMonster(
			item.MonsterLevel,
			item.Value,
			item.GoldPerSec,
			dropPos,
			"PlayerManualDrop",
			(item :: any).UpgradeLevel or 1,
			(item :: any).SourceZoneLevel or 1,
			(item :: any).ExpireUnix
		)
	end
end)

requestMonsterGiftRemote.OnServerEvent:Connect(function(donor: Player, receiverUserId: any)
	pruneExpiredMonsterGifts()
	if type(receiverUserId) ~= "number" then
		return
	end

	local now = os.clock()
	local last = lastGiftRequestByUserId[donor.UserId] or 0
	if now - last < 0.8 then
		return
	end
	lastGiftRequestByUserId[donor.UserId] = now

	local receiver = Players:GetPlayerByUserId(math.floor(receiverUserId))
	if not receiver or receiver == donor then
		return
	end
	if not arePlayersCloseEnough(donor, receiver) then
		pushToast(donor, "Too far away to send a gift.")  --距离太远，无法赠送
		return
	end

	local monster = InventoryService.GetGiftableMonster(donor)
	if not monster then
		pushToast(donor, "You don't have any monsters to give.") --你当前没有可赠送的怪物
		return
	end

	local existingOfferId = pendingMonsterGiftByReceiverUserId[receiver.UserId]
	if existingOfferId then
		clearPendingMonsterGift(existingOfferId)
	end

	local offerId = string.format("%d_%d_%d", donor.UserId, receiver.UserId, math.random(100000, 999999))
	local payloadMonster = sanitizeGiftMonsterPayload(monster)
	pendingMonsterGiftsByOfferId[offerId] = {
		OfferId = offerId,
		Donor = donor,
		Receiver = receiver,
		Monster = payloadMonster,
		CreatedAt = now,
	}
	pendingMonsterGiftByReceiverUserId[receiver.UserId] = offerId

	showMonsterGiftOfferRemote:FireClient(receiver, {
		OfferId = offerId,
		DonorUserId = donor.UserId,
		DonorName = donor.DisplayName ~= "" and donor.DisplayName or donor.Name,
		Monster = payloadMonster,
		ExpireSeconds = MONSTER_GIFT_EXPIRE_SECONDS,
	})
	pushToast(donor, string.format("Monster gift request sent to %s", receiver.Name))
end)

respondMonsterGiftOfferRemote.OnServerEvent:Connect(function(receiver: Player, offerId: any, accepted: any)
	pruneExpiredMonsterGifts()
	if type(offerId) ~= "string" then
		return
	end

	local offer = pendingMonsterGiftsByOfferId[offerId]
	if not offer or offer.Receiver ~= receiver then
		return
	end

	clearPendingMonsterGift(offerId)

	local donor = offer.Donor
	if not donor or donor.Parent ~= Players then
		pushToast(receiver, "Gift failed: the donor has left the game.") --赠送玩家已离开
		return
	end

	if accepted ~= true then
		pushToast(donor, string.format("%s rejected the gift.", receiver.Name)) --%s玩家拒绝了你的赠送
		return
	end

	if not arePlayersCloseEnough(donor, receiver) then
		pushToast(receiver, "Too far away to accept the gift.") --距离太远，赠送已取消
		pushToast(donor, string.format("%s is too far away to accept the gift.", receiver.Name)) --%s 距离太远，赠送已取消
		return
	end

	local consumed = InventoryService.ConsumeGiftableMonster(donor, offer.Monster)
	if not consumed then
		pushToast(receiver, "Gift failed: the recipient is no longer holding this monster") --赠送失败：对方已经不再拿着这只怪物
		pushToast(donor, "Gift failed: the monster's status has changed") -- 赠送失败：怪物状态已变化
		return
	end

	local ok = InventoryService.GiveGiftedMonsterTool(receiver, consumed, true)
	if not ok then
		InventoryService.ReturnGiftableMonster(donor, consumed)
		pushToast(receiver, "Receive failed: backpack is currently unavailable") --#region 接收失败：背包暂时不可用
		pushToast(donor, "Gift failed: the recipient's backpack is currently unavailable") --赠送失败：对方背包暂时不可用
		return
	end

	pushToast(receiver, string.format("Accepted %s's monster gift", donor.Name)) --已接受 %s 的怪物赠送
	pushToast(donor, string.format("%s accepted the gift and says thanks!", receiver.Name)) --%s玩家接受了赠送并感谢
end)

-- 测试：清空玩家数据（仅 Studio）
-- [修改内容] 处理玩家清空数据的请求（终极防崩溃版）
clearDataRemote.OnServerEvent:Connect(function(player: Player)
	warn(string.format("Player %s is wiping save data...", player.Name)) --玩家 %s 正在执行删档清空...
	
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
	player:Kick("\nData cleared successfully!\nPlease rejoin and start a new journey.")
end)

-- 普通攻击：客户端请求对某个怪造成一次伤害
-- 注意：服务端会做距离与对象合法性校验

damageRemote.OnServerEvent:Connect(function(player: Player, monsterPart: Instance)
	MonsterService.DamageMonster(player, monsterPart)
end)

requestPromptInteractionRemote.OnServerEvent:Connect(function(player: Player, promptInstance: Instance)
	debugPrint(DEBUG_PROMPT_INTERACTION, string.format(
		"[PromptDebug][Server] OnServerEvent player=%s prompt=%s class=%s parent=%s",
		player.Name,
		debugPromptPath(promptInstance),
		promptInstance and promptInstance.ClassName or "nil",
		promptInstance and debugPromptPath(promptInstance.Parent) or "nil"
	))

	if PlacementService.TryHandlePromptInteraction(player, promptInstance) then
		debugPrint(DEBUG_PROMPT_INTERACTION, string.format(
			"[PromptDebug][Server] handled_by=PlacementService player=%s prompt=%s",
			player.Name,
			debugPromptPath(promptInstance)
		))
		return
	end

	if MonsterService.TryHandlePromptInteraction(player, promptInstance) then
		debugPrint(DEBUG_PROMPT_INTERACTION, string.format(
			"[PromptDebug][Server] handled_by=MonsterService player=%s prompt=%s",
			player.Name,
			debugPromptPath(promptInstance)
		))
		return
	end

	debugPrint(DEBUG_PROMPT_INTERACTION, string.format(
		"[PromptDebug][Server] rejected_by_all player=%s prompt=%s",
		player.Name,
		debugPromptPath(promptInstance)
	))
end)

debugPrint(DEBUG_SERVER_STARTUP, "[Game] Server initialized")

-- [修改原因] 规范化引入 AnalyticsService，移除重复定义的 ReplicatedStorage，并直接引用上方已建好的 remotesFolder
local AnalyticsService = game:GetService("AnalyticsService")
local analyticsRemote = remotesFolder:WaitForChild("Analytics_Remote") :: RemoteEvent

-- 简单的防刷记录字典，防止作弊者狂发垃圾事件污染后台
local rateLimitData = {}

local function getCharacterRootPosition(player: Player): Vector3?
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	return nil
end

local function isPointInsidePart(part: BasePart, worldPosition: Vector3, padding: number?): boolean
	local extra = padding or 0
	local localPos = part.CFrame:PointToObjectSpace(worldPosition)
	local half = part.Size * 0.5
	return math.abs(localPos.X) <= (half.X + extra)
		and math.abs(localPos.Y) <= (half.Y + extra)
		and math.abs(localPos.Z) <= (half.Z + extra)
end

local function isPointInsideInstance(root: Instance, worldPosition: Vector3, padding: number?): boolean
	if root:IsA("BasePart") then
		return isPointInsidePart(root, worldPosition, padding)
	end

	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("BasePart") and isPointInsidePart(descendant, worldPosition, padding) then
			return true
		end
	end

	return false
end

local function getPlayerExitZone(player: Player): string
	local position = getCharacterRootPosition(player)
	if not position then
		return "Unknown"
	end

	for _, zone in ipairs(ZoneService.GetPickupZones()) do
		if isPointInsidePart(zone.Part, position, 2) then
			return "PickupZone"
		end
	end

	local homeFolder = workspace:FindFirstChild("HOME")
	if homeFolder and homeFolder:IsA("Folder") then
		for _, homeRoot in ipairs(homeFolder:GetChildren()) do
			if isPointInsideInstance(homeRoot, position, 2) then
				return "HomeZone"
			end
		end
	end

	local merchant = ZoneService.GetMerchantPart()
	if merchant and isPointInsidePart(merchant, position, 4) then
		return "MerchantZone"
	end

	local weaponMerchant = ZoneService.GetWeaponMerchantPart()
	if weaponMerchant and isPointInsidePart(weaponMerchant, position, 4) then
		return "MerchantZone"
	end

	local gachaPart = workspace:FindFirstChild("转盘抽奖", true)
	if gachaPart and gachaPart:IsA("BasePart") and isPointInsidePart(gachaPart, position, 4) then
		return "GachaZone"
	end

	return "Unknown"
end

local function getExitTimeText(): string
	return os.date("!%Y%m%dT%H%M%SZ")
end

local function logPlayerEnter(player: Player)
	AnalyticsService:LogCustomEvent(player, "PlayerEnter")
end

local function logPlayerLeave(player: Player)
	local zoneName = getPlayerExitZone(player)
	local exitTime = getExitTimeText()
	AnalyticsService:LogCustomEvent(player, string.format("PlayerLeave_%s_%s", zoneName, exitTime))
	debugPrint(DEBUG_ANALYTICS, string.format("[Analytics] PlayerLeave player=%s userId=%d time=%s zone=%s", player.Name, player.UserId, exitTime, zoneName))
	if rateLimitData[player.UserId] ~= nil then
		rateLimitData[player.UserId] = nil
	end
	return zoneName, exitTime
end

analyticsRemote.OnServerEvent:Connect(function(player: Player, eventCategory: string, eventName: string)
    if eventCategory == "Funnel" then
        local lastTime = rateLimitData[player.UserId] or 0
        if os.clock() - lastTime > 0.5 then -- 防刷限制：0.5秒内只能触发一次
            rateLimitData[player.UserId] = os.clock()
            -- [修改原因] 接收客户端漏斗步骤（如打开UI、弹出支付框）并上报自定义事件
            AnalyticsService:LogCustomEvent(player, eventName)
        end
    end
end)

Players.PlayerAdded:Connect(function(player: Player)
	logPlayerEnter(player)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	clearPendingMonsterGiftsForPlayer(player)
	logPlayerLeave(player)
end)