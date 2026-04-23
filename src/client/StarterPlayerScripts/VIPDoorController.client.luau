-- ==========================================
-- 脚本位置：StarterPlayerScripts.VIPDoorController.client.luau
-- 功能：【正式版】处理 VIP Part 穿透逻辑及购买后立即生效
-- ==========================================

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local VIP_GAMEPASS_ID = 1806675692

-- 递归函数：穿透当前物体以及它内部的所有子零件
local function disableCollisionRecursive(instance)
	if instance:IsA("BasePart") then
		instance.CanCollide = false
	end
	for _, child in ipairs(instance:GetChildren()) do
		disableCollisionRecursive(child)
	end
end

-- 开启 VIP 穿墙功能的核心函数
local function enableVIPDoors()
	-- 1. 按标签查找 (推荐的规范做法)
	local vipObjects = CollectionService:GetTagged("VIPPart")
	for _, obj in ipairs(vipObjects) do
		disableCollisionRecursive(obj)
	end

	-- 2. 按名字查找 (兼容你截图中的 VIP_part 命名)
	for _, desc in ipairs(workspace:GetDescendants()) do
		if desc.Name == "VIP_part" or desc.Name == "VIPPart" then
			disableCollisionRecursive(desc)
		end
	end

	-- 3. 监听后续动态生成的 VIP 门
	CollectionService:GetInstanceAddedSignal("VIPPart"):Connect(function(obj)
		disableCollisionRecursive(obj)
	end)
	
	print("[VIPDoor] 验证通过！已为玩家开启 VIP 专属通道！")
end

-- ==========================================
-- 逻辑 1：玩家刚进游戏时，检查是否已经拥有该通行证
-- ==========================================
task.spawn(function()
	local success, hasPass = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, VIP_GAMEPASS_ID)
	end)

	if success and hasPass then
		enableVIPDoors()
	elseif not success then
		warn("[VIPDoor] 检查 VIP 权限失败，请检查网络连接。")
	end
end)

-- ==========================================
-- 逻辑 2：玩家在游戏中购买成功时，立即生效
-- ==========================================
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(promptPlayer, gamePassId, wasPurchased)
	if promptPlayer == player and gamePassId == VIP_GAMEPASS_ID then
		if wasPurchased then
			-- 全新购买成功
			enableVIPDoors()
		else
			-- 如果玩家之前买过，但点了购买按钮，Roblox 会提示"已拥有"且 wasPurchased 为 false
			-- 这里做个二次确认，如果确实拥有，也给开门
			local success, hasPass = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, VIP_GAMEPASS_ID)
			end)
			if success and hasPass then
				enableVIPDoors()
			end
		end
	end
end)