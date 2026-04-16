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
	-- 假设你的视觉底层 Part 叫 "Base" 或者直接用 PrimaryPart
	local visualPart = model.PrimaryPart 
	
	if hitbox and visualPart then
		local debounce = false
		hitbox.Touched:Connect(function(hit)
			if debounce then return end
			local char = hit.Parent
			if char and char:FindFirstChild("Humanoid") then
				debounce = true
				
				-- 视觉部分下沉 0.5 Studs，然后弹回 (使用 PivotTo 保证整体模型移动)
				local originalCFrame = visualPart.CFrame
				local downCFrame = originalCFrame * CFrame.new(0, -0.5, 0)
				
				model:PivotTo(downCFrame)
				task.wait(0.1)
				
				-- 这里用一个简单的循环模拟弹性回弹
				for i = 1, 10 do
					model:PivotTo(downCFrame:Lerp(originalCFrame, i/10))
					task.wait(0.02)
				end
				model:PivotTo(originalCFrame)
				
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