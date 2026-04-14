---@diagnostic disable: undefined-global
--!strict
-- StarterPack.Weapon.WeaponClient
-- 使用官方默认背包/热键栏来装备/卸下 Tool（不自建装备按钮）。
-- 本脚本仅负责：
-- 1) Tool.Activated：攻击（前方2格、180°范围，服务端判定）
-- 2) Q：释放技能（服务端处理）



-- Players: 管理玩家对象
local Players 			= game:GetService("Players")
-- ReplicatedStorage: 客户端和服务端都能访问的共享存储
local ReplicatedStorage = game:GetService("ReplicatedStorage")
--用户输入服务，监听键盘、鼠标、触摸等输入
local UserInputService 	= game:GetService("UserInputService") 


local player = Players.LocalPlayer
local tool = script.Parent :: Tool

-- 自定义攻击动画 ID。
-- 可填写纯数字（例如：1234567890）或 rbxassetid://1234567890
-- 留空、格式不正确、或加载失败时，会自动回退到默认攻击动画，并打印“默认攻击动画”。
local CUSTOM_ATTACK_ANIMATION_ID = "97542205785892"
-- 自定义待机动作（握持姿势）的动画 ID
local CUSTOM_IDLE_ANIMATION_ID = "135075227978653" -- 手持武器待机动画ID

-- [修改内容] 新增：用于存储正在播放的待机动画轨道，以便在切换武器时正确关闭
local idleTrack: AnimationTrack? = nil

-- [修改内容] 其他变量...
local isAttacking = false

-- Players.LocalPlayer 只在本地脚本（LocalScript）里可用，表示“当前这个玩家自己”。
-- script.Parent 一般就是当前脚本挂着的对象，这里它挂在 Tool 下面，所以把它当成 Tool 使用。

-- 防止重复绑定
if tool:GetAttribute("__WeaponCombatBound") == true then
	return
end
tool:SetAttribute("__WeaponCombatBound", true)

-- 这里用 Attribute（属性标签）做“防重复初始化”。
-- 如果这个脚本因为某些原因被重复运行，或者逻辑被再次执行，
-- 就会先检查 __WeaponCombatBound 是否已经为 true。
-- 如果已经绑定过事件，就直接 return，避免一个点击触发多次攻击。

-- Config（给一个超时兜底，避免一直 WaitForChild 卡死）
local gameModules = ReplicatedStorage:WaitForChild("GameModules", 10)
local Config = {
	GRID_STUDS = 4,
}

-- WaitForChild("GameModules", 10) 的意思是：最多等待 10 秒去找 ReplicatedStorage 里的 GameModules。
--
-- Config 是默认配置表。
-- GRID_STUDS 可以理解为“1 格等于多少 studs（Roblox 世界单位）”。
-- 如果后面成功 require 了正式配置，就会覆盖这个默认值。

if gameModules then
	local ok, mod = pcall(function()
		return require(gameModules:WaitForChild("Config"))
	end)
	if ok and type(mod) == "table" then
		Config = mod
	else
		warn("[WeaponClient] require(Config) failed; fallback GRID_STUDS=4")
	end
else
	warn("[WeaponClient] ReplicatedStorage.GameModules missing; fallback GRID_STUDS=4")
end

-- pcall(function() ... end) 用来“保护性执行代码”。
-- 如果 require 失败，脚本不会直接报错中断，而是进入 else / warn 的兜底逻辑。
--
-- require(...) 用来加载 ModuleScript 返回的数据。
-- 这里期望 Config 模块返回一个 table，例如：
-- { GRID_STUDS = 4 }

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local damageRemote = remotes:WaitForChild("RequestDamageMonster") :: RemoteEvent
local useSkillRemote = remotes:WaitForChild("RequestUseWeaponSkill") :: RemoteEvent

-- RemoteEvent 是 Roblox 客户端和服务端通信的常见 API。
-- 这里拿到了两个远程事件：
-- 1. RequestDamageMonster：请求攻击怪物
-- 2. RequestUseWeaponSkill：请求释放武器技能
--
-- 注意：名字里有 Request（请求），说明客户端只是“申请”，
-- 真正是否生效、打到谁，通常仍由服务端决定。

local function isEquipped(): boolean
	return tool.Parent == (player.Character or nil)
end

local function normalizeAnimationId(rawId: string): string?
	local trimmed = string.gsub(rawId, "^%s*(.-)%s*$", "%1")
	if trimmed == "" then
		return nil
	end

	local numericId = string.match(trimmed, "^rbxassetid://(%d+)$") or string.match(trimmed, "^(%d+)$")
	if not numericId then
		return nil
	end

	return "rbxassetid://" .. numericId
end

-- [修改内容] 新增函数：播放待机动画
local function playIdleAnimation()
	-- [修改内容] 先停止旧的待机动画，防止重复叠加
	if idleTrack then
		idleTrack:Stop()
		idleTrack = nil
	end

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	local animationId = normalizeAnimationId(CUSTOM_IDLE_ANIMATION_ID)

	if not hum or not animator or not animationId then
		return
	end

	-- [修改内容] 创建并配置动画对象
	local animation = Instance.new("Animation")
	animation.AnimationId = animationId

	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if ok and trackOrError then
		idleTrack = trackOrError :: AnimationTrack
		-- [修改内容] 非常关键：优先级必须设为 Action 或更高，才能覆盖默认的握持动作
		idleTrack.Priority = Enum.AnimationPriority.Action 
		-- [修改内容] 必须设置为循环播放
		idleTrack.Looped = true 
		idleTrack:Play(0.3) -- [修改内容] 0.3 秒淡入时间，让姿势切换更平滑
	end
	
	animation:Destroy() -- [修改内容] 加载完成后可销毁实例，轨道已保留在内存中
end

-- [修改内容] 新增函数：停止待机动画
local function stopIdleAnimation()
	if idleTrack then
		idleTrack:Stop(0.3) -- [修改内容] 0.3 秒淡出
		idleTrack = nil
	end
end

local atktime , playSpeed ,cdTime = 0.2 , 1.5 , 0.5 --伤害生效时间，播放速度，攻击动作的 CD 时间

local function playDefaultAttackAnimation()
	print("默认攻击动画")

	local v = Instance.new("StringValue")
	v.Name = "toolanim"
	v.Value = "Slash"
	v.Parent = tool

	--延迟伤害生效时间 atktime
	task.delay(atktime, function()
		if v.Parent then v:Destroy() end
	end)

	task.spawn(function()
		task.wait(0.05)
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
				--只加速攻击动作（Action 及以上）
				if track.Priority ~= Enum.AnimationPriority.Core and track.Priority ~= Enum.AnimationPriority.Idle and track.Priority ~= Enum.AnimationPriority.Movement then
					track:AdjustSpeed(playSpeed)
				end
			end
		end
	end)
end




local function playAttackAnimation()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	local animationId = normalizeAnimationId(CUSTOM_ATTACK_ANIMATION_ID)

	if not hum or not animator or not animationId then
		playDefaultAttackAnimation()
		return
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = animationId

	local ok, trackOrError = pcall(function()
		return animator:LoadAnimation(animation)
	end)

	if not ok or not trackOrError then
		animation:Destroy()
		warn("[WeaponClient] 自定义攻击动画加载失败，切回默认攻击动画：", trackOrError)
		playDefaultAttackAnimation()
		return
	end

	local track = trackOrError :: AnimationTrack
	track.Priority = Enum.AnimationPriority.Action
	--track:Play(淡入时间, 权重, 播放速度)
	track:Play(0.05, 1, playSpeed)

	task.delay(2, function()
		animation:Destroy()
	end)
end

-- 这个函数仍然使用 Roblox 默认 Animate 脚本的旧机制：
-- 在 Tool 下临时创建一个名为 toolanim 的 StringValue 来触发挥砍动作。
--
-- 这次和之前不同的地方有两个：

--
-- 这样做的目标是：
-- - 默认挥刀动作大约 0.6 秒
-- - 2 倍速后，大约会在 0.3 秒左右播放完成
-- - 从而和新的攻击 CD 0.3 秒对齐
-- - 同时避免把跑步、待机这些基础动作也一起加速，导致移动表现异常
--
-- 用到的 API：
-- Instance.new("StringValue")：创建一个字符串值对象
-- task.delay(秒数, 函数)：延迟执行函数
-- task.spawn(function() ... end)：开一个新的异步任务，不阻塞当前逻辑
-- task.wait(秒数)：短暂等待，给默认动画一点时间开始播放
-- FindFirstChildOfClass("Humanoid")：在角色中查找 Humanoid
-- FindFirstChildOfClass("Animator")：在 Humanoid 中查找 Animator
-- animator:GetPlayingAnimationTracks()：获取当前正在播放的动画轨道
-- track.Priority：读取动画轨道优先级，用来区分基础动作和攻击动作
-- track:AdjustSpeed(2.0)：把动画轨道速度调整为 2 倍
-- :Destroy()：销毁对象

-- 严格的攻击状态锁。
-- 和“记录上次攻击时间，再比较时间差”不同，
-- 这里直接用一个布尔值表示：当前是否正处于一次完整攻击周期中。
--
-- 好处是：
-- 1. 逻辑更直接，点击时先看是否上锁
-- 2. 对连续点击/连点屏幕的拦截更严格
-- 3. 只有当整段攻击流程结束后，才会明确解锁
local isAttacking = false

local function getTargetFromScreenCenter(): Instance?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local viewport = camera.ViewportSize
	local center = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)

	local unitRay = camera:ViewportPointToRay(center.X, center.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Blacklist

	local character = player.Character
	if character then
		params.FilterDescendantsInstances = { character }
	end

	local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 500, params)
	return result and result.Instance or nil
end

-- 这个函数的作用：
-- 从“屏幕正中心”发出一条射线，看看玩家当前正对着什么物体。
--
-- 为什么需要它？
-- - 鼠标操作在 PC 上比较方便
-- - 但手机或手柄不一定有鼠标指向目标
-- - 所以可以用屏幕中心作为瞄准点做兜底
--
-- 关键 API 解释：
-- 1. workspace.CurrentCamera
--    当前客户端使用的相机
-- 2. camera.ViewportSize
--    当前屏幕/视口的宽高像素
-- 3. camera:ViewportPointToRay(x, y)
--    把屏幕上的一个点转成 3D 世界中的射线
-- 4. RaycastParams.new()
--    射线检测参数对象，用来配置过滤规则
-- 5. workspace:Raycast(origin, direction, params)
--    从 origin 朝 direction 方向发射射线，返回命中结果
--
-- 这里还把玩家自己的 character 加入黑名单过滤，
-- 避免射线先打到自己身上。

local function getMouseTarget(): Instance?
	local mouse = player:GetMouse()
	return mouse.Target
end

-- 这个函数返回鼠标当前指向的 3D 物体。
-- 对 PC 玩家很常见，但在移动端/手柄场景下不一定可靠。
--
-- player:GetMouse() 是较经典的本地输入 API，
-- mouse.Target 表示鼠标当前指向的 BasePart（或相关实例）。


local function tryAttack()
	-- 这是本脚本最核心的函数：尝试进行一次普通攻击。
--
-- 现在的攻击流程被重构成“动作先开始，伤害后触发”的节奏：
-- 1. 先确认武器已装备
-- 2. 再检查是否已经处于一次攻击周期中（Debounce 锁）
-- 3. 立刻播放一次本地挥剑动作
-- 4. 延迟 0.15 秒，等挥剑进入中段时再做伤害判定
-- 5. 优先用“前方 2 格、180 度”的扇形范围检测怪物
-- 6. 如果范围检测不可用，再退回到鼠标目标/屏幕中心射线兜底
-- 7. 0.3 秒完整攻击周期结束后，再解除锁，允许下一次攻击
--
-- 关键点说明：
-- isAttacking：严格的攻击锁，true 时表示这 0.3 秒攻击周期还没结束。
-- task.delay(0.15, ...)：把真正的命中检测延后 0.15 秒。
-- task.delay(0.3, ...)：在完整攻击周期结束后统一解锁。
-- monstersFolder：怪物集合，优先用于近战范围判定。
-- forward = hrp.CFrame.LookVector：玩家当前朝向。
-- forward:Dot(dir) >= 0：判断目标是否位于角色前方半圆。
-- getMouseTarget() / getTargetFromScreenCenter()：兜底获取瞄准目标。
-- damageRemote:FireServer(target)：通知服务端处理这次伤害请求。
--
-- 注意：
-- 这里只做“客户端时机控制 + 基础范围过滤”。
-- 真正是否命中、是否可以扣血，仍然应该由服务端最终校验。

	if not isEquipped() then return end

	-- 【防连点核心】如果当前正在攻击（处于0.3秒的周期内），则无视玩家的点击
	if isAttacking then return end
	isAttacking = true

	playAttackAnimation()

	-- 延迟 0.15s 执行伤害判定，完美对齐挥刀动作中段
	task.delay(0.2, function()
		if not isEquipped() then return end
		
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then return end

		-- 【修复点2】恢复前方的扇形检测逻辑，并保留 0.15s 的同步延迟
		local monstersFolder = workspace:FindFirstChild("Monsters")
		if monstersFolder and monstersFolder:IsA("Folder") then
			local maxDist = 2 * (Config.GRID_STUDS or 4)
			local maxDist2 = maxDist * maxDist
			local forward = hrp.CFrame.LookVector

			for _, inst in ipairs(monstersFolder:GetChildren()) do
				if inst:GetAttribute("IsMonster") == true and inst:GetAttribute("Dead") ~= true then
					local pos: Vector3?
					local targetForRemote: Instance? = nil
					
					if inst:IsA("BasePart") then
						pos = inst.Position
						targetForRemote = inst
					elseif inst:IsA("Model") then
						pos = inst:GetPivot().Position
						targetForRemote = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
					end

					if pos and targetForRemote then
						local offset = pos - hrp.Position
						local dist2 = offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z
						if dist2 <= maxDist2 then
							local dir = offset.Magnitude > 0 and offset.Unit or forward
							if forward:Dot(dir) >= 0 then
								damageRemote:FireServer(targetForRemote)
							end
						end
					end
				end
			end
		else
			-- 兜底检测（以防找不到怪物文件夹）
			local target = getMouseTarget() or getTargetFromScreenCenter()
			if target then
				damageRemote:FireServer(target)
			end
		end
	end)

	-- 【冷却解锁】强制等待 0.3 秒后，才允许进行下一次攻击
	task.delay(cdTime, function()
		isAttacking = false
	end)
end


-- [修改内容] 修改事件绑定部分：增加装备与卸下的监听
tool.Activated:Connect(tryAttack)

-- [修改内容] 当玩家穿戴上武器时，触发待机动作
tool.Equipped:Connect(function()
	playIdleAnimation()
end)

-- [修改内容] 当玩家收回武器时，停止待机动作，恢复正常走路姿势
tool.Unequipped:Connect(function()
	stopIdleAnimation()
end)



tool.Activated:Connect(tryAttack)

-- Tool.Activated 是 Tool 的经典事件。
-- 一般在玩家点击鼠标左键、点击触屏攻击按钮，或执行对应操作时触发。
-- 这里把它连接到 tryAttack，表示“点击武器时尝试普通攻击”。

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Q then
		if not isEquipped() then
			return
		end
		useSkillRemote:FireServer()
	end
end)

-- UserInputService.InputBegan：监听“输入开始”的事件。
-- 参数说明：
-- input：本次输入的详细信息（按了哪个键、鼠标还是触摸等）
-- gameProcessed：这个输入是否已经被 Roblox 系统或 UI 先处理了
--
-- 为什么要先判断 gameProcessed？
-- - 例如玩家正在聊天框输入字母 Q
-- - 或者某个 UI 已经占用了这次按键
-- - 这时就不应该再触发游戏技能
--
-- input.KeyCode == Enum.KeyCode.Q：表示监听键盘 Q 键。
--
-- 这里还会再次检查 isEquipped()：
-- 只有武器装备在手上时，按 Q 才能释放技能。
--
-- useSkillRemote:FireServer()：
-- 不需要传目标，只是告诉服务端“玩家请求使用武器技能”。
-- 技能具体怎么放、是否 CD 中、是否满足条件，都应由服务端继续判断。
