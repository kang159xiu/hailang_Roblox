--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PathfindingService = game:GetService("PathfindingService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local ZoneService = require(script.Parent:WaitForChild("ZoneService"))
local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
local MonsterService = require(script.Parent:WaitForChild("MonsterService"))

local GuardianService = {}

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

local activeGuardians = {}
local guardiansFolder: Folder

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

local function isPlayerInZone(playerHRP: BasePart, zonePart: BasePart): boolean
	local dx = playerHRP.Position.X - zonePart.Position.X
	local dz = playerHRP.Position.Z - zonePart.Position.Z
	local horizontalDistance = math.sqrt(dx^2 + dz^2)
	local maxRadius = math.max(zonePart.Size.X, zonePart.Size.Y, zonePart.Size.Z) / 2
	local margin = 15 
	return horizontalDistance <= (maxRadius + margin)
end

local function lookAtFlat(model: Model, rootPart: BasePart, targetPos: Vector3)
	local currentPos = rootPart.Position 
	local flatTarget = Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)
	if (flatTarget - currentPos).Magnitude > 0.1 then
		local targetCFrame = CFrame.lookAt(currentPos, flatTarget)
		model:PivotTo(targetCFrame)
	end
end

local function punishPlayer(guardian, player: Player, playerHRP: BasePart)
	-- 防止短时间内重复击飞
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

	-- 2. 完美抛物线击飞逻辑
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	
	if humanoid then
		-- 强制把玩家的身体状态改为纯物理 (Physics)，这会让它彻底放弃站立抵抗
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		humanoid.PlatformStand = true
	end
	
	-- 【黑科技核心】：把玩家往上强行拉高 2 个 Studs，彻底断开他与地板的物理粘连！
	playerHRP.CFrame = playerHRP.CFrame + Vector3.new(0, 2, 0)
	
	-- 抹平 Y 轴的高度差，只获取纯粹的水平方向
	local diff = playerHRP.Position - guardian.RootPart.Position
	local horizontalDir = Vector3.new(diff.X, 0, diff.Z)
	if horizontalDir.Magnitude > 0.01 then
		horizontalDir = horizontalDir.Unit
	else
		horizontalDir = Vector3.new(0, 0, 1) -- 容错：如果完全重合则向 Z 轴击飞
	end
	
	-- 赋予 45度角（水平推力 = 垂直升力）的初始爆发速度
	local pushPower = 120 -- 速度值，如果觉得飞得不够远，可以改到 100 或 120
	playerHRP.AssemblyLinearVelocity = (horizontalDir * pushPower) + Vector3.new(0, pushPower, 0)
	

	-- 【新增修改】：给玩家附加一个强烈的随机旋转角速度，实现空中“乱翻”
	local spin = 30 -- 翻滚的剧烈程度，数值越大转得越快
	playerHRP.AssemblyAngularVelocity = Vector3.new(
		math.random(-spin, spin), 
		math.random(-spin, spin), 
		math.random(-spin, spin)
	)

	-- 1秒后在空中或落地时恢复控制权，让玩家重新站起
	task.delay(1, function()
		if humanoid then
			humanoid.PlatformStand = false
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end)
	
	print(string.format("[GuardianService] 击飞 %s：解除地板粘连，执行 45 度完美抛物线", player.Name))
end

local function spawnGuardianForZone(zonePart: BasePart, zoneLevel: number, zoneKey: string)
	local config = GUARDIAN_CONFIG[zoneLevel] or GUARDIAN_CONFIG[1]
	local template = getGuardianTemplate(config.ModelName)
	if not template then return end

	local clone = template:Clone()
	local root = clone.PrimaryPart or clone:FindFirstChild("RootPart") or clone:FindFirstChild("HumanoidRootPart") or clone:FindFirstChildWhichIsA("BasePart", true) :: BasePart
	if not root then clone:Destroy() return end

	clone.PrimaryPart = root

	-- 【修改内容】只锚定 RootPart，同时开启 RootPart 的 CanTouch
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			if d == root then
				d.Anchored = true
				d.CanTouch = true -- 允许触发抓捕物理事件
			else
				d.Anchored = false
				d.CanTouch = false
			end
			d.CanCollide = false
		end
	end

	root.Transparency = 0.5
	root.BrickColor = BrickColor.new("Bright red")
	local decal = Instance.new("Decal", root)
	decal.Face = Enum.NormalId.Front
	decal.Texture = "rbxasset://textures/spawnLocation.png"
	
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
		WasPlayerInZone = false 
	}

	-- 【修改内容】绑定抓捕碰撞事件
	local g = activeGuardians[zoneKey]
	root.Touched:Connect(function(hit)
		-- 只有在追踪状态且碰到的目标是仇恨玩家时才触发
		if g.State == "Track" and g.TargetPlayer then
			local char = g.TargetPlayer.Character
			if char and hit:IsDescendantOf(char) then
				local hrp = char:FindFirstChild("HumanoidRootPart")
				if hrp then
					punishPlayer(g, g.TargetPlayer, hrp)
				end
			end
		end
	end)

	playAnim(activeGuardians[zoneKey], "Idle")
end


local function onHeartbeat(dt: number)
	local now = os.clock()

	for _, g in pairs(activeGuardians) do
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

		if g.State == "Idle" then
			if closestHRP then
				if not g.WasPlayerInZone then
					g.WasPlayerInZone = true
				end
				lookAtFlat(g.Model, g.RootPart, closestHRP.Position)
			else
				if g.WasPlayerInZone then
					g.WasPlayerInZone = false
				end
				g.Model:PivotTo(g.RootPart.CFrame:Lerp(g.SpawnCFrame, 0.1))
			end

		elseif g.State == "Track" and g.TargetPlayer then
			local character = g.TargetPlayer.Character
			local targetHrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			
			-- 【修改内容】移除了 isPlayerInZone 的判定，守护者会死追到底，直到玩家碰到 di_mian
			if not targetHrp then
				g.TargetPlayer = nil
				g.State = "Return"
				playAnim(g, "Track")
				continue
			end

			lookAtFlat(g.Model, g.RootPart, targetHrp.Position)

			-- 移动寻路逻辑
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

		elseif g.State == "Attack" then
			if now - g.AttackTimer > 1.5 then
				g.TargetPlayer = nil
				g.State = "Return"
				playAnim(g, "Track")
			end

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

	-- 【修改内容】监听玩家加入与角色生成，绑定脚底触碰地面的事件
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(char)
			local hrp = char:WaitForChild("HumanoidRootPart", 5)
			if hrp and hrp:IsA("BasePart") then
				-- 只要玩家移动，RootPart 就会高频与周围发生触碰
				hrp.Touched:Connect(function(hit)
					-- 检查踩到的地板有没有 di_mian 标签
					if hit and hit:IsA("BasePart") and CollectionService:HasTag(hit, "di_mian") then
						-- 遍历守护者，如果谁在追这个玩家，强制让它放弃并回原位
						for _, g in pairs(activeGuardians) do
							if g.State == "Track" and g.TargetPlayer == player then
								g.TargetPlayer = nil
								g.State = "Return"
								playAnim(g, "Track")
								print(string.format("[GuardianDebug] %s 逃入 di_mian 安全区，守护者放弃追踪！", player.Name))
							end
						end
					end
				end)
			end
		end)
	end)

	print("[GuardianService] 守护者系统初始化完成并启动寻路循环")
end

return GuardianService