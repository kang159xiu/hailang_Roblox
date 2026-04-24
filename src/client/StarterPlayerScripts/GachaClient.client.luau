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

-- [修改原因] 移除了代码后半部分重复的绑定，并加入 print 用于控制台调试
btnEntry.MouseButton1Click:Connect(function()
	frameGacha.Visible = not frameGacha.Visible
	print("🎰 抽奖入口被点击，当前界面开启状态：", frameGacha.Visible)
end)

local btnGold = frameGacha:WaitForChild("钱抽奖")
local btnRbx = frameGacha:WaitForChild("R币抽奖")
local btnFast = frameGacha:WaitForChild("快速转")
-- [修改原因] 需求2：新增关闭按钮绑定
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

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local requestEvent = remotes:WaitForChild("GachaRequest")
local resultEvent = remotes:WaitForChild("GachaResult")

-- [修改原因] 需求1：初始化显示。开局时为 5 个槽位随机填充怪兽图像，避免界面空白
task.spawn(function()
    local monsterFolder = workspace:FindFirstChild("Monster image") or ReplicatedStorage:FindFirstChild("MonsterAppearances")
    if monsterFolder then
        for _, vpf in ipairs(vpfList) do
            -- 默认显示 1 级或随机低级怪物
            local randomLevel = math.random(1, 5)
            local template = monsterFolder:FindFirstChild("怪物形象" .. randomLevel) or monsterFolder:FindFirstChild("Lv" .. randomLevel)
            if template then
                setupViewport(vpf, template)
            end
        end
    end
end)

-- [修改原因] 需求2：点击关闭按钮隐藏界面
btnClose.MouseButton1Click:Connect(function()
    frameGacha.Visible = false
    print("❌ 抽奖界面已关闭")
end)

local PRODUCT_ID_10_PULL = 3580035858
local isFastMode = false
local isAnimating = false

-- [修改原因] 获取“快速开”UI节点，并默认隐藏
local fastOpenIndicator = btnFast:WaitForChild("快速开")
fastOpenIndicator.Visible = false

-- 快速抽奖反馈
btnFast.MouseButton1Click:Connect(function()
	isFastMode = not isFastMode
	-- [修改原因] 控制快速开节点的显示与隐藏
	fastOpenIndicator.Visible = isFastMode
	
	-- [修改原因] 将客户端的快速模式状态同步给服务端，以便服务端计算发奖延迟
	requestEvent:FireServer("ToggleFastMode", isFastMode)
end)

-- 发起抽奖
btnGold.MouseButton1Click:Connect(function()
	if isAnimating then return end
	requestEvent:FireServer("Gold1")
end)

btnRbx.MouseButton1Click:Connect(function()
	if isAnimating then return end
	MarketplaceService:PromptProductPurchase(player, PRODUCT_ID_10_PULL)
end)

-- 3D 模型渲染辅助函数
local function setupViewport(vpf: Instance, modelTemplate: Instance?)
	-- [重大修改原因] 安全拦截！ImageLabel 不能显示 3D 模型
	if not vpf:IsA("ViewportFrame") then
		warn("⚠️ 错误：" .. vpf.Name .. " 是一个 " .. vpf.ClassName .. "，无法显示3D怪物！请在 Studio 中右键它 -> 替换为 ViewportFrame。")
		return
	end

	vpf:ClearAllChildren()
	if not modelTemplate then return end

	local clone = modelTemplate:Clone()
	clone.Parent = vpf

	local camera = Instance.new("Camera")
	vpf.CurrentCamera = camera
	camera.Parent = vpf

	local cf, size
	if clone:IsA("Model") then
		cf, size = clone:GetBoundingBox()
	elseif clone:IsA("BasePart") then
		cf = clone.CFrame
		size = clone.Size
	end

	if cf and size then
		local maxDim = math.max(size.X, size.Y, size.Z)
		if maxDim == 0 then maxDim = 5 end
		camera.CFrame = CFrame.new(cf.Position + (cf.LookVector * (maxDim * 1.5)) + Vector3.new(0, maxDim * 0.2, 0), cf.Position)
	end
end

-- 监听抽奖结果并执行老虎机滚动动画
-- [修改原因] 新增 serverDuration 参数，确保客户端动画时间与服务端发奖时间完美对齐
resultEvent.OnClientEvent:Connect(function(results, serverDuration)
	if isAnimating then return end
	isAnimating = true

	local monsterFolder = workspace:FindFirstChild("Monster image") or ReplicatedStorage:FindFirstChild("MonsterAppearances")
	
	-- [修改原因] 优先使用服务端下发的时间，普通1秒，快速0.3秒
	local duration = serverDuration or (isFastMode and 0.3 or 1.0)
	local startTime = os.clock()
	local frameCounter = 0

	local connection
	connection = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startTime
		frameCounter += 1
--【【【【【
		if elapsed >= duration then
			connection:Disconnect()
			-- [修改原因] 动画结束，展示真实抽中的怪物
			for i, vpf in ipairs(vpfList) do
				-- [修改原因] 精准匹配：如果是1抽，只有 results[1] 有值，只在 ViewportFrame01 显示结果。
				-- 剩余的框 (02-05) 将保留它们最后一次滚动时的随机怪物图像。
				local resLevel = results[i] 
				if resLevel then
					local template = monsterFolder and (monsterFolder:FindFirstChild("怪物形象" .. resLevel) or monsterFolder:FindFirstChild("Lv" .. resLevel) or monsterFolder:FindFirstChild("怪物形象 " .. resLevel))
					setupViewport(vpf, template)
				end
			end
			
			-- [修改原因] 增加极短暂的延迟，确保模型渲染彻底完成，防止玩家狂点导致的视觉闪烁Bug
			task.wait(0.1)
			isAnimating = false
			return
		end

		-- 每 4 帧更换一次模型随机闪烁
		if frameCounter % 4 == 0 then
			for i, vpf in ipairs(vpfList) do
				local randomLevel = math.random(1, 30)
				local template = monsterFolder and (monsterFolder:FindFirstChild("怪物形象" .. randomLevel) or monsterFolder:FindFirstChild("Lv" .. randomLevel) or monsterFolder:FindFirstChild("怪物形象 " .. randomLevel))
				setupViewport(vpf, template)
			end
		end
	end)
end)