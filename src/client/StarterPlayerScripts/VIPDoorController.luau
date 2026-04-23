-- ==========================================
-- 脚本位置：StarterPlayerScripts.VIPDoorController
-- 功能：处理 VIP Part 穿透逻辑及购买后立即生效
-- ==========================================

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local VIP_GAMEPASS_ID = 1806675692

-- 开启 VIP 穿墙功能的核心函数
local function enableVIPDoors()
	-- 1. 获取当前场景中所有被打上 "VIPPart" 标签的零件
	local vipParts = CollectionService:GetTagged("VIPPart")
	for _, part in ipairs(vipParts) do
		if part:IsA("BasePart") then
			-- [修改内容] 仅在客户端关闭碰撞，实现无缝穿墙
			part.CanCollide = false 
		end
	end

	-- 2. 监听后续可能动态生成的 VIP Part（例如地图动态加载）
	CollectionService:GetInstanceAddedSignal("VIPPart"):Connect(function(part)
		if part:IsA("BasePart") then
			part.CanCollide = false
		end
	end)
	
	print("[VIPDoor] 已为玩家开启 VIP 专属通道！")
end

-- ==========================================
-- 逻辑 1：玩家刚进游戏时，检查是否已经拥有该通行证
-- ==========================================
task.spawn(function()
	-- 使用 pcall 防止网络问题导致脚本报错中断
	local success, hasPass = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, VIP_GAMEPASS_ID)
	end)

	if success and hasPass then
		-- 如果已经拥有，直接开启穿墙
		enableVIPDoors()
	elseif not success then
		warn("[VIPDoor] 检查 VIP 权限失败，请检查网络连接。")
	end
end)

-- ==========================================
-- 逻辑 2：玩家在游戏中购买成功时，立即生效
-- ==========================================
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(promptPlayer, gamePassId, wasPurchased)
	-- 确保是当前玩家购买了，购买的是 VIP 通行证，并且购买成功了
	if promptPlayer == player and gamePassId == VIP_GAMEPASS_ID and wasPurchased then
		enableVIPDoors()
		
		-- 如果你有类似于全局提示的模块，可以在这里调用，例如：
		-- local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
		-- if remotes and remotes:FindFirstChild("PushClientToast") then
		-- 	remotes.PushClientToast:Fire("购买 VIP 成功！专属通道已开启！")
		-- end
	end
end)