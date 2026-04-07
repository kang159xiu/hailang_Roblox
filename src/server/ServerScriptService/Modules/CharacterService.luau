--!strict
-- ServerScriptService.Modules.CharacterService

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local CharacterService = {}

local function applyStats(player: Player, humanoid: Humanoid, fullHeal: boolean?)
	local stats = PlayerData.Get(player)

	-- speed
	humanoid.WalkSpeed = Config.WALK_SPEED_BASE + stats.SpeedLevel * Config.WALK_SPEED_PER_UPGRADE

	-- health
	local maxHealth = Config.HEALTH_BASE + stats.HealthLevel * Config.HEALTH_PER_UPGRADE
	humanoid.MaxHealth = maxHealth

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

function CharacterService.Init()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid") :: Humanoid
			applyStats(player, humanoid, true)
		end)
	end)

	-- 已经在游戏里的玩家
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				applyStats(player, humanoid, false)
			end
		end
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid") :: Humanoid
			applyStats(player, humanoid, true)
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
