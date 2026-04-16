--!strict
-- ServerScriptService.Modules.PlacementService
-- 负责：
-- 1) 玩家站到自己家的“怪放置区域x”时：
--    - 若装备了怪物道具(Tool) => 自动放置
--    - 若已放置怪 => 领取未领取金币
-- 2) 解锁放置区域（按 0 / 50 / 500 / 5000...）
-- 3) 放置后的怪提供“卖出/收起”交互
--
-- 说明：目前使用 ProximityPrompt 作为交互 UI（靠近出现，长按/点击）。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))

local Util = require(script.Parent:WaitForChild("Util"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local HomeService = require(script.Parent:WaitForChild("HomeService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))



local PlacementService = {}


------------------------
-- 金币单位换算函数
local function formatMoney(amount: number): string
	if amount < 10000 then
		return tostring(math.floor(amount))
	else
		-- 保留一位小数，如 15000 变成 1.5w
		return string.format("%.1fw", amount / 10000) 
	end
end



export type PersistedPlacedMonster = {
	MonsterLevel: number,
	Value: number,
	GoldPerSec: number,
	UnclaimedGold: number,
	LastTickUnix: number,
}

export type PersistedSlot = {
	Unlocked: boolean,
	Placed: PersistedPlacedMonster?,
}

type SlotState = {
	Unlocked: boolean,
	PlacedMonster: BasePart?,
	PlacedData: PersistedPlacedMonster?,
}

local slotStatesByUserId: {[number]: {[number]: SlotState}} = {}
local lastTouchAt: {[string]: number} = {}
local placementInitStartedByUserId: {[number]: boolean} = {}

-- While placed monsters are producing, UnclaimedGold changes every second.
-- We pulse dirty marks at a low frequency so periodic saves can happen even if the player doesn't do any actions.
local lastDirtyPulseUnixByUserId: {[number]: number} = {}

-- 这个函数用于把实例转换成便于日志输出的完整路径字符串，方便排查交互问题。
local function debugInstancePath(instance: Instance?): string
	if not instance then
		return "nil"
	end

	local ok, fullName = pcall(function()
		return instance:GetFullName()
	end)
	return ok and fullName or instance.Name
end

-- 解锁提示：只在玩家站在对应地块上方时才显示
-- 这个函数用于获取玩家角色上的 HumanoidRootPart，供距离和站位判定复用。
local function getHRP(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- 这个函数用于判断玩家是否真的站在某个放置区域上方，从而控制解锁提示是否显示。
local function isPlayerStandingOnSlot(player: Player, slotPart: BasePart): boolean
	local hrp = getHRP(player)
	if not hrp then
		return false
	end
	local hrpPos = hrp.Position
	local slotPos = slotPart.Position
	local yDelta = hrpPos.Y - slotPos.Y
	if yDelta < 0 or yDelta > 8 then
		return false
	end

	local planarDistance = Vector2.new(hrpPos.X - slotPos.X, hrpPos.Z - slotPos.Z).Magnitude
	local maxPlanarDistance = math.max(slotPart.Size.X, slotPart.Size.Z)
	return planarDistance <= maxPlanarDistance
end

-- =====================
-- 怪物收益显示（BillboardGui / SurfaceGui 模板）
-- =====================

local INCOME_DISPLAY_NAME_PREFIX = "怪物收益显示_"
local PLACED_MONSTER_HEAD_DISPLAY_NAME = "PlacedMonsterHeadBillboard"

local warnedMissingIncomeTemplate = false
type IncomeDisplayGui = BillboardGui | SurfaceGui

local cachedIncomeDisplayTemplate: IncomeDisplayGui? = nil
local cachedPlacedMonsterHeadTemplate: BillboardGui? = nil

-- 这个函数用于从场景里缓存并返回“怪数据显示头顶”的 BillboardGui 模板。
local function getPlacedMonsterHeadTemplate(): BillboardGui?
	if cachedPlacedMonsterHeadTemplate then
		return cachedPlacedMonsterHeadTemplate
	end

	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc.Name == "怪数据显示头顶" then
			local billboard = desc:FindFirstChildWhichIsA("BillboardGui", true)
			if billboard then
				cachedPlacedMonsterHeadTemplate = billboard
				return billboard
			end
		end
	end

	return nil
end

-- 这个函数用于从场景里找到收益显示模板，并缓存起来供所有放置区域复用。
local function getIncomeDisplayTemplate(): IncomeDisplayGui?
	if cachedIncomeDisplayTemplate then
		return cachedIncomeDisplayTemplate
	end

	local displayPart: Instance? = nil
	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc.Name == "收益显示" and (desc:IsA("BasePart") or desc:IsA("Model") or desc:IsA("Folder")) then
			displayPart = desc
			break
		end
	end

	local template: IncomeDisplayGui? = nil
	if displayPart then
		local billboard = displayPart:FindFirstChildWhichIsA("BillboardGui", true)
		if billboard then
			template = billboard
		else
			local surface = displayPart:FindFirstChildWhichIsA("SurfaceGui", true)
			if surface then
				template = surface
			end
		end
	end

	if not template then
		if not warnedMissingIncomeTemplate then
			warnedMissingIncomeTemplate = true
			warn("【致命错误】找不到收益显示模板！请确认：\n1. Workspace 下有一个名叫 '收益显示' 的零件/组。\n2. 该 '收益显示' 内部包含 BillboardGui 或 SurfaceGui。")
		end
		return nil
	end

	cachedIncomeDisplayTemplate = template
	return cachedIncomeDisplayTemplate
end

-- 这个函数用于在一个收益显示 GUI 里找到可写入文本的 TextLabel。
local function findIncomeDisplayTextLabel(gui: IncomeDisplayGui): TextLabel?
	for _, child in ipairs(gui:GetDescendants()) do
		if child:IsA("TextLabel") then
			return child
		end
	end
	return nil
end

-- 这个函数用于把怪物等级、收益和未领取金币等数据写进收益显示 GUI。
local function setIncomeDisplayText(gui: IncomeDisplayGui, monsterLevel: number?, goldPerSec: number?, unclaimed: number?, value: number?)
	local labelByName: {[string]: TextLabel} = {}
	local allLabels = {}
	for _, child in ipairs(gui:GetDescendants()) do
		if child:IsA("TextLabel") then
			labelByName[child.Name] = child
			table.insert(allLabels, child)
		end
	end

	local levelText = monsterLevel == nil and "未放置" or string.format("Lv.%d", monsterLevel)
	local goldPerSecText = string.format("+%d/s", goldPerSec or 0)
	local unclaimedText = tostring(unclaimed or 0)
	local valueText = tostring(value or 0)

	local hasStructuredLabels = false
	local function setIfExists(labelName: string, text: string)
		local label = labelByName[labelName]
		if label then
			label.Text = text
			hasStructuredLabels = true
		end
	end

	setIfExists("01等级", levelText)
	setIfExists("02怪每秒收益", goldPerSecText)
	setIfExists("03当前未领取收益", unclaimedText)
	setIfExists("04怪的价值", valueText)
	setIfExists("05怪价值", valueText)

	-- 新需求：放置后怪物前方的“收益显示”只展示当前未领取收益。
	-- 因此如果模板中存在结构化标签，则只保留 03当前未领取收益，其他字段清空。
	for labelName, label in pairs(labelByName) do
		if labelName ~= "03当前未领取收益" then
			label.Text = ""
		end
	end

	if hasStructuredLabels then
		return
	end

	local textLabel = findIncomeDisplayTextLabel(gui)
	if not textLabel then
		return
	end

	textLabel.Text = unclaimedText
end

-- 这个函数用于确保放置怪头顶一定挂有 BillboardGui，没有就按模板创建一个。
local function ensurePlacedMonsterHeadBillboard(rootPart: BasePart): BillboardGui?
	local existing = rootPart:FindFirstChild(PLACED_MONSTER_HEAD_DISPLAY_NAME)
	if existing and existing:IsA("BillboardGui") then
		--已存在的显示距离
		existing.MaxDistance = 30
		existing.AlwaysOnTop = true
		existing.Enabled = true
		return existing
	end

	local template = getPlacedMonsterHeadTemplate()
	if not template then
		return nil
	end

	local clone = template:Clone()
	clone.Adornee = rootPart
	clone.Name = PLACED_MONSTER_HEAD_DISPLAY_NAME
	-- 新需求：玩家离放置后的怪超过 15 个单位时，头顶数据显示自动隐藏。
	-- 这里直接使用 BillboardGui.MaxDistance，让 Roblox 按 3D 距离自动控制显示。
	--新克隆的 Billboard显示距离
	clone.MaxDistance = 30
	clone.AlwaysOnTop = true
	clone.Enabled = true
	clone.Parent = rootPart
	return clone
end

-- 这个函数用于刷新放置怪头顶显示的等级、价值和每秒收益文本。
local function setPlacedMonsterHeadBillboardText(rootPart: BasePart)
	local billboard = ensurePlacedMonsterHeadBillboard(rootPart)
	if not billboard then
		return
	end

	local level = math.floor(tonumber(rootPart:GetAttribute("MonsterLevel")) or 1)
	local value = math.floor(tonumber(rootPart:GetAttribute("Value")) or 0)
	local goldPerSec = math.floor(tonumber(rootPart:GetAttribute("GoldPerSec")) or 0)

	for _, child in ipairs(billboard:GetDescendants()) do
		if child:IsA("TextLabel") then
			if child.Name == "lv" then
				child.Text = string.format("Lv.%d", level)
			elseif child.Name == "cost" then
				child.Text = tostring(value)
			elseif child.Name == "gold" then
				child.Text = string.format("+%d/s", goldPerSec)
			end
		end
	end
end

-- 这个函数用于统一控制收益显示 GUI 的显隐状态。
local function setIncomeDisplayVisibility(gui: IncomeDisplayGui, visible: boolean)
	gui.Enabled = visible
end

-- 这个函数用于判断某个放置槽当前是否仍在 Workspace 中可见。
local function isSlotCurrentlyVisible(slotPart: BasePart): boolean
	return slotPart:IsDescendantOf(Workspace)
end

-- 这个函数用于确保某个放置槽前方存在收益显示 GUI，没有就克隆模板创建。
local function ensureIncomeDisplayGui(player: Player, slotPart: BasePart, collectorPart: BasePart?): IncomeDisplayGui?
	local anchorPart = collectorPart or slotPart
	if anchorPart.Parent == nil then
		return nil
	end

	local idx = slotPart:GetAttribute("SlotIndex")
	local name = INCOME_DISPLAY_NAME_PREFIX .. tostring(idx or slotPart.Name)
	local existing = anchorPart:FindFirstChild(name)
	if existing and (existing:IsA("BillboardGui") or existing:IsA("SurfaceGui")) then
		local gui = existing :: IncomeDisplayGui
		local owner = gui:GetAttribute("OwnerUserId")
		if type(owner) == "number" and owner ~= player.UserId then
			gui:Destroy()
		elseif findIncomeDisplayTextLabel(gui) then
			gui:SetAttribute("OwnerUserId", player.UserId)
			gui:SetAttribute("SlotIndex", idx)
			return gui
		else
			gui:Destroy()
		end
	end

	local template = getIncomeDisplayTemplate()
	if not template then
		return nil
	end

	local clone = template:Clone()
	clone.Name = name
	clone:SetAttribute("OwnerUserId", player.UserId)
	clone:SetAttribute("SlotIndex", idx)
	if clone:IsA("SurfaceGui") then
		clone.Adornee = anchorPart
		clone.Face = Enum.NormalId.Top
	elseif clone:IsA("BillboardGui") then
		clone.Adornee = anchorPart
	end
	clone.Parent = anchorPart
	setIncomeDisplayText(clone, nil, nil, nil, nil)
	return clone
end


-- 这个函数用于按当前放置怪数据刷新某个槽位对应的实体收益显示内容。
local function refreshIncomeDisplayForSlot(player: Player, slotPart: BasePart, collectorPart: BasePart?, placed: BasePart?)
	if not collectorPart then return end
	
	-- 递归查找真正的收益显示模型
	local displayModel = collectorPart:FindFirstChild("收益显示", true)
	if not displayModel then return end
	
	-- 递归查找所有的核心文字组件，无视层级深度！
	local costLabel = displayModel:FindFirstChild("升级所需金币", true)
	local levelLabel = displayModel:FindFirstChild("当前等级→下一等级", true)
	local unclaimedLabel = displayModel:FindFirstChild("03当前未领取收益", true) or displayModel:FindFirstChild("当前未领取收益", true)

	if not placed or placed.Parent == nil then
		-- 未放置状态
		if costLabel and costLabel:IsA("TextLabel") then costLabel.Text = "未放置" end
		if levelLabel and levelLabel:IsA("TextLabel") then levelLabel.Text = "" end
		if unclaimedLabel and unclaimedLabel:IsA("TextLabel") then unclaimedLabel.Text = "0" end
	else
		-- 已放置状态，计算金币和等级
		local upLevel = placed:GetAttribute("UpgradeLevel") or 1
		local baseGps = placed:GetAttribute("BaseGoldPerSec") or placed:GetAttribute("GoldPerSec") or 0
		local upgradeCost = upLevel * 10 * baseGps
		local unclaimed = math.floor(placed:GetAttribute("UnclaimedGold") or 0)

		-- 安全填入跳动的数据
		if costLabel and costLabel:IsA("TextLabel") then costLabel.Text = formatMoney(upgradeCost) end
		if levelLabel and levelLabel:IsA("TextLabel") then levelLabel.Text = string.format("LV.%d▶LV.%d", upLevel, upLevel + 1) end
		if unclaimedLabel and unclaimedLabel:IsA("TextLabel") then unclaimedLabel.Text = tostring(unclaimed) end
	end
end

-- 这个函数用于向客户端发送一条简短提示文本。
local function toast(player: Player, text: string)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild("PushClientToast")
	if ev and ev:IsA("RemoteEvent") then
		ev:FireClient(player, text)
	end
end

-- 这个函数用于按怪物等级，从 ReplicatedStorage 中找到对应的外观模板。
local function getMonsterAppearanceTemplate(monsterLevel: number): Instance?
	local folder = ReplicatedStorage:FindFirstChild("MonsterAppearances")
	if not folder or not folder:IsA("Folder") then
		return nil
	end

	return folder:FindFirstChild("怪物形象" .. tostring(monsterLevel))
		or folder:FindFirstChild("怪物形象 " .. tostring(monsterLevel))
		or folder:FindFirstChild("Lv" .. tostring(monsterLevel))
end

-- 这个函数用于清理模板里的旧焊接和约束，避免影响新的挂接逻辑。
local function stripJointsAndConstraints(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("Constraint") then
			d:Destroy()
		end
	end
end

-- 这个函数用于把外观模板里的所有 BasePart 调整成适合附加显示的物理状态。
local function prepareAppearanceParts(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true
		end
	end
end

-- 这个函数用于把一个外观容器内的所有零件焊到指定锚点零件上。
local function weldPartsToAnchor(anchorPart: BasePart, root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and d ~= anchorPart then
			local w = Instance.new("Weld")
			w.Part0 = anchorPart
			w.Part1 = d
			w.C0 = anchorPart.CFrame:Inverse() * d.CFrame
			w.Parent = d
		end
	end
end

-- 这个函数用于把外观锚点再焊接到最终的放置根 Part 上。
local function weldAnchorToRoot(rootPart: BasePart, anchorPart: BasePart)
	anchorPart.Anchored = false
	anchorPart.CanCollide = false
	anchorPart.CanTouch = false
	anchorPart.CanQuery = false
	anchorPart.Massless = true

	local w = Instance.new("Weld")
	w.Part0 = rootPart
	w.Part1 = anchorPart
	w.C0 = rootPart.CFrame:Inverse() * anchorPart.CFrame
	w.Parent = anchorPart
end

--清理放置位置
-- 这个函数用于为放置外观选择一个可靠的根 Part，并在需要时设置为 PrimaryPart。
local function sanitizePlacementRoot(inst: Instance): BasePart?
	if inst:IsA("Model") then
		local root = inst.PrimaryPart
			or (inst:FindFirstChild("HumanoidRootPart", true) :: BasePart?)
			or (inst:FindFirstChild("UpperTorso", true) :: BasePart?)
			or (inst:FindFirstChild("Torso", true) :: BasePart?)
			or inst:FindFirstChildWhichIsA("BasePart", true)
		if root then
			inst.PrimaryPart = root
		end
		return root
	elseif inst:IsA("BasePart") then
		return inst
	end

	return nil
end

-- 这个函数用于优先查找“与 Model 同名的 Part”，作为放置模板的逻辑根。
local function findPlacementTemplateRootPart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	end

	if inst:IsA("Model") then
		local sameName = inst:FindFirstChild(inst.Name)
		if sameName and sameName:IsA("BasePart") then
			return sameName
		end

		local deepSameName = inst:FindFirstChild(inst.Name, true)
		if deepSameName and deepSameName:IsA("BasePart") then
			return deepSameName
		end

		return inst.PrimaryPart
			or (inst:FindFirstChild("HumanoidRootPart", true) :: BasePart?)
			or (inst:FindFirstChild("UpperTorso", true) :: BasePart?)
			or (inst:FindFirstChild("Torso", true) :: BasePart?)
			or inst:FindFirstChildWhichIsA("BasePart", true)
	end

	if inst:IsA("Folder") then
		local sameName = inst:FindFirstChild(inst.Name)
		if sameName and sameName:IsA("BasePart") then
			return sameName
		end

		local deepSameName = inst:FindFirstChild(inst.Name, true)
		if deepSameName and deepSameName:IsA("BasePart") then
			return deepSameName
		end

		return inst:FindFirstChildWhichIsA("BasePart", true)
	end

	return nil
end

-- 这个函数用于把整个层级按根 Part 的目标 CFrame 一次性整体平移/旋转过去。
local function moveHierarchyToTarget(root: BasePart, rootInstance: Instance, targetCFrame: CFrame)
	local delta = targetCFrame * root.CFrame:Inverse()
	for _, d in ipairs(rootInstance:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CFrame = delta * d.CFrame
		end
	end
	root.CFrame = targetCFrame
end

-- 这个函数专门根据 Platform 当前的朝向，生成一个“位置上移但朝向不变”的目标 CFrame。
-- 这样模板里与 Model 同名的根 Part 就会严格跟随 Platform 的朝向。
local function getPlatformAlignedPlacementCFrame(slotPart: BasePart, yOffset: number): CFrame
	-- 先基于 Platform 的世界坐标，计算出向上偏移后的最终位置。
	local pos = slotPart.Position + Vector3.new(0, yOffset, 0)
	-- 再用 Platform 自己的 X/Y/Z 轴方向重建 CFrame，确保旋转完全一致。
	return CFrame.fromMatrix(pos, slotPart.CFrame.XVector, slotPart.CFrame.YVector, slotPart.CFrame.ZVector)
end

-- 这个函数用于读取某个怪物模板以及它对应的根 Part 信息，供回退逻辑复用。
local function getPlacementTemplateRootInfo(monsterLevel: number): (Instance?, BasePart?)
	local template = getMonsterAppearanceTemplate(monsterLevel)
	if not template then
		return nil, nil
	end

	return template, findPlacementTemplateRootPart(template)
end

-- 这个函数用于把 Model / BasePart / Folder 统一转换成便于后续处理的结构形式。
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

-- 这个函数用于从放置怪根 Part 向上找到整份已放置怪模板容器。
local function getPlacedMonsterContainer(rootPart: BasePart): Instance
	local current: Instance? = rootPart
	while current do
		if current ~= rootPart and current:GetAttribute("IsPlacedMonsterContainer") == true then
			return current
		end
		current = current.Parent
	end

	return rootPart
end

-- 这个函数用于销毁一只已放置怪对应的整个模板容器，而不只是根 Part。
local function destroyPlacedMonster(rootPart: BasePart)
	getPlacedMonsterContainer(rootPart):Destroy()
end

-- 这个函数用于直接复制怪物模板并放到指定 Platform 上，返回最终根 Part。
local function createPlacedMonsterFromTemplate(slotPart: BasePart, monsterLevel: number): BasePart?
	local template = getMonsterAppearanceTemplate(monsterLevel)
	if not template then
		return nil
	end

	-- 新要求：模板中“与 Model 同名的根 Part”朝向必须与 Platform 完全一致。
	-- 这里统一通过专用函数生成目标 CFrame，避免只对位置生效、旋转却偏掉。
	local targetCFrame = getPlatformAlignedPlacementCFrame(slotPart, 2)

	local clone = template:Clone()
	local model, part = toModelLike(clone)
	local rootPart: BasePart? = nil
	local container: Instance = clone

	if model then
		-- 如果模板是 Model，就优先找到“与 Model 同名的根 Part”作为真正的放置基准。
		rootPart = findPlacementTemplateRootPart(model)
		if not rootPart then
			clone:Destroy()
			return nil
		end

		-- 显式把这个根 Part 设为 PrimaryPart，后续 PivotTo 就会以它为参考。
		model.PrimaryPart = rootPart

		-- 放置区里的整套模板都保持锚定，避免刚放下时被物理系统打散。
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end

		-- 先用 PivotTo 把整份模型整体移动到目标位置与朝向。
		model:PivotTo(targetCFrame)
		-- 再用一次根 Part 精确对齐，确保最终“同名根 Part = Platform 的 CFrame 朝向”。
		moveHierarchyToTarget(rootPart, model, targetCFrame)
		container = model
	elseif part then
		-- 如果模板本身就是单个 Part，那它自己就是根。
		rootPart = part
		-- 单 Part 情况同样保持锚定。
		rootPart.Anchored = true
		-- 直接把单 Part 放到与 Platform 朝向一致的目标 CFrame。
		rootPart.CFrame = targetCFrame
		container = part
	else
		clone:Destroy()
		return nil
	end

	container:SetAttribute("IsPlacedMonsterContainer", true)
	container.Parent = slotPart.Parent
	return rootPart
end

-- 这个函数用于把怪物外观附加到占位根 Part 上，作为模板直放失败时的备用显示方案。
local function applyMonsterAppearanceToPlacedPart(rootPart: BasePart, monsterLevel: number)
	local template = getMonsterAppearanceTemplate(monsterLevel)
	if not template then
		return
	end

	-- 支持 Model / BasePart / Folder（三者都能保留子元件）
	if not (template:IsA("Model") or template:IsA("BasePart") or template:IsA("Folder")) then
		return
	end

	local old = rootPart:FindFirstChild("Appearance")
	if old then
		old:Destroy()
	end

	local appearanceFolder = Instance.new("Folder")
	appearanceFolder.Name = "Appearance"
	appearanceFolder.Parent = rootPart

	local clone = template:Clone()
	clone.Parent = appearanceFolder

	stripJointsAndConstraints(clone)
	prepareAppearanceParts(clone)

	local model, part = toModelLike(clone)
	local applied = false

	if model then
		local anchorPart = sanitizePlacementRoot(model)
		if anchorPart then
			moveHierarchyToTarget(anchorPart, model, rootPart.CFrame)
			weldPartsToAnchor(anchorPart, model)
			weldAnchorToRoot(rootPart, anchorPart)
			applied = true
		end
	elseif part then
		-- 与拿取区域/Tool 的附加方式保持一致：根 Part 直接对齐占位 Part
		part.CFrame = rootPart.CFrame
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = true

		weldPartsToAnchor(part, part)
		weldAnchorToRoot(rootPart, part)
		applied = true
	end

	-- 只有成功挂上可见外观时，才隐藏占位 RootPart
	rootPart.Transparency = if applied then 1 else 0
end

-- 这个函数用于按照区域序号计算对应放置区域的解锁价格。
local function getUnlockCost(slotIndex: number): number
	-- 规则：
	-- 01 自动解锁，花费 0
	-- 02 花费 50
	-- 03~30：= 上一个区域的 20 倍（跨层同理：11=10*20，21=20*20）
	if slotIndex <= 1 then
		return 0
	end
	if slotIndex == 2 then
		return 50
	end

	local cost = 50
	for _ = 3, slotIndex do
		cost *= 20
	end
	return cost
end

-- 这个函数用于为玩家创建或读取放置区域运行时状态表。
local function ensureState(player: Player): {[number]: SlotState}
	local m = slotStatesByUserId[player.UserId]
	if m then
		return m
	end

	m = {}
	for i = 1, 30 do
		m[i] = {
			Unlocked = (i == 1),
			PlacedMonster = nil,
			PlacedData = nil,
		}
	end
	slotStatesByUserId[player.UserId] = m
	return m
end

-- 这个函数用于判断当前家园等级是否允许玩家使用某个槽位。
local function canUseSlotByHomeLevel(player: Player, slotIndex: number): boolean
	local homeLevel = PlayerData.GetHomeLevel(player)
	return slotIndex <= homeLevel * 10
end

-- 这个函数用于检查某个放置区域的前一个区域是否已经解锁。
local function isPrevUnlocked(player: Player, slotIndex: number): boolean
	if slotIndex <= 1 then
		return true
	end
	local st = ensureState(player)[slotIndex - 1]
	return st ~= nil and st.Unlocked == true
end

-- 这个函数用于把放置怪累计但未领取的金币结算给玩家。
local function addUnclaimedToPlayer(player: Player, placed: BasePart)
	local un = placed:GetAttribute("UnclaimedGold")
	if type(un) ~= "number" or un <= 0 then
		return
	end
	placed:SetAttribute("UnclaimedGold", 0)
	PlayerData.AddGold(player, math.floor(un))
	PlayerData.Sync(player)

	local idx = placed:GetAttribute("SlotIndex")
	if type(idx) == "number" then
		local states = ensureState(player)
		local st = states[idx]
		if st and st.PlacedData then
			st.PlacedData.UnclaimedGold = 0
		end
	end

	DataDirtyService.MarkDirty(player)
end

-- 这个函数用于做服务端距离校验，判断玩家是否在允许的交互范围内。
local function isPlayerWithinInteractionDistance(player: Player, targetPart: BasePart, maxDistance: number?): boolean
	local hrp = getHRP(player)
	if not hrp then
		return false
	end

	local allowed = maxDistance or 10
	return (hrp.Position - targetPart.Position).Magnitude <= (allowed + 2)
end

-- 这个函数用于处理玩家卖出已放置怪的完整流程。
local function trySellPlacedMonster(player: Player, slotPart: BasePart, placedPart: BasePart): boolean
	if placedPart.Parent == nil then
		return false
	end
	if placedPart:GetAttribute("IsPlacedMonster") ~= true then
		return false
	end
	if placedPart:GetAttribute("OwnerUserId") ~= player.UserId then
		return false
	end
	if placedPart:GetAttribute("__InteractionLocked") == true then
		return false
	end

	placedPart:SetAttribute("__InteractionLocked", true)
	addUnclaimedToPlayer(player, placedPart)

	local val = placedPart:GetAttribute("Value")
	if type(val) ~= "number" then
		val = 0
	end
	PlayerData.AddGold(player, val)
	PlayerData.Sync(player)

	local idx = slotPart:GetAttribute("SlotIndex")
	if type(idx) == "number" then
		local st = ensureState(player)[idx]
		if st then
			st.PlacedData = nil
		end
	end

	DataDirtyService.MarkDirty(player, 5)

	local home = HomeService.GetHome(player)
	if home then
		local slot = HomeService.GetSlot(player, idx)
		refreshIncomeDisplayForSlot(player, slotPart, slot and slot.Collector or nil, nil)
	end

	toast(player, string.format("卖出获得 %d 金币", val))
	destroyPlacedMonster(placedPart)
	return true
end

-- 这个函数用于处理玩家把已放置怪收回背包的完整流程。
local function tryStorePlacedMonster(player: Player, slotPart: BasePart, placedPart: BasePart): boolean
	if placedPart.Parent == nil then
		return false
	end
	if placedPart:GetAttribute("IsPlacedMonster") ~= true then
		return false
	end
	if placedPart:GetAttribute("OwnerUserId") ~= player.UserId then
		return false
	end
	if placedPart:GetAttribute("__InteractionLocked") == true then
		return false
	end

	placedPart:SetAttribute("__InteractionLocked", true)
	addUnclaimedToPlayer(player, placedPart)

	local lvl = placedPart:GetAttribute("MonsterLevel")
	local v = placedPart:GetAttribute("Value")
	local gps = placedPart:GetAttribute("GoldPerSec")
	local ok = InventoryService.TryAddMonsterItem(
		player,
		type(lvl) == "number" and lvl or 1,
		type(v) == "number" and v or 0,
		type(gps) == "number" and gps or 0
	)
	if not ok then
		placedPart:SetAttribute("__InteractionLocked", false)
		return false
	end

	local idx = slotPart:GetAttribute("SlotIndex")
	if type(idx) == "number" then
		local st = ensureState(player)[idx]
		if st then
			st.PlacedData = nil
		end
	end

	DataDirtyService.MarkDirty(player, 5)

	local home = HomeService.GetHome(player)
	if home then
		local slot = HomeService.GetSlot(player, idx)
		refreshIncomeDisplayForSlot(player, slotPart, slot and slot.Collector or nil, nil)
	end

	toast(player, "已收起到背包")
	destroyPlacedMonster(placedPart)
	return true
end

-- 这个函数用于响应解锁提示交互，并在满足条件时解锁对应槽位。
local function tryUnlockSlotFromPrompt(player: Player, slotPart: BasePart, prompt: ProximityPrompt): boolean
	if player:GetAttribute("__DataLoaded") ~= true then
		return false
	end

	local idx = slotPart:GetAttribute("SlotIndex")
	if type(idx) ~= "number" then
		return false
	end

	if not isPlayerWithinInteractionDistance(player, slotPart, prompt.MaxActivationDistance) then
		return false
	end

	if not canUseSlotByHomeLevel(player, idx) then
		toast(player, "需要升级家园才能解锁该区域")
		updateUnlockPromptEnabled(player, slotPart)
		return false
	end

	if not isPrevUnlocked(player, idx) then
		toast(player, "请先解锁上一个放置区域")
		updateUnlockPromptEnabled(player, slotPart)
		return false
	end

	local state = ensureState(player)[idx]
	if state.Unlocked then
		prompt.Enabled = false
		return false
	end

	local cost = getUnlockCost(idx)
	if not PlayerData.TrySpendGold(player, cost) then
		toast(player, string.format("金币不足，需要 %d", cost))
		return false
	end

	state.Unlocked = true
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player, 5)
	prompt.Enabled = false
	toast(player, string.format("解锁成功：区域%d", idx))

	updateUnlockPromptEnabled(player, slotPart)
	local nextSlot = HomeService.GetSlotPart(player, idx + 1)
	if nextSlot then
		updateUnlockPromptEnabled(player, nextSlot)
	end

	return true
end

-- 这个函数用于创建一只真正放置到家园里的怪，并挂上属性、头顶显示和交互提示。
local function createPlacedMonsterPart(
	player: Player,
	slotPart: BasePart,
	monsterLevel: number,
	value: number,
	goldPerSec: number,
	unclaimedGold: number?,
	lastTickUnix: number?
): BasePart
	local placedFromTemplate = createPlacedMonsterFromTemplate(slotPart, monsterLevel)
	if placedFromTemplate then
		local p = placedFromTemplate
		p:SetAttribute("IsPlacedMonster", true)
		p:SetAttribute("OwnerUserId", player.UserId)
		p:SetAttribute("SlotIndex", slotPart:GetAttribute("SlotIndex"))
		p:SetAttribute("MonsterLevel", monsterLevel)
		p:SetAttribute("Value", value)
		p:SetAttribute("GoldPerSec", goldPerSec)
		p:SetAttribute("UnclaimedGold", unclaimedGold or 0)
		p:SetAttribute("LastTickUnix", lastTickUnix or os.time())

		setPlacedMonsterHeadBillboardText(p)

		local function setPlacedMonsterPromptVisible(visible: boolean)
			local sellPrompt = p:FindFirstChild("SellPrompt")
			if sellPrompt and sellPrompt:IsA("ProximityPrompt") then
				sellPrompt.Enabled = visible
			end

			local storePrompt = p:FindFirstChild("StorePrompt")
			if storePrompt and storePrompt:IsA("ProximityPrompt") then
				storePrompt.Enabled = visible
			end
		end

		local function revealPlacedMonsterPrompts(showSeconds: number?)
			local token = (p:GetAttribute("PromptRevealToken") or 0) + 1
			p:SetAttribute("PromptRevealToken", token)
			setPlacedMonsterPromptVisible(true)

			task.delay(showSeconds or 3, function()
				if p.Parent == nil then
					return
				end
				if p:GetAttribute("PromptRevealToken") ~= token then
					return
				end
				setPlacedMonsterPromptVisible(false)
			end)
		end

		local sell = Instance.new("ProximityPrompt")
		sell.Name = "SellPrompt"
		sell.ActionText = "卖出"
		sell.ObjectText = "放置怪"
		sell.KeyboardKeyCode = Enum.KeyCode.E
		sell.HoldDuration = 0.2
		sell.MaxActivationDistance = 10
		sell.RequiresLineOfSight = false
		sell.UIOffset = Vector2.new(0, 0)
		sell.Enabled = false
		sell.Parent = p

		sell.Triggered:Connect(function(triggerPlayer: Player)
			if player:GetAttribute("__DataLoaded") ~= true then
				return
			end
			if triggerPlayer.UserId ~= player.UserId then
				return
			end
			trySellPlacedMonster(player, slotPart, p)
		end)

		local store = Instance.new("ProximityPrompt")
		store.Name = "StorePrompt"
		store.ActionText = "收起"
		store.ObjectText = "放置怪"
		store.KeyboardKeyCode = Enum.KeyCode.R
		store.HoldDuration = 0.6
		store.MaxActivationDistance = 10
		store.RequiresLineOfSight = false
		store.UIOffset = Vector2.new(0, 50)
		store.Enabled = false
		store.Parent = p

		store.Triggered:Connect(function(triggerPlayer: Player)
			if player:GetAttribute("__DataLoaded") ~= true then
				return
			end
			if triggerPlayer.UserId ~= player.UserId then
				return
			end
			tryStorePlacedMonster(player, slotPart, p)
		end)

		p.Touched:Connect(function(hit)
			if player:GetAttribute("__DataLoaded") ~= true then
				return
			end
			local character = player.Character
			if not character then
				return
			end
			if not hit:IsDescendantOf(character) then
				return
			end

			local now = os.clock()
			local idx = slotPart:GetAttribute("SlotIndex")
			local key = string.format("placed_prompt_touch_%d_%s", player.UserId, tostring(idx))
			if (lastTouchAt[key] or 0) + 0.35 > now then
				return
			end
			lastTouchAt[key] = now
			revealPlacedMonsterPrompts(3)
		end)

		local function attachPromptClickDetector(targetPart: BasePart)
			local detectorName = "PlacedMonsterPromptClickDetector"
			local oldDetector = targetPart:FindFirstChild(detectorName)
			if oldDetector and oldDetector:IsA("ClickDetector") then
				oldDetector:Destroy()
			end

			local detector = Instance.new("ClickDetector")
			detector.Name = detectorName
			detector.MaxActivationDistance = 20
			detector.Parent = targetPart
			detector.MouseClick:Connect(function(clickPlayer: Player)
				if player:GetAttribute("__DataLoaded") ~= true then
					return
				end
				if clickPlayer.UserId ~= player.UserId then
					return
				end
				revealPlacedMonsterPrompts(3)
			end)
		end

		attachPromptClickDetector(p)
		local container = getPlacedMonsterContainer(p)
		for _, desc in ipairs(container:GetDescendants()) do
			if desc:IsA("BasePart") then
				attachPromptClickDetector(desc)
			end
		end

		container.Destroying:Connect(function()
			local m = slotStatesByUserId[player.UserId]
			if not m then
				return
			end
			local si = slotPart:GetAttribute("SlotIndex")
			if type(si) ~= "number" then
				return
			end
			local st = m[si]
			if st and st.PlacedMonster == p then
				st.PlacedMonster = nil
			end
		end)

		return p
	end

	-- 如果没法直接复制模板，就回退到占位 Part 方案。
	local _, templateRoot = getPlacementTemplateRootInfo(monsterLevel)
	-- 占位 Part 的尺寸优先参考模板根 Part，拿不到就用默认大小。
	local rootSize = templateRoot and templateRoot.Size or Vector3.new(3, 4, 3)
	-- 即使走回退分支，也继续使用 Platform 朝向作为最终朝向基准。
	local rootCFrame = getPlatformAlignedPlacementCFrame(slotPart, slotPart.Size.Y * 0.5 + rootSize.Y * 0.5 + 2)

	local p = Instance.new("Part")
	p.Name = "PlacedMonster"
	p.Anchored = true
	p.CanCollide = true
	p.Size = rootSize
	p.Material = Enum.Material.SmoothPlastic
	p.Color = Color3.fromRGB(60, 60, 60)
	p.Transparency = 0
	p.CFrame = rootCFrame
	p.Parent = slotPart.Parent

	p:SetAttribute("IsPlacedMonster", true)
	p:SetAttribute("OwnerUserId", player.UserId)
	p:SetAttribute("SlotIndex", slotPart:GetAttribute("SlotIndex"))
	p:SetAttribute("MonsterLevel", monsterLevel)
	p:SetAttribute("Value", value)
	p:SetAttribute("GoldPerSec", goldPerSec)
	p:SetAttribute("UnclaimedGold", unclaimedGold or 0)
	p:SetAttribute("LastTickUnix", lastTickUnix or os.time())

	-- 外观：与背包 Tool/刷怪外观保持一致
	applyMonsterAppearanceToPlacedPart(p, monsterLevel)
	setPlacedMonsterHeadBillboardText(p)

	local function setPlacedMonsterPromptVisible(visible: boolean)
		local sellPrompt = p:FindFirstChild("SellPrompt")
		if sellPrompt and sellPrompt:IsA("ProximityPrompt") then
			sellPrompt.Enabled = visible
		end

		local storePrompt = p:FindFirstChild("StorePrompt")
		if storePrompt and storePrompt:IsA("ProximityPrompt") then
			storePrompt.Enabled = visible
		end
	end

	local function revealPlacedMonsterPrompts(showSeconds: number?)
		local token = (p:GetAttribute("PromptRevealToken") or 0) + 1
		p:SetAttribute("PromptRevealToken", token)
		setPlacedMonsterPromptVisible(true)

		task.delay(showSeconds or 3, function()
			if p.Parent == nil then
				return
			end
			if p:GetAttribute("PromptRevealToken") ~= token then
				return
			end
			setPlacedMonsterPromptVisible(false)
		end)
	end

	-- 卖出 prompt
	local sell = Instance.new("ProximityPrompt")
	sell.Name = "SellPrompt"
	sell.ActionText = "卖出"
	sell.ObjectText = "放置怪"
	sell.KeyboardKeyCode = Enum.KeyCode.E
	sell.HoldDuration = 0.2
	sell.MaxActivationDistance = 10
	sell.RequiresLineOfSight = false
	-- 避免和“收起”Prompt UI 重合
	sell.UIOffset = Vector2.new(0, 0)
	sell.Enabled = false
	sell.Parent = p

	sell.Triggered:Connect(function(triggerPlayer: Player)
		if player:GetAttribute("__DataLoaded") ~= true then
			return
		end
		if triggerPlayer.UserId ~= player.UserId then
			return
		end
		trySellPlacedMonster(player, slotPart, p)
	end)

	-- 收起 prompt
	local store = Instance.new("ProximityPrompt")
	store.Name = "StorePrompt"
	store.ActionText = "收起"
	store.ObjectText = "放置怪"
	store.KeyboardKeyCode = Enum.KeyCode.R
	store.HoldDuration = 0.6
	store.MaxActivationDistance = 10
	store.RequiresLineOfSight = false
	-- 避免和“卖出”Prompt UI 重合
	store.UIOffset = Vector2.new(0, 50)
	store.Enabled = false
	store.Parent = p

	store.Triggered:Connect(function(triggerPlayer: Player)
		if player:GetAttribute("__DataLoaded") ~= true then
			return
		end
		if triggerPlayer.UserId ~= player.UserId then
			return
		end
		tryStorePlacedMonster(player, slotPart, p)
	end)

	-- 新需求：卖出/收起按钮默认隐藏，只有“碰到放置怪”或“点击放置怪”时才短暂显示。
	-- 注意：这里仍保留 ProximityPrompt 作为最终交互方式，只改变显示时机。
	p.Touched:Connect(function(hit)
		if player:GetAttribute("__DataLoaded") ~= true then
			return
		end
		local character = player.Character
		if not character then
			return
		end
		if not hit:IsDescendantOf(character) then
			return
		end

		local now = os.clock()
		local idx = slotPart:GetAttribute("SlotIndex")
		local key = string.format("placed_prompt_touch_%d_%s", player.UserId, tostring(idx))
		if (lastTouchAt[key] or 0) + 0.35 > now then
			return
		end
		lastTouchAt[key] = now
		revealPlacedMonsterPrompts(3)
	end)

	local function attachPromptClickDetector(targetPart: BasePart)
		local detectorName = "PlacedMonsterPromptClickDetector"
		local oldDetector = targetPart:FindFirstChild(detectorName)
		if oldDetector and oldDetector:IsA("ClickDetector") then
			oldDetector:Destroy()
		end

		local detector = Instance.new("ClickDetector")
		detector.Name = detectorName
		detector.MaxActivationDistance = 20
		detector.Parent = targetPart
		detector.MouseClick:Connect(function(clickPlayer: Player)
			if player:GetAttribute("__DataLoaded") ~= true then
				return
			end
			if clickPlayer.UserId ~= player.UserId then
				return
			end
			revealPlacedMonsterPrompts(3)
		end)
	end

	attachPromptClickDetector(p)
	local appearanceFolder = p:FindFirstChild("Appearance")
	if appearanceFolder then
		for _, desc in ipairs(appearanceFolder:GetDescendants()) do
			if desc:IsA("BasePart") then
				attachPromptClickDetector(desc)
			end
		end
	end

	-- 销毁时清理引用
	p.Destroying:Connect(function()
		local m = slotStatesByUserId[player.UserId]
		if not m then
			return
		end
		local si = slotPart:GetAttribute("SlotIndex")
		if type(si) ~= "number" then
			return
		end
		local st = m[si]
		if st and st.PlacedMonster == p then
			st.PlacedMonster = nil
		end
	end)

	return p
end

-- 这个函数用于检测玩家当前装备的怪物 Tool，并尝试放到指定槽位。
local function tryPlaceFromEquippedTool(player: Player, slotPart: BasePart)
	-- Block interactions before data is loaded (prevents overwriting loaded profile state)
	if player:GetAttribute("__DataLoaded") ~= true then
		return
	end

	local stateMap = ensureState(player)
	local idx = slotPart:GetAttribute("SlotIndex")
	if type(idx) ~= "number" then
		return
	end

	-- 超出当前家园等级：不能放置
	if not canUseSlotByHomeLevel(player, idx) then
		return
	end

	local state = stateMap[idx]
	if not state then
		return
	end
	if not state.Unlocked then
		return
	end
	if state.PlacedMonster and state.PlacedMonster.Parent then
		return
	end

	local character = player.Character
	if not character then
		return
	end

	-- 查找装备中的怪 Tool
	local equipped: Tool? = nil
	for _, ch in ipairs(character:GetChildren()) do
		if ch:IsA("Tool") and ch:GetAttribute("IsMonsterItem") == true then
			equipped = ch
			break
		end
	end
	if not equipped then
		return
	end

	local lvl = equipped:GetAttribute("MonsterLevel")
	local v = equipped:GetAttribute("Value")
	local gps = equipped:GetAttribute("GoldPerSec")

	-- 【新增】获取 Tool 上可能存在的强化属性
	local upLevel = equipped:GetAttribute("UpgradeLevel") or 1
	local baseV = equipped:GetAttribute("BaseValue") or v
	local baseGps = equipped:GetAttribute("BaseGoldPerSec") or gps

	local placed = createPlacedMonsterPart(
		player,
		slotPart,
		type(lvl) == "number" and lvl or 1,
		type(v) == "number" and v or 0,
		type(gps) == "number" and gps or 0
	)

	-- 【新增】将强化属性继承给放置到地上的怪
	if placed then
		placed:SetAttribute("UpgradeLevel", upLevel)
		placed:SetAttribute("BaseValue", baseV)
		placed:SetAttribute("BaseGoldPerSec", baseGps)
	end

	-- 放置后立即刷新收益显示牌子
	local home = HomeService.GetHome(player)
	if home then
		local slot = HomeService.GetSlot(player, idx)
		refreshIncomeDisplayForSlot(player, slotPart, slot and slot.Collector or nil, placed)
	end

	local itemId = equipped:GetAttribute("ItemId")
	if type(itemId) == "string" and itemId ~= "" then
		InventoryService.ConsumeItem(player, itemId)
	end

	state.PlacedMonster = placed
	state.PlacedData = {
		MonsterLevel = type(lvl) == "number" and lvl or 1,
		Value = type(v) == "number" and v or 0,
		GoldPerSec = type(gps) == "number" and gps or 0,
		UnclaimedGold = 0,
		LastTickUnix = os.time(),
		-- 【新增】把强化等级也写进存档数据里，保证下线不丢
		UpgradeLevel = upLevel, 
	}
	
	equipped:Destroy()
	DataDirtyService.MarkDirty(player, 5)
	toast(player, string.format("已放置怪到区域%d", idx))
end
	

-- 这个函数用于在玩家触碰 Collector 时领取该槽位已积累的金币。
local function payoutIfAny(player: Player, slotPart: BasePart)
	-- Block interactions before data is loaded
	if player:GetAttribute("__DataLoaded") ~= true then
		return
	end

	local stateMap = ensureState(player)
	local idx = slotPart:GetAttribute("SlotIndex")
	if type(idx) ~= "number" then
		return
	end

	-- 超出当前家园等级：不处理
	if not canUseSlotByHomeLevel(player, idx) then
		return
	end

	local state = stateMap[idx]
	if not state or not state.PlacedMonster or not state.PlacedMonster.Parent then
		return
	end

	local placed = state.PlacedMonster
	local un = placed:GetAttribute("UnclaimedGold")
	if type(un) ~= "number" or un <= 0 then
		return
	end

	addUnclaimedToPlayer(player, placed)
	toast(player, string.format("领取金币 +%d", math.floor(un)))
end

-- forward declare（ensureUnlockPrompt 里会用到）
local updateUnlockPromptEnabled: (Player, BasePart) -> ()

-- 这个函数用于给某个放置区域创建“解锁”用的 ProximityPrompt。
local function ensureUnlockPrompt(player: Player, slotPart: BasePart)
	local prompt = slotPart:FindFirstChild("UnlockPrompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		return
	end

	prompt = Instance.new("ProximityPrompt")
	prompt.Name = "UnlockPrompt"
	prompt.ActionText = "解锁"
	prompt.ObjectText = slotPart.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.F
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	-- 避免解锁提示挤掉“升级区域”提示
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OneGlobally
	prompt.Parent = slotPart

	prompt.Triggered:Connect(function(triggerPlayer: Player)
		-- Block interactions before data is loaded
		if player:GetAttribute("__DataLoaded") ~= true then
			return
		end
		if triggerPlayer.UserId ~= player.UserId then
			return
		end

		local idx = slotPart:GetAttribute("SlotIndex")
		if type(idx) ~= "number" then
			return
		end

		-- 超出当前家园等级：禁止解锁
		if not canUseSlotByHomeLevel(player, idx) then
			toast(player, "需要升级家园才能解锁该区域")
			updateUnlockPromptEnabled(player, slotPart)
			return
		end

		-- 必须按顺序解锁
		if not isPrevUnlocked(player, idx) then
			toast(player, "请先解锁上一个放置区域")
			updateUnlockPromptEnabled(player, slotPart)
			return
		end

		local state = ensureState(player)[idx]
		if state.Unlocked then
			prompt.Enabled = false
			return
		end

		local cost = getUnlockCost(idx)
		if not PlayerData.TrySpendGold(player, cost) then
			toast(player, string.format("金币不足，需要 %d", cost))
			return
		end

		state.Unlocked = true
		PlayerData.Sync(player)
		DataDirtyService.MarkDirty(player, 5)
		prompt.Enabled = false
		toast(player, string.format("解锁成功：区域%d", idx))

		-- 解锁后刷新本格与下一格（让下一格可立即解锁）
		updateUnlockPromptEnabled(player, slotPart)
		local nextSlot = HomeService.GetSlotPart(player, idx + 1)
		if nextSlot then
			updateUnlockPromptEnabled(player, nextSlot)
		end
	end)
end

-- 这个函数用于根据玩家当前状态，实时刷新解锁提示的文案和启用状态。
updateUnlockPromptEnabled = function(player: Player, slotPart: BasePart)
	local idx = slotPart:GetAttribute("SlotIndex")
	if type(idx) ~= "number" then
		return
	end

	local prompt = slotPart:FindFirstChild("UnlockPrompt")
	if not (prompt and prompt:IsA("ProximityPrompt")) then
		return
	end

	local state = ensureState(player)[idx]
	if not state then
		prompt.Enabled = false
		return
	end

		-- 玩家必须站在对应地块上方才显示解锁
	if not isPlayerStandingOnSlot(player, slotPart) then
		prompt.Enabled = false
		return
	end

	-- 超出当前家园等级：不可解锁/不可交互
	if not canUseSlotByHomeLevel(player, idx) then
		prompt.Enabled = true
		prompt.ActionText = "升级家园解锁"
		return
	end

	-- 已解锁
	if state.Unlocked then
		prompt.Enabled = false
		return
	end

	-- 必须按顺序解锁（需要上一个区域已解锁）
	if not isPrevUnlocked(player, idx) then
		prompt.Enabled = true
		prompt.ActionText = "先解锁上一个"
		return
	end

	prompt.Enabled = true
	prompt.ActionText = string.format("解锁(%d)", getUnlockCost(idx))
end


-- 这个函数是 PlacementService 的初始化入口，用来挂接所有玩家、槽位和心跳逻辑。
function PlacementService.Init()
	local function setupPlayer(player: Player)
		if placementInitStartedByUserId[player.UserId] then
			return
		end
		placementInitStartedByUserId[player.UserId] = true
		
		ensureState(player)

		-- 等 Home 建好
		task.spawn(function()
			local home
			while player.Parent do
				home = HomeService.GetHome(player)
				if home then
					break
				end
				task.wait(0.1)
			end

			if not home then
				warn("[PlacementService] Home not ready for player", player)
				return
			end

			local function refreshAllUnlockPrompts()
				for _, slot in ipairs(home.Slots) do
					updateUnlockPromptEnabled(player, slot.Part)
				end
			end

			-- [诊断] 检查 home 对象是否完整
			print(string.format("[PlacementDebug] 玩家 %s 的家园已就绪，共有 %d 个槽位", player.Name, #home.Slots))
			------------------
			for _, slot in ipairs(home.Slots) do
				ensureUnlockPrompt(player, slot.Part)
				updateUnlockPromptEnabled(player, slot.Part)

				-- 1. 生成并挂载“收益显示”面板 -------------------------
				if slot.Collector then
					local displayModel = slot.Collector:FindFirstChild("收益显示", true)
					
					if not displayModel then
						local template = ReplicatedStorage:FindFirstChild("收益显示", true) or Workspace:FindFirstChild("收益显示", true)
						
						if template and template:IsA("Model") then
							displayModel = template:Clone()
							local locatorPart = slot.Collector:FindFirstChild("收益显示定位", true)
							local anchorCFrame = locatorPart and locatorPart.CFrame or slot.Collector.CFrame
							
							-- 🌟 [物理层终极修复]：用代码强行解除空气墙对鼠标的拦截！
							-- 无论你的透明定位方块有多大，统统让鼠标穿透过去，直达牌子！
							if locatorPart then locatorPart.CanQuery = false end
							slot.Collector.CanQuery = false
							
							if not displayModel.PrimaryPart then
								displayModel.PrimaryPart = displayModel:FindFirstChildWhichIsA("BasePart", true)
							end
							
							if displayModel.PrimaryPart then
								displayModel:PivotTo(anchorCFrame)
							end
							displayModel.Parent = slot.Collector
						end
					end

					-- 2. 绑定纯粹的“鼠标点击”事件 -------------------------
					if displayModel then
						local clickPart = displayModel:FindFirstChild("点击升级", true) or displayModel.PrimaryPart
						if clickPart then
							-- 清理掉上一版生成的按键提示器（如果你运行过的话）
							local oldPrompt = clickPart:FindFirstChildWhichIsA("ProximityPrompt")
							if oldPrompt then oldPrompt:Destroy() end

							-- 寻找或自动创建鼠标点击检测器
							local clickDetector = clickPart:FindFirstChildWhichIsA("ClickDetector")
							if not clickDetector then
								clickDetector = Instance.new("ClickDetector")
								clickDetector.MaxActivationDistance = 32
								clickDetector.Parent = clickPart
							end

							-- 使用专属 ID 绑定，杜绝克隆污染
							local bindKey = "BoundForUser_" .. tostring(player.UserId)
							if not clickDetector:GetAttribute(bindKey) then
								clickDetector:SetAttribute(bindKey, true)
								
								clickDetector.MouseClick:Connect(function(playerWhoClicked)
									-- 🩺 [核心诊断打印]：鼠标成功点到，必然输出此句！
									print(string.format("🟢 [鼠标点击测试] 玩家 %s 成功点到了槽位 %d 的升级底座！", playerWhoClicked.Name, slot.Index))

									if playerWhoClicked ~= player then return end
									
									local state = slotStatesByUserId[player.UserId] and slotStatesByUserId[player.UserId][slot.Index]
									if not state or not state.PlacedMonster or not state.PlacedMonster.Parent then 
										toast(player, "请先放置怪物再升级！")
										print("🔴 [点击拒绝] 因为该槽位没有放置怪物。")
										return 
									end
									
									local pm = state.PlacedMonster
									local upLevel = pm:GetAttribute("UpgradeLevel") or 1
									local baseGps = pm:GetAttribute("BaseGoldPerSec") or pm:GetAttribute("GoldPerSec") or 0
									local upgradeCost = upLevel * 10 * baseGps
									
									if PlayerData.TrySpendGold(player, upgradeCost) then
										pm:SetAttribute("UpgradeLevel", upLevel + 1)
										local newGps = (upLevel + 1) * baseGps
										local baseValue = pm:GetAttribute("BaseValue") or pm:GetAttribute("Value")
										pm:SetAttribute("GoldPerSec", newGps)
										pm:SetAttribute("Value", baseValue * (upLevel + 1))
										
										setPlacedMonsterHeadBillboardText(pm)
										refreshIncomeDisplayForSlot(player, slot.Part, slot.Collector, pm)
										toast(player, "升级成功！")
										print("🟢 [升级成功] 当前等级: " .. tostring(upLevel + 1))
										DataDirtyService.MarkDirty(player)
									else
										toast(player, "金币不足！")
										print("🟡 [升级失败] 金币不足。所需: " .. tostring(upgradeCost))
									end
								end)
							end
						end
					end
				end

				-- 3. 终极收钱与放置逻辑 (保持原样，这部分你已经测试成功了) --------
				local function handleSlotTouch(hit)
					if player:GetAttribute("__DataLoaded") ~= true then return end
					local character = player.Character
					if not character or not hit:IsDescendantOf(character) then return end

					local idx = slot.Part:GetAttribute("SlotIndex") or slot.Index
					local key = string.format("touch_%d_%s", player.UserId, tostring(idx))
					local now = os.clock()
					if (lastTouchAt[key] or 0) + 0.35 > now then return end
					lastTouchAt[key] = now

					tryPlaceFromEquippedTool(player, slot.Part)
					payoutIfAny(player, slot.Part)
				end

				slot.Part.Touched:Connect(handleSlotTouch)
				if slot.Collector then
					slot.Collector.Touched:Connect(handleSlotTouch)
				end
			end

			-- 家园升级后需要刷新 UnlockPrompt（哪些格子可用/可解锁）
			player:GetAttributeChangedSignal("HomeLevel"):Connect(function()
				refreshAllUnlockPrompts()
			end)
		end)
	end

	-- 初始化已有玩家
	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end

	Players.PlayerAdded:Connect(function(player)
		setupPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(_player)
		-- IMPORTANT:
		-- Do not clear placement state here.
		-- DataPersistenceService needs access to the latest in-memory state during PlayerRemoving.
		-- Call PlacementService.Cleanup(player) after persistence is done.
	end)

	-- 在线产币（仅玩家在线才跑）
	local acc = 0
	local unlockAcc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		unlockAcc += dt

		-- 0.25s 刷新一次解锁提示（只在玩家站在对应地块上方时显示）
		if unlockAcc >= 0.25 then
			unlockAcc = 0
			for _, player in ipairs(Players:GetPlayers()) do
				local home = HomeService.GetHome(player)
				if not home then
					continue
				end
				for _, slot in ipairs(home.Slots) do
					updateUnlockPromptEnabled(player, slot.Part)
				end
			end
		end

		if acc < 1.0 then
			return
		end
		acc = 0

		for _, player in ipairs(Players:GetPlayers()) do
			local home = HomeService.GetHome(player)
			if not home then
				continue
			end

			local states = ensureState(player)
			for _, slot in ipairs(home.Slots) do
				local idx = slot.Index
				local state = states[idx]
				if state and state.PlacedMonster and state.PlacedMonster.Parent then
					local pm = state.PlacedMonster
					local gps = pm:GetAttribute("GoldPerSec")
					if type(gps) ~= "number" then
						gps = 0
					end
					local un = pm:GetAttribute("UnclaimedGold")
					if type(un) ~= "number" then
						un = 0
					end
					local newUn = math.min(30000, un + gps)
					local nowUnix = os.time()
					pm:SetAttribute("UnclaimedGold", newUn)
					pm:SetAttribute("LastTickUnix", nowUnix)

					-- mirror back to state.PlacedData for robust saving
					local st = state
					if st.PlacedData then
						st.PlacedData.UnclaimedGold = newUn
						st.PlacedData.LastTickUnix = nowUnix
					end

					-- 收益显示牌子刷新
					refreshIncomeDisplayForSlot(player, slot.Part, slot.Collector, pm)

					-- pulse dirty marking so periodic saves can capture production progress
					local lastPulse = lastDirtyPulseUnixByUserId[player.UserId] or 0
					if nowUnix - lastPulse >= 10 then
						lastDirtyPulseUnixByUserId[player.UserId] = nowUnix
						DataDirtyService.MarkDirty(player)
					end
				else
					-- 没放置怪：保持牌子显示“未放置”
					refreshIncomeDisplayForSlot(player, slot.Part, slot.Collector, nil)
				end
			end
		end
	end)
end


-- 这个函数用于在家园分配完成后，按存档数据重新生成玩家已放置的怪物。
local function rebuildPlacedMonstersWhenHomeReady(player: Player)
	-- Wait for HomeService to assign a plot
	local home
	while player.Parent do
		home = HomeService.GetHome(player)
		if home then
			break
		end
		task.wait(0.1)
	end

	if not home then
		return
	end

	local states = ensureState(player)
	local nowUnix = os.time()

	for _, slot in ipairs(home.Slots) do
		local idx = slot.Index
		local st = states[idx]
		if st and st.PlacedData and (not st.PlacedMonster or not st.PlacedMonster.Parent) then
			if player:GetAttribute("__DataLoaded") ~= true then
				return
			end
			local d = st.PlacedData

			-- Offline production: offline收益 = 在线收益的 1/20
			local lastTick = tonumber(d.LastTickUnix) or nowUnix
			local offlineSec = math.max(0, nowUnix - math.floor(lastTick))
			local gain = math.floor((offlineSec * (tonumber(d.GoldPerSec) or 0)) / 20)

			local un = math.floor(tonumber(d.UnclaimedGold) or 0)
			if gain > 0 then
				un = math.min(30000, un + gain)
				d.UnclaimedGold = un
				d.LastTickUnix = nowUnix
				DataDirtyService.MarkDirty(player, 5)
			else
				-- still advance last tick to avoid repeated large offline windows
				d.LastTickUnix = nowUnix
			end

			local placed = createPlacedMonsterPart(
				player,
				slot.Part,
				math.max(1, math.floor(tonumber(d.MonsterLevel) or 1)),
				math.floor(tonumber(d.Value) or 0),
				math.floor(tonumber(d.GoldPerSec) or 0),
				un,
				nowUnix
			)
			st.PlacedMonster = placed

			-- 进游戏/加载存档后也立即刷新收益显示牌子
			refreshIncomeDisplayForSlot(player, slot.Part, slot.Collector, placed)
		end
	end
end

-- 这个函数用于把玩家当前所有放置槽位状态导出成可持久化的数据结构。
function PlacementService.Export(player: Player): {PersistedSlot}
	local states = ensureState(player)
	local out: {PersistedSlot} = {}

	for i = 1, 30 do
		local st = states[i]
		local placedData: PersistedPlacedMonster? = nil

		if st then
			-- If a live part exists, read from it (source of truth)
			if st.PlacedMonster and st.PlacedMonster.Parent then
				local pm = st.PlacedMonster
				placedData = {
					MonsterLevel = math.max(1, math.floor(tonumber(pm:GetAttribute("MonsterLevel")) or 1)),
					Value = math.floor(tonumber(pm:GetAttribute("Value")) or 0),
					GoldPerSec = math.floor(tonumber(pm:GetAttribute("GoldPerSec")) or 0),
					UnclaimedGold = math.floor(tonumber(pm:GetAttribute("UnclaimedGold")) or 0),
					LastTickUnix = math.floor(tonumber(pm:GetAttribute("LastTickUnix")) or os.time()),
				}
				st.PlacedData = placedData
			elseif st.PlacedData then
				placedData = st.PlacedData
			end

			out[i] = {
				Unlocked = st.Unlocked == true,
				Placed = placedData,
			}
		else
			out[i] = {
				Unlocked = (i == 1),
				Placed = nil,
			}
		end
	end

	return out
end

-- 这个函数用于把存档中的放置数据重新应用到玩家当前运行时状态中。
function PlacementService.ApplyLoaded(player: Player, loadedSlots: {PersistedSlot}?)
	local states = ensureState(player)

	for i = 1, 30 do
		local loaded = (type(loadedSlots) == "table") and loadedSlots[i] or nil
		local unlocked = if type(loaded) == "table" then ((loaded :: any).Unlocked == true) else (i == 1)
		states[i].Unlocked = unlocked or (i == 1)
		states[i].PlacedMonster = nil
		states[i].PlacedData = nil

		if type(loaded) == "table" then
			local placed = (loaded :: any).Placed
			if type(placed) == "table" then
				states[i].PlacedData = {
					MonsterLevel = math.max(1, math.floor(tonumber((placed :: any).MonsterLevel) or 1)),
					Value = math.floor(tonumber((placed :: any).Value) or 0),
					GoldPerSec = math.floor(tonumber((placed :: any).GoldPerSec) or 0),
					UnclaimedGold = math.floor(tonumber((placed :: any).UnclaimedGold) or 0),
					LastTickUnix = math.floor(tonumber((placed :: any).LastTickUnix) or os.time()),
				}
			end
		end
	end

	-- Rebuild placed monster parts after Home is assigned
	task.defer(function()
		rebuildPlacedMonstersWhenHomeReady(player)
	end)
end

-- 这个函数用于在玩家彻底清理时移除 PlacementService 的运行时缓存。
function PlacementService.Cleanup(player: Player)
	slotStatesByUserId[player.UserId] = nil
	placementInitStartedByUserId[player.UserId] = nil
end

-- 这个函数用于统一处理 PlacementService 负责的各种 ProximityPrompt 服务端交互。
function PlacementService.TryHandlePromptInteraction(player: Player, promptInstance: Instance): boolean
	if player:GetAttribute("__DataLoaded") ~= true then
		print(string.format("[PromptDebug][Placement] reject player=%s reason=data_not_loaded", player.Name))
		return false
	end
	if not promptInstance:IsA("ProximityPrompt") then
		print(string.format("[PromptDebug][Placement] reject player=%s reason=not_prompt class=%s", player.Name, promptInstance.ClassName))
		return false
	end

	local promptParent = promptInstance.Parent
	if not (promptParent and promptParent:IsA("BasePart")) then
		print(string.format("[PromptDebug][Placement] reject player=%s prompt=%s reason=parent_not_basepart parent=%s", player.Name, debugInstancePath(promptInstance), debugInstancePath(promptParent)))
		return false
	end

	if promptInstance.Name == "UnlockPrompt" then
		local slotPart = promptParent
		if promptInstance.Enabled ~= true then
			print(string.format("[PromptDebug][Placement] reject player=%s prompt=%s reason=prompt_disabled", player.Name, debugInstancePath(promptInstance)))
			return false
		end

		local slotIndex = slotPart:GetAttribute("SlotIndex")
		print(string.format("[PromptDebug][Placement] attempt action=UnlockPrompt player=%s prompt=%s target=%s slotIndex=%s", player.Name, debugInstancePath(promptInstance), debugInstancePath(slotPart), tostring(slotIndex)))
		local ok = tryUnlockSlotFromPrompt(player, slotPart, promptInstance)
		print(string.format("[PromptDebug][Placement] result action=UnlockPrompt player=%s success=%s", player.Name, tostring(ok)))
		return ok
	end

	local placedPart = promptParent
	if placedPart:GetAttribute("IsPlacedMonster") ~= true then
		print(string.format("[PromptDebug][Placement] reject player=%s prompt=%s reason=not_placed_monster parent=%s", player.Name, debugInstancePath(promptInstance), debugInstancePath(placedPart)))
		return false
	end
	if placedPart:GetAttribute("OwnerUserId") ~= player.UserId then
		print(string.format("[PromptDebug][Placement] reject player=%s prompt=%s reason=owner_mismatch owner=%s expected=%s", player.Name, debugInstancePath(promptInstance), tostring(placedPart:GetAttribute("OwnerUserId")), tostring(player.UserId)))
		return false
	end
	if promptInstance.Enabled ~= true then
		print(string.format("[PromptDebug][Placement] reject player=%s prompt=%s reason=prompt_disabled", player.Name, debugInstancePath(promptInstance)))
		return false
	end
	if not isPlayerWithinInteractionDistance(player, placedPart, promptInstance.MaxActivationDistance) then
		print(string.format("[PromptDebug][Placement] reject player=%s prompt=%s reason=distance_check_failed max=%.2f target=%s", player.Name, debugInstancePath(promptInstance), promptInstance.MaxActivationDistance, debugInstancePath(placedPart)))
		return false
	end

	local slotIndex = placedPart:GetAttribute("SlotIndex")
	if type(slotIndex) ~= "number" then
		print(string.format("[PromptDebug][Placement] reject player=%s prompt=%s reason=invalid_slot_index value=%s", player.Name, debugInstancePath(promptInstance), tostring(slotIndex)))
		return false
	end
	local slotPart = HomeService.GetSlotPart(player, slotIndex)
	if not slotPart then
		print(string.format("[PromptDebug][Placement] reject player=%s prompt=%s reason=slot_part_missing slotIndex=%s", player.Name, debugInstancePath(promptInstance), tostring(slotIndex)))
		return false
	end

	if promptInstance.Name == "SellPrompt" then
		print(string.format("[PromptDebug][Placement] attempt action=SellPrompt player=%s prompt=%s target=%s slotIndex=%d", player.Name, debugInstancePath(promptInstance), debugInstancePath(placedPart), slotIndex))
		local ok = trySellPlacedMonster(player, slotPart, placedPart)
		print(string.format("[PromptDebug][Placement] result action=SellPrompt player=%s success=%s", player.Name, tostring(ok)))
		return ok
	end
	if promptInstance.Name == "StorePrompt" then
		print(string.format("[PromptDebug][Placement] attempt action=StorePrompt player=%s prompt=%s target=%s slotIndex=%d", player.Name, debugInstancePath(promptInstance), debugInstancePath(placedPart), slotIndex))
		local ok = tryStorePlacedMonster(player, slotPart, placedPart)
		print(string.format("[PromptDebug][Placement] result action=StorePrompt player=%s success=%s", player.Name, tostring(ok)))
		return ok
	end

	print(string.format("[PromptDebug][Placement] reject player=%s prompt=%s reason=unsupported_prompt_name name=%s", player.Name, debugInstancePath(promptInstance), promptInstance.Name))

	return false
end

return PlacementService
