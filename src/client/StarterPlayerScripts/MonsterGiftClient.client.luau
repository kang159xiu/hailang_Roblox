--!strict
-- StarterPlayerScripts.MonsterGiftClient
-- 玩家互送怪物客户端逻辑：
-- 1) 本地玩家正在拿怪物时，检测附近其他玩家，并显示按 E 赠送提示。
-- 2) 接收服务端赠送 offer，打开 MainUI.赠送界面并填充怪物信息。
-- 3) 处理接受/拒绝按钮，真正校验和转移全部由服务端完成。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")
local remotes = ReplicatedStorage:WaitForChild("Remotes")

local requestMonsterGiftRemote = remotes:WaitForChild("RequestMonsterGift") :: RemoteEvent
local showMonsterGiftOfferRemote = remotes:WaitForChild("ShowMonsterGiftOffer") :: RemoteEvent
local respondMonsterGiftOfferRemote = remotes:WaitForChild("RespondMonsterGiftOffer") :: RemoteEvent

local GIFT_PROMPT_NAME = "LocalMonsterGiftPrompt"
local PROMPT_DISTANCE = 8 --赠送距离
local SCAN_INTERVAL = 0.35

type GiftMonsterPayload = {
	MonsterLevel: number?,
	Value: number?,
	GoldPerSec: number?,
	UpgradeLevel: number?,
	BaseValue: number?,
	BaseGoldPerSec: number?,
	SourceZoneLevel: number?,
	ExpireUnix: number?,
	StorageKind: string?,
}

type GiftOfferPayload = {
	OfferId: string?,
	DonorUserId: number?,
	DonorName: string?,
	Monster: GiftMonsterPayload?,
	ExpireSeconds: number?,
}

local promptsByUserId: {[number]: ProximityPrompt} = {}
local currentOfferId: string? = nil
local acceptConnection: RBXScriptConnection? = nil
local rejectConnection: RBXScriptConnection? = nil
local closeConnection: RBXScriptConnection? = nil

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

local function getMonsterAppearanceFolders(): {Instance}
	local folders: {Instance} = {}
	appendUnique(folders, ReplicatedStorage:FindFirstChild("Monster image"))
	appendUnique(folders, ReplicatedStorage:FindFirstChild("MonsterAppearances"))
	appendUnique(folders, workspace:FindFirstChild("Monster image"))
	return folders
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

local function findMonsterTemplate(level: number): Instance?
	local safeLevel = math.max(1, math.floor(tonumber(level) or 1))
	local strNormal = tostring(safeLevel)
	local strZero = string.format("%02d", safeLevel)
	local names = {
		"怪物形象" .. strNormal,
		"怪物形象" .. strZero,
		"怪物形象 " .. strNormal,
		"怪物形象 " .. strZero,
		"Lv" .. strNormal,
		"Lv" .. strZero,
		"Lv " .. strNormal,
		"Lv " .. strZero,
		strNormal,
		strZero,
	}

	local nameSet: {[string]: boolean} = {}
	for _, name in ipairs(names) do
		nameSet[name] = true
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

		for _, name in ipairs(names) do
			consider(root:FindFirstChild(name))
		end
		if best then
			return best
		end

		for _, inst in ipairs(root:GetDescendants()) do
			if nameSet[inst.Name] then
				consider(inst)

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

	for _, root in ipairs(getMonsterAppearanceFolders()) do
		local found = findInRoot(root)
		if found then
			return found
		end
	end

	warn(string.format("[MonsterGiftClient] 未找到赠送怪物形象模板：Lv.%d", safeLevel))
	return nil
end

local function setupViewport(viewport: Instance, modelSource: Instance?)
	if not viewport:IsA("ViewportFrame") then
		return
	end

	viewport:ClearAllChildren()
	if not modelSource then
		return
	end

	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(180, 180, 180)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-1, -1, -1)

	local clone = modelSource:Clone()
	clone.Parent = viewport

	local camera = Instance.new("Camera")
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	if clone:IsA("Folder") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name .. "_ViewportModel"
		wrapper.Parent = viewport
		for _, child in ipairs(clone:GetChildren()) do
			child.Parent = wrapper
		end
		clone:Destroy()
		clone = wrapper
	end

	local visualModel = clone:FindFirstChild("Model", true)
	if visualModel and visualModel:IsA("Model") and visualModel:FindFirstChildWhichIsA("BasePart", true) then
		visualModel.Parent = viewport
		clone:Destroy()
		clone = visualModel
	end

	local function isLikelyVisualPart(part: BasePart): boolean
		return part.Name ~= "RootPart" and part.Transparency < 1
	end

	local function getVisualBounds(root: Instance): (CFrame?, Vector3?)
		local parts: {BasePart} = {}
		for _, inst in ipairs(root:GetDescendants()) do
			if inst:IsA("BasePart") and isLikelyVisualPart(inst) then
				table.insert(parts, inst)
			end
		end
		if root:IsA("BasePart") and isLikelyVisualPart(root) then
			table.insert(parts, root)
		end

		if #parts == 0 then
			for _, inst in ipairs(root:GetDescendants()) do
				if inst:IsA("BasePart") then
					table.insert(parts, inst)
				end
			end
			if root:IsA("BasePart") then
				table.insert(parts, root)
			end
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
		if root:IsA("Model") then
			local cf, size = root:GetBoundingBox()
			return cf, size
		elseif root:IsA("BasePart") then
			return root.CFrame, root.Size
		end
		return nil, nil
	end

	local boundsCF, boundsSize = getVisualBounds(clone)
	if not boundsCF or not boundsSize then
		warn("[MonsterGiftClient] Viewport 渲染失败：模板中没有可显示 BasePart - " .. modelSource:GetFullName())
		return
	end

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
		return
	end

	local maxDim = math.max(boundsSize.X, boundsSize.Y, boundsSize.Z)
	if maxDim < 0.1 then
		maxDim = 5
	end

	local modelCF = getModelBounds(clone)
	local center = if modelCF then modelCF.Position else boundsCF.Position
	local distance = maxDim
	local height = math.max(boundsSize.Y * 0.02, maxDim * 0.15)
	camera.FieldOfView = 35
	camera.CFrame = CFrame.new(center + Vector3.new(-distance, height, -distance), center)
end

local function getHrp(player: Player): BasePart?
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end
	return nil
end

local function characterHasGiftableMonster(character: Model?): boolean
	if not character then
		return false
	end

	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and child:GetAttribute("IsMonsterItem") == true then
			return true
		end
	end

	local carriedHolder = character:FindFirstChild("CarriedMonsters")
	return carriedHolder ~= nil and #carriedHolder:GetChildren() > 0
end

local function getDistanceToLocalPlayer(otherPlayer: Player): number?
	local localHrp = getHrp(localPlayer)
	local otherHrp = getHrp(otherPlayer)
	if not localHrp or not otherHrp then
		return nil
	end
	return (localHrp.Position - otherHrp.Position).Magnitude
end

local function removePromptForUserId(userId: number)
	local prompt = promptsByUserId[userId]
	if prompt then
		prompt:Destroy()
		promptsByUserId[userId] = nil
	end
end

local function ensurePromptForPlayer(receiver: Player, hrp: BasePart)
	local existing = promptsByUserId[receiver.UserId]
	if existing and existing.Parent == hrp then
		return
	end

	removePromptForUserId(receiver.UserId)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = GIFT_PROMPT_NAME
	prompt.ActionText = "Gift" --赠送
	prompt.ObjectText = receiver.DisplayName ~= "" and receiver.DisplayName or receiver.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.RequiresLineOfSight = false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Parent = hrp

	prompt.Triggered:Connect(function(triggeringPlayer: Player?)
		if triggeringPlayer and triggeringPlayer ~= localPlayer then
			return
		end
		requestMonsterGiftRemote:FireServer(receiver.UserId)
	end)

	promptsByUserId[receiver.UserId] = prompt
end

local function refreshGiftPrompts()
	local localCanGift = characterHasGiftableMonster(localPlayer.Character)
	if not localCanGift then
		for userId in pairs(promptsByUserId) do
			removePromptForUserId(userId)
		end
		return
	end

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= localPlayer then
			local hrp = getHrp(otherPlayer)
			local distance = getDistanceToLocalPlayer(otherPlayer)
			local shouldShow = hrp ~= nil
				and distance ~= nil
				and distance <= PROMPT_DISTANCE

			if shouldShow and hrp then
				ensurePromptForPlayer(otherPlayer, hrp)
			else
				removePromptForUserId(otherPlayer.UserId)
			end
		end
	end

	for userId, prompt in pairs(promptsByUserId) do
		local owner = Players:GetPlayerByUserId(userId)
		if not owner or not owner.Parent or not prompt.Parent then
			removePromptForUserId(userId)
		end
	end
end

local function findGiftWindow(): GuiObject?
	local mainUI = playerGui:FindFirstChild("MainUI")
	local giftWindow = mainUI and mainUI:FindFirstChild("赠送界面", true)
	if giftWindow and giftWindow:IsA("GuiObject") then
		return giftWindow
	end
	return nil
end

local function setSelectedStrokeEnabled(button: Instance?, enabled: boolean)
	if not button then
		return
	end
	local stroke = button:FindFirstChild("SelectedStroke", true)
	if stroke and stroke:IsA("UIStroke") then
		stroke.Enabled = enabled
	end
end

local function hideGiftWindow()
	local giftWindow = findGiftWindow()
	if giftWindow then
		giftWindow.Visible = false
	end
	currentOfferId = nil
end

local function bindCloseButton(giftWindow: GuiObject)
	local topBar = giftWindow:FindFirstChild("顶部条", true)
	local closeButton = topBar and topBar:FindFirstChild("Close", true)

	if closeConnection then
		closeConnection:Disconnect()
		closeConnection = nil
	end

	if closeButton and closeButton:IsA("GuiButton") then
		closeConnection = closeButton.Activated:Connect(function()
			hideGiftWindow()
		end)
		closeButton.MouseButton1Click:Connect(function()
			hideGiftWindow()
		end)
	else
		warn("[MonsterGiftClient] 赠送界面中未找到 顶部条.Close 按钮")
	end
end

local function bindGiftButtons(giftWindow: GuiObject)
	local buttonFrame = giftWindow:FindFirstChild("接受/拒绝按钮", true)
	local acceptButton = buttonFrame and buttonFrame:FindFirstChild("接受", true)
	local rejectButton = buttonFrame and buttonFrame:FindFirstChild("拒绝", true)

	if acceptConnection then
		acceptConnection:Disconnect()
		acceptConnection = nil
	end
	if rejectConnection then
		rejectConnection:Disconnect()
		rejectConnection = nil
	end
	bindCloseButton(giftWindow)

	if acceptButton and acceptButton:IsA("GuiButton") then
		acceptConnection = acceptButton.Activated:Connect(function()
			if not currentOfferId then
				return
			end
			respondMonsterGiftOfferRemote:FireServer(currentOfferId, true)
			hideGiftWindow()
		end)
	else
		warn("[MonsterGiftClient] 赠送界面中未找到 接受 按钮")
	end

	if rejectButton and rejectButton:IsA("GuiButton") then
		rejectConnection = rejectButton.Activated:Connect(function()
			if not currentOfferId then
				return
			end
			local stroke = rejectButton:FindFirstChild("SelectedStroke", true)
			if stroke and stroke:IsA("UIStroke") then
				stroke.Enabled = not stroke.Enabled
			end
			respondMonsterGiftOfferRemote:FireServer(currentOfferId, false)
			task.delay(0.12, hideGiftWindow)
		end)
	else
		warn("[MonsterGiftClient] 赠送界面中未找到 拒绝 按钮")
	end

end

local function bindCloseButtonWhenAvailable()
	local giftWindow = findGiftWindow()
	if giftWindow then
		bindCloseButton(giftWindow)
	end
end

local function populateGiftWindow(giftWindow: GuiObject, payload: GiftOfferPayload)
	local monster: any = payload.Monster or {}
	local monsterLevel = math.max(1, math.floor(tonumber(monster.MonsterLevel) or 1))
	local goldPerSec = math.floor(tonumber(monster.GoldPerSec) or 0)
	local donorName = payload.DonorName or "Player"

	local infoFrame = giftWindow:FindFirstChild("赠送信息Farm", true)
	if not infoFrame then
		warn("[MonsterGiftClient] 赠送界面缺少 赠送信息Farm")
		return
	end

	local nameLabel = infoFrame:FindFirstChild("xx玩家NAME", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = donorName
	end

	local infoLabel = infoFrame:FindFirstChild("等级+x钱币/s", true)
	if infoLabel and infoLabel:IsA("TextLabel") then
		infoLabel.Text = string.format("Lv.%d +%d Coins/s", monsterLevel, goldPerSec)
	end

	local itemFrame = infoFrame:FindFirstChild("Item", true)
	local viewport = itemFrame and itemFrame:FindFirstChild("ViewportFrame_显示赠怪形象", true)
	if viewport then
		setupViewport(viewport, findMonsterTemplate(monsterLevel))
	else
		warn("[MonsterGiftClient] 赠送界面缺少 Item.ViewportFrame_显示赠怪形象")
	end

	local buttonFrame = giftWindow:FindFirstChild("接受/拒绝按钮", true)
	local rejectButton = buttonFrame and buttonFrame:FindFirstChild("拒绝", true)
	setSelectedStrokeEnabled(rejectButton, false)
end

showMonsterGiftOfferRemote.OnClientEvent:Connect(function(payload: GiftOfferPayload)
	if type(payload) ~= "table" or type(payload.OfferId) ~= "string" then
		return
	end

	local giftWindow = findGiftWindow()
	if not giftWindow then
		warn("[MonsterGiftClient] 未找到 PlayerGui.MainUI.赠送界面，无法显示赠送确认")
		return
	end

	currentOfferId = payload.OfferId
	populateGiftWindow(giftWindow, payload)
	bindGiftButtons(giftWindow)
	giftWindow.Visible = true

	local expireSeconds = math.max(1, math.floor(tonumber(payload.ExpireSeconds) or 20))
	local offerIdAtOpen = currentOfferId
	task.delay(expireSeconds, function()
		if currentOfferId == offerIdAtOpen then
			hideGiftWindow()
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	removePromptForUserId(player.UserId)
end)

bindCloseButtonWhenAvailable()
playerGui.DescendantAdded:Connect(function(inst: Instance)
	if inst.Name == "Close" or inst.Name == "赠送界面" or inst.Name == "顶部条" then
		task.defer(bindCloseButtonWhenAvailable)
	end
end)

task.spawn(function()
	while true do
		refreshGiftPrompts()
		task.wait(SCAN_INTERVAL)
	end
end)

-- 角色重生/位移后立即刷新一次，避免提示残留到旧 HumanoidRootPart。
localPlayer.CharacterAdded:Connect(function()
	for userId in pairs(promptsByUserId) do
		removePromptForUserId(userId)
	end
	task.defer(refreshGiftPrompts)
end)

RunService.Heartbeat:Connect(function()
	-- Heartbeat 只做轻量兜底：如果某个 Prompt 的父级被销毁，马上清理表引用。
	for userId, prompt in pairs(promptsByUserId) do
		if not prompt.Parent then
			promptsByUserId[userId] = nil
		end
	end
end)
