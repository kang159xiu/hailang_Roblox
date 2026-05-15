local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local requestUpgradePlacedMonster = remotes:WaitForChild("RequestUpgradePlacedMonster") :: RemoteEvent
local localPlayer = Players.LocalPlayer

warn(string.format("[UpgradeButtonDebug][Client] IncomeJuiceAnim loaded player=%s script=%s", localPlayer.Name, script:GetFullName()))

-- 动画参数
local shrinkInfo = TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local bounceInfo = TweenInfo.new(0.3, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)

-- 1. 负责 UI 点击缩放动画
local boundButtons: {[Instance]: boolean} = {}
local lastFireAtByButton: {[Instance]: number} = {}

local function getSlotIndexOnAncestry(instance: Instance?): number?
	local current: Instance? = instance
	while current do
		local slotIndex = current:GetAttribute("SlotIndex")
		if type(slotIndex) == "number" then
			return slotIndex :: number
		end
		current = current.Parent
	end
	return nil
end

local function getSlotIndexFrom(instance: Instance): number?
	local slotIndex = getSlotIndexOnAncestry(instance)
	if slotIndex then
		return slotIndex
	end

	-- SurfaceGui 可能挂在点击升级 Part 下，也可能通过 Adornee 指向 Part。
	-- 如果按钮祖先链没有 SlotIndex，就继续从 SurfaceGui.Adornee 及其祖先兜底查找。
	local ancestorGui = instance:FindFirstAncestorWhichIsA("SurfaceGui")
	if ancestorGui and ancestorGui:IsA("SurfaceGui") then
		local surfaceGui = ancestorGui :: SurfaceGui
		local adorneeSlotIndex = getSlotIndexOnAncestry(surfaceGui.Adornee)
		if adorneeSlotIndex then
			return adorneeSlotIndex
		end
	end

	return nil
end

local function getOwnerUserIdOnAncestry(instance: Instance?): number?
	local current: Instance? = instance
	while current do
		local ownerUserId = current:GetAttribute("OwnerUserId")
		if type(ownerUserId) == "number" then
			return ownerUserId :: number
		end
		current = current.Parent
	end
	return nil
end

local function getOwnerUserIdFrom(instance: Instance): number?
	local ownerUserId = getOwnerUserIdOnAncestry(instance)
	if ownerUserId then
		return ownerUserId
	end

	local ancestorGui = instance:FindFirstAncestorWhichIsA("SurfaceGui")
	if ancestorGui and ancestorGui:IsA("SurfaceGui") then
		local surfaceGui = ancestorGui :: SurfaceGui
		local adorneeOwnerUserId = getOwnerUserIdOnAncestry(surfaceGui.Adornee)
		if adorneeOwnerUserId then
			return adorneeOwnerUserId
		end
	end

	return nil
end

local function playUpgradeButtonAnim(bg: GuiObject, originalSize: UDim2, targetSize: UDim2)
	TweenService:Create(bg, shrinkInfo, {Size = targetSize}):Play()
	task.wait(0.1)
	TweenService:Create(bg, bounceInfo, {Size = originalSize}):Play()
end

local function fireUpgradeRequest(button: GuiButton, bg: GuiObject, originalSize: UDim2, targetSize: UDim2, source: string)
	local now = os.clock()
	if (lastFireAtByButton[button] or 0) + 0.2 > now then
		return
	end
	lastFireAtByButton[button] = now

	local slotIndex = getSlotIndexFrom(button)
	if not slotIndex then
		warn(string.format("[UpgradeButtonDebug][Client] missing SlotIndex source=%s button=%s", source, button:GetFullName()))
		return
	end

	local ownerUserId = getOwnerUserIdFrom(button)
	if type(ownerUserId) ~= "number" or math.floor(ownerUserId) ~= localPlayer.UserId then
		return
	end

	task.spawn(function()
		playUpgradeButtonAnim(bg, originalSize, targetSize)
	end)

	warn(string.format("[UpgradeButtonDebug][Client] fire source=%s slot=%d owner=%d button=%s", source, math.floor(slotIndex), math.floor(ownerUserId), button:GetFullName()))
	requestUpgradePlacedMonster:FireServer(slotIndex, ownerUserId)
end

local function bindUpgradeButton(button: GuiButton)
	if boundButtons[button] then
		return
	end
	boundButtons[button] = true
	button.Active = true
	button.Visible = true
	button.Selectable = true

	local ancestorGui = button:FindFirstAncestorWhichIsA("SurfaceGui")
	local surfaceGui = if ancestorGui and ancestorGui:IsA("SurfaceGui") then ancestorGui :: SurfaceGui else nil
	if surfaceGui then
		surfaceGui.Active = true
	end
	local bg: GuiObject = button
	if surfaceGui then
		local bgCandidate = surfaceGui:FindFirstChild("升级背景", true)
		if bgCandidate and bgCandidate:IsA("GuiObject") then
			bg = bgCandidate :: GuiObject
		end
	end
	local originalSize = bg.Size
	local targetSize = UDim2.new(originalSize.X.Scale * 0.8, originalSize.X.Offset * 0.8, originalSize.Y.Scale * 0.8, originalSize.Y.Offset * 0.8)

	warn(string.format(
		"[UpgradeButtonDebug][Client] bound button=%s slot=%s surface=%s",
		button:GetFullName(),
		tostring(getSlotIndexFrom(button)),
		if surfaceGui then surfaceGui:GetFullName() else "nil"
	))

	button.Activated:Connect(function()
		fireUpgradeRequest(button, bg, originalSize, targetSize, "Activated")
	end)
end

local function isUpgradeSearchBoundary(instance: Instance): boolean
	-- 不能爬到 Workspace 后全局递归 FindFirstChild，否则点到“安全区/地面”时也会拿到第一个升级按钮，导致槽位错乱。
	return instance == workspace
		or instance:IsA("WorldRoot")
		or instance.Name == "HOME"
		or instance.Name:match("^HOME%d+") ~= nil
end

local function isValidUpgradeButtonForHit(button: GuiButton, hitInstance: Instance?): boolean
	if not (button.Visible and button.Active) then
		return false
	end

	local buttonSlotIndex = getSlotIndexFrom(button)
	if not buttonSlotIndex then
		return false
	end

	local hitSlotIndex = getSlotIndexOnAncestry(hitInstance)
	if hitSlotIndex and math.floor(hitSlotIndex) ~= math.floor(buttonSlotIndex) then
		return false
	end

	return true
end

local function findUpgradeButtonNearHit(hitInstance: Instance?): GuiButton?
	local current: Instance? = hitInstance
	while current do
		if isUpgradeSearchBoundary(current) then
			break
		end

		local directButton = current:FindFirstChild("ImageButton_升级按钮")
		if directButton and directButton:IsA("GuiButton") and isValidUpgradeButtonForHit(directButton :: GuiButton, hitInstance) then
			return directButton :: GuiButton
		end

		-- 只在带 SlotIndex 的局部槽位/收益显示节点里递归查找，避免跨槽或跨 Home 全局误匹配。
		if current:GetAttribute("SlotIndex") ~= nil or current.Name == "收益显示" or current.Name == "点击升级" then
			local nestedButton = current:FindFirstChild("ImageButton_升级按钮", true)
			if nestedButton and nestedButton:IsA("GuiButton") and isValidUpgradeButtonForHit(nestedButton :: GuiButton, hitInstance) then
				return nestedButton :: GuiButton
			end
		end

		current = current.Parent
	end
	return nil
end

local function bindFallbackWorldClick()
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		warn(string.format(
			"[UpgradeButtonDebug][Client] input source=%s gameProcessed=%s pos=(%.0f,%.0f)",
			tostring(input.UserInputType),
			tostring(gameProcessed),
			input.Position.X,
			input.Position.Y
		))

		if gameProcessed then
			return
		end

		local camera = workspace.CurrentCamera
		if not camera then
			warn("[UpgradeButtonDebug][Client] no CurrentCamera for fallback raycast")
			return
		end

		local position = input.Position
		local ray = camera:ViewportPointToRay(position.X, position.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local character = localPlayer.Character
		params.FilterDescendantsInstances = if character then {character} else {}

		local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
		if not result then
			warn("[UpgradeButtonDebug][Client] world raycast hit=nil")
			return
		end

		warn(string.format("[UpgradeButtonDebug][Client] world raycast hit=%s", result.Instance:GetFullName()))

		local button = findUpgradeButtonNearHit(result.Instance)
		if not button then
			warn(string.format("[UpgradeButtonDebug][Client] no ImageButton_升级按钮 near hit=%s", result.Instance:GetFullName()))
			return
		end

		bindUpgradeButton(button)
		local ancestorGui = button:FindFirstAncestorWhichIsA("SurfaceGui")
		local surfaceGui = if ancestorGui and ancestorGui:IsA("SurfaceGui") then ancestorGui :: SurfaceGui else nil
		local bg: GuiObject = button
		if surfaceGui then
			local bgCandidate = surfaceGui:FindFirstChild("升级背景", true)
			if bgCandidate and bgCandidate:IsA("GuiObject") then
				bg = bgCandidate :: GuiObject
			end
		end
		local originalSize = bg.Size
		local targetSize = UDim2.new(originalSize.X.Scale * 0.8, originalSize.X.Offset * 0.8, originalSize.Y.Scale * 0.8, originalSize.Y.Offset * 0.8)
		fireUpgradeRequest(button, bg, originalSize, targetSize, "WorldRaycast")
	end)
end

local function bindClicker(part: BasePart)
	local button = part:FindFirstChild("ImageButton_升级按钮", true)
	if not button then
		local surfaceGui = part:WaitForChild("SurfaceGui", 5)
		button = surfaceGui and surfaceGui:FindFirstChild("ImageButton_升级按钮", true)
	end
	if not button then
		task.wait(0.5)
		button = part:FindFirstChild("ImageButton_升级按钮", true)
	end
	if button and button:IsA("GuiButton") then
		bindUpgradeButton(button :: GuiButton)
	else
		warn(string.format("[UpgradeButtonDebug][Client] ImageButton_升级按钮 not found under clicker=%s", part:GetFullName()))
	end
end

-- 2. 负责踩踏回弹动画 (物理视觉分离)
local function bindDisplay(model: Model)
	local hitbox = model:WaitForChild("Hitbox", 5) :: BasePart
	
	if hitbox then
		local debounce = false
		hitbox.Touched:Connect(function(hit)
			if debounce then return end
			local char = hit.Parent
			if char and char:FindFirstChild("Humanoid") then
				debounce = true
				
				-- 【修复】找到名为 Visuals 的子容器，只对它做下沉动画
				-- 如果没找到 Visuals，兜底移动整个 model (会导致发抖)
				local targetModel = model:FindFirstChild("Visuals") or model
				local originalCFrame = targetModel:GetPivot()
				local downCFrame = originalCFrame * CFrame.new(0, -0.5, 0)
				
				targetModel:PivotTo(downCFrame)
				task.wait(0.1)
				
				-- 简单的循环模拟弹性回弹
				for i = 1, 10 do
					targetModel:PivotTo(downCFrame:Lerp(originalCFrame, i/10))
					task.wait(0.02)
				end
				targetModel:PivotTo(originalCFrame)
				
				task.wait(0.5) -- 冷却
				debounce = false
			end
		end)
	end
end

-- 绑定现有的和未来动态生成的组件
local initialClickerCount = 0
for _, part in ipairs(CollectionService:GetTagged("Anim_UpgradeClicker")) do
	initialClickerCount += 1
	bindClicker(part)
end
CollectionService:GetInstanceAddedSignal("Anim_UpgradeClicker"):Connect(bindClicker)

local initialUpgradeButtonCount = 0
for _, descendant in ipairs(workspace:GetDescendants()) do
	if descendant.Name == "ImageButton_升级按钮" and descendant:IsA("GuiButton") then
		initialUpgradeButtonCount += 1
		bindUpgradeButton(descendant :: GuiButton)
	end
end

local boundButtonCount = 0
for _ in pairs(boundButtons) do
	boundButtonCount += 1
end

warn(string.format(
	"[UpgradeButtonDebug][Client] initial scan clickers=%d upgradeButtons=%d boundButtons=%d",
	initialClickerCount,
	initialUpgradeButtonCount,
	boundButtonCount
))

workspace.DescendantAdded:Connect(function(descendant)
	if descendant.Name == "ImageButton_升级按钮" and descendant:IsA("GuiButton") then
		warn(string.format("[UpgradeButtonDebug][Client] dynamic button added=%s", descendant:GetFullName()))
		bindUpgradeButton(descendant :: GuiButton)
	end
end)

bindFallbackWorldClick()

for _, model in ipairs(CollectionService:GetTagged("Anim_IncomeDisplay")) do bindDisplay(model) end
CollectionService:GetInstanceAddedSignal("Anim_IncomeDisplay"):Connect(bindDisplay)