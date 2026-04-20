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

function UIController.Init() -- [修改内容] 暴露初始化接口供外部调用
	-- 1. 金币同步
	local function refreshGold() goldLabel.Text = formatNumberShort(player:GetAttribute("Gold") or 0) end
	player:GetAttributeChangedSignal("Gold"):Connect(refreshGold)
	refreshGold()

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