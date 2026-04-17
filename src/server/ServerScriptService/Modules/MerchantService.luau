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

function MerchantService.Init()
	local merchant = ZoneService.GetMerchantPart()
	if merchant then
		-- 清理旧版本 prompt（避免同时出现多个）
		destroyPromptIfExists(merchant, "UpgradeSpeed")
		destroyPromptIfExists(merchant, "UpgradeAttack")

		local openPrompt = ensurePrompt(merchant, "OpenUpgradeShop")
		openPrompt.ActionText = "打开升级商店"
		openPrompt.ObjectText = "商人"
		openPrompt.Triggered:Connect(function(player)
			openUpgradeShopUI:FireClient(player)
		end)
	else
		warn("[MerchantService] Missing Workspace.商人区域")
	end

	local weaponMerchant = ZoneService.GetWeaponMerchantPart()
	if weaponMerchant then
		-- 清理旧版本 prompt（避免同时出现多个）
		destroyPromptIfExists(weaponMerchant, "BuyNextWeapon")

		local openPrompt = ensurePrompt(weaponMerchant, "OpenWeaponShop")
		openPrompt.ActionText = "打开武器商店"
		openPrompt.ObjectText = "武器商人"
		openPrompt.Triggered:Connect(function(player)
			openWeaponShopUI:FireClient(player)
		end)
	else
		warn("[MerchantService] Missing Workspace.武器商人区域")
	end

	-- =====================
	-- 购买请求（客户端 -> 服务端）
	-- =====================

	requestPurchaseWeapon.OnServerEvent:Connect(function(player: Player, desiredWeaponLevel: any)
		local wm = ZoneService.GetWeaponMerchantPart()
		if not wm then
			return
		end
		if not isNear(player, wm, 12) then
			return
		end

		local stats = PlayerData.Get(player)
		local desired = tonumber(desiredWeaponLevel)
		if not desired then
			return
		end

		-- 目前规则：只能买“下一把”
		local nextLevel = stats.WeaponLevel + 1
		if desired ~= nextLevel then
			pushToast(player, "只能购买下一把武器")
			return
		end

		local price = Config.WEAPON_PRICE_BY_LEVEL[nextLevel]
		if price == nil then
			pushToast(player, "已经是最高武器")
			return
		end
		if not PlayerData.TrySpendGold(player, price) then
			-- [修改内容] 使用 Util.FormatMoney 转化价格，并把占位符 %d (数字) 改为 %s (字符串)
			pushToast(player, string.format("金币不足，需要 %s", Util.FormatMoney(price)))
			return
		end
		WeaponToolService.GrantWeapon(player, nextLevel, true)
		DataDirtyService.MarkDirty(player, 5)
		-- [修改内容] 购买成功的提示也同样加上单位转化
		pushToast(player, string.format("购买成功：武器Lv.%d（花费%s）", nextLevel, Util.FormatMoney(price)))
	end)

	-- 装备已拥有的武器（从商店 UI 点击）
	requestEquipWeapon.OnServerEvent:Connect(function(player: Player, desiredWeaponLevel: any)
		local wm = ZoneService.GetWeaponMerchantPart()
		if not wm then
			return
		end
		if not isNear(player, wm, 12) then
			return
		end

		local desired = tonumber(desiredWeaponLevel)
		if not desired then
			return
		end

		-- 服务端校验：只能装备已拥有武器
		PlayerData.SetEquippedWeaponLevel(player, desired)
		WeaponToolService.Sync(player, true)
		DataDirtyService.MarkDirty(player, 5)
		pushToast(player, string.format("已装备：武器Lv.%d", desired))
	end)

	requestPurchaseUpgrade.OnServerEvent:Connect(function(player: Player, upgradeType: any)
		local m = ZoneService.GetMerchantPart()
		if not m then
			return
		end
		if not isNear(player, m, 12) then
			return
		end

		local t = tostring(upgradeType)
		local stats = PlayerData.Get(player)

		if t == "Attack" then
			local nextLevel = stats.AttackLevel + 1
			local cost = Config.GetAttackUpgradeCost(nextLevel)
			if not PlayerData.TrySpendGold(player, cost) then
				pushToast(player, string.format("金币不足，需要 %d", cost))
				return
			end
			PlayerData.AddAttackLevel(player, 1)
			DataDirtyService.MarkDirty(player, 5)
			pushToast(player, string.format("攻击力升级成功：Lv.%d（花费%d）", nextLevel, cost))
		elseif t == "Speed" then
			local nextLevel = stats.SpeedLevel + 1
			local cost = Config.GetSpeedUpgradeCost(nextLevel)
			if not PlayerData.TrySpendGold(player, cost) then
				pushToast(player, string.format("金币不足，需要 %d", cost))
				return
			end
			PlayerData.AddSpeedLevel(player, 1)
			CharacterService.Refresh(player)
			DataDirtyService.MarkDirty(player, 5)
			pushToast(player, string.format("速度升级成功：Lv.%d（花费%d）", nextLevel, cost))
		elseif t == "Health" then
			local nextLevel = stats.HealthLevel + 1
			local cost = Config.GetHealthUpgradeCost(nextLevel)
			if not PlayerData.TrySpendGold(player, cost) then
				pushToast(player, string.format("金币不足，需要 %d", cost))
				return
			end
			PlayerData.AddHealthLevel(player, 1)
			CharacterService.Refresh(player)
			DataDirtyService.MarkDirty(player, 5)
			pushToast(player, string.format("血量升级成功：Lv.%d（花费%d）", nextLevel, cost))
		elseif t == "Carry" then
			local nextLevel = stats.CarryLevel + 1
			local cost = Config.GetCarryUpgradeCost(nextLevel)
			if cost == nil then
				pushToast(player, "携带数量已满级")
				return
			end
			if not PlayerData.TrySpendGold(player, cost) then
				pushToast(player, string.format("金币不足，需要 %d", cost))
				return
			end
			PlayerData.AddCarryLevel(player, 1)
			DataDirtyService.MarkDirty(player, 5)
			pushToast(player, string.format("携带数量升级成功：Lv.%d（花费%d）", nextLevel, cost))
		else
			return
		end
	end)
end

return MerchantService
