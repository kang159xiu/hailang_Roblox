--!strict
-- StarterPlayerScripts.Client
-- 客户端：
-- 1) HUD：左上角金币 + Toast
-- 2) 怪头顶信息：距离显示（远处仅倒计时，近处显示详细），并显示存在时间倒计时
-- 3) 商店 UI：武器商店（滚动列表）/升级商店（攻击/血量/速度）


--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local ContextActionService = game:GetService("ContextActionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

-- [修改内容] 引入新创建的 UI 控制器模块
local UIController = require(script.Parent:WaitForChild("UIController"))

-- 启动 UI 逻辑
task.spawn(function()
    UIController.Init()
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
local requestPromptInteraction = remotes:WaitForChild("RequestPromptInteraction") :: RemoteEvent


-- =====================
-- 怪头顶信息：距离显示 + 倒计时
-- =====================

type TrackedMonster = {
	Part: BasePart,
}

local tracked: {TrackedMonster} = {}
local trackedSet: {[BasePart]: true} = {}


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
	close.Text = "关闭"
	close.Parent = frame
	close.Activated:Connect(function() frame.Visible = false end)

	return frame
end

-- [修改内容] 引入必要的数值格式化工具
local function formatNumberShort(n: number): string
	local abs = math.abs(n)
	local units = {
		{ 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" },
		{ 1e9, "B" }, { 1e6, "M" }, { 1e4, "w" },
	}
	for _, u in ipairs(units) do
		local base = u[1] :: number
		local suffix = u[2] :: string
		if abs >= base then
			local v = n / base
			local s: string = string.format("%.1f", v)
			s = s:gsub("%.?0+$", "")
			return s .. suffix
		end
	end
	return tostring(math.floor(n))
end





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



-- =======================================================
-- [修改内容] 增加：被守护者追逐时的屏幕抖动 (Camera Shake)
-- =======================================================
local currentCamera = workspace.CurrentCamera
local shakeIntensity = 0

-- 使用 BindToRenderStep 保证在默认相机脚本更新后，再叠加我们的抖动偏移
RunService:BindToRenderStep("GuardianCameraShake", Enum.RenderPriority.Camera.Value + 1, function(dt)
	local isChased = false
	local minDistance = 100
	
	local guardiansFolder = workspace:FindFirstChild("Guardians")
	if guardiansFolder then
		for _, guardian in ipairs(guardiansFolder:GetChildren()) do
			-- 检测是否有守护者的追击目标是 LocalPlayer
			if guardian:GetAttribute("TargetPlayerName") == player.Name then
				isChased = true
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

	-- 计算目标抖动强度（距离越近抖动越强烈，距离 60 开始有感）
	local targetIntensity = 0
	if isChased and minDistance < 60 then
		-- 当距离为 60 时强度为 0.1，完全贴脸时强度可达 1.5
		targetIntensity = math.clamp(1 - (minDistance / 60), 0.1, 1) * 1.5 
	end
	
	-- 平滑过渡抖动强度，防止开始和停止时画面突兀
	shakeIntensity = shakeIntensity + (targetIntensity - shakeIntensity) * 8 * dt

	-- 如果强度足够大，则计算相机抖动
	if shakeIntensity > 0.02 then
		local now = os.clock() * 25 -- 控制抖动频率(速度)
		
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