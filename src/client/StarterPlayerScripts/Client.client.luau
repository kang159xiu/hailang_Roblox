--!strict
-- StarterPlayerScripts.Client
-- 客户端：
-- 1) HUD：左上角金币 + Toast
-- 2) 怪头顶信息：距离显示（远处仅倒计时，近处显示详细），并显示存在时间倒计时
-- 3) 商店 UI：武器商店（滚动列表）/升级商店（攻击/血量/速度）
--

--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local ContextActionService = game:GetService("ContextActionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

-- [修改内容] 引入新创建的 UI 控制器模块
local UIController = require(script.Parent:WaitForChild("UIController"))
local TutorialController = require(script.Parent:WaitForChild("TutorialController"))

-- 启动 UI 逻辑
task.spawn(function()
    UIController.Init()
end)

task.spawn(function()
	TutorialController.Init()
end)

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

-- [修改内容] 移除已被 UIController 接管的 UI Remotes
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local showDamageNumberRemote = remotes:WaitForChild("ShowDamageNumber") :: RemoteEvent

-- =====================
-- 伤害数字：克隆 Workspace.区域.伤害数字 模板，从怪物头顶弹出后向下飘落并淡出
-- =====================

local function findDamageNumberTemplate(): BasePart?
	local areaFolder = workspace:FindFirstChild("区域")
	local template = areaFolder and areaFolder:FindFirstChild("伤害数字")
	if template and template:IsA("BasePart") then
		return template
	end
	warn("[DamageNumber] 未找到模板：Workspace.区域.伤害数字，需要是一个 Part，内部包含 BillboardGui/TextLabel")
	return nil
end

local function findFirstTextLabel(root: Instance): TextLabel?
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("TextLabel") then
			return descendant
		end
	end
	return nil
end

local function setBillboardEnabledAndAdornee(rootPart: BasePart)
	for _, descendant in ipairs(rootPart:GetDescendants()) do
		if descendant:IsA("BillboardGui") then
			descendant.Enabled = true
			descendant.AlwaysOnTop = true
			descendant.Adornee = rootPart
		end
	end
end

local function playDamageNumber(originPosition: Vector3, monsterHeight: number, damage: number)
	if type(damage) ~= "number" or damage <= 0 then
		return
	end

	local template = findDamageNumberTemplate()
	if not template then
		return
	end

	local numberPart = template:Clone()
	numberPart.Name = "DamageNumber"
	numberPart.Anchored = true
	numberPart.CanCollide = false
	numberPart.CanQuery = false
	numberPart.CanTouch = false
	numberPart.Transparency = 1

	local startOffset = Vector3.new(
		math.random(-100, 100) / 100,
		(math.max(monsterHeight, 1) * 0.5) + 3,--上升高度
		math.random(-100, 100) / 100
	)
	local driftOffset = Vector3.new(
		math.random(-120, 120) / 100,
		-8,--掉落高度
		math.random(-120, 120) / 100
	)
	local startPosition = originPosition + startOffset
	local endPosition = startPosition + driftOffset
	numberPart.CFrame = CFrame.new(startPosition)
	numberPart.Parent = workspace

	setBillboardEnabledAndAdornee(numberPart)

	local label = findFirstTextLabel(numberPart)
	if label then
		label.Text = string.format("-%d", math.floor(damage + 0.5))
		label.TextColor3 = Color3.fromRGB(255, 0, 0)
		label.TextStrokeColor3 = Color3.fromRGB(20, 10, 0)
		label.TextStrokeTransparency = 0
		label.TextTransparency = 0
		label.Visible = true
	end

	local moveTween = TweenService:Create(
		numberPart,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),--0.9掉落速度
		{ CFrame = CFrame.new(endPosition) }
	)
	moveTween:Play()

	if label then
		local popTween = TweenService:Create(
			label,
			TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ TextSize = math.max(label.TextSize, 34) }
		)
		local fadeTween = TweenService:Create(
			label,
			TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1, TextStrokeTransparency = 1 }
		)
		popTween:Play()
		task.delay(0.45, function()
			if label and label.Parent then
				fadeTween:Play()
			end
		end)
	end

	task.delay(1, function()
		if numberPart and numberPart.Parent then
			numberPart:Destroy()
		end
	end)
end

showDamageNumberRemote.OnClientEvent:Connect(function(originPosition: Vector3, monsterHeight: number, damage: number)
	playDamageNumber(originPosition, monsterHeight, damage)
end)


-- =====================
-- 怪头顶信息：距离显示 + 倒计时
-- =====================

type TrackedMonster = {
	Part: BasePart,
}

local tracked: {TrackedMonster} = {}
local trackedSet: {[BasePart]: true} = {}

-- 与武器客户端的攻击范围保持一致：3 格。
-- 之前这里写死 10 studs，若 GRID_STUDS=4，则实际攻击范围是 12 studs，
-- 会出现“能攻击/自动攻击范围内，但攻击按钮不显示”的不一致。
local ATTACK_BUTTON_SHOW_DISTANCE = 3 * (Config.GRID_STUDS or 4)


local function isTrackableAttackTarget(part: BasePart): boolean
	if part:GetAttribute("IsMonster") == true then
		return true
	end

	return false
end

local function trackMonster(monsterPart: BasePart)
	if not isTrackableAttackTarget(monsterPart) then
		return
	end
	if trackedSet[monsterPart] then
		return
	end
	trackedSet[monsterPart] = true

	table.insert(tracked, { Part = monsterPart })
end

local function findMonsterRootPart(inst: Instance): BasePart?
	-- 新版怪物通常是 Model，IsMonster 可能挂在外层 Model 和内部根 BasePart 上。
	-- 为了避免 PrimaryPart 尚未复制到客户端、或根部件不叫 Root 导致漏追踪，
	-- 这里优先找自身/PrimaryPart，再递归找可作为攻击按钮距离目标的 BasePart。
	if inst:IsA("BasePart") and isTrackableAttackTarget(inst) then
		return inst
	end

	if inst:IsA("Model") then
		local primary = inst.PrimaryPart
		if primary and isTrackableAttackTarget(primary) then
			return primary
		end
	end

	for _, descendant in ipairs(inst:GetDescendants()) do
		if descendant:IsA("BasePart") and isTrackableAttackTarget(descendant) then
			return descendant
		end
	end

	return nil
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
		-- 这里不再手动 FireServer。
		-- 怪物尸体 CollectPrompt 现在统一依赖原生 ProximityPrompt.Triggered，
		-- 这样既能保留“按一下 E 收取”，也不会和服务端原生链路发生双触发。
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



-- [修改内容] 引入必要的数值格式化工具
local function formatNumberShort(n: number): string
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
    
    local formatted = (value >= 100) and string.format("%.0f", value) 
                   or (value >= 10 and string.format("%.1f", value) 
                   or string.format("%.2f", value))

    if string.find(formatted, "%.") then
        formatted = string.gsub(formatted, "0+$", "")
        formatted = string.gsub(formatted, "%.$", "")
    end

    return (n < 0 and "-" or "") .. formatted .. suffixes[suffixIndex]
end



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
	local showDist = 150
	local detailDist = (Config.MONSTER_DETAIL_SHOW_DISTANCE or 6)

	bb.Enabled = dist <= showDist
	if not bb.Enabled then
		return
	end

	local level = monsterPart:GetAttribute("MonsterLevel") or 1
	local hp = monsterPart:GetAttribute("HP") or 0
	local maxHp = monsterPart:GetAttribute("MaxHP") or 0
	local value = monsterPart:GetAttribute("Value") or 0
	local gps = monsterPart:GetAttribute("GoldPerSec") or 0
	local dead = monsterPart:GetAttribute("Dead") == true

	local remainText = string.format("%ds", remain)

	-- 1. 更新【等级+血量】节点
	local statsLabel = bb:FindFirstChild("等级+血量")
	if statsLabel and statsLabel:IsA("TextLabel") then
		statsLabel.Text = string.format("[Lv. %d]  HP:%d/%d", level, hp, maxHp)
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
			valueLabel.Text = "Dead (Collectible)"--已死亡(可收起)
			valueLabel.Visible = true
		else
			if dist > detailDist then
				-- 距离较远时隐藏
				valueLabel.Visible = false
			else
				-- 靠近时显示
				valueLabel.Visible = true
				valueLabel.Text = string.format("$%s/s", formatNumberShort(gps))
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
		-- 新版：怪是 Model（内部有带 IsMonster 的根 BasePart）；旧版也兼容直接 BasePart。
		local root = findMonsterRootPart(ch)
		if root then
			trackMonster(root)
			return
		end

		-- 某些情况下 Model 先复制到客户端，Attribute/PrimaryPart 稍后才可用；延迟一帧再兜底追踪一次。
		task.defer(function()
			local deferredRoot = findMonsterRootPart(ch)
			if deferredRoot then
				trackMonster(deferredRoot)
			end
		end)
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

	workspace.DescendantAdded:Connect(function(descendant)
		if descendant:IsDescendantOf(workspace:FindFirstChild("Monsters") or workspace) and (descendant:IsA("BasePart") or descendant:IsA("Model")) then
			tryTrackFromChild(descendant)
		end
	end)
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
		
		-- [修改内容] 计算最近的活体怪物距离，用于控制攻击按钮
		local closestDist = 9999
		local hrp = getHRP()
		
		for _, t in ipairs(tracked) do
			updateMonsterText(t.Part)
			
			-- 只有当玩家存在，且该怪物还没死的情况下，才计算是否要弹出攻击按钮
			if hrp and t.Part:GetAttribute("Dead") ~= true then
				local dist = (hrp.Position - t.Part.Position).Magnitude
				if dist < closestDist then
					closestDist = dist
				end
			end
		end
		
		-- [修改内容] 如果最近的活怪进入武器攻击范围，显示攻击按钮，否则隐藏
		if UIController.SetAttackButtonVisible then
			UIController.SetAttackButtonVisible(closestDist <= ATTACK_BUTTON_SHOW_DISTANCE)
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





-- [修改内容] 插入完整的商店 UI 逻辑块，负责窗口创建、内容刷新和交互

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
	close.Text = "Close"
	close.Parent = frame
	close.Activated:Connect(function() frame.Visible = false end)

	return frame
end

-- =====================
-- Home 头像显示：一直显示
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
			local grandParentInstance = parentInstance and parentInstance.Parent

			if (parentInstance and parentInstance.Name == HEAD_TEMPLATE_ROOT_NAME)
				or (grandParentInstance and grandParentInstance.Name == HEAD_TEMPLATE_ROOT_NAME) then
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
	clonedGui.Enabled = true

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

	if currentHeadGui and currentHeadSpawnPoint then
		setHeadGuiVisible(true)
	else
		setHeadGuiVisible(false)
	end

end)



-- =======================================================
-- [修改内容] 增加：被守护者追逐时的屏幕抖动 (Camera Shake)
-- =======================================================
local currentCamera = workspace.CurrentCamera
local shakeIntensity = 0
local chaseCameraHeightOffset = 0
local activeChaseGlowGuardians: {[Instance]: Highlight} = {}

local CHASE_CAMERA_HEIGHT = 1
local CHASE_CAMERA_LERP_SPEED = 5
local CHASE_GLOW_FLASH_SPEED = 7

local hookedGuardians: {[Instance]: boolean} = {}

local function getGuardianZoneKey(guardian: Instance): string
	local zoneKey = guardian:GetAttribute("ZoneKey")
	return type(zoneKey) == "string" and zoneKey or ""
end

local function collectLocalPersonalGuardianZones(guardiansFolder: Instance): ({[string]: boolean}, boolean)
	local zones: {[string]: boolean} = {}
	local hasLocalPersonalGuardian = false
	for _, guardian in ipairs(guardiansFolder:GetChildren()) do
		if guardian:GetAttribute("IsPersonalGuardian") == true
			and guardian:GetAttribute("OwnerUserId") == player.UserId then
			hasLocalPersonalGuardian = true
			local zoneKey = getGuardianZoneKey(guardian)
			if zoneKey ~= "" then
				zones[zoneKey] = true
			end
		end
	end
	return zones, hasLocalPersonalGuardian
end

local function setGuardianLocalVisible(guardian: Instance, isVisible: boolean)
	for _, descendant in ipairs(guardian:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = isVisible and 0 or 1
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = isVisible and 0 or 1
		elseif descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			descendant.Enabled = isVisible
		elseif descendant:IsA("BillboardGui") or descendant:IsA("SurfaceGui") then
			descendant.Enabled = isVisible
		end
	end
end

local function getOrCreateGuardianGlowOutline(guardian: Instance): Highlight?
	local glowOutline = guardian:FindFirstChild("GlowOutline")
	if glowOutline and not glowOutline:IsA("Highlight") then
		glowOutline:Destroy()
		glowOutline = nil
	end

	if not glowOutline then
		local highlight = Instance.new("Highlight")
		highlight.Name = "GlowOutline"
		highlight.Adornee = guardian
		highlight.FillColor = Color3.fromRGB(255, 0, 0)
		highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Enabled = false
		highlight.Parent = guardian
		return highlight
	end

	local highlight = glowOutline :: Highlight
	highlight.Adornee = guardian
	highlight.FillColor = Color3.fromRGB(255, 0, 0)
	highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	return highlight
end

local function setGuardianChaseGlow(guardian: Instance, enabled: boolean, now: number?)
	if enabled then
		local highlight = activeChaseGlowGuardians[guardian] or getOrCreateGuardianGlowOutline(guardian)
		if not highlight then
			return
		end

		activeChaseGlowGuardians[guardian] = highlight
		highlight.Enabled = true

		-- “内部一直闪红色”：FillTransparency 在半透明与高亮之间循环，Outline 保持红色可见。
		local pulse = (math.sin((now or os.clock()) * CHASE_GLOW_FLASH_SPEED) + 1) * 0.5
		highlight.FillTransparency = 0.15 + (pulse * 0.45)
		highlight.OutlineTransparency = 0
		return
	end

	local highlight = activeChaseGlowGuardians[guardian]
	if not highlight then
		local existing = guardian:FindFirstChild("GlowOutline")
		if existing and existing:IsA("Highlight") then
			highlight = existing
		end
	end

	if highlight then
		highlight.Enabled = false
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1
	end
	activeChaseGlowGuardians[guardian] = nil
end

local function clearStaleGuardianChaseGlows(chasingGuardians: {[Instance]: boolean})
	for guardian in pairs(activeChaseGlowGuardians) do
		if guardian.Parent == nil or not chasingGuardians[guardian] then
			setGuardianChaseGlow(guardian, false)
		end
	end
end

local function shouldGuardianBeVisibleToLocalPlayer(guardian: Instance, localPersonalZones: {[string]: boolean}, hasLocalPersonalGuardian: boolean): boolean
	local isPersonal = guardian:GetAttribute("IsPersonalGuardian") == true
	local ownerUserId = guardian:GetAttribute("OwnerUserId")

	-- 其他玩家的专属追踪守护者永远不在本客户端显示。
	if isPersonal then
		return ownerUserId == player.UserId
	end

	-- 本玩家只要已有一个本地专属守护者，就隐藏所有公共守护者，
	-- 确保当前客户端任意时刻最多只看到一个守护者模型。
	if hasLocalPersonalGuardian then
		return false
	end

	-- 如果本玩家在同一个区域已经有专属追踪守护者，则隐藏原地公共守护者，
	-- 避免“追踪守护者 + 原地待机守护者”同时可见。
	local zoneKey = getGuardianZoneKey(guardian)
	if zoneKey ~= "" and localPersonalZones[zoneKey] == true then
		return false
	end

	return true
end

local function refreshAllGuardianVisibility()
	local guardiansFolder = workspace:FindFirstChild("Guardians")
	if not guardiansFolder then
		return
	end

	local localPersonalZones, hasLocalPersonalGuardian = collectLocalPersonalGuardianZones(guardiansFolder)
	for _, guardian in ipairs(guardiansFolder:GetChildren()) do
		setGuardianLocalVisible(guardian, shouldGuardianBeVisibleToLocalPlayer(guardian, localPersonalZones, hasLocalPersonalGuardian))
	end
end

local function hookGuardianVisibility(guardian: Instance)
	if hookedGuardians[guardian] then
		refreshAllGuardianVisibility()
		return
	end
	hookedGuardians[guardian] = true

	refreshAllGuardianVisibility()
	guardian:GetAttributeChangedSignal("IsPersonalGuardian"):Connect(function()
		refreshAllGuardianVisibility()
	end)
	guardian:GetAttributeChangedSignal("OwnerUserId"):Connect(function()
		refreshAllGuardianVisibility()
	end)
	guardian:GetAttributeChangedSignal("ZoneKey"):Connect(function()
		refreshAllGuardianVisibility()
	end)
	guardian.DescendantAdded:Connect(function()
		refreshAllGuardianVisibility()
	end)
	guardian.Destroying:Connect(function()
		hookedGuardians[guardian] = nil
		setGuardianChaseGlow(guardian, false)
		task.defer(refreshAllGuardianVisibility)
	end)
end

local function initPersonalGuardianVisibility()
	local function hookFolder(folder: Instance)
		for _, guardian in ipairs(folder:GetChildren()) do
			hookGuardianVisibility(guardian)
		end
		folder.ChildAdded:Connect(hookGuardianVisibility)
		folder.ChildRemoved:Connect(function()
			refreshAllGuardianVisibility()
		end)
		refreshAllGuardianVisibility()
	end

	local guardiansFolder = workspace:FindFirstChild("Guardians")
	if guardiansFolder then
		hookFolder(guardiansFolder)
	else
		workspace.ChildAdded:Connect(function(child)
			if child.Name == "Guardians" then
				hookFolder(child)
			end
		end)
	end
end

initPersonalGuardianVisibility()

-- 使用 BindToRenderStep 保证在默认相机脚本更新后，再叠加我们的抖动偏移
RunService:BindToRenderStep("GuardianCameraShake", Enum.RenderPriority.Camera.Value + 1, function(dt)
	currentCamera = workspace.CurrentCamera
	if not currentCamera then
		return
	end

	local isChased = false
	local minDistance = 100
	local chasingGuardians: {[Instance]: boolean} = {}
	local nowClock = os.clock()
	
	local guardiansFolder = workspace:FindFirstChild("Guardians")
	if guardiansFolder then
		for _, guardian in ipairs(guardiansFolder:GetChildren()) do
			if guardian:GetAttribute("IsPersonalGuardian") == true and guardian:GetAttribute("OwnerUserId") ~= player.UserId then
				continue
			end

			-- 检测是否有守护者的追击目标是 LocalPlayer
			if guardian:GetAttribute("TargetPlayerName") == player.Name then
				isChased = true
				chasingGuardians[guardian] = true
				setGuardianChaseGlow(guardian, true, nowClock)
				local hrp = getHRP()
				if hrp and guardian.PrimaryPart then
					local dist = (hrp.Position - guardian.PrimaryPart.Position).Magnitude
					if dist < minDistance then
						minDistance = dist
					end
				end
			end
		end
	end
	clearStaleGuardianChaseGlows(chasingGuardians)

	-- 计算目标抖动强度（距离越近抖动越强烈，距离 60 开始有感）
	local targetIntensity = 0
	if isChased and minDistance < 60 then
		-- 当距离为 60 时强度为 0.1，完全贴脸时强度可达 1.5
		targetIntensity = math.clamp(1 - (minDistance / 60), 0.1, 1) * 1
	end
	
	-- 平滑过渡抖动强度，防止开始和停止时画面突兀
	shakeIntensity = shakeIntensity + (targetIntensity - shakeIntensity) * 8 * dt

	-- 被追逐时把视角整体拉高；脱离追逐后平滑恢复。
	local targetCameraHeightOffset = isChased and CHASE_CAMERA_HEIGHT or 0
	chaseCameraHeightOffset = chaseCameraHeightOffset + (targetCameraHeightOffset - chaseCameraHeightOffset) * math.clamp(CHASE_CAMERA_LERP_SPEED * dt, 0, 1)
	if math.abs(chaseCameraHeightOffset) > 0.02 then
		currentCamera.CFrame = currentCamera.CFrame * CFrame.new(0, chaseCameraHeightOffset, 0)
	end

	-- 如果强度足够大，则计算相机抖动
	if shakeIntensity > 0.02 then
		local now = nowClock * 25 -- 控制抖动频率(速度)
		
		-- 使用柏林噪声(math.noise)生成平缓随机的 XYZ 偏移
		local xOffset = math.noise(now, 100, 0) * shakeIntensity
		local yOffset = math.noise(now, 200, 0) * shakeIntensity
		local rollOffset = math.noise(now, 300, 0) * (shakeIntensity * 0.25) -- 倾斜抖动减弱一点以防晕3D

		-- 将抖动叠加到当前相机的 CFrame 上
		currentCamera.CFrame = currentCamera.CFrame 
			* CFrame.new(xOffset, yOffset, 0) 
			* CFrame.Angles(0, 0, math.rad(rollOffset))
	end
end)