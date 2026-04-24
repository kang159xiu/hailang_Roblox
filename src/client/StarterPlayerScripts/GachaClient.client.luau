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

-- [修改原因] 将界面开关逻辑移到最前面，确保即使后面等待节点或网络通信延迟，也不会影响玩家打开/关闭UI
btnEntry.MouseButton1Click:Connect(function()
	frameGacha.Visible = not frameGacha.Visible
end)

local btnGold = frameGacha:WaitForChild("钱抽奖")
local btnRbx = frameGacha:WaitForChild("R币抽奖")
local btnFast = frameGacha:WaitForChild("快速转")
local frameDisplay = frameGacha:WaitForChild("显示抽奖内容_Fram")

-- [注意] 这里请确保你的5个框名字真的是 "01", "02"... 如果不是，请修改这里的字符串
local vpfList = {
	frameDisplay:WaitForChild("ImageLabel_01"),
	frameDisplay:WaitForChild("ImageLabel_02"),
	frameDisplay:WaitForChild("ImageLabel_03"),
	frameDisplay:WaitForChild("ImageLabel_04"),
	frameDisplay:WaitForChild("ImageLabel_05"),
}

-- 提示：如果服务端脚本报错没有运行，这里也会卡住
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local requestEvent = remotes:WaitForChild("GachaRequest")
local resultEvent = remotes:WaitForChild("GachaResult")

local PRODUCT_ID_10_PULL = 3580035858
local isFastMode = false
local isAnimating = false

-- 界面开关
btnEntry.MouseButton1Click:Connect(function()
	frameGacha.Visible = not frameGacha.Visible
end)

btnFast.MouseButton1Click:Connect(function()
	isFastMode = not isFastMode
	-- [修改原因] 给予玩家视觉反馈
	btnFast.ImageColor3 = isFastMode and Color3.fromRGB(150, 255, 150) or Color3.fromRGB(255, 255, 255)
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

-- [修改原因] 3D 模型渲染辅助函数，自动计算最完美的相机景深，防止怪物穿模或过小
local function setupViewport(vpf: ViewportFrame, modelTemplate: Instance?)
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
		-- 摄像机稍微抬高并向后退，正视怪物模型
		camera.CFrame = CFrame.new(cf.Position + (cf.LookVector * (maxDim * 1.5)) + Vector3.new(0, maxDim * 0.2, 0), cf.Position)
	end
end

-- [修改原因] 监听抽奖结果并执行老虎机滚动动画
resultEvent.OnClientEvent:Connect(function(results)
	if isAnimating then return end
	isAnimating = true

	local monsterFolder = workspace:FindFirstChild("Monster image") or ReplicatedStorage:FindFirstChild("MonsterAppearances")
	
	local duration = isFastMode and 0.5 or 2.5
	local startTime = os.clock()
	local frameCounter = 0

	local connection
	connection = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startTime
		frameCounter += 1

		if elapsed >= duration then
			connection:Disconnect()
			-- [修改原因] 动画结束，展示真实抽中的怪物。如果是 10 抽，截取前 5 个展示在格子里；如果是 1 抽，全部格子展示同 1 个以示强调
			for i, vpf in ipairs(vpfList) do
				local resLevel = (#results > 1) and results[i] or results[1]
				if resLevel then
					local template = monsterFolder and (monsterFolder:FindFirstChild("怪物形象" .. resLevel) or monsterFolder:FindFirstChild("Lv" .. resLevel) or monsterFolder:FindFirstChild("怪物形象 " .. resLevel))
					setupViewport(vpf, template)
				end
			end
			isAnimating = false
			return
		end

		-- [修改原因] 每 4 帧更换一次模型，实现疯狂随机闪烁的抽奖感
		if frameCounter % 4 == 0 then
			for i, vpf in ipairs(vpfList) do
				local randomLevel = math.random(1, 30)
				local template = monsterFolder and (monsterFolder:FindFirstChild("怪物形象" .. randomLevel) or monsterFolder:FindFirstChild("Lv" .. randomLevel) or monsterFolder:FindFirstChild("怪物形象 " .. randomLevel))
				setupViewport(vpf, template)
			end
		end
	end)
end)