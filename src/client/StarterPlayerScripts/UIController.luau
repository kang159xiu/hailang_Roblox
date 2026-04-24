--
local UIController = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- [新增内容] 引入社交服务用于弹出邀请界面
local SocialService = game:GetService("SocialService") 
-- [新增内容] 引入市场服务用于处理通行证购买
local MarketplaceService = game:GetService("MarketplaceService")

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
-- [修改内容] 引用金币增减提示的 TextLabel
local addGoldUI = mainGui:WaitForChild("GoldFrame"):WaitForChild("addGoldUI") :: TextLabel
local monsterInventoryWindow = mainGui:WaitForChild("MonsterInventoryWindow") :: Frame
local monsterInventoryList = monsterInventoryWindow:WaitForChild("List") :: ScrollingFrame
local rowTemplate = monsterInventoryWindow:WaitForChild("RowTemplate") :: ImageButton

-- [修改内容] 引用删除数据按钮
local deleteBtn = mainGui:WaitForChild("delete") :: ImageButton
-- [修改内容] 引用清空数据的远程事件
local requestClearPlayerData = remotes:WaitForChild("RequestClearPlayerData") :: RemoteEvent

-- [修改内容] 新增武器列表、武器模板和选项卡按钮的变量引用
local weaponList = monsterInventoryWindow:WaitForChild("weaponList") :: ScrollingFrame
local weaponTemplate = monsterInventoryWindow:WaitForChild("WeaponTemplate") :: GuiObject
local monsterTabBtn = monsterInventoryWindow:WaitForChild("monster") :: GuiButton
local weaponTabBtn = monsterInventoryWindow:WaitForChild("weapon") :: GuiButton

-- [终极修复] 使用递归查找(true)，瞬间搜遍整个UI层级，彻底消灭16秒的假死卡顿！
local inviteButton = mainGui:FindFirstChild("ImageButton_邀请", true) :: ImageButton 
local vipButton = mainGui:FindFirstChild("ImageButton_VIP", true) :: ImageButton 
local backpackButton = mainGui:FindFirstChild("BackpackButton", true)
-- [终极修复] 先声明攻击按钮变量，但不立刻查找，避免由于 UI 加载延迟导致永远为 nil
local attackButton: ImageButton? = nil

-- [修改内容] 必须加上 true 开启深层递归查找，否则移入 List 文件夹后代码将无法定位该按钮
local speedToggleButton = mainGui:FindFirstChild("ImageButton_正常速度", true) :: ImageButton?
local normalSpeedBgOn = speedToggleButton and speedToggleButton:FindFirstChild("开启常速背景") :: ImageLabel?
local normalSpeedBgOff = speedToggleButton and speedToggleButton:FindFirstChild("关闭常速背景") :: ImageLabel?
local speedToggleText = speedToggleButton and speedToggleButton:FindFirstChild("开/关速度状态") :: TextLabel?
local isNormalSpeedActive = false -- 默认状态为 false（即默认使用升级后的加速状态）

-- [修改内容] 引用您预设的商店 UI
local playerGui = player:WaitForChild("PlayerGui")
local shopsGui = playerGui:WaitForChild("ShopsUI")

-- 升级商店引用
local upgradeWindow = shopsGui:WaitForChild("升级商店Window")
local upgradeCloseBtn = upgradeWindow:WaitForChild("Close") :: GuiButton
local upgradeTemplate = upgradeWindow:WaitForChild("RowTemplate") :: GuiObject
local upgradeList = upgradeWindow:FindFirstChild("List") or upgradeWindow
upgradeTemplate.Visible = false -- 隐藏原始模板，防止它作为实体显示出来

-- [修改内容] 武器商店引用
local weaponWindow = shopsGui:FindFirstChild("武器商店Window")
local weaponShopList = weaponWindow and weaponWindow:FindFirstChild("List")
local weaponShopTemplate = weaponWindow and weaponWindow:FindFirstChild("单个武器背景")
if weaponShopTemplate then weaponShopTemplate.Visible = false end -- 隐藏原始模板

if weaponWindow then
	local weaponCloseBtn = weaponWindow:FindFirstChild("Close")
	if weaponCloseBtn and weaponCloseBtn:IsA("GuiButton") then
		weaponCloseBtn.Activated:Connect(function()
			weaponWindow.Visible = false
		end)
	end
end

-- 清理旧的克隆行
local function clearUpgradeRows()
	for _, child in ipairs(upgradeList:GetChildren()) do
		-- 只删除克隆出来的组件，保留模板和 Layout 排版组件
		if child:IsA("GuiObject") and child.Name ~= "RowTemplate" and not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end
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

-- [新增内容] 提示消息显示的计数器，防止多个提示动画冲突
local toastHideCounter = 0 

local function showToast(text: string)
	-- 保留原本的控制台打印，方便调试
	print("[系统提示]:", text) 
	
	-- 获取 UI 控件
	local toastPanel = mainGui:FindFirstChild("提示消息")
	if not toastPanel then return end
	
	local iconLabel = toastPanel:FindFirstChild("icon") :: ImageLabel?
	local messageLabel = toastPanel:FindFirstChild("massage") :: TextLabel? 
	
	-- 1. 设置文字
	if messageLabel then
		messageLabel.Text = text
	end
	
	-- 2. 匹配 Config 中的图标
	local matchedIconId = nil
	-- 确保 Config.TOAST_ICONS 存在（需要你在 Config.luau 中提前加好）
	if Config.TOAST_ICONS then
		for keyword, imageId in pairs(Config.TOAST_ICONS) do
			if string.find(text, keyword) then
				matchedIconId = imageId
				break 
			end
		end
	end
	
	-- 3. 控制图标显示
	if iconLabel then
		if matchedIconId and matchedIconId ~= "" and matchedIconId ~= "rbxassetid://0" then
			iconLabel.Image = matchedIconId
			iconLabel.Visible = true
		else
			iconLabel.Visible = false 
		end
	end
	
	-- 4. 弹窗显示与计时隐藏逻辑
	toastHideCounter += 1
	local currentCounter = toastHideCounter
	
	toastPanel.Visible = true
	
	task.spawn(function()
		task.wait(2.5) -- 停留2.5秒后自动隐藏
		if toastHideCounter == currentCounter then
			toastPanel.Visible = false
		end
	end)
end



local function loadViewportFromScene(targetContainer: GuiObject, modelSource: Instance?)
	if not modelSource then return end
	
	-- 1. 清理格子里旧的 UI 元素
	targetContainer:ClearAllChildren()

	-- 2. 自动创建 ViewportFrame
	local viewport = Instance.new("ViewportFrame")
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	-- 增加环境光，防止展示出来的模型变黑
	viewport.Ambient = Color3.fromRGB(150, 150, 150)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-1, -1, -2)
	viewport.Parent = targetContainer

	-- 3. 克隆场景里的模型并放入 Viewport
	local clone = modelSource:Clone()
	if clone:IsA("Model") then
		-- 将模型移动到虚拟空间的原点
		clone:PivotTo(CFrame.new(0, 0, 0))
	elseif clone:IsA("BasePart") then
		clone.CFrame = CFrame.new(0, 0, 0)
	end
	clone.Parent = viewport

	-- 4. 自动创建摄像机
	local camera = Instance.new("Camera")
	viewport.CurrentCamera = camera
	camera.Parent = viewport

	-- 5. 核心算法：计算模型大小，自动将摄像机拉到完美距离
	local cf, size
	if clone:IsA("Model") then
		cf, size = clone:GetBoundingBox()
	else
		cf = clone.CFrame
		size = clone.Size
	end

	-- 找出模型最长的一边
	local maxDim = math.max(size.X, size.Y, size.Z)
	if maxDim == 0 then maxDim = 2 end -- 兜底防错

	-- 根据视场角(FOV)计算刚好能看全模型的距离，乘 1.2 是为了留一点边缘空白
	local distance = (maxDim / 2) / math.tan(math.rad(camera.FieldOfView) / 2) * 1.2
	
	-- 将摄像机放在模型的斜右前方，并让它看向模型的中心点
	local camPos = cf.Position + Vector3.new(distance * 0.6, distance * 0.4, distance * 0.8)
	camera.CFrame = CFrame.lookAt(camPos, cf.Position)
end


-- =====================
-- [修改内容] 升级商店逻辑
-- =====================
-- [修改内容] 融合了你优秀的表驱动循环逻辑，以及精准的 UI 模板文本分离映射
local function refreshUpgradeShopUI()
	-- 1. 清理旧条目
	for _, ch in ipairs(upgradeList:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "RowTemplate" and not ch:IsA("UILayout") then
			ch:Destroy()
		end
	end

	-- 2. 定义升级类型
	local upgradeTypes = {
		{ name = "升级攻击", type = "Attack", getLv = "AttackLevel" },
		{ name = "升级速度", type = "Speed", getLv = "SpeedLevel" },
		{ name = "升级血量", type = "Health", getLv = "HealthLevel" },
		{ name = "升级背包容量", type = "Carry", getLv = "CarryLevel" },
	}

	for _, info in ipairs(upgradeTypes) do
		local currentLv = player:GetAttribute(info.getLv) or 0
		local nextLv = currentLv + 1
		
		-- 获取花费和增加数值字符串
		local cost = 0
		local incrementText = ""
		local isMaxed = false

		if info.type == "Attack" then
			cost = Config.GetAttackUpgradeCost and Config.GetAttackUpgradeCost(nextLv) or 0
			incrementText = string.format("+%d 攻击力", Config.ATTACK_UPGRADE_ADD or 10)
		elseif info.type == "Speed" then
			cost = Config.GetSpeedUpgradeCost and Config.GetSpeedUpgradeCost(nextLv) or 0
			incrementText = string.format("+%d 速度", Config.WALK_SPEED_PER_UPGRADE or 2)
		elseif info.type == "Health" then
			cost = Config.GetHealthUpgradeCost and Config.GetHealthUpgradeCost(nextLv) or 0
			incrementText = string.format("+%d 最大血量", Config.HEALTH_PER_UPGRADE or 100)
		elseif info.type == "Carry" then
			local nextCost = Config.GetCarryUpgradeCost and Config.GetCarryUpgradeCost(nextLv)
			if nextCost == nil then
				isMaxed = true -- 如果获取不到下一级价格，说明满了
			else
				cost = nextCost
				local currentCarry = Config.GetCarryMax and Config.GetCarryMax(currentLv) or (currentLv + 1)
				local nextCarry = Config.GetCarryMax and Config.GetCarryMax(nextLv) or (nextLv + 1)
				incrementText = string.format("可携带: %d → %d", currentCarry, nextCarry)
			end
		end

		-- 3. 克隆模板并设置
		-- 注意：如果你的模板变量叫 upgradeRowTemplate，请把这里的 upgradeTemplate 换成你实际的变量名
		local row = upgradeTemplate:Clone() 
		row.Name = info.type .. "Row"
		row.Visible = true
		row.Parent = upgradeList

		-- A. 赋值：升级目标文本框
		local targetLabel = row:FindFirstChild("升级目标")
		if targetLabel and targetLabel:IsA("TextLabel") then
			targetLabel.Text = info.name
		end

		-- B. 赋值：花费与增加数值文本框
		local costInfoLabel = row:FindFirstChild("花费+增加数值")
		if costInfoLabel and costInfoLabel:IsA("TextLabel") then
			if isMaxed then
				costInfoLabel.Text = "已满级"
			else
				costInfoLabel.Text = string.format("花费:%s   %s", formatNumberShort(cost), incrementText)
			end
		end

		-- C. 绑定：升级按钮
		local upBtn = row:FindFirstChild("升级按钮")
		if upBtn and upBtn:IsA("GuiButton") then
			if isMaxed then
				if upBtn:IsA("ImageButton") then
					upBtn.ImageTransparency = 0.5 -- 满级变灰
				end
				upBtn.Interactable = false -- 禁用点击 (Roblox 新版按钮禁用属性)
				upBtn.Active = false
			else
				if upBtn:IsA("ImageButton") then
					upBtn.ImageTransparency = 0
				end
				upBtn.Interactable = true
				upBtn.Activated:Connect(function()
					-- 注意：确保你的 requestPurchaseUpgrade 变量在文件顶部有定义
					requestPurchaseUpgrade:FireServer(info.type)
				end)
			end
		end
	end
end
-- =====================
-- 怪物背包逻辑
-- =====================
local function refreshMonsterInventoryUI(payload)
	for _, ch in ipairs(monsterInventoryList:GetChildren()) do
		-- [修改内容] 改为判断 UILayout，防止 UIGridLayout 等其他布局组件被误删
		if ch:IsA("GuiObject") and ch ~= rowTemplate and not ch:IsA("UILayout") then ch:Destroy() end
	end

	-- [修改内容] 精确定位到 Workspace 下的 "Monster image" 文件夹
	local monsterFolder = workspace:FindFirstChild("Monster image")

	for i, it in ipairs(payload or {}) do
		local row = rowTemplate:Clone()
		row.Visible = true
		row.Parent = monsterInventoryList
		
		local label = row:FindFirstChild("Label")
		if label and label:IsA("TextLabel") then
			label.Text = string.format("怪Lv%d  价值:%s  +%s/s", it.MonsterLevel, formatNumberShort(it.Value), formatNumberShort(it.GoldPerSec))
		end
		
		-- [修改内容] 根据命名规则 "怪物形象01-30" 匹配加载
		local imageContainer = row:FindFirstChild("ImageLabel")
		if imageContainer and monsterFolder then
			local iconName = string.format("怪物形象%02d", it.MonsterLevel)
			local model = monsterFolder:FindFirstChild(iconName)
			loadViewportFromScene(imageContainer, model)
		end

		local takeOutBtn = row:FindFirstChild("拿出按钮")
		if takeOutBtn and takeOutBtn:IsA("GuiButton") then
			takeOutBtn.Activated:Connect(function() requestTakeOutMonsterItem:FireServer(it.ItemId) end)
		end
	end
end


-- =====================
-- 武器背包逻辑
-- =====================
local function refreshWeaponInventoryUI()
	for _, ch in ipairs(weaponList:GetChildren()) do
		-- [修改内容] 改为判断 UILayout
		if ch:IsA("GuiObject") and ch ~= weaponTemplate and not ch:IsA("UILayout") then ch:Destroy() end
	end

	local maxWeaponLevel = player:GetAttribute("WeaponLevel") or 1
	local equippedWeapon = player:GetAttribute("EquippedWeaponLevel") or 1
	
	-- [修改内容] 精确定位到 Workspace 下的 "weapon" 文件夹
	local weaponFolder = workspace:FindFirstChild("weapon")

	for i = 1, maxWeaponLevel do
		local row = weaponTemplate:Clone()
		row.Visible = true
		row.Parent = weaponList
		
		local label = row:FindFirstChild("Label")
		if label and label:IsA("TextLabel") then
			label.Text = Config.WEAPON_NAME_BY_LEVEL[i] or ("武器" .. i)
		end
		
		-- [修改内容] 根据命名规则 "武器01-20" 匹配加载
		local imageContainer = row:FindFirstChild("ImageLabel")
		if imageContainer and weaponFolder then
			local iconName = string.format("武器%02d", i)
			local model = weaponFolder:FindFirstChild(iconName)
			loadViewportFromScene(imageContainer, model)
		end

		local equipBtn = row:FindFirstChild("装备按钮")
		if equipBtn and equipBtn:IsA("GuiButton") then
			local btnText = equipBtn:FindFirstChild("装备text")
			if btnText and btnText:IsA("TextLabel") then
				if i == equippedWeapon then
					btnText.Text = "已装备"
				else
					btnText.Text = "装备武器"
					equipBtn.Activated:Connect(function()
						requestEquipWeapon:FireServer(i)
					end)
				end
			end
		end
	end
end

-- =====================
-- [修改内容] 选项卡切换逻辑
-- =====================
local function switchInventoryTab(tabName: string)
	if tabName == "monster" then
		monsterInventoryList.Visible = true
		weaponList.Visible = false
	elseif tabName == "weapon" then
		monsterInventoryList.Visible = false
		weaponList.Visible = true
		refreshWeaponInventoryUI()
	end
end



-- =====================
-- [最终版] 金币爆点飞行动效逻辑
-- =====================
local TweenService = game:GetService("TweenService")
local rng = Random.new()

local function playGoldFlyingAnimation(increaseAmount: number)
	local playerGui = player:WaitForChild("PlayerGui")
	local sucaiGui = playerGui:FindFirstChild("sucai")
	if not sucaiGui then return end
	local moneyFrame = sucaiGui:FindFirstChild("money_Frame")
	if not moneyFrame then return end
	local moneyImageSource = moneyFrame:FindFirstChild("money_image")
	if not moneyImageSource then return end

	local fxContainer = mainGui:FindFirstChild("FXContainer")
	if not fxContainer then
		fxContainer = Instance.new("Frame")
		fxContainer.Name = "FXContainer"
		fxContainer.BackgroundTransparency = 1
		fxContainer.Size = UDim2.fromScale(1, 1)
		fxContainer.ZIndex = 100 
		fxContainer.Parent = mainGui
	end

	-- 动态计算生成数量: 基础10个，每多100金币多生成1个，上限20个
	local count = math.clamp(10 + math.floor(increaseAmount / 100), 10, 20)

	for i = 1, count do
		task.spawn(function()
			local coin = moneyImageSource:Clone()
			coin.Visible = true -- 强制显示！
			coin.Size = UDim2.fromOffset(50, 50) 
			coin.AnchorPoint = Vector2.new(0.5, 0.5)
			coin.Position = UDim2.fromScale(0.5, 0.5) 
			coin.Parent = fxContainer

			-- 散开动画
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = rng:NextNumber(50, 400)
			local scatterPos = UDim2.new(0.5, math.cos(angle) * radius, 0.5, math.sin(angle) * radius)
			
			local scatterTween = TweenService:Create(coin, TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
				Position = scatterPos
			})
			scatterTween:Play()
			scatterTween.Completed:Wait() 

			-- 飞向目标
			local targetAbsPos = goldLabel.AbsolutePosition + (goldLabel.AbsoluteSize / 2)
			local flyTween = TweenService:Create(coin, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.fromOffset(targetAbsPos.X, targetAbsPos.Y)
			})
			flyTween:Play()
			flyTween.Completed:Wait() 

			coin:Destroy()
		end)
		-- 极短延迟，让金币有先有后
		task.wait(rng:NextNumber(0, 0.02))
	end
end

-- 添加金币增减文字动画逻辑
local function playGoldTextAnimation(difference: number)
	if difference == 0 or not addGoldUI then return end
	
	local textClone = addGoldUI:Clone()
	textClone.Visible = true
	textClone.Parent = addGoldUI.Parent
	
	if difference > 0 then
		textClone.Text = "+" .. formatNumberShort(difference)
		textClone.TextColor3 = Color3.fromRGB(238, 255, 0)
	else
		textClone.Text = "-" .. formatNumberShort(math.abs(difference))
		textClone.TextColor3 = Color3.fromRGB(255, 85, 85)
	end
	
	textClone.TextTransparency = 0
	if textClone:FindFirstChild("UIStroke") then
		textClone.UIStroke.Transparency = 0
	end
	
	local targetPos = textClone.Position - UDim2.fromOffset(0, 30)
	local tweenInfo = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(textClone, tweenInfo, {
		Position = targetPos,
		TextTransparency = 1
	})
	
	if textClone:FindFirstChild("UIStroke") then
		local strokeTween = TweenService:Create(textClone.UIStroke, tweenInfo, {
			Transparency = 1
		})
		strokeTween:Play()
	end
	
	tween:Play()
	tween.Completed:Connect(function()
		textClone:Destroy()
	end)
end

-- =====================
-- 武器商店渲染逻辑 
-- =====================
local function refreshWeaponShopUI()
	if not weaponShopList or not weaponShopTemplate then return end

	for _, ch in ipairs(weaponShopList:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "单个武器背景" and not ch:IsA("UILayout") then
			ch:Destroy()
		end
	end

	local maxWeaponLevel = player:GetAttribute("WeaponLevel") or 1
	local equippedWeapon = player:GetAttribute("EquippedWeaponLevel") or 1
	local weaponFolder = workspace:FindFirstChild("weapon")

	for i = 1, 20 do
		local price = Config.WEAPON_PRICE_BY_LEVEL and Config.WEAPON_PRICE_BY_LEVEL[i]
		local attack = Config.WEAPON_ATTACK_BY_LEVEL and Config.WEAPON_ATTACK_BY_LEVEL[i]
		if not price and i > 1 then continue end

		local row = weaponShopTemplate:Clone()
		row.Name = "WeaponShopRow_" .. i
		row.Visible = true
		row.Parent = weaponShopList

		local nameLabel = row:FindFirstChild("武器名称")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = Config.WEAPON_NAME_BY_LEVEL and Config.WEAPON_NAME_BY_LEVEL[i] or ("武器" .. i)
		end

		local infoLabel = row:FindFirstChild("武器价格/武器攻击力")
		if infoLabel and infoLabel:IsA("TextLabel") then
			infoLabel.Text = string.format("价格: %s   攻击力: +%s", formatNumberShort(price or 0), formatNumberShort(attack or 0))
		end

		local imageContainer = row:FindFirstChild("武器形象")
		if imageContainer and weaponFolder then
			local iconName = string.format("武器%02d", i)
			local model = weaponFolder:FindFirstChild(iconName)
			if model then
				loadViewportFromScene(imageContainer, model)
			end
		end

		local actionFrame = row:FindFirstChild("购买UIFrame")
		local btn = actionFrame and actionFrame:FindFirstChild("未购买/购买/装备")
		
		if btn and btn:IsA("GuiButton") then
			if i > maxWeaponLevel + 1 then
				btn.Text = "未解锁"
				btn.Interactable = false  
				btn.Active = false
			elseif i == maxWeaponLevel + 1 then
				btn.Text = "购买"
				btn.Interactable = true
				btn.Active = true
				btn.Activated:Connect(function()
					requestPurchaseWeapon:FireServer(i)
				end)
			elseif i <= maxWeaponLevel then
				if i == equippedWeapon then
					btn.Text = "已装备"
					btn.Interactable = false
					btn.Active = false
				else
					btn.Text = "装备"
					btn.Interactable = true
					btn.Active = true
					btn.Activated:Connect(function()
						requestEquipWeapon:FireServer(i)
					end)
				end
			end
		else
			warn("[UIController] 未在 购买UIFrame 中找到按钮组件！")
		end
	end

	task.defer(function()
		if weaponShopList:IsA("ScrollingFrame") then
			weaponShopList.AutomaticCanvasSize = Enum.AutomaticSize.Y
			local gridLayout = weaponShopList:FindFirstChildWhichIsA("UIGridLayout")
			if gridLayout then
				weaponShopList.CanvasSize = UDim2.fromOffset(0, gridLayout.AbsoluteContentSize.Y + 20)
			end
		end
	end)
end

function UIController.Init() 
	if rowTemplate then rowTemplate.Visible = false end
	if weaponTemplate then weaponTemplate.Visible = false end

	if monsterInventoryList then
		monsterInventoryList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		monsterInventoryList.CanvasSize = UDim2.new(0, 0, 0, 0)
	end
	if weaponList then
		weaponList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		weaponList.CanvasSize = UDim2.new(0, 0, 0, 0)
	end

	-- 1. 金币同步与飞行动效触发 (纯净版)
	local lastGold = player:GetAttribute("Gold") or 0
	goldLabel.Text = formatNumberShort(lastGold)
	
	if addGoldUI then addGoldUI.Visible = false end
	
	local function onGoldChanged()
		local currentGold = player:GetAttribute("Gold") or 0
		goldLabel.Text = formatNumberShort(currentGold)
		local difference = currentGold - lastGold
		
		if difference ~= 0 then
			playGoldTextAnimation(difference)
		end
		if currentGold > lastGold then
			playGoldFlyingAnimation(difference)
		end
		lastGold = currentGold
	end
	player:GetAttributeChangedSignal("Gold"):Connect(onGoldChanged)

	-- 2. Toast 监听
	toastRemote.OnClientEvent:Connect(showToast)

	-- 3. 怪物背包同步
	syncMonsterInventory.OnClientEvent:Connect(function(payload) refreshMonsterInventoryUI(payload) end)

	-- 4. 按钮事件绑定
	if backpackButton then
		backpackButton.Activated:Connect(function() 
			local newState = not monsterInventoryWindow.Visible
			monsterInventoryWindow.Visible = newState
			if newState then switchInventoryTab("monster") end
		end)
	end

	if monsterTabBtn then monsterTabBtn.Activated:Connect(function() switchInventoryTab("monster") end) end
	if weaponTabBtn then weaponTabBtn.Activated:Connect(function() switchInventoryTab("weapon") end) end

	player:GetAttributeChangedSignal("EquippedWeaponLevel"):Connect(function()
		if monsterInventoryWindow.Visible and weaponList.Visible then
			refreshWeaponInventoryUI()
		end
	end)

	-- 5. 初始化商店
	if not shopsGui then
		shopsGui = Instance.new("ScreenGui")
		shopsGui.Name = "ShopsGui"
		shopsGui.Parent = playerGui
	end

	openWeaponShopUI.OnClientEvent:Connect(function()
		if weaponWindow then
			weaponWindow.Visible = true
			refreshWeaponShopUI() 
		end
	end)

	player:GetAttributeChangedSignal("WeaponLevel"):Connect(function()
		if weaponWindow and weaponWindow.Visible then refreshWeaponShopUI() end
	end)
	player:GetAttributeChangedSignal("EquippedWeaponLevel"):Connect(function()
		if weaponWindow and weaponWindow.Visible then refreshWeaponShopUI() end
	end)

	openUpgradeShopUI.OnClientEvent:Connect(function()
		if upgradeWindow then
			upgradeWindow.Visible = true
			refreshUpgradeShopUI()
		end
	end)

	if upgradeCloseBtn then
		upgradeCloseBtn.Activated:Connect(function() upgradeWindow.Visible = false end)
	end

	local attributes = {"AttackLevel", "SpeedLevel", "HealthLevel", "CarryLevel"}
	for _, attr in ipairs(attributes) do
		player:GetAttributeChangedSignal(attr):Connect(function()
			if upgradeWindow.Visible then refreshUpgradeShopUI() end
		end)
	end

	-- 删除数据按钮逻辑
	local safeDeleteBtn = mainGui:FindFirstChild("delete", true)
	local safeRequestClear = remotes:WaitForChild("RequestClearPlayerData", 5)

	if safeDeleteBtn and safeRequestClear then
		safeDeleteBtn.Activated:Connect(function()
			safeRequestClear:FireServer()
		end)
	end

	-- 邀请按钮逻辑
	if inviteButton then
		inviteButton.Activated:Connect(function()
			SocialService:PromptGameInvite(player)
		end)
	end

	-- VIP 按钮逻辑
	if vipButton then
		vipButton.Activated:Connect(function()
			MarketplaceService:PromptGamePassPurchase(player, 1806675692)
		end)
	end

	-- [终极修复] 攻击按钮逻辑（加入强力异步等待机制，100% 确保找到加载缓慢的按钮）
	task.spawn(function()
		-- 优先使用 WaitForChild 死等 5 秒，如果由于层级深没拿到，再使用递归全局寻找
		local btn = mainGui:WaitForChild("ImageButton_攻击", 5) or mainGui:FindFirstChild("ImageButton_攻击", true)
		
		-- 如果 5 秒后网络还没把按钮发过来，开启后台无限扫描直到它出现为止
		if not btn then
			warn("[UIController] 5秒内未找到 ImageButton_攻击，正在后台持续扫描...")
			while not btn do
				task.wait(1)
				btn = mainGui:FindFirstChild("ImageButton_攻击", true)
			end
		end
		
		print("[UIController] ✅ 成功捕获到攻击按钮，已正式接管逻辑！")
		attackButton = btn :: ImageButton
		attackButton.Visible = false -- 初始状态强制隐藏
		
		attackButton.Activated:Connect(function()
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not hum then return end

			local equippedTool = char:FindFirstChildOfClass("Tool")
			if equippedTool then
				-- 已经手持武器则直接挥砍
				equippedTool:Activate()
			else
				-- 未手持武器则自动找到背包的武器并装备
				local backpackTool = player.Backpack:FindFirstChildOfClass("Tool")
				if backpackTool then
					hum:EquipTool(backpackTool)
				end
			end
		end)
	end)


	-- 正常速度切换按钮逻辑
	if speedToggleButton then
		local function applyCurrentSpeed()
			local char = player.Character
			if not char then return end
			local humanoid = char:FindFirstChildWhichIsA("Humanoid")
			if not humanoid then return end

			if isNormalSpeedActive then
				humanoid.WalkSpeed = Config.WALK_SPEED_BASE or 20
			else
				local speedLevel = player:GetAttribute("SpeedLevel") or 0
				humanoid.WalkSpeed = (Config.WALK_SPEED_BASE or 20) + (speedLevel * (Config.WALK_SPEED_PER_UPGRADE or 1))
			end
		end

		local function updateSpeedUI()
			if isNormalSpeedActive then
				if normalSpeedBgOn then normalSpeedBgOn.Visible = true end
				if normalSpeedBgOff then normalSpeedBgOff.Visible = false end
				if speedToggleText then speedToggleText.Text = "开启加速" end
			else
				if normalSpeedBgOn then normalSpeedBgOn.Visible = false end
				if normalSpeedBgOff then normalSpeedBgOff.Visible = true end
				if speedToggleText then speedToggleText.Text = "关闭加速" end
			end
		end

		updateSpeedUI()

		speedToggleButton.Activated:Connect(function()
			isNormalSpeedActive = not isNormalSpeedActive 
			updateSpeedUI()
			applyCurrentSpeed()
		end)

		player.CharacterAdded:Connect(function(char)
			char:WaitForChild("Humanoid", 5)
			applyCurrentSpeed()
		end)

		player:GetAttributeChangedSignal("SpeedLevel"):Connect(function() applyCurrentSpeed() end)
	end

	print("[UIController] 2D UI 逻辑加载完毕！")
end

-- [新增内容] 暴露设置攻击按钮显示状态的方法给 Client.client.luau 调用
function UIController.SetAttackButtonVisible(visible: boolean)
	if attackButton then
		if attackButton.Visible ~= visible then
			attackButton.Visible = visible
		end
	end
end



return UIController