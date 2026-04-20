--
local UIController = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")

-- 获取所有 UI 相关的 RemoteEvent
local toastRemote = remotes:WaitForChild("PushClientToast") :: RemoteEvent
local syncMonsterInventory = remotes:WaitForChild("SyncMonsterInventory") :: RemoteEvent
local requestTakeOutMonsterItem = remotes:WaitForChild("RequestTakeOutMonsterItem") :: RemoteEvent
local openWeaponShopUI = remotes:WaitForChild("OpenWeaponShopUI") :: RemoteEvent
local openUpgradeShopUI = remotes:WaitForChild("OpenUpgradeShopUI") :: RemoteEvent
local requestPurchaseWeapon = remotes:WaitForChild("RequestPurchaseWeapon") :: RemoteEvent
local requestEquipWeapon = remotes:WaitForChild("RequestEquipWeapon") :: RemoteEvent
local requestPurchaseUpgrade = remotes:WaitForChild("RequestPurchaseUpgrade") :: RemoteEvent
local requestClearPlayerData = remotes:WaitForChild("RequestClearPlayerData") :: RemoteEvent

-- =====================
-- 基础 UI 变量
-- =====================
local mainGui = player:WaitForChild("PlayerGui"):WaitForChild("MainUI") :: ScreenGui
local goldLabel = mainGui:WaitForChild("GoldFrame"):WaitForChild("GoldLabel") :: TextLabel
local monsterInventoryWindow = mainGui:WaitForChild("MonsterInventoryWindow") :: Frame
local monsterInventoryList = monsterInventoryWindow:WaitForChild("List") :: ScrollingFrame
local rowTemplate = monsterInventoryWindow:WaitForChild("RowTemplate") :: ImageButton
local backpackButton = mainGui:WaitForChild("BackpackButton", 10)

local shopsGui: ScreenGui
local weaponWindow: Frame
local upgradeWindow: Frame

-- =====================
-- 辅助函数
-- =====================
local function formatNumberShort(n: number): string
	local abs = math.abs(n)
	local units = {{ 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e4, "w" }}
	for _, u in ipairs(units) do
		local base, suffix = u[1], u[2]
		if abs >= base then
			local v = n / base
			local s = (math.abs(v) >= 100) and string.format("%.0f", v) or (math.abs(v) >= 10 and string.format("%.1f", v) or string.format("%.2f", v))
			return s:gsub("%.?0+$", "") .. suffix
		end
	end
	return tostring(math.floor(n))
end

local function showToast(text: string)
	print("[系统提示]:", text) -- [修改内容] 保持原有的静默输出逻辑
end

-- =====================
-- 怪物背包逻辑
-- =====================
local function refreshMonsterInventoryUI(payload)
	for _, ch in ipairs(monsterInventoryList:GetChildren()) do
		if ch:IsA("GuiObject") and ch ~= rowTemplate and not ch:IsA("UIListLayout") then ch:Destroy() end
	end

	for i, it in ipairs(payload or {}) do
		local row = rowTemplate:Clone()
		row.Visible = true
		row.Parent = monsterInventoryList
		local label = row:FindFirstChild("Label")
		if label and label:IsA("TextLabel") then
			label.Text = string.format("怪Lv%d  价值:%s  +%s/s", it.MonsterLevel, formatNumberShort(it.Value), formatNumberShort(it.GoldPerSec))
		end
		local takeOutBtn = row:FindFirstChild("拿出按钮")
		if takeOutBtn and takeOutBtn:IsA("GuiButton") then
			takeOutBtn.Activated:Connect(function() requestTakeOutMonsterItem:FireServer(it.ItemId) end)
		end
	end
end

-- =====================
-- 商店 UI 逻辑 (武器/升级)
-- =====================
local function createWindow(titleText: string)
	local frame = Instance.new("Frame")
	frame.Name = titleText .. "Window"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(620, 420)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.Visible = false
	frame.Parent = shopsGui
	-- ... (此处省略部分 UI 创建代码，实际应包含 Title 和 Close 按钮逻辑)
	return frame
end

-- =====================
-- [修改内容] 金币爆点飞行动效逻辑
-- =====================
local TweenService = game:GetService("TweenService")
local rng = Random.new()

local function playGoldFlyingAnimation(increaseAmount: number)
	local playerGui = player:WaitForChild("PlayerGui")
	
	-- 1. 获取用户指定的素材图片
	local sucaiGui = playerGui:FindFirstChild("sucai")
	if not sucaiGui then return end
	local moneyFrame = sucaiGui:FindFirstChild("money_Frame")
	if not moneyFrame then return end
	local moneyImageSource = moneyFrame:FindFirstChild("money_image")
	if not moneyImageSource then return end

	-- 2. 创建一个全局特效容器，保证在屏幕最上层，防止被其他UI裁剪
	local fxContainer = mainGui:FindFirstChild("FXContainer")
	if not fxContainer then
		fxContainer = Instance.new("Frame")
		fxContainer.Name = "FXContainer"
		fxContainer.BackgroundTransparency = 1
		fxContainer.Size = UDim2.fromScale(1, 1)
		fxContainer.ZIndex = 100 -- 置于顶层
		fxContainer.Parent = mainGui
	end

	-- 3. 动态计算生成数量: 基础10个，每多100金币多生成1个，上限20个
	local count = math.clamp(10 + math.floor(increaseAmount / 100), 10, 20)

	for i = 1, count do
		task.spawn(function()
			-- 克隆金币UI
			local coin = moneyImageSource:Clone()
			
			-- [修改内容] 强制设置金币的绝对像素大小，例如宽 40，高 40。您可以根据实际观感调整这两个数值。
			coin.Size = UDim2.fromOffset(50, 50) 
			
			coin.AnchorPoint = Vector2.new(0.5, 0.5)
			coin.Position = UDim2.fromScale(0.5, 0.5) -- 初始从屏幕中心爆出
			coin.Parent = fxContainer

			-- 第一阶段：散开动画 (时间节奏: 0.3秒，半径: 50~200)
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = rng:NextNumber(50, 200)
			local scatterPos = UDim2.new(0.5, math.cos(angle) * radius, 0.5, math.sin(angle) * radius)
			
			local scatterTween = TweenService:Create(coin, TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
				Position = scatterPos
			})
			scatterTween:Play()
			scatterTween.Completed:Wait() -- 阻塞当前协程，等待0.3秒散开结束

			-- 第二阶段：飞向目标 (时间节奏: 0.4秒)
			-- 获取金币文本框在屏幕上的绝对中心位置
			local targetAbsPos = goldLabel.AbsolutePosition + (goldLabel.AbsoluteSize / 2)
			local flyTween = TweenService:Create(coin, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				-- 直接使用 Offset 精确锁定屏幕像素坐标
				Position = UDim2.fromOffset(targetAbsPos.X, targetAbsPos.Y)
			})
			flyTween:Play()
			flyTween.Completed:Wait() -- 阻塞当前协程，等待0.4秒飞行结束

			-- 动画完成，销毁克隆体
			coin:Destroy()
		end)
		
		-- [修改内容] 添加极短的随机延迟，让爆出的金币有先后的层次感
		task.wait(rng:NextNumber(0, 0.02))
	end
end


function UIController.Init() -- [修改内容] 暴露初始化接口供外部调用
	-- 1. [修改内容] 金币同步与飞行动效触发
	local lastGold = player:GetAttribute("Gold") or 0
	goldLabel.Text = formatNumberShort(lastGold)
	
	local function onGoldChanged()
		local currentGold = player:GetAttribute("Gold") or 0
		goldLabel.Text = formatNumberShort(currentGold)
		
		-- 判断是收获金币（增加）才播放动画
		if currentGold > lastGold then
			local increaseAmount = currentGold - lastGold
			playGoldFlyingAnimation(increaseAmount)
		end
		
		lastGold = currentGold
	end
	player:GetAttributeChangedSignal("Gold"):Connect(onGoldChanged)

	-- 2. Toast 监听
	toastRemote.OnClientEvent:Connect(showToast)

	-- 3. 怪物背包同步
	syncMonsterInventory.OnClientEvent:Connect(function(payload) refreshMonsterInventoryUI(payload) end)

	-- 4. 背包按钮开关
	if backpackButton then
		backpackButton.Activated:Connect(function() monsterInventoryWindow.Visible = not monsterInventoryWindow.Visible end)
	end

	-- 5. 初始化商店 (此处应包含原脚本中 openWeaponShopUI 等监听器)
	-- [逻辑流]：监听服务端事件 -> 显示对应的 Window -> 调用刷新函数渲染列表
    print("[UIController] 2D UI 逻辑已初始化")
end

return UIController