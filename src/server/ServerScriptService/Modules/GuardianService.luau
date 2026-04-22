--!strict
-- ServerScriptService.Modules.GuardianService
-- 守护者系统：负责区域守护、寻路追踪玩家、击飞惩罚与掉落

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local ZoneService = require(script.Parent:WaitForChild("ZoneService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local MonsterService = require(script.Parent:WaitForChild("MonsterService"))

local GuardianService = {}

--------------------------------------------------------------------------------
-- 1. 守护者配置表 (1~30 级)
--------------------------------------------------------------------------------
type AnimationConfig = { Idle: string, Track: string, Attack: string }
type GuardianData = { ModelName: string, Speed: number, Animations: AnimationConfig }
local GUARDIAN_CONFIG: { [number]: GuardianData } = {}

-- [修改内容] 新增：专属动画配置表。你可以在这里为每一级的守护者独立配置动画 ID
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

-- 自动初始化 1~30 级的配置
for level = 1, 30 do
	-- 如果你在上面的表里配了该等级的动画，就用你配的；如果没配，就自动生成空的兜底
	local customAnim = CUSTOM_ANIMATIONS[level] or { Idle = "", Track = "", Attack = "" }
	
	GUARDIAN_CONFIG[level] = {
		ModelName = "守护者形象" .. tostring(level), 
		-- 速度随等级提升：基础 20，每级增加 3
		Speed = 20 + (level * 3), 
		Animations = customAnim
	}
end

--------------------------------------------------------------------------------
-- 2. 运行时状态记录
--------------------------------------------------------------------------------
local activeGuardians = {}
local guardiansFolder: Folder

--------------------------------------------------------------------------------
-- 3. 辅助功能函数
--------------------------------------------------------------------------------
local function getGuardianTemplate(modelName: string): Model?
	local templateFolder = workspace:FindFirstChild("GuardianModel")
	if not templateFolder then return nil end

	-- 尝试查找当前等级对应的特定形象
	local template = templateFolder:FindFirstChild(modelName)
	
	-- 如果还没做该等级的模型，则暂时用 1 级模型兜底（防止脚本报错停止运行）
	if not template then
		template = templateFolder:FindFirstChild("守护者形象1")
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

local function playAnim(guardian, animName: string)
	for name, track in pairs(guardian.AnimTracks) do
		if track then
			if name == animName then
				if not track.IsPlaying then
					track.Looped = (name ~= "Attack")
					track:Play()
				end
			else
				track:Stop()
			end
		end
	end
end

-- 检查玩家是否在区域内 (2D 水平判定)
local function isPlayerInZone(playerHRP: BasePart, zonePart: BasePart): boolean
	local dx = playerHRP.Position.X - zonePart.Position.X
	local dz = playerHRP.Position.Z - zonePart.Position.Z
	local horizontalDistance = math.sqrt(dx^2 + dz^2)
	
	local maxRadius = math.max(zonePart.Size.X, zonePart.Size.Y, zonePart.Size.Z) / 2
	local margin = 15 
	
	return horizontalDistance <= (maxRadius + margin)
end

-- 让守护者看向目标 (PivotTo 驱动)
-- [修改内容] 增强版朝向逻辑：仅改变 XZ 平面旋转，并严格抵消 PivotOffset 带来的位置偏移
local function lookAtFlat(model: Model, rootPart: BasePart, targetPos: Vector3)
	local currentPos = rootPart.Position 
	-- 强制目标点高度等于当前高度，防止模型“抬头”或“低头”
	local flatTarget = Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)

	if (flatTarget - currentPos).Magnitude > 0.1 then
		-- [修改内容] 计算基础朝向后，叠加 CFrame.Angles 旋转 180 度(math.pi) 来反转模型正面 Angles(0, math.pi, 0)
		local targetCFrame = CFrame.lookAt(currentPos, flatTarget) * CFrame.Angles(0, 0, 0)
		-- [修改内容] 必须乘以 rootPart.PivotOffset，否则每次转身都会导致坐标叠加偏移，引起跳动
		model:PivotTo(targetCFrame * rootPart.PivotOffset)
	end
end

-- =======================================================
-- [修改内容] 增加辅助函数：获取玩家当前举起的怪物最高等级
-- 遍历玩家角色身上的部件，判断是否携带了怪物，如果没携带返回 0

local function getPlayerCarriedMaxLevel(player: Player): number
	local maxLevel = 0
	local char = player.Character
	if char then
		for _, child in ipairs(char:GetChildren()) do
			-- 判断是否是怪物模型（名字带“怪物”或“Monster”，或者有Attribute）
			if child:GetAttribute("IsMonster") or child:GetAttribute("MonsterLevel") or string.find(child.Name, "怪物") or string.find(child.Name, "Monster") then
				
				local lv = child:GetAttribute("MonsterLevel")
				
				-- 如果模型身上没有挂载 Attribute，就尝试从名字(如"怪物形象5")中提取数字
				if type(lv) ~= "number" then
					local numStr = string.match(child.Name, "%d+")
					lv = numStr and tonumber(numStr) or 1
				end

				if lv > maxLevel then
					maxLevel = lv
				end
			end
		end
	end
	return maxLevel
end
-- =======================================================
-- =======================================================
-- [修改内容] 新增辅助函数：向下打射线检测玩家脚底是否踩着安全区
local function isPlayerOnSafeGround(char: Model): boolean
	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return false end
	
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- 射线忽略玩家自己的身体
	params.FilterDescendantsInstances = {char}
	
	-- 从玩家中心往下打 20 个单位的射线（即使跳起来也能检测到下方的地面）
	local result = workspace:Raycast(hrp.Position, Vector3.new(0, -20, 0), params)
	
	if result and result.Instance then
		local hit = result.Instance
		if CollectionService:HasTag(hit, "di_mian") or CollectionService:HasTag(hit, "ground") or CollectionService:HasTag(hit, "gorund") then
			return true
		end
	end
	return false
end
-- =======================================================


--------------------------------------------------------------------------------
-- 4. 惩罚逻辑：爆怪、击飞并乱翻
--------------------------------------------------------------------------------

local function punishPlayer(guardian, player: Player, playerHRP: BasePart)
	if guardian.State ~= "Track" then return end
	guardian.State = "Attack"
	guardian.TargetPlayer = nil 
	-- [修改内容] 攻击时丢失目标，清除追逐标记
	guardian.Model:SetAttribute("TargetPlayerName", "")
	guardian.AttackTimer = os.clock()
	playAnim(guardian, "Attack")

	-- 1. 掉落怪物
	local droppedItems = InventoryService.DropAllCarried(player)
	for _, item in ipairs(droppedItems) do
		local offset = Vector3.new(math.random(-4, 4), 0, math.random(-4, 4))
		local dropPos = playerHRP.Position + offset
		MonsterService.SpawnDroppedMonster(item.MonsterLevel, item.Value, item.GoldPerSec, dropPos, guardian.ZoneKey)
	end

	-- 2. 物理表现：击飞并空中翻滚
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	
	if humanoid then
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		humanoid.PlatformStand = true
	end
	
	-- 强制离地，解除摩擦力
	playerHRP.CFrame = playerHRP.CFrame + Vector3.new(0, 2, 0)
	
	-- 计算 45 度击飞向量
	local diff = playerHRP.Position - guardian.RootPart.Position
	local horizontalDir = Vector3.new(diff.X, 0, diff.Z)
	horizontalDir = horizontalDir.Magnitude > 0.1 and horizontalDir.Unit or Vector3.new(0, 0, 1)
	
	local pushPower = 100 
	playerHRP.AssemblyLinearVelocity = (horizontalDir * pushPower) + Vector3.new(0, pushPower, 0)
	
	-- 附加随机旋转角速度 (实现身体乱翻)
	local spin = 40
	playerHRP.AssemblyAngularVelocity = Vector3.new(
		math.random(-spin, spin), 
		math.random(-spin, spin), 
		math.random(-spin, spin)
	)
	
	-- 1.2秒后恢复状态
	task.delay(1.2, function()
		if humanoid then
			humanoid.PlatformStand = false
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end)
end

--------------------------------------------------------------------------------
-- 5. 生成与循环逻辑
--------------------------------------------------------------------------------
local function spawnGuardianForZone(zonePart: BasePart, zoneLevel: number, zoneKey: string)
	local config = GUARDIAN_CONFIG[zoneLevel] or GUARDIAN_CONFIG[1]
	local template = getGuardianTemplate(config.ModelName)
	if not template then return end

	local clone = template:Clone()
	
	-- [修改内容] 优先寻找你指定的 RootPart。如果找不到，再尝试 PrimaryPart 或其他部件
	local root = clone:FindFirstChild("RootPart") 
		or clone.PrimaryPart or clone:FindFirstChild("FakeRootPart") or clone:FindFirstChildWhichIsA("BasePart", true) :: BasePart
	
		--
	if not root or not root:IsA("BasePart") then 
		root = Instance.new("Part")
		root.Name = "RootPart"  -- [修改内容] 兜底生成的部件名字也统一叫 RootPart
		root.Size = Vector3.new(2, 2, 2)
		root.Transparency = 1
		root.CanCollide = false
		root.Anchored = true
		root.CFrame = zonePart.CFrame * CFrame.new(0, 3, 0)
		root.Parent = clone
	end

	-- 强制统一控制权
	clone.PrimaryPart = root
	-- [修改内容] 初始化追击标记
	clone:SetAttribute("TargetPlayerName", "")

	-- [修改内容] 强制全锚定模式：将模型内所有零件全部锚定
	-- [修改内容] 为了让 Motor6D 动画能生效，除了 RootPart 必须锚定外，其他所有外观零件绝对不能锚定！
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = (d == root)  -- 只有 RootPart 是 true，其他全是 false
			d.CanTouch = (d == root)
			d.CanCollide = false
			d.Massless = true
		end
	end

	local spawnCFrame = zonePart.CFrame * CFrame.new(0, (zonePart.Size.Y / 2) + (root.Size.Y / 2), 0)
	-- [修改内容] 必须乘以 PivotOffset，消除生成时的坐标偏移
	clone:PivotTo(spawnCFrame * root.PivotOffset)
	clone.Parent = guardiansFolder

	local controller = clone:FindFirstChildWhichIsA("AnimationController") or Instance.new("AnimationController", clone)
	local animator = controller:FindFirstChildWhichIsA("Animator") or Instance.new("Animator", controller)

	activeGuardians[zoneKey] = {
		ZoneKey = zoneKey,
		ZoneLevel = zoneLevel,
		ZonePart = zonePart,
		Model = clone,
		RootPart = root,
		Speed = config.Speed,
		AnimTracks = loadAnimations(animator, config.Animations),
		State = "Idle",      
		SpawnCFrame = spawnCFrame,
		TargetPlayer = nil,
		Waypoints = {},
		CurrentWaypointIdx = 1,
		LastPathTime = 0,
		AttackTimer = 0
	}

	-- 绑定碰撞抓捕
	root.Touched:Connect(function(hit)
		local g = activeGuardians[zoneKey]
		-- [修改内容] 增加 g 存在的判断，防止异步触发时 g 已经被清理
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


local function onHeartbeat(dt: number)
	local now = os.clock()
	for key, g in pairs(activeGuardians) do
		
		-- [修改内容] 1. 终极存活检测：如果模型被引擎意外销毁，安全剔除，防止崩溃
		if type(g) ~= "table" or not g.Model or not g.RootPart or not g.RootPart:IsA("BasePart") or not g.RootPart.Parent then
			if type(g) == "table" and g.Model then 
				pcall(function() g.Model:Destroy() end) 
			end
			activeGuardians[key] = nil
			continue
		end

		-- [修改内容] 2. 出生点兜底：如果数据表中丢失了 SpawnCFrame，用当前位置补全
		if not g.SpawnCFrame then
			g.SpawnCFrame = g.RootPart.CFrame
		end

		-- 搜索最近玩家逻辑
		local closestHRP = nil
		local minDist = 999 
		for _, player in ipairs(Players:GetPlayers()) do
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp and isPlayerInZone(hrp, g.ZonePart) then
				
				local carriedLevel = getPlayerCarriedMaxLevel(player)
				local isSafe = isPlayerOnSafeGround(char)
				
				if not isSafe then
					-- 核心跨区追踪逻辑
					if carriedLevel > 0 and g.ZoneLevel <= carriedLevel then
						if g.State == "Idle" or g.State == "Return" then
							g.TargetPlayer = player
							-- [修改内容] 标记模型正在追击该玩家，以便客户端识别
							g.Model:SetAttribute("TargetPlayerName", player.Name)
							g.State = "Track"
							g.LastPathTime = 0
							playAnim(g, "Track")
						end
					end

					-- 计算距离锁定目标
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
				-- [修改内容] 追踪附近的玩家时也会自动应用 lookAtFlat 里的 180 度修正
				lookAtFlat(g.Model, g.RootPart, closestHRP.Position)
			else
				-- [修改内容] 当玩家不在附近时，让守护者完美对齐地块的朝向（同样叠加 180 度修正）
				local targetIdleCFrame = g.SpawnCFrame * CFrame.Angles(0, math.pi, 0)
				local dist = (g.RootPart.Position - targetIdleCFrame.Position).Magnitude
				
				if dist > 5 then
					-- [修改内容] 强制拉回时乘以 PivotOffset 补偿
					g.Model:PivotTo(targetIdleCFrame * g.RootPart.PivotOffset)
				else
					-- [修改内容] 平滑插值后，乘以 PivotOffset 补偿，彻底切断“无限起飞再被拉回”的死循环
					local lerpedCF = g.RootPart.CFrame:Lerp(targetIdleCFrame, 0.1)
					g.Model:PivotTo(lerpedCF * g.RootPart.PivotOffset)
				end
			end
		elseif g.State == "Track" and g.TargetPlayer then
			local targetChar = g.TargetPlayer.Character
			local targetHrp = targetChar and targetChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			local isSafe = targetChar and isPlayerOnSafeGround(targetChar)

			if not targetHrp or getPlayerCarriedMaxLevel(g.TargetPlayer) == 0 or isSafe then
				g.TargetPlayer = nil
				-- [修改内容] 玩家逃脱，清除追击标记
				g.Model:SetAttribute("TargetPlayerName", "")
				g.State = "Return"
				playAnim(g, "Track")
				continue
			end

			lookAtFlat(g.Model, g.RootPart, targetHrp.Position)
			
			-- 寻路移动逻辑
			if now - g.LastPathTime > 0.3 then
				g.LastPathTime = now
				local path = PathfindingService:CreatePath({AgentRadius = 2, AgentHeight = 4, AgentCanJump = false})
				pcall(function() path:ComputeAsync(g.RootPart.Position, targetHrp.Position) end)
				if path.Status == Enum.PathStatus.Success then
					g.Waypoints = path:GetWaypoints()
					g.CurrentWaypointIdx = 2
				end
			end

			-- [修改内容] 3. 寻路点安全检测：防止 g.Waypoints[idx] 为 nil 导致崩溃
			if g.Waypoints and #g.Waypoints > 0 and g.CurrentWaypointIdx <= #g.Waypoints then
				local currentWP = g.Waypoints[g.CurrentWaypointIdx]
				if currentWP then
					local targetWP = currentWP.Position
					local moveVec = (targetWP - g.RootPart.Position)
					local flatMoveVec = Vector3.new(moveVec.X, 0, moveVec.Z)
					if flatMoveVec.Magnitude < 1 then
						g.CurrentWaypointIdx += 1
					else
						-- [修改内容] 提取出新的中心坐标，再应用 PivotOffset 补偿
						local nextCF = g.RootPart.CFrame + (flatMoveVec.Unit * g.Speed * dt)
						g.Model:PivotTo(nextCF * g.RootPart.PivotOffset)
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
				playAnim(g, "Idle")
			else
				-- [修改内容] 移动时看向出生点，应用 PivotOffset 补偿
				local nextCF = g.RootPart.CFrame + (moveVec.Unit * g.Speed * dt)
				g.Model:PivotTo(nextCF * g.RootPart.PivotOffset)
				lookAtFlat(g.Model, g.RootPart, targetIdleCFrame.Position)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- 6. 对外接口与初始化
--------------------------------------------------------------------------------
function GuardianService.TriggerAlert(player: Player, zonePart: BasePart)
	local zoneKey = zonePart:GetFullName()
	local g = activeGuardians[zoneKey]
	if g and (g.State == "Idle" or g.State == "Return") then
		g.TargetPlayer = player
		-- [修改内容] 触发追击，设置追击标记
		g.Model:SetAttribute("TargetPlayerName", player.Name)
		g.State = "Track"
		g.LastPathTime = 0
		playAnim(g, "Track")
		print(string.format("[GuardianService] %s 触发拾取！守护者正在追击...", player.Name))
	end
end

function GuardianService.Init()
	guardiansFolder = workspace:FindFirstChild("Guardians") or Instance.new("Folder", workspace)
	guardiansFolder.Name = "Guardians"

	local zones = ZoneService.GetPickupZones()
	for _, z in ipairs(zones) do
		spawnGuardianForZone(z.Part, z.Level, z.Part:GetFullName())
	end
	
	RunService.Heartbeat:Connect(onHeartbeat)
	
	-- [修改内容] 旧版基于 Touched 事件的检测容易引起状态打架和疯狂打印，已被彻底移除。现在由 onHeartbeat 里的射线(Raycast)负责安全区检测。
end

return GuardianService