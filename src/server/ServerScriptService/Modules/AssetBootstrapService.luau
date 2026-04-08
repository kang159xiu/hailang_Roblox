--!strict
-- ServerScriptService.Modules.AssetBootstrapService
-- 用来把你在 Workspace 里手动放入的“模板模型”复制成可供系统使用的外观资源。
--
-- 约定（你可以改成你自己的命名）：
-- Workspace 里存在：
--  - 武器1  (Model 或 BasePart)
--  - 怪物形象1 (Model 或 BasePart)
--
-- 本服务会在 ReplicatedStorage 下创建：
--  - WeaponAppearances/武器1..武器20
-- 并在 ReplicatedStorage.MonsterAppearances 下（如缺失）补齐：
--  - Lv1..Lv30

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AssetBootstrapService = {}

local function getWeaponTemplateNames(index: number): {string}
	local level2 = string.format("%02d", index)
	return {
		string.format("武器%s", level2),
		string.format("武器%d", index),
		string.format("武器 %s", level2),
		string.format("武器 %d", index),
	}
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

local function findDescendantByNames(root: Instance, names: {string}): Instance?
	for _, name in ipairs(names) do
		local direct = root:FindFirstChild(name)
		if direct then
			return direct
		end
	end

	for _, d in ipairs(root:GetDescendants()) do
		for _, name in ipairs(names) do
			if d.Name == name then
				return d
			end
		end
	end
	return nil
end

local function ensureFolder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = name
	nf.Parent = parent
	return nf
end

local function safeClone(inst: Instance): Instance?
	local ok, clone = pcall(function()
		return inst:Clone()
	end)
	if not ok then
		return nil
	end
	return clone
end

local function buildWeaponAppearances()
	local appearances = ensureFolder(ReplicatedStorage, "WeaponAppearances")

	-- 如果已经有 20 个了，就不重复生成
	local already = 0
	for i = 1, 20 do
		if appearances:FindFirstChild("武器" .. tostring(i)) then
			already += 1
		end
	end
	if already >= 20 then
		return
	end

	local base = findDescendantByNames(workspace, getWeaponTemplateNames(1))
	if not base then
		warn("[AssetBootstrapService] 未找到 Workspace.weapon/Workspace 中的 武器01/武器1（无法自动生成武器外观）")
		return
	end

	for i = 1, 20 do
		local name = "武器" .. tostring(i)
		if appearances:FindFirstChild(name) then
			continue
		end

		local c = safeClone(base)
		if not c then
			warn("[AssetBootstrapService] 克隆失败：", base:GetFullName())
			break
		end
		c.Name = name
		c.Parent = appearances
	end
end

local function buildMonsterAppearances()
	local monsterAppearances = ReplicatedStorage:FindFirstChild("MonsterAppearances")
	if not monsterAppearances or not monsterAppearances:IsA("Folder") then
		-- 你当前项目里应该已经有这个 Folder；没有就创建一个
		monsterAppearances = ensureFolder(ReplicatedStorage, "MonsterAppearances")
	end

	-- 如果 怪物形象1..怪物形象30 都有了，就不重复生成
	local okCount = 0
	for i = 1, 30 do
		if monsterAppearances:FindFirstChild("怪物形象" .. tostring(i)) then
			okCount += 1
		end
	end
	if okCount >= 30 then
		return
	end

	local base = findDescendantByNames(workspace, getMonsterTemplateNames(1))
	if not base then
		warn("[AssetBootstrapService] 未找到 Workspace.'Monster image'/Workspace 中的 怪物形象01/怪物形象1（无法自动生成怪物外观）")
		return
	end

	for i = 1, 30 do
		local name = "怪物形象" .. tostring(i)
		if monsterAppearances:FindFirstChild(name) then
			continue
		end

		local c = safeClone(base)
		if not c then
			warn("[AssetBootstrapService] 克隆失败：", base:GetFullName())
			break
		end
		c.Name = name
		c.Parent = monsterAppearances
	end
end

function AssetBootstrapService.Init()
	buildWeaponAppearances()
	buildMonsterAppearances()
end

return AssetBootstrapService
