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
local ContextActionService = game:GetService("ContextActionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local UserInputService = game:GetService("UserInputService")

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
local requestPromptInteraction = remotes:WaitForChild("RequestPromptInteraction") :: RemoteEvent
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

-- [修改内容] 按照新层级，先获取 GoldFrame 容器，再定位内部的 GoldLabel
local goldFrame = mainGui:WaitForChild("GoldFrame")
local goldLabel = goldFrame:WaitForChild("GoldLabel") :: TextLabel
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
	-- [修改内容] 更新文本显示方式。如果您的新 UI 已经带了金币图标，
	-- 这里通常直接显示格式化后的数字即可。
	-- 如果您仍需要 "Gold: " 前缀，请改回 string.format("Gold: %s", ...)
	goldLabel.Text = formatNumberShort(getGold())
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
	for _, child in ipairs(bb:GetDescendants()) do
		if child:IsA("TextLabel") then
			return child
		end
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

local visiblePrompts: {[ProximityPrompt]: true} = {}

local function debugPromptPath(prompt: ProximityPrompt?): string
	if not prompt then
		return "nil"
	end
	local ok, fullName = pcall(function()
		return prompt:GetFullName()
	end)
	return ok and fullName or prompt.Name
end

ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
	visiblePrompts[prompt] = true

end)

ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
	visiblePrompts[prompt] = nil
end)
ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, triggerPlayer: Player)
end)

ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt: ProximityPrompt, triggerPlayer: Player)

end)

ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt: ProximityPrompt, triggerPlayer: Player)

end)

local function promptDebugActionHandler(
	actionName: string,
	inputState: Enum.UserInputState,
	inputObject: InputObject
): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	return Enum.ContextActionResult.Pass
end

ContextActionService:BindActionAtPriority(
	"PromptDebug_E",
	promptDebugActionHandler,
	false,
	3000,
	Enum.KeyCode.E
)

ContextActionService:BindActionAtPriority(
	"PromptDebug_R",
	promptDebugActionHandler,
	false,
	3000,
	Enum.KeyCode.R
)

ContextActionService:BindActionAtPriority(
	"PromptDebug_F",
	promptDebugActionHandler,
	false,
	3000,
	Enum.KeyCode.F
)

UserInputService.TextBoxFocused:Connect(function(textBox: TextBox)

end)

UserInputService.TextBoxFocusReleased:Connect(function(textBox: TextBox)

end)

UserInputService.LastInputTypeChanged:Connect(function(lastInputType: Enum.UserInputType)

end)

UserInputService.WindowFocused:Connect(function()
end)

UserInputService.WindowFocusReleased:Connect(function()
end)

local function findBestVisiblePromptForKey(keyCode: Enum.KeyCode): ProximityPrompt?
	local hrp = getHRP()
	if not hrp then
		return nil
	end

	local bestPrompt: ProximityPrompt? = nil
	local bestDistance = math.huge
	local candidateCount = 0

	for prompt in pairs(visiblePrompts) do
		if prompt.Parent == nil then
			visiblePrompts[prompt] = nil
			continue
		end
		if not prompt.Enabled then
			continue
		end
		if prompt.KeyboardKeyCode ~= keyCode then
			continue
		end

		local parent = prompt.Parent
		if not (parent and parent:IsA("BasePart")) then
			continue
		end

		local dist = (hrp.Position - parent.Position).Magnitude
		candidateCount += 1

		if dist <= (prompt.MaxActivationDistance + 2) and dist < bestDistance then
			bestDistance = dist
			bestPrompt = prompt
		end
	end

	return bestPrompt
end

local function tryFirePromptInteractionFromKeyboard(keyCode: Enum.KeyCode, source: string)
	local prompt = findBestVisiblePromptForKey(keyCode)
	if prompt then
		-- 不再在按键按下瞬间手动 FireServer。
		-- 之前这会绕过 Roblox 原生 ProximityPrompt 的 HoldDuration，
		-- 导致像“收起/卖出/解锁”这类本应长按的交互变成一按就触发。
		-- 现在改为完全交给 ProximityPrompt 自己处理按住与触发时机。
		return
	else
		return
	end
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if input.KeyCode ~= Enum.KeyCode.E and input.KeyCode ~= Enum.KeyCode.R and input.KeyCode ~= Enum.KeyCode.F then
		return
	end

	tryFirePromptInteractionFromKeyboard(input.KeyCode, "InputBegan")
end)

UserInputService.InputEnded:Connect(function(input: InputObject, gameProcessedEvent: boolean)
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if input.KeyCode ~= Enum.KeyCode.E and input.KeyCode ~= Enum.KeyCode.R and input.KeyCode ~= Enum.KeyCode.F then
		return
	end


	if gameProcessedEvent then
		return
	end
end)

local keyDownDebugState = {
	[Enum.KeyCode.E] = false,
	[Enum.KeyCode.R] = false,
	[Enum.KeyCode.F] = false,
}



local function updateMonsterText(monsterPart: BasePart)
	-- [修改内容] 最终版本：包含文字独立分配 + 距离隐藏 + 实时动态计算 UI 大小
	local bb = monsterPart:FindFirstChild("MonsterBillboard")
	if not bb or not bb:IsA("BillboardGui") then
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

	-- 显示/隐藏的总距离控制
	local showDist = 30
	local detailDist = (Config.MONSTER_DETAIL_SHOW_DISTANCE or 6)

	bb.Enabled = dist <= showDist
	if not bb.Enabled then
		return
	end

	-- ==========================================
	-- 【核心修复：恢复并强化根据距离实时刷新的逻辑】
	-- ==========================================
	-- 1. 恢复原始的完整尺寸（不再除以 2！）你可以根据需要调大这两个数字
	local baseW, baseH = 260, 90 
	
	-- 2. 计算距离比例 (t: 0代表完全贴脸，1代表达到最远可视距离)
	local t = math.clamp(dist / showDist, 0, 1)
	
	-- 3. 调整缩放倍率！
	local maxScale = 1.5  -- 贴脸时放大到 1.5 倍（之前是 1.2）
	local minScale = 1  -- 离远时缩小到 0.8 倍（之前是 0.55，太小了）
	
	-- 4. 实时计算当前帧的最终比例，并强制刷新大小
	local scale = maxScale + (minScale - maxScale) * t
	bb.Size = UDim2.fromOffset(math.floor(baseW * scale), math.floor(baseH * scale))
	-- ==========================================

	local level = monsterPart:GetAttribute("MonsterLevel") or 1
	local hp = monsterPart:GetAttribute("HP") or 0
	local maxHp = monsterPart:GetAttribute("MaxHP") or 0
	local value = monsterPart:GetAttribute("Value") or 0
	local gps = monsterPart:GetAttribute("GoldPerSec") or 0
	local dead = monsterPart:GetAttribute("Dead") == true

	local remainText = string.format("剩余: %ds", remain)

	-- 1. 更新【等级+血量】节点
	local statsLabel = bb:FindFirstChild("等级+血量")
	if statsLabel and statsLabel:IsA("TextLabel") then
		statsLabel.Text = string.format("Lv.%d  HP:%d/%d", level, hp, maxHp)
	end

	-- 2. 更新【剩余】节点
	local timeLabel = bb:FindFirstChild("剩余")
	if timeLabel and timeLabel:IsA("TextLabel") then
		timeLabel.Text = remainText
	end

	-- 3. 更新【价值】节点
	local valueLabel = bb:FindFirstChild("价值+每秒+x金币")
	if valueLabel and valueLabel:IsA("TextLabel") then
		if dead then
			valueLabel.Text = "已死亡(可收起)"
			valueLabel.Visible = true
		else
			if dist > detailDist then
				-- 距离较远时隐藏
				valueLabel.Visible = false
			else
				-- 靠近时显示
				valueLabel.Visible = true
				valueLabel.Text = string.format("价值:%s  +%s/s", formatNumberShort(value), formatNumberShort(gps))
			end
		end
	end

	-- [兜底逻辑] 如果模板里依然有旧的 "Label"，直接隐藏它，防止干扰
	local oldLabel = bb:FindFirstChild("Label")
	if oldLabel and oldLabel:IsA("TextLabel") then
		oldLabel.Visible = false
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
	if acc < 0.2 then
		-- continue below for per-frame key polling while prompts are visible
	else
		acc = 0

		untrackDestroyed()
		for _, t in ipairs(tracked) do
			updateMonsterText(t.Part)
		end
	end

	local visiblePromptCount = 0
	for _ in pairs(visiblePrompts) do
		visiblePromptCount += 1
	end

	if visiblePromptCount <= 0 then
		for keyCode, wasDown in pairs(keyDownDebugState) do
			if wasDown then
				keyDownDebugState[keyCode] = false
			end
		end
		return
	end

	for _, keyCode in ipairs({Enum.KeyCode.E, Enum.KeyCode.R, Enum.KeyCode.F}) do
		local isDown = UserInputService:IsKeyDown(keyCode)
		local wasDown = keyDownDebugState[keyCode]
		if isDown ~= wasDown then
			keyDownDebugState[keyCode] = isDown


			if isDown then
				-- 仅保留状态跟踪，不再主动触发 Prompt 交互。
				tryFirePromptInteractionFromKeyboard(keyCode, "IsKeyDownPoll")
			end
		end
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
	
	-- [修改内容] 设置UI的对齐锚点。Vector2.new(1, 0) 代表将按钮的“右上角”作为定位的参考点。
	clearBtn.AnchorPoint = Vector2.new(0, 1)
	
	-- [修改内容] 设置UI的实际坐标。UDim2.new(X比例, X偏移, Y比例, Y偏移)
	-- 这里的 (1, -10, 0, 8) 意味着：
	-- X轴：父级窗口宽度 100% 的位置，向左偏移 10 个像素（即紧贴右边缘）
	-- Y轴：父级窗口高度 0% 的位置，向下偏移 8 个像素（即紧贴上边缘）
	clearBtn.Position = UDim2.new(1, -10, 0, 8)
	
	clearBtn.Size = UDim2.fromOffset(92, 24)
	clearBtn.BackgroundColor3 = Color3.fromRGB(75, 87, 255)
	clearBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	clearBtn.Font = Enum.Font.GothamBold
	clearBtn.TextScaled = true
	clearBtn.Text = "清空数据测试"
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


	-- 1. 获取容器
	local buyFrame = row:FindFirstChild("购买UIFrame")
	if buyFrame then
		-- 2. [修改内容] 直接在容器内寻找真正的按钮组件 (如 TextButton 或 ImageButton)
		local actionBtn = buyFrame:FindFirstChildWhichIsA("GuiButton")

		if actionBtn then
			-- 3. 更新按钮上的文字状态 (显示：购买 / 装备 / 卸下)
			if actionBtn:IsA("TextButton") then
				actionBtn.Text = buttonText
			else
				-- [修改内容] 如果按钮是图片按钮，则尝试寻找容器内的 TextLabel 来显示文字
				local textLabel = buyFrame:FindFirstChildWhichIsA("TextLabel")
				if textLabel then 
					textLabel.Text = buttonText 
				end
			end
			
			-- 4. 绑定点击触发逻辑
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

--升级商店布局

local upgradeLayout = upgradeList:FindFirstChildOfClass("UIListLayout")
if not upgradeLayout then
	upgradeLayout = Instance.new("UIListLayout")
	upgradeLayout.Padding = UDim.new(0, 10)
	upgradeLayout.Parent = upgradeList
end

-- [修改内容] 1. 尝试获取你在 UI 里做好的模板，并在初始化时将其隐藏，避免它作为实体显示在列表中
local upgradeTemplate = upgradeWindow:FindFirstChild("RowTemplate") :: GuiObject?
if upgradeTemplate then
	upgradeTemplate.Visible = false
end

local function getLevelAttr(name: string, default: number): number
	local v = player:GetAttribute(name)
	if type(v) ~= "number" then
		return default
	end
	return v
end

-- [修改内容] 2. 修改升级行的生成逻辑
local function buildUpgradeRow(titleText: string, infoText: string, onBuy: () -> ())
	-- 如果找到了你的自定义模板，就优先使用模板逻辑
	if upgradeTemplate and upgradeTemplate:IsA("GuiObject") then
		local row = upgradeTemplate:Clone()
		row.Name = "UpgradeRow_" .. titleText
		row.Visible = true
		row.Parent = upgradeList

		-- 绑定标题（如：升级攻击力）
		local titleLabel = row:FindFirstChild("升级目标")
		if titleLabel and titleLabel:IsA("TextLabel") then
			titleLabel.Text = titleText
		end

		-- 绑定花费与增加数值（如：花费:10w  +10 攻击力）
		local infoLabel = row:FindFirstChild("花费+增加数值")
		if infoLabel and infoLabel:IsA("TextLabel") then
			infoLabel.Text = infoText
		end

		-- 绑定升级按钮的点击事件
		local btn = row:FindFirstChild("升级按钮")
		if btn then
			local actionBtn = btn
			if not btn:IsA("GuiButton") then
				-- 如果“升级按钮”是个Frame，尝试找里面的真正的Button
				actionBtn = btn:FindFirstChildWhichIsA("GuiButton")
			end
			
			if actionBtn and actionBtn:IsA("GuiButton") then
				actionBtn.Activated:Connect(function()
					onBuy()
				end)
			end
		end

		return -- 模板生成完毕后直接返回，跳过下方的旧版代码
	end

	-- [兜底逻辑] 如果没有找到模板，继续使用原版代码动态生成 Frame
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
-- Home 头像显示：离开出生点 20 单位后显示，回到范围内隐藏
-- 仅本地创建，因此只有玩家自己可见
-- 模板来源：Workspace.区域.HOME头像name.part.BillboardGui
-- =====================

local HEAD_DISPLAY_DISTANCE = 40
local HEAD_TEMPLATE_FOLDER_NAME = "区域"
local HEAD_TEMPLATE_ROOT_NAME = "HOME头像name"
local HEAD_TEMPLATE_GUI_NAME = "BillboardGui"
local HEAD_CLONE_GUI_NAME = "Head"

local currentHeadGui: BillboardGui? = nil
local currentHeadSpawnPoint: BasePart? = nil
local currentHeadHomeRoot: Instance? = nil
local currentHeadCharacter: Model? = nil
local currentHeadHumanoidRootPart: BasePart? = nil

local function getHeadAvatarThumbnail(): string
	local ok, content = pcall(function()
		return Players:GetUserThumbnailAsync(
			player.UserId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size420x420
		)
	end)

	if ok then
		return content
	end

	return ""
end

local headAvatarImage = getHeadAvatarThumbnail()
local headDisplayPlayerName = player.DisplayName ~= "" and player.DisplayName or player.Name

local function findHeadTemplateBillboardGui(): BillboardGui?
	local regionFolder = workspace:FindFirstChild(HEAD_TEMPLATE_FOLDER_NAME)
	if regionFolder then
		local root = regionFolder:FindFirstChild(HEAD_TEMPLATE_ROOT_NAME, true)
		if root then
			local gui = root:FindFirstChild(HEAD_TEMPLATE_GUI_NAME, true)
			if gui and gui:IsA("BillboardGui") then
				return gui
			end
		end
	end

	for _, descendant in ipairs(workspace:GetDescendants()) do
		if descendant:IsA("BillboardGui") and descendant.Name == HEAD_TEMPLATE_GUI_NAME then
			local parentInstance = descendant.Parent
			if parentInstance and parentInstance.Name == HEAD_TEMPLATE_ROOT_NAME then
				return descendant
			end
		end
	end

	return nil
end

local function findOwnedHomeForHead(): Instance?
	local homeFolder = workspace:FindFirstChild("HOME")
	if not homeFolder then
		return nil
	end

	for _, child in ipairs(homeFolder:GetChildren()) do
		if child:GetAttribute("OwnerUserId") == player.UserId then
			return child
		end
	end

	return nil
end

local function findHeadSpawnPoint(homeRoot: Instance?): BasePart?
	if not homeRoot then
		return nil
	end

	local spawnPoint = homeRoot:FindFirstChild("出生点", true)
	if spawnPoint and spawnPoint:IsA("BasePart") then
		return spawnPoint
	end

	return nil
end

local function destroyHeadGui()
	if currentHeadGui then
		currentHeadGui:Destroy()
		currentHeadGui = nil
	end
end

local function setHeadGuiVisible(isVisible: boolean)
	if currentHeadGui then
		currentHeadGui.Enabled = isVisible
	end
end

local function ensureHeadGui(spawnPoint: BasePart): BillboardGui?
	if currentHeadGui and currentHeadGui.Parent == spawnPoint then
		return currentHeadGui
	end

	destroyHeadGui()

	local templateGui = findHeadTemplateBillboardGui()
	if not templateGui then
		warn("[HeadDisplay] 未找到头像模板 BillboardGui，请检查 Workspace.区域.HOME头像name.part.BillboardGui")
		return nil
	end

	local clonedGui = templateGui:Clone()
	clonedGui.Name = HEAD_CLONE_GUI_NAME
	clonedGui.Adornee = spawnPoint
	clonedGui.Parent = spawnPoint
	clonedGui.Enabled = false

	local imageLabel = clonedGui:FindFirstChild("ImageLabel", true)
	if imageLabel and imageLabel:IsA("ImageLabel") then
		imageLabel.Image = headAvatarImage
	end

	local textLabel = clonedGui:FindFirstChild("TextLabel", true)
	if textLabel and textLabel:IsA("TextLabel") then
		textLabel.Text = headDisplayPlayerName
	end

	currentHeadGui = clonedGui
	return clonedGui
end

local function refreshHeadCharacterReferences(character: Model?)
	currentHeadCharacter = character
	currentHeadHumanoidRootPart = nil

	if not character then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		currentHeadHumanoidRootPart = hrp
		return
	end

	task.spawn(function()
		local found = character:WaitForChild("HumanoidRootPart", 5)
		if found and found:IsA("BasePart") and currentHeadCharacter == character then
			currentHeadHumanoidRootPart = found
		end
	end)
end

local function refreshHeadHomeReferences()
	local homeRoot = findOwnedHomeForHead()
	currentHeadHomeRoot = homeRoot
	currentHeadSpawnPoint = findHeadSpawnPoint(homeRoot)

	if currentHeadSpawnPoint then
		ensureHeadGui(currentHeadSpawnPoint)
	else
		destroyHeadGui()
	end
end

refreshHeadCharacterReferences(player.Character)
refreshHeadHomeReferences()

player.CharacterAdded:Connect(function(character)
	refreshHeadCharacterReferences(character)
	setHeadGuiVisible(false)
end)

player.CharacterRemoving:Connect(function()
	refreshHeadCharacterReferences(nil)
	setHeadGuiVisible(false)
end)

RunService.Heartbeat:Connect(function()
	if not currentHeadHomeRoot or currentHeadHomeRoot:GetAttribute("OwnerUserId") ~= player.UserId then
		refreshHeadHomeReferences()
	end

	if currentHeadGui and currentHeadSpawnPoint and currentHeadHumanoidRootPart then
		local distance = (currentHeadHumanoidRootPart.Position - currentHeadSpawnPoint.Position).Magnitude
		setHeadGuiVisible(distance > HEAD_DISPLAY_DISTANCE)
	else
		setHeadGuiVisible(false)
	end
end)


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
