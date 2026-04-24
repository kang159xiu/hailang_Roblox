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
	-- 安全拦截！ImageLabel 不能显示 3D 模型
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
	-- [修改原因] 兼容性修复：如果怪物是个 Tool（工具），原代码无法读取大小会导致相机罢工，从而产生白屏！
	elseif clone:IsA("Tool") then
		local handle = clone:FindFirstChild("Handle") or clone:FindFirstChildWhichIsA("BasePart")
		if handle then
			cf = handle.CFrame
			size = handle.Size
		else
			-- 如果 Tool 里没有任何可见的实体零件，给个默认坐标防崩溃
			cf = CFrame.new(0, 0, 0)
			size = Vector3.new(2, 2, 2)
		end
	end

	if cf and size then
		local maxDim = math.max(size.X, size.Y, size.Z)
		if maxDim == 0 then maxDim = 5 end
		
		-- ==========================================
		-- 🛠️ 在这里调整显示怪物的大小和位置 🛠️
		-- ==========================================
		local ZOOM_MULTIPLIER = 0.8  -- 【控制大小】数值越小，怪物显得越大；数值越大，相机离得越远（怪物显得越小）。建议在 0.8 到 2.5 之间微调。
		local HEIGHT_OFFSET = 0.2    -- 【控制高低】数值越大，相机抬得越高（怪物看起来在画面偏下方）。
		
		-- 获取朝向，防止有些模型没有朝向导致报错
		local lookDir = cf.LookVector
		if lookDir.Magnitude < 0.01 then lookDir = Vector3.new(0, 0, -1) end 
		
		camera.CFrame = CFrame.new(cf.Position + (lookDir * (maxDim * ZOOM_MULTIPLIER)) + Vector3.new(0, maxDim * HEIGHT_OFFSET, 0), cf.Position)
	else
		warn("⚠️ 报错：无法计算 " .. clone.Name .. " 的大小，请确保它是 Model、BasePart 或包含零件的 Tool。")
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

		if elapsed >= duration then
			connection:Disconnect()
			-- [修改原因] 动画结束，展示真实抽中的怪物
            for i, vpf in ipairs(vpfList) do
				local resLevel = results[i] 
				if resLevel then
					local template = monsterFolder and (monsterFolder:FindFirstChild("怪物形象" .. resLevel) or monsterFolder:FindFirstChild("Lv" .. resLevel) or monsterFolder:FindFirstChild("怪物形象 " .. resLevel))
					
					if template then
						-- 找到了模型，正常渲染
						setupViewport(vpf, template)
					else
						-- [修改原因] 找不到模型时的安全拦截！不要调用 setupViewport 去清空它，而是发出警告
						warn("⚠️ 报错：玩家抽中了等级为 " .. resLevel .. " 的怪物，但在文件夹里找不到它的模型！")
						warn("请检查文件夹中是否有名为 '怪物形象" .. resLevel .. "' 的模型。")
						-- 因为没有执行清空操作，ViewportFrame01 会保留动画最后一帧的画面，不会变成白板
					end
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