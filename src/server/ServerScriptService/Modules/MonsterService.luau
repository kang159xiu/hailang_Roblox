--!strict
-- ServerScriptService.Modules.MonsterService
-- 在拿取区域随机刷“怪”，可被武器攻击，并在头顶显示信息。
-- 注意：怪物形象已升级为“打组(Model)”为主。
-- 本服务会创建一个怪物根 Part，再把外观模板（Model/BasePart）克隆后做纯数学 Weld 到根上，
-- 保证场地实体怪物在解锚/物理参与时不散架、不偏移。



local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- ReplicatedStorage：客户端和服务端共享的数据仓库
-- 这里主要用来读取配置和怪物外观模板
--
-- RunService：Roblox 的运行时服务。
-- 当前脚本里虽然暂时没有直接使用它的逻辑，
-- 但通常这类服务模块里会预留给心跳、调试或后续扩展使用。

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))

local Util = require(script.Parent:WaitForChild("Util"))
local ZoneService = require(script.Parent:WaitForChild("ZoneService"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

-- require(...)：加载 ModuleScript 并拿到它导出的 table/函数。
--
-- 这些模块分别负责：
-- Config：全局配置，例如怪物血量、价值、刷新间隔
-- Util：工具函数，例如 clamp、加权随机、随机点坐标、确保文件夹存在
-- ZoneService：提供“可刷怪区域”的数据
-- CombatService：计算玩家伤害
-- InventoryService：处理玩家拾取怪物尸体后的入背包/携带逻辑

local MonsterService = {}

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local playWeaponHitVFXRemote = remotes:WaitForChild("PlayWeaponHitVFX") :: RemoteEvent

local monstersFolder: Folder
local aliveMonsters: {[BasePart]: true} = {}

local monsterAppearances: Instance? = nil

-- monstersFolder：Workspace 里的怪物容器，所有怪物根 Part 都会放在这里。
-- aliveMonsters：一个“集合表”，key 是怪物根 Part，value 固定写 true。
--   这种写法常用于高效判断“某个对象是否在集合中”。
-- monsterAppearances：怪物外观模板文件夹，通常放在 ReplicatedStorage 里。

type PickupZone = {
	Level: number,
	Part: BasePart,
}

-- PickupZone 表示一个刷怪区域：
-- Level：这个区域对应的等级，用来决定会刷出什么级别的怪
-- Part：区域本体，怪物会在这个 Part 顶面随机生成



-- ZoneKey -> PickupZone
local pickupZonesByKey: {[string]: PickupZone} = {}
-- 防止同一 Zone 同时多次补怪导致超刷
local zoneEnsureRunning: {[string]: true} = {}

local function debugInstancePath(instance: Instance?): string
	if not instance then
		return "nil"
	end

	local ok, fullName = pcall(function()
		return instance:GetFullName()
	end)
	return ok and fullName or instance.Name
end

-- pickupZonesByKey：把区域唯一标识映射到区域数据本身，方便后续查找
-- zoneEnsureRunning：防重入锁，避免同一个区域同时开启多个“补怪协程”

local function getZoneKey(zonePart: BasePart): string
	-- 一个区域需要有“稳定唯一 ID”，这样服务端才能知道：
	-- “这个怪是属于哪个区域刷出来的”。
	--
	-- GetFullName() 会返回类似 Workspace.Zones.Zone1 这样的层级路径，
	-- 通常比只用 Name 更稳，因为不同父级下可能有重名对象。
	-- FullName 包含层级路径，能较稳定区分不同区域
	return zonePart:GetFullName()
end

local function getAliveCount(): number
	-- 统计全图当前存活怪物总数。
	--
	-- pairs(aliveMonsters) 会遍历集合表里的所有 key，
	-- 每遍历到一个怪物，就把计数 +1。
	local n = 0
	for _ in pairs(aliveMonsters) do
		n += 1
	end
	return n
end

local function getAliveCountInZone(zoneKey: string): number
	-- 统计某一个区域当前活着的怪物数量。
	--
	-- 为什么要专门写这个函数？
	-- 因为刷怪限制不只是“全图最大数量”，
	-- 还经常需要控制“单个区域最多多少只”。
	local n = 0
	for m in pairs(aliveMonsters) do
		if m:IsDescendantOf(monstersFolder) and m:GetAttribute("ZoneKey") == zoneKey then
			n += 1
		end
	end
	return n
end

local function getMonsterInstanceFromRoot(monsterPart: BasePart): Instance
	local current: Instance? = monsterPart
	while current do
		if current ~= monsterPart and current:GetAttribute("IsMonster") == true then
			return current
		end

		if monstersFolder and current == monstersFolder then
			break
		end

		current = current.Parent
	end

	return monsterPart
end

local function syncMonsterModelAttribute(monsterPart: BasePart, name: string, value: any)
	local inst = getMonsterInstanceFromRoot(monsterPart)
	if inst ~= monsterPart then
		inst:SetAttribute(name, value)
	end
end

local function buildBillboard(monsterPart: BasePart)
	-- 给怪物头顶创建一个 BillboardGui（看板 UI）。
	--
	-- BillboardGui 是 Roblox 里一种“挂在 3D 物体上的 2D UI”，
	-- 常用于名字、血条、提示文字等头顶显示。

	-- 这里先只创建容器和 Label，
	-- 具体显示什么文字，可以在别的逻辑里继续更新 tl.Text。
	local bb = Instance.new("BillboardGui")
	bb.Name = "MonsterBillboard"
	bb.AlwaysOnTop = true
	bb.Enabled = true
	bb.MaxDistance = 30
	bb.Size = UDim2.fromOffset(260, 90)

	--设置生成区域怪头顶数据的显示高低 + 2.5
	bb.StudsOffset = Vector3.new(0, monsterPart.Size.Y * 0.5 + 2.5, 0)
	bb.Parent = monsterPart

	local tl = Instance.new("TextLabel")
	tl.Name = "Label"
	tl.BackgroundTransparency = 1
	tl.Size = UDim2.fromScale(1, 1)
	tl.TextColor3 = Color3.fromRGB(255, 255, 255)
	tl.TextStrokeTransparency = 0.2
	tl.TextScaled = true
	tl.Font = Enum.Font.GothamBold
	tl.Text = ""
	tl.Parent = bb
end

local function setMonsterBillboardText(monsterPart: BasePart)
	local bb = monsterPart:FindFirstChild("MonsterBillboard")
	if not bb or not bb:IsA("BillboardGui") then
		return
	end

	local label = bb:FindFirstChild("Label")
	if not label or not label:IsA("TextLabel") then
		return
	end

	local level = tonumber(monsterPart:GetAttribute("MonsterLevel")) or 1
	local hp = tonumber(monsterPart:GetAttribute("HP")) or 0
	local maxHp = tonumber(monsterPart:GetAttribute("MaxHP")) or 0
	local value = tonumber(monsterPart:GetAttribute("Value")) or 0
	local gps = tonumber(monsterPart:GetAttribute("GoldPerSec")) or 0
	local dead = monsterPart:GetAttribute("Dead") == true

	if dead then
		label.Text = string.format("Lv.%d  HP:%d/%d\n已死亡(可收起)", level, hp, maxHp)
	else
		label.Text = string.format("Lv.%d  HP:%d/%d\n价值:%d  +%d/s", level, hp, maxHp, value, gps)
	end
end

local function ensureCollectPrompt(monsterPart: BasePart)
	-- 给死亡后的怪物添加 ProximityPrompt（接近交互提示）。
	--
	-- ProximityPrompt 是 Roblox 的近距离交互 API：
	-- 玩家靠近对象时，可以按指定按键进行互动。
	-- 这里设置成：
	-- - ActionText = "收起"
	-- - ObjectText = "怪尸体"
	-- - 键位 E
	-- - 长按 1.25 秒
	--
	-- 触发后流程：
	-- 1. 检查怪物还在不在场景里
	-- 2. 检查怪物是否真的已经死亡
	-- 3. 检查是否已经被别人收取过
	-- 4. 临时标记 Collected=true，防止重复触发
	-- 5. 调用 InventoryService.PickupCarryMonster(...) 尝试放进玩家系统
	-- 6. 成功则销毁怪物；失败则回滚 Collected 状态并重新启用提示
	local existing = monsterPart:FindFirstChild("CollectPrompt")
	if existing and existing:IsA("ProximityPrompt") then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "CollectPrompt"
	prompt.ActionText = "收起"
	prompt.ObjectText = "怪尸体"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = monsterPart

	prompt.Triggered:Connect(function(player: Player)
		MonsterService.TryHandlePromptInteraction(player, prompt)
	end)
end

local function isPlayerWithinInteractionDistance(player: Player, targetPart: BasePart, maxDistance: number?): boolean
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return false
	end

	local allowed = maxDistance or 10
	return (hrp.Position - targetPart.Position).Magnitude <= (allowed + 2)
end

local function tryCollectDeadMonster(player: Player, monsterPart: BasePart, prompt: ProximityPrompt?): boolean
	if monsterPart.Parent == nil then
		return false
	end
	if monsterPart:GetAttribute("IsMonster") ~= true then
		return false
	end
	if monsterPart:GetAttribute("Dead") ~= true then
		return false
	end
	if monsterPart:GetAttribute("Collected") == true then
		return false
	end
	if prompt and prompt.Enabled ~= true then
		return false
	end
	if not isPlayerWithinInteractionDistance(player, monsterPart, prompt and prompt.MaxActivationDistance or 10) then
		return false
	end

	monsterPart:SetAttribute("Collected", true)
	if prompt then
		prompt.Enabled = false
	end

	local level = monsterPart:GetAttribute("MonsterLevel")
	local value = monsterPart:GetAttribute("Value")
	local gps = monsterPart:GetAttribute("GoldPerSec")

	local ok = InventoryService.PickupCarryMonster(
		player,
		type(level) == "number" and level or 1,
		type(value) == "number" and value or 0,
		type(gps) == "number" and gps or 0
	)

	if ok then
		aliveMonsters[monsterPart] = nil
		local monsterInstance = getMonsterInstanceFromRoot(monsterPart)
		monsterInstance:Destroy()
		return true
	end

	monsterPart:SetAttribute("Collected", false)
	if prompt then
		prompt.Enabled = true
	end
	return false
end

local function stripJointsAndConstraints(root: Instance)
	-- 这个函数会删除一个对象下面所有 Joint / Constraint。
	--
	-- 这类 API 常见于处理模型清洗，避免旧的焊接、约束、铰链等物理结构干扰新逻辑。
	-- 当前文件里虽然暂时没有调用它，但保留它通常是为了外观模型接入时做安全处理。
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("Constraint") then
			d:Destroy()
		end
	end
end

local function findMonsterAppearanceRoot(): Instance?
	local workspaceRoot = workspace:FindFirstChild("Monster image")
	if workspaceRoot then
		return workspaceRoot
	end

	local replicatedRoot = ReplicatedStorage:FindFirstChild("MonsterAppearances")
	if replicatedRoot then
		return replicatedRoot
	end

	return nil
end

local function getMonsterTemplate(monsterLevel: number): Model?
	-- 按怪物等级去查找对应的外观模板。

	--
	-- 这里兼容了几种命名方式：
	-- - 怪物形象1
	-- - 怪物形象 1
	-- - Lv1
	--
	-- 返回值必须是完整模板 Model：
	-- - 外层名字：怪物形象xx
	-- - 子节点 Model：视觉表现层
	-- - 子节点 同名 BasePart：逻辑根节点
	local root = monsterAppearances
	if not root then
		return nil
	end
	local level2 = string.format("%02d", monsterLevel)
	local inst = root:FindFirstChild("怪物形象" .. level2)
		or root:FindFirstChild("怪物形象" .. tostring(monsterLevel))
		or root:FindFirstChild("怪物形象 " .. level2)
		or root:FindFirstChild("怪物形象 " .. tostring(monsterLevel))
	if inst and inst:IsA("Model") then
		return inst
	end

	local fallback = root:FindFirstChild("怪物形象01")
		or root:FindFirstChild("怪物形象1")
		or root:FindFirstChild("怪物形象 01")
		or root:FindFirstChild("怪物形象 1")
	if fallback and fallback:IsA("Model") then
		return fallback
	end

	return nil
end

local function findTemplateRootPart(monsterTemplate: Model): BasePart?
	local rootName = monsterTemplate.Name
	local root = monsterTemplate:FindFirstChild(rootName)
	if root and root:IsA("BasePart") then
		return root
	end

	local deepRoot = monsterTemplate:FindFirstChild(rootName, true)
	if deepRoot and deepRoot:IsA("BasePart") then
		return deepRoot
	end

	local primaryPart = monsterTemplate.PrimaryPart
	if primaryPart then
		return primaryPart
	end

	local namedFallback = monsterTemplate:FindFirstChild("Root", true)
		or monsterTemplate:FindFirstChild("HumanoidRootPart", true)
		or monsterTemplate:FindFirstChild("MonsterRoot", true)
	if namedFallback and namedFallback:IsA("BasePart") then
		return namedFallback
	end

	return monsterTemplate:FindFirstChildWhichIsA("BasePart", true)
		:: BasePart?
	end

local function prepareMonsterTemplateClone(monsterTemplate: Model): (Model?, BasePart?)
	local clone = monsterTemplate:Clone()
	local root = findTemplateRootPart(clone)
	if not root then
		warn(string.format("[MonsterService] Monster template %s 找不到可用根部件；建议优先在模板内放一个与外层同名的 BasePart", monsterTemplate.Name))
		clone:Destroy()
		return nil
	end

	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.Massless = true
			if d ~= root then
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
	end

	root.Anchored = true
	root.CanCollide = true
	root.CanQuery = true
	root.CanTouch = true

	return clone, root
end


local function getZoneAlignedSpawnCFrame(zone: BasePart, rootPart: BasePart, margin: number): CFrame
	local posTop = Util.randomPointOnTop(zone, margin)
	local pos = posTop + Vector3.new(0, rootPart.Size.Y * 0.5 + 1, 0)
	return CFrame.fromMatrix(pos, zone.CFrame.XVector, zone.CFrame.YVector, zone.CFrame.ZVector)
end

local function createMonsterPart(zone: BasePart, zoneLevel: number, monsterLevel: number): (BasePart?, Instance?)
	-- 创建一只怪物的“整模板实例 + 逻辑根 Part + Billboard”。
	-- 1. 根据怪物等级选择完整模板 Model
	-- 2. 直接 clone 整个模板，而不是运行时重新焊接外观
	-- 3. 找到与父节点同名的根 Part，作为逻辑根节点
	-- 4. 整体移动到刷怪区域顶部
	-- 5. 把各种 Attribute 写到根 Part，并同步必要属性到外层 Model
	-- 6. 给根 Part 创建头顶 Billboard
	--
	-- Attribute 在这里非常重要，因为它让怪物数据直接挂在实例上：
	-- - IsMonster: 是否是怪物
	-- - ZoneLevel / MonsterLevel: 区域等级、怪物等级
	-- - HP / MaxHP: 当前血量、最大血量
	-- - Value / GoldPerSec: 价值、持续产金速度
	-- - SpawnUnix / ExpireUnix: 出生时间、过期时间
	local template = getMonsterTemplate(monsterLevel)
	if not template then
		warn(string.format("[MonsterService] Monster template for level %d not found", monsterLevel))
		return nil
	end

	local clone, p = prepareMonsterTemplateClone(template)
	if not clone or not p then
		return nil
	end

	local margin = 3
	-- 新需求：拿取区域刷出来的怪物朝向也要与区域 Part 完全一致。
	-- 因此这里不再只用 CFrame.new(位置)，而是复用区域的 X/Y/Z 轴重建目标 CFrame。
	local newRootCF = getZoneAlignedSpawnCFrame(zone, p, margin)
	clone:PivotTo(newRootCF)
	clone.PrimaryPart = p

	-- 属性
	p:SetAttribute("IsMonster", true)
	p:SetAttribute("ZoneLevel", zoneLevel)
	p:SetAttribute("MonsterLevel", monsterLevel)

	local maxHp = Config.MONSTER_HP_BY_LEVEL[monsterLevel] or 50
	local value = Config.MONSTER_VALUE_BY_LEVEL[monsterLevel] or 10
	local gps = Config.MONSTER_GOLD_PER_SEC_BY_LEVEL[monsterLevel] or 1

	p:SetAttribute("MaxHP", maxHp)
	p:SetAttribute("HP", maxHp)
	p:SetAttribute("Value", value)
	p:SetAttribute("GoldPerSec", gps)
	p:SetAttribute("SpawnUnix", os.time())
	p:SetAttribute("ExpireUnix", os.time() + Config.MONSTER_LIFETIME_SECONDS)
	p:SetAttribute("Dead", false)
	p:SetAttribute("Collected", false)

	clone:SetAttribute("IsMonster", true)
	clone:SetAttribute("Dead", false)
	clone:SetAttribute("MonsterLevel", monsterLevel)
	clone:SetAttribute("ZoneLevel", zoneLevel)

	buildBillboard(p)
	setMonsterBillboardText(p)

	return p, clone
end

local function pickMonsterLevelForZone(zoneLevel: number): number?
	-- 根据区域等级，按“权重表”随机出一个怪物等级。
	--
	-- 例如某个区域可能更容易刷 1~3 级怪，
	-- 而高等级怪只是低概率出现。
	--
	-- weightedPick(weights) 是典型的“加权随机”工具函数：
	-- 权重越大，被抽中的概率越高。
	local weights20 = Config.ZONE_MONSTER_WEIGHTS[zoneLevel]
	if not weights20 then
		return nil
	end

	local weights: {number} = {}
	for i = 1, 30 do
		weights[i] = weights20[i] or 0
	end

	return Util.weightedPick(weights)
end

local function markDead(monsterPart: BasePart)
	-- 将怪物标记为死亡。
	--
	-- 这里没有直接 Destroy 掉怪物，
	-- 因为你的设计是：怪物死后还要作为“尸体/可收起对象”留在场景里。
	--
	-- 所以死亡后主要做两件事：
	-- 1. 标记 Dead = true
	-- 2. 添加收取用的 ProximityPrompt
	if monsterPart:GetAttribute("Dead") == true then
		return
	end
	-- 不改变外观颜色：保持“死亡前后模型一致”（你要求）
	monsterPart:SetAttribute("Dead", true)
	syncMonsterModelAttribute(monsterPart, "Dead", true)
	ensureCollectPrompt(monsterPart)
	setMonsterBillboardText(monsterPart)
end

function MonsterService.MarkDead(monsterPart: Instance)
	-- 对外暴露的死亡接口。
	-- 别的模块如果要让怪物直接死亡，可以调用 MonsterService.MarkDead(...)。
	-- 这里先做类型和属性校验，避免误传普通物体。
	if monsterPart and monsterPart:IsA("BasePart") and monsterPart:GetAttribute("IsMonster") == true then
		markDead(monsterPart)
	end
end

function MonsterService.TryHandlePromptInteraction(player: Player, promptInstance: Instance): boolean
	if not promptInstance:IsA("ProximityPrompt") then
		print(string.format("[PromptDebug][Monster] reject player=%s reason=not_prompt class=%s", player.Name, promptInstance.ClassName))
		return false
	end
	if promptInstance.Name ~= "CollectPrompt" then
		print(string.format("[PromptDebug][Monster] reject player=%s prompt=%s reason=not_collect_prompt name=%s", player.Name, debugInstancePath(promptInstance), promptInstance.Name))
		return false
	end

	local promptParent = promptInstance.Parent
	if not (promptParent and promptParent:IsA("BasePart")) then
		print(string.format("[PromptDebug][Monster] reject player=%s prompt=%s reason=parent_not_basepart parent=%s", player.Name, debugInstancePath(promptInstance), debugInstancePath(promptParent)))
		return false
	end

	print(string.format("[PromptDebug][Monster] attempt action=CollectPrompt player=%s prompt=%s target=%s", player.Name, debugInstancePath(promptInstance), debugInstancePath(promptParent)))
	local ok = tryCollectDeadMonster(player, promptParent, promptInstance)
	print(string.format("[PromptDebug][Monster] result action=CollectPrompt player=%s success=%s", player.Name, tostring(ok)))
	return ok
end

local replenishZoneToTarget: (PickupZone, string, number) -> ()

local function spawnMonsterInZone(zonePart: BasePart, zoneLevel: number, zoneKey: string?): boolean
	-- 在指定区域里生成一只怪物，并挂到 monstersFolder 下。
	--
	-- 这里会先做一系列“上限检查”：
	-- 1. 单区域是否已经达到上限
	-- 2. 全图是否已经达到总上限
	-- 3. 是否能成功随机到一个怪物等级
	--
	-- 真正生成成功后，还会设置两个后续机制：
	-- 1. Destroying 监听：怪物被销毁时，从 aliveMonsters 中移除，并尝试触发补怪
	-- 2. task.delay 生命周期销毁：怪物存在太久会自动消失
	local key = zoneKey or getZoneKey(zonePart)

	local maxPerZone = Config.MAX_MONSTERS_PER_ZONE or 10
	if getAliveCountInZone(key) >= maxPerZone then
		return false
	end

	if getAliveCount() >= Config.MAX_ALIVE_MONSTERS then
		return false
	end

	local monsterLevel = pickMonsterLevelForZone(zoneLevel)
	if not monsterLevel then
		return false
	end

	local monster, monsterInstance = createMonsterPart(zonePart, zoneLevel, monsterLevel)
	if not monster or not monsterInstance then
		return false
	end
	monster:SetAttribute("ZoneKey", key)
	syncMonsterModelAttribute(monster, "ZoneKey", key)
	monsterInstance.Parent = monstersFolder
	aliveMonsters[monster] = true

	-- 统一在 Destroying 中做字典清理 + 触发“保底补怪”（分批 1~3 只，每批间隔 5s）
	monsterInstance.Destroying:Connect(function()
		aliveMonsters[monster] = nil
		local z = pickupZonesByKey[key]
		if z then
			local minDesired = Config.MIN_MONSTERS_PER_ZONE or 2
			-- 不要在 Destroying 回调里直接补怪，避免重入
			task.defer(function()
				replenishZoneToTarget(z, key, minDesired)
			end)
		end
	end)

	task.delay(Config.MONSTER_LIFETIME_SECONDS, function()
		if monsterInstance and monsterInstance.Parent then
			monsterInstance:Destroy()
		end
	end)

	return true
end

replenishZoneToTarget = function(z: PickupZone, key: string, target: number)
	-- 把某个区域“补怪”到目标数量。
	--
	-- 这里不是一次性瞬间刷满，而是“分批刷怪”：
	-- - 每批 1~3 只
	-- - 每批之间间隔若干秒
	--
	-- 这样做的好处是：
	-- 1. 场景表现更自然，不会突然一下子冒满屏怪
	-- 2. 便于控制节奏
	-- 3. 防止同一时刻生成过多对象带来卡顿
	--
	-- 特别逻辑：
	-- 如果区域已经被清空，并且缺口 >= 2，
	-- 则会尽量在第一批补到至少 2 只，避免区域空太久。
	-- 防止同一 Zone 同时多次补怪
	if zoneEnsureRunning[key] then
		return
	end
	zoneEnsureRunning[key] = true

	task.spawn(function()
		local minDesired = Config.MIN_MONSTERS_PER_ZONE or 2
		local maxDesired = Config.MAX_MONSTERS_PER_ZONE or 10
		local batchMin = Config.REPLENISH_BATCH_MIN or 1
		local batchMax = Config.REPLENISH_BATCH_MAX or 3
		local batchInterval = Config.REPLENISH_BATCH_INTERVAL_SECONDS or 5

		local clampedTarget = math.clamp(target, minDesired, maxDesired)

		while true do
			local cur = getAliveCountInZone(key)
			if cur >= clampedTarget then
				break
			end

			local missing = clampedTarget - cur
			local batch = math.random(batchMin, batchMax)
			batch = math.clamp(batch, 1, missing)

			-- 当区域被清空时：优先“一批内”补到至少 2 只（仍符合 1~3 只/批）
			if cur == 0 and missing >= 2 then
				batch = math.clamp(math.max(batch, 2), 1, missing)
			end

			for _ = 1, batch do
				if not spawnMonsterInZone(z.Part, z.Level, key) then
					break
				end
			end

			-- 刷完一批后固定间隔再继续补下一批
			task.wait(batchInterval)
		end

		zoneEnsureRunning[key] = nil
	end)
end

function MonsterService.DamageMonster(player: Player, hit: Instance)
	-- 处理玩家对怪物造成伤害。
	--
	-- 这是战斗链路里最关键的服务端函数之一。
	-- 流程如下：
	-- 1. 从 hit 开始向上找，定位真正的怪物根 Part
	-- 2. 检查这个目标是否确实存在于 Monsters 文件夹里
	-- 3. 检查玩家角色和 HumanoidRootPart 是否存在
	-- 4. 再做一次服务端距离校验（防止客户端乱传超远目标）
	-- 5. 读取怪物 HP / MaxHP
	-- 6. 通过 CombatService.GetPlayerDamage(player) 获取玩家伤害
	-- 7. 计算新血量并写回 Attribute
	-- 8. 如果血量归零，则标记死亡
	--
	-- 注意这里体现了非常重要的服务端安全思想：
	-- 即使客户端传来了一个“命中的怪物”，服务端仍然要自己重新验证距离、对象合法性、血量状态。
	-- 允许点到子元件：向上找到真正带 IsMonster 的根 Part。
	local monsterPart: BasePart?
	local cur: Instance? = hit
	while cur do
		if cur:IsA("BasePart") and cur:GetAttribute("IsMonster") == true then
			monsterPart = cur
			break
		end
		if cur == monstersFolder then
			break
		end
		cur = cur.Parent
	end

	if not monsterPart then
		return
	end
	if not monsterPart:IsDescendantOf(monstersFolder) then
		return
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local hitPart = if hit:IsA("BasePart") then hit else monsterPart

	local dist = (hrp.Position - monsterPart.Position).Magnitude
	if dist > 16 then
		return
	end

	local hp = monsterPart:GetAttribute("HP")
	local maxHp = monsterPart:GetAttribute("MaxHP")
	if type(hp) ~= "number" or type(maxHp) ~= "number" then
		return
	end
	if hp <= 0 then
		return
	end

	local dmg = CombatService.GetPlayerDamage(player)
	local newHp = math.max(0, hp - dmg)
	monsterPart:SetAttribute("HP", newHp)
	setMonsterBillboardText(monsterPart)

	local stats = PlayerData.Get(player)
	local weaponLevel = stats.EquippedWeaponLevel or stats.WeaponLevel or 1
	playWeaponHitVFXRemote:FireAllClients(hitPart, weaponLevel)

	if newHp <= 0 then
		markDead(monsterPart)
	end
end

function MonsterService.Init()
	-- 模块初始化入口。
	--
	-- 一般会在服务器启动时调用一次 MonsterService.Init()。
	-- 它做的事情包括：
	-- 1. 确保 Workspace 里存在 Monsters 文件夹
	-- 2. 读取怪物外观模板文件夹
	-- 3. 从 ZoneService 获取所有刷怪区域
	-- 4. 给每个区域记录唯一 key
	-- 5. 先刷到最低保底数量
	-- 6. 为每个区域启动一个长期循环，按随机间隔持续检查并补怪
	--
	-- 也就是说，Init() 负责把整个怪物生态系统“启动起来”。
	monstersFolder = Util.ensureFolder(workspace, "Monsters")
	monsterAppearances = findMonsterAppearanceRoot()
	if not monsterAppearances then
		warn("[MonsterService] 未找到怪物模板目录：优先查找 Workspace.'Monster image'，其次 ReplicatedStorage.MonsterAppearances")
	end

	local zones = ZoneService.GetPickupZones()
	if #zones == 0 then
		warn("[MonsterService] No pickup zones found")
		return
	end

	math.randomseed(os.clock() * 1e6)

	for _, z in ipairs(zones) do
		local key = getZoneKey(z.Part)
		pickupZonesByKey[key] = z

		-- 初始化：先保底到最小值
		local minDesired = Config.MIN_MONSTERS_PER_ZONE or 2
		for _ = 1, minDesired do
			if not spawnMonsterInZone(z.Part, z.Level, key) then
				break
			end
		end

		task.spawn(function()
			local maxPerZone = Config.MAX_MONSTERS_PER_ZONE or 10
			while true do
				local waitTime = math.random(Config.SPAWN_INTERVAL_MIN, Config.SPAWN_INTERVAL_MAX)
				task.wait(waitTime)

				-- 每次循环随机目标数量：允许区域在 [min, max] 内浮动增长
				local target = math.random(minDesired, maxPerZone)
				local cur = getAliveCountInZone(key)

				-- 不足才触发“分批补怪”（每批 1~3 只，每批间隔 5s）
				if cur < target then
					replenishZoneToTarget(z, key, target)
				end
			end
		end)
	end
end

return MonsterService

-- return MonsterService 表示把这个模块导出给别的脚本使用。
-- 其他服务可以这样拿到它：
-- local MonsterService = require(...)
-- MonsterService.Init()
-- MonsterService.DamageMonster(player, hit)
