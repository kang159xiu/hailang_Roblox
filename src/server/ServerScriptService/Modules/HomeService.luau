--!strict
-- ServerScriptService.Modules.HomeService
--
-- 新版本：
-- - Workspace.HOME 下已经预放置 HOME01~HOME08（以及房屋/怪放置区域/升级区域/出生点等）。
-- - 玩家进入时不再 Clone/复制，只是“随机分配一个未被占用的 HOME 地块”。
-- - 玩家离开时释放地块。
-- - 负责：
--   1) 分配与释放 HOME
--   2) 收集并标记玩家可用的“怪放置区域01~30”
--   3) 传送玩家到自己 HOME 的 出生点
--   4) 家园升级（1~3）+ 升级区域 SurfaceGui 文本更新 + 按等级显示/隐藏房屋（含 Truss/梯子形象）

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local HomeService = {}
local hiddenHousesCache: {[Instance]: {[number]: Instance}} = {}


print("家庭服务已加载")

export type PlacementSlot = {
	Index: number,
	Part: BasePart,
	SlotRoot: Instance,
	Collector: BasePart?,
}

export type PlayerHome = {
	HomeRoot: Instance, -- HOME01 / HOME02 ...（目前是 Part，但不依赖类型）
	Slots: {PlacementSlot}, -- 01~30
	UpgradeArea: Instance,
	UpgradePart: BasePart,
	SpawnPoint: BasePart,
}

local homesByUserId: {[number]: PlayerHome} = {}
local ownerByHome: {[Instance]: number} = {}

local function toast(player: Player, text: string)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild("PushClientToast")
	if ev and ev:IsA("RemoteEvent") then
		ev:FireClient(player, text)
	end
end

local function getHomeFolder(): Folder?
	local f = workspace:FindFirstChild("HOME")
	if f and f:IsA("Folder") then
		return f
	end
	return nil
end

local function scanAllHomes(): {Instance}
	local folder = getHomeFolder()
	if not folder then
		return {}
	end
	local list: {Instance} = {}
	for i = 1, 8 do
		local name = string.format("HOME%02d", i)
		local ch = folder:FindFirstChild(name)
		if ch and (ch:IsA("Model") or ch:IsA("Folder") or ch:IsA("BasePart")) then
			table.insert(list, ch)
		end
	end
	return list
end

local function parseSlotIndex(name: string): number?
	local digits = name:match("^怪放置区域(%d+)$")
	if not digits then
		return nil
	end
	return tonumber(digits)
end

local function findFirstNamedBasePart(root: Instance, childName: string): BasePart?
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == childName then
			return d
		end
	end
	return nil
end

local function collectSlots(homeRoot: Instance): {PlacementSlot}
	local slots: {PlacementSlot} = {}

	local function scanTree(root: Instance)
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("Model") or d:IsA("Folder") then
				local idx = parseSlotIndex(d.Name)
				if idx then
					local platform = findFirstNamedBasePart(d, "Platform")
					if platform then
						local collector = findFirstNamedBasePart(d, "Collector")
						table.insert(slots, {
							Index = idx,
							Part = platform,
							SlotRoot = d,
							Collector = collector,
						})
					end
				end
			end
		end
	end

	-- 1. 扫描当前在场景里的结构
	scanTree(homeRoot)

	-- 2. 扫描被 Parent=nil 隐藏在缓存里的 2/3 级房屋结构
	local cache = hiddenHousesCache[homeRoot]
	if cache then
		for _, hiddenHouse in pairs(cache) do
			scanTree(hiddenHouse)
		end
	end

	table.sort(slots, function(a, b)
		return a.Index < b.Index
	end)
	return slots
end
local function findSpawnPoint(homeRoot: Instance): BasePart?
	local inst = homeRoot:FindFirstChild("出生点", true)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	return nil
end

local function findUpgradeAreaRoot(homeRoot: Instance): Instance?
	return homeRoot:FindFirstChild("升级区域")
end

local function resolveUpgradeInteractionPart(upgradeRoot: Instance): BasePart?
	if upgradeRoot:IsA("BasePart") then
		return upgradeRoot
	end

	local named = upgradeRoot:FindFirstChild("升级区域", true)
	if named and named:IsA("BasePart") then
		return named
	end

	for _, d in ipairs(upgradeRoot:GetDescendants()) do
		if d:IsA("BasePart") then
			if d:FindFirstChildWhichIsA("ClickDetector") or d:FindFirstChildWhichIsA("SurfaceGui") then
				return d
			end
		end
	end

	return upgradeRoot:FindFirstChildWhichIsA("BasePart", true)
end

local function findHouse(homeRoot: Instance, level: number): Instance?
	return homeRoot:FindFirstChild(string.format("%d级房屋", level))
end

local function setHomeOwner(homeRoot: Instance, ownerUserId: number?)
	if ownerUserId then
		homeRoot:SetAttribute("OwnerUserId", ownerUserId)
		ownerByHome[homeRoot] = ownerUserId
	else
		homeRoot:SetAttribute("OwnerUserId", nil)
		ownerByHome[homeRoot] = nil
	end
end

local function formatUpgradeCostText(cost: number?): string
	if cost == nil then
		return "已满级"
	end
	-- 你要求 UI 用 1w/5w
	if cost == 200000 then
		return "20w"
	elseif cost == 1000000 then
		return "100w"
	end
	return tostring(cost)
end

local function getNextHomeUpgradeCost(homeLevel: number): number?
	if homeLevel <= 1 then
		return 200000
	elseif homeLevel == 2 then
		return 1000000
	end
	return nil
end

local function updateUpgradeGui(upgradeArea: Instance, homeLevel: number)
	local priceValue = upgradeArea:FindFirstChild("03价格数值", true)
	if priceValue and priceValue:IsA("TextLabel") then
		priceValue.Text = formatUpgradeCostText(getNextHomeUpgradeCost(homeLevel))
	end

	local levelLabel = upgradeArea:FindFirstChild("05等级", true)
	if levelLabel and levelLabel:IsA("TextLabel") then
		levelLabel.Text = tostring(homeLevel)
	end
end

local function applyHomeLevelToHome(homeRoot: Instance, homeLevel: number)
	local cache = hiddenHousesCache[homeRoot]
	if not cache then
		cache = {}
		hiddenHousesCache[homeRoot] = cache
	end

	for lvl = 1, 3 do
		if lvl <= homeLevel then
			local house = findHouse(homeRoot, lvl) or cache[lvl]
			if house and house.Parent ~= homeRoot then
				house.Parent = homeRoot
			end
			cache[lvl] = nil
		else
			local house = findHouse(homeRoot, lvl)
			if house then
				cache[lvl] = house
				house.Parent = nil
			end
		end
	end
end

local function teleportToSpawn(player: Player, spawnPoint: BasePart)
	local function doTeleport(character: Model)
		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			return
		end
		-- 抬高一点避免卡在地里
		hrp.CFrame = spawnPoint.CFrame + Vector3.new(0, 3.5, 0)
	end

	local character = player.Character
	if character then
		doTeleport(character)
	end

	-- 保险：重生也送回自己地块
	player.CharacterAdded:Connect(function(char)
		-- 避免刚生成时 HumanoidRootPart 还没出现
		local deadline = os.clock() + 5
		while os.clock() < deadline do
			local hrp = char:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				break
			end
			task.wait(0.05)
		end
		doTeleport(char)
	end)
end

local refreshUpgradePromptEnabled: (Instance, Instance, BasePart) -> ()

local function ensureUpgradePrompt(homeRoot: Instance, upgradeArea: Instance, upgradePart: BasePart)
	-- [修改内容] 加上 true 允许在 Attachment 等子级中递归查找 prompt
	local prompt = upgradePart:FindFirstChild("HomeUpgradePrompt", true) 
	if not (prompt and prompt:IsA("ProximityPrompt")) then
		
		-- [修改内容] 创建一个 Attachment 作为高度的锚点
		local attachment = upgradePart:FindFirstChild("PromptAttachment")
		if not attachment then
			attachment = Instance.new("Attachment")
			attachment.Name = "PromptAttachment"
			-- [修改内容] 调整这个 Vector3.new(0, 3, 0) 中的 3！数字越大，提示框位置越高。
			attachment.Position = Vector3.new(0, 3, 0) 
			attachment.Parent = upgradePart
		end

		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "HomeUpgradePrompt"
		prompt.ActionText = "升级家园"
		prompt.ObjectText = "家园"
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.HoldDuration = 0.5
		prompt.RequiresLineOfSight = false
		-- [修改内容] 将 prompt 的父级设为我们刚刚创建的 attachment，从而继承它的高度偏移
		prompt.Parent = attachment


		prompt.Triggered:Connect(function(triggerPlayer: Player)
			local owner = homeRoot:GetAttribute("OwnerUserId")
			if type(owner) ~= "number" or owner ~= triggerPlayer.UserId then
				return
			end

			local curLevel = PlayerData.GetHomeLevel(triggerPlayer)
			local cost = getNextHomeUpgradeCost(curLevel)
			if cost == nil then
				toast(triggerPlayer, "家园已满级")
				updateUpgradeGui(upgradeArea, curLevel)
				return
			end
			--【【
			if not PlayerData.TrySpendGold(triggerPlayer, cost) then
				toast(triggerPlayer, string.format("金币不足，需要 %s", formatUpgradeCostText(cost)))
				return
			end

			-- [修改原因] 经济埋点：上报家园升级造成的金币消耗
			local AnalyticsService = game:GetService("AnalyticsService")
			AnalyticsService:LogEconomyEvent(
				triggerPlayer,
				Enum.AnalyticsEconomyAction.Spend,
				"Gold",
				cost,
				PlayerData.Get(triggerPlayer).Gold,
				Enum.AnalyticsEconomyTransactionType.Gameplay,
				"Home_Upgrade"
			)

			local newLevel = math.min(3, curLevel + 1)
			PlayerData.SetHomeLevel(triggerPlayer, newLevel)
			applyHomeLevelToHome(homeRoot, newLevel)
			updateUpgradeGui(upgradeArea, newLevel)
			refreshUpgradePromptEnabled(homeRoot, upgradeArea, upgradePart)

			DataDirtyService.MarkDirty(triggerPlayer, 5)

			toast(triggerPlayer, string.format("升级成功：家园等级 %d", newLevel))
		end)
	end

	return prompt :: ProximityPrompt
end

refreshUpgradePromptEnabled = function(homeRoot: Instance, upgradeArea: Instance, upgradePart: BasePart)
	local oldDetector = upgradePart:FindFirstChild("HomeUpgradeClickDetector")
	if oldDetector and oldDetector:IsA("ClickDetector") then
		oldDetector:Destroy()
	end

	local owner = homeRoot:GetAttribute("OwnerUserId")
	local hasOwner = (type(owner) == "number")

	local existing = upgradePart:FindFirstChild("HomeUpgradePrompt")
	if not hasOwner then
		if existing and existing:IsA("ProximityPrompt") then
			existing:Destroy()
		end
		return
	end

	local prompt = ensureUpgradePrompt(homeRoot, upgradeArea, upgradePart)
	local ownerPlayer = Players:GetPlayerByUserId(owner :: number)
	if not ownerPlayer then
		prompt.Enabled = false
		return
	end

	local homeLevel = PlayerData.GetHomeLevel(ownerPlayer)
	prompt.Enabled = getNextHomeUpgradeCost(homeLevel) ~= nil
	updateUpgradeGui(upgradeArea, homeLevel)
end

local function assignHomeToPlayer(player: Player)
	if homesByUserId[player.UserId] then
		return
	end

	local allHomes = scanAllHomes()
	if #allHomes == 0 then
		warn("[HomeService] Workspace.HOME is empty")
		return
	end

	local free: {Instance} = {}
	for _, h in ipairs(allHomes) do
		if ownerByHome[h] == nil then
			table.insert(free, h)
		end
	end

	if #free == 0 then
		warn("[HomeService] No free HOME plots for player", player)
		return
	end

	local picked = free[math.random(1, #free)]

	local upgradeArea = findUpgradeAreaRoot(picked)
	local upgradePart = upgradeArea and resolveUpgradeInteractionPart(upgradeArea) or nil
	local spawnPoint = findSpawnPoint(picked)
	if not upgradeArea or not upgradePart or not spawnPoint then
		warn("[HomeService] HOME missing 升级区域/出生点:", picked:GetFullName())
		return
	end

	setHomeOwner(picked, player.UserId)

	local slots = collectSlots(picked)
	if #slots < 30 then
		warn("[HomeService] HOME slots < 30:", picked:GetFullName(), #slots)
	end

	-- 标记归属 & SlotIndex（PlacementService 依赖）
	for _, s in ipairs(slots) do
		s.Part:SetAttribute("OwnerUserId", player.UserId)
		s.Part:SetAttribute("SlotIndex", s.Index)
	end

	homesByUserId[player.UserId] = {
		HomeRoot = picked,
		Slots = slots,
		UpgradeArea = upgradeArea,
		UpgradePart = upgradePart,
		SpawnPoint = spawnPoint,
	}

	local homeLevel = PlayerData.GetHomeLevel(player)
	applyHomeLevelToHome(picked, homeLevel)
	updateUpgradeGui(upgradeArea, homeLevel)
	refreshUpgradePromptEnabled(picked, upgradeArea, upgradePart)

	teleportToSpawn(player, spawnPoint)
end

local function releaseHomeForPlayer(player: Player)
	local ph = homesByUserId[player.UserId]
	if not ph then
		return
	end

	setHomeOwner(ph.HomeRoot, nil)

	-- 清掉 slot 上的 Owner 标记（避免下一个玩家误判）
	for _, s in ipairs(ph.Slots) do
		if s.Part and s.Part.Parent then
			-- 清解锁 prompt（避免 Prompt 闭包绑定到旧玩家，导致新玩家无法解锁）
			local unlockPrompt = s.Part:FindFirstChild("UnlockPrompt")
			if unlockPrompt and unlockPrompt:IsA("ProximityPrompt") then
				unlockPrompt:Destroy()
			end

			s.Part:SetAttribute("OwnerUserId", nil)
			s.Part:SetAttribute("SlotIndex", nil)
			if s.Collector then
				s.Collector:SetAttribute("OwnerUserId", nil)
				s.Collector:SetAttribute("SlotIndex", nil)
			end
		end
	end

	-- 清掉已放置怪（避免遗留到下一个玩家）
	-- 以及清掉“怪物收益显示”克隆件
	for _, d in ipairs(ph.HomeRoot:GetDescendants()) do
		if d:IsA("BasePart") then
			if d:GetAttribute("IsPlacedMonster") == true then
				local owner = d:GetAttribute("OwnerUserId")
				if type(owner) == "number" and owner == player.UserId then
					d:Destroy()
				end
			elseif d:GetAttribute("IsMonsterIncomeDisplay") == true then
				local owner = d:GetAttribute("OwnerUserId")
				if type(owner) == "number" and owner == player.UserId then
					d:Destroy()
				end
			end
		end
	end

	-- 未被占用的 HOME：默认只显示 1级房屋，隐藏 2/3 级房屋
	applyHomeLevelToHome(ph.HomeRoot, 1)
	updateUpgradeGui(ph.UpgradeArea, 1)
	refreshUpgradePromptEnabled(ph.HomeRoot, ph.UpgradeArea, ph.UpgradePart)

	homesByUserId[player.UserId] = nil
end

function HomeService.GetHome(player: Player): PlayerHome?
	return homesByUserId[player.UserId]
end

function HomeService.GetSlotPart(player: Player, slotIndex: number): BasePart?
	local home = homesByUserId[player.UserId]
	if not home then
		return nil
	end
	for _, slot in ipairs(home.Slots) do
		if slot.Index == slotIndex then
			return slot.Part
		end
	end
	return nil
end

function HomeService.GetSlot(player: Player, slotIndex: number): PlacementSlot?
	local home = homesByUserId[player.UserId]
	if not home then
		return nil
	end
	for _, slot in ipairs(home.Slots) do
		if slot.Index == slotIndex then
			return slot
		end
	end
	return nil
end

function HomeService.GetAllSlots(player: Player): {PlacementSlot}
	local home = homesByUserId[player.UserId]
	if not home then
		return {}
	end
	return home.Slots
end

local function waitForDataLoaded(player: Player)
	-- DataPersistenceService will set this attribute after profile is loaded.
	while player.Parent do
		if player:GetAttribute("__DataLoaded") == true then
			return
		end
		task.wait(0.05)
	end
end

local function hookPlayer(player: Player)
	task.spawn(function()
		waitForDataLoaded(player)
		assignHomeToPlayer(player)
	end)
end

function HomeService.Init()
	math.randomseed(os.clock() * 1e6)

	-- 启动时清理占用状态（避免上一次运行残留 Attribute）
	for _, home in ipairs(scanAllHomes()) do
		setHomeOwner(home, nil)
		for _, slot in ipairs(collectSlots(home)) do
			slot.Part:SetAttribute("OwnerUserId", nil)
			slot.Part:SetAttribute("SlotIndex", nil)
			local unlockPrompt = slot.Part:FindFirstChild("UnlockPrompt")
			if unlockPrompt and unlockPrompt:IsA("ProximityPrompt") then
				unlockPrompt:Destroy()
			end
			if slot.Collector then
				slot.Collector:SetAttribute("OwnerUserId", nil)
				slot.Collector:SetAttribute("SlotIndex", nil)
			end
		end

		-- 其他的 HOME 没被占用时：默认只显示 1级房屋，不显示 2/3级房屋
		applyHomeLevelToHome(home, 1)
		local upgradeArea = findUpgradeAreaRoot(home)
		local upgradePart = upgradeArea and resolveUpgradeInteractionPart(upgradeArea) or nil
		if upgradeArea and upgradePart then
			updateUpgradeGui(upgradeArea, 1)
			refreshUpgradePromptEnabled(home, upgradeArea, upgradePart)
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end

	Players.PlayerAdded:Connect(function(player)
		hookPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		releaseHomeForPlayer(player)
	end)
end

return HomeService
