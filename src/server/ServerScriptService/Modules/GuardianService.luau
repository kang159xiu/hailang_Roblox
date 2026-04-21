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

-- 自动初始化 1~30 级的配置
for level = 1, 30 do
	GUARDIAN_CONFIG[level] = {
		-- 对应模型名：守护者形象1, 守护者形象2 ...
		ModelName = "守护者形象" .. tostring(level), 
		-- 速度随等级提升：基础 12，每级增加 3
		Speed = 20 + (level * 3), 
		Animations = {
			Idle = "",   -- 在此处填入你的动画 ID
			Track = "", 
			Attack = "" 
		}
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
local function lookAtFlat(model: Model, rootPart: BasePart, targetPos: Vector3)
	local currentPos = rootPart.Position 
	local flatTarget = Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)

	if (flatTarget - currentPos).Magnitude > 0.1 then
		local targetCFrame = CFrame.lookAt(currentPos, flatTarget)
		model:PivotTo(targetCFrame)
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
	-- [修改内容] 优先寻找 FakeRootPart，确保操作的是 Rig 的核心根节点，防止 Motor6D 偏移导致模型飞天
	local root = clone:FindFirstChild("FakeRootPart") or clone.PrimaryPart or clone:FindFirstChild("RootPart") or clone:FindFirstChild("HumanoidRootPart") or clone:FindFirstChildWhichIsA("BasePart", true) :: BasePart
	
	if not root then 
		clone:Destroy() 
		return 
	end

	-- [修改内容] 强制将识别到的 root 设置为模型的 PrimaryPart，统一后续 PivotTo 的行为
	clone.PrimaryPart = root

	-- 清理调试颜色，开启触碰
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = (d == root)
			d.CanTouch = (d == root)
			d.CanCollide = false
		end
	end

	-- [修改内容] 以 RootPart 中心点为主。先定位到区域顶表面 (zonePart.Size.Y / 2)，然后再向上移动 RootPart 自身一半的高度 (root.Size.Y / 2)
	-- 去除了原本写死的 '+ 4' 偏移，保证模型脚底精确贴合地面
	local spawnCFrame = zonePart.CFrame * CFrame.new(0, (zonePart.Size.Y / 2) + (root.Size.Y / 2), 0)
	clone:PivotTo(spawnCFrame)
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
		if g.State == "Track" and g.TargetPlayer then
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
	for _, g in pairs(activeGuardians) do
		-- 搜索最近玩家逻辑
		local closestHRP = nil
		local minDist = 999 
		for _, player in ipairs(Players:GetPlayers()) do
			local char = player.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp and isPlayerInZone(hrp, g.ZonePart) then
				
				local carriedLevel = getPlayerCarriedMaxLevel(player)
				-- [修改内容] 每帧检测该玩家脚底是否是安全区
				local isSafe = isPlayerOnSafeGround(char)
				
				-- [修改内容] 只有当玩家【不在安全区】时，守护者才会锁定并追击他
				if not isSafe then
					-- 核心跨区追踪逻辑
					if carriedLevel > 0 and g.ZoneLevel <= carriedLevel then
						if g.State == "Idle" or g.State == "Return" then
							g.TargetPlayer = player
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
				lookAtFlat(g.Model, g.RootPart, closestHRP.Position)
			else
				g.Model:PivotTo(g.RootPart.CFrame:Lerp(g.SpawnCFrame, 0.1))
			end
		elseif g.State == "Track" and g.TargetPlayer then
			local targetChar = g.TargetPlayer.Character
			local targetHrp = targetChar and targetChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			
			-- [修改内容] 检测正在被追的人是不是踩进了安全区
			local isSafe = targetChar and isPlayerOnSafeGround(targetChar)

			-- [修改内容] 如果玩家不存在、头顶怪没了、或者【跑进了安全区(isSafe)】，守护者立刻回头放弃追踪
			if not targetHrp or getPlayerCarriedMaxLevel(g.TargetPlayer) == 0 or isSafe then
				g.TargetPlayer = nil
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

			if g.Waypoints and g.CurrentWaypointIdx <= #g.Waypoints then
				local targetWP = g.Waypoints[g.CurrentWaypointIdx].Position
				local moveVec = (targetWP - g.RootPart.Position)
				local flatMoveVec = Vector3.new(moveVec.X, 0, moveVec.Z)
				if flatMoveVec.Magnitude < 1 then
					g.CurrentWaypointIdx += 1
				else
					g.Model:PivotTo(g.RootPart.CFrame + (flatMoveVec.Unit * g.Speed * dt))
				end
			end
		elseif g.State == "Attack" then
			if now - g.AttackTimer > 1.5 then
				g.State = "Return"
				playAnim(g, "Track")
			end
		elseif g.State == "Return" then
			local moveVec = (g.SpawnCFrame.Position - g.RootPart.Position)
			if moveVec.Magnitude < 1 then
				g.Model:PivotTo(g.SpawnCFrame)
				g.State = "Idle"
				playAnim(g, "Idle")
			else
				g.Model:PivotTo(g.RootPart.CFrame + (moveVec.Unit * g.Speed * dt))
				lookAtFlat(g.Model, g.RootPart, g.SpawnCFrame.Position)
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