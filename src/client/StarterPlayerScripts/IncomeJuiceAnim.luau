local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local requestUpgradePlacedMonster = remotes:WaitForChild("RequestUpgradePlacedMonster") :: RemoteEvent

-- 动画参数
local shrinkInfo = TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local bounceInfo = TweenInfo.new(0.3, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)

-- 1. 负责 UI 点击缩放动画
local boundButtons: {[Instance]: boolean} = {}

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

	button.Activated:Connect(function()
		local slotIndex = getSlotIndexFrom(button)
		if not slotIndex then
			warn(string.format("[UpgradeButtonDebug][Client] missing SlotIndex button=%s", button:GetFullName()))
			return
		end

		TweenService:Create(bg, shrinkInfo, {Size = targetSize}):Play()
		task.wait(0.1)
		TweenService:Create(bg, bounceInfo, {Size = originalSize}):Play()

		warn(string.format("[UpgradeButtonDebug][Client] fire slot=%d button=%s", math.floor(slotIndex), button:GetFullName()))
		requestUpgradePlacedMonster:FireServer(slotIndex)
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
for _, part in ipairs(CollectionService:GetTagged("Anim_UpgradeClicker")) do bindClicker(part) end
CollectionService:GetInstanceAddedSignal("Anim_UpgradeClicker"):Connect(bindClicker)

for _, descendant in ipairs(workspace:GetDescendants()) do
	if descendant.Name == "ImageButton_升级按钮" and descendant:IsA("GuiButton") then
		bindUpgradeButton(descendant :: GuiButton)
	end
end

workspace.DescendantAdded:Connect(function(descendant)
	if descendant.Name == "ImageButton_升级按钮" and descendant:IsA("GuiButton") then
		bindUpgradeButton(descendant :: GuiButton)
	end
end)

for _, model in ipairs(CollectionService:GetTagged("Anim_IncomeDisplay")) do bindDisplay(model) end
CollectionService:GetInstanceAddedSignal("Anim_IncomeDisplay"):Connect(bindDisplay)