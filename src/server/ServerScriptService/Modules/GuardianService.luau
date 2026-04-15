--!strict
-- ServerScriptService.Modules.GuardianService
-- 守护者系统：负责区域守护、寻路追踪玩家、击飞惩罚与掉落

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ZoneService = require(script.Parent:WaitForChild("ZoneService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local MonsterService = require(script.Parent:WaitForChild("MonsterService"))

local GuardianService = {}

--------------------------------------------------------------------------------
-- 1. 守护者配置表
--------------------------------------------------------------------------------
type AnimationConfig = { Idle: string, Track: string, Attack: string }
type GuardianData = { ModelName: string, Speed: number, Animations: AnimationConfig }

local GUARDIAN_CONFIG: { [number]: GuardianData } = {}

-- 初始化 1~30 级的默认配置
for level = 1, 30 do
	GUARDIAN_CONFIG[level] = {
		ModelName = "守护者形象" .. tostring(level), 
		Speed = 12 + (level * 1.5), -- 速度随等级增加
		Animations = {
			Idle = "",   -- 填入类似 "rbxassetid://12345678"
			Track = "", 
			Attack = "" 
		}
	}
end

--------------------------------------------------------------------------------
-- 2. 运行时数据状态
--------------------------------------------------------------------------------
local activeGuardians = {}
local guardiansFolder: Folder

--------------------------------------------------------------------------------
-- 3. 辅助函数
--------------------------------------------------------------------------------
local function getGuardianTemplate(modelName: string): Model?
	local templateFolder = workspace:FindFirstChild("GuardianModel")
	if not templateFolder then 
		warn("[GuardianService] 致命错误: 在 Workspace 中找不到名为 'GuardianModel' 的文件夹！")
		return nil 
	end

	local template = templateFolder:FindFirstChild(modelName)
	if not template then
		template = templateFolder:FindFirstChild("守护者形象1")
		if template then
			print(string.format("[GuardianService] 暂未制作 %s，自动使用 守护者形象1 兜底", modelName))
		end
	end

	if template and template:IsA("Model") then
		return template
	else
		warn(string.format("[GuardianService] 在 GuardianModel 文件夹里找不到可用的模型: %s", modelName))
	end
	return nil
end

local function spawnGuardianForZone(zonePart: BasePart, zoneLevel: number, zoneKey: string)
	local config = GUARDIAN_CONFIG[zoneLevel] or GUARDIAN_CONFIG[1]
	local template = getGuardianTemplate(config.ModelName)
	if not template then 
		warn("[GuardianService] 模板获取失败，跳过区域: " .. zoneKey)
		return 
	end

	local clone = template:Clone()
	
	-- [修改内容] 精准抓取根节点：加入了对 "RootPart" 这个名字的精确查找
	local root = clone.PrimaryPart 
		or clone:FindFirstChild("RootPart") 
		or clone:FindFirstChild("HumanoidRootPart") 
		or clone:FindFirstChildWhichIsA("BasePart", true) :: BasePart
		
	if not root then 
		warn(string.format("[GuardianService] 守护者模型 %s 里面连一个基础零件 (BasePart) 都没有！无法生成。", config.ModelName))
		clone:Destroy() 
		return 
	end

	clone.PrimaryPart = root

	-- [核心修改内容] 解决不转身的问题：
	-- 只能锚定 RootPart！其他所有展示部件 (FakeRootPart, Cube 等) 必须解除锚定。
	-- 因为它们有 WeldConstraint 和 Motor6D 连着 RootPart，只要 RootPart 不掉，它们就不会掉，而且会完美跟着旋转和播放动画！
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			if d == root then
				d.Anchored = true   -- 根节点：定海神针
			else
				d.Anchored = false  -- 外观节点：解除束缚，交由焊接和骨骼控制
			end
			d.CanCollide = false
		end
	end
	
	-- 继承朝向并翻转 180 度 (面朝玩家)
	local spawnCFrame = zonePart.CFrame * CFrame.new(0, (zonePart.Size.Y / 2) + 4 + (root.Size.Y / 2), 0) * CFrame.Angles(0, math.pi, 0)
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

	playAnim(activeGuardians[zoneKey], "Idle")
end

local function punishPlayer(guardian, player: Player, playerHRP: BasePart)
	guardian.State = "Attack"
	guardian.AttackTimer = os.clock()
	playAnim(guardian, "Attack")

	-- 1. 物理击飞 (向后上方强力推开)
	local direction = (playerHRP.Position - guardian.RootPart.Position).Unit
	local impulse = (direction * 800) + Vector3.new(0, 600, 0) -- 水平推力 + 垂直升力
	playerHRP:ApplyImpulse(impulse * playerHRP.AssemblyMass)

	-- 2. 惩罚掉落逻辑 (联动其他 Service)
	-- [需要你在 InventoryService 暴露出相应的扣除/掉落方法，这里是概念调用]
	-- local droppedMonsterData = InventoryService.DropCarriedMonster(player)
	-- if droppedMonsterData then
	--     MonsterService.SpawnDeadMonster(droppedMonsterData, playerHRP.Position)
	-- end
	
	-- 客户端特效联动 (如果有的话)
	-- playWeaponHitVFXRemote:FireAllClients(playerHRP, 1) 
end

-- 核心心跳循环：处理所有守护者的行为
local function onHeartbeat(dt: number)
	local now = os.clock()

	for _, g in pairs(activeGuardians) do
		-- 获取当前区域内最近的玩家（用于闲置时死盯）
		local function getClosestPlayerInZone()
			local closestHRP: BasePart? = nil
			local minDist = 100 -- 侦测范围
			for _, player in ipairs(Players:GetPlayers()) do
				local char = player.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if hrp and isPlayerInZone(hrp, g.ZonePart) then
					local d = (hrp.Position - g.RootPart.Position).Magnitude
					if d < minDist then
						minDist = d
						closestHRP = hrp
					end
				end
			end
			return closestHRP
		end

        local function lookAtFlat(rootPart: BasePart, targetPos: Vector3)
            -- 1. 拿到自己(守护者)的当前位置
            local currentPos = rootPart.Position 
            
            -- 2. 【抹平高度】：造一个“虚拟目标点”
            -- 强制把目标的 Y（高度）改成和守护者一样的 currentPos.Y
            -- 为什么要这样做？如果不抹平，当你跳起来，守护者就会仰头；你蹲下，它就会低头，这会导致整个人形/怪物模型发生奇怪的倾斜甚至栽倒在地。抹平后，它就只会在水平面（X和Z轴）上像雷达一样转圈。
            local flatTarget = Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)
            
            if (flatTarget - currentPos).Magnitude > 0.1 then
                -- 3. 【核心 API】：CFrame.lookAt
                -- 这个函数的作用是：强行把 rootPart 的 **“正前方 (Front 面)”** 对准 flatTarget。
                -- 4. 【角度补偿】：* CFrame.Angles(0, math.pi, 0)
                -- 因为之前我们发现模型是背对的，所以这里在对准之后，额外让它在 Y 轴上原地旋转 180 度（math.pi）。
                rootPart.CFrame = CFrame.lookAt(currentPos, flatTarget) * CFrame.Angles(0, math.pi, 0)
            end
        end

		-- 【状态：闲置（待机）】
		if g.State == "Idle" then
			local hrp = getClosestPlayerInZone()
			if hrp then
				-- [修改内容] 玩家进入区域，即便没触发追击，守护者也要死死盯着他
				lookAtFlat(g.RootPart, hrp.Position)
			else
				-- 如果没人，缓慢转回区域初始朝向
				g.RootPart.CFrame = g.RootPart.CFrame:Lerp(g.SpawnCFrame, 0.1)
			end

		-- 【状态：追踪】
		elseif g.State == "Track" and g.TargetPlayer then
			local character = g.TargetPlayer.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart
			
			if not hrp or not isPlayerInZone(hrp, g.ZonePart) then
				g.TargetPlayer = nil
				g.State = "Return"
				playAnim(g, "Track")
				continue
			end

			-- [修改内容] 将盯人逻辑移到移动判断之外，确保无论是否正在移动，视线永远锁定玩家
			lookAtFlat(g.RootPart, hrp.Position)

			-- 抓捕距离判定
			local distToPlayer = (hrp.Position - g.RootPart.Position).Magnitude
			if distToPlayer < 5 then
				punishPlayer(g, g.TargetPlayer, hrp)
				continue
			end

			-- 每 0.3 秒更新路径
			if now - g.LastPathTime > 0.3 then
				g.LastPathTime = now
				local path = PathfindingService:CreatePath({AgentRadius = 2, AgentHeight = 4, AgentCanJump = false})
				local success = pcall(function() path:ComputeAsync(g.RootPart.Position, hrp.Position) end)
				if success and path.Status == Enum.PathStatus.Success then
					g.Waypoints = path:GetWaypoints()
					g.CurrentWaypointIdx = 2
				end
			end

			-- 移动驱动
			if g.Waypoints and g.CurrentWaypointIdx <= #g.Waypoints then
				local targetWP = g.Waypoints[g.CurrentWaypointIdx].Position
				local moveVec = (targetWP - g.RootPart.Position)
				local flatMoveVec = Vector3.new(moveVec.X, 0, moveVec.Z)
				
				if flatMoveVec.Magnitude < 1 then
					g.CurrentWaypointIdx += 1
				else
					local moveDir = flatMoveVec.Unit
					g.RootPart.CFrame = g.RootPart.CFrame + (moveDir * g.Speed * dt)
					-- 注意：lookAtFlat 已经在上面执行过了，这里不再重复
				end
			end

		-- 【状态：攻击硬直】
		elseif g.State == "Attack" then
			if now - g.AttackTimer > 1.5 then
				g.TargetPlayer = nil
				g.State = "Return"
				playAnim(g, "Track")
			end

		-- 【状态：返回原位】
		elseif g.State == "Return" then
			local targetWP = g.SpawnCFrame.Position
			local moveVec = (targetWP - g.RootPart.Position)
			
			if moveVec.Magnitude < 1 then
				g.RootPart.CFrame = g.SpawnCFrame
				g.State = "Idle"
				playAnim(g, "Idle")
			else
				local moveDir = moveVec.Unit
				g.RootPart.CFrame = g.RootPart.CFrame + (moveDir * g.Speed * dt)
				lookAtFlat(g.RootPart, targetWP)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- 5. 对外接口
--------------------------------------------------------------------------------
-- 当玩家在区域内拾取怪物时，调用此函数触发追击警报
function GuardianService.TriggerAlert(player: Player, zonePart: BasePart)
	local zoneKey = zonePart:GetFullName()
	local g = activeGuardians[zoneKey]
	
	if g and (g.State == "Idle" or g.State == "Return") then
		g.TargetPlayer = player
		g.State = "Track"
		g.LastPathTime = 0 -- 立即计算一次路径
		playAnim(g, "Track")
		print(string.format("[GuardianService] 守护者锁定目标: %s", player.Name))
	end
end

function GuardianService.Init()
	guardiansFolder = workspace:FindFirstChild("Guardians") :: Folder
	if not guardiansFolder then
		guardiansFolder = Instance.new("Folder")
		guardiansFolder.Name = "Guardians"
		guardiansFolder.Parent = workspace
	end

	local zones = ZoneService.GetPickupZones()
	for _, z in ipairs(zones) do
		spawnGuardianForZone(z.Part, z.Level, z.Part:GetFullName())
	end
	
	-- 启动心跳寻路循环
	RunService.Heartbeat:Connect(onHeartbeat)
	
	print("[GuardianService] 守护者系统初始化完成并启动寻路循环")
end

return GuardianService