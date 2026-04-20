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

local backpackButton = mainGui:WaitForChild("BackpackButton", 10)

-- [修改内容] 引用您预设的商店 UI
local playerGui = player:WaitForChild("PlayerGui")
local shopsGui = player:WaitForChild("PlayerGui"):WaitForChild("ShopsUI")
local upgradeWindow = shopsGui:WaitForChild("升级商店Window")

local upgradeCloseBtn = upgradeWindow:WaitForChild("Close") :: GuiButton
local upgradeRowTemplate = upgradeWindow:WaitForChild("RowTemplate") :: ImageLabel
local upgradeList = upgradeWindow:FindFirstChild("List") or upgradeWindow

local upgradeTemplate = upgradeWindow:WaitForChild("RowTemplate")
upgradeTemplate.Visible = false -- 隐藏原始模板，防止它作为实体显示出来
-- 清理旧的克隆行
local function clearUpgradeRows()
	for _, child in ipairs(upgradeList:GetChildren()) do
		-- 只删除克隆出来的组件，保留模板和 Layout 排版组件
		if child:IsA("GuiObject") and child.Name ~= "RowTemplate" and not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

-- [修改内容] 纯模板化的生成逻辑，不再使用 Instance.new
local function buildUpgradeRow(titleText: string, infoText: string, onBuy: () -> ())
	local row = upgradeTemplate:Clone()
	row.Name = "UpgradeRow_" .. titleText
	row.Visible = true
	row.Parent = upgradeList

	-- 1. 绑定标题（如：升级攻击）
	local titleLabel = row:FindFirstChild("升级目标")
	if titleLabel and titleLabel:IsA("TextLabel") then
		titleLabel.Text = titleText
	end

	-- 2. 绑定花费与增加数值（如：花费:10w +10 攻击力）
	local infoLabel = row:FindFirstChild("花费+增加数值")
	if infoLabel and infoLabel:IsA("TextLabel") then
		infoLabel.Text = infoText
	end

	-- 3. 绑定升级按钮的点击事件 (ImageButton 继承自 GuiButton)
	local btn = row:FindFirstChild("升级按钮")
	if btn and btn:IsA("GuiButton") then
		btn.Activated:Connect(function()
			onBuy()
		end)
	else
		warn("[UIController] 未在 RowTemplate 中找到名为 '升级按钮' 的按钮组件！")
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

local function showToast(text: string)
	print("[系统提示]:", text) -- [修改内容] 保持原有的静默输出逻辑
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

-- [修改内容] 添加金币增减文字动画逻辑
local function playGoldTextAnimation(difference: number)
	if difference == 0 or not addGoldUI then return end
	
	-- 克隆一个现有的 addGoldUI，避免金币快速变化时动画互相干扰和覆盖
	local textClone = addGoldUI:Clone()
	textClone.Visible = true
	textClone.Parent = addGoldUI.Parent
	
	-- 根据增减判断文本与颜色
	if difference > 0 then
		textClone.Text = "+" .. formatNumberShort(difference)
		textClone.TextColor3 = Color3.fromRGB(238, 255, 0) -- 绿色代表增加
	else
		textClone.Text = "-" .. formatNumberShort(math.abs(difference))
		textClone.TextColor3 = Color3.fromRGB(255, 85, 85) -- 红色代表减少
	end
	
	-- 初始化透明度和位置（保持为模板原位置）
	textClone.TextTransparency = 0
	if textClone:FindFirstChild("UIStroke") then
		textClone.UIStroke.Transparency = 0
	end
	
	-- 创建向上移动并淡出的动画 (向上偏移 30 像素)
	local targetPos = textClone.Position - UDim2.fromOffset(0, 30)
	
	-- 对 TextLabel 自身进行动画
	local tweenInfo = TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(textClone, tweenInfo, {
		Position = targetPos,
		TextTransparency = 1
	})
	
	-- 如果带有描边 (UIStroke)，也让描边一起淡出
	if textClone:FindFirstChild("UIStroke") then
		local strokeTween = TweenService:Create(textClone.UIStroke, tweenInfo, {
			Transparency = 1
		})
		strokeTween:Play()
	end
	
	tween:Play()
	
	-- 动画结束后销毁克隆体释放内存
	tween.Completed:Connect(function()
		textClone:Destroy()
	end)
end

function UIController.Init() -- [修改内容] 暴露初始化接口供外部调用
	-- [修改内容] 游戏启动时，隐藏用于克隆的原始模板，避免在列表中显示空白项
	if rowTemplate then rowTemplate.Visible = false end
	if weaponTemplate then weaponTemplate.Visible = false end

	-- [修改内容] 强制开启两个滑动列表的 Y 轴（上下）自动画布大小，并将基础 CanvasSize 归零。彻底修复无法滑动的问题。
	if monsterInventoryList then
		monsterInventoryList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		monsterInventoryList.CanvasSize = UDim2.new(0, 0, 0, 0)
	end
	if weaponList then
		weaponList.AutomaticCanvasSize = Enum.AutomaticSize.Y
		weaponList.CanvasSize = UDim2.new(0, 0, 0, 0)
	end

	-- 1. [修改内容] 金币同步与飞行动效触发
	local lastGold = player:GetAttribute("Gold") or 0
	goldLabel.Text = formatNumberShort(lastGold)
	
	-- [修改内容] 隐藏原始的增减提示 UI 作为模板
	if addGoldUI then addGoldUI.Visible = false end
	
	local function onGoldChanged()
		local currentGold = player:GetAttribute("Gold") or 0
		goldLabel.Text = formatNumberShort(currentGold)
		
		-- 计算金币差值
		local difference = currentGold - lastGold
		
		-- [修改内容] 无论金币是增加还是减少，都播放文字飘动提示
		if difference ~= 0 then
			playGoldTextAnimation(difference)
		end
		
		-- 判断是收获金币（增加）才播放全屏飞行动画
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

	-- 4. [修改内容] 背包按钮开关及选项卡逻辑
	if backpackButton then
		backpackButton.Activated:Connect(function() 
			local newState = not monsterInventoryWindow.Visible
			monsterInventoryWindow.Visible = newState
			if newState then
				-- 打开背包时默认重置显示怪物页
				switchInventoryTab("monster")
			end
		end)
	end

	-- [修改内容] 监听顶部选项卡按钮点击
	if monsterTabBtn then
		monsterTabBtn.Activated:Connect(function() switchInventoryTab("monster") end)
	end
	if weaponTabBtn then
		weaponTabBtn.Activated:Connect(function() switchInventoryTab("weapon") end)
	end

	-- [修改内容] 关键：监听装备属性变化，只要服务端一改，客户端立即重刷列表
	player:GetAttributeChangedSignal("EquippedWeaponLevel"):Connect(function()
		if monsterInventoryWindow.Visible and weaponList.Visible then
			refreshWeaponInventoryUI()
		end
	end)

	-- 5. 初始化商店 (此处应包含原脚本中 openWeaponShopUI 等监听器)
	-- [逻辑流]：监听服务端事件 -> 显示对应的 Window -> 调用刷新函数渲染列表
	-- [修改内容] 初始化 shopsGui 容器（如果不存在的话）
	if not shopsGui then
		shopsGui = Instance.new("ScreenGui")
		shopsGui.Name = "ShopsGui"
		shopsGui.Parent = player:WaitForChild("PlayerGui")
	end

	-- [修改内容] 监听服务端发来的打开武器商店指令
	openWeaponShopUI.OnClientEvent:Connect(function()
		if not weaponWindow then
			weaponWindow = createWindow("Weapon")
		end
		weaponWindow.Visible = true
	end)

	-- [修改内容] 监听服务端发来的打开升级商店指令
	openUpgradeShopUI.OnClientEvent:Connect(function()
		upgradeWindow.Visible = true
		refreshUpgradeShopUI() -- 每次打开刷新一次数据
	end)

	-- [修改内容] 绑定关闭按钮
	if upgradeCloseBtn then
		upgradeCloseBtn.Activated:Connect(function()
			upgradeWindow.Visible = false
		end)
	end

	-- [修改内容] 属性变化时实时刷新（可选，为了让购买后文字立即变动）
	local attributes = {"AttackLevel", "SpeedLevel", "HealthLevel", "CarryLevel"}
	for _, attr in ipairs(attributes) do
		player:GetAttributeChangedSignal(attr):Connect(function()
			if upgradeWindow.Visible then
				refreshUpgradeShopUI()
			end
		end)
	end

	print("[UIController] 2D UI 逻辑已初始化")

	-- [修改内容] 删除按钮逻辑，带防卡死判断（终极唯一版）
	local safeDeleteBtn = mainGui:FindFirstChild("delete")
	-- 设置 5 秒超时，如果拿不到 RemoteEvent 就不死等，防止整个 UI 瘫痪
	local safeRequestClear = remotes:WaitForChild("RequestClearPlayerData", 5)

	if safeDeleteBtn and safeRequestClear then
		safeDeleteBtn.Activated:Connect(function()
			print("已向服务器发送清空数据指令！")
			safeRequestClear:FireServer()
		end)
	elseif safeDeleteBtn then
		warn("严重错误：RequestClearPlayerData 远程事件加载失败！")
	end
end

return UIController