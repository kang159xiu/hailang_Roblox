-- 服务端路径: ServerScriptService.GachaServer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local PlayerData = require(game.ServerScriptService.Modules.PlayerData)
local InventoryService = require(game.ServerScriptService.Modules.InventoryService)

-- [修改原因] 初始化 RemoteEvent 用于前后端通信
local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then 
	remotes = Instance.new("Folder", ReplicatedStorage)
	remotes.Name = "Remotes" 
end

local requestEvent = remotes:FindFirstChild("GachaRequest") or Instance.new("RemoteEvent", remotes)
requestEvent.Name = "GachaRequest"

local resultEvent = remotes:FindFirstChild("GachaResult") or Instance.new("RemoteEvent", remotes)
resultEvent.Name = "GachaResult"

local PRODUCT_ID_10_PULL = 3580035858
local COST_1_PULL_GOLD = 1000000

-- [修改原因] 核心算法：怪物等级越高，抽中概率越低 (指数级衰减权重)
local function getRandomMonsterLevel()
	local weights = {}
	local totalWeight = 0
	
	for i = 1, 30 do
		-- 等级越高，权重呈指数级下降。例如 1级权重极高，30级权重接近 1
		local weight = math.max(1, math.floor(100000 / (1.4 ^ i)))
		table.insert(weights, weight)
		totalWeight += weight
	end

	local randomVal = math.random(1, totalWeight)
	local currentWeight = 0
	for i = 1, 30 do
		currentWeight += weights[i]
		if randomVal <= currentWeight then
			return i
		end
	end
	return 1
end

-- [修改原因] 新增一个表来记录每个玩家是否开启了快速模式
local playerFastModeCache = {}

-- [修改原因] 执行抽奖、发奖与结果广播
local function performGacha(player: Player, times: number)
	local results = {}
	local maxLevel = 0

	for i = 1, times do
		local lvl = getRandomMonsterLevel()
		table.insert(results, lvl)
		if lvl > maxLevel then
			maxLevel = lvl
		end
	end

	-- [修改原因] 获取该玩家的快速模式状态，计算延迟时间（普通1秒，快速0.3秒）
	local isFast = playerFastModeCache[player]
	local delayTime = isFast and 0.3 or 1.0

	-- [修改原因] 下发结果给客户端做动画展示，并将延迟时间一同下发保证同步
	resultEvent:FireClient(player, results, delayTime)

	-- [修改原因] 开启异步延迟，动画结束后再把怪物给玩家
	task.delay(delayTime, function()
		-- 安全校验：防止玩家在等待期间退出了游戏
		if not player.Parent then return end

		local hasEquippedMax = false
		for _, lvl in ipairs(results) do
			-- 需求：当次抽奖获得怪物的最高级在玩家手中拿着
			local shouldEquip = false
			if lvl == maxLevel and not hasEquippedMax then
				shouldEquip = true
				hasEquippedMax = true
			end
			
			InventoryService.GiveGachaMonsterTool(player, lvl, shouldEquip)
		end
	end)
end

-- 监听金币抽奖及模式切换
requestEvent.OnServerEvent:Connect(function(player, action, extraData)
	-- 接收并记录客户端发来的快速模式状态
	if action == "ToggleFastMode" then
		playerFastModeCache[player] = extraData == true
	elseif action == "Gold1" then
		-- [修改原因] 修复之前的语法错误，确保扣费逻辑在正确的 action 判断分支内
		if PlayerData.TrySpendGold(player, COST_1_PULL_GOLD) then
			performGacha(player, 1)
		else
			local toastEvent = remotes:FindFirstChild("PushClientToast")
			if toastEvent then toastEvent:FireClient(player, "金币不足") end
		end
	end
end)

-- [修改原因] 监听 Robux 支付回调
MarketplaceService.ProcessReceipt = function(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then 
		return Enum.ProductPurchaseDecision.NotProcessedYet 
	end

	if receiptInfo.ProductId == PRODUCT_ID_10_PULL then
		performGacha(player, 10)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	return Enum.ProductPurchaseDecision.NotProcessedYet
end