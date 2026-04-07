--!strict
-- ServerScriptService.Modules.CombatService

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local CombatService = {}

-- 计算玩家当前一次普通攻击的伤害
function CombatService.GetPlayerDamage(player: Player): number
	local stats = PlayerData.Get(player)
	local weaponLevel = stats.EquippedWeaponLevel or stats.WeaponLevel
	local weaponAttack = Config.WEAPON_ATTACK_BY_LEVEL[weaponLevel] or 10
	local add = stats.AttackLevel * Config.ATTACK_UPGRADE_ADD
	return weaponAttack + add
end

return CombatService
