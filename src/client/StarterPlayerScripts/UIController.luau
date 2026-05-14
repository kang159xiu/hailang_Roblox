--
local UIController = {}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
-- [新增内容] 引入社交服务用于弹出邀请界面
local SocialService = game:GetService("SocialService") 
-- [新增内容] 引入市场服务用于处理通行证购买
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService = game:GetService("TweenService")

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
local requestDropCarriedMonsters = remotes:WaitForChild("RequestDropCarriedMonsters") :: RemoteEvent
local requestRebirth = remotes:WaitForChild("RequestRebirth") :: RemoteEvent
local requestStealPlacedGold = remotes:WaitForChild("RequestStealPlacedGold") :: RemoteEvent
local stealGoldAvailability = remotes:WaitForChild("StealGoldAvailability") :: RemoteEvent
local stealGoldOwnerWarning = remotes:WaitForChild("StealGoldOwnerWarning") :: RemoteEvent
local stealGoldResult = remotes:WaitForChild("StealGoldResult") :: RemoteEvent

-- =====================
-- 基础 UI 变量
-- =====================
local mainGui = player:WaitForChild("PlayerGui"):WaitForChild("MainUI") :: ScreenGui
local goldLabel = mainGui:WaitForChild("GoldFrame"):WaitForChild("GoldLabel") :: TextLabel
local atkLabel: TextLabel? = nil
do
	local atkDisplayFrame = mainGui:WaitForChild("ATK显示", 5)
	if atkDisplayFrame then
		local foundAtkLabel = atkDisplayFrame:WaitForChild("ATKLabel", 5)
		if foundAtkLabel and foundAtkLabel:IsA("TextLabel") then
			atkLabel = foundAtkLabel
		else
			warn("[UIController] ATK显示 下未找到 TextLabel: ATKLabel")
		end
	else
		warn("[UIController] MainUI 下未找到 ATK显示，攻击力 UI 不会显示")
	end
end
local speedLabel: TextLabel? = nil
do
	local speedDisplayFrame = mainGui:WaitForChild("速度显示", 5)
	if speedDisplayFrame then
		local foundSpeedLabel = speedDisplayFrame:WaitForChild("速度Label", 5)
		if foundSpeedLabel and foundSpeedLabel:IsA("TextLabel") then
			speedLabel = foundSpeedLabel
		else
			warn("[UIController] 速度显示 下未找到 TextLabel: 速度Label")
		end
	else
		warn("[UIController] MainUI 下未找到 速度显示，速度 UI 不会显示")
	end
end
-- 引用金币增减提示的 TextLabel
local addGoldUI = mainGui:WaitForChild("GoldFrame"):WaitForChild("addGoldUI") :: TextLabel
local monsterInventoryWindow = mainGui:WaitForChild("MonsterInventoryWindow") :: Frame
local monsterInventoryList = monsterInventoryWindow:WaitForChild("List") :: ScrollingFrame
local rowTemplate = monsterInventoryWindow:WaitForChild("RowTemplate") :: ImageButton
-- 【新增】获取你刚做好的关闭按钮
local inventoryCloseBtn = monsterInventoryWindow:WaitForChild("guanbibb", 5) :: GuiButton?


-- 引用删除数据按钮
local deleteBtn = mainGui:WaitForChild("delete") :: ImageButton

-- 新增武器列表、武器模板和选项卡按钮的变量引用
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
local stealButton: GuiButton? = nil
local stealTotalLabel: TextLabel? = nil
local stealActualTotal = 0
local stealDisplayedTotal = 0
local stealCountTweenToken = 0
local pendingStealGoldFlySuppressUntil = 0
local stealWarningFrame: GuiObject? = nil
local stealWarningLabel: TextLabel? = nil
local stealWarningBlinkToken = 0
local dropCarriedFrame: GuiObject? = nil
local dropCarriedButton: GuiButton? = nil
local carriedFolderChildAddedConnection: RBXScriptConnection? = nil
local carriedFolderChildRemovedConnection: RBXScriptConnection? = nil
local carriedCharacterChildAddedConnection: RBXScriptConnection? = nil
local carriedCharacterChildRemovedConnection: RBXScriptConnection? = nil

-- 必须加上 true 开启深层递归查找，否则移入 List 文件夹后代码将无法定位该按钮
local speedToggleButton = mainGui:FindFirstChild("ImageButton_正常速度", true) :: ImageButton?
local normalSpeedBgOn = speedToggleButton and speedToggleButton:FindFirstChild("开启常速背景") :: ImageLabel?
local normalSpeedBgOff = speedToggleButton and speedToggleButton:FindFirstChild("关闭常速背景") :: ImageLabel?
local speedToggleText = speedToggleButton and speedToggleButton:FindFirstChild("开/关速度状态") :: TextLabel?
local isNormalSpeedActive = false -- 默认状态为 false（即默认使用升级后的加速状态）

local AUTO_ATTACK_ENABLED_ATTRIBUTE = "AutoAttackEnabled"
local formatNumberShort: (number) -> string

local function setStealTotalLabelText(amount: number)
	if stealTotalLabel then
		stealTotalLabel.Text = "+" .. formatNumberShort(math.max(0, math.floor(amount))) .. "金币"
	end
end

local function resetStealTotal()
	stealCountTweenToken += 1
	stealActualTotal = 0
	stealDisplayedTotal = 0
	setStealTotalLabelText(0)
end

local function setStealButtonVisible(visible: boolean)
	if stealButton and stealButton.Visible ~= visible then
		stealButton.Visible = visible
	end
end

local function bindButtonPressScaleAnimation(button: GuiButton)
	local existingScale = button:FindFirstChild("PressScale")
	local pressScale: UIScale
	if existingScale and existingScale:IsA("UIScale") then
		pressScale = existingScale :: UIScale
	else
		local newScale = Instance.new("UIScale")
		newScale.Name = "PressScale"
		newScale.Scale = 1
		newScale.Parent = button
		pressScale = newScale
	end

	local currentTween: Tween? = nil
	local pressToken = 0
	local pressedAt = 0
	local minPressVisibleSeconds = 0.08
	local pressedScale = 0.85

	local function tweenTo(targetScale: number)
		if currentTween then
			currentTween:Cancel()
			currentTween = nil
		end

		currentTween = TweenService:Create(pressScale, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = targetScale,
		})
		currentTween:Play()
	end

	local function pressDown()
		pressToken += 1
		pressedAt = os.clock()
		tweenTo(pressedScale)
	end

	local function releaseUp()
		pressToken += 1
		local token = pressToken
		local elapsed = os.clock() - pressedAt
		local waitTime = math.max(0, minPressVisibleSeconds - elapsed)

		task.delay(waitTime, function()
			if token == pressToken then
				tweenTo(1)
			end
		end)
	end

	button.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			pressDown()
		end
	end)
	button.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			releaseUp()
		end
	end)
	button.MouseLeave:Connect(releaseUp)
end

local function stopStealWarning()
	stealWarningBlinkToken += 1
	if stealWarningFrame then
		stealWarningFrame.Visible = false
	end
	if stealWarningLabel then
		stealWarningLabel.TextTransparency = 0
	end
end

local function showStealWarning(thiefName: string?)
	stealWarningBlinkToken += 1
	local token = stealWarningBlinkToken
	local safeName = if type(thiefName) == "string" and thiefName ~= "" then thiefName else "有"

	if stealWarningLabel then
		stealWarningLabel.Text = string.format("%s玩家在偷取你的钱币", safeName)
	end
	if stealWarningFrame then
		stealWarningFrame.Visible = true
	end

	task.spawn(function()
		while stealWarningBlinkToken == token do
			if stealWarningLabel then
				stealWarningLabel.TextTransparency = 0
			end
			task.wait(0.35)
			if stealWarningBlinkToken ~= token then
				break
			end
			if stealWarningLabel then
				stealWarningLabel.TextTransparency = 0.65
			end
			task.wait(0.35)
		end
		if stealWarningLabel then
			stealWarningLabel.TextTransparency = 0
		end
	end)
end

local rebirthButton = mainGui:FindFirstChild("ImageButton_重生", true) :: GuiButton?
local rebirthWindow = mainGui:FindFirstChild("重生界面", true) :: GuiObject?
local rebirthProgressBar = rebirthWindow and rebirthWindow:FindFirstChild("ImageLabel1_进度", true) :: GuiObject?
local rebirthNeedMoneyLabel = rebirthWindow and rebirthWindow:FindFirstChild("需要钱比例", true) :: TextLabel?
local rebirthRobuxButton = rebirthWindow and rebirthWindow:FindFirstChild("r币重生", true) :: GuiButton?
local rebirthCloseButton = rebirthWindow and rebirthWindow:FindFirstChild("关闭", true) :: GuiButton?
local rebirthConfirmButton = rebirthWindow and rebirthWindow:FindFirstChild("重生", true) :: GuiButton?
local rebirthProgressBaseSize = rebirthProgressBar and rebirthProgressBar.Size or UDim2.new(1.5, 0, 1, 0)
local rebirthUIDebugPrints = 0

local function hasCarriedMonsters(): boolean
	local character = player.Character
	if not character then
		return false
	end

	local holder = character:FindFirstChild("CarriedMonsters")
	return holder ~= nil and #holder:GetChildren() > 0
end

local function setDropCarriedVisible(visible: boolean)
	if dropCarriedFrame and dropCarriedFrame.Visible ~= visible then
		dropCarriedFrame.Visible = visible
	end
end

local function refreshDropCarriedVisible()
	setDropCarriedVisible(hasCarriedMonsters())
end

local function bindCarriedFolderWatcher(character: Model?)
	if carriedFolderChildAddedConnection then
		carriedFolderChildAddedConnection:Disconnect()
		carriedFolderChildAddedConnection = nil
	end
	if carriedFolderChildRemovedConnection then
		carriedFolderChildRemovedConnection:Disconnect()
		carriedFolderChildRemovedConnection = nil
	end
	if carriedCharacterChildAddedConnection then
		carriedCharacterChildAddedConnection:Disconnect()
		carriedCharacterChildAddedConnection = nil
	end
	if carriedCharacterChildRemovedConnection then
		carriedCharacterChildRemovedConnection:Disconnect()
		carriedCharacterChildRemovedConnection = nil
	end

	if not character then
		refreshDropCarriedVisible()
		return
	end

	local function attachToHolder(holder: Instance?)
		if carriedFolderChildAddedConnection then
			carriedFolderChildAddedConnection:Disconnect()
			carriedFolderChildAddedConnection = nil
		end
		if carriedFolderChildRemovedConnection then
			carriedFolderChildRemovedConnection:Disconnect()
			carriedFolderChildRemovedConnection = nil
		end

		if holder then
			carriedFolderChildAddedConnection = holder.ChildAdded:Connect(refreshDropCarriedVisible)
			carriedFolderChildRemovedConnection = holder.ChildRemoved:Connect(function()
				task.defer(refreshDropCarriedVisible)
			end)
		end

		refreshDropCarriedVisible()
	end

	attachToHolder(character:FindFirstChild("CarriedMonsters"))
	carriedCharacterChildAddedConnection = character.ChildAdded:Connect(function(child)
		if child.Name == "CarriedMonsters" then
			attachToHolder(child)
		end
	end)
	carriedCharacterChildRemovedConnection = character.ChildRemoved:Connect(function(child)
		if child.Name == "CarriedMonsters" then
			attachToHolder(nil)
		end
	end)
end

-- 引用您预设的商店 UI
local playerGui = player:WaitForChild("PlayerGui")
local shopsGui = playerGui:WaitForChild("ShopsUI")

-- 升级商店引用
local upgradeWindow = shopsGui:WaitForChild("升级商店Window")
local upgradeCloseBtn = upgradeWindow:WaitForChild("Close") :: GuiButton
local upgradeList = upgradeWindow:WaitForChild("List") :: GuiObject
local legacyUpgradeTemplate = upgradeWindow:FindFirstChild("RowTemplate") :: GuiObject?

-- 升级商店现在使用你放在 List 下的 4 个独立模板：
-- StarterGui.ShopsUI.升级商店Window.List.HP升级 / 攻击升级 / 速度升级 / 拿取个数升级
-- 注意：HP升级 模板名称保留不改，但现在显示和功能都代表“跳跃升级”。
local UPGRADE_TEMPLATE_NAME_BY_TYPE = {
	Attack = "攻击升级",
	Speed = "速度升级",
	Health = "HP升级",
	Carry = "拿取个数升级",
}

local UPGRADE_TEMPLATE_NAME_SET: {[string]: boolean} = {}
for _, templateName in pairs(UPGRADE_TEMPLATE_NAME_BY_TYPE) do
	UPGRADE_TEMPLATE_NAME_SET[templateName] = true
end

local upgradeTemplatesByType: {[string]: GuiObject} = {}
for upgradeType, templateName in pairs(UPGRADE_TEMPLATE_NAME_BY_TYPE) do
	local template = upgradeList:FindFirstChild(templateName)
	if template and template:IsA("GuiObject") then
		upgradeTemplatesByType[upgradeType] = template
		template.Visible = false -- 模板只用于克隆，不直接显示
	else
		warn(string.format("[UIController] 升级商店缺少模板：List.%s", templateName))
	end
end
if legacyUpgradeTemplate then
	legacyUpgradeTemplate.Visible = false -- 兼容旧模板，防止它作为实体显示出来
end

-- 武器商店引用
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
		if child:IsA("GuiObject") and not UPGRADE_TEMPLATE_NAME_SET[child.Name] and child.Name ~= "RowTemplate" and not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end
-- =====================
-- 辅助函数
-- =====================
function formatNumberShort(n: number): string
    if type(n) ~= "number" then return "0" end
    local abs = math.abs(n)
    if abs < 1000 then return tostring(math.floor(n)) end

    local suffixes = {"K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd", "Td", "Qd", "Qid", "Sxd", "Spd", "Ocd", "Nod", "Vg"}
    
    local suffixIndex = 0
    local value = abs
    
    while value >= 999.5 and suffixIndex < #suffixes do
        value /= 1000
        suffixIndex += 1
    end

    if value >= 1000 then
        return string.format("%.2fe%d", value, suffixIndex * 3)
    end

    local base = 10 ^ (suffixIndex * 3)
    local value = abs / base
    
    local formatted = (value >= 100) and string.format("%.0f", value) 
                   or (value >= 10 and string.format("%.1f", value) 
                   or string.format("%.2f", value))

    if string.find(formatted, "%.") then
        formatted = string.gsub(formatted, "0+$", "")
        formatted = string.gsub(formatted, "%.$", "")
    end

    return (n < 0 and "-" or "") .. formatted .. suffixes[suffixIndex]
end

local function refreshRebirthUI()
	-- 重生 UI 中可能存在模板/重复 TextLabel；每次刷新时动态更新所有同名标签，避免缓存到旧引用或模板导致显示停在 1x。
	local function setAllRebirthTextLabels(labelName: string, text: string): number
		if not rebirthWindow then
			return 0
		end

		local hitCount = 0
		for _, desc in ipairs(rebirthWindow:GetDescendants()) do
			if desc.Name == labelName and desc:IsA("TextLabel") then
				(desc :: TextLabel).Text = text
				hitCount += 1
			end
		end
		return hitCount
	end

	local function debugRebirthTextLabels(reason: string)
		if not rebirthWindow then
			return
		end
		if rebirthUIDebugPrints >= 3 then
			return
		end
		rebirthUIDebugPrints += 1

		warn(string.format("[RebirthUIDebug] %s window=%s", reason, rebirthWindow:GetFullName()))
		warn(string.format(
			"[RebirthUIDebug] attrs Gold=%s RebirthCount=%s RebirthMultiplier=%s NextRebirthCost=%s",
			tostring(player:GetAttribute("Gold")),
			tostring(player:GetAttribute("RebirthCount")),
			tostring(player:GetAttribute("RebirthMultiplier")),
			tostring(player:GetAttribute("NextRebirthCost"))
		))

		for _, desc in ipairs(rebirthWindow:GetDescendants()) do
			if desc:IsA("TextLabel") then
				warn(string.format(
					"[RebirthUIDebug] label path=%s name=%s text=%s visible=%s",
					desc:GetFullName(),
					desc.Name,
					desc.Text,
					tostring((desc :: TextLabel).Visible)
				))
			end
		end
	end

	local gold = player:GetAttribute("Gold") or 0
	local rebirthCount = player:GetAttribute("RebirthCount") or 0
	if type(rebirthCount) ~= "number" then
		rebirthCount = 0
	end
	rebirthCount = math.max(0, math.floor(rebirthCount))

	local multiplier = player:GetAttribute("RebirthMultiplier")
	if type(multiplier) ~= "number" then
		multiplier = Config.GetRebirthCashMultiplier and Config.GetRebirthCashMultiplier(rebirthCount) or (rebirthCount + 1)
	end
	multiplier = math.max(1, math.floor(multiplier :: number))

	local cost = player:GetAttribute("NextRebirthCost")
	if type(cost) ~= "number" then
		cost = Config.GetRebirthCost and Config.GetRebirthCost(rebirthCount) or 10000
	end
	local nextMultiplier = multiplier + 1

	local currentHitCount = 0
	currentHitCount += setAllRebirthTextLabels("当前现金倍率", string.format("%dx", multiplier))
	currentHitCount += setAllRebirthTextLabels("当前现金倍率textlable", string.format("%dx", multiplier))
	local nextHitCount = setAllRebirthTextLabels("升级后倍率", string.format("%dx", nextMultiplier))
	if currentHitCount == 0 or nextHitCount == 0 then
		debugRebirthTextLabels(string.format("missing label currentHits=%d nextHits=%d", currentHitCount, nextHitCount))
	elseif rebirthUIDebugPrints < 1 then
		debugRebirthTextLabels(string.format("label hits currentHits=%d nextHits=%d", currentHitCount, nextHitCount))
	end

	if rebirthNeedMoneyLabel then
		rebirthNeedMoneyLabel.Text = string.format("%s/%s", formatNumberShort(gold), formatNumberShort(cost))
	end
	if rebirthProgressBar then
		local ratio = 0
		if cost > 0 then
			ratio = math.clamp(gold / cost, 0, 1)
		end
		rebirthProgressBar.Size = UDim2.new(1.5 * ratio, rebirthProgressBaseSize.X.Offset, rebirthProgressBaseSize.Y.Scale, rebirthProgressBaseSize.Y.Offset)
	end
end

local function getCurrentAttackPower(): number
	local equippedWeaponLevel = player:GetAttribute("EquippedWeaponLevel") or player:GetAttribute("WeaponLevel") or 1
	if type(equippedWeaponLevel) ~= "number" then
		equippedWeaponLevel = 1
	end

	local attackLevel = player:GetAttribute("AttackLevel") or 0
	if type(attackLevel) ~= "number" then
		attackLevel = 0
	end

	local weaponAttack = Config.WEAPON_ATTACK_BY_LEVEL[equippedWeaponLevel] or 10
	local upgradeAdd = Config.ATTACK_UPGRADE_ADD or 10
	return weaponAttack + (attackLevel * upgradeAdd)
end

local function refreshAttackPowerLabel()
	if not atkLabel then
		return
	end

	atkLabel.Text = "ATK: " .. formatNumberShort(getCurrentAttackPower())
end

local function getCurrentMoveSpeed(): number
	local speedLevel = player:GetAttribute("SpeedLevel") or 0
	if type(speedLevel) ~= "number" then
		speedLevel = 0
	end

	local baseSpeed = Config.WALK_SPEED_BASE or 20
	local addPerLevel = Config.WALK_SPEED_PER_UPGRADE or 1
	return baseSpeed + (speedLevel * addPerLevel)
end

local function refreshSpeedLabel()
	if not speedLabel then
		return
	end

	speedLabel.Text = "Speed: " .. formatNumberShort(getCurrentMoveSpeed())
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
local function appendUniqueInstance(list: {Instance}, inst: Instance?)
	if not inst then
		return
	end
	for _, existing in ipairs(list) do
		if existing == inst then
			return
		end
	end
	table.insert(list, inst)
end

local function getMonsterAppearanceFolders(): {Instance}
	local folders = {}
	appendUniqueInstance(folders, ReplicatedStorage:FindFirstChild("Monster image"))
	appendUniqueInstance(folders, ReplicatedStorage:FindFirstChild("MonsterAppearances"))
	appendUniqueInstance(folders, workspace:FindFirstChild("Monster image"))
	return folders
end

local function findMonsterInventoryTemplate(level: number): Instance?
	local safeLevel = math.max(1, math.floor(tonumber(level) or 1))
	local strNormal = tostring(safeLevel)
	local strZero = string.format("%02d", safeLevel)
	local names = {
		"怪物形象" .. strNormal, "怪物形象" .. strZero,
		"怪物形象 " .. strNormal, "怪物形象 " .. strZero,
		"Lv" .. strNormal, "Lv" .. strZero,
		"Lv " .. strNormal, "Lv " .. strZero,
		strNormal, strZero,
	}

	local nameSet = {}
	for _, name in ipairs(names) do
		nameSet[name] = true
	end

	local function isRenderableTemplate(inst: Instance): boolean
		return inst:IsA("BasePart")
			or ((inst:IsA("Model") or inst:IsA("Folder")) and inst:FindFirstChildWhichIsA("BasePart", true) ~= nil)
	end

	local function scoreTemplate(inst: Instance): number
		if not isRenderableTemplate(inst) then
			return -1
		end

		local score = #inst:GetDescendants()
		if inst:IsA("Model") then
			score += 1000000
		elseif inst:IsA("Folder") then
			score += 200000
		elseif inst:IsA("BasePart") then
			score += 100000
		end
		return score
	end

	local function findInRoot(root: Instance): Instance?
		local best: Instance? = nil
		local bestScore = -1

		local function consider(candidate: Instance?)
			if not candidate then
				return
			end
			local score = scoreTemplate(candidate)
			if score > bestScore then
				best = candidate
				bestScore = score
			end
		end

		for _, name in ipairs(names) do
			consider(root:FindFirstChild(name))
		end

		if best then
			return best
		end

		for _, inst in ipairs(root:GetDescendants()) do
			if nameSet[inst.Name] then
				consider(inst)

				local cur = inst.Parent
				while cur and cur ~= root do
					if cur:IsA("Model") then
						consider(cur)
						break
					end
					cur = cur.Parent
				end
			end
		end

		return best
	end

	for _, root in ipairs(getMonsterAppearanceFolders()) do
		local found = findInRoot(root)
		if found then
			return found
		end
	end

	warn(string.format("[UIController] 未找到怪物背包形象模板：Lv.%d，已尝试名称：%s", safeLevel, table.concat(names, ", ")))
	return nil
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
	clone.Parent = viewport

	-- 4. 自动创建摄像机
	local camera = Instance.new("Camera")
	viewport.CurrentCamera = camera
	camera.Parent = viewport

	-- Folder 模板先包成 Model，方便统一计算和移动。
	if clone:IsA("Folder") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name .. "_ViewportModel"
		wrapper.Parent = viewport
		for _, child in ipairs(clone:GetChildren()) do
			child.Parent = wrapper
		end
		clone:Destroy()
		clone = wrapper
	end

	-- 怪物模板常见结构：外层模板 > 内部 Model > RootPart/真实外观。
	-- 优先显示内部 Model，避免外层定位件或透明 RootPart 把镜头中心撑偏。
	local visualModel = clone:FindFirstChild("Model", true)
	if visualModel and visualModel:IsA("Model") and visualModel:FindFirstChildWhichIsA("BasePart", true) then
		visualModel.Parent = viewport
		clone:Destroy()
		clone = visualModel
	end

	local function isLikelyVisualPart(part: BasePart): boolean
		if part.Name == "RootPart" then
			return false
		end
		if part.Transparency >= 1 then
			return false
		end
		return true
	end

	local function getVisualBounds(root: Instance): (CFrame?, Vector3?)
		local parts = {}
		for _, inst in ipairs(root:GetDescendants()) do
			if inst:IsA("BasePart") and isLikelyVisualPart(inst) then
				table.insert(parts, inst)
			end
		end

		if root:IsA("BasePart") and isLikelyVisualPart(root) then
			table.insert(parts, root)
		end

		-- 如果排除 RootPart/透明件后没有可见零件，则回退到全部 BasePart，至少保证有可显示对象。
		if #parts == 0 then
			for _, inst in ipairs(root:GetDescendants()) do
				if inst:IsA("BasePart") then
					table.insert(parts, inst)
				end
			end
			if root:IsA("BasePart") then
				table.insert(parts, root)
			end
		end

		if #parts == 0 then
			return nil, nil
		end

		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		for _, part in ipairs(parts) do
			local cf = part.CFrame
			local half = part.Size * 0.5
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local p = (cf * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
						minX = math.min(minX, p.X)
						minY = math.min(minY, p.Y)
						minZ = math.min(minZ, p.Z)
						maxX = math.max(maxX, p.X)
						maxY = math.max(maxY, p.Y)
						maxZ = math.max(maxZ, p.Z)
					end
				end
			end
		end

		local center = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
		local size = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
		return CFrame.new(center), size
	end

	local function getModelBounds(root: Instance): (CFrame?, Vector3?)
		if root:IsA("Model") then
			local cf, size = root:GetBoundingBox()
			return cf, size
		elseif root:IsA("BasePart") then
			return root.CFrame, root.Size
		end
		return nil, nil
	end

	-- 5. 按可见外观计算镜头，并把模型挪到 Viewport 原点附近。
	local boundsCF, boundsSize = getVisualBounds(clone)
	if not boundsCF or not boundsSize then
		warn("[UIController] Viewport 渲染失败：模板中没有可显示 BasePart - " .. modelSource:GetFullName())
		return
	end

	if clone:IsA("Model") then
		local modelCF, modelSize = getModelBounds(clone)
		if modelCF and modelSize then
			clone:PivotTo(CFrame.new(0, modelSize.Y * 0.5, 0) * modelCF:Inverse() * clone:GetPivot())
		else
			clone:PivotTo(CFrame.new(0, boundsSize.Y * 0.5, 0) * boundsCF:Inverse() * clone:GetPivot())
		end
		boundsCF, boundsSize = getVisualBounds(clone)
	elseif clone:IsA("BasePart") then
		clone.CFrame = CFrame.new(0, boundsSize.Y * 0.5, 0)
		boundsCF, boundsSize = getVisualBounds(clone)
	end

	if not boundsCF or not boundsSize then
		warn("[UIController] Viewport 渲染失败：移动模型后无法计算包围盒 - " .. modelSource:GetFullName())
		return
	end

	local maxDim = math.max(boundsSize.X, boundsSize.Y, boundsSize.Z)
	if maxDim < 0.1 then maxDim = 5 end

	local modelCF = getModelBounds(clone)
	local center = if modelCF then modelCF.Position else boundsCF.Position
	local distance = maxDim
	local height = math.max(boundsSize.Y * 0.02, maxDim * 0.15)
	camera.FieldOfView = 35
	camera.CFrame = CFrame.new(center + Vector3.new(-distance, height, -distance), center)
end


-- =====================
-- 升级商店逻辑
-- =====================
-- 融合了你优秀的表驱动循环逻辑，以及精准的 UI 模板文本分离映射
local function refreshUpgradeShopUI()
	-- 1. 清理旧条目
	clearUpgradeRows()

	-- 2. 定义升级类型
	local upgradeTypes = {
		{ name = "Upgrade Attack", type = "Attack", getLv = "AttackLevel" },--升级攻击
		{ name = "Upgrade Speed", type = "Speed", getLv = "SpeedLevel" },--升级速度
		{ name = "Upgrade Jump", type = "Health", getLv = "HealthLevel" },--升级跳跃（复用 HealthLevel 存档键）
		{ name = "Upgrade Carry Capacity", type = "Carry", getLv = "CarryLevel" },--升级背包容量
	}

	for _, info in ipairs(upgradeTypes) do
		local currentLv = player:GetAttribute(info.getLv) or 0
		local nextLv = currentLv + 1
		
		-- 获取花费和增加数值字符串
		local cost = 0
		local incrementText = ""
		local currentValueText = ""
		local isMaxed = false

		if info.type == "Attack" then
			cost = Config.GetAttackUpgradeCost and Config.GetAttackUpgradeCost(nextLv) or 0
			incrementText = string.format("+%d Attack", Config.ATTACK_UPGRADE_ADD or 10)--升级攻击力
			currentValueText = string.format("ATK: %s", formatNumberShort(getCurrentAttackPower()))
		elseif info.type == "Speed" then
			cost = Config.GetSpeedUpgradeCost and Config.GetSpeedUpgradeCost(nextLv) or 0
			incrementText = string.format("+%d Speed", Config.WALK_SPEED_PER_UPGRADE or 2)--升级速度
			currentValueText = string.format("Speed: %s", formatNumberShort(getCurrentMoveSpeed()))
		elseif info.type == "Health" then
			local maxJumpLevel = if Config.GetMaxJumpUpgradeLevel then Config.GetMaxJumpUpgradeLevel() else math.max(0, math.floor(((Config.JUMP_POWER_MAX or 150) - (Config.JUMP_POWER_BASE or 50)) / (Config.JUMP_POWER_PER_UPGRADE or 1)))
			local currentJump = if Config.GetJumpPowerForLevel then Config.GetJumpPowerForLevel(currentLv) else math.clamp((Config.JUMP_POWER_BASE or 50) + currentLv * (Config.JUMP_POWER_PER_UPGRADE or 1), Config.JUMP_POWER_BASE or 50, Config.JUMP_POWER_MAX or 150)
			currentValueText = string.format("Jump: %s", formatNumberShort(currentJump))
			if currentLv >= maxJumpLevel then
				isMaxed = true
			else
				cost = if Config.GetJumpUpgradeCost then Config.GetJumpUpgradeCost(nextLv) else (Config.GetHealthUpgradeCost and Config.GetHealthUpgradeCost(nextLv) or 0)
				local nextJump = if Config.GetJumpPowerForLevel then Config.GetJumpPowerForLevel(nextLv) else math.clamp((Config.JUMP_POWER_BASE or 50) + nextLv * (Config.JUMP_POWER_PER_UPGRADE or 1), Config.JUMP_POWER_BASE or 50, Config.JUMP_POWER_MAX or 150)
				incrementText = string.format("Jump: %d → %d", currentJump, nextJump)--升级跳跃
			end
		elseif info.type == "Carry" then
			local currentCarry = Config.GetCarryMax and Config.GetCarryMax(currentLv) or (currentLv + 1)
			currentValueText = string.format("Carry: %s", formatNumberShort(currentCarry))
			local nextCost = Config.GetCarryUpgradeCost and Config.GetCarryUpgradeCost(nextLv)
			if nextCost == nil then
				isMaxed = true -- 如果获取不到下一级价格，说明满了
			else
				cost = nextCost
				local nextCarry = Config.GetCarryMax and Config.GetCarryMax(nextLv) or (nextLv + 1)
				incrementText = string.format("Carry: %d → %d", currentCarry, nextCarry)
			end
		end

		-- 3. 按升级类型克隆你放在 List 下的独立模板
		local template = upgradeTemplatesByType[info.type] or legacyUpgradeTemplate
		if not template then
			warn(string.format("[UIController] 无法创建升级条目：缺少 %s 对应模板", info.type))
			continue
		end

		local row = template:Clone()
		row.Name = info.type .. "Row"
		row.LayoutOrder = table.find({"Health", "Attack", "Speed", "Carry"}, info.type) or 0
		row.Visible = true
		row.Parent = upgradeList

		-- 图标：优先保留模板自身图片；如果模板图片为空，再读取 Config.UPGRADE_SHOP_ICON_BY_TYPE 兜底
		local iconLabel = row:FindFirstChild("ImageLabel", true)
		if iconLabel and iconLabel:IsA("ImageLabel") then
			local iconId = Config.UPGRADE_SHOP_ICON_BY_TYPE and Config.UPGRADE_SHOP_ICON_BY_TYPE[info.type]
			local templateImageEmpty = iconLabel.Image == nil or iconLabel.Image == "" or iconLabel.Image == "rbxassetid://0"
			if templateImageEmpty and iconId and iconId ~= "" and iconId ~= "rbxassetid://0" then
				iconLabel.Image = iconId
				iconLabel.Visible = true
			end
		end

		-- A. 赋值：升级目标文本框
		local targetLabel = row:FindFirstChild("升级目标", true)
		if targetLabel and targetLabel:IsA("TextLabel") then
			targetLabel.Text = info.name
		end

		-- B. 赋值：花费与增加数值文本框
		local costInfoLabel = row:FindFirstChild("花费+增加数值", true)
		if costInfoLabel and costInfoLabel:IsA("TextLabel") then
			if isMaxed then
				costInfoLabel.Text = if currentValueText ~= "" then string.format("Max Level   %s", currentValueText) else "Max Level" --已满级

			else
				costInfoLabel.Text = if currentValueText ~= "" then string.format("Cost: %s   %s   %s", formatNumberShort(cost), incrementText, currentValueText) else string.format("Cost: %s   %s", formatNumberShort(cost), incrementText)
			end
		end

		-- C. 绑定：升级按钮
		local upBtn = row:FindFirstChild("升级按钮", true)
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
		if ch:IsA("GuiObject") and ch ~= rowTemplate and not ch:IsA("UILayout") then ch:Destroy() end
	end

	for i, it in ipairs(payload or {}) do
		local row = rowTemplate:Clone()
		row.Visible = true
		row.Parent = monsterInventoryList
		
		local label = row:FindFirstChild("Label", true)
		if label and label:IsA("TextLabel") then
			label.Text = string.format("Monster Lv.%d  Value:%s  +%s/s", it.MonsterLevel, formatNumberShort(it.Value), formatNumberShort(it.GoldPerSec))
		end 
		
		local imageContainer = row:FindFirstChild("ImageLabel", true)
		if imageContainer and imageContainer:IsA("GuiObject") then
			local model = findMonsterInventoryTemplate(it.MonsterLevel)
			loadViewportFromScene(imageContainer, model)
		else
			warn("[UIController] 怪物背包 RowTemplate 中未找到 ImageLabel 容器")
		end

		local takeOutBtn = row:FindFirstChild("拿出按钮", true)
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
		-- 改为判断 UILayout
		if ch:IsA("GuiObject") and ch ~= weaponTemplate and not ch:IsA("UILayout") then ch:Destroy() end
	end

	local maxWeaponLevel = player:GetAttribute("WeaponLevel") or 1
	local equippedWeapon = player:GetAttribute("EquippedWeaponLevel") or 1
	
	-- 精确定位到 Workspace 下的 "weapon" 文件夹
	local weaponFolder = workspace:FindFirstChild("weapon")

	for i = 1, maxWeaponLevel do
		local row = weaponTemplate:Clone()
		row.Visible = true
		row.Parent = weaponList
		
		local label = row:FindFirstChild("Label")
		if label and label:IsA("TextLabel") then
			label.Text = Config.WEAPON_NAME_BY_LEVEL[i] or ("Weapon " .. i)
		end
		
		-- 根据命名规则 "武器01-20" 匹配加载
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
					btnText.Text = "Equipped" -- 已装备
				else
					btnText.Text = "Equip Weapon" -- 装备武器
					equipBtn.Activated:Connect(function()
						requestEquipWeapon:FireServer(i)
					end)
				end
			end
		end
	end
end

-- =====================
-- 选项卡切换逻辑
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
local rng = Random.new()

local function getGuiCenter(guiObject: GuiObject): Vector2
	return guiObject.AbsolutePosition + (guiObject.AbsoluteSize / 2)
end

local function getScreenCenter(): Vector2
	local camera = workspace.CurrentCamera
	local viewportSize = if camera then camera.ViewportSize else mainGui.AbsoluteSize
	return Vector2.new(viewportSize.X / 2, viewportSize.Y / 2)
end

local function playGoldFlyingAnimation(increaseAmount: number, originAbsPos: Vector2?)
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
	local originPos = originAbsPos or getScreenCenter()

	for i = 1, count do
		task.spawn(function()
			local coin = moneyImageSource:Clone()
			coin.Visible = true -- 强制显示！
			coin.Size = UDim2.fromOffset(50, 50)
			coin.AnchorPoint = Vector2.new(0.5, 0.5)
			coin.Position = UDim2.fromOffset(originPos.X, originPos.Y)
			coin.Parent = fxContainer

			-- 散开动画
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = rng:NextNumber(50, 220)
			local scatterPos = UDim2.fromOffset(originPos.X + math.cos(angle) * radius, originPos.Y + math.sin(angle) * radius)
			
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

local function playStealGoldTextSettleAnimation(amount: number)
	local value = math.floor(tonumber(amount) or 0)
	if value <= 0 then
		return
	end

	local origin = if stealTotalLabel then getGuiCenter(stealTotalLabel) elseif stealButton then getGuiCenter(stealButton) else getGuiCenter(goldLabel)
	local target = getGuiCenter(goldLabel)

	local label = Instance.new("TextLabel")
	label.Name = "StealGoldSettleFlyText"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromOffset(origin.X, origin.Y)
	label.Size = UDim2.fromOffset(180, 46)
	label.BackgroundTransparency = 1
	label.Text = "+" .. formatNumberShort(value) .. "金币"
	label.TextColor3 = Color3.fromRGB(255, 221, 64)
	label.TextStrokeTransparency = 0.25
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.ZIndex = 200
	label.Parent = mainGui

	local tween = TweenService:Create(label, TweenInfo.new(0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Position = UDim2.fromOffset(target.X, target.Y),
		TextTransparency = 0.15,
		TextStrokeTransparency = 1,
	})
	tween:Play()
	tween.Completed:Connect(function()
		if label.Parent then
			label:Destroy()
		end
	end)
end

local function animateStealTotalTo(targetTotal: number)
	stealCountTweenToken += 1
	local token = stealCountTweenToken
	local fromValue = stealDisplayedTotal
	local toValue = math.max(0, math.floor(targetTotal))
	local duration = 0.45
	local startedAt = os.clock()

	task.spawn(function()
		while stealCountTweenToken == token do
			local alpha = math.clamp((os.clock() - startedAt) / duration, 0, 1)
			local eased = 1 - ((1 - alpha) * (1 - alpha))
			stealDisplayedTotal = math.floor(fromValue + ((toValue - fromValue) * eased))
			setStealTotalLabelText(stealDisplayedTotal)
			if alpha >= 1 then
				break
			end
			task.wait()
		end

		if stealCountTweenToken == token then
			stealDisplayedTotal = toValue
			setStealTotalLabelText(toValue)
		end
	end)
end

local function handleStealGoldResult(amount: number, mode: string?)
	local value = math.floor(tonumber(amount) or 0)
	local resultMode = mode or "progress"

	if resultMode == "cancelled" then
		resetStealTotal()
		return
	end

	if resultMode == "settled" then
		local settled = if value > 0 then value else stealActualTotal
		if settled > 0 then
			stealActualTotal = settled
			stealDisplayedTotal = settled
			setStealTotalLabelText(settled)
			pendingStealGoldFlySuppressUntil = math.max(pendingStealGoldFlySuppressUntil, os.clock() + 1.0)
			playGoldFlyingAnimation(settled, if stealButton then getGuiCenter(stealButton) else nil)
			playStealGoldTextSettleAnimation(settled)
		end
		resetStealTotal()
		return
	end

	if value <= 0 then
		return
	end

	stealActualTotal += value
	animateStealTotalTo(stealActualTotal)
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

	local function safeFullName(instance: Instance?): string
		if not instance then
			return "nil"
		end
		local ok, fullName = pcall(function()
			return instance:GetFullName()
		end)
		return ok and fullName or instance.Name
	end


	if weaponShopList:IsA("ScrollingFrame") then
		weaponShopList.CanvasPosition = Vector2.new(0, 0)
	end

	-- 只清理代码克隆出来的武器条目，保留你在 Studio 中配置好的 UIListLayout / UIPadding。
	for _, ch in ipairs(weaponShopList:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "单个武器背景" then
			ch:Destroy()
		end
	end

	local maxWeaponLevel = player:GetAttribute("WeaponLevel") or 1
	local equippedWeapon = player:GetAttribute("EquippedWeaponLevel") or 1
	local weaponFolder = workspace:FindFirstChild("weapon")
	local createdCount = 0

	for i = 1, 20 do
		local price = Config.WEAPON_PRICE_BY_LEVEL and Config.WEAPON_PRICE_BY_LEVEL[i]
		local attack = Config.WEAPON_ATTACK_BY_LEVEL and Config.WEAPON_ATTACK_BY_LEVEL[i]
		if not price and i > 1 then
			warn(string.format("[WeaponShopDebug] 跳过武器 %d：未找到价格配置", i))
			continue
		end

		local row = weaponShopTemplate:Clone()
		-- [修改原因] 使用 %02d 补零格式化名称 (例如 WeaponShopRow_01)，防止 UI 布局组件意外按 Name 排序导致错乱
		row.Name = string.format("WeaponShopRow_%02d", i)
		row.AnchorPoint = Vector2.new(0, 0)
		row.Position = UDim2.fromOffset(0, 0)
		row.LayoutOrder = i
		row.Visible = true
		row.Parent = weaponShopList
		createdCount += 1

		local nameLabel = row:FindFirstChild("武器名称")
		if nameLabel and nameLabel:IsA("TextLabel") then
			nameLabel.Text = Config.WEAPON_NAME_BY_LEVEL and Config.WEAPON_NAME_BY_LEVEL[i] or ("武器" .. i)
		end

		local infoLabel = row:FindFirstChild("武器价格/武器攻击力")
		if infoLabel and infoLabel:IsA("TextLabel") then
			infoLabel.Text = string.format("Price: %s   Attack: +%s", formatNumberShort(price or 0), formatNumberShort(attack or 0))
		end--价格: %s 攻击力

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
				btn.Text = "Locked"--未解锁
				btn.Interactable = false  
				btn.Active = false
			elseif i == maxWeaponLevel + 1 then
				btn.Text = "Buy"
				btn.Interactable = true
				btn.Active = true
				btn.Activated:Connect(function()
					requestPurchaseWeapon:FireServer(i)
				end)
			elseif i <= maxWeaponLevel then
				if i == equippedWeapon then
					btn.Text = "Equipped"--已装备
					btn.Interactable = false
					btn.Active = false
				else
					btn.Text = "Equip"--装备
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

	-- [修改原因] 使用延时确保 UI 渲染树已更新，彻底解决“前几项不见”和“底部留白”的问题
	task.defer(function()
		if weaponShopList:IsA("ScrollingFrame") then
			-- 1. 暂时关闭自动尺寸，手动重置一次画布
			weaponShopList.AutomaticCanvasSize = Enum.AutomaticSize.None
			weaponShopList.CanvasSize = UDim2.new(0, 0, 0, 0)
			weaponShopList.CanvasPosition = Vector2.new(0, 0)
			
			-- 2. 强制 UI 刷新一次位置计算
			task.wait() 
			
			-- 3. 重新启用自动尺寸，让它根据 Studio 中保留的 UIListLayout 重新计算
			weaponShopList.AutomaticCanvasSize = Enum.AutomaticSize.Y
			
			-- 4. 最终复位滚动条到最上方
			weaponShopList.CanvasPosition = Vector2.new(0, 0)
			
		end
	end)
end

function UIController.Init() 
	if rowTemplate then rowTemplate.Visible = false end
	if weaponTemplate then weaponTemplate.Visible = false end

	-- 1. 怪物列表滚动修复
	if monsterInventoryList then
		monsterInventoryList.AutomaticCanvasSize = Enum.AutomaticSize.None
		local layout = monsterInventoryList:FindFirstChildWhichIsA("UIListLayout")
		if layout then
			layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
				monsterInventoryList.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 10)
			end)
		end
	end

	-- 2. 武器列表滚动修复
	if weaponList then
		weaponList.AutomaticCanvasSize = Enum.AutomaticSize.None
		local layout = weaponList:FindFirstChildWhichIsA("UIListLayout")
		if layout then
			layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
				weaponList.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 10)
			end)
		end
	end

	-- 1. 金币同步与飞行动效触发 (纯净版)
	local lastGold = player:GetAttribute("Gold") or 0
	goldLabel.Text = formatNumberShort(lastGold)
	refreshAttackPowerLabel()
	refreshSpeedLabel()
	task.defer(refreshAttackPowerLabel)
	task.defer(refreshSpeedLabel)
	task.delay(1, refreshAttackPowerLabel)
	task.delay(1, refreshSpeedLabel)
	
	if addGoldUI then addGoldUI.Visible = false end
	
	local function onGoldChanged()
		local currentGold = player:GetAttribute("Gold") or 0
		goldLabel.Text = formatNumberShort(currentGold)
		local difference = currentGold - lastGold
		
		if difference ~= 0 then
			playGoldTextAnimation(difference)
		end
		if currentGold > lastGold then
			if os.clock() <= pendingStealGoldFlySuppressUntil then
				pendingStealGoldFlySuppressUntil = 0
			else
				playGoldFlyingAnimation(difference)
			end
		end
		lastGold = currentGold
	end
	player:GetAttributeChangedSignal("Gold"):Connect(onGoldChanged)
	player:GetAttributeChangedSignal("EquippedWeaponLevel"):Connect(refreshAttackPowerLabel)
	player:GetAttributeChangedSignal("WeaponLevel"):Connect(refreshAttackPowerLabel)
	player:GetAttributeChangedSignal("AttackLevel"):Connect(refreshAttackPowerLabel)
	player:GetAttributeChangedSignal("SpeedLevel"):Connect(refreshSpeedLabel)
	player.CharacterAdded:Connect(function()
		task.delay(0.5, refreshAttackPowerLabel)
		task.delay(0.5, refreshSpeedLabel)
	end)

	-- 重生界面：开关、倍率展示、进度条、普通金币重生与 R 币重生
	if rebirthWindow then
		rebirthWindow.Visible = false
		refreshRebirthUI()
	else
		warn("[UIController] 未找到 MainUI.重生界面，重生 UI 不会显示")
	end

	if rebirthButton then
		rebirthButton.Activated:Connect(function()
			if not rebirthWindow then
				return
			end
			rebirthWindow.Visible = not rebirthWindow.Visible
			if rebirthWindow.Visible then
				refreshRebirthUI()
			end
		end)
	else
		warn("[UIController] 未找到 ImageButton_重生，无法打开重生界面")
	end

	if rebirthCloseButton then
		rebirthCloseButton.Activated:Connect(function()
			if rebirthWindow then
				rebirthWindow.Visible = false
			end
		end)
	end

	if rebirthConfirmButton then
		rebirthConfirmButton.Activated:Connect(function()
			requestRebirth:FireServer()
		end)
	end

	if rebirthRobuxButton then
		rebirthRobuxButton.Activated:Connect(function()
			local productId = Config.REBIRTH_PRODUCT_ID
			if type(productId) == "number" and productId > 0 then
				local analyticsRemote = game.ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild("Analytics_Remote")
				if analyticsRemote then
					analyticsRemote:FireServer("Funnel", "Rebirth_Robux_Prompt_Shown")
				end
				MarketplaceService:PromptProductPurchase(player, productId)
			else
				showToast("Rebirth product is not configured")
			end
		end)
	end

	for _, attr in ipairs({ "Gold", "RebirthCount", "RebirthMultiplier", "NextRebirthCost" }) do
		player:GetAttributeChangedSignal(attr):Connect(refreshRebirthUI)
	end

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
-- 【新增】红叉关闭按钮的逻辑
    if inventoryCloseBtn then
        inventoryCloseBtn.Activated:Connect(function()
            -- 点击红叉时，直接隐藏背包面板
            monsterInventoryWindow.Visible = false
        end)
    end

	if monsterTabBtn then monsterTabBtn.Activated:Connect(function() switchInventoryTab("monster") end) end
	if weaponTabBtn then weaponTabBtn.Activated:Connect(function() switchInventoryTab("weapon") end) end

	-- 放下怪按钮：运行时 UI 在 PlayerGui.MainUI，Studio 中的 StarterGui.MainUI 只是模板。
	task.spawn(function()
		local function findDropCarriedFrame(): GuiObject?
			local frame = mainGui:FindFirstChild("放下怪/回家", true) or playerGui:FindFirstChild("放下怪/回家", true)
			if frame and frame:IsA("GuiObject") then
				return frame :: GuiObject
			end

			local starterMainUi = StarterGui:FindFirstChild("MainUI")
			local starterFrame = starterMainUi and starterMainUi:FindFirstChild("放下怪/回家", true)
			if starterFrame and starterFrame:IsA("GuiObject") then
				warn("[UIController] 只在 StarterGui 模板中找到 放下怪/回家；运行时仍会继续等待 PlayerGui 副本。")
			end

			return nil
		end

		local frame = findDropCarriedFrame()
		if not frame then
			warn("[UIController] 未找到 放下怪/回家，正在后台持续扫描...")
			while not frame do
				task.wait(1)
				frame = findDropCarriedFrame()
			end
		end

		dropCarriedFrame = frame
		dropCarriedFrame.Visible = false

		local button = dropCarriedFrame:FindFirstChild("ImageButton_放下怪", true)
		if not button then
			warn("[UIController] 放下怪/回家 下未找到 ImageButton_放下怪，正在后台持续扫描...")
			while not button do
				task.wait(1)
				button = dropCarriedFrame:FindFirstChild("ImageButton_放下怪", true)
			end
		end

		if not button:IsA("GuiButton") then
			warn("[UIController] ImageButton_放下怪 不是 GuiButton，无法绑定点击事件")
			return
		end

		dropCarriedButton = button :: GuiButton
		dropCarriedButton.Activated:Connect(function()
			if not hasCarriedMonsters() then
				refreshDropCarriedVisible()
				return
			end

			setDropCarriedVisible(false)
			requestDropCarriedMonsters:FireServer()
			task.delay(0.5, refreshDropCarriedVisible)
		end)

		bindCarriedFolderWatcher(player.Character)
		player.CharacterAdded:Connect(function(character)
			task.defer(function()
				bindCarriedFolderWatcher(character)
			end)
		end)
		player.CharacterRemoving:Connect(function()
			bindCarriedFolderWatcher(nil)
		end)
		refreshDropCarriedVisible()
	end)

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
	-------------------------
	openWeaponShopUI.OnClientEvent:Connect(function()
	if weaponWindow then
		weaponWindow.Visible = true
		-- [修改原因] 漏斗埋点：记录玩家打开了武器商店界面
		local analyticsRemote = game.ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild("Analytics_Remote")
		if analyticsRemote then
			analyticsRemote:FireServer("Funnel", "Weapon_Shop_UI_Opened")
		end
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
		-- [修改原因] 漏斗埋点：记录玩家打开了属性升级商店界面
		local analyticsRemote = game.ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild("Analytics_Remote")
		if analyticsRemote then
			analyticsRemote:FireServer("Funnel", "Upgrade_Shop_UI_Opened")
		end
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
			-- [修改原因] 漏斗埋点：记录玩家点击了VIP购买按钮并唤起 Roblox 原生支付窗口
			local analyticsRemote = game.ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild("Analytics_Remote")
			if analyticsRemote then
				analyticsRemote:FireServer("Funnel", "VIP_Prompt_Shown")
			end
			MarketplaceService:PromptGamePassPurchase(player, 1806675692)
		end)
	end

	stealGoldAvailability.OnClientEvent:Connect(function(canSteal: boolean)
		setStealButtonVisible(canSteal == true)
	end)

	stealGoldOwnerWarning.OnClientEvent:Connect(function(active: boolean, thiefName: string?)
		if active == true then
			showStealWarning(thiefName)
		else
			stopStealWarning()
		end
	end)

	stealGoldResult.OnClientEvent:Connect(function(amount: number, mode: string?)
		handleStealGoldResult(amount, mode)
	end)

	task.spawn(function()
		local playerGui = player:WaitForChild("PlayerGui")

		local function findStealButton(): GuiButton?
			local direct = mainGui:FindFirstChild("ImageButton_偷取", true)
			if direct and direct:IsA("GuiButton") then
				return direct :: GuiButton
			end

			local playerGuiButton = playerGui:FindFirstChild("ImageButton_偷取", true)
			if playerGuiButton and playerGuiButton:IsA("GuiButton") then
				return playerGuiButton :: GuiButton
			end

			local starterMainUi = StarterGui:FindFirstChild("MainUI")
			local starterButton = starterMainUi and starterMainUi:FindFirstChild("ImageButton_偷取", true)
			if starterButton and starterButton:IsA("GuiButton") then
				warn("[UIController] 只在 StarterGui 模板中找到 ImageButton_偷取；运行时仍会继续等待 PlayerGui 副本。")
			end

			return nil
		end

		local waited = mainGui:WaitForChild("ImageButton_偷取", 5)
		local btn = if waited and waited:IsA("GuiButton") then waited :: GuiButton else findStealButton()
		if not btn then
			warn("[UIController] 5秒内未找到 ImageButton_偷取，正在后台持续扫描...")
			while not btn do
				task.wait(1)
				btn = findStealButton()
			end
		end

		stealButton = btn
		local totalLabel = stealButton:FindFirstChild("+xx金币", true)
		if totalLabel and totalLabel:IsA("TextLabel") then
			stealTotalLabel = totalLabel :: TextLabel
			setStealTotalLabelText(0)
		else
			warn("[UIController] ImageButton_偷取 下未找到 TextLabel: +xx金币")
		end
		stealButton.Visible = false
		bindButtonPressScaleAnimation(stealButton)
		stealButton.Activated:Connect(function()
			pendingStealGoldFlySuppressUntil = os.clock() + 1.5
			requestStealPlacedGold:FireServer()
		end)
	end)

	task.spawn(function()
		local playerGui = player:WaitForChild("PlayerGui")

		local function findWarningFrame(): GuiObject?
			local direct = mainGui:FindFirstChild("偷取提示消息", true) or playerGui:FindFirstChild("偷取提示消息", true)
			if direct and direct:IsA("GuiObject") then
				return direct :: GuiObject
			end

			local starterMainUi = StarterGui:FindFirstChild("MainUI")
			local starterFrame = starterMainUi and starterMainUi:FindFirstChild("偷取提示消息", true)
			if starterFrame and starterFrame:IsA("GuiObject") then
				warn("[UIController] 只在 StarterGui 模板中找到 偷取提示消息；运行时仍会继续等待 PlayerGui 副本。")
			end

			return nil
		end

		local frame = findWarningFrame()
		if not frame then
			warn("[UIController] 未找到 偷取提示消息，正在后台持续扫描...")
			while not frame do
				task.wait(1)
				frame = findWarningFrame()
			end
		end

		stealWarningFrame = frame
		local label = frame:FindFirstChild("massage", true)
		if label and label:IsA("TextLabel") then
			stealWarningLabel = label :: TextLabel
		else
			warn("[UIController] 偷取提示消息 下未找到 TextLabel: massage")
		end
		stealWarningFrame.Visible = false
	end)

	-- [终极修复] 攻击按钮逻辑（加入强力异步等待机制，100% 确保找到加载缓慢的按钮）
	task.spawn(function()
		local function findAttackButton(): ImageButton?
			-- 运行时 UI 在 PlayerGui.MainUI；用户在 Studio 里看到的 StarterGui.MainUI 是模板。
			-- 因此先找 PlayerGui.MainUI，再用 PlayerGui/StarterGui 递归兜底，避免层级或复制时序差异导致 attackButton 一直 nil。
			local direct = mainGui:FindFirstChild("ImageButton_攻击", true)
			if direct and direct:IsA("ImageButton") then
				return direct :: ImageButton
			end

			local playerGuiButton = playerGui:FindFirstChild("ImageButton_攻击", true)
			if playerGuiButton and playerGuiButton:IsA("ImageButton") then
				return playerGuiButton :: ImageButton
			end

			local starterMainUi = StarterGui:FindFirstChild("MainUI")
			local starterButton = starterMainUi and starterMainUi:FindFirstChild("ImageButton_攻击", true)
			if starterButton and starterButton:IsA("ImageButton") then
				warn("[UIController] 只在 StarterGui 模板中找到 ImageButton_攻击；运行时仍会继续等待 PlayerGui 副本。")
			end

			return nil
		end

		-- 优先使用 WaitForChild 等 5 秒，如果由于层级深没拿到，再使用递归全局寻找
		local waited = mainGui:WaitForChild("ImageButton_攻击", 5)
		local btn = if waited and waited:IsA("ImageButton") then waited :: ImageButton else findAttackButton()
		
		-- 如果 5 秒后网络还没把按钮发过来，开启后台无限扫描直到它出现为止
		if not btn then
			warn("[UIController] 5秒内未找到 ImageButton_攻击，正在后台持续扫描...")
			while not btn do
				task.wait(1)
				btn = findAttackButton()
			end
		end
		
		attackButton = btn
		attackButton.Visible = false -- 初始状态强制隐藏
		bindButtonPressScaleAnimation(attackButton)
		
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

	-- 自动攻击开关按钮逻辑
	task.spawn(function()
		local autoAttackButton = mainGui:WaitForChild("ImageButton_自动攻击", 5) or mainGui:FindFirstChild("ImageButton_自动攻击", true)
		if not autoAttackButton then
			warn("[UIController] 5秒内未找到 ImageButton_自动攻击，正在后台持续扫描...")
			while not autoAttackButton do
				task.wait(1)
				autoAttackButton = mainGui:FindFirstChild("ImageButton_自动攻击", true)
			end
		end

		if not autoAttackButton:IsA("GuiButton") then
			warn("[UIController] ImageButton_自动攻击 不是 GuiButton，无法绑定点击事件")
			return
		end

		local openAttackUI = autoAttackButton:FindFirstChild("开启攻击", true)
		local closeAttackUI = autoAttackButton:FindFirstChild("关闭攻击", true)
		local autoAttackStateText = autoAttackButton:FindFirstChild("开/关速度状态", true)

		local function updateAutoAttackUI()
			local enabled = player:GetAttribute(AUTO_ATTACK_ENABLED_ATTRIBUTE) == true

			if openAttackUI and openAttackUI:IsA("GuiObject") then
				openAttackUI.Visible = not enabled
			end

			if closeAttackUI and closeAttackUI:IsA("GuiObject") then
				closeAttackUI.Visible = enabled
			end

			if autoAttackStateText and autoAttackStateText:IsA("TextLabel") then
				autoAttackStateText.Text = enabled and "Attack: On" or "Attack: Off"--自动攻击: 开/关
			end
		end

		if player:GetAttribute(AUTO_ATTACK_ENABLED_ATTRIBUTE) == nil then
			player:SetAttribute(AUTO_ATTACK_ENABLED_ATTRIBUTE, false)
		end

		updateAutoAttackUI()
		player:GetAttributeChangedSignal(AUTO_ATTACK_ENABLED_ATTRIBUTE):Connect(updateAutoAttackUI)

		autoAttackButton.Activated:Connect(function()
			local enabled = player:GetAttribute(AUTO_ATTACK_ENABLED_ATTRIBUTE) == true
			player:SetAttribute(AUTO_ATTACK_ENABLED_ATTRIBUTE, not enabled)
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
				if speedToggleText then speedToggleText.Text = "[T] Slow:OFF" end
			else
				if normalSpeedBgOn then normalSpeedBgOn.Visible = false end
				if normalSpeedBgOff then normalSpeedBgOff.Visible = true end
				if speedToggleText then speedToggleText.Text = "[T] Slow:ON" end --UI显示关闭加速文字
			end
		end

		updateSpeedUI()

		local function toggleSpeedMode()
			isNormalSpeedActive = not isNormalSpeedActive 
			updateSpeedUI()
			applyCurrentSpeed()
		end

		speedToggleButton.Activated:Connect(toggleSpeedMode)

		UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
			if gameProcessedEvent or input.UserInputType ~= Enum.UserInputType.Keyboard then
				return
			end

			if input.KeyCode == Enum.KeyCode.T then
				toggleSpeedMode()
			end
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