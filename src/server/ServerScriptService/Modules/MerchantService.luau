--!strict
-- ServerScriptService.Modules.MerchantService
-- 负责：
-- 1) 商人区域/武器商人区域：触发后打开对应商店 UI（客户端界面）
-- 2) 处理客户端的购买请求（服务端校验：距离/金币/等级）
--

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local WeaponToolService = require(script.Parent:WaitForChild("WeaponToolService"))
local CharacterService = require(script.Parent:WaitForChild("CharacterService"))
local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))

local ZoneService = require(script.Parent:WaitForChild("ZoneService"))
-- [修改内容] 引入 Util 模块，以便在下方使用 Util.FormatMoney 转化数字
local Util = require(script.Parent:WaitForChild("Util"))



local MerchantService = {}

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local requestPurchaseUpgrade = remotes:WaitForChild("RequestPurchaseUpgrade") :: RemoteEvent
local requestPurchaseWeapon = remotes:WaitForChild("RequestPurchaseWeapon") :: RemoteEvent
local requestEquipWeapon = remotes:WaitForChild("RequestEquipWeapon") :: RemoteEvent
local openWeaponShopUI = remotes:WaitForChild("OpenWeaponShopUI") :: RemoteEvent
local openUpgradeShopUI = remotes:WaitForChild("OpenUpgradeShopUI") :: RemoteEvent


local function ensurePrompt(parent: Instance, name: string): ProximityPrompt
	local p = parent:FindFirstChild(name)
	if p and p:IsA("ProximityPrompt") then
		return p
	end
	p = Instance.new("ProximityPrompt")
	p.Name = name
	p.Parent = parent
	p.RequiresLineOfSight = false
	p.MaxActivationDistance = 10
	p.HoldDuration = 0.2
	p.KeyboardKeyCode = Enum.KeyCode.E
	return p
end

local function destroyPromptIfExists(parent: Instance, name: string)
	local p = parent:FindFirstChild(name)
	if p and p:IsA("ProximityPrompt") then
		p:Destroy()
	end
end

local function pushToast(player: Player, text: string)
	local toast = remotes:FindFirstChild("PushClientToast")
	if toast and toast:IsA("RemoteEvent") then
		toast:FireClient(player, text)
	end
end

local function isNear(player: Player, part: BasePart, maxDist: number): boolean
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return false
	end

	-- 不能只用“到 Part 中心点的距离”：
	-- 当商人区域 Part 较大时，玩家可触发 Prompt，但到中心点可能 > maxDist，
	-- 会导致“商店已打开但购买被服务端拒绝”。
	-- 这里改为“到 Part 包围盒最近点”的距离判断。
	local localPos = part.CFrame:PointToObjectSpace(hrp.Position)
	local half = part.Size * 0.5
	local nearestLocal = Vector3.new(
		math.clamp(localPos.X, -half.X, half.X),
		math.clamp(localPos.Y, -half.Y, half.Y),
		math.clamp(localPos.Z, -half.Z, half.Z)
	)
	local nearestWorld = part.CFrame:PointToWorldSpace(nearestLocal)

	return (hrp.Position - nearestWorld).Magnitude <= maxDist
end

local function getDistanceToPartBounds(player: Player, part: BasePart): number?
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end

	local localPos = part.CFrame:PointToObjectSpace(hrp.Position)
	local half = part.Size * 0.5
	local nearestLocal = Vector3.new(
		math.clamp(localPos.X, -half.X, half.X),
		math.clamp(localPos.Y, -half.Y, half.Y),
		math.clamp(localPos.Z, -half.Z, half.Z)
	)
	local nearestWorld = part.CFrame:PointToWorldSpace(nearestLocal)
	return (hrp.Position - nearestWorld).Magnitude
end

function MerchantService.Init()
	-- 1. [修改内容] 初始化升级商人交互
	local merchant = ZoneService.GetMerchantPart()
	if merchant then
		local openPrompt = ensurePrompt(merchant, "OpenUpgradeShop")
		openPrompt.ActionText = "Open Upgrade Shop"
		openPrompt.ObjectText = "Merchant"
		openPrompt.Triggered:Connect(function(player)
			openUpgradeShopUI:FireClient(player)
		end)
	end

	-- 1.1 初始化武器商人交互
	local weaponMerchant = ZoneService.GetWeaponMerchantPart()
	if weaponMerchant then
		local openPrompt = ensurePrompt(weaponMerchant, "OpenWeaponShop")
		openPrompt.ActionText = "Open Weapon Shop"
		openPrompt.ObjectText = "Weapon Merchant"
		openPrompt.Triggered:Connect(function(player)
			openWeaponShopUI:FireClient(player)
		end)
	end

	-- 2. [修改内容] 处理武器购买请求
	requestPurchaseWeapon.OnServerEvent:Connect(function(player: Player, desiredWeaponLevel: any)
		local wm = ZoneService.GetWeaponMerchantPart()
		if not wm then
			warn(string.format("[WeaponShopDebug][Server] rejected action=purchase player=%s desired=%s reason=merchant_missing", player.Name, tostring(desiredWeaponLevel)))
			pushToast(player, "Weapon shop is not available")
			return
		end
		if not isNear(player, wm, 12) then
			warn(string.format(
				"[WeaponShopDebug][Server] rejected action=purchase player=%s desired=%s reason=too_far distance=%s",
				player.Name,
				tostring(desiredWeaponLevel),
				tostring(getDistanceToPartBounds(player, wm))
			))
			pushToast(player, "Move closer to the weapon shop")
			return
		end

		local stats = PlayerData.Get(player)
		local desired = tonumber(desiredWeaponLevel)
		if not desired then
			warn(string.format("[WeaponShopDebug][Server] rejected action=purchase player=%s desired=%s reason=invalid_desired", player.Name, tostring(desiredWeaponLevel)))
			pushToast(player, "Invalid weapon level")
			return
		end
		desired = math.floor(desired)

		warn(string.format(
			"[WeaponShopDebug][Server] received action=purchase player=%s desired=%d current=%d gold=%s",
			player.Name,
			desired,
			stats.WeaponLevel,
			tostring(stats.Gold)
		))
		if desired < 1 then
			warn(string.format("[WeaponShopDebug][Server] rejected action=purchase player=%s desired=%d reason=invalid_level", player.Name, desired))
			pushToast(player, "Invalid weapon level")
			return
		end

		local price = Config.WEAPON_PRICE_BY_LEVEL[desired]
		if price == nil then
			warn(string.format("[WeaponShopDebug][Server] rejected action=purchase player=%s desired=%d reason=missing_price", player.Name, desired))
			pushToast(player, "Invalid weapon level")
			return
		end

		if table.find(stats.OwnedWeaponLevels, desired) ~= nil then
			warn(string.format("[WeaponShopDebug][Server] rejected action=purchase player=%s desired=%d reason=already_owned", player.Name, desired))
			pushToast(player, string.format("Already owned: Weapon Lv.%d", desired))
			return
		end
		
		

		if not PlayerData.TrySpendGold(player, price) then
			warn(string.format("[WeaponShopDebug][Server] rejected action=purchase player=%s desired=%d reason=not_enough_gold need=%s gold=%s", player.Name, desired, tostring(price), tostring(stats.Gold)))
			pushToast(player, string.format("Not enough gold. Need %s", Util.FormatMoney(price)))
			return
		end
		
		-- [修改原因] 经济埋点：上报武器购买造成的金币消耗
		local AnalyticsService = game:GetService("AnalyticsService")
		AnalyticsService:LogEconomyEvent(
			player,
			Enum.AnalyticsEconomyFlowType.Sink,
			"Gold", 
			price,
			PlayerData.Get(player).Gold, 
			"Shop",
			"Weapon_Purchase_Lv" .. tostring(desired)
		)

		WeaponToolService.GrantWeapon(player, desired, true)
		DataDirtyService.MarkDirty(player, 5)
		warn(string.format("[WeaponShopDebug][Server] success action=purchase player=%s level=%d cost=%s", player.Name, desired, tostring(price)))
		pushToast(player, string.format("Purchase successful: Weapon Lv.%d (Cost %s)", desired, Util.FormatMoney(price)))
	end)

	-- 3. [修改内容] 处理装备已拥有武器的请求
	requestEquipWeapon.OnServerEvent:Connect(function(player: Player, desiredWeaponLevel: any)
		local wm = ZoneService.GetWeaponMerchantPart()
		if not wm then
			warn(string.format("[WeaponShopDebug][Server] rejected action=equip player=%s desired=%s reason=merchant_missing", player.Name, tostring(desiredWeaponLevel)))
			pushToast(player, "Weapon shop is not available")
			return
		end
		if not isNear(player, wm, 12) then
			warn(string.format(
				"[WeaponShopDebug][Server] rejected action=equip player=%s desired=%s reason=too_far distance=%s",
				player.Name,
				tostring(desiredWeaponLevel),
				tostring(getDistanceToPartBounds(player, wm))
			))
			pushToast(player, "Move closer to the weapon shop")
			return
		end

		local desired = tonumber(desiredWeaponLevel)
		if not desired then
			warn(string.format("[WeaponShopDebug][Server] rejected action=equip player=%s desired=%s reason=invalid_desired", player.Name, tostring(desiredWeaponLevel)))
			pushToast(player, "Invalid weapon level")
			return
		end
		desired = math.floor(desired)
		warn(string.format("[WeaponShopDebug][Server] received action=equip player=%s desired=%d", player.Name, desired))

		PlayerData.SetEquippedWeaponLevel(player, desired)
		WeaponToolService.Sync(player, true)
		DataDirtyService.MarkDirty(player, 5)
		warn(string.format("[WeaponShopDebug][Server] success action=equip player=%s level=%d", player.Name, desired))
		pushToast(player, string.format("Equipped: Weapon Lv.%d", desired))
	end)

	-- 4. [修改内容] 处理升级请求（攻击/速度/跳跃/携带数量/偷取数量）
	requestPurchaseUpgrade.OnServerEvent:Connect(function(player: Player, upgradeType: any)
		local m = ZoneService.GetMerchantPart()
		if not m then
			warn(string.format("[UpgradeShopDebug][Server] rejected player=%s type=%s reason=merchant_missing", player.Name, tostring(upgradeType)))
			pushToast(player, "Upgrade shop is not available")
			return
		end
		if not isNear(player, m, 12) then
			warn(string.format("[UpgradeShopDebug][Server] rejected player=%s type=%s reason=too_far", player.Name, tostring(upgradeType)))
			pushToast(player, "Move closer to the upgrade shop")
			return
		end

		local t = tostring(upgradeType)
		warn(string.format("[UpgradeShopDebug][Server] received player=%s type=%s", player.Name, t))
		local stats = PlayerData.Get(player)
		---【【【【
		if t == "Attack" then
			local nextLevel = stats.AttackLevel + 1
			local cost = Config.GetAttackUpgradeCost(nextLevel)
			if PlayerData.TrySpendGold(player, cost) then
				-- [修改原因] 经济埋点：上报攻击力升级造成的金币消耗
				local AnalyticsService = game:GetService("AnalyticsService")
				AnalyticsService:LogEconomyEvent(
					player,
					Enum.AnalyticsEconomyFlowType.Sink,
					"Gold",
					cost,
					PlayerData.Get(player).Gold,
					"Gameplay",
					"Upgrade_Attack"
				)
				
				PlayerData.AddAttackLevel(player, 1)
				DataDirtyService.MarkDirty(player, 5)
				pushToast(player, string.format("Attack upgraded! Cost: %s", Util.FormatMoney(cost)))
			else
				pushToast(player, "Not enough gold")
			end
		elseif t == "Speed" then
			local nextLevel = stats.SpeedLevel + 1
			local cost = Config.GetSpeedUpgradeCost(nextLevel)
			if PlayerData.TrySpendGold(player, cost) then
				-- [修改原因] 经济埋点：上报速度升级造成的金币消耗
				local AnalyticsService = game:GetService("AnalyticsService")
				AnalyticsService:LogEconomyEvent(
					player,
					Enum.AnalyticsEconomyFlowType.Sink,
					"Gold",
					cost,
					PlayerData.Get(player).Gold,
					"Gameplay",
					"Upgrade_Speed"
				)
				
				PlayerData.AddSpeedLevel(player, 1)
				CharacterService.Refresh(player)
				DataDirtyService.MarkDirty(player, 5)
				pushToast(player, string.format("Speed upgraded! Cost: %s", Util.FormatMoney(cost)))
			else
				pushToast(player, "Not enough gold")
			end
		elseif t == "Health" or t == "Jump" then
			local nextLevel = stats.HealthLevel + 1
			local maxJumpLevel = if Config.GetMaxJumpUpgradeLevel then Config.GetMaxJumpUpgradeLevel() else math.max(0, math.floor(((Config.JUMP_POWER_MAX or 150) - (Config.JUMP_POWER_BASE or 50)) / (Config.JUMP_POWER_PER_UPGRADE or 1)))
			if stats.HealthLevel >= maxJumpLevel then
				pushToast(player, "Jump is max level")
				return
			end
			local cost = if Config.GetJumpUpgradeCost then Config.GetJumpUpgradeCost(nextLevel) else Config.GetHealthUpgradeCost(nextLevel)
			if PlayerData.TrySpendGold(player, cost) then
				-- [修改原因] 经济埋点：上报跳跃升级造成的金币消耗
				local AnalyticsService = game:GetService("AnalyticsService")
				AnalyticsService:LogEconomyEvent(
					player,
					Enum.AnalyticsEconomyFlowType.Sink,
					"Gold",
					cost,
					PlayerData.Get(player).Gold,
					"Gameplay",
					"Upgrade_Jump"
				)
				
				-- 复用 HealthLevel 作为旧存档键；实际效果由 CharacterService 应用为 JumpPower。
				PlayerData.AddHealthLevel(player, 1)
				CharacterService.Refresh(player)
				DataDirtyService.MarkDirty(player, 5)
				pushToast(player, string.format("Jump upgraded! Cost: %s", Util.FormatMoney(cost)))
			else
				pushToast(player, "Not enough gold")
			end
		elseif t == "Carry" then
			local nextLevel = stats.CarryLevel + 1
			local cost = Config.GetCarryUpgradeCost(nextLevel)
			if cost == nil then
				pushToast(player, "Carry capacity is maxed")
				return
			end
			if PlayerData.TrySpendGold(player, cost) then
				-- [修改原因] 经济埋点：上报背包携带数量升级造成的金币消耗
				local AnalyticsService = game:GetService("AnalyticsService")
				AnalyticsService:LogEconomyEvent(
					player,
					Enum.AnalyticsEconomyFlowType.Sink,
					"Gold",
					cost,
					PlayerData.Get(player).Gold,
					"Gameplay",
					"Upgrade_Carry"
				)
				
				PlayerData.AddCarryLevel(player, 1)
				DataDirtyService.MarkDirty(player, 5)
				pushToast(player, string.format("Carry capacity upgraded! Cost: %s", Util.FormatMoney(cost)))
			else
				pushToast(player, "Not enough gold")
			end
		elseif t == "Steal" then
			local nextLevel = math.max(0, math.floor(tonumber((stats :: any).StealLevel) or 0)) + 1
			local cost = Config.GetStealUpgradeCost(nextLevel)
			if PlayerData.TrySpendGold(player, cost) then
				-- [修改原因] 经济埋点：上报每次偷取金币数量升级造成的金币消耗
				local AnalyticsService = game:GetService("AnalyticsService")
				AnalyticsService:LogEconomyEvent(
					player,
					Enum.AnalyticsEconomyFlowType.Sink,
					"Gold",
					cost,
					PlayerData.Get(player).Gold,
					"Gameplay",
					"Upgrade_Steal"
				)

				PlayerData.AddStealLevel(player, 1)
				DataDirtyService.MarkDirty(player, 5)
				pushToast(player, string.format("Steal amount upgraded! Cost: %s", Util.FormatMoney(cost)))
			else
				pushToast(player, "Not enough gold")
			end
		end
	end)
end

return MerchantService
