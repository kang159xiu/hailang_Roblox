-- 客户端路径: StarterPlayerScripts.GachaClient
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local DEBUG_GACHA_STARTUP = false

local player = Players.LocalPlayer
local PlayerGui = player:WaitForChild("PlayerGui")
local mainUI = PlayerGui:WaitForChild("MainUI")

-- 绑定 UI 节点
local btnEntry = mainUI:WaitForChild("抽奖入口")
local frameGacha = mainUI:WaitForChild("抽奖界面")

local btnGold = frameGacha:WaitForChild("钱抽奖")
local btnRbx = frameGacha:WaitForChild("R币抽奖")
local btnRbx5 = frameGacha:WaitForChild("r币5次")
local btnCount = frameGacha:WaitForChild("次数抽奖")
local countDrawsLabel = btnCount:WaitForChild("Draws")
local onlineRewardsLabel = btnCount:FindFirstChild("Online Rewards")
local btnFast = frameGacha:WaitForChild("快速转")
local btnClose = frameGacha:WaitForChild("关闭")
local frameDisplay = frameGacha:WaitForChild("显示抽奖内容_Fram")
local frameBorder = frameDisplay:WaitForChild("边框")

-- 获取 5 个展示框
local vpfList = {
	frameDisplay:WaitForChild("ViewportFrame01"),
	frameDisplay:WaitForChild("ViewportFrame02"),
	frameDisplay:WaitForChild("ViewportFrame03"),
	frameDisplay:WaitForChild("ViewportFrame04"),
	frameDisplay:WaitForChild("ViewportFrame05"),
}

-- 获取 5 个边框；每个边框内有 5 个 UIGradient，对应 5 档稀有度。
local borderList = {
	frameBorder:WaitForChild("ImageLabel1"),
	frameBorder:WaitForChild("ImageLabel2"),
	frameBorder:WaitForChild("ImageLabel3"),
	frameBorder:WaitForChild("ImageLabel4"),
	frameBorder:WaitForChild("ImageLabel5"),
}

local RARITY_GRADIENT_BY_TIER = {
	[1] = "01UIGradient_green",
	[2] = "02UIGradient_blue",
	[3] = "03UIGradient_violet",
	[4] = "04UIGradient_yellow",
	[5] = "05UIGradient_red",
}

local findMonsterTemplate
local setupViewport
local hasGachaPreview
local refreshGachaPreview

local function getMonsterRarityTier(level: number): number
	-- 30 个怪，每 6 级为 1 档稀有度：1-6 绿、7-12 蓝、13-18 紫、19-24 黄、25-30 红。
	local safeLevel = math.clamp(math.floor(tonumber(level) or 1), 1, 30)
	return math.clamp(math.ceil(safeLevel / 6), 1, 5)
end

local function setBorderRarity(border: Instance?, level: number)
	if not border or not border:IsA("GuiObject") then
		return
	end

	local activeGradientName = RARITY_GRADIENT_BY_TIER[getMonsterRarityTier(level)]
	border.Visible = true

	for _, child in ipairs(border:GetChildren()) do
		if child:IsA("UIGradient") then
			child.Enabled = child.Name == activeGradientName
		end
	end
end

local function setSlotMonster(slotIndex: number, level: number, monsterFolder: Instance, isDebug: boolean)
	local vpf = vpfList[slotIndex]
	if not vpf then
		return
	end

	local template = findMonsterTemplate(monsterFolder, level)
	if template then
		setupViewport(vpf, template, isDebug)
		setBorderRarity(borderList[slotIndex], level)
	end
end

local function appendUnique(list: {Instance}, inst: Instance?)
	if not inst then
		return
	end
	for _, existing in ipairs(list) do
		if existing == inst then
			return
		end
	end
	table.insert(list, inst)
end

local function getMonsterFolderCandidates(): {Instance}
	local folders = {}
	appendUnique(folders, ReplicatedStorage:FindFirstChild("Monster image"))
	appendUnique(folders, ReplicatedStorage:FindFirstChild("MonsterAppearances"))
	appendUnique(folders, workspace:FindFirstChild("Monster image"))
	return folders
end

local function findMonsterFolder(): Instance?
	-- [资源路径] 怪物形象主路径是 ReplicatedStorage 下名为 "Monster image" 的文件夹。
	-- 因为文件夹名中间有空格，代码里不能写 ReplicatedStorage.Monster image，必须用 FindFirstChild("Monster image")。
	-- MonsterAppearances 是服务端整理后的兼容备用目录；Workspace.Monster image 作为最后兜底。
	return getMonsterFolderCandidates()[1]
end

local touchDebounce = false
local gachaTouchConnection: RBXScriptConnection? = nil

local function openGachaUI()
	frameGacha.Visible = true

	local analyticsRemote = game.ReplicatedStorage:WaitForChild("Remotes"):FindFirstChild("Analytics_Remote")
	if analyticsRemote then
		analyticsRemote:FireServer("Funnel", "Gacha_UI_Opened")
	end

	if not hasGachaPreview() then
		refreshGachaPreview(false)
	end
end

hasGachaPreview = function()
	for _, vpf in ipairs(vpfList) do
		if #vpf:GetChildren() > 0 then
			return true
		end
	end
	return false
end

refreshGachaPreview = function(isDebug: boolean)
	local monsterFolder = findMonsterFolder()
	if not monsterFolder then
		warn("❌ [致命错误] 在 ReplicatedStorage 中没找到 'Monster image'（也未找到兼容目录 MonsterAppearances）！请检查名字。")
		return false
	end

	task.wait(0.5)

	for slotIndex, _ in ipairs(vpfList) do
		local randomLevel = math.random(1, 30)
		setSlotMonster(slotIndex, randomLevel, monsterFolder, isDebug)
	end

	return true
end

-- [修改原因] 打开抽奖界面时，如果预览还是空的，就立即补刷 5 个怪物形象
btnEntry.MouseButton1Click:Connect(function()
	frameGacha.Visible = not frameGacha.Visible
	if frameGacha.Visible then
		openGachaUI()
	end
end)

local function bindGachaTouch(part: BasePart)
	if gachaTouchConnection then
		gachaTouchConnection:Disconnect()
		gachaTouchConnection = nil
	end

	gachaTouchConnection = part.Touched:Connect(function(hit)
		if touchDebounce then
			return
		end

		local character = player.Character
		if not character or not hit:IsDescendantOf(character) then
			return
		end

		touchDebounce = true
		openGachaUI()

		task.delay(1, function()
			touchDebounce = false
		end)
	end)
end

local function tryBindGachaTouchFromInstance(inst: Instance?)
	if inst and inst:IsA("BasePart") then
		bindGachaTouch(inst)
		return true
	end
	return false
end

task.spawn(function()
	local immediate = workspace:FindFirstChild("转盘抽奖")
	if tryBindGachaTouchFromInstance(immediate) then
		return
	end

	local waited = workspace:WaitForChild("转盘抽奖", 30)
	if tryBindGachaTouchFromInstance(waited) then
		return
	end

	warn("[GachaClient] 30 秒内未找到 Workspace.转盘抽奖，开始监听后续加载")
end)

workspace.ChildAdded:Connect(function(child)
	if child.Name == "转盘抽奖" then
		tryBindGachaTouchFromInstance(child)
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

	local nameSet = {}
	for _, name in ipairs(names) do
		nameSet[name] = true
	end

	local function isRenderableTemplate(inst: Instance): boolean
		return inst:IsA("BasePart")
			or ((inst:IsA("Model") or inst:IsA("Folder")) and inst:FindFirstChildWhichIsA("BasePart", true) ~= nil)
	end

	local function scoreTemplate(inst: Instance): number
		if not isRenderableTemplate(inst) then
			return -1
		end

		local score = #inst:GetDescendants()
		if inst:IsA("Model") then
			score += 1000000
		elseif inst:IsA("Folder") then
			score += 200000
		elseif inst:IsA("BasePart") then
			score += 100000
		end
		return score
	end

	local function findInRoot(root: Instance): Instance?
		local best: Instance? = nil
		local bestScore = -1

		local function consider(candidate: Instance?)
			if not candidate then
				return
			end
			local score = scoreTemplate(candidate)
			if score > bestScore then
				best = candidate
				bestScore = score
			end
		end

		-- 先查直接子级，和 Studio 中 ReplicatedStorage.Monster image.怪物形象01 的结构对应。
		for _, name in ipairs(names) do
			consider(root:FindFirstChild(name))
		end

		if best then
			return best
		end

		-- 再递归查找，兼容 Monster image 下面又套了一层文件夹/模型的情况。
		for _, inst in ipairs(root:GetDescendants()) do
			if nameSet[inst.Name] then
				consider(inst)

				-- 如果命中的是某个零件/子物件，向上找最近的 Model，避免只克隆一个定位 Part 导致看不到完整怪物。
				local cur = inst.Parent
				while cur and cur ~= root do
					if cur:IsA("Model") then
						consider(cur)
						break
					end
					cur = cur.Parent
				end
			end
		end

		return best
	end

	local roots = {}
	appendUnique(roots, folder)
	for _, candidate in ipairs(getMonsterFolderCandidates()) do
		appendUnique(roots, candidate)
	end

	for _, root in ipairs(roots) do
		local found = findInRoot(root)
		if found then
			return found
		end
	end

	local childNames = {}
	for _, child in ipairs(folder:GetChildren()) do
		table.insert(childNames, child.Name .. "(" .. child.ClassName .. ")")
	end
	
	warn("⚠️ [查找失败] 目标等级:", level, "候选名字:", table.concat(names, ", "), "主文件夹:", folder:GetFullName(), "直接子级:", table.concat(childNames, ", "))
	return nil
end

-- =====================================================================
-- 3D 渲染核心函数 (精准定位 Part 版)
-- =====================================================================
setupViewport = function(vpf: Instance, modelTemplate: Instance?, isDebug: boolean)
	if not vpf:IsA("ViewportFrame") then return end
	vpf:ClearAllChildren()
	if not modelTemplate then return end

	vpf.BackgroundTransparency = 1
	vpf.Ambient = Color3.fromRGB(180, 180, 180)
	vpf.LightColor = Color3.fromRGB(255, 255, 255)
	vpf.LightDirection = Vector3.new(-1, -1, -1)

	-- 1. 直接克隆整个外层 Model，不做任何多余的拆解
	local clone = modelTemplate:Clone()
	clone.Parent = vpf

	local camera = Instance.new("Camera")
	vpf.CurrentCamera = camera
	camera.Parent = vpf

	-- 如果模板本身是 Folder，先包成 Model，方便后续统一 PivotTo / GetBoundingBox。
	if clone:IsA("Folder") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name .. "_ViewportModel"
		wrapper.Parent = vpf
		for _, child in ipairs(clone:GetChildren()) do
			child.Parent = wrapper
		end
		clone:Destroy()
		clone = wrapper
	end

	-- 2. Studio 中的怪物模板结构是：外层怪物模板 > 内部名为 "Model" 的编组 > RootPart/真实外观。
	-- 真正该显示的是内部 "Model"，不是外层模板；否则外层定位对象或 RootPart 可能把包围盒撑歪，导致相机看向空处。
	local visualModel = clone:FindFirstChild("Model", true)
	if visualModel and visualModel:IsA("Model") and visualModel:FindFirstChildWhichIsA("BasePart", true) then
		visualModel.Parent = vpf
		clone:Destroy()
		clone = visualModel

	end

	local function isLikelyVisualPart(part: BasePart): boolean
		-- RootPart 通常只是透明定位块，不应该决定镜头距离/中心。
		-- 但如果整个模型只有 RootPart，后面会自动回退使用全部零件，避免完全没包围盒。
		if part.Name == "RootPart" then
			return false
		end
		if part.Transparency >= 1 then
			return false
		end
		return true
	end

	local function getVisualBounds(root: Instance): (CFrame?, Vector3?)
		local parts = {}
		for _, inst in ipairs(root:GetDescendants()) do
			if inst:IsA("BasePart") and isLikelyVisualPart(inst) then
				table.insert(parts, inst)
			end
		end

		-- 如果排除 RootPart/全透明零件后没有任何可见零件，则回退到全部 BasePart，至少保证能显示。
		if #parts == 0 then
			for _, inst in ipairs(root:GetDescendants()) do
				if inst:IsA("BasePart") then
					table.insert(parts, inst)
				end
			end
		end

		if root:IsA("BasePart") and (#parts == 0 or isLikelyVisualPart(root)) then
			table.insert(parts, root)
		end

		if #parts == 0 then
			return nil, nil
		end

		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		for _, part in ipairs(parts) do
			local cf = part.CFrame
			local half = part.Size * 0.5
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						local p = (cf * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
						minX = math.min(minX, p.X)
						minY = math.min(minY, p.Y)
						minZ = math.min(minZ, p.Z)
						maxX = math.max(maxX, p.X)
						maxY = math.max(maxY, p.Y)
						maxZ = math.max(maxZ, p.Z)
					end
				end
			end
		end

		local center = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
		local size = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
		return CFrame.new(center), size
	end

	local function getModelBounds(root: Instance): (CFrame?, Vector3?)
		-- 以怪物形象内部 Model 自身的整体中心作为摄像机定位点。
		-- 和 getVisualBounds 不同，这里不排除 RootPart/透明 Part，目的是按内部 Model 的真实整体中心对齐。
		if root:IsA("Model") then
			local cf, size = root:GetBoundingBox()
			return cf, size
		elseif root:IsA("BasePart") then
			return root.CFrame, root.Size
		end

		return nil, nil
	end

	-- 3. ViewportFrame 必须按“可见外观”计算镜头。
	-- 旧版只用 Root/同名 Part 或整个外层模型对焦；如果 RootPart 是透明定位块，或者视觉模型相对根 Part 有偏移，
	-- 相机会看向空位置，结果就是用户看到 5 个蓝色 ViewportFrame 但没有怪物。
	local boundsCF: CFrame?
	local boundsSize: Vector3?
	boundsCF, boundsSize = getVisualBounds(clone)

	if not boundsCF or not boundsSize then
		warn("⚠️ [渲染失败] 在", clone.Name, "里面完全找不到可显示的 BasePart，请检查怪物模板！")
		return
	end

	-- 4. 把模型中心移动到 ViewportFrame 原点附近，避免模板原始世界坐标太远导致相机看不到。
	if clone:IsA("Model") then
		local modelCF, modelSize = getModelBounds(clone)
		if modelCF and modelSize then
			clone:PivotTo(CFrame.new(0, modelSize.Y * 0.5, 0) * modelCF:Inverse() * clone:GetPivot())
		else
			clone:PivotTo(CFrame.new(0, boundsSize.Y * 0.5, 0) * boundsCF:Inverse() * clone:GetPivot())
		end
		boundsCF, boundsSize = getVisualBounds(clone)
	elseif clone:IsA("BasePart") then
		clone.CFrame = CFrame.new(0, boundsSize.Y * 0.5, 0)
		boundsCF, boundsSize = getVisualBounds(clone)
	end

	if not boundsCF or not boundsSize then
		warn("⚠️ [渲染失败] 移动模型后无法计算包围盒:", clone.Name)
		return
	end

	local maxDim = math.max(boundsSize.X, boundsSize.Y, boundsSize.Z)
	if maxDim < 0.1 then
		maxDim = 5
	end


	local modelCF = getModelBounds(clone)
	local center = if modelCF then modelCF.Position else boundsCF.Position
	local distance = maxDim * 1 --镜头距离
	local height = math.max(boundsSize.Y * 0.02, maxDim * 0.15) --控制高度 boundsSize.Y 越小越低

	-- 摄像机水平位置：之前 Vector3.new(distance, height, distance) 拍到怪物背面；
	-- 这里反转到另一侧，从怪物正面方向看内部 Model 中心。
	local offset = Vector3.new(-distance, height, -distance)
	camera.FieldOfView = 35
	camera.CFrame = CFrame.new(center + offset, center)


end

-- =====================================================================
-- 业务逻辑绑定
-- =====================================================================

task.spawn(function()
	if DEBUG_GACHA_STARTUP then
		print("🚀 --- 游戏开局初始化开始，2秒后加载初始怪物展示 ---")
	end
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

local function getCurrentGachaDrawCount(): number
	local count = player:GetAttribute("GachaDrawCount")
	return math.max(0, math.floor(tonumber(count) or 0))
end

local function updateCountDrawsLabel()
	if countDrawsLabel:IsA("TextLabel") or countDrawsLabel:IsA("TextButton") or countDrawsLabel:IsA("TextBox") then
		countDrawsLabel.Text = "x" .. tostring(getCurrentGachaDrawCount())
	end
end

local function formatOnlineRewardTime(seconds: number): string
	seconds = math.max(0, math.floor(tonumber(seconds) or 0))
	local minutes = math.floor(seconds / 60)
	local remainSeconds = seconds % 60
	return string.format("%dm%02ds", minutes, remainSeconds)
end

local function updateOnlineRewardsLabel()
	if not onlineRewardsLabel or not (onlineRewardsLabel:IsA("TextLabel") or onlineRewardsLabel:IsA("TextButton") or onlineRewardsLabel:IsA("TextBox")) then
		return
	end

	if player:GetAttribute("OnlineRewardAllClaimed") == true then
		onlineRewardsLabel.Text = "Done <+1>"
		return
	end

	local secondsUntilNext = math.max(0, math.floor(tonumber(player:GetAttribute("OnlineRewardSecondsUntilNext")) or 0))
	onlineRewardsLabel.Text = formatOnlineRewardTime(secondsUntilNext) .. " <+1>"
end

updateCountDrawsLabel()
player:GetAttributeChangedSignal("GachaDrawCount"):Connect(updateCountDrawsLabel)
updateOnlineRewardsLabel()
player:GetAttributeChangedSignal("OnlineRewardSecondsUntilNext"):Connect(updateOnlineRewardsLabel)
player:GetAttributeChangedSignal("OnlineRewardAllClaimed"):Connect(updateOnlineRewardsLabel)

btnFast.MouseButton1Click:Connect(function()
	isFastMode = not isFastMode
	fastOpenIndicator.Visible = isFastMode
	requestEvent:FireServer("ToggleFastMode", isFastMode)
end)

btnGold.MouseButton1Click:Connect(function()
	if isAnimating then return end
	requestEvent:FireServer("Gold1")
end)

local function requestCountGacha()
	if isAnimating then
		return
	end

	updateCountDrawsLabel()
	local currentDrawCount = getCurrentGachaDrawCount()
	if currentDrawCount <= 0 then
		warn("[GachaClient] 次数抽奖失败：当前抽奖次数不足")
		return
	end

	print("[GachaClient] Count1 request, draws=", currentDrawCount)
	requestEvent:FireServer("Count1")
end

btnCount.Activated:Connect(requestCountGacha)


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

	local monsterFolder = findMonsterFolder()
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


				for slotIndex, _ in ipairs(vpfList) do
					setSlotMonster(slotIndex, resLevel, monsterFolder, true)
				end
				return
			end

			if frameCounter % 4 == 0 then
				for slotIndex, _ in ipairs(vpfList) do
					local randomLevel = math.random(1, 30)
					setSlotMonster(slotIndex, randomLevel, monsterFolder, false)
				end
			end
		end)

		repeat task.wait() until finished
		task.wait(0.05)
	end

	isAnimating = false
end)
