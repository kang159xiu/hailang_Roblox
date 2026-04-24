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
	-- [修改原因] 立即强制上锁！防止玩家狂点导致给服务端发多次请求，造成背包结果和UI脱节
	isAnimating = true 
	requestEvent:FireServer("Gold1")
	
	-- 安全锁：如果服务端因为金币不足没能返回抽奖结果，2秒后自动解锁，防止按钮永远卡死
	task.delay(2, function() isAnimating = false end)
end)

btnRbx.MouseButton1Click:Connect(function()
	if isAnimating then return end
	isAnimating = true
	MarketplaceService:PromptProductPurchase(player, PRODUCT_ID_10_PULL)
	task.delay(3, function() isAnimating = false end)
end)

-- 3D 模型渲染辅助函数 (终极万能版)
local function setupViewport(vpf: Instance, modelTemplate: Instance?)
	if not vpf:IsA("ViewportFrame") then return end
	
	-- 每次渲染前清空上一次的残影
	vpf:ClearAllChildren()
	if not modelTemplate then return end

	local clone = modelTemplate:Clone()

	-- ==========================================
	-- [万能修复核心] 无论你提供的是什么奇葩格式，强行包成合规的 Model！
	-- ==========================================
	local wrapperModel = Instance.new("Model")
	wrapperModel.Name = "PureVisualModel"
	
	if clone:IsA("Model") or clone:IsA("BasePart") then
		-- 如果本来就是模型或零件，直接装进去
		clone.Parent = wrapperModel
	elseif clone:IsA("Tool") or clone:IsA("Folder") then
		-- 如果是 Tool 或 文件夹，强行剥掉外壳，把里面的肉（零件）全部掏出来装进去
		for _, child in ipairs(clone:GetChildren()) do
			child.Parent = wrapperModel
		end
		clone:Destroy()
	else
		clone.Parent = wrapperModel
	end
	
	wrapperModel.Parent = vpf

	-- 架设摄像机
	local camera = Instance.new("Camera")
	vpf.CurrentCamera = camera
	camera.Parent = vpf

	-- 自动抓取所有零件，计算最完美的中心点和大小（彻底告别找不到 PrimaryPart 的问题）
	local cf, size = wrapperModel:GetBoundingBox()
	
	-- 防呆机制：如果计算出的大小是 0（比如里面是个空壳）
	if size == Vector3.new(0, 0, 0) then
		local firstPart = wrapperModel:FindFirstChildWhichIsA("BasePart", true)
		if firstPart then
			cf = firstPart.CFrame
			size = firstPart.Size
		else
			warn("⚠️ 致命报错：你放在 Monster image 里的【" .. modelTemplate.Name .. "】是空的！里面没有任何 3D 实体零件！")
			return
		end
	end

	-- 精准对焦
	local maxDim = math.max(size.X, size.Y, size.Z)
	if maxDim < 0.1 then maxDim = 5 end
	
	-- ==========================================
	-- 🛠️ 依然可以在这里调整拍出来的大小 🛠️
	local ZOOM_MULTIPLIER = 1.2  -- 改小变大，改大变小
	local HEIGHT_OFFSET = 0.2    -- 调整高低
	-- ==========================================

	local lookDir = cf.LookVector
	if lookDir.Magnitude < 0.01 then lookDir = Vector3.new(0, 0, -1) end 
	
	camera.CFrame = CFrame.new(cf.Position + (lookDir * (maxDim * ZOOM_MULTIPLIER)) + Vector3.new(0, maxDim * HEIGHT_OFFSET, 0), cf.Position)
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

		if elapsed >= duration then
			connection:Disconnect()
			-- [修改原因] 动画结束，精确展示真实抽中的怪物，并彻底清理多余的假动画残留
			for i, vpf in ipairs(vpfList) do
				local resLevel = results[i] 
				if resLevel then
					local template = monsterFolder and (monsterFolder:FindFirstChild("怪物形象" .. resLevel) or monsterFolder:FindFirstChild("Lv" .. resLevel) or monsterFolder:FindFirstChild("怪物形象 " .. resLevel))
					
					if template then
						-- 完美匹配，显示玩家真正获得的模型
						setupViewport(vpf, template)
					else
						-- [核心修复] 如果因为你还没建好这个模型导致找不到，宁可让框清空，也绝不能留着上一个闪烁的假怪物骗人！
						warn("⚠️ 报错：抽中了【" .. resLevel .. "】级怪物，但文件夹里没有模型！已清空显示以防误导。")
						vpf:ClearAllChildren() 
					end
				else
					-- [核心修复] 如果是单抽，只有 results[1] 有值。02 到 05 号框必须强行清空！
					-- 否则它们会一直显示着老虎机转动时的假怪物，让玩家以为那是结果。
					vpf:ClearAllChildren()
				end
			end
			
			task.wait(0.1)
			-- 解锁交给下一次抽奖
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