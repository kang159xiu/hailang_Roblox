--!strict
-- 被玩家攻击击飞时的本地表现。
-- 服务端仍负责命中判定、距离校验、冷却和最终物理同步；客户端只在服务端确认后立即播放本机击飞，减少网络复制等待带来的卡顿感。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local playPlayerKnockbackRemote = remotes:WaitForChild("PlayPlayerKnockback") :: RemoteEvent

local knockbackTokenByUserId: {[number]: number} = {}

local function getCharacterParts(targetPlayer: Player): (Model?, Humanoid?, BasePart?)
	local character = targetPlayer.Character
	if not character then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return character, humanoid, nil
	end

	return character, humanoid, root :: BasePart
end

local function getSafeNumber(value: any, fallback: number, minValue: number, maxValue: number): number
	if type(value) ~= "number" then
		return fallback
	end
	return math.clamp(value, minValue, maxValue)
end

local function getNextKnockbackToken(userId: number): number
	local token = (knockbackTokenByUserId[userId] or 0) + 1
	knockbackTokenByUserId[userId] = token
	return token
end

local function playLocalKnockback(targetPlayer: Player, direction: Vector3, pushPower: any, upwardPower: any, angularVelocity: Vector3, duration: any)
	local character, humanoid, root = getCharacterParts(targetPlayer)
	if not character or not humanoid or not root then
		return
	end

	local horizontalDir = Vector3.new(direction.X, 0, direction.Z)
	horizontalDir = if horizontalDir.Magnitude > 0.1 then horizontalDir.Unit else Vector3.new(0, 0, 1)

	local safePushPower = getSafeNumber(pushPower, 80, 0, 140)
	local safeUpwardPower = getSafeNumber(upwardPower, 80, 0, 140)
	local safeDuration = getSafeNumber(duration, 0.35, 0.1, 1.2)

	local token = getNextKnockbackToken(targetPlayer.UserId)
	local isLocalTarget = targetPlayer == player

	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	-- 对所有客户端都立即做一次短时视觉预测：
	-- 1. 被击飞玩家本机能立刻感受到击飞；
	-- 2. 攻击者/旁观者也不用等服务端物理复制，能更快看到目标被弹开。
	root.CFrame = root.CFrame + Vector3.new(0, 1.5, 0)
	root.CFrame = CFrame.lookAt(root.Position, root.Position + horizontalDir)
		* CFrame.Angles(math.rad(90), 0, 0)
	root.AssemblyLinearVelocity = (horizontalDir * safePushPower) + Vector3.new(0, safeUpwardPower, 0)
	root.AssemblyAngularVelocity = angularVelocity

	task.delay(safeDuration, function()
		if token ~= knockbackTokenByUserId[targetPlayer.UserId] then
			return
		end

		if targetPlayer.Character == character and humanoid.Parent ~= nil and root.Parent ~= nil then
			root.AssemblyAngularVelocity = Vector3.zero
			-- 只有被击飞玩家本机负责恢复自己的控制状态；其他客户端只停止本地旋转预测，等待服务端权威状态同步。
			if isLocalTarget then
				humanoid.PlatformStand = false
				humanoid.AutoRotate = true
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end
	end)
end

playPlayerKnockbackRemote.OnClientEvent:Connect(function(targetUserId: any, direction: any, pushPower: any, upwardPower: any, angularVelocity: any, duration: any)
	if type(targetUserId) ~= "number" then
		return
	end
	if typeof(direction) ~= "Vector3" or typeof(angularVelocity) ~= "Vector3" then
		return
	end

	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if not targetPlayer then
		return
	end

	playLocalKnockback(targetPlayer, direction, pushPower, upwardPower, angularVelocity, duration)
end)