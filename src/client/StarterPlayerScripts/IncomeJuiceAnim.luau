local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

-- 动画参数
local shrinkInfo = TweenInfo.new(0.1, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local bounceInfo = TweenInfo.new(0.3, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)

-- 1. 负责 UI 点击缩放动画
local function bindClicker(part: BasePart)
	local clickDetector = part:WaitForChild("ClickDetector", 5) :: ClickDetector
	local surfaceGui = part:WaitForChild("SurfaceGui", 5) :: SurfaceGui
	local bg = surfaceGui and surfaceGui:WaitForChild("升级背景", 5) :: GuiObject

	if clickDetector and bg then
		local originalSize = bg.Size
		local targetSize = UDim2.new(originalSize.X.Scale * 0.8, 0, originalSize.Y.Scale * 0.8, 0)

		clickDetector.MouseClick:Connect(function()
			-- 缩小
			TweenService:Create(bg, shrinkInfo, {Size = targetSize}):Play()
			task.wait(0.1)
			-- 弹回原大小
			TweenService:Create(bg, bounceInfo, {Size = originalSize}):Play()
		end)
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

for _, model in ipairs(CollectionService:GetTagged("Anim_IncomeDisplay")) do bindDisplay(model) end
CollectionService:GetInstanceAddedSignal("Anim_IncomeDisplay"):Connect(bindDisplay)