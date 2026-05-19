--!strict
-- 被玩家攻击击飞时的本地表现。
-- 服务端仍负责命中判定、距离校验、冷却和最终物理同步；客户端只在服务端确认后立即播放本机击飞，减少网络复制等待带来的卡顿感。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local playPlayerKnockbackRemote = remotes:WaitForChild("PlayPlayerKnockback") :: RemoteEvent

local knockbackTokenByUserId: {[number]: number} = {}
local visualCloneByUserId: {[number]: Model} = {}

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

local function setCharacterLocalTransparency(character: Model, transparency: number)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = transparency
		end
	end
end

local function clearVisualClone(userId: number)
	local oldClone = visualCloneByUserId[userId]
	if oldClone then
		oldClone:Destroy()
		visualCloneByUserId[userId] = nil
	end
end

local function createVisualClone(character: Model, userId: number): Model?
	clearVisualClone(userId)

	local oldArchivable = character.Archivable
	character.Archivable = true
	local ok, clonedCharacter = pcall(function()
		return character:Clone()
	end)
	character.Archivable = oldArchivable

	if not ok or not clonedCharacter or not clonedCharacter:IsA("Model") then
		return nil
	end

	clonedCharacter.Name = character.Name .. "_KnockbackVisual"
	for _, descendant in clonedCharacter:GetDescendants() do
		if descendant:IsA("BaseScript") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		elseif descendant:IsA("Humanoid") then
			descendant.AutoRotate = true
			descendant.PlatformStand = false
			descendant.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end

	clonedCharacter.Parent = workspace
	visualCloneByUserId[userId] = clonedCharacter
	return clonedCharacter
end

local function playAttackerVisualKnockback(targetPlayer: Player, character: Model, root: BasePart, horizontalDir: Vector3, safePushPower: number, safeUpwardPower: number, angularVelocity: Vector3, safeDuration: number, token: number)
	local clone = createVisualClone(character, targetPlayer.UserId)
	if not clone then
		return
	end

	setCharacterLocalTransparency(character, 1)

	local startTime = os.clock()
	local startPosition = root.Position + Vector3.new(0, 1.5, 0)
	local baseCFrame = CFrame.lookAt(startPosition, startPosition + horizontalDir)
	clone:PivotTo(baseCFrame)

	task.spawn(function()
		while clone.Parent ~= nil and token == knockbackTokenByUserId[targetPlayer.UserId] do
			local elapsed = os.clock() - startTime
			if elapsed >= safeDuration then
				break
			end

			local position = startPosition
				+ ((horizontalDir * safePushPower) + Vector3.new(0, safeUpwardPower, 0)) * elapsed
				+ Vector3.new(0, -workspace.Gravity * 0.125 * elapsed * elapsed, 0)
			clone:PivotTo(CFrame.lookAt(position, position + horizontalDir))

			RunService.RenderStepped:Wait()
		end

		if token == knockbackTokenByUserId[targetPlayer.UserId] and targetPlayer.Character == character then
			setCharacterLocalTransparency(character, 0)
		end
		clearVisualClone(targetPlayer.UserId)
	end)
end

local function playLocalKnockback(targetPlayer: Player, direction: Vector3, pushPower: any, upwardPower: any, angularVelocity: Vector3, duration: any, attackerUserId: any)
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

	-- 只有被击飞玩家本机直接驱动自己的真实角色物理。
	-- 攻击者/旁观者不再本地改远端玩家 RootPart，避免和服务端/目标玩家复制状态打架，导致“横着卡顿”。
	if not isLocalTarget then
		if type(attackerUserId) == "number" and attackerUserId == player.UserId then
			playAttackerVisualKnockback(targetPlayer, character, root, horizontalDir, safePushPower, safeUpwardPower, angularVelocity, safeDuration, token)
		end
		return
	end

	-- 被击飞玩家本机立即驱动真实角色，减少网络复制等待带来的卡顿感。
	root.CFrame = root.CFrame + Vector3.new(0, 1.5, 0)
	root.CFrame = CFrame.lookAt(root.Position, root.Position + horizontalDir)
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

playPlayerKnockbackRemote.OnClientEvent:Connect(function(targetUserId: any, direction: any, pushPower: any, upwardPower: any, angularVelocity: any, duration: any, attackerUserId: any)
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

	playLocalKnockback(targetPlayer, direction, pushPower, upwardPower, angularVelocity, duration, attackerUserId)
end)