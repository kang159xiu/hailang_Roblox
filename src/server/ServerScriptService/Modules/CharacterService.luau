--!strict
-- ServerScriptService.Modules.CharacterService

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local CharacterService = {}

local FALL_RECOVERY_STATES = {
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Physics,
}

local function hookFallRecovery(humanoid: Humanoid)
	-- 允许玩家正常被击飞/倒地，只在进入倒地相关状态后延迟 0.1 秒尝试站起。
	-- 不再 SetStateEnabled(false)，否则会直接吞掉击飞/倒地物理表现。
	if humanoid:GetAttribute("FallRecoverHooked") == true then
		return
	end
	humanoid:SetAttribute("FallRecoverHooked", true)

	humanoid.StateChanged:Connect(function(_, newState)
		if table.find(FALL_RECOVERY_STATES, newState) ~= nil then
			task.delay(0.1, function()
				if humanoid.Parent == nil or humanoid.Health <= 0 then
					return
				end

				humanoid.PlatformStand = false
				humanoid.Sit = false
				humanoid.AutoRotate = true
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end)
		end
	end)
end

local function applyStats(player: Player, humanoid: Humanoid, fullHeal: boolean?)
	local stats = PlayerData.Get(player)
	hookFallRecovery(humanoid)

	-- 设置移动速度: 基础速度 + 速度等级 * 每级增加速度
	humanoid.WalkSpeed = Config.WALK_SPEED_BASE + stats.SpeedLevel * Config.WALK_SPEED_PER_UPGRADE

	-- 固定玩家最大血量：原“血量升级”已改为“跳跃升级”，不再提升 MaxHealth。
	local maxHealth = Config.HEALTH_BASE or 100
	humanoid.MaxHealth = maxHealth

	-- 跳跃升级：复用旧存档键 HealthLevel，避免老玩家数据丢失。
	humanoid.UseJumpPower = true
	humanoid.JumpPower = if Config.GetJumpPowerForLevel then Config.GetJumpPowerForLevel(stats.HealthLevel) else math.clamp((Config.JUMP_POWER_BASE or 50) + stats.HealthLevel * (Config.JUMP_POWER_PER_UPGRADE or 1), Config.JUMP_POWER_BASE or 50, Config.JUMP_POWER_MAX or 150)

	--如果要求完全恢复血量 (比如重生时)
	if fullHeal == true then
		humanoid.Health = maxHealth
		return
	end

	if humanoid.Health > maxHealth then
		humanoid.Health = maxHealth
	elseif humanoid.Health <= 0 then
		humanoid.Health = maxHealth
	end
end

-- [新增内容] 处理玩家死亡掉落头顶怪物的逻辑
local function hookCharacterDied(player: Player, character: Model, humanoid: Humanoid)
	humanoid.Died:Connect(function()
		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local dropPos = hrp and hrp.Position or Vector3.new(0, 5, 0)
		
		-- 局部引入避免循环依赖
		local InventoryService = require(script.Parent:WaitForChild("InventoryService"))
		local MonsterService = require(script.Parent:WaitForChild("MonsterService"))
		
		-- 获取并清空头顶携带的怪物
		local droppedMonsters = InventoryService.DropAllCarried(player)
		if droppedMonsters and #droppedMonsters > 0 then
			for _, monsterData in ipairs(droppedMonsters) do
				-- 在玩家尸体周围随机散落
				local offset = Vector3.new(math.random(-4, 4), 0, math.random(-4, 4))
				local spawnPos = dropPos + offset
				
				MonsterService.SpawnDroppedMonster(
					monsterData.MonsterLevel,
					monsterData.Value,
					monsterData.GoldPerSec,
					spawnPos,
					"PlayerDeathDrop", -- 掉落怪的特殊ZoneKey标识
					(monsterData :: any).UpgradeLevel or 1,
					(monsterData :: any).SourceZoneLevel or 1,
					(monsterData :: any).ExpireUnix
				)
			end
		end
	end)
end

function CharacterService.Init()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid") :: Humanoid
			applyStats(player, humanoid, true)
			hookCharacterDied(player, character, humanoid) -- [修改内容] 绑定死亡事件
		end)
	end)

	-- 已经在游戏里的玩家
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				applyStats(player, humanoid, false)
				hookCharacterDied(player, player.Character, humanoid) -- [修改内容] 绑定死亡事件
			end
		end
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid") :: Humanoid
			applyStats(player, humanoid, true)
			hookCharacterDied(player, character, humanoid) -- [修改内容] 绑定死亡事件
		end)
	end
end

function CharacterService.Refresh(player: Player, fullHeal: boolean?)
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	applyStats(player, humanoid, fullHeal)
end

return CharacterService
