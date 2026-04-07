--!strict
-- StarterPlayerScripts.Client
-- 客户端：
-- 1) HUD：左上角金币 + Toast
-- 2) 怪头顶信息：距离显示（远处仅倒计时，近处显示详细），并显示存在时间倒计时
-- 3) 商店 UI：武器商店（滚动列表）/升级商店（攻击/血量/速度）


local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer

-- 提高同时可见 Prompt 上限（默认 16）。
-- 家园升到 2/3 级后可见的“解锁/交互”Prompt 可能变多，
-- 如果达到上限会导致“升级按钮”不显示。
-- 这里提到 64，避免被顶掉。
ProximityPromptService.MaxPromptsVisible = 64

-- 使用官方默认背包/热键栏（武器装备系统）
-- 注意：SetCoreGuiEnabled 可能在客户端刚启动时调用失败，所以这里做重试。
local function enableDefaultBackpack()
	for _ = 1, 40 do
		local ok = pcall(function()
			-- 如果某处把 All 关了，只开 Backpack 可能不生效，所以这里先确保 All=true
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, true)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, true)
		end)
		if ok then
			return
		end
		task.wait(0.1)
	end
	warn("[Client] Failed to enable CoreGui Backpack")
end

task.spawn(enableDefaultBackpack)

player.CharacterAdded:Connect(function()
	-- 有些情况下重生后 CoreGui 状态会被重置/脚本竞争，这里再补一次
	task.delay(0.25, enableDefaultBackpack)
end)

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local toastRemote = remotes:WaitForChild("PushClientToast") :: RemoteEvent
local syncMonsterInventory = remotes:WaitForChild("SyncMonsterInventory") :: RemoteEvent
local requestTakeOutMonsterItem = remotes:WaitForChild("RequestTakeOutMonsterItem") :: RemoteEvent
local requestClearPlayerData = remotes:WaitForChild("RequestClearPlayerData") :: RemoteEvent
local openWeaponShopUI = remotes:WaitForChild("OpenWeaponShopUI") :: RemoteEvent
local openUpgradeShopUI = remotes:WaitForChild("OpenUpgradeShopUI") :: RemoteEvent
local requestPurchaseWeapon = remotes:WaitForChild("RequestPurchaseWeapon") :: RemoteEvent
local requestEquipWeapon = remotes:WaitForChild("RequestEquipWeapon") :: RemoteEvent
local requestPurchaseUpgrade = remotes:WaitForChild("RequestPurchaseUpgrade") :: RemoteEvent

-- =====================
-- HUD：Gold + Toast
-- =====================

-- 使用 StarterGui.MainUI（场景里已存在），避免重复创建 HUD 导致遮挡。
local mainGui = player:WaitForChild("PlayerGui"):WaitForChild("MainUI") :: ScreenGui

local goldLabel = mainGui:WaitForChild("GoldLabel") :: TextLabel
local toast = mainGui:WaitForChild("Toast") :: TextLabel

toast.Visible = false

local toastToken = 0
local function showToast(text: string, seconds: number?)
	toastToken += 1
	local token = toastToken
	toast.Text = text
	toast.Visible = true
	local t = seconds or 2
	task.delay(t, function()
		if toastToken ~= token then
			return
		end
		toast.Visible = false
	end)
end

toastRemote.OnClientEvent:Connect(function(text: string)
	showToast(text)
end)

local function getGold(): number
	local g = player:GetAttribute("Gold")
	if type(g) == "number" then
		return g
	end

	-- 兜底：有些情况下 Attribute 同步会慢一拍，改用 leaderstats 读一次
	local ls = player:FindFirstChild("leaderstats")
	local gold = ls and ls:FindFirstChild("Gold")
	if gold and gold:IsA("IntValue") then
		return gold.Value
	end

	return 0
end

local function formatNumberShort(n: number): string
	-- UI number formatting:
	-- < 1e4: raw number
	-- >= 1e4: w (万)
	-- >= 1e6: M
	-- >= 1e9: B
	-- >= 1e12: T
	-- >= 1e15: Qa
	-- >= 1e18: Qi
	local abs = math.abs(n)
	local units = {
		{ 1e18, "Qi" },
		{ 1e15, "Qa" },
		{ 1e12, "T" },
		{ 1e9, "B" },
		{ 1e6, "M" },
		{ 1e4, "w" },
	}

	for _, u in ipairs(units) do
		local base = u[1] :: number
		local suffix = u[2] :: string
		if abs >= base then
			local v = n / base
			local s: string
			local av = math.abs(v)
			if av >= 100 then
				s = string.format("%.0f", v)
			elseif av >= 10 then
				s = string.format("%.1f", v)
			else
				s = string.format("%.2f", v)
			end
			s = s:gsub("%.?0+$", "")
			return s .. suffix
		end
	end

	return tostring(math.floor(n))
end

local function refreshGold()
	goldLabel.Text = string.format("Gold: %s", formatNumberShort(getGold()))
end

refreshGold()
player:GetAttributeChangedSignal("Gold"):Connect(refreshGold)

-- =====================
-- 怪头顶信息：距离显示 + 倒计时
-- =====================

type TrackedMonster = {
	Part: BasePart,
}

local tracked: {TrackedMonster} = {}
local trackedSet: {[BasePart]: true} = {}

local function findMonsterLabel(monsterPart: BasePart): TextLabel?
	local bb = monsterPart:FindFirstChild("MonsterBillboard")
	if not bb or not bb:IsA("BillboardGui") then
		return nil
	end
	local label = bb:FindFirstChild("Label")
	if label and label:IsA("TextLabel") then
		return label
	end
	return nil
end

local function trackMonster(monsterPart: BasePart)
	if monsterPart:GetAttribute("IsMonster") ~= true then
		return
	end
	if trackedSet[monsterPart] then
		return
	end
	trackedSet[monsterPart] = true

	table.insert(tracked, { Part = monsterPart })
end

local function untrackDestroyed()
	local i = 1
	while i <= #tracked do
		local t = tracked[i]
		if t.Part.Parent == nil then
			trackedSet[t.Part] = nil
			table.remove(tracked, i)
		else
			i += 1
		end
	end
end

local function getHRP(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function updateMonsterText(monsterPart: BasePart)
	local label = findMonsterLabel(monsterPart)
	if not label then
		return
	end

	local expireUnix = monsterPart:GetAttribute("ExpireUnix")
	local remain = 0
	if type(expireUnix) == "number" then
		remain = math.max(0, expireUnix - os.time())
	end

	local hrp = getHRP()
	local dist = 9999
	if hrp then
		dist = (hrp.Position - monsterPart.Position).Magnitude
	end

	-- 显示距离
	local showDist = (Config.MONSTER_INFO_SHOW_DISTANCE or 15)
	local detailDist = (Config.MONSTER_DETAIL_SHOW_DISTANCE or 6)

	local bb = label.Parent
	if bb and bb:IsA("BillboardGui") then
		-- 显示距离
		bb.Enabled = dist <= showDist
		if not bb.Enabled then
			return
		end

		-- 你要求：靠近变大、离远变小；并且整体大小缩小一半
		local baseW, baseH = 130, 45 -- 原来 260x90 的一半
		local t = math.clamp(dist / showDist, 0, 1)
		local maxScale = 1.2
		local minScale = 0.55
		local scale = maxScale + (minScale - maxScale) * t
		bb.Size = UDim2.fromOffset(math.floor(baseW * scale), math.floor(baseH * scale))
	end

	local level = monsterPart:GetAttribute("MonsterLevel") or 1
	local hp = monsterPart:GetAttribute("HP") or 0
	local maxHp = monsterPart:GetAttribute("MaxHP") or 0
	local value = monsterPart:GetAttribute("Value") or 0
	local gps = monsterPart:GetAttribute("GoldPerSec") or 0
	local dead = monsterPart:GetAttribute("Dead") == true

	local remainText = string.format("%ds", remain)

	if dead then
		label.Text = string.format(
			"Lv.%d  HP:%d/%d\n剩余:%s\n已死亡(可收起)",
			level,
			hp,
			maxHp,
			remainText
		)
	else
		if dist > detailDist then
			label.Text = string.format("Lv.%d  HP:%d/%d\n剩余:%s", level, hp, maxHp, remainText)
		else
			label.Text = string.format(
				"Lv.%d  HP:%d/%d\n剩余:%s\n价值:%s  +%s/s",
				level,
				hp,
				maxHp,
				remainText,
				formatNumberShort(value),
				formatNumberShort(gps)
			)
		end
	end
end

local function initMonsterBillboards()
	local function tryTrackFromChild(ch: Instance)
		-- 新版：怪是 Model（内部有 Root BasePart）；旧版也兼容直接 BasePart
		if ch:IsA("Model") and ch:GetAttribute("IsMonster") == true then
			local root = (ch.PrimaryPart :: BasePart?)
				or (ch:FindFirstChild("Root") :: BasePart?)
				or ch:FindFirstChildWhichIsA("BasePart", true)
			if root and root:IsA("BasePart") then
				trackMonster(root)
			end
			return
		end

		if ch:IsA("BasePart") then
			trackMonster(ch)
		end
	end

	local function hookMonstersFolder(monstersFolder: Instance)
		if not monstersFolder:IsA("Folder") then
			return
		end

		for _, ch in ipairs(monstersFolder:GetChildren()) do
			tryTrackFromChild(ch)
		end

		monstersFolder.ChildAdded:Connect(function(ch)
			tryTrackFromChild(ch)
		end)
	end

	local existing = workspace:FindFirstChild("Monsters")
	if existing then
		hookMonstersFolder(existing)
	else
		-- 等服务端创建
		workspace.ChildAdded:Connect(function(ch)
			if ch.Name == "Monsters" then
				hookMonstersFolder(ch)
			end
		end)
	end
end

initMonsterBillboards()

local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < 0.15 then
		return
	end
	acc = 0

	untrackDestroyed()
	for _, t in ipairs(tracked) do
		updateMonsterText(t.Part)
	end
end)

-- =====================
-- 怪物背包 UI（MonsterInventoryWindow）
-- =====================

type MonsterInvItem = {
	ItemId: string,
	MonsterLevel: number,
	Value: number,
	GoldPerSec: number,
}

local monsterInvItems: {MonsterInvItem} = {}

local monsterInventoryWindow = mainGui:WaitForChild("MonsterInventoryWindow") :: Frame
local monsterInventoryList = monsterInventoryWindow:WaitForChild("List") :: ScrollingFrame
local rowTemplate = monsterInventoryWindow:WaitForChild("RowTemplate") :: ImageButton

-- Template should not be visible itself
rowTemplate.Visible = false

local function clearMonsterInvRows()
	for _, ch in ipairs(monsterInventoryList:GetChildren()) do
		if ch:IsA("GuiObject") and ch ~= rowTemplate and not ch:IsA("UIListLayout") then
			ch:Destroy()
		end
	end
end

local function refreshMonsterInventoryUI()
	clearMonsterInvRows()

	for i, it in ipairs(monsterInvItems) do
		local row = rowTemplate:Clone()
		row.Name = "Row_" .. tostring(i)
		row.Visible = true
		row.Parent = monsterInventoryList

		local label = row:FindFirstChild("Label") :: TextLabel?
		if label and label:IsA("TextLabel") then
			label.Text = string.format("怪Lv%d  价值:%s  +%s/s", it.MonsterLevel, formatNumberShort(it.Value), formatNumberShort(it.GoldPerSec))
		end

		local takeOutBtn = row:FindFirstChild("拿出按钮")
		if takeOutBtn and takeOutBtn:IsA("GuiButton") then
			(takeOutBtn :: GuiButton).Activated:Connect(function()
				requestTakeOutMonsterItem:FireServer(it.ItemId)
			end)
		end
	end

	-- Resize canvas
	task.defer(function()
		local layout = monsterInventoryList:FindFirstChildOfClass("UIListLayout")
		if layout then
			monsterInventoryList.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 10)
		end
	end)
end

syncMonsterInventory.OnClientEvent:Connect(function(payload: any)
	monsterInvItems = {}
	if type(payload) == "table" then
		for _, it in ipairs(payload) do
			if type(it) == "table" then
				local item: MonsterInvItem = {
					ItemId = tostring((it :: any).ItemId or ""),
					MonsterLevel = tonumber((it :: any).MonsterLevel) or 1,
					Value = tonumber((it :: any).Value) or 0,
					GoldPerSec = tonumber((it :: any).GoldPerSec) or 0,
				}
				if item.ItemId ~= "" then
					table.insert(monsterInvItems, item)
				end
			end
		end
	end
	refreshMonsterInventoryUI()
end)

-- 测试：清空玩家数据按钮
local clearBtn = monsterInventoryWindow:FindFirstChild("ClearDataButton")
if not (clearBtn and clearBtn:IsA("TextButton")) then
	clearBtn = Instance.new("TextButton")
	clearBtn.Name = "ClearDataButton"
	clearBtn.AnchorPoint = Vector2.new(1, 0)
	clearBtn.Position = UDim2.new(1, -10, 0, 8)
	clearBtn.Size = UDim2.fromOffset(92, 24)
	clearBtn.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
	clearBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	clearBtn.Font = Enum.Font.GothamBold
	clearBtn.TextScaled = true
	clearBtn.Text = "清空数据"
	clearBtn.Parent = monsterInventoryWindow
end

(clearBtn :: TextButton).Activated:Connect(function()
	requestClearPlayerData:FireServer()
	showToast("已发送清空数据请求（测试用）")
end)

local shopsGui = player:WaitForChild("PlayerGui"):WaitForChild("ShopsUI", 5) :: ScreenGui?
if not (shopsGui and shopsGui:IsA("ScreenGui")) then
	shopsGui = Instance.new("ScreenGui")
	shopsGui.Name = "ShopsUI"
	shopsGui.ResetOnSpawn = false
	shopsGui.Enabled = true
	shopsGui.Parent = player:WaitForChild("PlayerGui")
end

local function createWindow(titleText: string): Frame
	local frame = Instance.new("Frame")
	frame.Name = titleText .. "Window"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(620, 420)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.05
	frame.Visible = false
	frame.Parent = shopsGui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 10)
	title.Size = UDim2.fromOffset(400, 36)
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Text = titleText
	title.Parent = frame

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromOffset(frame.Size.X.Offset - 12, 12)
	close.Size = UDim2.fromOffset(90, 32)
	close.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
	close.TextColor3 = Color3.fromRGB(255, 255, 255)
	close.Font = Enum.Font.GothamBold
	close.TextScaled = true
	close.Text = "关闭"
	close.Parent = frame

	return frame
end

local function ensureCloseButton(frame: Frame)
	if frame:GetAttribute("__CloseBound") == true then
		return
	end
	frame:SetAttribute("__CloseBound", true)

	local close = frame:FindFirstChild("Close")
	if close and close:IsA("GuiButton") then
		(close :: GuiButton).Activated:Connect(function()
			frame.Visible = false
		end)
	end
end

-- ===== 武器商店 =====

local weaponWindow = (shopsGui:FindFirstChild("武器商店Window") :: Frame?) or createWindow("武器商店")
ensureCloseButton(weaponWindow)

local weaponInfo = weaponWindow:FindFirstChild("Info") :: TextLabel?
if not (weaponInfo and weaponInfo:IsA("TextLabel")) then
	weaponInfo = Instance.new("TextLabel")
	weaponInfo.Name = "Info"
	weaponInfo.BackgroundTransparency = 1
	weaponInfo.Position = UDim2.fromOffset(16, 52)
	weaponInfo.Size = UDim2.fromOffset(560, 28)
	weaponInfo.TextXAlignment = Enum.TextXAlignment.Left
	weaponInfo.Font = Enum.Font.Gotham
	weaponInfo.TextScaled = true
	weaponInfo.TextColor3 = Color3.fromRGB(220, 220, 220)
	weaponInfo.Text = ""
	weaponInfo.Parent = weaponWindow
end

local weaponList = weaponWindow:FindFirstChild("List") :: ScrollingFrame?
if not (weaponList and weaponList:IsA("ScrollingFrame")) then
	weaponList = Instance.new("ScrollingFrame")
	weaponList.Name = "List"
	weaponList.Position = UDim2.fromOffset(16, 88)
	weaponList.Size = UDim2.fromOffset(588, 316)
	weaponList.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	weaponList.BackgroundTransparency = 0.35
	weaponList.BorderSizePixel = 0
	weaponList.ScrollBarThickness = 8
	weaponList.Parent = weaponWindow
end

local weaponLayout = weaponList:FindFirstChildOfClass("UIListLayout")
if not weaponLayout then
	weaponLayout = Instance.new("UIListLayout")
	weaponLayout.Padding = UDim.new(0, 8)
	weaponLayout.SortOrder = Enum.SortOrder.LayoutOrder
	weaponLayout.Parent = weaponList
end

local weaponItemTemplate = weaponWindow:FindFirstChild("单个武器背景") :: GuiObject?
if weaponItemTemplate then
	weaponItemTemplate.Visible = false
end

local function clearChildren(container: Instance)
	for _, ch in ipairs(container:GetChildren()) do
		if not ch:IsA("UIListLayout") then
			ch:Destroy()
		end
	end
end

local function getWeaponLevel(): number
	local w = player:GetAttribute("WeaponLevel")
	if type(w) ~= "number" then
		return 1
	end
	return w
end

local function getEquippedWeaponLevel(): number
	local w = player:GetAttribute("EquippedWeaponLevel")
	if type(w) ~= "number" then
		return getWeaponLevel()
	end
	return w
end

type WeaponAction = "Buy" | "Equip" | "Unequip"

local function resolveWeaponAction(itemLevel: number): (string, WeaponAction)
	local ownedMaxLevel = getWeaponLevel()
	local equippedLevel = getEquippedWeaponLevel()

	if itemLevel > ownedMaxLevel then
		return "购买武器", "Buy"
	end

	if itemLevel == equippedLevel then
		return "卸下武器", "Unequip"
	end

	return "装备", "Equip"
end

local function sendWeaponAction(action: WeaponAction, itemLevel: number)
	if action == "Buy" then
		requestPurchaseWeapon:FireServer(itemLevel)
	elseif action == "Equip" then
		requestEquipWeapon:FireServer(itemLevel)
	elseif action == "Unequip" then
		-- 约定：卸下武器时切换回 1 级默认武器/空手
		requestEquipWeapon:FireServer(1)
	end
end

local function buildWeaponRow(level: number)
	local attack = Config.WEAPON_ATTACK_BY_LEVEL[level] or 0
	local price = Config.WEAPON_PRICE_BY_LEVEL[level]
	if price == nil then
		return
	end
	local buttonText, action = resolveWeaponAction(level)

	-- 优先使用你在 StarterGui.ShopsUI 里做的模板：武器商店Window.单个武器背景
	if weaponItemTemplate and weaponItemTemplate:IsA("GuiObject") then
		local row = weaponItemTemplate:Clone()
		row.Name = "WeaponRow" .. tostring(level)
		row.LayoutOrder = level
		row.Visible = true
		row.Parent = weaponList

		local nameLabel = row:FindFirstChild("武器名称")
		if nameLabel and nameLabel:IsA("TextLabel") then
			local weaponName = ((Config :: any).WEAPON_NAME_BY_LEVEL and (Config :: any).WEAPON_NAME_BY_LEVEL[level]) or string.format("武器 Lv.%d", level)
			nameLabel.Text = tostring(weaponName)
		end

		local priceAtk = row:FindFirstChild("武器价格/武器攻击力")
		if priceAtk and priceAtk:IsA("TextLabel") then
			priceAtk.Text = string.format("价格:%d  攻击力+%d", price, attack)
		end



-- 绑定自定义的 购买UIFrame
		local buyFrame = row:FindFirstChild("购买UIFrame")
		if buyFrame then
			local actionBtn = buyFrame
			if not buyFrame:IsA("GuiButton") then
				actionBtn = buyFrame:FindFirstChildWhichIsA("GuiButton")
			end

			if actionBtn then
				-- 更新按钮文字状态 (购买/装备/卸下)
				if actionBtn:IsA("TextButton") then
					actionBtn.Text = buttonText
				else
					local textLabel = buyFrame:FindFirstChildWhichIsA("TextLabel")
					if textLabel then textLabel.Text = buttonText end
				end
				
				-- 触发对应逻辑
				actionBtn.Activated:Connect(function()
					sendWeaponAction(action, level)
				end)
			end
		end

		

		return
	end

	-- fallback：旧版本动态创建行
	local row = Instance.new("Frame")
	row.Name = "WeaponRow" .. tostring(level)
	row.LayoutOrder = level
	row.Size = UDim2.fromOffset(570, 70)
	row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	row.BorderSizePixel = 0
	row.Parent = weaponList

	local icon = Instance.new("ViewportFrame")
	icon.Name = "Icon"
	icon.Position = UDim2.fromOffset(10, 8)
	icon.Size = UDim2.fromOffset(54, 54)
	icon.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
	icon.BorderSizePixel = 0
	icon.Parent = row

	local cam = Instance.new("Camera")
	cam.Parent = icon
	icon.CurrentCamera = cam

	local part = Instance.new("Part")
	part.Size = Vector3.new(0.4, 3.2, 0.4)
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Wood
	local t = (level - 1) / 19
	part.Color = Color3.fromRGB(154, 127, 89):Lerp(Color3.fromRGB(120, 120, 120), t)
	part.CFrame = CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(35), math.rad(15))
	part.Parent = icon

	cam.CFrame = CFrame.new(Vector3.new(2.4, 1.5, 2.4), Vector3.new(0, 0.6, 0))

	local nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.Position = UDim2.fromOffset(76, 10)
	nameLabel.Size = UDim2.fromOffset(240, 24)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	local weaponName = ((Config :: any).WEAPON_NAME_BY_LEVEL and (Config :: any).WEAPON_NAME_BY_LEVEL[level]) or string.format("武器 Lv.%d", level)
	nameLabel.Text = tostring(weaponName)
	nameLabel.Parent = row

	local desc = Instance.new("TextLabel")
	desc.BackgroundTransparency = 1
	desc.Position = UDim2.fromOffset(76, 38)
	desc.Size = UDim2.fromOffset(320, 20)
	desc.TextXAlignment = Enum.TextXAlignment.Left
	desc.Font = Enum.Font.Gotham
	desc.TextScaled = true
	desc.TextColor3 = Color3.fromRGB(220, 220, 220)
	desc.Text = string.format("攻击力+%d   价格:%s", attack, formatNumberShort(price))
	desc.Parent = row

	local btn = Instance.new("TextButton")
	btn.Name = "Buy"
	btn.AnchorPoint = Vector2.new(1, 0.5)
	btn.Position = UDim2.new(1, -10, 0.5, 0)
	btn.Size = UDim2.fromOffset(110, 44)
	btn.Font = Enum.Font.GothamBold
	btn.TextScaled = true
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Parent = row
	btn.BackgroundColor3 = Color3.fromRGB(80, 120, 200)
	btn.Text = buttonText
	btn.Activated:Connect(function()
		sendWeaponAction(action, level)
	end)
end

local function refreshWeaponShop()
	weaponInfo.Text = string.format("已拥有最高：Lv.%d   当前装备：Lv.%d", getWeaponLevel(), getEquippedWeaponLevel())
	clearChildren(weaponList)
	for level = 1, 20 do
		buildWeaponRow(level)
	end
	task.delay(0, function()
		weaponList.CanvasSize = UDim2.fromOffset(0, weaponLayout.AbsoluteContentSize.Y + 10)
	end)
end

openWeaponShopUI.OnClientEvent:Connect(function()
	weaponWindow.Visible = true
	refreshWeaponShop()
end)

player:GetAttributeChangedSignal("EquippedWeaponLevel"):Connect(refreshWeaponShop)

player:GetAttributeChangedSignal("WeaponLevel"):Connect(refreshWeaponShop)

player:GetAttributeChangedSignal("Gold"):Connect(function()
	if weaponWindow.Visible then
		refreshWeaponShop()
	end
end)

-- ===== 升级商店 =====

local upgradeWindow = (shopsGui:FindFirstChild("升级商店Window") :: Frame?) or createWindow("升级商店")
ensureCloseButton(upgradeWindow)

local upgradeList = upgradeWindow:FindFirstChild("List") :: Frame?
if not (upgradeList and upgradeList:IsA("Frame")) then
	upgradeList = Instance.new("Frame")
	upgradeList.Name = "List"
	upgradeList.Position = UDim2.fromOffset(16, 60)
	upgradeList.Size = UDim2.fromOffset(588, 344)
	upgradeList.BackgroundTransparency = 1
	upgradeList.Parent = upgradeWindow
end

local upgradeLayout = upgradeList:FindFirstChildOfClass("UIListLayout")
if not upgradeLayout then
	upgradeLayout = Instance.new("UIListLayout")
	upgradeLayout.Padding = UDim.new(0, 10)
	upgradeLayout.Parent = upgradeList
end

local function getLevelAttr(name: string, default: number): number
	local v = player:GetAttribute(name)
	if type(v) ~= "number" then
		return default
	end
	return v
end

local function buildUpgradeRow(titleText: string, infoText: string, onBuy: () -> ())
	local row = Instance.new("Frame")
	row.Size = UDim2.fromOffset(588, 96)
	row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
	row.BorderSizePixel = 0
	row.Parent = upgradeList

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(14, 10)
	title.Size = UDim2.fromOffset(320, 30)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = Enum.Font.GothamBold
	title.TextScaled = true
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Text = titleText
	title.Parent = row

	local info = Instance.new("TextLabel")
	info.BackgroundTransparency = 1
	info.Position = UDim2.fromOffset(14, 46)
	info.Size = UDim2.fromOffset(420, 40)
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.Font = Enum.Font.Gotham
	info.TextScaled = true
	info.TextColor3 = Color3.fromRGB(220, 220, 220)
	info.Text = infoText
	info.Parent = row

	local btn = Instance.new("TextButton")
	btn.AnchorPoint = Vector2.new(1, 0.5)
	btn.Position = UDim2.new(1, -12, 0.5, 0)
	btn.Size = UDim2.fromOffset(110, 50)
	btn.BackgroundColor3 = Color3.fromRGB(80, 120, 200)
	btn.Font = Enum.Font.GothamBold
	btn.TextScaled = true
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Text = "升级"
	btn.Parent = row

	btn.Activated:Connect(function()
		onBuy()
	end)
end

local function refreshUpgradeShop()
	clearChildren(upgradeList)

	local atkLevel = getLevelAttr("AttackLevel", 0)
	local hpLevel = getLevelAttr("HealthLevel", 0)
	local spdLevel = getLevelAttr("SpeedLevel", 0)
	local carryLevel = getLevelAttr("CarryLevel", 0)

	local nextAtkCost = Config.GetAttackUpgradeCost(atkLevel + 1)
	local nextHpCost = Config.GetHealthUpgradeCost(hpLevel + 1)
	local nextSpdCost = Config.GetSpeedUpgradeCost(spdLevel + 1)
	local nextCarryCost = (Config.GetCarryUpgradeCost and Config.GetCarryUpgradeCost(carryLevel + 1)) or nil

	buildUpgradeRow(
		"升级攻击力",
		string.format("花费:%s   +%d 攻击力", formatNumberShort(nextAtkCost), Config.ATTACK_UPGRADE_ADD),
		function()
			requestPurchaseUpgrade:FireServer("Attack")
		end
	)

	buildUpgradeRow(
		"升级血量",
		string.format("花费:%s   +%d 最大血量", formatNumberShort(nextHpCost), Config.HEALTH_PER_UPGRADE),
		function()
			requestPurchaseUpgrade:FireServer("Health")
		end
	)

	buildUpgradeRow(
		"升级速度",
		string.format("花费:%s   +%d 速度", formatNumberShort(nextSpdCost), Config.WALK_SPEED_PER_UPGRADE),
		function()
			requestPurchaseUpgrade:FireServer("Speed")
		end
	)

	-- 携带怪数量升级（最多 5）
	local curMaxCarry = (Config.GetCarryMax and Config.GetCarryMax(carryLevel)) or (1 + carryLevel)
	local nextMaxCarry = (Config.GetCarryMax and Config.GetCarryMax(carryLevel + 1)) or (1 + carryLevel + 1)
	local carryInfo: string
	if nextCarryCost == nil then
		carryInfo = string.format("当前可携带:%d（已满级）", curMaxCarry)
	else
		carryInfo = string.format("花费:%s   可携带:%d → %d", formatNumberShort(nextCarryCost), curMaxCarry, nextMaxCarry)
	end

	buildUpgradeRow(
		"升级携带数量",
		carryInfo,
		function()
			requestPurchaseUpgrade:FireServer("Carry")
		end
	)
end

openUpgradeShopUI.OnClientEvent:Connect(function()
	upgradeWindow.Visible = true
	refreshUpgradeShop()
end)

local function hookRefreshOnAttr(attrName: string)
	player:GetAttributeChangedSignal(attrName):Connect(function()
		if upgradeWindow.Visible then
			refreshUpgradeShop()
		end
	end)
end

hookRefreshOnAttr("Gold")
hookRefreshOnAttr("AttackLevel")
hookRefreshOnAttr("HealthLevel")
hookRefreshOnAttr("SpeedLevel")
hookRefreshOnAttr("CarryLevel")


-- =====================
-- 背包按钮：显示/隐藏“怪物背包”窗口（MainUI.MonsterInventoryWindow）
-- 说明：这不是 Roblox CoreGui 的背包界面；CoreGui 背包保持启用。
-- =====================

local backpackButton = mainGui:WaitForChild("BackpackButton", 10)

if backpackButton and backpackButton:IsA("GuiButton") then
	local function setOpen(open: boolean)
		monsterInventoryWindow.Visible = open
	end

	(backpackButton :: GuiButton).Activated:Connect(function()
		setOpen(not monsterInventoryWindow.Visible)
	end)
else
	warn("[Client] MainUI.BackpackButton missing")
end

showToast("客户端已启动")
