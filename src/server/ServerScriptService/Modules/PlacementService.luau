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
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))

local Util = require(script.Parent:WaitForChild("Util"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local HomeService = require(script.Parent:WaitForChild("HomeService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))

local PlacementService = {}

local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local playPlacedMonsterJumpRemote = remotesFolder:WaitForChild("PlayPlacedMonsterJump") :: RemoteEvent
local requestStealPlacedGoldRemote = remotesFolder:WaitForChild("RequestStealPlacedGold") :: RemoteEvent
local requestUpgradePlacedMonsterRemote = remotesFolder:WaitForChild("RequestUpgradePlacedMonster") :: RemoteEvent
local stealGoldAvailabilityRemote = remotesFolder:WaitForChild("StealGoldAvailability") :: RemoteEvent
local stealGoldOwnerWarningRemote = remotesFolder:WaitForChild("StealGoldOwnerWarning") :: RemoteEvent
local stealGoldResultRemote = remotesFolder:WaitForChild("StealGoldResult") :: RemoteEvent

------------------------
-- 终极类型安全属性提取器 (彻底消灭 unknown 报错)
local function getNumAttr(inst: Instance, attrName: string, default: number): number
	local val = inst:GetAttribute(attrName)
	if type(val) == "number" then
		return val :: number
	end
	return default
end
------------------------

------------------------
-- 金币单位换算函数
local function formatMoney(amount: number): string
    return Util.FormatMoney(amount)
end

local function getPlayerCashMultiplier(player: Player): number
	local multiplier = PlayerData.GetRebirthMultiplier(player)
	if type(multiplier) ~= "number" then
		return 1
	end
	return math.max(1, math.floor(multiplier))
end

local function getOwnerCashMultiplierFromPlaced(rootPart: BasePart): number
	local ownerUserId = getNumAttr(rootPart, "OwnerUserId", -1)
	local owner = ownerUserId > 0 and Players:GetPlayerByUserId(ownerUserId) or nil
	if owner then
		return getPlayerCashMultiplier(owner)
	end
	return 1
end

local function applyCashMultiplier(amount: number, multiplier: number): number
	return math.floor(amount * math.max(1, multiplier))
end

export type PersistedPlacedMonster = {
  MonsterLevel: number,
  AppearanceLevel: number?,
  Value: number,
  GoldPerSec: number,
  UnclaimedGold: number,
  LastTickUnix: number,
  UpgradeLevel: number?,
  BaseValue: number?,
  BaseGoldPerSec: number?,
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

type StealableTarget = {
	Owner: Player,
	HomeRoot: Instance,
}

type StealableGoldSource = {
	SlotIndex: number,
	SlotPart: BasePart,
	CollectorPart: BasePart?,
	PlacedPart: BasePart,
	State: SlotState,
}

local slotStatesByUserId: {[number]: {[number]: SlotState}} = {}
local lastTouchAt: {[string]: number} = {}
local placementInitStartedByUserId: {[number]: boolean} = {}

local STEAL_AMOUNT = 50
local STEAL_REQUEST_COOLDOWN_SECONDS = 0.2
local STEAL_SETTLE_IDLE_SECONDS = 0.8
local lastStealRequestAtByUserId: {[number]: number} = {}
local lastStealAvailabilityByUserId: {[number]: boolean} = {}
local activeStealWarningByOwnerUserId: {[number]: string?} = {}

type PendingStealSession = {
	Amount: number,
	OwnerUserId: number,
	SlotIndex: number,
	LastStealClock: number,
}

local pendingStealByThiefUserId: {[number]: PendingStealSession} = {}

local DEBUG_UPGRADE_BUTTON = false
local DEBUG_PLACEMENT_GOLD = false
local DEBUG_PLACEMENT_VFX = false
local DEBUG_PLACEMENT_INIT = false

local function debugPrint(enabled: boolean, message: string)
	if enabled then
		print(message)
	end
end

local function debugUpgradeButton(message: string)
	if DEBUG_UPGRADE_BUTTON then
		print("[UpgradeButtonDebug][Server] " .. message)
	end
end

local function getStealAmountForPlayer(player: Player): number
	local stats = PlayerData.Get(player)
	local stealLevel = math.max(0, math.floor(tonumber((stats :: any).StealLevel) or 0))
	if Config.GetStealAmountForLevel then
		return math.max(0, math.floor(tonumber(Config.GetStealAmountForLevel(stealLevel)) or STEAL_AMOUNT))
	end
	return math.max(0, math.floor((Config.STEAL_AMOUNT_BASE or STEAL_AMOUNT) + stealLevel * (Config.STEAL_AMOUNT_PER_UPGRADE or 10)))
end

-- While placed monsters are producing, UnclaimedGold changes every second.
local lastDirtyPulseUnixByUserId: {[number]: number} = {}

local function getClampedMonsterLevel(level: number): number
	return math.max(1, math.floor(tonumber(level) or 1))
end

local function inferAppearanceLevelFromStats(fallbackLevel: number, baseValue: number?, baseGoldPerSec: number?): number
	local fallback = getClampedMonsterLevel(fallbackLevel)
	local gps = if type(baseGoldPerSec) == "number" then math.floor(baseGoldPerSec :: number) else nil
	local value = if type(baseValue) == "number" then math.floor(baseValue :: number) else nil

	local gpsByLevel = Config.MONSTER_GOLD_PER_SEC_BY_LEVEL
	if gps and type(gpsByLevel) == "table" then
		for level, configuredGps in ipairs(gpsByLevel :: {number}) do
			if math.floor(tonumber(configuredGps) or -1) == gps then
				return getClampedMonsterLevel(level)
			end
		end
	end

	local valueByLevel = Config.MONSTER_VALUE_BY_LEVEL
	if value and type(valueByLevel) == "table" then
		for level, configuredValue in ipairs(valueByLevel :: {number}) do
			if math.floor(tonumber(configuredValue) or -1) == value then
				return getClampedMonsterLevel(level)
			end
		end
	end

	return fallback
end

local function getAppearanceLevelFromPlacedData(pData: PersistedPlacedMonster): number
	if type(pData.AppearanceLevel) == "number" then
		return getClampedMonsterLevel(pData.AppearanceLevel :: number)
	end

	return inferAppearanceLevelFromStats(
		pData.MonsterLevel,
		pData.BaseValue or pData.Value,
		pData.BaseGoldPerSec or pData.GoldPerSec
	)
end

-- 这个函数用于把实例转换成便于日志输出的完整路径字符串，方便排查交互问题。
local function debugInstancePath(instance: Instance?): string
	if not instance then
		return "nil"
	end
	local ok, fullName = pcall(function()
		return (instance :: Instance):GetFullName()
	end)
	return ok and fullName or (instance :: Instance).Name
end

-- 解锁提示：只在玩家站在对应地块上方时才显示
local function getHRP(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

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

local function isPlayerStandingOnStealablePosition(thief: Player, slotPart: BasePart, collectorPart: BasePart?): boolean
	if isPlayerStandingOnSlot(thief, slotPart) then
		return true
	end
	if collectorPart and isPlayerStandingOnSlot(thief, collectorPart) then
		return true
	end
	return false
end

local function getHomeBounds(homeRoot: Instance): (Vector3?, Vector3?)
	if homeRoot:IsA("BasePart") then
		local part = homeRoot :: BasePart
		return part.Position, part.Size
	elseif homeRoot:IsA("Model") then
		local model = homeRoot :: Model
		local cf, size = model:GetBoundingBox()
		return cf.Position, size
	end

	local minX = math.huge
	local minY = math.huge
	local minZ = math.huge
	local maxX = -math.huge
	local maxY = -math.huge
	local maxZ = -math.huge
	local foundPart = false

	for _, descendant in ipairs(homeRoot:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local part = descendant :: BasePart
			local halfSize = part.Size * 0.5
			local pos = part.Position
			minX = math.min(minX, pos.X - halfSize.X)
			minY = math.min(minY, pos.Y - halfSize.Y)
			minZ = math.min(minZ, pos.Z - halfSize.Z)
			maxX = math.max(maxX, pos.X + halfSize.X)
			maxY = math.max(maxY, pos.Y + halfSize.Y)
			maxZ = math.max(maxZ, pos.Z + halfSize.Z)
			foundPart = true
		end
	end

	if not foundPart then
		return nil, nil
	end

	local minV = Vector3.new(minX, minY, minZ)
	local maxV = Vector3.new(maxX, maxY, maxZ)
	return (minV + maxV) * 0.5, maxV - minV
end

local function isPlayerStandingInHomeBounds(player: Player, homeRoot: Instance): boolean
	local hrp = getHRP(player)
	if not hrp then
		return false
	end

	local center, size = getHomeBounds(homeRoot)
	if not center or not size then
		return false
	end

	local pos = hrp.Position
	local margin = 3
	local halfX = (size :: Vector3).X * 0.5 + margin
	local halfZ = (size :: Vector3).Z * 0.5 + margin
	local minY = (center :: Vector3).Y - (size :: Vector3).Y * 0.5 - 2
	local maxY = (center :: Vector3).Y + (size :: Vector3).Y * 0.5 + 20

	return math.abs(pos.X - (center :: Vector3).X) <= halfX
		and math.abs(pos.Z - (center :: Vector3).Z) <= halfZ
		and pos.Y >= minY
		and pos.Y <= maxY
end

local function setStealAvailability(player: Player, canSteal: boolean)
	if lastStealAvailabilityByUserId[player.UserId] == canSteal then
		return
	end
	lastStealAvailabilityByUserId[player.UserId] = canSteal
	stealGoldAvailabilityRemote:FireClient(player, canSteal)
end

local function fireStealResult(player: Player, amount: number, mode: string)
	stealGoldResultRemote:FireClient(player, math.max(0, math.floor(amount)), mode)
end

local function settlePendingSteal(thief: Player, _reason: string)
	local pending = pendingStealByThiefUserId[thief.UserId]
	if not pending then
		return
	end

	local amount = math.max(0, math.floor(pending.Amount))
	pendingStealByThiefUserId[thief.UserId] = nil

	if amount > 0 and thief.Parent ~= nil and thief:GetAttribute("__DataLoaded") == true then
		PlayerData.AddRawGold(thief, amount)
		PlayerData.Sync(thief)
		DataDirtyService.MarkDirty(thief)
		fireStealResult(thief, amount, "settled")
	else
		fireStealResult(thief, 0, "cancelled")
	end
end

local function cancelPendingSteal(thief: Player, _reason: string)
	local pending = pendingStealByThiefUserId[thief.UserId]
	if not pending then
		return
	end
	pendingStealByThiefUserId[thief.UserId] = nil
	fireStealResult(thief, 0, "cancelled")
end

-- =====================
-- 怪物收益显示（BillboardGui / SurfaceGui 模板）
-- =====================

local INCOME_DISPLAY_NAME_PREFIX = "怪物收益显示_"
local PLACED_MONSTER_HEAD_DISPLAY_NAME = "PlacedMonsterHeadBillboard"
local PLACED_PROMPT_INITIAL_HIDE_SECONDS = 1
local PLACED_PROMPT_INITIAL_HIDE_UNTIL_ATTR = "PromptInitialHideUntilClock"

local warnedMissingIncomeTemplate = false
type IncomeDisplayGui = BillboardGui | SurfaceGui

local cachedIncomeDisplayTemplate: IncomeDisplayGui? = nil
local cachedPlacedMonsterHeadTemplate: BillboardGui? = nil

local function getPlacedPromptInitialHideRemaining(rootPart: BasePart): number
	local hideUntil = getNumAttr(rootPart, PLACED_PROMPT_INITIAL_HIDE_UNTIL_ATTR, 0)
	return math.max(0, hideUntil - os.clock())
end

local function markPlacedPromptInitialHidden(rootPart: BasePart)
	rootPart:SetAttribute(PLACED_PROMPT_INITIAL_HIDE_UNTIL_ATTR, os.clock() + PLACED_PROMPT_INITIAL_HIDE_SECONDS)
end

local function getPlacedMonsterHeadTemplate(): BillboardGui?
	if cachedPlacedMonsterHeadTemplate then
		return cachedPlacedMonsterHeadTemplate
	end

	for _, desc in ipairs(Workspace:GetDescendants()) do
		if desc.Name == "怪数据显示头顶" then
			local billboard = desc:FindFirstChildWhichIsA("BillboardGui", true)
			if billboard then
				cachedPlacedMonsterHeadTemplate = billboard :: BillboardGui
				return cachedPlacedMonsterHeadTemplate
			end
		end
	end
	return nil
end

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
			template = billboard :: BillboardGui
		else
			local surface = displayPart:FindFirstChildWhichIsA("SurfaceGui", true)
			if surface then
				template = surface :: SurfaceGui
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

local function findIncomeDisplayTextLabel(gui: IncomeDisplayGui): TextLabel?
	local inst = gui :: Instance
	for _, child in ipairs(inst:GetDescendants()) do
		if child:IsA("TextLabel") then
			return child :: TextLabel
		end
	end
	return nil
end

local function setIncomeDisplayText(gui: IncomeDisplayGui, monsterLevel: number?, goldPerSec: number?, unclaimed: number?, value: number?)
	local labelByName: {[string]: TextLabel} = {}
	local allLabels = {}
	local inst = gui :: Instance
	for _, child in ipairs(inst:GetDescendants()) do
		if child:IsA("TextLabel") then
			local t = child :: TextLabel
			labelByName[t.Name] = t
			table.insert(allLabels, t)
		end
	end

	local levelText = monsterLevel == nil and "Not Placed" or string.format("Lv.%d", monsterLevel or 1)
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

local function ensurePlacedMonsterHeadBillboard(rootPart: BasePart): BillboardGui?
	local existing = rootPart:FindFirstChild(PLACED_MONSTER_HEAD_DISPLAY_NAME)
	if existing and existing:IsA("BillboardGui") then
		local b = existing :: BillboardGui
		b.MaxDistance = 100
		b.AlwaysOnTop = true
		b.Enabled = true
		return b
	end

	local template = getPlacedMonsterHeadTemplate()
	if not template then
		return nil
	end

	local clone = (template :: Instance):Clone() :: BillboardGui
	clone.Adornee = rootPart
	clone.Name = PLACED_MONSTER_HEAD_DISPLAY_NAME
	clone.MaxDistance = 100
	clone.AlwaysOnTop = true
	clone.Enabled = true
	clone.Parent = rootPart
	return clone
end

local function setPlacedMonsterHeadBillboardText(rootPart: BasePart)
	local billboard = ensurePlacedMonsterHeadBillboard(rootPart)
	if not billboard then
		return
	end

	local level = math.floor(getNumAttr(rootPart, "UpgradeLevel", getNumAttr(rootPart, "MonsterLevel", 1)))
	local value = math.floor(getNumAttr(rootPart, "Value", 0))
	local goldPerSec = math.floor(getNumAttr(rootPart, "GoldPerSec", 0))

	local bInst = billboard :: Instance
	for _, child in ipairs(bInst:GetDescendants()) do
		if child:IsA("TextLabel") then
			local t = child :: TextLabel
			if t.Name == "lv" then
				t.Text = string.format("[Lv. %d]", level)
			elseif t.Name == "cost" then
				t.Text = formatMoney(value)
			elseif t.Name == "gold" then
				-- 怪物头顶每秒产出显示基础产量；只有领取到账/提示时才乘重生倍率。
				t.Text = string.format("$%s/s", formatMoney(goldPerSec))
			end
		end
	end
end

local function setIncomeDisplayVisibility(gui: IncomeDisplayGui, visible: boolean)
	local inst = gui :: Instance
	if inst:IsA("BillboardGui") then
		local b = gui :: BillboardGui
		b.Enabled = visible
	elseif inst:IsA("SurfaceGui") then
		local s = gui :: SurfaceGui
		s.Enabled = visible
	end
end

local function isSlotCurrentlyVisible(slotPart: BasePart): boolean
	return slotPart:IsDescendantOf(Workspace)
end

local function ensureIncomeDisplayGui(player: Player, slotPart: BasePart, collectorPart: BasePart?): IncomeDisplayGui?
	local anchorPart = collectorPart or slotPart
	if anchorPart.Parent == nil then
		return nil
	end

	local idx = getNumAttr(slotPart, "SlotIndex", 1)
	local name = INCOME_DISPLAY_NAME_PREFIX .. tostring(idx)
	local existing = anchorPart:FindFirstChild(name)
	if existing and (existing:IsA("BillboardGui") or existing:IsA("SurfaceGui")) then
		local gui = existing :: IncomeDisplayGui
		local guiInst = gui :: Instance
		local owner = getNumAttr(guiInst, "OwnerUserId", -1)
		if owner ~= -1 and owner ~= player.UserId then
			guiInst:Destroy()
		elseif findIncomeDisplayTextLabel(gui) then
			guiInst:SetAttribute("OwnerUserId", player.UserId)
			guiInst:SetAttribute("SlotIndex", idx)
			return gui
		else
			guiInst:Destroy()
		end
	end

	local template = getIncomeDisplayTemplate()
	if not template then
		return nil
	end

	local clone = (template :: Instance):Clone() :: IncomeDisplayGui
	local cloneInst = clone :: Instance
	cloneInst.Name = name
	cloneInst:SetAttribute("OwnerUserId", player.UserId)
	cloneInst:SetAttribute("SlotIndex", idx)
	if cloneInst:IsA("SurfaceGui") then
		local s = clone :: SurfaceGui
		s.Adornee = anchorPart
		s.Face = Enum.NormalId.Top
	elseif cloneInst:IsA("BillboardGui") then
		local b = clone :: BillboardGui
		b.Adornee = anchorPart
	end
	cloneInst.Parent = anchorPart
	setIncomeDisplayText(clone, nil, nil, nil, nil)
	return clone
end

local function refreshIncomeDisplayForSlot(player: Player, slotPart: BasePart, collectorPart: BasePart?, placed: BasePart?)
	if not collectorPart then return end
	
	local displayModel = collectorPart:FindFirstChild("收益显示", true)
	if not displayModel then return end
	
	local costLabel = displayModel:FindFirstChild("升级所需金币", true)
	local levelLabel = displayModel:FindFirstChild("当前等级→下一等级", true)
	local unclaimedLabel = displayModel:FindFirstChild("03当前未领取收益", true) or displayModel:FindFirstChild("当前未领取收益", true)

	if not placed or placed.Parent == nil then
		if costLabel and costLabel:IsA("TextLabel") then (costLabel :: TextLabel).Text = "Not Placed" end
		if levelLabel and levelLabel:IsA("TextLabel") then (levelLabel :: TextLabel).Text = "" end
		if unclaimedLabel and unclaimedLabel:IsA("TextLabel") then (unclaimedLabel :: TextLabel).Text = "0" end
	else
		local activePm = placed :: BasePart
		local upLevel = getNumAttr(activePm, "UpgradeLevel", 1)
		local baseGps = getNumAttr(activePm, "BaseGoldPerSec", getNumAttr(activePm, "GoldPerSec", 0))
		local upgradeCost = upLevel * 100 * baseGps
		-- 收益牌显示“基础未领取金额”。
		-- 实际领取到账、Toast、addGoldUI 仍由 PlayerData.AddGold 按重生倍率计算。
		local unclaimed = math.floor(getNumAttr(activePm, "UnclaimedGold", 0))

		if costLabel and costLabel:IsA("TextLabel") then (costLabel :: TextLabel).Text = "$" .. formatMoney(upgradeCost) end
		if levelLabel and levelLabel:IsA("TextLabel") then (levelLabel :: TextLabel).Text = string.format("LV.%d ▶ LV.%d", upLevel, upLevel + 1) end
		if unclaimedLabel and unclaimedLabel:IsA("TextLabel") then
			(unclaimedLabel :: TextLabel).Text = "$" .. formatMoney(unclaimed)
		end
	end
end

local function toast(player: Player, text: string)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ev = remotes and remotes:FindFirstChild("PushClientToast")
	if ev and ev:IsA("RemoteEvent") then
		ev:FireClient(player, text)
	end
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

local function stripJointsAndConstraints(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("Constraint") then
			d:Destroy()
		end
	end
end

local function prepareAppearanceParts(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			local bp = d :: BasePart
			bp.Anchored = false
			bp.CanCollide = false
			bp.CanTouch = false
			bp.CanQuery = false
			bp.Massless = true
		end
	end
end

local function weldPartsToAnchor(anchorPart: BasePart, root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and d ~= anchorPart then
			local bp = d :: BasePart
			local w = Instance.new("Weld") :: Weld
			w.Part0 = anchorPart
			w.Part1 = bp
			w.C0 = anchorPart.CFrame:Inverse() * bp.CFrame
			w.Parent = bp
		end
	end
end

local function weldAnchorToRoot(rootPart: BasePart, anchorPart: BasePart)
	anchorPart.Anchored = false
	anchorPart.CanCollide = false
	anchorPart.CanTouch = false
	anchorPart.CanQuery = false
	anchorPart.Massless = true

	local w = Instance.new("Weld") :: Weld
	w.Part0 = rootPart
	w.Part1 = anchorPart
	w.C0 = rootPart.CFrame:Inverse() * anchorPart.CFrame
	w.Parent = anchorPart
end

local function sanitizePlacementRoot(inst: Instance): BasePart?
	if inst:IsA("Model") then
		local m = inst :: Model
		local root = m.PrimaryPart
			or (m:FindFirstChild("HumanoidRootPart", true) :: BasePart?)
			or (m:FindFirstChild("UpperTorso", true) :: BasePart?)
			or (m:FindFirstChild("Torso", true) :: BasePart?)
			or m:FindFirstChildWhichIsA("BasePart", true)
		if root then
			m.PrimaryPart = root
		end
		return root
	elseif inst:IsA("BasePart") then
		return inst :: BasePart
	end
	return nil
end

local function findPlacementTemplateRootPart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst :: BasePart
	end

	if inst:IsA("Model") then
		local m = inst :: Model
		local sameName = m:FindFirstChild(m.Name)
		if sameName and sameName:IsA("BasePart") then
			return sameName :: BasePart
		end
		local deepSameName = m:FindFirstChild(m.Name, true)
		if deepSameName and deepSameName:IsA("BasePart") then
			return deepSameName :: BasePart
		end
		return m.PrimaryPart
			or (m:FindFirstChild("HumanoidRootPart", true) :: BasePart?)
			or (m:FindFirstChild("UpperTorso", true) :: BasePart?)
			or (m:FindFirstChild("Torso", true) :: BasePart?)
			or m:FindFirstChildWhichIsA("BasePart", true)
	end

	if inst:IsA("Folder") then
		local f = inst :: Folder
		local sameName = f:FindFirstChild(f.Name)
		if sameName and sameName:IsA("BasePart") then
			return sameName :: BasePart
		end
		local deepSameName = f:FindFirstChild(f.Name, true)
		if deepSameName and deepSameName:IsA("BasePart") then
			return deepSameName :: BasePart
		end
		return f:FindFirstChildWhichIsA("BasePart", true)
	end

	return nil
end

local function moveHierarchyToTarget(root: BasePart, rootInstance: Instance, targetCFrame: CFrame)
	local delta = targetCFrame * root.CFrame:Inverse()
	for _, d in ipairs(rootInstance:GetDescendants()) do
		if d:IsA("BasePart") then
			local bp = d :: BasePart
			bp.CFrame = delta * bp.CFrame
		end
	end
	root.CFrame = targetCFrame
end

local function getPlatformAlignedPlacementCFrame(slotPart: BasePart, yOffset: number): CFrame
	local pos = slotPart.Position + Vector3.new(0, yOffset, 0)
	return CFrame.fromMatrix(pos, slotPart.CFrame.XVector, slotPart.CFrame.YVector, slotPart.CFrame.ZVector)
end

local function getPlacementTemplateRootInfo(monsterLevel: number): (Instance?, BasePart?)
	local template = getMonsterAppearanceTemplate(monsterLevel)
	if not template then
		return nil, nil
	end
	return template, findPlacementTemplateRootPart(template)
end

local function toModelLike(inst: Instance): (Model?, BasePart?)
	if inst:IsA("Model") then
		return inst :: Model, nil
	end
	if inst:IsA("BasePart") then
		return nil, inst :: BasePart
	end
	if inst:IsA("Folder") then
		local m = Instance.new("Model") :: Model
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

local placedMonsterJumping: {[BasePart]: boolean} = {}

local function getPlacedMonsterPivot(rootPart: BasePart): CFrame
	local container = getPlacedMonsterContainer(rootPart)
	if container:IsA("Model") then
		return (container :: Model):GetPivot()
	elseif container:IsA("BasePart") then
		return (container :: BasePart).CFrame
	end
	return rootPart.CFrame
end

local function pivotPlacedMonster(rootPart: BasePart, targetCFrame: CFrame)
	local container = getPlacedMonsterContainer(rootPart)
	if container:IsA("Model") then
		(container :: Model):PivotTo(targetCFrame)
	elseif container:IsA("BasePart") then
		(container :: BasePart).CFrame = targetCFrame
	else
		rootPart.CFrame = targetCFrame
	end
end

local function playPlacedMonsterJump(rootPart: BasePart)
	if placedMonsterJumping[rootPart] then
		return
	end
	placedMonsterJumping[rootPart] = true

	task.spawn(function()
		if rootPart.Parent == nil then
			placedMonsterJumping[rootPart] = nil
			return
		end

		local originalCFrame = getPlacedMonsterPivot(rootPart)
		local peakCFrame = originalCFrame * CFrame.new(0, 2, 0)
		local cframeValue = Instance.new("CFrameValue")
		cframeValue.Value = originalCFrame

		local conn = cframeValue:GetPropertyChangedSignal("Value"):Connect(function()
			if rootPart.Parent ~= nil then
				pivotPlacedMonster(rootPart, cframeValue.Value)
			end
		end)

		local tween = TweenService:Create(
			cframeValue,
			TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true),
			{ Value = peakCFrame }
		)

		tween:Play()
		tween.Completed:Wait()
		conn:Disconnect()
		cframeValue:Destroy()

		if rootPart.Parent ~= nil then
			pivotPlacedMonster(rootPart, originalCFrame)
		end
		placedMonsterJumping[rootPart] = nil
	end)
end

local function requestPlacedMonsterJump(player: Player, rootPart: BasePart)
	-- 收钱后的怪物跳跃只是表现动画，不参与金币结算。
	-- 改为只通知领取收益的玩家客户端本地播放，避免服务端 Tween 每帧同步模型位置造成卡顿。
	if rootPart.Parent == nil then
		return
	end

	playPlacedMonsterJumpRemote:FireClient(player, rootPart)
end

local function destroyPlacedMonster(rootPart: BasePart)
	getPlacedMonsterContainer(rootPart):Destroy()
end

local function createPlacedMonsterFromTemplate(slotPart: BasePart, monsterLevel: number): BasePart?
	local template = getMonsterAppearanceTemplate(monsterLevel)
	if not template then
		return nil
	end

	local targetCFrame = getPlatformAlignedPlacementCFrame(slotPart, 2)
	local clone = (template :: Instance):Clone()
	local cloneInst = clone :: Instance
	local model, part = toModelLike(cloneInst)
	local rootPart: BasePart? = nil
	local container: Instance = cloneInst

	if model then
		rootPart = findPlacementTemplateRootPart(model)
		if not rootPart then
			cloneInst:Destroy()
			return nil
		end

		model.PrimaryPart = rootPart

		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				local bp = d :: BasePart
				bp.Anchored = true
			end
		end

		model:PivotTo(targetCFrame)
		moveHierarchyToTarget(rootPart, model, targetCFrame)
		container = model
	elseif part then
		-- 用一个确定的 bp 变量来避免 rootPart 可选类型引发的警告
		local bp = part :: BasePart
		rootPart = bp
		bp.Anchored = true
		bp.CFrame = targetCFrame
		container = bp
	else
		cloneInst:Destroy()
		return nil
	end

	container:SetAttribute("IsPlacedMonsterContainer", true)
	container.Parent = slotPart.Parent
	return rootPart
end

local function applyMonsterAppearanceToPlacedPart(rootPart: BasePart, monsterLevel: number)
	local template = getMonsterAppearanceTemplate(monsterLevel)
	if not template then
		return
	end

	if not (template:IsA("Model") or template:IsA("BasePart") or template:IsA("Folder")) then
		return
	end

	local old = rootPart:FindFirstChild("Appearance")
	if old then
		old:Destroy()
	end

	local appearanceFolder = Instance.new("Folder") :: Folder
	appearanceFolder.Name = "Appearance"
	appearanceFolder.Parent = rootPart

	local clone = (template :: Instance):Clone()
	local cloneInst = clone :: Instance
	cloneInst.Parent = appearanceFolder

	stripJointsAndConstraints(cloneInst)
	prepareAppearanceParts(cloneInst)

	local model, part = toModelLike(cloneInst)
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
		local bp = part :: BasePart
		bp.CFrame = rootPart.CFrame
		bp.Anchored = false
		bp.CanCollide = false
		bp.CanTouch = false
		bp.CanQuery = false
		bp.Massless = true

		weldPartsToAnchor(bp, bp)
		weldAnchorToRoot(rootPart, bp)
		applied = true
	end

	rootPart.Transparency = if applied then 1 else 0
end

local function getUnlockCost(slotIndex: number): number
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

local function ensureState(player: Player): {[number]: SlotState}
	local m = slotStatesByUserId[player.UserId]
	if type(m) == "table" then
		return m :: {[number]: SlotState}
	end

	local newM: {[number]: SlotState} = {}
	for i = 1, 30 do
		newM[i] = {
			Unlocked = true,
			PlacedMonster = nil,
			PlacedData = nil,
		}
	end
	slotStatesByUserId[player.UserId] = newM
	return newM
end

local function canUseSlotByHomeLevel(player: Player, slotIndex: number): boolean
	local homeLevel = PlayerData.GetHomeLevel(player)
	return slotIndex <= homeLevel * 10
end

local function isPrevUnlocked(player: Player, slotIndex: number): boolean
	if slotIndex <= 1 then
		return true
	end
	local stateMap = ensureState(player)
	local st = stateMap[slotIndex - 1]
	return st ~= nil and st.Unlocked == true
end

local function addUnclaimedToPlayer(player: Player, placed: BasePart): number
	local un = getNumAttr(placed, "UnclaimedGold", 0)
	if un <= 0 then
		return 0
	end
	local idx = getNumAttr(placed, "SlotIndex", 1)
	local unBase = math.floor(un)
	local multiplier = getPlayerCashMultiplier(player)
	local expectedAdded = applyCashMultiplier(unBase, multiplier)
	placed:SetAttribute("UnclaimedGold", 0)
	local added = PlayerData.AddGold(player, unBase)
	PlayerData.Sync(player)

	debugPrint(DEBUG_PLACEMENT_GOLD, string.format(
		"[PlacementGoldDebug] collect player=%s slot=%d unclaimedBase=%d multiplier=x%d expectedAdded=%d actualAdded=%d",
		player.Name,
		idx,
		unBase,
		multiplier,
		expectedAdded,
		added
	))

	local states = ensureState(player)
	local st = states[idx]
	if st and st.PlacedData then
		st.PlacedData.UnclaimedGold = 0
	end

	DataDirtyService.MarkDirty(player)
	return added
end

local function findStealableTargetForPlayer(thief: Player): StealableTarget?
	if thief:GetAttribute("__DataLoaded") ~= true then
		return nil
	end

	for _, owner in ipairs(Players:GetPlayers()) do
		if owner ~= thief and owner:GetAttribute("__DataLoaded") == true then
			local home = HomeService.GetHome(owner)
			if home and isPlayerStandingInHomeBounds(thief, home.HomeRoot) then
				return {
					Owner = owner,
					HomeRoot = home.HomeRoot,
				}
			end
		end
	end

	return nil
end

local function findStealableGoldSourceForOwner(owner: Player): StealableGoldSource?
	local home = HomeService.GetHome(owner)
	local states = slotStatesByUserId[owner.UserId]
	if not home or type(states) ~= "table" then
		return nil
	end

	local safeStates = states :: {[number]: SlotState}
	for _, slot in ipairs(home.Slots) do
		local state = safeStates[slot.Index]
		local placed = state and state.PlacedMonster
		if placed and placed.Parent and placed:GetAttribute("IsPlacedMonster") == true then
			local activePlaced = placed :: BasePart
			if getNumAttr(activePlaced, "OwnerUserId", -1) == owner.UserId and getNumAttr(activePlaced, "UnclaimedGold", 0) > 0 then
				return {
					SlotIndex = slot.Index,
					SlotPart = slot.Part,
					CollectorPart = slot.Collector,
					PlacedPart = activePlaced,
					State = state,
				}
			end
		end
	end

	return nil
end

local function refreshStealAvailabilityAndWarnings()
	local ownerToThiefName: {[number]: string} = {}

	for _, thief in ipairs(Players:GetPlayers()) do
		local target = findStealableTargetForPlayer(thief)
		setStealAvailability(thief, target ~= nil)
		if target then
			ownerToThiefName[target.Owner.UserId] = thief.Name
		end
	end

	for _, owner in ipairs(Players:GetPlayers()) do
		local thiefName = ownerToThiefName[owner.UserId]
		local previousName = activeStealWarningByOwnerUserId[owner.UserId]
		if thiefName and previousName ~= thiefName then
			activeStealWarningByOwnerUserId[owner.UserId] = thiefName
			stealGoldOwnerWarningRemote:FireClient(owner, true, thiefName)
		elseif not thiefName and previousName ~= nil then
			activeStealWarningByOwnerUserId[owner.UserId] = nil
			stealGoldOwnerWarningRemote:FireClient(owner, false)
		end
	end
end

local function processPendingStealSettlements()
	local now = os.clock()
	for _, thief in ipairs(Players:GetPlayers()) do
		local pending = pendingStealByThiefUserId[thief.UserId]
		if pending then
			local target = findStealableTargetForPlayer(thief)
			if not target then
				settlePendingSteal(thief, "left_home")
			elseif target.Owner.UserId ~= pending.OwnerUserId then
				settlePendingSteal(thief, "target_changed")
			elseif now - pending.LastStealClock >= STEAL_SETTLE_IDLE_SECONDS then
				settlePendingSteal(thief, "idle")
			end
		end
	end
end

function PlacementService.CancelPendingStealIfOwnerHit(thief: Player, owner: Player): boolean
	local pending = pendingStealByThiefUserId[thief.UserId]
	if pending and pending.OwnerUserId == owner.UserId then
		cancelPendingSteal(thief, "owner_hit")
		return true
	end
	return false
end

function PlacementService.TryStealGold(thief: Player): number
	if thief:GetAttribute("__DataLoaded") ~= true then
		return 0
	end

	local now = os.clock()
	local last = lastStealRequestAtByUserId[thief.UserId] or 0
	if now - last < STEAL_REQUEST_COOLDOWN_SECONDS then
		return 0
	end
	lastStealRequestAtByUserId[thief.UserId] = now

	local target = findStealableTargetForPlayer(thief)
	if not target then
		settlePendingSteal(thief, "no_target")
		setStealAvailability(thief, false)
		return 0
	end

	local pending = pendingStealByThiefUserId[thief.UserId]
	if pending and pending.OwnerUserId ~= target.Owner.UserId then
		settlePendingSteal(thief, "target_changed")
		pending = nil
	end

	local source = findStealableGoldSourceForOwner(target.Owner)
	if not source then
		toast(thief, "Not enough coins") --当前没钱
		setStealAvailability(thief, true)
		return 0
	end

	local un = math.floor(getNumAttr(source.PlacedPart, "UnclaimedGold", 0))
	if un <= 0 then
		toast(thief, "Not enough coins") --当前没钱
		setStealAvailability(thief, true)
		return 0
	end

	local stealAmount = getStealAmountForPlayer(thief)
	if stealAmount <= 0 then
		return 0
	end

	local stolen = math.min(stealAmount, un)
	local remaining = un - stolen
	local nowUnix = os.time()

	source.PlacedPart:SetAttribute("UnclaimedGold", remaining)
	source.PlacedPart:SetAttribute("LastTickUnix", nowUnix)

	if source.State.PlacedData then
		source.State.PlacedData.UnclaimedGold = remaining
		source.State.PlacedData.LastTickUnix = nowUnix
	end

	if not pending then
		pending = {
			Amount = 0,
			OwnerUserId = target.Owner.UserId,
			SlotIndex = source.SlotIndex,
			LastStealClock = now,
		}
		pendingStealByThiefUserId[thief.UserId] = pending
	end
	pending.Amount += stolen
	pending.LastStealClock = now
	fireStealResult(thief, stolen, "progress")

	refreshIncomeDisplayForSlot(target.Owner, source.SlotPart, source.CollectorPart, source.PlacedPart)
	DataDirtyService.MarkDirty(target.Owner)

	if remaining > 0 then
		stealGoldOwnerWarningRemote:FireClient(target.Owner, true, thief.Name)
		activeStealWarningByOwnerUserId[target.Owner.UserId] = thief.Name
	else
		stealGoldOwnerWarningRemote:FireClient(target.Owner, false)
		activeStealWarningByOwnerUserId[target.Owner.UserId] = nil
	end
	-- 只要玩家仍在可偷目标家中，就保持偷取按钮显示。
	-- 如果本次刚好把当前未领取金币偷到 0，立刻发 false 会让客户端按钮短暂消失；
	-- 后台范围刷新随后又会发 true，造成“点着点着消失 0.x 秒又出现”的闪烁。
	-- 真正离开目标/不可偷时，前面的 no_target 分支和定时刷新仍会负责隐藏按钮。
	setStealAvailability(thief, true)
	return stolen
end

local function isPlayerWithinInteractionDistance(player: Player, targetPart: BasePart, maxDistance: number?): boolean
	local hrp = getHRP(player)
	if not hrp then
		return false
	end
	local allowed = maxDistance or 10
	return (hrp.Position - targetPart.Position).Magnitude <= (allowed + 2)
end

local function trySellPlacedMonster(player: Player, slotPart: BasePart, placedPart: BasePart): boolean
	if placedPart.Parent == nil then return false end
	if placedPart:GetAttribute("IsPlacedMonster") ~= true then return false end
	if getNumAttr(placedPart, "OwnerUserId", -1) ~= player.UserId then return false end
	if placedPart:GetAttribute("__InteractionLocked") == true then return false end
	if getPlacedPromptInitialHideRemaining(placedPart) > 0 then return false end

	placedPart:SetAttribute("__InteractionLocked", true)
	addUnclaimedToPlayer(player, placedPart)

	local val = getNumAttr(placedPart, "Value", 0)
	local actualSoldGold = PlayerData.AddGold(player, val)
	PlayerData.Sync(player)

	local idx = getNumAttr(slotPart, "SlotIndex", 1)
	local stateMap = ensureState(player)
	local st = stateMap[idx]
	if st then
		st.PlacedData = nil
	end

	DataDirtyService.MarkDirty(player, 5)

	local home = HomeService.GetHome(player)
	if home then
		local slot = HomeService.GetSlot(player, idx)
		refreshIncomeDisplayForSlot(player, slotPart, slot and slot.Collector or nil, nil)
	end

	toast(player, string.format("Sold for %d Gold", actualSoldGold))
	destroyPlacedMonster(placedPart)
	return true
end

local function tryStorePlacedMonster(player: Player, slotPart: BasePart, placedPart: BasePart): boolean
	if placedPart.Parent == nil then return false end
	if placedPart:GetAttribute("IsPlacedMonster") ~= true then return false end
	if getNumAttr(placedPart, "OwnerUserId", -1) ~= player.UserId then return false end
	if placedPart:GetAttribute("__InteractionLocked") == true then return false end
	if getPlacedPromptInitialHideRemaining(placedPart) > 0 then return false end

	placedPart:SetAttribute("__InteractionLocked", true)
	addUnclaimedToPlayer(player, placedPart)

	local lvl = getNumAttr(placedPart, "MonsterLevel", 1)
	local v = getNumAttr(placedPart, "Value", 0)
	local gps = getNumAttr(placedPart, "GoldPerSec", 0)
	local upLevel = getNumAttr(placedPart, "UpgradeLevel", 1)
	local baseV = getNumAttr(placedPart, "BaseValue", v)
	local baseGps = getNumAttr(placedPart, "BaseGoldPerSec", gps)
	local sourceZoneLevel = getNumAttr(placedPart, "SourceZoneLevel", 1)
	
	local ok = InventoryService.TryAddMonsterItem(player, lvl, v, gps, upLevel, baseV, baseGps, sourceZoneLevel)
	if not ok then
		placedPart:SetAttribute("__InteractionLocked", false)
		return false
	end

	local idx = getNumAttr(slotPart, "SlotIndex", 1)
	local stateMap = ensureState(player)
	local st = stateMap[idx]
	if st then
		st.PlacedData = nil
	end

	DataDirtyService.MarkDirty(player, 5)

	local home = HomeService.GetHome(player)
	if home then
		local slot = HomeService.GetSlot(player, idx)
		refreshIncomeDisplayForSlot(player, slotPart, slot and slot.Collector or nil, nil)
	end

	toast(player, "Collected to Backpack")
	destroyPlacedMonster(placedPart)
	return true
end

local updateUnlockPromptEnabled

local function tryUnlockSlotFromPrompt(player: Player, slotPart: BasePart, prompt: ProximityPrompt): boolean
	if player:GetAttribute("__DataLoaded") ~= true then
		return false
	end

	local rawIdx = slotPart:GetAttribute("SlotIndex")
	if type(rawIdx) ~= "number" then return false end
	local idx = rawIdx :: number

	if not isPlayerWithinInteractionDistance(player, slotPart, prompt.MaxActivationDistance) then
		return false
	end

	if not canUseSlotByHomeLevel(player, idx) then
		toast(player, "Upgrade your home to unlock this area")
		updateUnlockPromptEnabled(player, slotPart)
		return false
	end

	if not isPrevUnlocked(player, idx) then
		toast(player, "Unlock the previous placement area first")
		updateUnlockPromptEnabled(player, slotPart)
		return false
	end

	local stateMap = ensureState(player)
	local state = stateMap[idx]
	if not state then return false end
	
	if state.Unlocked then
		prompt.Enabled = false
		return false
	end

	local cost = getUnlockCost(idx)
	if not PlayerData.TrySpendGold(player, cost) then
		toast(player, string.format("Not enough gold. Need %d", cost))
		return false
	end

	state.Unlocked = true
	PlayerData.Sync(player)
	DataDirtyService.MarkDirty(player, 5)
	prompt.Enabled = false
	toast(player, string.format("Unlocked: Area %d", idx))

	updateUnlockPromptEnabled(player, slotPart)
	local nextSlot = HomeService.GetSlotPart(player, idx + 1)
	if nextSlot then
		updateUnlockPromptEnabled(player, nextSlot)
	end

	return true
end

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
		p:SetAttribute("SlotIndex", getNumAttr(slotPart, "SlotIndex", 1))
		p:SetAttribute("MonsterLevel", monsterLevel)
		p:SetAttribute("AppearanceLevel", monsterLevel)
		p:SetAttribute("Value", value)
		p:SetAttribute("GoldPerSec", goldPerSec)
		p:SetAttribute("UnclaimedGold", unclaimedGold or 0)
		p:SetAttribute("LastTickUnix", lastTickUnix or os.time())

		setPlacedMonsterHeadBillboardText(p)

		local function setPlacedMonsterPromptVisible(visible: boolean)
			if visible and getPlacedPromptInitialHideRemaining(p) > 0 then
				visible = false
			end
			local sellPrompt = p:FindFirstChild("SellPrompt")
			if sellPrompt and sellPrompt:IsA("ProximityPrompt") then
				local sp = sellPrompt :: ProximityPrompt
				sp.Enabled = visible
			end
			local storePrompt = p:FindFirstChild("StorePrompt")
			if storePrompt and storePrompt:IsA("ProximityPrompt") then
				local stp = storePrompt :: ProximityPrompt
				stp.Enabled = visible
			end
		end

		local function revealPlacedMonsterPrompts(showSeconds: number?)
			local token = getNumAttr(p, "PromptRevealToken", 0) + 1
			p:SetAttribute("PromptRevealToken", token)

			local hideRemaining = getPlacedPromptInitialHideRemaining(p)
			if hideRemaining > 0 then
				setPlacedMonsterPromptVisible(false)
				task.delay(hideRemaining, function()
					if p.Parent == nil then return end
					if getNumAttr(p, "PromptRevealToken", 0) ~= token then return end
					revealPlacedMonsterPrompts(showSeconds)
				end)
				return
			end

			setPlacedMonsterPromptVisible(true)

			task.delay(showSeconds or 3, function()
				if p.Parent == nil then return end
				if getNumAttr(p, "PromptRevealToken", 0) ~= token then return end
				setPlacedMonsterPromptVisible(false)
			end)
		end

		p:GetAttributeChangedSignal("TriggerPromptReveal"):Connect(function()
			revealPlacedMonsterPrompts(3)
		end)

		local sell = Instance.new("ProximityPrompt") :: ProximityPrompt
		sell.Name = "SellPrompt"
		sell.ActionText = "Sell"
		sell.ObjectText = "Sell Brainrot"
		sell.KeyboardKeyCode = Enum.KeyCode.E
		sell.HoldDuration = 0.2
		sell.MaxActivationDistance = 10
		sell.RequiresLineOfSight = false
		sell.UIOffset = Vector2.new(0, 0)
		sell.Enabled = false
		sell.Parent = p

		sell.Triggered:Connect(function(triggerPlayer: Player)
			if player:GetAttribute("__DataLoaded") ~= true then return end
			if triggerPlayer.UserId ~= player.UserId then return end
			trySellPlacedMonster(player, slotPart, p)
		end)

		local store = Instance.new("ProximityPrompt") :: ProximityPrompt
		store.Name = "StorePrompt"
		store.ActionText = "Collect"
		store.ObjectText = "Add to Inventory"
		store.KeyboardKeyCode = Enum.KeyCode.R
		store.HoldDuration = 0.6
		store.MaxActivationDistance = 10
		store.RequiresLineOfSight = false
		store.UIOffset = Vector2.new(0, 70)
		store.Enabled = false
		store.Parent = p

		store.Triggered:Connect(function(triggerPlayer: Player)
			if player:GetAttribute("__DataLoaded") ~= true then return end
			if triggerPlayer.UserId ~= player.UserId then return end
			tryStorePlacedMonster(player, slotPart, p)
		end)

		-- 不再通过点击怪物或 Collector 显示 Sell/Collect；只允许站到 Platform/放置区域时触发显示。
		local container = getPlacedMonsterContainer(p)

		container.Destroying:Connect(function()
			local m = slotStatesByUserId[player.UserId]
			if type(m) ~= "table" then return end
			local safeM = m :: {[number]: SlotState}
			local idx = getNumAttr(slotPart, "SlotIndex", -1)
			if idx == -1 then return end
			local st = safeM[idx]
			if st and st.PlacedMonster == p then
				st.PlacedMonster = nil
			end
		end)

		return p
	end

	local _, templateRoot = getPlacementTemplateRootInfo(monsterLevel)
	local rootSize = Vector3.new(3, 4, 3)
	if templateRoot then
		rootSize = (templateRoot :: BasePart).Size
	end

	local rootCFrame = getPlatformAlignedPlacementCFrame(slotPart, slotPart.Size.Y * 0.5 + rootSize.Y * 0.5 + 2)

	local p = Instance.new("Part") :: Part
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
	p:SetAttribute("SlotIndex", getNumAttr(slotPart, "SlotIndex", 1))
	p:SetAttribute("MonsterLevel", monsterLevel)
	p:SetAttribute("AppearanceLevel", monsterLevel)
	p:SetAttribute("Value", value)
	p:SetAttribute("GoldPerSec", goldPerSec)
	p:SetAttribute("UnclaimedGold", unclaimedGold or 0)
	p:SetAttribute("LastTickUnix", lastTickUnix or os.time())

	applyMonsterAppearanceToPlacedPart(p, monsterLevel)
	setPlacedMonsterHeadBillboardText(p)

	local function setPlacedMonsterPromptVisible(visible: boolean)
		if visible and getPlacedPromptInitialHideRemaining(p) > 0 then
			visible = false
		end
		local sellPrompt = p:FindFirstChild("SellPrompt")
		if sellPrompt and sellPrompt:IsA("ProximityPrompt") then
			local sp = sellPrompt :: ProximityPrompt
			sp.Enabled = visible
		end
		local storePrompt = p:FindFirstChild("StorePrompt")
		if storePrompt and storePrompt:IsA("ProximityPrompt") then
			local stp = storePrompt :: ProximityPrompt
			stp.Enabled = visible
		end
	end

	local function revealPlacedMonsterPrompts(showSeconds: number?)
		local token = getNumAttr(p, "PromptRevealToken", 0) + 1
		p:SetAttribute("PromptRevealToken", token)

		local hideRemaining = getPlacedPromptInitialHideRemaining(p)
		if hideRemaining > 0 then
			setPlacedMonsterPromptVisible(false)
			task.delay(hideRemaining, function()
				if p.Parent == nil then return end
				if getNumAttr(p, "PromptRevealToken", 0) ~= token then return end
				revealPlacedMonsterPrompts(showSeconds)
			end)
			return
		end

		setPlacedMonsterPromptVisible(true)

		task.delay(showSeconds or 3, function()
			if p.Parent == nil then return end
			if getNumAttr(p, "PromptRevealToken", 0) ~= token then return end
			setPlacedMonsterPromptVisible(false)
		end)
	end

	p:GetAttributeChangedSignal("TriggerPromptReveal"):Connect(function()
		revealPlacedMonsterPrompts(3)
	end)

	local sell = Instance.new("ProximityPrompt") :: ProximityPrompt
	sell.Name = "SellPrompt"
	sell.ActionText = "Sell"
	sell.ObjectText = "Placed Monster"
	sell.KeyboardKeyCode = Enum.KeyCode.E
	sell.HoldDuration = 0.2
	sell.MaxActivationDistance = 10
	sell.RequiresLineOfSight = false
	sell.UIOffset = Vector2.new(0, 0)
	sell.Enabled = false
	sell.Parent = p

	sell.Triggered:Connect(function(triggerPlayer: Player)
		if player:GetAttribute("__DataLoaded") ~= true then return end
		if triggerPlayer.UserId ~= player.UserId then return end
		trySellPlacedMonster(player, slotPart, p)
	end)

	local store = Instance.new("ProximityPrompt") :: ProximityPrompt
	store.Name = "StorePrompt"
	store.ActionText = "Collect"
	store.ObjectText = "Placed Monster"
	store.KeyboardKeyCode = Enum.KeyCode.R
	store.HoldDuration = 0.6
	store.MaxActivationDistance = 10
	store.RequiresLineOfSight = false
	store.UIOffset = Vector2.new(0, 50)
	store.Enabled = false
	store.Parent = p

	store.Triggered:Connect(function(triggerPlayer: Player)
		if player:GetAttribute("__DataLoaded") ~= true then return end
		if triggerPlayer.UserId ~= player.UserId then return end
		tryStorePlacedMonster(player, slotPart, p)
	end)

	-- 不再通过点击怪物或 Collector 显示 Sell/Collect；只允许站到 Platform/放置区域时触发显示。

	p.Destroying:Connect(function()
		local m = slotStatesByUserId[player.UserId]
		if type(m) ~= "table" then return end
		local safeM = m :: {[number]: SlotState}
		local idx = getNumAttr(slotPart, "SlotIndex", -1)
		if idx == -1 then return end
		local st = safeM[idx]
		if st and st.PlacedMonster == p then
			st.PlacedMonster = nil
		end
	end)

	return p
end

local function findPlacementVfxTemplate(): Instance?
	-- 兼容几种常见摆放方式：
	-- 1) Workspace.放置特效.放置特效01
	-- 2) Workspace 任意层级下的 放置特效01
	-- 3) Workspace 任意层级下的 放置特效（本身就是模板）
	local namedTemplate = Workspace:FindFirstChild("放置特效01", true)
	if namedTemplate then
		return namedTemplate
	end

	local vfxRoot = Workspace:FindFirstChild("放置特效", true)
	if not vfxRoot then
		return nil
	end

	local nestedTemplate = vfxRoot:FindFirstChild("放置特效01", true)
	if nestedTemplate then
		return nestedTemplate
	end

	return vfxRoot
end

local function createPlacementVfxAnchor(targetCFrame: CFrame): Part
    local anchor = Instance.new("Part") :: Part
    anchor.Name = "PlacementVFXAnchor"
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanTouch = false
    anchor.CanQuery = false
    anchor.Transparency = 1
    anchor.Size = Vector3.new(1, 1, 1)
    anchor.CFrame = targetCFrame
    anchor.Parent = Workspace
    return anchor
end

local function movePlacementVfxFolderToCFrame(folder: Folder, targetCFrame: CFrame)
    local rootPart = folder:FindFirstChildWhichIsA("BasePart", true)
    if rootPart then
        moveHierarchyToTarget(rootPart :: BasePart, folder, targetCFrame)
    end
end

local function normalizeLoosePlacementVfxObjects(root: Instance, anchor: BasePart)
	local looseAttachments: {Attachment} = {}
	local looseEmitters: {ParticleEmitter} = {}

	for _, desc in ipairs(root:GetDescendants()) do
		if desc:IsA("Attachment") then
			local parent = desc.Parent
			if not (parent and (parent:IsA("BasePart") or parent:IsA("Terrain"))) then
				table.insert(looseAttachments, desc :: Attachment)
			end
		elseif desc:IsA("ParticleEmitter") then
			local parent = desc.Parent
			if not (parent and (parent:IsA("Attachment") or parent:IsA("BasePart"))) then
				table.insert(looseEmitters, desc :: ParticleEmitter)
			end
		end
	end

	for _, attachment in ipairs(looseAttachments) do
		if attachment.Parent then
			attachment.Parent = anchor
		end
	end

	for _, emitter in ipairs(looseEmitters) do
		if emitter.Parent then
			local attachment = Instance.new("Attachment") :: Attachment
			attachment.Name = "PlacementVFXAttachment"
			attachment.Parent = anchor
			emitter.Parent = attachment
		end
	end
end

local function movePlacementVfxToCFrame(vfxInst: Instance, targetCFrame: CFrame): Instance
	if vfxInst:IsA("Model") then
		(vfxInst :: Model):PivotTo(targetCFrame)
		return vfxInst
	elseif vfxInst:IsA("BasePart") then
		(vfxInst :: BasePart).CFrame = targetCFrame
		return vfxInst
	elseif vfxInst:IsA("Folder") then
		local folder = vfxInst :: Folder
		local rootPart = folder:FindFirstChildWhichIsA("BasePart", true)
		if rootPart then
			movePlacementVfxFolderToCFrame(folder, targetCFrame)
			return vfxInst
		end

		local anchor = createPlacementVfxAnchor(targetCFrame)
		folder.Parent = anchor
		normalizeLoosePlacementVfxObjects(folder, anchor)
		return anchor
	elseif vfxInst:IsA("Attachment") then
		local attachment = vfxInst :: Attachment
		local anchor = createPlacementVfxAnchor(targetCFrame)
		attachment.Parent = anchor
		return anchor
	elseif vfxInst:IsA("ParticleEmitter") then
		local emitter = vfxInst :: ParticleEmitter
		local anchor = createPlacementVfxAnchor(targetCFrame)

		local attachment = Instance.new("Attachment") :: Attachment
		attachment.Name = "PlacementVFXAttachment"
		attachment.Parent = anchor
		emitter.Parent = attachment
		return anchor
	end

	local anchor = createPlacementVfxAnchor(targetCFrame)
	vfxInst.Parent = anchor
	return anchor
end

local function emitPlacementVfxAt(targetCFrame: CFrame): boolean
	local vfxTemplate = findPlacementVfxTemplate()
	if not vfxTemplate then
		debugPrint(DEBUG_PLACEMENT_VFX, "[VFX Debug] 警告：找不到放置特效模板。支持放置到 Workspace 任意层级：'放置特效01'，或 '放置特效/放置特效01'。")
		return false
	end

	vfxTemplate.Archivable = true
	local vfxClone = vfxTemplate:Clone()
	local vfxInst = vfxClone :: Instance
	vfxInst.Name = "PlacementVFX_Runtime"
	vfxInst.Parent = Workspace
	local runtimeRoot = movePlacementVfxToCFrame(vfxInst, targetCFrame)

	local emitted = 0
	local function emitIfParticle(inst: Instance)
		if inst:IsA("ParticleEmitter") then
			local pe = inst :: ParticleEmitter
			pe.Enabled = true
			pe:Emit(30)
			emitted += 1
		end
	end

	emitIfParticle(runtimeRoot)
	for _, desc in ipairs(runtimeRoot:GetDescendants()) do
		emitIfParticle(desc)
	end

	if emitted <= 0 then
		debugPrint(DEBUG_PLACEMENT_VFX, "[VFX Debug] 警告：放置特效模板内没有 ParticleEmitter：" .. debugInstancePath(vfxTemplate))
	else
		debugPrint(DEBUG_PLACEMENT_VFX, string.format("[VFX Debug] 放置特效已播放，模板=%s，发射器数量=%d", debugInstancePath(vfxTemplate), emitted))
	end

	task.delay(2.5, function()
		if runtimeRoot and runtimeRoot.Parent then
			runtimeRoot:Destroy()
		end
	end)

	return emitted > 0
end

local function tryPlaceFromEquippedTool(player: Player, slotPart: BasePart): boolean
	if player:GetAttribute("__DataLoaded") ~= true then return false end

	local rawIdx = slotPart:GetAttribute("SlotIndex")
	if type(rawIdx) ~= "number" then return false end
	local idx = rawIdx :: number

	if not canUseSlotByHomeLevel(player, idx) then return false end

	local stateMap = ensureState(player)
	local state = stateMap[idx]
	if not state then return false end
	if not state.Unlocked then return false end
	if state.PlacedMonster and state.PlacedMonster.Parent then return false end

	local character = player.Character
	if not character then return false end

	local equipped: Tool? = nil
	for _, ch in ipairs(character:GetChildren()) do
		if ch:IsA("Tool") and ch:GetAttribute("IsMonsterItem") == true then
			equipped = ch :: Tool
			break
		end
	end
	if not equipped then return false end

	local activeTool = equipped :: Tool
	local lvl = getNumAttr(activeTool, "MonsterLevel", 1)
	local v = getNumAttr(activeTool, "Value", 0)
	local gps = getNumAttr(activeTool, "GoldPerSec", 0)
	local appearanceLevel = getNumAttr(activeTool, "AppearanceLevel", lvl)

	local upLevel = getNumAttr(activeTool, "UpgradeLevel", 1)
	local baseV = getNumAttr(activeTool, "BaseValue", v)
	local baseGps = getNumAttr(activeTool, "BaseGoldPerSec", gps)

	local placed = createPlacedMonsterPart(player, slotPart, appearanceLevel, v, gps)
	if not placed then return false end
	
	local activePm = placed :: BasePart
	markPlacedPromptInitialHidden(activePm)
	activePm:SetAttribute("MonsterLevel", appearanceLevel)
	activePm:SetAttribute("AppearanceLevel", appearanceLevel)
	activePm:SetAttribute("UpgradeLevel", upLevel)
	activePm:SetAttribute("BaseValue", baseV)
	activePm:SetAttribute("BaseGoldPerSec", baseGps)
	setPlacedMonsterHeadBillboardText(activePm)

	emitPlacementVfxAt(activePm.CFrame)

	local home = HomeService.GetHome(player)
	if home then
		local slot = HomeService.GetSlot(player, idx)
		refreshIncomeDisplayForSlot(player, slotPart, slot and slot.Collector or nil, placed)
	end

	local itemId = activeTool:GetAttribute("ItemId")
	if type(itemId) == "string" and itemId ~= "" then
		InventoryService.ConsumeItem(player, itemId)
	end

	state.PlacedMonster = placed
	state.PlacedData = {
		MonsterLevel = appearanceLevel,
		AppearanceLevel = appearanceLevel,
		Value = v,
		GoldPerSec = gps,
		UnclaimedGold = 0,
		LastTickUnix = os.time(),
		UpgradeLevel = upLevel,
		BaseValue = baseV,
		BaseGoldPerSec = baseGps,
	}
	
	activeTool:Destroy()
	DataDirtyService.MarkDirty(player, 5)
	toast(player, string.format("Placed Monster in Area %d", idx))
	task.defer(function()
		local TutorialService = require(script.Parent:WaitForChild("TutorialService"))
		TutorialService.OnMonsterPlaced(player, idx)
	end)
	return true
end
	
local function payoutIfAny(player: Player, slotPart: BasePart)
	if player:GetAttribute("__DataLoaded") ~= true then return end

	local rawIdx = slotPart:GetAttribute("SlotIndex")
	if type(rawIdx) ~= "number" then return end
	local idx = rawIdx :: number

	if not canUseSlotByHomeLevel(player, idx) then return end

	local stateMap = ensureState(player)
	local state = stateMap[idx]
	if not state then return end
	
	local pm = state.PlacedMonster
	if not pm or not pm.Parent then return end

	local activePm = pm :: BasePart
	local un = getNumAttr(activePm, "UnclaimedGold", 0)
	if un <= 0 then return end

	local actualCollected = addUnclaimedToPlayer(player, activePm)
	requestPlacedMonsterJump(player, activePm)
	toast(player, string.format("Collected Gold +%d", actualCollected))
	task.defer(function()
		local TutorialService = require(script.Parent:WaitForChild("TutorialService"))
		TutorialService.OnGoldCollected(player, idx)
	end)
end

local function isPlacedMonsterForSlot(candidate: Instance, player: Player, slotIndex: number): boolean
	if not candidate:IsA("BasePart") then
		return false
	end
	local part = candidate :: BasePart
	return part.Parent ~= nil
		and part:GetAttribute("IsPlacedMonster") == true
		and getNumAttr(part, "OwnerUserId", -1) == player.UserId
		and math.floor(getNumAttr(part, "SlotIndex", -1)) == slotIndex
end

local function findExistingPlacedMonsterForSlot(player: Player, slotIndex: number, slotPart: BasePart, homeRoot: Instance): BasePart?
	local searchRoots: {Instance} = {}
	if slotPart.Parent then
		table.insert(searchRoots, slotPart.Parent :: Instance)
	end
	if homeRoot ~= slotPart.Parent then
		table.insert(searchRoots, homeRoot)
	end

	local searched: {[Instance]: boolean} = {}
	for _, root in ipairs(searchRoots) do
		if searched[root] then
			continue
		end
		searched[root] = true

		if isPlacedMonsterForSlot(root, player, slotIndex) then
			return root :: BasePart
		end

		for _, descendant in ipairs(root:GetDescendants()) do
			if isPlacedMonsterForSlot(descendant, player, slotIndex) then
				return descendant :: BasePart
			end
		end
	end

	return nil
end

local function rebuildPlacedMonsterForSlot(player: Player, slotPart: BasePart, state: SlotState): BasePart?
	local pData = state.PlacedData
	if not pData then
		return nil
	end

	local nowUnix = os.time()
	local appearanceLevel = getAppearanceLevelFromPlacedData(pData)
	pData.MonsterLevel = appearanceLevel
	pData.AppearanceLevel = appearanceLevel
	pData.LastTickUnix = nowUnix

	local placed = createPlacedMonsterPart(
		player,
		slotPart,
		appearanceLevel,
		math.floor(pData.Value),
		math.floor(pData.GoldPerSec),
		math.floor(pData.UnclaimedGold),
		nowUnix
	)

	local activePm = placed :: BasePart
	activePm:SetAttribute("MonsterLevel", appearanceLevel)
	activePm:SetAttribute("AppearanceLevel", appearanceLevel)
	activePm:SetAttribute("UpgradeLevel", pData.UpgradeLevel or 1)
	activePm:SetAttribute("BaseValue", pData.BaseValue or getNumAttr(activePm, "Value", 0))
	activePm:SetAttribute("BaseGoldPerSec", pData.BaseGoldPerSec or getNumAttr(activePm, "GoldPerSec", 0))
	setPlacedMonsterHeadBillboardText(activePm)

	state.PlacedMonster = activePm
	DataDirtyService.MarkDirty(player, 5)
	return activePm
end

local function resolvePlacedMonsterForUpgrade(player: Player, slotIndex: number, slotPart: BasePart, homeRoot: Instance, state: SlotState): BasePart?
	local pm = state.PlacedMonster
	if pm and pm.Parent and isPlacedMonsterForSlot(pm, player, slotIndex) then
		return pm :: BasePart
	end

	local existing = findExistingPlacedMonsterForSlot(player, slotIndex, slotPart, homeRoot)
	if existing then
		state.PlacedMonster = existing
		debugUpgradeButton(string.format("recovered placed monster reference player=%s slot=%d monster=%s", player.Name, slotIndex, existing:GetFullName()))
		return existing
	end

	local rebuilt = rebuildPlacedMonsterForSlot(player, slotPart, state)
	if rebuilt then
		debugUpgradeButton(string.format("rebuilt placed monster for upgrade player=%s slot=%d monster=%s", player.Name, slotIndex, rebuilt:GetFullName()))
		return rebuilt
	end

	return nil
end

local function tryUpgradePlacedMonster(player: Player, slotIndex: number): boolean
	if player:GetAttribute("__DataLoaded") ~= true then
		debugUpgradeButton(string.format("upgrade rejected: data not loaded player=%s", player.Name))
		return false
	end

	local idx = math.floor(slotIndex)
	if idx < 1 then
		debugUpgradeButton(string.format("upgrade rejected: invalid slot player=%s slot=%s", player.Name, tostring(slotIndex)))
		return false
	end

	local home = HomeService.GetHome(player)
	if not home then
		debugUpgradeButton(string.format("upgrade rejected: home not found player=%s slot=%d", player.Name, idx))
		return false
	end

	local slot = HomeService.GetSlot(player, idx)
	if not slot then
		debugUpgradeButton(string.format("upgrade rejected: slot not found player=%s slot=%d", player.Name, idx))
		return false
	end

	local stateMap = slotStatesByUserId[player.UserId]
	if type(stateMap) ~= "table" then
		debugUpgradeButton(string.format("upgrade rejected: state map missing player=%s slot=%d", player.Name, idx))
		return false
	end

	local safeMap = stateMap :: {[number]: SlotState}
	local state = safeMap[idx]
	if not state then
		debugUpgradeButton(string.format("upgrade rejected: slot state missing player=%s slot=%d", player.Name, idx))
		return false
	end

	local pm = resolvePlacedMonsterForUpgrade(player, idx, slot.Part, home.HomeRoot, state)
	if not pm or not pm.Parent then
		debugUpgradeButton(string.format("upgrade rejected: placed monster missing player=%s slot=%d", player.Name, idx))
		toast(player, "Place a monster before upgrading!")
		return false
	end

	local activePm = pm :: BasePart
	if activePm:GetAttribute("IsPlacedMonster") ~= true then
		debugUpgradeButton(string.format("upgrade rejected: target is not placed monster player=%s slot=%d monster=%s", player.Name, idx, activePm:GetFullName()))
		return false
	end
	if getNumAttr(activePm, "OwnerUserId", -1) ~= player.UserId then
		debugUpgradeButton(string.format("upgrade rejected: owner mismatch player=%s slot=%d owner=%d monster=%s", player.Name, idx, getNumAttr(activePm, "OwnerUserId", -1), activePm:GetFullName()))
		return false
	end

	local upLevel = getNumAttr(activePm, "UpgradeLevel", 1)
	local baseGps = getNumAttr(activePm, "BaseGoldPerSec", getNumAttr(activePm, "GoldPerSec", 0))
	local upgradeCost = upLevel * 100 * baseGps

	if not PlayerData.TrySpendGold(player, upgradeCost) then
		debugUpgradeButton(string.format("upgrade rejected: not enough gold player=%s slot=%d cost=%d level=%d baseGps=%d", player.Name, idx, upgradeCost, upLevel, baseGps))
		toast(player, "Not enough gold!")
		return false
	end

	local newLevel = upLevel + 1
	local newGps = newLevel * baseGps
	local baseValue = getNumAttr(activePm, "BaseValue", getNumAttr(activePm, "Value", 0))
	local newValue = baseValue * newLevel
	activePm:SetAttribute("UpgradeLevel", newLevel)
	activePm:SetAttribute("GoldPerSec", newGps)
	activePm:SetAttribute("Value", newValue)

	if state.PlacedData then
		local appearanceLevel = getNumAttr(activePm, "AppearanceLevel", getNumAttr(activePm, "MonsterLevel", 1))
		state.PlacedData.MonsterLevel = appearanceLevel
		state.PlacedData.AppearanceLevel = appearanceLevel
		state.PlacedData.UpgradeLevel = newLevel
		state.PlacedData.GoldPerSec = newGps
		state.PlacedData.Value = newValue
		state.PlacedData.LastTickUnix = os.time()
	end

	setPlacedMonsterHeadBillboardText(activePm)
	refreshIncomeDisplayForSlot(player, slot.Part, slot.Collector, activePm)
	toast(player, "Upgrade successful!")
	DataDirtyService.MarkDirty(player)
	debugUpgradeButton(string.format("upgrade success player=%s slot=%d level=%d cost=%d newGps=%d", player.Name, idx, newLevel, upgradeCost, newGps))
	return true
end

local function revealPlacedMonsterPromptsFromPlatform(player: Player, slotIndex: number, now: number)
	local m = slotStatesByUserId[player.UserId]
	if type(m) ~= "table" then return end

	local safeMap = m :: {[number]: SlotState}
	local state = safeMap[slotIndex]
	if not (state and state.PlacedMonster and state.PlacedMonster.Parent) then return end

	local pmInst = state.PlacedMonster :: BasePart
	-- 首次放置后的隐藏保护期内，不触发延迟显示，避免玩家刚放下怪就看到回收/卖出。
	if getPlacedPromptInitialHideRemaining(pmInst) > 0 then
		return
	end

	pmInst:SetAttribute("TriggerPromptReveal", now)
end

local function ensureUnlockPrompt(player: Player, slotPart: BasePart)
	local prompt = slotPart:FindFirstChild("UnlockPrompt") :: ProximityPrompt?
	if prompt then return end

	local newPrompt = Instance.new("ProximityPrompt") :: ProximityPrompt
	newPrompt.Name = "UnlockPrompt"
	newPrompt.ActionText = "Unlock"
	newPrompt.ObjectText = slotPart.Name
	newPrompt.KeyboardKeyCode = Enum.KeyCode.F
	newPrompt.HoldDuration = 0.4
	newPrompt.MaxActivationDistance = 10
	newPrompt.RequiresLineOfSight = false
	newPrompt.Exclusivity = Enum.ProximityPromptExclusivity.OneGlobally
	newPrompt.Parent = slotPart

	newPrompt.Triggered:Connect(function(triggerPlayer: Player)
		if player:GetAttribute("__DataLoaded") ~= true then return end
		if triggerPlayer.UserId ~= player.UserId then return end

		local rawIdx = slotPart:GetAttribute("SlotIndex")
		if type(rawIdx) ~= "number" then return end
		local idx = rawIdx :: number

		if not canUseSlotByHomeLevel(player, idx) then
			toast(player, "Upgrade your home to unlock this area")
			updateUnlockPromptEnabled(player, slotPart)
			return
		end

		if not isPrevUnlocked(player, idx) then
			toast(player, "Unlock the previous placement area first")
			updateUnlockPromptEnabled(player, slotPart)
			return
		end

		local stateMap = ensureState(player)
		local state = stateMap[idx]
		if not state then return end
		
		if state.Unlocked then
			newPrompt.Enabled = false
			return
		end

		local cost = getUnlockCost(idx)
		if not PlayerData.TrySpendGold(player, cost) then
			toast(player, string.format("Not enough gold. Need %d", cost))
			return
		end

		state.Unlocked = true
		PlayerData.Sync(player)
		DataDirtyService.MarkDirty(player, 5)
		newPrompt.Enabled = false
		toast(player, string.format("Unlocked: Area %d", idx))

		updateUnlockPromptEnabled(player, slotPart)
		local nextSlot = HomeService.GetSlotPart(player, idx + 1)
		if nextSlot then
			updateUnlockPromptEnabled(player, nextSlot)
		end
	end)
end

updateUnlockPromptEnabled = function(player: Player, slotPart: BasePart)
	local rawIdx = slotPart:GetAttribute("SlotIndex")
	if type(rawIdx) ~= "number" then return end
	local idx = rawIdx :: number

	local prompt = slotPart:FindFirstChild("UnlockPrompt") :: ProximityPrompt?
	if not prompt then return end

	local stateMap = ensureState(player)
	local state = stateMap[idx]
	if not state then
		prompt.Enabled = false
		return
	end

	if not isPlayerStandingOnSlot(player, slotPart) then
		prompt.Enabled = false
		return
	end

	if not canUseSlotByHomeLevel(player, idx) then
		prompt.Enabled = true
		prompt.ActionText = "Upgrade Home to Unlock"
		return
	end

	if state.Unlocked then
		prompt.Enabled = false
		return
	end

	if not isPrevUnlocked(player, idx) then
		prompt.Enabled = true
		prompt.ActionText = "Unlock Previous First"
		return
	end

	prompt.Enabled = true
	prompt.ActionText = string.format("Unlock (%d)", getUnlockCost(idx))
end

function PlacementService.Init()
	requestStealPlacedGoldRemote.OnServerEvent:Connect(function(player: Player)
		PlacementService.TryStealGold(player)
	end)

	requestUpgradePlacedMonsterRemote.OnServerEvent:Connect(function(player: Player, slotIndex: any, clickedOwnerUserId: any)
		if type(slotIndex) ~= "number" then
			debugUpgradeButton(string.format("rejected non-number slotIndex player=%s value=%s", player.Name, tostring(slotIndex)))
			return
		end
		if type(clickedOwnerUserId) ~= "number" or math.floor(clickedOwnerUserId :: number) ~= player.UserId then
			return
		end
		debugUpgradeButton(string.format("received player=%s slot=%d owner=%d", player.Name, math.floor(slotIndex :: number), math.floor(clickedOwnerUserId :: number)))
		tryUpgradePlacedMonster(player, slotIndex :: number)
	end)

	local function setupPlayer(player: Player)
		if placementInitStartedByUserId[player.UserId] then return end
		placementInitStartedByUserId[player.UserId] = true
		
		ensureState(player)

		task.spawn(function()
			local home
			while player.Parent do
				home = HomeService.GetHome(player)
				if home then break end
				task.wait(0.1)
			end

			if not home then
				warn("[PlacementService] Home not ready for player", player)
				return
			end

			debugPrint(DEBUG_PLACEMENT_INIT, string.format("[PlacementDebug] 玩家 %s 的家园已就绪，共有 %d 个槽位", player.Name, #home.Slots))
			for _, slot in ipairs(home.Slots) do
				local displayModel: Model? = nil
				if slot.Collector then
					displayModel = slot.Collector:FindFirstChild("收益显示", true) :: Model?
					
					if not displayModel then
						local template = ReplicatedStorage:FindFirstChild("收益显示", true) or Workspace:FindFirstChild("收益显示", true)
						
						if template and template:IsA("Model") then
							local dm = (template :: Instance):Clone() :: Model
							displayModel = dm
							
							local locatorPart = slot.Collector:FindFirstChild("收益显示定位", true) :: BasePart?
							local anchorCFrame = locatorPart and locatorPart.CFrame or slot.Collector.CFrame

							if locatorPart then locatorPart.CanQuery = false end
							slot.Collector.CanQuery = false
							
							if not dm.PrimaryPart then
								local realBase = dm:FindFirstChild("收益显示底座", true) :: BasePart?
								if realBase then
									dm.PrimaryPart = realBase
								else
									dm.PrimaryPart = dm:FindFirstChildWhichIsA("BasePart") :: BasePart?
								end
							end
							
							if dm.PrimaryPart then
								dm:PivotTo(anchorCFrame)
							end
							
							dm.Parent = slot.Collector
						end
					end

					if displayModel then
						local dm = displayModel :: Model
						dm:SetAttribute("OwnerUserId", player.UserId)
						dm:SetAttribute("SlotIndex", slot.Index)
						local clickPart = (dm:FindFirstChild("点击升级", true) :: BasePart?) or dm.PrimaryPart
						if clickPart then
							clickPart:SetAttribute("OwnerUserId", player.UserId)
							clickPart:SetAttribute("SlotIndex", slot.Index)
							clickPart.CanQuery = true

							local surfaceGui = clickPart:FindFirstChild("SurfaceGui") :: SurfaceGui?
							if not (surfaceGui and surfaceGui:IsA("SurfaceGui")) then
								surfaceGui = clickPart:FindFirstChildWhichIsA("SurfaceGui", true) :: SurfaceGui?
							end
							if not (surfaceGui and surfaceGui:IsA("SurfaceGui")) then
								surfaceGui = dm:FindFirstChildWhichIsA("SurfaceGui", true) :: SurfaceGui?
							end
							if surfaceGui then
								local badBtn = surfaceGui:FindFirstChild("AutoUpgradeButton")
								if badBtn then badBtn:Destroy() end
								surfaceGui.Active = true
								surfaceGui:SetAttribute("OwnerUserId", player.UserId)
								surfaceGui:SetAttribute("SlotIndex", slot.Index)

								local upgradeButton = surfaceGui:FindFirstChild("ImageButton_升级按钮", true)
								if upgradeButton and upgradeButton:IsA("GuiButton") then
									local btn = upgradeButton :: GuiButton
									btn.Active = true
									btn.Visible = true
									btn.Selectable = true
									btn:SetAttribute("OwnerUserId", player.UserId)
									btn:SetAttribute("SlotIndex", slot.Index)
								else
									debugUpgradeButton(string.format("ImageButton_升级按钮 not found for player=%s slot=%d display=%s surface=%s", player.Name, slot.Index, dm:GetFullName(), surfaceGui:GetFullName()))
								end
							else
								debugUpgradeButton(string.format("SurfaceGui not found for player=%s slot=%d display=%s clickPart=%s", player.Name, slot.Index, dm:GetFullName(), clickPart:GetFullName()))
							end

							local oldCD = clickPart:FindFirstChildWhichIsA("ClickDetector") :: ClickDetector?
							if oldCD then oldCD:Destroy() end
						end
					end
				end

				local function handleSlotTouch(hit)
					if player:GetAttribute("__DataLoaded") ~= true then return end
					local character = player.Character
					if not character or not hit:IsDescendantOf(character) then return end

					local rawIdx = slot.Part:GetAttribute("SlotIndex")
					local idx = if type(rawIdx) == "number" then rawIdx :: number else slot.Index
					local key = string.format("touch_%d_%s", player.UserId, tostring(idx))
					local now = os.clock()
					if (lastTouchAt[key] or 0) + 0.35 > now then return end
					lastTouchAt[key] = now

					local placedNow = tryPlaceFromEquippedTool(player, slot.Part)
					payoutIfAny(player, slot.Part)
					if placedNow then
						return
					end

					revealPlacedMonsterPromptsFromPlatform(player, idx, now)
				end

				local function handleCollectorTouch(hit)
					if player:GetAttribute("__DataLoaded") ~= true then return end
					local character = player.Character
					if not character or not hit:IsDescendantOf(character) then return end

					local rawIdx = slot.Part:GetAttribute("SlotIndex")
					local idx = if type(rawIdx) == "number" then rawIdx :: number else slot.Index
					local key = string.format("collector_touch_%d_%s", player.UserId, tostring(idx))
					local now = os.clock()
					if (lastTouchAt[key] or 0) + 0.35 > now then return end
					lastTouchAt[key] = now

					payoutIfAny(player, slot.Part)
				end

				slot.Part.Touched:Connect(handleSlotTouch)
				if slot.Collector then
					slot.Collector.Touched:Connect(handleCollectorTouch)
				end
			end
		end)
	end

	for _, player in ipairs(Players:GetPlayers()) do
		setupPlayer(player)
	end

	Players.PlayerAdded:Connect(function(player)
		setupPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		settlePendingSteal(player, "player_removing")
		lastStealRequestAtByUserId[player.UserId] = nil
		lastStealAvailabilityByUserId[player.UserId] = nil
		activeStealWarningByOwnerUserId[player.UserId] = nil
	end)

	local acc = 0
	local unlockAcc = 0
	RunService.Heartbeat:Connect(function(dt)
		-- 偷取按钮/警告需要跟随玩家进入、离开其他玩家 Home 立即刷新，
		-- 不要被下面每秒一次的金币产出循环卡住。
		refreshStealAvailabilityAndWarnings()
		processPendingStealSettlements()

		acc += dt
		unlockAcc += dt

		if acc < 1.0 then return end
		acc = 0

		for _, player in ipairs(Players:GetPlayers()) do
			local home = HomeService.GetHome(player)
			if not home then continue end

			local states = ensureState(player)
			for _, slot in ipairs(home.Slots) do
				local idx = slot.Index
				local state = states[idx]
				if not state then continue end
				
				local pm = state.PlacedMonster
				if pm and pm.Parent then
					local activePm = pm :: BasePart
					local gps = getNumAttr(activePm, "GoldPerSec", 0)
					local un = getNumAttr(activePm, "UnclaimedGold", 0)
					
					local newUn = un + gps 
					local nowUnix = os.time()
					activePm:SetAttribute("UnclaimedGold", newUn)
					activePm:SetAttribute("LastTickUnix", nowUnix)

					local st = state
					if st.PlacedData then
						st.PlacedData.UnclaimedGold = newUn
						st.PlacedData.LastTickUnix = nowUnix
					end

					setPlacedMonsterHeadBillboardText(activePm)
					refreshIncomeDisplayForSlot(player, slot.Part, slot.Collector, activePm)

					local lastPulse = lastDirtyPulseUnixByUserId[player.UserId] or 0
					if nowUnix - lastPulse >= 10 then
						lastDirtyPulseUnixByUserId[player.UserId] = nowUnix
						DataDirtyService.MarkDirty(player)
					end
				else
					refreshIncomeDisplayForSlot(player, slot.Part, slot.Collector, nil)
				end
			end
		end
	end)
end

local function rebuildPlacedMonstersWhenHomeReady(player: Player)
	local home
	while player.Parent do
		home = HomeService.GetHome(player)
		if home then break end
		task.wait(0.1)
	end

	if not home then return end

	local states = ensureState(player)
	local nowUnix = os.time()

	for _, slot in ipairs(home.Slots) do
		local idx = slot.Index
		local st = states[idx]
		if st and st.PlacedData and (not st.PlacedMonster or not st.PlacedMonster.Parent) then
			if player:GetAttribute("__DataLoaded") ~= true then return end
			
			local pData = st.PlacedData :: PersistedPlacedMonster
			if not pData then continue end

			local lastTick = pData.LastTickUnix
			local offlineSec = math.max(0, nowUnix - math.floor(lastTick))
			local gain = math.floor((offlineSec * pData.GoldPerSec) / 20)

			local un = math.floor(pData.UnclaimedGold)
			if gain > 0 then
				un = un + gain 
				pData.UnclaimedGold = un
				pData.LastTickUnix = nowUnix
				DataDirtyService.MarkDirty(player, 5)
			else
				pData.LastTickUnix = nowUnix
			end

			local appearanceLevel = getAppearanceLevelFromPlacedData(pData)
			pData.MonsterLevel = appearanceLevel
			pData.AppearanceLevel = appearanceLevel

			local placed = createPlacedMonsterPart(
				player,
				slot.Part,
				appearanceLevel,
				math.floor(pData.Value),
				math.floor(pData.GoldPerSec),
				un,
				nowUnix
			)
			
			if placed then
				local activePm = placed :: BasePart
				activePm:SetAttribute("MonsterLevel", appearanceLevel)
				activePm:SetAttribute("AppearanceLevel", appearanceLevel)
				activePm:SetAttribute("UpgradeLevel", pData.UpgradeLevel or 1)
				activePm:SetAttribute("BaseValue", pData.BaseValue or getNumAttr(activePm, "Value", 0))
				activePm:SetAttribute("BaseGoldPerSec", pData.BaseGoldPerSec or getNumAttr(activePm, "GoldPerSec", 0))
				setPlacedMonsterHeadBillboardText(activePm)
			end
			
			st.PlacedMonster = placed
			refreshIncomeDisplayForSlot(player, slot.Part, slot.Collector, placed)
		end
	end
end

function PlacementService.Export(player: Player): {PersistedSlot}
	local states = ensureState(player)
	local out: {PersistedSlot} = {}

	for i = 1, 30 do
		local st = states[i]
		local placedData: PersistedPlacedMonster? = nil

		if st then
			if st.PlacedMonster and st.PlacedMonster.Parent then
				local pm = st.PlacedMonster :: BasePart
				local appearanceLevel = getClampedMonsterLevel(getNumAttr(pm, "AppearanceLevel", getNumAttr(pm, "MonsterLevel", 1)))
				placedData = {
					MonsterLevel = appearanceLevel,
					AppearanceLevel = appearanceLevel,
					Value = math.floor(getNumAttr(pm, "Value", 0)),
					GoldPerSec = math.floor(getNumAttr(pm, "GoldPerSec", 0)),
					UnclaimedGold = math.floor(getNumAttr(pm, "UnclaimedGold", 0)),
					LastTickUnix = math.floor(getNumAttr(pm, "LastTickUnix", os.time())),
					UpgradeLevel = math.floor(getNumAttr(pm, "UpgradeLevel", 1)),
					BaseValue = math.floor(getNumAttr(pm, "BaseValue", getNumAttr(pm, "Value", 0))),
					BaseGoldPerSec = math.floor(getNumAttr(pm, "BaseGoldPerSec", getNumAttr(pm, "GoldPerSec", 0))),
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

function PlacementService.ApplyLoaded(player: Player, loadedSlots: {PersistedSlot}?)
	local states = ensureState(player)

	for i = 1, 30 do
		local loaded = (type(loadedSlots) == "table") and loadedSlots[i] or nil
		states[i].Unlocked = true
		states[i].PlacedMonster = nil
		states[i].PlacedData = nil

		if type(loaded) == "table" then
			local placed = (loaded :: any).Placed :: any
			if type(placed) == "table" then
				local monsterLevel = math.max(1, math.floor(if type(placed.MonsterLevel) == "number" then placed.MonsterLevel else 1))
				local value = math.floor(if type(placed.Value) == "number" then placed.Value else 0)
				local goldPerSec = math.floor(if type(placed.GoldPerSec) == "number" then placed.GoldPerSec else 0)
				local baseValue = math.floor(if type(placed.BaseValue) == "number" then placed.BaseValue else value)
				local baseGoldPerSec = math.floor(if type(placed.BaseGoldPerSec) == "number" then placed.BaseGoldPerSec else goldPerSec)
				local appearanceLevel = if type(placed.AppearanceLevel) == "number"
					then getClampedMonsterLevel(placed.AppearanceLevel)
					else inferAppearanceLevelFromStats(monsterLevel, baseValue, baseGoldPerSec)

				states[i].PlacedData = {
					MonsterLevel = appearanceLevel,
					AppearanceLevel = appearanceLevel,
					Value = value,
					GoldPerSec = goldPerSec,
					UnclaimedGold = math.floor(if type(placed.UnclaimedGold) == "number" then placed.UnclaimedGold else 0),
					LastTickUnix = math.floor(if type(placed.LastTickUnix) == "number" then placed.LastTickUnix else os.time()),
					UpgradeLevel = math.floor(if type(placed.UpgradeLevel) == "number" then placed.UpgradeLevel else 1),
					BaseValue = baseValue,
					BaseGoldPerSec = baseGoldPerSec,
				}
			end
		end
	end

	task.defer(function()
		rebuildPlacedMonstersWhenHomeReady(player)
	end)
end

function PlacementService.Cleanup(player: Player)
	settlePendingSteal(player, "cleanup")
	slotStatesByUserId[player.UserId] = nil
	placementInitStartedByUserId[player.UserId] = nil
	lastStealRequestAtByUserId[player.UserId] = nil
	lastStealAvailabilityByUserId[player.UserId] = nil
	activeStealWarningByOwnerUserId[player.UserId] = nil
end

function PlacementService.TryHandlePromptInteraction(player: Player, promptInstance: Instance): boolean
	if player:GetAttribute("__DataLoaded") ~= true then return false end
	if not promptInstance:IsA("ProximityPrompt") then return false end

	local promptParent = promptInstance.Parent
	if not (promptParent and promptParent:IsA("BasePart")) then return false end

	local placedPart = promptParent :: BasePart
	if placedPart:GetAttribute("IsPlacedMonster") ~= true then return false end
	if getNumAttr(placedPart, "OwnerUserId", -1) ~= player.UserId then return false end
	if (promptInstance :: ProximityPrompt).Enabled ~= true then return false end
	if not isPlayerWithinInteractionDistance(player, placedPart, (promptInstance :: ProximityPrompt).MaxActivationDistance) then return false end

	local rawIdx = placedPart:GetAttribute("SlotIndex")
	if type(rawIdx) ~= "number" then return false end
	
	local slotIndex = rawIdx :: number
	local slotPart = HomeService.GetSlotPart(player, slotIndex)
	if not slotPart then return false end

	if promptInstance.Name == "SellPrompt" then
		return trySellPlacedMonster(player, slotPart, placedPart)
	end
	if promptInstance.Name == "StorePrompt" then
		return tryStorePlacedMonster(player, slotPart, placedPart)
	end

	return false
end

function PlacementService.Clear(player: Player)
	local m = slotStatesByUserId[player.UserId]
	if type(m) ~= "table" then return end
	local safeM = m :: {[number]: SlotState}
	activeStealWarningByOwnerUserId[player.UserId] = nil
	
	for i = 1, 30 do
		local st = safeM[i]
		if not st then continue end
		
		local pm = st.PlacedMonster
		if pm and pm.Parent then
			destroyPlacedMonster(pm :: BasePart)
		end
		st.PlacedMonster = nil
		st.PlacedData = nil
	end
	
	DataDirtyService.MarkDirty(player)
end

function PlacementService.GetPlayerBaseGoldPerSec(player: Player): number
	local total = 0
	local states = slotStatesByUserId[player.UserId]
	if type(states) ~= "table" then
		return 0
	end

	for _, state in pairs(states :: {[number]: SlotState}) do
		local placedMonster = state.PlacedMonster
		if placedMonster and placedMonster.Parent then
			total += math.max(0, math.floor(getNumAttr(placedMonster :: BasePart, "GoldPerSec", 0)))
		elseif state.PlacedData then
			total += math.max(0, math.floor(tonumber(state.PlacedData.GoldPerSec) or 0))
		end
	end

	return math.floor(total)
end

return PlacementService