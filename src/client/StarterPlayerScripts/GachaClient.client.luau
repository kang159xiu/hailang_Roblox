-- 客户端路径: StarterPlayerScripts.GachaClient
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")
local mainUI = PlayerGui:WaitForChild("MainUI")

-- 绑定 UI 节点
local btnEntry = mainUI:WaitForChild("抽奖入口")
local frameGacha = mainUI:WaitForChild("抽奖界面")

local btnGold = frameGacha:WaitForChild("钱抽奖")
local btnRbx = frameGacha:WaitForChild("R币抽奖")
local btnRbx5 = frameGacha:WaitForChild("r币5次")
local btnFast = frameGacha:WaitForChild("快速转")
local btnClose = frameGacha:WaitForChild("关闭")
local frameDisplay = frameGacha:WaitForChild("显示抽奖内容_Fram")

-- 获取 5 个展示框
local vpfList = {
	frameDisplay:WaitForChild("ViewportFrame01"),
	frameDisplay:WaitForChild("ViewportFrame02"),
	frameDisplay:WaitForChild("ViewportFrame03"),
	frameDisplay:WaitForChild("ViewportFrame04"),
	frameDisplay:WaitForChild("ViewportFrame05"),
}

local findMonsterTemplate
local setupViewport

local function hasGachaPreview()
	for _, vpf in ipairs(vpfList) do
		if #vpf:GetChildren() > 0 then
			return true
		end
	end
	return false
end

local function refreshGachaPreview(isDebug: boolean)
	local monsterFolder = workspace:FindFirstChild("Monster image") or ReplicatedStorage:FindFirstChild("MonsterAppearances")
	if not monsterFolder then
		warn("❌ [致命错误] 在 workspace 和 ReplicatedStorage 中都没找到装怪物的文件夹！请检查名字。")
		return false
	end

	print("📁 成功找到装怪物的文件夹:", monsterFolder:GetFullName())

	for _, vpf in ipairs(vpfList) do
		local randomLevel = math.random(1, 5)
		local template = findMonsterTemplate(monsterFolder, randomLevel)
		if template then
			setupViewport(vpf, template, isDebug)
		end
	end

	return true
end

-- [修改原因] 打开抽奖界面时，如果预览还是空的，就立即补刷 5 个怪物形象
btnEntry.MouseButton1Click:Connect(function()
	frameGacha.Visible = not frameGacha.Visible
	if frameGacha.Visible then
		-- [修改原因] 漏斗埋点：记录玩家打开了抽奖界面
		local analyticsRemote = game.ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild("Analytics_Remote")
		if analyticsRemote then
			analyticsRemote:FireServer("Funnel", "Gacha_UI_Opened")
		end
	end
	if frameGacha.Visible and not hasGachaPreview() then
		refreshGachaPreview(false)
	end
end)

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local requestEvent = remotes:WaitForChild("GachaRequest")
local resultEvent = remotes:WaitForChild("GachaResult")

-- =====================================================================
-- 🩺 [诊断点 1] 智能模糊查找辅助函数 (带日志)
-- =====================================================================
findMonsterTemplate = function(folder, level)
	if not folder then 
		warn("❌ 查找失败：传入的文件夹是空的！")
		return nil 
	end
	
	local strNormal = tostring(level)
	local strZero = string.format("%02d", level)

	local names = {
		"怪物形象"..strNormal, "怪物形象"..strZero,
		"怪物形象 "..strNormal, "怪物形象 "..strZero,
		"Lv"..strNormal, "Lv"..strZero,
		"Lv "..strNormal, "Lv "..strZero,
		strNormal, strZero
	}

	for _, name in ipairs(names) do
		local found = folder:FindFirstChild(name)
		if found then 
			print("🔍 [查找成功] 目标等级:", level, " 找到了名字匹配的模型:", found.Name)
			return found 
		end
	end
	
	warn("⚠️ [查找失败] 目标等级:", level, " 在文件夹里穷举了所有可能的名字，都没有找到！")
	return nil
end

-- =====================================================================
-- 3D 渲染核心函数 (精准定位 Part 版)
-- =====================================================================
setupViewport = function(vpf: Instance, modelTemplate: Instance?, isDebug: boolean)
	if not vpf:IsA("ViewportFrame") then return end
	vpf:ClearAllChildren()
	if not modelTemplate then return end


	-- 1. 直接克隆整个外层 Model，不做任何多余的拆解
	local clone = modelTemplate:Clone()
	clone.Parent = vpf

	local camera = Instance.new("Camera")
	vpf.CurrentCamera = camera
	camera.Parent = vpf

	-- 2. 优先寻找模板里专门的定位 Part；找不到再多层兜底
	local anchorPart = nil

	local preferredNames = {
		clone.Name,
		"RootPart",
		"HumanoidRootPart",
		"Handle",
		"PrimaryPart",
		"Root",
	}

	for _, partName in ipairs(preferredNames) do
		local found = clone:FindFirstChild(partName, true)
		if found and found:IsA("BasePart") then
			anchorPart = found
			break
		end
	end

	if not anchorPart and clone:IsA("Model") and clone.PrimaryPart then
		anchorPart = clone.PrimaryPart
	end

	if not anchorPart then
		anchorPart = clone:FindFirstChildWhichIsA("BasePart", true)
	end


	-- 3. 精准架设摄像机
	if anchorPart then
		if isDebug then print("✅ 成功锁定定位 Part:", anchorPart.Name, "坐标:", anchorPart.Position) end
		
		-- 直接拿你的定位 Part 的大小和位置来对焦
		local cf = anchorPart.CFrame
		local size = anchorPart.Size
		local maxDim = math.max(size.X, size.Y, size.Z)
		if maxDim < 0.1 then maxDim = 5 end

		-- ==========================================
		-- 🛠️ 调整大小的开关在这里 🛠️
		local ZOOM_MULTIPLIER = 1.8  -- 数值越大，相机离定位块越远（怪物显得越小）
		local HEIGHT_OFFSET = 0.5    -- 数值越大，相机抬得越高
		-- ==========================================

		-- 使用斜角上帝视角看着你的定位 Part
		local offset = Vector3.new(maxDim * ZOOM_MULTIPLIER, maxDim * HEIGHT_OFFSET, maxDim * ZOOM_MULTIPLIER)
		camera.CFrame = CFrame.new(cf.Position + offset, cf.Position)
	else
		warn("⚠️ [渲染失败] 在", clone.Name, "里面完全找不到定位 Part，请检查！")
	end
end

-- =====================================================================
-- 业务逻辑绑定
-- =====================================================================

task.spawn(function()
	print("🚀 --- 游戏开局初始化开始，2秒后加载初始怪物展示 ---")
	task.wait(3)
	refreshGachaPreview(true)
end)


btnClose.MouseButton1Click:Connect(function()
    frameGacha.Visible = false
end)

local PRODUCT_ID_10_PULL = 3580035858
local PRODUCT_ID_5_PULL = 3580661228
local isFastMode = false
local isAnimating = false
local fastOpenIndicator = btnFast:WaitForChild("快速开")
fastOpenIndicator.Visible = false

btnFast.MouseButton1Click:Connect(function()
	isFastMode = not isFastMode
	fastOpenIndicator.Visible = isFastMode
	requestEvent:FireServer("ToggleFastMode", isFastMode)
end)

btnGold.MouseButton1Click:Connect(function()
	if isAnimating then return end
	print("🔘 点击单抽按钮，发送请求给服务端...")
	requestEvent:FireServer("Gold1")
end)


btnRbx.MouseButton1Click:Connect(function()
	if isAnimating then return end
	MarketplaceService:PromptProductPurchase(player, PRODUCT_ID_10_PULL)
end)

btnRbx5.MouseButton1Click:Connect(function()
	if isAnimating then return end
	MarketplaceService:PromptProductPurchase(player, PRODUCT_ID_5_PULL)
end)



-- 抽奖结果监听
resultEvent.OnClientEvent:Connect(function(results, serverDuration)
	if isAnimating then return end
	isAnimating = true
	print("🎯 收到服务端发来的抽奖结果！结果数量:", #results, " 动画延迟时长:", serverDuration)

	local monsterFolder = workspace:FindFirstChild("Monster image") or ReplicatedStorage:FindFirstChild("MonsterAppearances")
	if not monsterFolder then
		warn("❌ 找不到怪物展示文件夹")
		isAnimating = false
		return
	end

	local perDrawDuration = 0.3

	for drawIndex, resLevel in ipairs(results) do
		local startTime = os.clock()
		local frameCounter = 0
		local finished = false

		local connection
		connection = RunService.RenderStepped:Connect(function()
			local elapsed = os.clock() - startTime
			frameCounter += 1

			if elapsed >= perDrawDuration then
				connection:Disconnect()
				finished = true

				print("🛑 第", drawIndex, "次抽奖动画结束，显示最终结果:", resLevel)

				for _, vpf in ipairs(vpfList) do
					local template = findMonsterTemplate(monsterFolder, resLevel)
					if template then
						setupViewport(vpf, template, true)
					end
				end
				return
			end

			if frameCounter % 4 == 0 then
				for _, vpf in ipairs(vpfList) do
					local randomLevel = math.random(1, 30)
					local template = findMonsterTemplate(monsterFolder, randomLevel)
					if template then
						setupViewport(vpf, template, false)
					end
				end
			end
		end)

		repeat task.wait() until finished
		task.wait(0.05)
	end

	isAnimating = false
end)
