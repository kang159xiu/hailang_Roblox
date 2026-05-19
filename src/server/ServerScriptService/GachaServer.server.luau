-- 服务端路径: ServerScriptService.GachaServer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local PlayerData = require(game.ServerScriptService.Modules.PlayerData)
local InventoryService = require(game.ServerScriptService.Modules.InventoryService)
local CharacterService = require(game.ServerScriptService.Modules.CharacterService)
local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))

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
local PRODUCT_ID_5_PULL = 3580661228
local PRODUCT_ID_REBIRTH = Config.REBIRTH_PRODUCT_ID
local COST_1_PULL_GOLD = 1000000

local ONLINE_REWARD_MINUTES = { 1, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120 }
local ONLINE_REWARD_SECONDS = {}
for index, minutes in ipairs(ONLINE_REWARD_MINUTES) do
	ONLINE_REWARD_SECONDS[index] = minutes * 60
end

local function getUtcDateKey(): string
	local t = os.date("!*t", os.time())
	return string.format("%04d%02d%02d", t.year, t.month, t.day)
end

local function syncOnlineRewardCountdown(player: Player)
	local claimedIndex = PlayerData.GetOnlineRewardClaimedIndex(player)
	local onlineSeconds = PlayerData.GetOnlineRewardSeconds(player)
	local nextIndex = claimedIndex + 1
	local nextSeconds = ONLINE_REWARD_SECONDS[nextIndex]

	if not nextSeconds then
		player:SetAttribute("OnlineRewardAllClaimed", true)
		player:SetAttribute("OnlineRewardSecondsUntilNext", 0)
		player:SetAttribute("OnlineRewardNextRewardMinutes", 0)
		return
	end

	player:SetAttribute("OnlineRewardAllClaimed", false)
	player:SetAttribute("OnlineRewardSecondsUntilNext", math.max(0, nextSeconds - onlineSeconds))
	player:SetAttribute("OnlineRewardNextRewardMinutes", ONLINE_REWARD_MINUTES[nextIndex])
end

local function runOnlineRewardLoop(player: Player)
	task.spawn(function()
		while player.Parent and player:GetAttribute("__DataLoaded") ~= true do
			task.wait(0.2)
		end
		if not player.Parent then
			return
		end

		PlayerData.EnsureOnlineRewardDate(player, getUtcDateKey())
		syncOnlineRewardCountdown(player)

		while player.Parent do
			task.wait(1)
			if not player.Parent then
				break
			end

			local dateKey = getUtcDateKey()
			PlayerData.AddOnlineRewardSeconds(player, 1, dateKey)

			local onlineSeconds = PlayerData.GetOnlineRewardSeconds(player)
			local claimedIndex = PlayerData.GetOnlineRewardClaimedIndex(player)
			while claimedIndex < #ONLINE_REWARD_SECONDS and onlineSeconds >= ONLINE_REWARD_SECONDS[claimedIndex + 1] do
				claimedIndex += 1
				PlayerData.SetOnlineRewardClaimedIndex(player, claimedIndex)
				PlayerData.AddGachaDrawCount(player, 1)
			end

			syncOnlineRewardCountdown(player)
		end
	end)
end


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

Players.PlayerAdded:Connect(runOnlineRewardLoop)
for _, player in ipairs(Players:GetPlayers()) do
	runOnlineRewardLoop(player)
end

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

	local isFast = playerFastModeCache[player]
	local delayTime

	if times > 1 then
		delayTime = times * 0.3
	else
		delayTime = isFast and 0.3 or 1.0
	end


resultEvent:FireClient(player, results, delayTime)

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
			if toastEvent then toastEvent:FireClient(player, "Not enough gold") end
		end
	elseif action == "Count1" then
		-- 次数抽奖：后续其它玩法只需要调用 PlayerData.AddGachaDrawCount(player, n) 发放次数。
		local drawsBefore = PlayerData.GetGachaDrawCount(player)
		print("[GachaServer] Count1 requested", player.Name, "drawsBefore=", drawsBefore)
		if PlayerData.TrySpendGachaDrawCount(player, 1) then
			print("[GachaServer] Count1 accepted", player.Name, "drawsAfter=", PlayerData.GetGachaDrawCount(player))
			performGacha(player, 1)
		else
			warn("[GachaServer] Count1 rejected: not enough draws", player.Name, "draws=", drawsBefore)
			local toastEvent = remotes:FindFirstChild("PushClientToast")
			if toastEvent then toastEvent:FireClient(player, "Not enough gacha draws") end
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

	if receiptInfo.ProductId == PRODUCT_ID_5_PULL then
		performGacha(player, 5)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	if receiptInfo.ProductId == PRODUCT_ID_REBIRTH then
		PlayerData.PerformRobuxRebirth(player)
		CharacterService.Refresh(player, true)
		local toastEvent = remotes:FindFirstChild("PushClientToast")
		if toastEvent and toastEvent:IsA("RemoteEvent") then
			toastEvent:FireClient(player, string.format("Robux rebirth successful! Cash multiplier is now x%d", PlayerData.GetRebirthMultiplier(player)))
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end


	return Enum.ProductPurchaseDecision.NotProcessedYet
end