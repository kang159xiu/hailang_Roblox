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

for level = 1, 30 do
	GUARDIAN_CONFIG[level] = {
		ModelName = "守护者形象" .. tostring(level), 
		Speed = 12 + (level * 1.5), 
		Animations = { Idle = "", Track = "", Attack = "" }
	}
end

--------------------------------------------------------------------------------
-- 2. 运行时数据状态
--------------------------------------------------------------------------------
local activeGuardians = {}
local guardiansFolder: Folder

--------------------------------------------------------------------------------
-- 3. 核心辅助函数 (移到外层，极致性能与稳定)
--------------------------------------------------------------------------------
local function getGuardianTemplate(modelName: string): Model?
	local templateFolder = workspace:FindFirstChild("GuardianModel")
	if not templateFolder then return nil end

	local template = templateFolder:FindFirstChild(modelName) or templateFolder:FindFirstChild("守护者形象1")
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

-- 【防弹版】检查玩家是否在区域内 (纯 2D 世界坐标距离，无视任何旋转和缩放异常)
local function isPlayerInZone(playerHRP: BasePart, zonePart: BasePart): boolean
	local dx = playerHRP.Position.X - zonePart.Position.X
	local dz = playerHRP.Position.Z - zonePart.Position.Z
	local horizontalDistance = math.sqrt(dx^2 + dz^2)
	
	-- 拿取区域最大边长的一半，加上 15 Studs 的超大容错范围
	local maxRadius = math.max(zonePart.Size.X, zonePart.Size.Y, zonePart.Size.Z) / 2
	local margin = 15 
	
	return horizontalDistance <= (maxRadius + margin)
end

-- 【强制转向】让守护者看向目标 (锁定 Y 轴，翻转 180 度，使用 PivotTo)
local function lookAtFlat(model: Model, rootPart: BasePart, targetPos: Vector3)
	local currentPos = rootPart.Position 
	local flatTarget = Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)
	
	if (flatTarget - currentPos).Magnitude > 0.1 then
		-- 去掉 180 度翻转，让 RootPart 的 Front 脸正对玩家
        local targetCFrame = CFrame.lookAt(currentPos, flatTarget)
		model:PivotTo(targetCFrame)
	end
end

--------------------------------------------------------------------------------
-- 4. 生成与状态机逻辑
--------------------------------------------------------------------------------
local function spawnGuardianForZone(zonePart: BasePart, zoneLevel: number, zoneKey: string)
	local config = GUARDIAN_CONFIG[zoneLevel] or GUARDIAN_CONFIG[1]
	local template = getGuardianTemplate(config.ModelName)
	if not template then return end

	local clone = template:Clone()
	
	-- 暴力抓取 RootPart
	local root = clone.PrimaryPart or clone:FindFirstChild("RootPart") or clone:FindFirstChild("HumanoidRootPart") or clone:FindFirstChildWhichIsA("BasePart", true) :: BasePart
	if not root then clone:Destroy() return end

	clone.PrimaryPart = root

	-- 【核心修复】绝对取消除了 RootPart 以外所有东西的锚定
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			if d == root then
				d.Anchored = true
			else
				d.Anchored = false
			end
			d.CanCollide = false
		end
	end

	-- 【调试模式】给 RootPart 上红色和箭头，方便观察
	root.Transparency = 0.5
	root.BrickColor = BrickColor.new("Bright red")
	local decal = Instance.new("Decal", root)
	decal.Face = Enum.NormalId.Front
	decal.Texture = "rbxasset://textures/spawnLocation.png"
	
	-- 初始化位置
    local spawnCFrame = zonePart.CFrame * CFrame.new(0, (zonePart.Size.Y / 2) + 4 + (root.Size.Y / 2), 0)
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
		AttackTimer = 0,
		-- 调试用记录
		WasPlayerInZone = false 
	}

	playAnim(activeGuardians[zoneKey], "Idle")
end

local function punishPlayer(guardian, player: Player, playerHRP: BasePart)
	guardian.State = "Attack"
	guardian.AttackTimer = os.clock()
	playAnim(guardian, "Attack")

	local direction = (playerHRP.Position - guardian.RootPart.Position).Unit
	local impulse = (direction * 800) + Vector3.new(0, 600, 0) 
	playerHRP:ApplyImpulse(impulse * playerHRP.AssemblyMass)
end

-- 心跳循环
local function onHeartbeat(dt: number)
	local now = os.clock()

	for _, g in pairs(activeGuardians) do
		
		-- 寻找区域内玩家
		local closestHRP: BasePart? = nil
		local minDist = 999 
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

		-- 【状态：闲置（待机盯人）】
		if g.State == "Idle" then
			if closestHRP then
				-- 【调试打印】
				if not g.WasPlayerInZone then
					g.WasPlayerInZone = true
					print(string.format("[GuardianDebug] 玩家踏入区域 %s，守护者开始死盯！", g.ZoneKey))
				end
				-- 死死盯住
				lookAtFlat(g.Model, g.RootPart, closestHRP.Position)
			else
				-- 【调试打印】
				if g.WasPlayerInZone then
					g.WasPlayerInZone = false
					print(string.format("[GuardianDebug] 玩家离开区域 %s，守护者恢复待机。", g.ZoneKey))
				end
				-- 没人则平滑转回原位
				g.Model:PivotTo(g.RootPart.CFrame:Lerp(g.SpawnCFrame, 0.1))
			end

		-- 【状态：追踪】
		elseif g.State == "Track" and g.TargetPlayer then
			local character = g.TargetPlayer.Character
			local targetHrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			
			if not targetHrp or not isPlayerInZone(targetHrp, g.ZonePart) then
				g.TargetPlayer = nil
				g.State = "Return"
				playAnim(g, "Track")
				continue
			end

			lookAtFlat(g.Model, g.RootPart, targetHrp.Position)

			local distToPlayer = (targetHrp.Position - g.RootPart.Position).Magnitude
			if distToPlayer < 5 then
				punishPlayer(g, g.TargetPlayer, targetHrp)
				continue
			end

			if now - g.LastPathTime > 0.3 then
				g.LastPathTime = now
				local path = PathfindingService:CreatePath({AgentRadius = 2, AgentHeight = 4, AgentCanJump = false})
				local success = pcall(function() path:ComputeAsync(g.RootPart.Position, targetHrp.Position) end)
				if success and path.Status == Enum.PathStatus.Success then
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
					local moveDir = flatMoveVec.Unit
					g.Model:PivotTo(g.RootPart.CFrame + (moveDir * g.Speed * dt))
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
				g.Model:PivotTo(g.SpawnCFrame)
				g.State = "Idle"
				playAnim(g, "Idle")
			else
				local moveDir = moveVec.Unit
				g.Model:PivotTo(g.RootPart.CFrame + (moveDir * g.Speed * dt))
				lookAtFlat(g.Model, g.RootPart, targetWP)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- 5. 对外接口
--------------------------------------------------------------------------------
function GuardianService.TriggerAlert(player: Player, zonePart: BasePart)
	local zoneKey = zonePart:GetFullName()
	local g = activeGuardians[zoneKey]
	
	if g and (g.State == "Idle" or g.State == "Return") then
		g.TargetPlayer = player
		g.State = "Track"
		g.LastPathTime = 0 
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
	
	RunService.Heartbeat:Connect(onHeartbeat)
	print("[GuardianService] 守护者系统初始化完成并启动寻路循环")
end

return GuardianService