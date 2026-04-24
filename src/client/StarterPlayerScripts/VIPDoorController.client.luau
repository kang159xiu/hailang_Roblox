-- ==========================================
-- 脚本位置：StarterPlayerScripts.VIPDoorController.client.luau
-- 功能：【正式版】处理 VIP Part 穿透逻辑及购买后立即生效
-- ==========================================

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local VIP_GAMEPASS_ID = 1806675692

local isVIP = false -- [新增] 记录当前玩家是否已拥有 VIP 权限
local promptDebounce = false -- [新增] 防抖控制，避免连续触碰导致的弹窗轰炸

-- [新增] 递归函数：为零件及子零件绑定触碰事件，未拥有 VIP 时弹出购买界面
local function bindPurchasePromptRecursive(instance)
	if instance:IsA("BasePart") then
		instance.Touched:Connect(function(hit)
			if isVIP then return end -- 如果已经拥有VIP，不触发弹窗

			local character = player.Character
			-- 确认碰到的物体属于本地玩家的角色
			if character and hit:IsDescendantOf(character) then
				if not promptDebounce then
					promptDebounce = true
					-- [新增] 触发 Roblox 官方购买提示界面
					MarketplaceService:PromptGamePassPurchase(player, VIP_GAMEPASS_ID)
					task.wait(2.5) -- [新增] 2.5秒防抖冷却，避免多次碰撞疯狂弹窗
					promptDebounce = false
				end
			end
		end)
	end
	for _, child in ipairs(instance:GetChildren()) do
		bindPurchasePromptRecursive(child)
	end
end

-- [新增] 独立初始化触碰监听，游戏启动时立刻挂载
local function initVIPTouchPrompts()
	-- 1. 按标签查找
	for _, obj in ipairs(CollectionService:GetTagged("VIPPart")) do
		bindPurchasePromptRecursive(obj)
	end
	-- 2. 按名字查找
	for _, desc in ipairs(workspace:GetDescendants()) do
		if desc.Name == "VIP_part" or desc.Name == "VIPPart" then
			bindPurchasePromptRecursive(desc)
		end
	end
	-- 3. 监听动态生成的 VIP 门
	CollectionService:GetInstanceAddedSignal("VIPPart"):Connect(function(obj)
		bindPurchasePromptRecursive(obj)
	end)
end

-- 立即挂载所有触碰事件
initVIPTouchPrompts()

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
		isVIP = true -- [修改] 同步状态为已拥有，阻断后续的触碰购买弹窗
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
			isVIP = true -- [修改] 购买成功，更新全局 VIP 状态
			enableVIPDoors()
		else
			-- 如果玩家之前买过，但点了购买按钮，Roblox 会提示"已拥有"且 wasPurchased 为 false
			-- 这里做个二次确认，如果确实拥有，也给开门
			local success, hasPass = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, VIP_GAMEPASS_ID)
			end)
			if success and hasPass then
				isVIP = true -- [修改] 二次验证成功，更新全局 VIP 状态
				enableVIPDoors()
			end
		end
	end
end)