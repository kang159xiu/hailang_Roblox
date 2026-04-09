--!strict
-- ReplicatedStorage.GameModules.Config
--
-- 所有“表数据”都集中在这里，后期你只需要改这里就能调整数值。

local Config = {}

-- =====================
-- 单位/通用配置
-- =====================

-- “格”对应多少 studs（不确定的话先用 4，后期你可以改）
Config.GRID_STUDS = 4

-- 怪生成最大同时数量（注意：若希望每个区域允许到 10 只怪，请保证该上限 >= 区域数 * 10）
Config.MAX_ALIVE_MONSTERS = 120

-- 每个怪生成后存在时间（秒），到点消失（即使没人打/拿）
Config.MONSTER_LIFETIME_SECONDS = 60

-- 每个区域刷新检查间隔：随机 10~60 秒
Config.SPAWN_INTERVAL_MIN = 10
Config.SPAWN_INTERVAL_MAX = 60

-- 每个区域数量范围：至少多少只怪 / 最多允许增长到多少只怪
Config.MIN_MONSTERS_PER_ZONE = 2
Config.MAX_MONSTERS_PER_ZONE = 10

-- 补怪参数：每次补 1~3 只，每批间隔 5 秒
Config.REPLENISH_BATCH_MIN = 1
Config.REPLENISH_BATCH_MAX = 3
Config.REPLENISH_BATCH_INTERVAL_SECONDS = 5

-- =====================
-- 玩家金币与升级
-- =====================

-- 新玩家初始金币（只在 PlayerAdded 初始化时生效）
Config.PLAYER_START_GOLD = 100000000

Config.WALK_SPEED_BASE = 16
Config.WALK_SPEED_PER_UPGRADE = 1

-- 速度升级花费：level * (level * 50)
function Config.GetSpeedUpgradeCost(level: number): number
	return level * (level * 50)
end

-- 攻击力升级花费：level * (level * 100)
function Config.GetAttackUpgradeCost(level: number): number
	return level * (level * 100)
end

-- 攻击力每次升级增加多少（你确认：+10/级）
Config.ATTACK_UPGRADE_ADD = 10



-- 血量升级（你没给具体数值，这里先给一个常用占位，后期你再改）
Config.HEALTH_BASE = 100
Config.HEALTH_PER_UPGRADE = 20

-- 血量升级花费：level * (level * 80)（占位，可改）
function Config.GetHealthUpgradeCost(level: number): number
	return level * (level * 80)
end

-- =====================
-- 携带怪数量升级（最多 5 个）
-- =====================

-- 默认可携带数量 = 1，每升级 1 级 +1，最多 5。
Config.CARRY_MAX_BASE = 1
Config.CARRY_MAX_CAP = 5

-- 升级价格（w=万）：10w, 100w, 1000w, 10000w
Config.CARRY_UPGRADE_COSTS = {
	100000,      -- Lv.1
	1000000,     -- Lv.2
	10000000,    -- Lv.3
	100000000,   -- Lv.4
}

function Config.GetCarryUpgradeCost(level: number): number?
	local costs = Config.CARRY_UPGRADE_COSTS
	local c = costs[level]
	if type(c) == "number" then
		return c
	end
	return nil
end

function Config.GetCarryMax(carryLevel: number): number
	carryLevel = math.max(0, math.floor(tonumber(carryLevel) or 0))
	local v = Config.CARRY_MAX_BASE + carryLevel
	return math.clamp(v, Config.CARRY_MAX_BASE, Config.CARRY_MAX_CAP)
end

-- 怪头顶信息显示距离（studs）：距离远只显示“倒计时”
Config.MONSTER_INFO_SHOW_DISTANCE = 15

-- 详细信息显示距离（studs）：距离近时才显示价值/金币产出等
Config.MONSTER_DETAIL_SHOW_DISTANCE = 6

-- 武器图片（占位，后期你可以填 rbxassetid）
Config.WEAPON_IMAGE_ID_BY_LEVEL = {
	-- [1] = "rbxassetid://0",
}

	-- 武器名称表：1~20级对应显示名称（用于热键栏 Tool 名称/商店显示等）
	-- 你后期只需要改这里的文字即可完成“武器改名”。
	Config.WEAPON_NAME_BY_LEVEL = {
		[1] = "武器1",
		[2] = "武器2",
		[3] = "武器3",
		[4] = "武器4",
		[5] = "武器5",
		[6] = "武器6",
		[7] = "武器7",
		[8] = "武器8",
		[9] = "武器9",
		[10] = "武器10",
		[11] = "武器11",
		[12] = "武器12",
		[13] = "武器13",
		[14] = "武器14",
		[15] = "武器15",
		[16] = "武器16",
		[17] = "武器17",
		[18] = "武器18",
		[19] = "武器19",
		[20] = "武器20",
	}

	-- =====================
	-- 怪（1~30级）
	-- =====================

Config.MONSTER_HP_BY_LEVEL = {
	50, 100, 150, 200, 250, 300, 400, 500, 600, 700,
	800, 1000, 1500, 2000, 2500, 3000, 3500, 4000, 5000,
	10000, 15000, 20000, 25000, 30000, 40000, 50000, 60000, 70000, 100000,
}

-- 1~30 级怪的价值（卖出获得金币）
Config.MONSTER_VALUE_BY_LEVEL = {
	10, 20, 30, 40, 50, 60, 70, 80, 90, 100,
	200, 250, 300, 350, 400, 450, 500, 550, 600, 650,
	1000, 1200, 1400, 1600, 1800, 2000, 2200, 2400, 2600, 3000,	
}

-- 1~30 级怪的每秒产金币（放置后产生，金币先累积到“未领取”）
Config.MONSTER_GOLD_PER_SEC_BY_LEVEL = {
	1, 2, 4, 6, 8, 10, 15, 20, 25, 30,
	40, 50, 60, 70, 80, 90, 100, 120, 130, 140,
	200, 250, 300, 350, 400, 450, 500, 550, 600, 700,
}

-- 拿取区域（1~10级）刷怪概率表
-- 说明：每个数组长度为 30，对应怪等级 1~30 的权重（不是百分比，权重越大越容易刷出）。
Config.ZONE_MONSTER_WEIGHTS = {
	[1]  = {100,80,60,40,20,10,5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
	[2]  = {10,40,80,100,100,80,40,20,10,5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
	[3]  = {0,5,10,20,40,80,100,100,80,40,20,10,5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
	[4]  = {0,0,0,5,10,20,40,80,100,100,80,40,20,10,5,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
	[5]  = {0,0,0,0,0,0,5,10,20,40,80,100,100,80,40,20,10,5,0,0,0,0,0,0,0,0,0,0,0,0},
	[6]  = {0,0,0,0,0,0,0,0,0,5,10,20,40,80,100,100,80,40,20,10,5,0,0,0,0,0,0,0,0,0},
	[7]  = {0,0,0,0,0,0,0,0,0,0,0,5,10,20,40,80,100,100,80,40,20,10,5,0,0,0,0,0,0,0},
	[8]  = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,10,20,40,80,100,100,80,40,20,10,5,0,0,0,0},
	[9]  = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,10,20,40,80,100,100,80,40,20,10,5,0},
	[10] = {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,5,10,20,40,60,80,100,100,120},
}

-- =====================
-- 岩浆（拿取区域危害）
-- =====================

-- 每个区域岩浆每秒伤害（DPS）
Config.LAVA_DAMAGE_PER_SEC_BY_ZONE = {100,200,300,500,800,1000,1500,2000,2500,3000}

-- 1~10 区域岩浆上升高度（格）：(1-2, 2-3, ..., 10-11)
Config.LAVA_HEIGHT_RANGE_GRIDS_BY_ZONE = {
	[1]  = {1,2},
	[2]  = {2,3},
	[3]  = {3,4},
	[4]  = {4,5},
	[5]  = {5,6},
	[6]  = {6,7},
	[7]  = {7,8},
	[8]  = {8,9},
	[9]  = {9,10},
	[10] = {10,11},
}

-- =====================
-- 武器（1~20）
-- =====================

Config.WEAPON_ATTACK_BY_LEVEL = {
	10, 50, 100, 200, 400, 600, 1000, 1500, 2000, 2200,
	2500, 3000, 3500, 4000, 4500, 5000, 5500,
	-- 18~20 你没给基础攻击，这里先让它 = 技能伤害，后面你可改
	6000, 7000, 8000,
}

-- 武器价格（w=万）
Config.WEAPON_PRICE_BY_LEVEL = {
	0, 100, 1000, 5000, 10000, 20000, 30000, 40000, 60000, 70000,
	80000, 90000, 100000, 150000, 200000, 250000, 300000, 900000, 1500000, 2000000,
}

-- 技能（18/19/20）固定伤害 & 冷却
Config.SKILL_COOLDOWN_SECONDS = 1
Config.SKILL18_PROJECTILE_DAMAGE = 5000
Config.SKILL19_TICK_DAMAGE = 7000
Config.SKILL20_AOE_DAMAGE = 8000

return Config
