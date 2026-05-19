--!strict
-- 客户端倒地恢复：允许玩家被击飞/短暂倒地，倒地约 0.1 秒后自动尝试站起。
-- 注意：这里不再每帧扶正、不清角速度、不禁用 FallingDown/Ragdoll/Physics，避免吞掉击飞效果。

local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer
local RECOVERY_DELAY_SECONDS = 0.1

local FALL_RECOVERY_STATES = {
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Physics,
}

local FALL_RECOVERY_STATE_SET: {[Enum.HumanoidStateType]: boolean} = {}
for _, state in ipairs(FALL_RECOVERY_STATES) do
	FALL_RECOVERY_STATE_SET[state] = true
end

local stateConnection: RBXScriptConnection? = nil

local function disconnectCurrentCharacterHooks()
	if stateConnection then
		stateConnection:Disconnect()
		stateConnection = nil
	end
end

local function recoverHumanoidAfterDelay(humanoid: Humanoid)
	task.delay(RECOVERY_DELAY_SECONDS, function()
		if humanoid.Parent == nil or humanoid.Health <= 0 then
			return
		end

		humanoid.PlatformStand = false
		humanoid.Sit = false
		humanoid.AutoRotate = true
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end)
end

local function bindCharacter(character: Model)
	disconnectCurrentCharacterHooks()

	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or not humanoid:IsA("Humanoid") then
		return
	end

	stateConnection = humanoid.StateChanged:Connect(function(_, newState)
		if FALL_RECOVERY_STATE_SET[newState] then
			recoverHumanoidAfterDelay(humanoid)
		end
	end)
end

localPlayer.CharacterAdded:Connect(bindCharacter)
if localPlayer.Character then
	task.defer(bindCharacter, localPlayer.Character)
end