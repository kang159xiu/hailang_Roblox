--!strict
-- ServerScriptService.Modules.ZoneService
-- 负责收集场景中的区域 Part（拿取区域、商人区域等）

local ZoneService = {}

local PICKUP_ZONE_PREFIX = "拿取区域"
local MERCHANT_PART_NAME = "商人区域"
local WEAPON_MERCHANT_PART_NAME = "武器商人区域"

export type PickupZone = {
	Level: number,
	Part: BasePart,
}

local function findInWorkspace(name: string): Instance?
	-- 兼容把区域放进 Folder 的情况（例如 Workspace."Pick-up area"）
	-- 优先在 Pick-up area 里找（如果存在），否则在整个 Workspace 递归查找。
	local pickupRoot = workspace:FindFirstChild("Pick-up area")
	if pickupRoot then
		local inst = pickupRoot:FindFirstChild(name, true)
		if inst then
			return inst
		end
	end
	return workspace:FindFirstChild(name, true)
end

function ZoneService.GetPickupZones(): {PickupZone}
	local zones: {PickupZone} = {}
	for level = 1, 10 do
		local name = string.format("%s%d级", PICKUP_ZONE_PREFIX, level)
		local inst = findInWorkspace(name)
		if inst and inst:IsA("BasePart") then
			table.insert(zones, { Level = level, Part = inst })
		end
	end
	table.sort(zones, function(a, b)
		return a.Level < b.Level
	end)
	return zones
end

function ZoneService.GetMerchantPart(): BasePart?
	local inst = findInWorkspace(MERCHANT_PART_NAME)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	return nil
end

function ZoneService.GetWeaponMerchantPart(): BasePart?
	local inst = findInWorkspace(WEAPON_MERCHANT_PART_NAME)
	if inst and inst:IsA("BasePart") then
		return inst
	end
	return nil
end

return ZoneService
