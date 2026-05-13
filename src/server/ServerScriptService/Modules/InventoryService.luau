--!strict
-- ServerScriptService.Modules.InventoryService
-- 负责：玩家“怪物背包”（10格）存储。
-- 重要规则（按你的需求）：
-- 1) 在刷怪区域拾取怪：怪先显示在玩家头顶（携带态），不进入背包 UI。
-- 2) 玩家碰到带有 "gorund" 标签的 Part 后：携带态的怪收起并转成 Tool（进入底部工具栏），并自动手持其中一只。
-- 3) 只有“放置后的怪被收起”时：怪进入背包 UI（MonsterInventoryWindow 列表），不出现在 Tool 栏。
-- 4) 玩家在背包 UI 点击“拿出按钮”：把该怪从背包 UI 拿出为 Tool，出现在底部 Tool 栏。


local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))

local InventoryService = {}

export type MonsterItem = {
	ItemId: string,
	MonsterLevel: number,
	Value: number,
	GoldPerSec: number,
	UpgradeLevel: number?,
	BaseValue: number?,
	BaseGoldPerSec: number?,
	SourceZoneLevel: number?,
	ExpireUnix: number?,
	StorageKind: string?,
}

type CarriedMonster = {
	MonsterLevel: number,
	Value: number,
	GoldPerSec: number,
	UpgradeLevel: number,
	SourceZoneLevel: number,
	ExpireUnix: number,
}



local MAX_SLOTS = math.huge -- 不再限制怪物背包容量；仅保留常量占位，避免其他旧代码报错

local itemsByUserId: {[number]: {MonsterItem}} = {}
local groundTouchCooldownByUserId: {[number]: number} = {}
local toolCacheFolder: Folder? = nil

-- 玩家“携带中”的怪（在刷怪区拾取后显示在头顶，直到碰到 gorund 标签区域后转换成 Tool）
local carriedByUserId: {[number]: {CarriedMonster}} = {}
local carriedHolderByUserId: {[number]: Folder?} = {}

local function normalizeMonsterItem(raw: any): MonsterItem
	local monsterLevel = math.max(1, math.floor(tonumber(raw.MonsterLevel) or 1))
	local value = math.floor(tonumber(raw.Value) or 0)
	local goldPerSec = math.floor(tonumber(raw.GoldPerSec) or 0)
	local upgradeLevel = math.max(1, math.floor(tonumber(raw.UpgradeLevel) or 1))
	local baseValue = math.floor(tonumber(raw.BaseValue) or math.floor(value / math.max(upgradeLevel, 1)))
	local baseGoldPerSec = math.floor(tonumber(raw.BaseGoldPerSec) or math.floor(goldPerSec / math.max(upgradeLevel, 1)))
	local sourceZoneLevel = math.max(1, math.floor(tonumber(raw.SourceZoneLevel) or 1))
	local expireUnix = math.floor(tonumber(raw.ExpireUnix) or 0)
	local storageKind = tostring(raw.StorageKind or "Inventory")

	return {
		ItemId = tostring(raw.ItemId or ""),
		MonsterLevel = monsterLevel,
		Value = value,
		GoldPerSec = goldPerSec,
		UpgradeLevel = upgradeLevel,
		BaseValue = baseValue,
		BaseGoldPerSec = baseGoldPerSec,
		SourceZoneLevel = sourceZoneLevel,
		ExpireUnix = expireUnix,
		StorageKind = storageKind,
	}
end

local function getRemotes(): Folder?
	local f = ReplicatedStorage:FindFirstChild("Remotes")
	if f and f:IsA("Folder") then
		return f
	end
	return nil
end

local function pushToast(player: Player, text: string)
	local remotes = getRemotes()
	local toast = remotes and remotes:FindFirstChild("PushClientToast")
	if toast and toast:IsA("RemoteEvent") then
		toast:FireClient(player, text)
	end
end

local function syncToClient(player: Player)
	local remotes = getRemotes()
	local ev = remotes and remotes:FindFirstChild("SyncMonsterInventory")
	if not (ev and ev:IsA("RemoteEvent")) then
		return
	end

	local list = itemsByUserId[player.UserId] or {}
	local payload: {any} = {}
	for _, it in ipairs(list) do
		table.insert(payload, {
			ItemId = tostring(it.ItemId),
			MonsterLevel = math.max(1, math.floor(tonumber(it.MonsterLevel) or 1)),
			Value = math.floor(tonumber(it.Value) or 0),
			GoldPerSec = math.floor(tonumber(it.GoldPerSec) or 0),
		})
	end
	ev:FireClient(player, payload)
end

local function newItemId(): string
	return string.format("%d_%d", os.time(), math.random(1000, 9999))
end

local function sanitizeModel(model: Instance): BasePart?
	local root = nil
	if model:IsA("Model") then
		root = model.PrimaryPart
			or model:FindFirstChild("HumanoidRootPart", true)
			or model:FindFirstChild("UpperTorso", true)
			or model:FindFirstChild("Torso", true)
			or model:FindFirstChildWhichIsA("BasePart", true)
		if root then
			model.PrimaryPart = root -- 确保 PrimaryPart 存在，供 PivotTo 使用
		end
	elseif model:IsA("BasePart") then
		root = model
	end

	if not root then return nil end

	-- 1. 剥离会让怪物自己乱动的“灵魂”组件
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("Humanoid") or d:IsA("AnimationController") or d:IsA("Animator") or d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end

	-- 2. 核心修复：代码级强力打胶！
	-- 因为 Studio 原型中没有物理焊接，必须在解除锚定前，把所有零件死死焊在 Root 上
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d ~= root then
			local w = Instance.new("Weld")
			w.Name = "ModelWeld"
			w.Part0 = root
			w.Part1 = d
			-- 【终极核心】：直接用矩阵数学算出现有完美距离，写进 C0 锁死！无视任何物理环境。
			w.C0 = root.CFrame:Inverse() * d.CFrame
			w.Parent = d
		end
	end

	-- 3. 剥夺物理干预权并解冻（此时有 WeldConstraint 保护，绝对不会掉落散架）
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
		end
	end

	return root
end

local function getMonsterAppearanceTemplate(monsterLevel: number): Instance?
	local folder = ReplicatedStorage:FindFirstChild("Monster image")
		or ReplicatedStorage:FindFirstChild("MonsterAppearances")
	if not folder or not folder:IsA("Folder") then
		return nil
	end

	local level2 = string.format("%02d", monsterLevel)
	return folder:FindFirstChild("怪物形象" .. level2)
		or folder:FindFirstChild("怪物形象" .. tostring(monsterLevel))
		or folder:FindFirstChild("怪物形象 " .. level2)
		or folder:FindFirstChild("怪物形象 " .. tostring(monsterLevel))
		or folder:FindFirstChild("Lv" .. tostring(monsterLevel))
		or folder:FindFirstChild("怪物形象01")
		or folder:FindFirstChild("怪物形象1")
		or folder:FindFirstChild("怪物形象 01")
		or folder:FindFirstChild("怪物形象 1")
end

local function ensureHandle(tool: Tool): BasePart
	local h = tool:FindFirstChild("Handle")
	if h and h:IsA("BasePart") then
		tool.RequiresHandle = true
		return h
	end

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 1, 1)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	tool.RequiresHandle = true
	return handle
end

local function ensureToolCacheFolder(): Folder
	if toolCacheFolder and toolCacheFolder.Parent then
		return toolCacheFolder
	end

	local existing = ReplicatedStorage:FindFirstChild("MonsterToolCache")
	if existing and existing:IsA("Folder") then
		toolCacheFolder = existing
		return existing
	end

	local f = Instance.new("Folder")
	f.Name = "MonsterToolCache"
	f.Parent = ReplicatedStorage
	toolCacheFolder = f
	return f
end

-- 运行时模板烘焙：把怪物外观模板预处理成可直接使用的 Tool
local function buildToolTemplates()
	-- 读取场景中的怪物外观文件夹
	local sourceFolder = ReplicatedStorage:FindFirstChild("Monster image")
		or ReplicatedStorage:FindFirstChild("MonsterAppearances")
		or workspace:FindFirstChild("Monster image")
	if not sourceFolder then return end

	local cache = ensureToolCacheFolder()
	cache:ClearAllChildren()

	for _, template in ipairs(sourceFolder:GetChildren()) do
		if template:IsA("Model") then
			local tool = Instance.new("Tool")
			tool.Name = template.Name
			tool.RequiresHandle = true
			tool.CanBeDropped = false

			local handle = Instance.new("Part")
			handle.Name = "Handle"
			handle.Size = Vector3.new(1, 1, 1)
			handle.Transparency = 1
			handle.CanCollide = false
			handle.Massless = true

			local clone = template:Clone()

			-- 统一第二套对齐方式：Handle 直接以模板 Model 的 Pivot 为准。
			-- 这样 Tool / 放置 / 刷怪三条链路都尽量使用同一套整体对齐基准。
			handle.CFrame = clone:GetPivot()

			handle.Parent = tool

			-- 1. 剔除灵魂组件
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("Humanoid") or d:IsA("AnimationController") or d:IsA("Animator") or d:IsA("Script") or d:IsA("LocalScript") then
					d:Destroy()
				end
			end

			-- 2. 穿透嵌套打组，纯数学焊接所有 BasePart
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then
					local w = Instance.new("Weld")
					w.Name = "ToolWeld"
					w.Part0 = handle
					w.Part1 = d
					-- 瞬间锁死完美相对坐标
					w.C0 = handle.CFrame:Inverse() * d.CFrame
					w.Parent = handle

					-- 剥离物理属性
					d.Anchored = false
					d.CanCollide = false
					d.CanTouch = false
					d.CanQuery = false
					d.Massless = true
				end
			end

			clone.Parent = tool
			tool.Parent = cache
		end
	end
end

local function getBakedToolTemplate(monsterLevel: number): Tool?
	local appearance = getMonsterAppearanceTemplate(monsterLevel)
	if not appearance then
		return nil
	end

	local cache = ensureToolCacheFolder()
	if #cache:GetChildren() == 0 then
		buildToolTemplates()
	end

	local baked = cache:FindFirstChild(appearance.Name)
	if baked and baked:IsA("Tool") then
		return baked
	end
	return nil
end

local function applyMonsterAppearanceToTool(tool: Tool, monsterLevel: number)
	local template = getMonsterAppearanceTemplate(monsterLevel)
	local old = tool:FindFirstChild("Appearance")
	if old then old:Destroy() end

	local handle = ensureHandle(tool)
	if not template then
		handle.Transparency = 0
		return
	end

	local appearanceFolder = Instance.new("Folder")
	appearanceFolder.Name = "Appearance"
	appearanceFolder.Parent = tool

	local clone = template:Clone()

	-- 【核心修复】：必须在 Anchored 状态下（解冻前）先整体平移！
	-- 此时子零件完全依赖相对坐标，绝对不会发生偏移
	if clone:IsA("Model") then
		clone.PrimaryPart = clone.PrimaryPart
			or (clone:FindFirstChild("HumanoidRootPart", true) :: BasePart?)
			or (clone:FindFirstChild("UpperTorso", true) :: BasePart?)
			or (clone:FindFirstChild("Torso", true) :: BasePart?)
			or clone:FindFirstChildWhichIsA("BasePart", true)
		clone:PivotTo(handle.CFrame)
	elseif clone:IsA("BasePart") then
		clone.CFrame = handle.CFrame
	end

	clone.Parent = appearanceFolder

	-- 平移完成后，再调用清洗逻辑（此时会在正确的坐标位置原地打胶并解冻）
	local cloneRoot = sanitizeModel(clone)

	if cloneRoot then
		-- 只需要把主根基固定在 Tool Handle 上
		local w = Instance.new("Weld")
		w.Name = "HandleWeld"
		w.Part0 = handle
		w.Part1 = cloneRoot
		w.C0 = handle.CFrame:Inverse() * cloneRoot.CFrame
		w.Parent = cloneRoot
		handle.Transparency = 1
	else
		handle.Transparency = 0
	end
end

local function createMonsterToolFromData(monsterLevel: number, value: number, goldPerSec: number, itemId: string): Tool
	local baked = getBakedToolTemplate(monsterLevel)
	local tool = if baked then baked:Clone() else Instance.new("Tool")
	tool.Name = string.format("Monster Lv.%d", monsterLevel)
	tool.CanBeDropped = false
	tool.ToolTip = string.format("Value:%d  +%d/s", value, goldPerSec)

	ensureHandle(tool)

	tool:SetAttribute("IsMonsterItem", true)
	tool:SetAttribute("ItemId", itemId)
	tool:SetAttribute("MonsterLevel", monsterLevel)
	tool:SetAttribute("Value", value)
	tool:SetAttribute("GoldPerSec", goldPerSec)

	if not baked then
		applyMonsterAppearanceToTool(tool, monsterLevel)
	end
	return tool
end

local function applyMonsterDataToTool(tool: Tool, item: MonsterItem)
	local normalized = normalizeMonsterItem(item)
	tool:SetAttribute("IsMonsterItem", true)
	tool:SetAttribute("MonsterLevel", normalized.MonsterLevel)
	tool:SetAttribute("Value", normalized.Value)
	tool:SetAttribute("GoldPerSec", normalized.GoldPerSec)
	tool:SetAttribute("UpgradeLevel", normalized.UpgradeLevel or 1)
	tool:SetAttribute("BaseValue", normalized.BaseValue or normalized.Value)
	tool:SetAttribute("BaseGoldPerSec", normalized.BaseGoldPerSec or normalized.GoldPerSec)
	tool:SetAttribute("SourceZoneLevel", normalized.SourceZoneLevel or 1)
	tool:SetAttribute("FromGacha", true)
end

local function collectMonsterToolsFromContainer(container: Instance?, out: {MonsterItem}, seenTools: {[Tool]: boolean})
	if not container then
		return
	end

	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") and child:GetAttribute("IsMonsterItem") == true then
			local tool = child :: Tool
			if seenTools[tool] then
				continue
			end
			seenTools[tool] = true
			local item = normalizeMonsterItem({
				ItemId = newItemId(),
				MonsterLevel = tool:GetAttribute("MonsterLevel"),
				Value = tool:GetAttribute("Value"),
				GoldPerSec = tool:GetAttribute("GoldPerSec"),
				UpgradeLevel = tool:GetAttribute("UpgradeLevel"),
				BaseValue = tool:GetAttribute("BaseValue"),
				BaseGoldPerSec = tool:GetAttribute("BaseGoldPerSec"),
				SourceZoneLevel = tool:GetAttribute("SourceZoneLevel"),
				StorageKind = "Tool",
			})
			table.insert(out, item)
		end
	end
end

local function clearCarried(player: Player)
	local holder = carriedHolderByUserId[player.UserId]
	if holder and holder.Parent then
		holder:Destroy()
	end
	carriedHolderByUserId[player.UserId] = nil
	carriedByUserId[player.UserId] = {}
end

local function ensureCarriedList(player: Player): {CarriedMonster}
	local list = carriedByUserId[player.UserId]
	if not list then
		list = {}
		carriedByUserId[player.UserId] = list
	end
	return list
end

local function toModelLike(inst: Instance): (Model?, BasePart?)
	if inst:IsA("Model") then
		return inst, nil
	end
	if inst:IsA("BasePart") then
		return nil, inst
	end
	if inst:IsA("Folder") then
		local m = Instance.new("Model")
		m.Name = inst.Name
		m.Parent = inst.Parent
		for _, ch in ipairs(inst:GetChildren()) do
			ch.Parent = m
		end
		inst:Destroy()
		return m, nil
	end
	return nil, nil
end

local function getWidthX(inst: Instance): number
	if inst:IsA("BasePart") then
		return inst.Size.X
	end
	if inst:IsA("Model") then
		local _, size = inst:GetBoundingBox()
		return size.X
	end
	return 2
end

local function rebuildCarriedVisual(player: Player)
	local list = ensureCarriedList(player)

	local character = player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- clear old
	local old = carriedHolderByUserId[player.UserId]
	if old and old.Parent then
		old:Destroy()
	end

	if #list == 0 then
		carriedHolderByUserId[player.UserId] = nil
		return
	end

	local holder = Instance.new("Folder")
	holder.Name = "CarriedMonsters"
	holder:SetAttribute("IsCarriedMonster", true)
	holder.Parent = character
	carriedHolderByUserId[player.UserId] = holder

	-- Build instances first (so we can compute widths)
	local built: {Instance} = {}
	local widths: {number} = {}
	for _, c in ipairs(list) do
		local template = getMonsterAppearanceTemplate(c.MonsterLevel)
		local inst: Instance
		if template then
			inst = template:Clone()
		else
			local p = Instance.new("Part")
			p.Size = Vector3.new(2, 2, 2)
			p.Anchored = false
			p.CanCollide = false
			p.Material = Enum.Material.Neon
			p.Color = Color3.fromRGB(120, 0, 255)
			inst = p
		end
		inst.Parent = holder

		local model, part = toModelLike(inst)
		if model then
			inst = model
		elseif part then
			inst = part
		end

		inst:SetAttribute("SourceZoneLevel", (c :: any).SourceZoneLevel or 1)

		table.insert(built, inst)
		table.insert(widths, math.max(1, getWidthX(inst)))

	end

	-- Centered arrangement on player's local X axis
	local gap = 0.75
	local total = 0
	for i, w in ipairs(widths) do
		total += w
		if i < #widths then
			total += gap
		end
	end

	local x = -total * 0.5
	for i, inst in ipairs(built) do
		local w = widths[i]
		x += w * 0.5
		local targetCF = hrp.CFrame * CFrame.new(x, 5, 0)

		-- 调用新版清洗逻辑
		local cloneRoot = sanitizeModel(inst)
		if cloneRoot then
			if inst:IsA("Model") then
				inst:PivotTo(targetCF)
			else
				cloneRoot.CFrame = targetCF
			end

			-- 只需要把主根基固定在头顶 hrp 上
			local wld = Instance.new("Weld")
			wld.Name = "HeadWeld"
			wld.Part0 = hrp
			wld.Part1 = cloneRoot
			wld.C0 = hrp.CFrame:Inverse() * cloneRoot.CFrame
			wld.Parent = cloneRoot
		end

		x += w * 0.5 + gap
	end
end

-- =====================
-- Public API
-- =====================

local function convertCarriedToTools(player: Player, autoEquipOne: boolean): number
	local carried = ensureCarriedList(player)
	if #carried == 0 then
		return 0
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		backpack = player:WaitForChild("Backpack", 3) :: any
	end
	if not backpack or not backpack:IsA("Backpack") then
		return 0
	end

	local moved = #carried
	local firstTool: Tool? = nil
	
	-- 【修复】这里只用一个统一的循环，并挂上所有强化属性
	for _, c in ipairs(carried) do
		local tool = createMonsterToolFromData(
			c.MonsterLevel,
			c.Value,
			c.GoldPerSec,
			"" -- IMPORTANT: 从携带态来的 Tool 不属于背包列表
		)
		
		applyMonsterDataToTool(tool, {
			ItemId = "",
			MonsterLevel = c.MonsterLevel,
			Value = c.Value,
			GoldPerSec = c.GoldPerSec,
			UpgradeLevel = (c :: any).UpgradeLevel or 1,
			BaseValue = math.floor(c.Value / math.max((c :: any).UpgradeLevel or 1, 1)),
			BaseGoldPerSec = math.floor(c.GoldPerSec / math.max((c :: any).UpgradeLevel or 1, 1)),
			SourceZoneLevel = (c :: any).SourceZoneLevel or 1,
			StorageKind = "Tool",
		})
		tool.Parent = backpack
		if not firstTool then firstTool = tool end
	end

	clearCarried(player)

	if autoEquipOne and firstTool then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			-- defer 一帧，确保 Tool 已稳定进入 Backpack
			task.defer(function()
				if firstTool and firstTool.Parent == backpack then
					humanoid:EquipTool(firstTool)
				end
			end)
		end
	end

	pushToast(player, string.format("Collected and moved to toolbar: %d", moved))
	return moved
end

function InventoryService.ConvertCarriedToInventory(player: Player)
	-- 兼容旧接口名：当前改为直接转 Tool（底部工具栏）并自动手持一只
	convertCarriedToTools(player, true)
end

function InventoryService.Init()
	buildToolTemplates()

	local function bindGroundTouch(player: Player, character: Model)
		local hrp = character:FindFirstChild("HumanoidRootPart") or character:WaitForChild("HumanoidRootPart", 5)
		if not (hrp and hrp:IsA("BasePart")) then
			return
		end

		hrp.Touched:Connect(function(hit)
			if not hit:IsA("BasePart") then
				return
			end
			if not CollectionService:HasTag(hit, "gorund") then
				return
			end

			local now = os.clock()
			local last = groundTouchCooldownByUserId[player.UserId] or 0
			if now - last < 0.8 then
				return
			end
			groundTouchCooldownByUserId[player.UserId] = now

			convertCarriedToTools(player, true)
		end)
	end

	local function hookPlayer(player: Player)
		if itemsByUserId[player.UserId] == nil then
			itemsByUserId[player.UserId] = {}
		end

		player.CharacterAdded:Connect(function()
			-- 重生后：刷新背包 UI；如果还在携带态，重新挂一次
			task.delay(0.2, function()
				syncToClient(player)
				rebuildCarriedVisual(player)
			end)

			local character = player.Character
			if character then
				bindGroundTouch(player, character)
			end
		end)

		-- 初次进来
		task.defer(function()
			syncToClient(player)
		end)
	end

	Players.PlayerAdded:Connect(hookPlayer)
	Players.PlayerRemoving:Connect(function(_player)
		-- IMPORTANT: 不在这里清理，等待 DataPersistenceService 释放后再 Cleanup
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		hookPlayer(player)
	end
end

function InventoryService.GetItems(player: Player): {MonsterItem}
	return itemsByUserId[player.UserId] or {}
end

function InventoryService.TryAddMonsterItem(player: Player, monsterLevel: number, value: number, goldPerSec: number, upgradeLevel: number?, baseValue: number?, baseGoldPerSec: number?, sourceZoneLevel: number?): boolean
	local list = itemsByUserId[player.UserId]
	if not list then
		list = {}
		itemsByUserId[player.UserId] = list
	end

	local item: MonsterItem = normalizeMonsterItem({
		ItemId = newItemId(),
		MonsterLevel = monsterLevel,
		Value = value,
		GoldPerSec = goldPerSec,
		UpgradeLevel = upgradeLevel,
		BaseValue = baseValue,
		BaseGoldPerSec = baseGoldPerSec,
		SourceZoneLevel = sourceZoneLevel,
		StorageKind = "Inventory",
	})
	table.insert(list, item)

	DataDirtyService.MarkDirty(player)
	syncToClient(player)

	pushToast(player, string.format("Collected: Monster Lv.%d", monsterLevel))
	return true
end


-- 刷怪区域拾取：进入携带态（头顶显示），不进入背包 UI
function InventoryService.PickupCarryMonster(player: Player, level: number, value: number, gps: number, upgradeLevel: number, sourceZoneLevel: number, expireUnix: number?)
	local stats = PlayerData.Get(player)
	local maxCarry = Config.GetCarryMax(stats.CarryLevel)

	local list = ensureCarriedList(player)
	if #list >= maxCarry then
		pushToast(player, string.format("Carry full (%d/%d)", #list, maxCarry))
		return false
	end

	local safeExpireUnix = math.floor(tonumber(expireUnix) or 0)
	if safeExpireUnix <= 0 then
		safeExpireUnix = os.time() + Config.MONSTER_LIFETIME_SECONDS
	end

	table.insert(list, {
		MonsterLevel = level,
		Value = value,
		GoldPerSec = gps,
		UpgradeLevel = upgradeLevel or 1,
		SourceZoneLevel = math.max(1, math.floor(tonumber(sourceZoneLevel) or 1)),
		ExpireUnix = safeExpireUnix,
	})

	rebuildCarriedVisual(player)
	pushToast(player, string.format("Picked up: Monster Lv.%d (Carry %d/%d)", level, #list, maxCarry))
	task.defer(function()
		local TutorialService = require(script.Parent:WaitForChild("TutorialService"))
		TutorialService.OnMonsterAcquired(player)
	end)
	return true
end

-- [新增] 玩家被打飞/主动放下时：强制清空携带中的怪物，并返回数据给外部掉落
function InventoryService.DropAllCarried(player: Player, toastText: string?): {CarriedMonster}
	local list = carriedByUserId[player.UserId]
	if not list or #list == 0 then
		return {}
	end

	-- 深拷贝一份数据用于返回
	local dropped = {}
	for _, v in ipairs(list) do
		table.insert(dropped, {
			MonsterLevel = v.MonsterLevel,
			Value = v.Value,
			GoldPerSec = v.GoldPerSec,
			UpgradeLevel = (v :: any).UpgradeLevel or 1,
			SourceZoneLevel = (v :: any).SourceZoneLevel or 1,
			ExpireUnix = (v :: any).ExpireUnix or (os.time() + Config.MONSTER_LIFETIME_SECONDS),
		})

	end

	-- 清空玩家头顶的模型和数据
	clearCarried(player)
	if toastText ~= "" then
		pushToast(player, toastText or "You were knocked back by the Guardian and dropped all carried monsters!")
	end
	
	return dropped
end

-- 兼容旧接口：把携带态转换为 Tool（并自动手持一只）
function InventoryService.ConvertCarriedToTool(player: Player)
	convertCarriedToTools(player, true)
end

-- UI 点击“拿出按钮”：从背包 UI 拿出为 Tool
function InventoryService.TakeOutToTool(player: Player, itemId: string)
	local list = itemsByUserId[player.UserId]
	if not list then
		return
	end

	local idx: number? = nil
	local it: MonsterItem? = nil
	for i, v in ipairs(list) do
		if v.ItemId == itemId then
			idx = i
			it = v
			break
		end
	end
	if not idx or not it then
		return
	end

	table.remove(list, idx)
	DataDirtyService.MarkDirty(player)
	syncToClient(player)

	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		backpack = player:WaitForChild("Backpack", 3) :: any
	end
	if not backpack or not backpack:IsA("Backpack") then
		return
	end

	local tool = createMonsterToolFromData(
		it.MonsterLevel,
		it.Value,
		it.GoldPerSec,
		"" -- IMPORTANT: 拿出后不再属于背包列表
	)
	applyMonsterDataToTool(tool, it)
	tool.Parent = backpack
end

-- 旧接口：放置时如果 Tool 有 ItemId 才会调用；我们现在给出的 Tool ItemId 都是空字符串，通常不会触发
function InventoryService.ConsumeItem(player: Player, itemId: string): boolean
	local list = itemsByUserId[player.UserId]
	if not list then
		return false
	end

	for i, it in ipairs(list) do
		if it.ItemId == itemId then
			table.remove(list, i)
			DataDirtyService.MarkDirty(player)
			syncToClient(player)
			return true
		end
	end
	return false
end

function InventoryService.Export(player: Player): {MonsterItem}
	local list = itemsByUserId[player.UserId] or {}
	local out: {MonsterItem} = {}
	local seenTools: {[Tool]: boolean} = {}
	for _, it in ipairs(list) do
		table.insert(out, normalizeMonsterItem({
			ItemId = tostring(it.ItemId),
			MonsterLevel = it.MonsterLevel,
			Value = it.Value,
			GoldPerSec = it.GoldPerSec,
			UpgradeLevel = (it :: any).UpgradeLevel,
			BaseValue = (it :: any).BaseValue,
			BaseGoldPerSec = (it :: any).BaseGoldPerSec,
			SourceZoneLevel = (it :: any).SourceZoneLevel,
			StorageKind = (it :: any).StorageKind or "Inventory",
		}))
	end

	local carried = carriedByUserId[player.UserId] or {}
	for _, it in ipairs(carried) do
		table.insert(out, normalizeMonsterItem({
			ItemId = newItemId(),
			MonsterLevel = it.MonsterLevel,
			Value = it.Value,
			GoldPerSec = it.GoldPerSec,
			UpgradeLevel = it.UpgradeLevel,
			BaseValue = math.floor(it.Value / math.max(it.UpgradeLevel, 1)),
			BaseGoldPerSec = math.floor(it.GoldPerSec / math.max(it.UpgradeLevel, 1)),
			SourceZoneLevel = it.SourceZoneLevel,
			ExpireUnix = it.ExpireUnix,
			StorageKind = "Carried",
		}))
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	collectMonsterToolsFromContainer(backpack, out, seenTools)
	collectMonsterToolsFromContainer(player.Character, out, seenTools)
	return out
end

function InventoryService.ApplyLoaded(player: Player, loadedItems: {MonsterItem}?)
	local list: {MonsterItem} = {}
	local carriedList: {CarriedMonster} = {}
	local toolItems: {MonsterItem} = {}
	if type(loadedItems) == "table" then
		for _, it in ipairs(loadedItems) do
			if type(it) == "table" then
				local itemId = tostring((it :: any).ItemId or "")
				if itemId ~= "" then
					local item = normalizeMonsterItem(it)
					if item.StorageKind == "Tool" then
						table.insert(toolItems, item)
					elseif item.StorageKind == "Carried" then
						local safeExpireUnix = math.floor(tonumber((it :: any).ExpireUnix) or 0)
						if safeExpireUnix <= 0 then
							safeExpireUnix = os.time() + Config.MONSTER_LIFETIME_SECONDS
						end
						table.insert(carriedList, {
							MonsterLevel = item.MonsterLevel,
							Value = item.Value,
							GoldPerSec = item.GoldPerSec,
							UpgradeLevel = item.UpgradeLevel or 1,
							SourceZoneLevel = item.SourceZoneLevel or 1,
							ExpireUnix = safeExpireUnix,
						})
					else
						table.insert(list, item)
					end
				end
			end
		end
	end

	itemsByUserId[player.UserId] = list
	carriedByUserId[player.UserId] = carriedList
	syncToClient(player)
	rebuildCarriedVisual(player)

	if #toolItems > 0 then
		task.defer(function()
			local backpack = player:FindFirstChildOfClass("Backpack")
			if not backpack then
				backpack = player:WaitForChild("Backpack", 3) :: any
			end
			if not backpack or not backpack:IsA("Backpack") then
				return
			end

			for _, item in ipairs(toolItems) do
				local tool = createMonsterToolFromData(item.MonsterLevel, item.Value, item.GoldPerSec, "")
				applyMonsterDataToTool(tool, item)
				tool.Parent = backpack
			end
		end)
	end

end

function InventoryService.Cleanup(player: Player)
	itemsByUserId[player.UserId] = nil
	clearCarried(player)
end


function InventoryService.Clear(player: Player)
	itemsByUserId[player.UserId] = {}
	clearCarried(player)
	syncToClient(player)
	
	local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))
	DataDirtyService.MarkDirty(player)
end

-- [修改原因] 增加直接发放怪物 Tool 的接口，供抽奖系统调用，并支持自动装备最高级怪物
function InventoryService.GiveGachaMonsterTool(player: Player, monsterLevel: number, autoEquip: boolean)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		backpack = player:WaitForChild("Backpack", 3) :: any
	end
	if not backpack or not backpack:IsA("Backpack") then return end

	-- 安全获取配置表中的数值，防止超出索引
	local value = Config.MONSTER_VALUE_BY_LEVEL[monsterLevel] or (monsterLevel * 10)
	local gps = Config.MONSTER_GOLD_PER_SEC_BY_LEVEL[monsterLevel] or monsterLevel

	-- 统计当前 Tool 数量：角色手上 + Backpack 里都算
	local toolCount = 0
	for _, child in ipairs(backpack:GetChildren()) do
		if child:IsA("Tool") then
			toolCount += 1
		end
	end

	local character = player.Character
	if character then
		for _, child in ipairs(character:GetChildren()) do
			if child:IsA("Tool") then
				toolCount += 1
			end
		end
	end

	-- 这里的 10 表示你下方工具栏/可直接携带区的上限
	-- 超过后，抽奖怪直接进入怪物背包 UI，不再继续塞 Tool
	if toolCount >= 10 then
		local ok = InventoryService.TryAddMonsterItem(player, monsterLevel, value, gps)
		if ok then
			pushToast(player, string.format("Toolbar full, Monster Lv.%d moved to backpack", monsterLevel))
		else
			pushToast(player, string.format("Toolbar and backpack are full, Monster Lv.%d could not be claimed", monsterLevel))
		end
		return
	end

	-- 工具栏未满时，正常发 Tool
	local tool = createMonsterToolFromData(
		monsterLevel,
		value,
		gps,
		"" -- 抽到的怪直接是 Tool，不进入 UI 背包体系
	)

	tool:SetAttribute("UpgradeLevel", 1)
	tool:SetAttribute("BaseValue", value)
	tool:SetAttribute("BaseGoldPerSec", gps)
	tool:SetAttribute("FromGacha", true)


	tool.Parent = backpack

	if autoEquip then
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			task.defer(function()
				if tool and tool.Parent == backpack then
					humanoid:EquipTool(tool)
				end
			end)
		end
	end
end



return InventoryService
