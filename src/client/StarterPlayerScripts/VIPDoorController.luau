-- ==========================================
-- 脚本位置：StarterPlayerScripts.VIPDoorController
-- ==========================================

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local VIP_GAMEPASS_ID = 1806675692

print("[VIPDoor-日志] VIP控制器已启动，正在监听玩家...")

local function disableCollisionRecursive(instance)
	if instance:IsA("BasePart") then
		instance.CanCollide = false
	end
	for _, child in ipairs(instance:GetChildren()) do
		disableCollisionRecursive(child)
	end
end

local function enableVIPDoors()
	local vipObjects = CollectionService:GetTagged("VIPPart")
	local count = 0
	for _, obj in ipairs(vipObjects) do
		disableCollisionRecursive(obj)
		count += 1
	end

	CollectionService:GetInstanceAddedSignal("VIPPart"):Connect(function(obj)
		disableCollisionRecursive(obj)
	end)
	
	-- 这里的打印加了数量统计，方便你确认标签是否真的打上了
	print("[VIPDoor-成功] 穿墙已开启！共找到了 " .. count .. " 个 VIPPart。")
end

-- 1. 进游戏时的检查
task.spawn(function()
	print("[VIPDoor-日志] 正在向服务器请求确认玩家是否拥有通行证...")
	local success, hasPass = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, VIP_GAMEPASS_ID)
	end)

	if success then
		print("[VIPDoor-日志] 服务器返回结果：玩家是否拥有 = " .. tostring(hasPass))
		if hasPass then
			enableVIPDoors()
		end
	else
		warn("[VIPDoor-警告] 请求失败，请检查网络或通行证ID是否正确！")
	end
end)

-- 2. 点击购买后的检查
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(promptPlayer, gamePassId, wasPurchased)
	print("[VIPDoor-日志] 收到购买窗口关闭的回调！")
	print("[VIPDoor-日志] 弹窗的通行证ID: " .. tostring(gamePassId))
	print("[VIPDoor-日志] 玩家是否成功付款: " .. tostring(wasPurchased))
	
	if promptPlayer == player and gamePassId == VIP_GAMEPASS_ID then
		if wasPurchased then
			print("[VIPDoor-日志] 判定：这是一次全新的成功购买，立即开门！")
			enableVIPDoors()
		else
			warn("[VIPDoor-警告] 判定：玩家取消了购买，或者玩家本身就已经拥有该物品(没扣钱)。")
			-- 如果玩家已经拥有，Roblox会把 wasPurchased 设为 false。
			-- 我们补一刀，再次查一下是不是因为本来就有
			local hasPass = MarketplaceService:UserOwnsGamePassAsync(player.UserId, VIP_GAMEPASS_ID)
			if hasPass then
				print("[VIPDoor-补救] 确认玩家其实早就拥有了，立刻开门！")
				enableVIPDoors()
			end
		end
	end
end)