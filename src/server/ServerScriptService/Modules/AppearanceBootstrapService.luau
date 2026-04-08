--!strict
-- ServerScriptService.Modules.AppearanceBootstrapService
-- 运行时从 Workspace 中的模板（武器1/怪物形象1）生成复制品到 ReplicatedStorage，供武器/怪物外观使用。
-- 规则：
-- 1) 你在 Workspace 放好：武器1、怪物形象1（必需）
-- 2) 模板可以放在 Workspace 任意层级（支持 FindFirstChild(..., true) 递归查找）
-- 3) 如果你后续自己做了 武器2/武器3... 或 怪物形象2...，本服务会优先用对应编号的模板；
--    如果没做，就用 1 号模板克隆补齐。


local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AppearanceBootstrapService = {}

local function ensureFolder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local newF = Instance.new("Folder")
	newF.Name = name
	newF.Parent = parent
	return newF
end

local function destroyAllByName(parent: Instance, name: string)
	while true do
		local inst = parent:FindFirstChild(name)
		if not inst then
			break
		end
		inst:Destroy()
	end
end

local function cloneTemplate(source: Instance): Instance
	-- 直接克隆模板对象（会包含其所有子元件），用于生成外观资源
	return source:Clone()
end

local function getMonsterTemplateNames(index: number): {string}
	local level2 = string.format("%02d", index)
	return {
		string.format("怪物形象%s", level2),
		string.format("怪物形象%d", index),
		string.format("怪物形象 %s", level2),
		string.format("怪物形象 %d", index),
	}
end

local function getWeaponTemplateNames(index: number): {string}
	local level2 = string.format("%02d", index)
	return {
		string.format("武器%s", level2),
		string.format("武器%d", index),
		string.format("武器 %s", level2),
		string.format("武器 %d", index),
	}
end

local function scoreTemplate(inst: Instance): number
	-- 仅用于在同名候选中择优：优先 Model，其次 Folder，其次 BasePart；然后按子孙数量。
	-- 注意：Folder 仅作为“你明确把模板做成 Folder 并命名为 武器1/怪物形象1”时的兜底。
	local score = 0
	if inst:IsA("Model") then
		score += 1000000
	elseif inst:IsA("Folder") then
		score += 200000
	elseif inst:IsA("BasePart") then
		score += 100000
	else
		return -1
	end
	return score + #inst:GetDescendants()
end

local function hasAnyBasePart(inst: Instance): boolean
	if inst:IsA("BasePart") then
		return true
	end
	return inst:FindFirstChildWhichIsA("BasePart", true) ~= nil
end

local function isAllowedTemplate(inst: Instance): boolean
	-- 只接受能产生可见外观的模板：BasePart 或“内部至少有一个 BasePart 的 Model/Folder”
	if inst:IsA("BasePart") then
		return true
	end
	if inst:IsA("Model") or inst:IsA("Folder") then
		return hasAnyBasePart(inst)
	end
	return false
end

local function needsRefresh(existing: Instance, src: Instance): boolean
	-- 仅在“类型不匹配/明显不完整”时替换。
	if not isAllowedTemplate(src) then
		return false
	end
	if not isAllowedTemplate(existing) then
		return true
	end

	-- 更偏好 Model（最稳定）
	if src:IsA("Model") and not existing:IsA("Model") then
		return true
	end

	local srcDesc = #src:GetDescendants()
	local exDesc = #existing:GetDescendants()
	-- 只要源模板更复杂，就刷新（外观资源属于运行时缓存，刷新成本低，但能避免“空外观/缺零件”）
	if srcDesc > exDesc then
		return true
	end
	-- 特判：已有外观完全空（常见于之前误生成了 Folder/空容器）
	if exDesc == 0 and srcDesc > 0 then
		return true
	end

	return false
end

local function findByNames(root: Instance, names: {string}): Instance?
	local nameSet: {[string]: true} = {}
	for _, n in ipairs(names) do
		nameSet[n] = true
	end

	local best: Instance? = nil
	local bestScore = -1

	local function consider(candidate: Instance)
		if not isAllowedTemplate(candidate) then
			return
		end
		local s = scoreTemplate(candidate)
		if s > bestScore then
			bestScore = s
			best = candidate
		end
	end

	local function visit(inst: Instance)
		if nameSet[inst.Name] then
			-- 1) 直接命中的对象（允许 Model/Folder/BasePart）
			consider(inst)

			-- 2) 如果命中的是某个零件/子物件，向上找最近的 Model 当作更完整的模板候选
			-- 注意：这里不要自动选父 Folder（很多项目会用 Folder 归档多个模板，选到会导致外观错乱/不可见）。
			local cur = inst.Parent
			while cur and cur ~= root do
				if cur:IsA("Model") then
					consider(cur)
					break
				end
				cur = cur.Parent
			end
		end
	end

	-- GetDescendants() 不包含 root 的直接子级；这里两者都遍历，避免漏掉 Workspace 直接放置的模板
	for _, ch in ipairs(root:GetChildren()) do
		visit(ch)
	end
	for _, inst in ipairs(root:GetDescendants()) do
		visit(inst)
	end

	return best
end

local function findWeaponTemplate(index: number): Instance?
	local weaponRoot = workspace:FindFirstChild("weapon")
	local names = getWeaponTemplateNames(index)
	if weaponRoot then
		-- 优先只取 weapon 文件夹的“直接子级”，避免误选到其它地方的同名对象
		for _, name in ipairs(names) do
			local direct = weaponRoot:FindFirstChild(name)
			if direct and isAllowedTemplate(direct) then
				return direct
			end
		end

		local found = findByNames(weaponRoot, names)
		if found then
			return found
		end
	end

	return findByNames(workspace, names)
end

local function findMonsterTemplate(index: number): Instance?
	local monsterRoot = workspace:FindFirstChild("Monster image")
	local names = getMonsterTemplateNames(index)
	if monsterRoot then
		-- 优先只取 Monster image 文件夹的“直接子级”，避免误选到其它地方的同名对象
		for _, name in ipairs(names) do
			local direct = monsterRoot:FindFirstChild(name)
			if direct and isAllowedTemplate(direct) then
				return direct
			end
		end

		local found = findByNames(monsterRoot, names)
		if found then
			return found
		end
	end

	return findByNames(workspace, names)
end

local function ensureWeaponAppearances()
	local base = findWeaponTemplate(1)
	if not base or not isAllowedTemplate(base) then
		warn("[AppearanceBootstrapService] 未找到武器模板：请在 Workspace.weapon 或 Workspace 任意位置放置 名称=武器01/武器1（Model/Folder/BasePart）")
		return
	end

	local folder = ensureFolder(ReplicatedStorage, "WeaponAppearances")

	for i = 1, 20 do
		local dstName = string.format("武器%d", i)
		local src = findWeaponTemplate(i) or base

		destroyAllByName(folder, dstName)

		local c = cloneTemplate(src)
		c.Name = dstName
		c.Parent = folder
	end
end

local function ensureMonsterAppearances()
	local base = findMonsterTemplate(1)
	if not base or not isAllowedTemplate(base) then
		warn("[AppearanceBootstrapService] 未找到怪物模板：请在 Workspace 任意位置放置 名称=怪物形象01/怪物形象1（Model/Folder/BasePart）")
		return
	end

	local folder = ensureFolder(ReplicatedStorage, "MonsterAppearances")

	for i = 1, 30 do
		local dstName = string.format("怪物形象%d", i)
		local src = findMonsterTemplate(i) or base

		destroyAllByName(folder, dstName)

		local c = cloneTemplate(src)
		c.Name = dstName
		c.Parent = folder
	end
end

function AppearanceBootstrapService.Init()
	ensureWeaponAppearances()
	ensureMonsterAppearances()
end

return AppearanceBootstrapService
