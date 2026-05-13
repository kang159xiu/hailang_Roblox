--!strict
-- ServerScriptService.Modules.GuardianService
-- 守护者系统：负责区域守护、寻路追击玩家、击飞惩罚与掉落

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local ZoneService = require(script.Parent:WaitForChild("ZoneService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local MonsterService = require(script.Parent:WaitForChild("MonsterService"))
local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))

local GuardianService = {}

local DIRECT_CHASE_DISTANCE = 12
local CATCH_DISTANCE = 5
local ZONE_TRACK_MARGIN = 3
local PATH_RECALC_INTERVAL = 0.8
local PATH_RECALC_TARGET_MOVE_DISTANCE = 8
local GUARDIAN_ACCEL_START_SPEED = 20 --初始速度
local GUARDIAN_ACCEL_DURATION = 3 --守护者加速时间


-- 1. 守护者配置表（1~30 级）

type AnimationConfig = { Idle: string, Track: string, Attack: string }
type GuardianData = { ModelName: string, Speed: number, Animations: AnimationConfig }
local GUARDIAN_CONFIG: { [number]: GuardianData } = {}

-- 专属动画配置表：可以在这里为每一级守护者单独配置动画 ID
local CUSTOM_ANIMATIONS = {
	[1] = { Idle = "rbxassetid://81551578379988", Track = "rbxassetid://132222392379713", Attack = "" },
	[2] = { Idle = "rbxassetid://75291175844780", Track = "rbxassetid://78735945899751", Attack = "" },
	[3] = { Idle = "rbxassetid://114979548917103", Track = "rbxassetid://97381162200240", Attack = "" },
	[4] = { Idle = "rbxassetid://112545660735763", Track = "rbxassetid://107357919201909", Attack = "" },
	[5] = { Idle = "rbxassetid://100537385040728", Track = "rbxassetid://96222636503887", Attack = "" },
	[6] = { Idle = "rbxassetid://92084664894159", Track = "rbxassetid://97627296401053", Attack = "" },
	[7] = { Idle = "rbxassetid://86144328246135", Track = "rbxassetid://135043731853331", Attack = "" },
	[8] = { Idle = "rbxassetid://89574551671070", Track = "rbxassetid://123374707041935", Attack = "" },
	[9] = { Idle = "rbxassetid://113172908675912", Track = "rbxassetid://117253206075071", Attack = "" },
	[10] = { Idle = "rbxassetid://115990250502932", Track = "rbxassetid://109359462253664", Attack = "" },
	-- 你可以继续往下复制，最高写到 [30]
}

local function getGuardianSpeedByZoneLevel(zoneLevel: number): number
	local speedMap = Config.GUARDIAN_SPEED_BY_ZONE_LEVEL
	return (speedMap and speedMap[zoneLevel]) or speedMap[1] or 16
end

-- 自动初始化 1~30 级的配置
for level = 1, 30 do
	-- 如果上面的表中配置了该等级的动画，就使用自定义配置；否则自动生成空的兜底配置
	local customAnim = CUSTOM_ANIMATIONS[level] or { Idle = "", Track = "", Attack = "" }

	GUARDIAN_CONFIG[level] = {
		ModelName = "守护者形象" .. tostring(level),
		-- 速度统一改为只从 Config.GUARDIAN_SPEED_BY_ZONE_LEVEL 读取
		Speed = getGuardianSpeedByZoneLevel(level),
		Animations = customAnim
	}
end


-- 2. 运行时状态记录
local activeGuardians = {}
local personalGuardians = {}
local guardiansFolder: Folder
local guardianTemplateFolder = ReplicatedStorage:WaitForChild("GuardianModel")


-- 3. 辅助功能函数

local function getGuardianTemplate(modelName: string): Model?
	-- 尝试查找当前等级对应的特定形象
	local template = guardianTemplateFolder:FindFirstChild(modelName)

	-- 如果还没做该等级的模型，则暂时用 1 级模型兜底，防止脚本报错停止运行
	if not template then
		template = guardianTemplateFolder:FindFirstChild("守护者形象1")
	end

	return (template and template:IsA("Model")) and template or nil
end

local function loadAnimations(animator: Animator, config: AnimationConfig)
	local tracks = {}
	local function loadTrack(id: string): AnimationTrack?
		if not id or id == "" then return nil end
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local success, track = pcall(function() return animator:LoadAnimation(anim) end)
		return success and track or nil
	end
	tracks.Idle = loadTrack(config.Idle)
	tracks.Track = loadTrack(config.Track)
	tracks.Attack = loadTrack(config.Attack)
	return tracks
end

local function playAnim(guardian, _animName: string)
	-- 守护者不再根据状态切换待机/攻击动作：始终播放 Track（奔跑）动作。
	-- 这样公共守护者待机、专属守护者追击/返回、攻击惩罚阶段都会保持同一个奔跑动画，避免动作来回切换。
	local forcedAnimName = "Track"
	for name, track in pairs(guardian.AnimTracks) do
		if track then
			if name == forcedAnimName then
				if not track.IsPlaying then
					track.Looped = true
					track:Play()
				end
			else
				track:Stop()
			end
		end
	end
end

-- 检查玩家是否在区域内。
-- 之前这里用“中心点距离 <= 最大边半径 + 15”的圆形范围判断，多个相邻/斜放区域会互相重叠。
-- 玩家第二次带怪进入高等级区域时，可能同一帧被多个公共守护者判定为在各自区域内。
-- 进而反复创建/销毁不同区域的专属守护者，客户端表现就是守护者一闪一闪且无法稳定追踪。
-- 现在改成按区域 Part 自身 CFrame 的本地坐标做盒子判定，更符合真实场地范围。
local function isPlayerInZone(playerHRP: BasePart, zonePart: BasePart): boolean
	local localPos = zonePart.CFrame:PointToObjectSpace(playerHRP.Position)
	local halfSize = zonePart.Size * 0.5
	return math.abs(localPos.X) <= halfSize.X + ZONE_TRACK_MARGIN
		and math.abs(localPos.Z) <= halfSize.Z + ZONE_TRACK_MARGIN
end

local function getZoneHorizontalLocalDistance(playerHRP: BasePart, zonePart: BasePart): number
	local localPos = zonePart.CFrame:PointToObjectSpace(playerHRP.Position)
	return Vector3.new(localPos.X, 0, localPos.Z).Magnitude
end

-- 让守护者看向目标（PivotTo 驱动）。
-- 增强版朝向逻辑：仅改变 XZ 平面旋转，并严格抵消 PivotOffset 带来的位置偏移。
local function lookAtFlat(model: Model, rootPart: BasePart, targetPos: Vector3)
	local currentPos = rootPart.Position
	-- 强制目标点高度等于当前高度，防止模型“抬头”或“低头”。
	local flatTarget = Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)

	if (flatTarget - currentPos).Magnitude > 0.1 then
		-- 计算基础朝向后，可按模型实际朝向叠加 CFrame.Angles 修正。
		local targetCFrame = CFrame.lookAt(currentPos, flatTarget) * CFrame.Angles(0, 0, 0)
		-- 必须乘以 rootPart.PivotOffset，否则每次转身都会导致坐标叠加偏移，引起跳动。
		model:PivotTo(targetCFrame * rootPart.PivotOffset)
	end
end

local function getFlatLookCFrame(position: Vector3, targetPos: Vector3, fallbackCFrame: CFrame): CFrame
	local flatTarget = Vector3.new(targetPos.X, position.Y, targetPos.Z)
	if (flatTarget - position).Magnitude > 0.1 then
		return CFrame.lookAt(position, flatTarget)
	end

	return CFrame.new(position) * fallbackCFrame.Rotation
end

local function pivotGuardianAt(g, position: Vector3, lookTargetPos: Vector3)
	local nextCF = getFlatLookCFrame(position, lookTargetPos, g.RootPart.CFrame)
	g.Model:PivotTo(nextCF * g.RootPart.PivotOffset)
end

local function getCurrentGuardianTrackSpeed(g, now: number): number
	local targetSpeed = g.TargetSpeed or g.Speed or GUARDIAN_ACCEL_START_SPEED
	local startedAt = g.TrackStartedAt

	if type(startedAt) ~= "number" or startedAt <= 0 then
		return targetSpeed
	end

	if targetSpeed <= GUARDIAN_ACCEL_START_SPEED then
		return targetSpeed
	end

	local alpha = math.clamp((now - startedAt) / GUARDIAN_ACCEL_DURATION, 0, 1)
	return GUARDIAN_ACCEL_START_SPEED + ((targetSpeed - GUARDIAN_ACCEL_START_SPEED) * alpha)
end

local function moveGuardianTowards(g, targetPos: Vector3, dt: number, moveSpeed: number?): boolean
	local currentPos = g.RootPart.Position
	local moveVec = targetPos - currentPos
	local flatMoveVec = Vector3.new(moveVec.X, 0, moveVec.Z)
	local distance = flatMoveVec.Magnitude

	if distance < 0.05 then
		pivotGuardianAt(g, currentPos, targetPos)
		return true
	end

	local speed = moveSpeed or g.Speed
	local step = math.min(speed * dt, distance)
	local nextPos = currentPos + (flatMoveVec.Unit * step)
	pivotGuardianAt(g, nextPos, targetPos)

	return distance - step <= 0.05
end

-- =======================================================
-- 辅助函数：获取玩家当前举起/携带怪物的最高来源区域等级。
-- 遍历玩家角色身上的部件，判断是否携带了怪物；如果没有携带则返回 0。

local function getPlayerCarriedSourceZoneLevel(player: Player): number
	local maxSourceZoneLevel = 0
	local char = player.Character
	if not char then
		return 0
	end

	local function tryReadSourceZoneLevel(inst: Instance)
		if inst:GetAttribute("FromGacha") == true then
			return
		end

		if inst:GetAttribute("IsMonster") or inst:GetAttribute("MonsterLevel") or string.find(inst.Name, "怪物") or string.find(inst.Name, "Monster") then
			local sourceZoneLevel = inst:GetAttribute("SourceZoneLevel")
			if type(sourceZoneLevel) ~= "number" then
				sourceZoneLevel = inst:GetAttribute("ZoneLevel")
			end
			if type(sourceZoneLevel) == "number" and sourceZoneLevel > maxSourceZoneLevel then
				maxSourceZoneLevel = sourceZoneLevel
			end
		end
	end

	for _, child in ipairs(char:GetChildren()) do
		tryReadSourceZoneLevel(child)
	end

	local carriedFolder = char:FindFirstChild("CarriedMonsters")
	if carriedFolder then
		for _, child in ipairs(carriedFolder:GetChildren()) do
			tryReadSourceZoneLevel(child)
		end
	end

	return maxSourceZoneLevel
end

-- =======================================================
-- =======================================================
-- 辅助函数：向下打射线检测玩家脚底是否踩着安全区。
-- 注意：InventoryService 的规则明确写的是碰到 "gorund" 后才把携带怪物转成 Tool。
-- 这里如果把普通 "ground"/"di_mian" 也算安全区，玩家在刷怪区刚拿起怪物就会被判定安全。
-- 专属守护者会立刻进入 Return 并销毁，客户端表现为第一次就闪一下且不追踪。
local function isPlayerOnSafeGround(char: Model): boolean
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return false end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- 射线忽略玩家自己的身体。
	params.FilterDescendantsInstances = {char}

	-- 从玩家中心往下打 20 个单位的射线，即使跳起来也能检测到下方地面。
	local result = workspace:Raycast(hrp.Position, Vector3.new(0, -20, 0), params)

	if result and result.Instance then
		local hit = result.Instance
		if CollectionService:HasTag(hit, "gorund") then
			return true
		end
	end
	return false
end

-- 玩家携带怪物时只要碰到带有 di_mian 标签的 Part，就停止守护者追踪。
-- 这里和上面的 gorund 规则分开：gorund 负责把头顶携带态转换成 Tool；di_mian 只负责让守护者放弃追踪。
local function isCharacterTouchingDimian(char: Model): boolean
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {char}

		local result = workspace:Raycast(hrp.Position, Vector3.new(0, -20, 0), params)
		if result and result.Instance and CollectionService:HasTag(result.Instance, "di_mian") then
			return true
		end
	end

	for _, descendant in ipairs(char:GetDescendants()) do
		if descendant:IsA("BasePart") then
			for _, touchingPart in ipairs(descendant:GetTouchingParts()) do
				if touchingPart and not touchingPart:IsDescendantOf(char) and CollectionService:HasTag(touchingPart, "di_mian") then
					return true
				end
			end
		end
	end

	return false
end
-- =======================================================

local function getExistingPersonalGuardianForPlayer(player: Player)
	local suffix = "::" .. tostring(player.UserId)
	for key, g in pairs(personalGuardians) do
		if string.sub(key, -#suffix) == suffix then
			return key, g
		end
	end
	return nil, nil
end

local function playerHasActivePersonalGuardian(player: Player): boolean
	local _, g = getExistingPersonalGuardianForPlayer(player)
	return type(g) == "table"
		and g.Model ~= nil
		and g.RootPart ~= nil
		and g.RootPart.Parent ~= nil
		and g.State == "Track"
		and g.TargetPlayer == player
end



-- 4. 惩罚逻辑：掉落怪物、击飞并翻滚
local function punishPlayer(guardian, player: Player, playerHRP: BasePart)
	if guardian.State ~= "Track" then return end
	guardian.State = "Attack"
	guardian.TargetPlayer = nil
	-- 攻击时丢失目标，清除追踪标记。
	guardian.Model:SetAttribute("TargetPlayerName", "")
	guardian.AttackTimer = os.clock()
	playAnim(guardian, "Attack")

	-- 1. 掉落怪物
	local droppedItems = InventoryService.DropAllCarried(player)
	for _, item in ipairs(droppedItems) do
		local offset = Vector3.new(math.random(-4, 4), 0, math.random(-4, 4))
		local dropPos = playerHRP.Position + offset
		MonsterService.SpawnDroppedMonster(
			item.MonsterLevel,
			item.Value,
			item.GoldPerSec,
			dropPos,
			guardian.ZoneKey,
			(item :: any).UpgradeLevel or 1,
			(item :: any).SourceZoneLevel or 1,
			(item :: any).ExpireUnix
		)
	end

	-- 2. 物理表现：击飞 + 短暂平躺无序翻滚
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		-- Humanoid 默认会自动站立/扶正，单纯调整 AssemblyAngularVelocity 会被抵消。
		-- 这里短暂交给物理模拟，让玩家能平躺并无序翻滚；随后自动恢复控制。
		humanoid.AutoRotate = false
		humanoid.PlatformStand = true
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end

	-- 强制离地，解除摩擦力。
	playerHRP.CFrame = playerHRP.CFrame + Vector3.new(0, 2, 0)

	-- 计算击飞方向。
	local diff = playerHRP.Position - guardian.RootPart.Position
	local horizontalDir = Vector3.new(diff.X, 0, diff.Z)
	horizontalDir = horizontalDir.Magnitude > 0.1 and horizontalDir.Unit or Vector3.new(0, 0, 1)

	-- 先把角色横过来，避免击飞后仍保持站立姿态。
	playerHRP.CFrame = CFrame.lookAt(playerHRP.Position, playerHRP.Position + horizontalDir)
		* CFrame.Angles(math.rad(90), 0, math.rad(math.random(0, 360)))

	local pushPower = 100
	playerHRP.AssemblyLinearVelocity = (horizontalDir * pushPower) + Vector3.new(0, pushPower, 0)

	-- 无序翻滚角速度。数值越大翻滚越剧烈。
	local spin = 25
	playerHRP.AssemblyAngularVelocity = Vector3.new(
		math.random(-spin, spin),
		math.random(-spin, spin),
		math.random(-spin, spin)
	)

	if humanoid then
		local punishedCharacter = character
		local restored = false
		local touchArmedAt = os.clock() + 0.15
		local touchConnections: {RBXScriptConnection} = {}

		local function disconnectTouchListeners()
			for _, connection in ipairs(touchConnections) do
				connection:Disconnect()
			end
			table.clear(touchConnections)
		end

		local function restorePlayerControl()
			if restored then
				return
			end
			restored = true
			disconnectTouchListeners()

			-- 玩家可能已经重生/角色被销毁，恢复前先做安全检查。
			if player.Character ~= punishedCharacter then
				return
			end
			if humanoid.Parent == nil then
				return
			end

			playerHRP.AssemblyAngularVelocity = Vector3.zero
			humanoid.PlatformStand = false
			humanoid.AutoRotate = true
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end

		local function onCharacterTouched(hit: BasePart)
			-- 刚击飞的一瞬间可能还在碰到守护者/自身，稍微延迟启用触地恢复，避免立刻取消翻滚。
			if os.clock() < touchArmedAt then
				return
			end
			if hit:IsDescendantOf(punishedCharacter) then
				return
			end
			if guardian.Model and hit:IsDescendantOf(guardian.Model) then
				return
			end

			restorePlayerControl()
		end

		for _, descendant in ipairs(punishedCharacter:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(touchConnections, descendant.Touched:Connect(onCharacterTouched))
			end
		end

		-- 兜底：如果玩家一直没有碰到任何 Part，例如飞出地图或卡在空中，短暂延迟后也恢复，避免永久无法操作。
		task.delay(0.2, function()
			restorePlayerControl()
		end)
	end
end


-- 5. 生成与循环逻辑

local function setupGuardianModel(clone: Model, zonePart: BasePart): BasePart?
	local root = clone:FindFirstChild("RootPart")
		or clone.PrimaryPart or clone:FindFirstChild("FakeRootPart") or clone:FindFirstChildWhichIsA("BasePart", true) :: BasePart

	if not root or not root:IsA("BasePart") then
		root = Instance.new("Part")
		root.Name = "RootPart"
		root.Size = Vector3.new(2, 2, 2)
		root.Transparency = 1
		root.CanCollide = false
		root.Anchored = true
		root.CFrame = zonePart.CFrame * CFrame.new(0, 3, 0)
		root.Parent = clone
	end

	clone.PrimaryPart = root
	clone:SetAttribute("TargetPlayerName", "")

	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = (d == root)
			d.CanTouch = (d == root)
			d.CanCollide = false
			d.Massless = true
		end
	end

	return root
end

local function createGuardianState(zonePart: BasePart, zoneLevel: number, zoneKey: string, ownerPlayer: Player?)
	local config = GUARDIAN_CONFIG[zoneLevel] or GUARDIAN_CONFIG[1]
	local template = getGuardianTemplate(config.ModelName)
	if not template then return nil end

	local clone = template:Clone()
	local root = setupGuardianModel(clone, zonePart)
	if not root then return nil end

	local spawnCFrame = zonePart.CFrame * CFrame.new(0, (zonePart.Size.Y / 2) + (root.Size.Y / 2), 0)
	clone:PivotTo(spawnCFrame * root.PivotOffset)

	clone:SetAttribute("ZoneKey", zoneKey)
	clone:SetAttribute("IsPersonalGuardian", ownerPlayer ~= nil)
	clone:SetAttribute("OwnerUserId", ownerPlayer and ownerPlayer.UserId or 0)
	clone:SetAttribute("OwnerPlayerName", ownerPlayer and ownerPlayer.Name or "")
	clone.Name = ownerPlayer and string.format("PersonalGuardian_%s_%d", ownerPlayer.Name, zoneLevel) or string.format("Guardian_%d", zoneLevel)
	clone.Parent = guardiansFolder

	local controller = clone:FindFirstChildWhichIsA("AnimationController") or Instance.new("AnimationController", clone)
	local animator = controller:FindFirstChildWhichIsA("Animator") or Instance.new("Animator", controller)

	return {
		ZoneKey = zoneKey,
		ZoneLevel = zoneLevel,
		ZonePart = zonePart,
		Model = clone,
		RootPart = root,
		Speed = config.Speed,
		TargetSpeed = config.Speed,
		TrackStartedAt = 0,
		AnimTracks = loadAnimations(animator, config.Animations),
		State = "Idle",
		SpawnCFrame = spawnCFrame,
		TargetPlayer = nil,
		OwnerPlayer = ownerPlayer,
		Waypoints = {},
		CurrentWaypointIdx = 1,
		LastPathTime = 0,
		LastPathTargetPosition = nil,
		AttackTimer = 0,
	}
end

local function spawnGuardianForZone(zonePart: BasePart, zoneLevel: number, zoneKey: string)
	activeGuardians[zoneKey] = createGuardianState(zonePart, zoneLevel, zoneKey, nil)
	local g = activeGuardians[zoneKey]
	if not g then return end

	-- 绑定碰撞抓取。
	g.RootPart.Touched:Connect(function(hit)
		local g = activeGuardians[zoneKey]
		-- 增加 g 存在判断，防止异步触发时 g 已经被清理。
		if g and g.State == "Track" and g.TargetPlayer then
			local char = g.TargetPlayer.Character
			if char and hit:IsDescendantOf(char) then
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if hrp then punishPlayer(g, g.TargetPlayer, hrp) end
			end
		end
	end)

	playAnim(activeGuardians[zoneKey], "Idle")
end

local function getPersonalGuardianKey(player: Player, zoneKey: string): string
	return zoneKey .. "::" .. tostring(player.UserId)
end

local function destroyPersonalGuardian(personalKey: string)
	local g = personalGuardians[personalKey]
	if g and g.Model then
		pcall(function()
			g.Model:Destroy()
		end)
	end
	personalGuardians[personalKey] = nil
end

local function destroyOtherPersonalGuardiansForPlayer(player: Player, keepKey: string?)
	local suffix = "::" .. tostring(player.UserId)
	for key in pairs(personalGuardians) do
		if key ~= keepKey and string.sub(key, -#suffix) == suffix then
			destroyPersonalGuardian(key)
		end
	end
end

local function ensurePersonalGuardian(player: Player, zonePart: BasePart, zoneLevel: number, zoneKey: string)
	local personalKey = getPersonalGuardianKey(player, zoneKey)
	destroyOtherPersonalGuardiansForPlayer(player, personalKey)

	local g = personalGuardians[personalKey]

	if not g or not g.Model or not g.RootPart or not g.RootPart.Parent then
		g = createGuardianState(zonePart, zoneLevel, zoneKey, player)
		if not g then return nil end
		personalGuardians[personalKey] = g

		g.RootPart.Touched:Connect(function(hit)
			local current = personalGuardians[personalKey]
			if current and current.State == "Track" and current.TargetPlayer then
				local char = current.TargetPlayer.Character
				if char and hit:IsDescendantOf(char) then
					local hrp = char:FindFirstChild("HumanoidRootPart")
					if hrp then punishPlayer(current, current.TargetPlayer, hrp) end
				end
			end
		end)
		playAnim(g, "Idle")
	end

	return g
end

local function startPersonalGuardianTrack(player: Player, zonePart: BasePart, zoneLevel: number, zoneKey: string)
	local existingKey, existingGuardian = getExistingPersonalGuardianForPlayer(player)
	local personalKey = getPersonalGuardianKey(player, zoneKey)
	if existingKey and existingKey ~= personalKey and type(existingGuardian) == "table" then
		-- 已经有一个专属守护者在追踪这个玩家时，不允许 Heartbeat 因区域边界/重叠范围再次抢占切换。
		-- 否则 ensurePersonalGuardian 会销毁旧的再创建新的，客户端就会看到守护者一闪一闪。
		if existingGuardian.State == "Track" and existingGuardian.TargetPlayer == player then
			return
		end
	end

	local g = ensurePersonalGuardian(player, zonePart, zoneLevel, zoneKey)
	if not g then return end
	if g.State == "Track" and g.TargetPlayer == player then
		return
	end

	local targetSpeed = getGuardianSpeedByZoneLevel(zoneLevel)
	g.TargetSpeed = targetSpeed
	g.Speed = GUARDIAN_ACCEL_START_SPEED
	g.TrackStartedAt = os.clock()
	g.TargetPlayer = player
	g.Model:SetAttribute("TargetPlayerName", player.Name)
	g.Model:SetAttribute("OwnerUserId", player.UserId)
	g.Model:SetAttribute("OwnerPlayerName", player.Name)
	g.State = "Track"
	g.LastPathTime = 0
	playAnim(g, "Track")
end

local function updateTrackingGuardian(g, key, dt: number, now: number, shouldDestroyOnReturn: boolean)
	if type(g) ~= "table" or not g.Model or not g.RootPart or not g.RootPart:IsA("BasePart") or not g.RootPart.Parent then
		if type(g) == "table" and g.Model then
			pcall(function() g.Model:Destroy() end)
		end
		if shouldDestroyOnReturn then
			personalGuardians[key] = nil
		else
			activeGuardians[key] = nil
		end
		return
	end

	if not g.SpawnCFrame then
		g.SpawnCFrame = g.RootPart.CFrame
	end

	if g.State == "Track" and g.TargetPlayer then
		local targetChar = g.TargetPlayer.Character
		local targetHrp = targetChar and targetChar:FindFirstChild("HumanoidRootPart") :: BasePart?
		local isSafe = targetChar and isPlayerOnSafeGround(targetChar)
		local isTouchingDimian = targetChar and isCharacterTouchingDimian(targetChar)

		if not targetHrp or getPlayerCarriedSourceZoneLevel(g.TargetPlayer) == 0 or isSafe or isTouchingDimian then
			g.TargetPlayer = nil
			g.Model:SetAttribute("TargetPlayerName", "")
			g.State = "Return"
			g.Speed = g.TargetSpeed or g.Speed
			playAnim(g, "Track")
			return
		end

		local currentSpeed = getCurrentGuardianTrackSpeed(g, now)
		g.Speed = currentSpeed

		local targetOffset = targetHrp.Position - g.RootPart.Position
		local flatTargetOffset = Vector3.new(targetOffset.X, 0, targetOffset.Z)
		local targetDistance = flatTargetOffset.Magnitude

		if targetDistance <= CATCH_DISTANCE then
			punishPlayer(g, g.TargetPlayer, targetHrp)
			return
		end

		local shouldRecalcPath = now - g.LastPathTime > PATH_RECALC_INTERVAL
		local hasUsablePath = g.Waypoints and #g.Waypoints > 0 and g.CurrentWaypointIdx <= #g.Waypoints
		if g.LastPathTargetPosition then
			shouldRecalcPath = shouldRecalcPath and ((targetHrp.Position - g.LastPathTargetPosition).Magnitude >= PATH_RECALC_TARGET_MOVE_DISTANCE or not hasUsablePath)
		end

		if targetDistance > DIRECT_CHASE_DISTANCE and shouldRecalcPath then
			g.LastPathTime = now
			local path = PathfindingService:CreatePath({AgentRadius = 2, AgentHeight = 4, AgentCanJump = false})
			pcall(function() path:ComputeAsync(g.RootPart.Position, targetHrp.Position) end)
			if path.Status == Enum.PathStatus.Success then
				g.LastPathTargetPosition = targetHrp.Position
				g.Waypoints = path:GetWaypoints()
				g.CurrentWaypointIdx = 2
			else
				g.Waypoints = {}
				g.CurrentWaypointIdx = 1
			end
		end

		if targetDistance <= DIRECT_CHASE_DISTANCE then
			moveGuardianTowards(g, targetHrp.Position, dt, currentSpeed)
			return
		end

		if g.Waypoints and #g.Waypoints > 0 and g.CurrentWaypointIdx <= #g.Waypoints then
			local currentWP = g.Waypoints[g.CurrentWaypointIdx]
			if currentWP then
				local targetWP = currentWP.Position
				local moveVec = (targetWP - g.RootPart.Position)
				local flatMoveVec = Vector3.new(moveVec.X, 0, moveVec.Z)
				if flatMoveVec.Magnitude < 1 then
					g.CurrentWaypointIdx += 1
				else
					local reachedWaypoint = moveGuardianTowards(g, targetWP, dt, currentSpeed)
					if reachedWaypoint then
						g.CurrentWaypointIdx += 1
					end
				end
			else
				g.CurrentWaypointIdx += 1
			end
		end
	elseif g.State == "Attack" then
		if now - g.AttackTimer > 1.5 then
			g.State = "Return"
			playAnim(g, "Track")
		end
	elseif g.State == "Return" then
		local targetIdleCFrame = g.SpawnCFrame * CFrame.Angles(0, math.pi, 0)
		local moveVec = (targetIdleCFrame.Position - g.RootPart.Position)

		if moveVec.Magnitude < 1 then
			g.Model:PivotTo(targetIdleCFrame * g.RootPart.PivotOffset)
			g.State = "Idle"
			g.TargetPlayer = nil
			g.Model:SetAttribute("TargetPlayerName", "")
			playAnim(g, "Idle")

			if shouldDestroyOnReturn then
				destroyPersonalGuardian(key)
			end
		else
			moveGuardianTowards(g, targetIdleCFrame.Position, dt)
		end
	end
end


local function onHeartbeat(dt: number)
	local now = os.clock()
	local preferredGuardianKeyByUserId: {[number]: string} = {}

	-- 同一玩家同一帧只允许触发一个最匹配的区域追踪。
	-- 这层保护可以避免多个区域边界/重叠范围同时命中时，专属守护者在不同 ZoneKey 间反复切换。
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			continue
		end

		if playerHasActivePersonalGuardian(player) then
			continue
		end

		local carriedSourceZoneLevel = getPlayerCarriedSourceZoneLevel(player)
		if carriedSourceZoneLevel <= 0 then
			continue
		end

		if isPlayerOnSafeGround(char) or isCharacterTouchingDimian(char) then
			continue
		end

		local bestKey: string? = nil
		local bestScore = math.huge
		for key, g in pairs(activeGuardians) do
			if type(g) ~= "table" or not g.ZonePart or not g.ZoneLevel then
				continue
			end

			if g.ZoneLevel <= carriedSourceZoneLevel and isPlayerInZone(hrp, g.ZonePart) then
				local score = getZoneHorizontalLocalDistance(hrp, g.ZonePart)
				if score < bestScore then
					bestScore = score
					bestKey = key
				end
			end
		end

		if bestKey then
			preferredGuardianKeyByUserId[player.UserId] = bestKey
		end
	end

	for key, g in pairs(activeGuardians) do

		-- 1. 终极存活检测：如果模型被引擎意外销毁，安全剔除，防止崩溃。
		if type(g) ~= "table" or not g.Model or not g.RootPart or not g.RootPart:IsA("BasePart") or not g.RootPart.Parent then
			if type(g) == "table" and g.Model then
				pcall(function() g.Model:Destroy() end)
			end
			activeGuardians[key] = nil
			continue
		end

		-- 2. 出生点兜底：如果数据表中丢失 SpawnCFrame，就用当前位置补全。
		if not g.SpawnCFrame then
			g.SpawnCFrame = g.RootPart.CFrame
		end

		-- 搜索最近玩家逻辑。
		local closestHRP = nil
		local minDist = 999
		for _, player in ipairs(Players:GetPlayers()) do
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp and isPlayerInZone(hrp, g.ZonePart) then

				local carriedSourceZoneLevel = getPlayerCarriedSourceZoneLevel(player)
				local isSafe = isPlayerOnSafeGround(char)
				local isTouchingDimian = isCharacterTouchingDimian(char)

				if not isSafe and not isTouchingDimian then
					-- 只在“当前区域等级 <= 怪物来源区域等级”时追击。
					if carriedSourceZoneLevel > 0 and not playerHasActivePersonalGuardian(player) and g.ZoneLevel <= carriedSourceZoneLevel and preferredGuardianKeyByUserId[player.UserId] == key then
						startPersonalGuardianTrack(player, g.ZonePart, g.ZoneLevel, g.ZoneKey)
					end


					-- 计算距离并锁定目标。
					local d = (hrp.Position - g.RootPart.Position).Magnitude
					if d < minDist then
						minDist = d
						closestHRP = hrp
					end
				end
			end
		end

		if g.State == "Idle" then
			if closestHRP then
				-- 追踪附近玩家时也会自动应用 lookAtFlat 里的朝向修正。
				lookAtFlat(g.Model, g.RootPart, closestHRP.Position)
			else
				-- 当玩家不在附近时，让守护者对齐地块朝向。
				local targetIdleCFrame = g.SpawnCFrame * CFrame.Angles(0, math.pi, 0)
				local dist = (g.RootPart.Position - targetIdleCFrame.Position).Magnitude

				if dist > 5 then
					-- 强制拉回时乘以 PivotOffset 补偿。
					g.Model:PivotTo(targetIdleCFrame * g.RootPart.PivotOffset)
				else
					-- 平滑插值后乘以 PivotOffset 补偿，切断“无限起飞再被拉回”的死循环。
					local lerpedCF = g.RootPart.CFrame:Lerp(targetIdleCFrame, 0.1)
					g.Model:PivotTo(lerpedCF * g.RootPart.PivotOffset)
				end
			end
		elseif g.State == "Attack" then
			if now - g.AttackTimer > 1.5 then
				g.State = "Return"
				playAnim(g, "Track")
			end
		elseif g.State == "Return" then
			local targetIdleCFrame = g.SpawnCFrame * CFrame.Angles(0, math.pi, 0)
			local moveVec = (targetIdleCFrame.Position - g.RootPart.Position)

			if moveVec.Magnitude < 1 then
				g.Model:PivotTo(targetIdleCFrame * g.RootPart.PivotOffset)
				g.State = "Idle"
				playAnim(g, "Idle")
			else
				-- 移动与朝向合并成一次 PivotTo，减少模型在客户端看到的抖动。
				moveGuardianTowards(g, targetIdleCFrame.Position, dt)
			end
		end
	end

	for key, g in pairs(personalGuardians) do
		updateTrackingGuardian(g, key, dt, now, true)
	end
end


-- 6. 对外接口与初始化

function GuardianService.TriggerAlert(player: Player, zonePart: BasePart)
    local zoneKey = zonePart:GetFullName()
    local publicGuardian = activeGuardians[zoneKey]
    if not publicGuardian then
        return
    end

    -- [修改原因] 强制转为数字 tonumber，防止因读取到字符串导致查表失败或后续崩溃。
    local rawLevel = zonePart:GetAttribute("ZoneLevel")
    local zoneLevel = tonumber(rawLevel) or publicGuardian.ZoneLevel or 1
    local targetSpeed = getGuardianSpeedByZoneLevel(zoneLevel)

    -- 不再抢占公共守护者；为触发玩家启动自己的专属追踪守护者。
    startPersonalGuardianTrack(player, zonePart, zoneLevel, zoneKey)

    -- [修改原因] 使用 %s 作为容错占位符，防止类型不符导致 string.format 中断守护者线程。
end

function GuardianService.Init()
	guardiansFolder = workspace:FindFirstChild("Guardians") or Instance.new("Folder", workspace)
	guardiansFolder.Name = "Guardians"

	local zones = ZoneService.GetPickupZones()
	for _, z in ipairs(zones) do
		spawnGuardianForZone(z.Part, z.Level, z.Part:GetFullName())
	end

	RunService.Heartbeat:Connect(onHeartbeat)

	Players.PlayerRemoving:Connect(function(player)
		local suffix = "::" .. tostring(player.UserId)
		for key in pairs(personalGuardians) do
			if string.sub(key, -#suffix) == suffix then
				destroyPersonalGuardian(key)
			end
		end
	end)

	-- 旧版基于 Touched 事件的检测容易引起状态打架和疯狂打印，已被彻底移除。现在由 onHeartbeat 里的射线 Raycast 负责安全区检测。
end

return GuardianService
