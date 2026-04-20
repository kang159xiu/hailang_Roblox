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
    -- 1. [修改内容] 初始化升级商人交互
	local merchant = ZoneService.GetMerchantPart()
	if merchant then
		local openPrompt = ensurePrompt(merchant, "OpenUpgradeShop")
		openPrompt.ActionText = "打开升级商店"
		openPrompt.ObjectText = "商人"
		openPrompt.Triggered:Connect(function(player)
			openUpgradeShopUI:FireClient(player)
		end)
	end

    -- 2. [修改内容] 处理武器购买请求
	requestPurchaseWeapon.OnServerEvent:Connect(function(player: Player, desiredWeaponLevel: any)
		local wm = ZoneService.GetWeaponMerchantPart()
		if not wm or not isNear(player, wm, 12) then return end

		local stats = PlayerData.Get(player)
		local nextLevel = stats.WeaponLevel + 1
        local price = Config.WEAPON_PRICE_BY_LEVEL[nextLevel]
		
		if price and PlayerData.TrySpendGold(player, price) then
			WeaponToolService.GrantWeapon(player, nextLevel, true)
			pushToast(player, string.format("购买成功！花费 %s", Util.FormatMoney(price)))
		else
			pushToast(player, "金币不足或已满级")
		end
	end)

    -- 3. [修改内容] 处理升级请求（攻击/速度/血量）
    requestPurchaseUpgrade.OnServerEvent:Connect(function(player: Player, upgradeType: string)
        local m = ZoneService.GetMerchantPart()
        if not m or not isNear(player, m, 12) then return end
        
        -- 根据 upgradeType 执行 PlayerData.AddAttackLevel 等逻辑并扣款
        -- (参考有商店版本的 140-175 行逻辑进行集成)
    end)
end

return MerchantService
