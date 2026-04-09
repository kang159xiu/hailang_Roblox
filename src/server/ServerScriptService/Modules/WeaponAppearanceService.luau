--!strict
-- ServerScriptService.Modules.WeaponAppearanceService
-- 根据玩家 WeaponLevel，把对应“武器外观”焊到 Tool.Handle 上，让玩家真正手持武器。
-- 外观来源：ReplicatedStorage.WeaponAppearances（由 AppearanceBootstrapService 从 Workspace.武器1 复制生成）

--

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponAppearanceService = {}

local function getEquippedWeaponLevel(player: Player): number
	local v = player:GetAttribute("EquippedWeaponLevel")
	if type(v) == "number" then
		return v
	end
	v = player:GetAttribute("WeaponLevel")
	if type(v) == "number" then
		return v
	end
	return 1
end

local function isWeaponTool(inst: Instance): boolean
	return inst:IsA("Tool") --and inst:GetAttribute("IsWeaponTool") == true
end

local function getToolWeaponLevel(tool: Tool): number?
	local v = tool:GetAttribute("WeaponLevel")
	if type(v) == "number" then
		return v
	end
	return nil
end

local function getAppearanceTemplate(level: number): Instance?
	local folder = ReplicatedStorage:FindFirstChild("WeaponAppearances")
	if not folder or not folder:IsA("Folder") then
		return nil
	end

	local level2 = string.format("%02d", level)
	return folder:FindFirstChild(string.format("武器%s", level2))
		or folder:FindFirstChild(string.format("武器%d", level))
		or folder:FindFirstChild(string.format("武器 %s", level2))
		or folder:FindFirstChild(string.format("武器 %d", level))
		or folder:FindFirstChild("武器01")
		or folder:FindFirstChild("武器1")
		or folder:FindFirstChild("武器 01")
		or folder:FindFirstChild("武器 1")
end

local function findFirstNamedBasePart(root: Instance, names: {string}): BasePart?
	for _, name in ipairs(names) do
		local direct = root:FindFirstChild(name)
		if direct and direct:IsA("BasePart") then
			return direct
		end

		local deep = root:FindFirstChild(name, true)
		if deep and deep:IsA("BasePart") then
			return deep
		end
	end

	return nil
end

local function buildNameVariants(name: string): {string}
	local variants = { name }
	local numberSuffix = string.match(name, "(%d+)$")
	if not numberSuffix then
		return variants
	end

	local asNumber = tonumber(numberSuffix)
	if not asNumber then
		return variants
	end

	local prefix = string.sub(name, 1, #name - #numberSuffix)
	local padded = prefix .. string.format("%02d", asNumber)
	local plain = prefix .. tostring(asNumber)

	if padded ~= name then
		table.insert(variants, padded)
	end
	if plain ~= name and plain ~= padded then
		table.insert(variants, plain)
	end

	return variants
end

local function findTemplateRootPart(template: Instance): BasePart?
	if template:IsA("BasePart") then
		return template
	end

	if not template:IsA("Model") and not template:IsA("Folder") then
		return nil
	end

	-- 模型侧统一规则：优先使用“与模板同名的 Part”作为唯一对齐锚点。
	-- 但由于外观缓存名可能被规范化成“武器3”，而模板内部零件仍叫“武器03”，
	-- 因此这里同时兼容同编号的 01 / 1 两种命名。
	local sameNamePart = findFirstNamedBasePart(template, buildNameVariants(template.Name))
	if sameNamePart then
		return sameNamePart
	end

	-- 兼容旧模板：如果还没按“同名 Part”规范制作，再尝试 rootpart / PrimaryPart。
	local explicitRoot = findFirstNamedBasePart(template, {
		"rootpart",
		"RootPart",
		"rootPart",
	})
	if explicitRoot then
		return explicitRoot
	end

	if template:IsA("Model") and template.PrimaryPart then
		return template.PrimaryPart
	end

	-- 最后兼容老命名，避免旧资源立刻失效。
	local namedFallback = findFirstNamedBasePart(template, {
		"Root",
		"Handle",
		"WeaponRoot",
	})
	if namedFallback and namedFallback:IsA("BasePart") then
		return namedFallback
	end

	return template:FindFirstChildWhichIsA("BasePart", true)
end

local function ensureHandle(tool: Tool): BasePart

	local h = tool:FindFirstChild("Handle")
	if h and h:IsA("BasePart") then
		for _, child in ipairs(h:GetChildren()) do
			if child:IsA("Attachment") then
				child:Destroy()
			elseif child:IsA("Model") or child:IsA("Folder") then
				child:Destroy()
			elseif child:IsA("BasePart") and string.lower(child.Name) ~= "rootpart" then
				child:Destroy()
			end
		end
		
		-- 保留模板中 Handle 的原始尺寸，防止因尺寸改变导致默认的持握中心点偏移。
		-- 同时，TouchInterest 和 rootpart 依然会被安全保留；
		-- 但会清掉 Handle 下残留的旧外观模型，避免“玩家还握着模板武器”的现象。
		
		h.Transparency = 1
		h.CanCollide = false
		h.CanTouch = false
		h.CanQuery = false
		h.Massless = true
		return h
	end

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 1, 1)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.CanTouch = false
	handle.CanQuery = false
	handle.Massless = true
	handle.Parent = tool
	tool.RequiresHandle = true
	return handle
end

local function getToolRootPart(handle: BasePart): BasePart?
	local root = handle:FindFirstChild("rootpart")
	if root and root:IsA("BasePart") then
		return root
	end

	local deepRoot = handle:FindFirstChild("rootpart", true)
	if deepRoot and deepRoot:IsA("BasePart") then
		return deepRoot
	end

	return nil
end

--在给武器应用新的外观之前，清理掉（销毁）旧的外观模型
local function clearOldAppearance(tool: Tool)
	local old = tool:FindFirstChild("Appearance")
	if old then
		old:Destroy()
	end
end

local function stripJointsAndConstraints(root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		-- 你的 Workspace 模板里可能包含焊到 Baseplate 的 Weld，这会导致克隆出来的武器/怪物被“锁”在地板上。
		-- 所以这里统一清理掉所有 Joint/Constraint，再由我们重新 Weld 到 Tool.Handle。
		if d:IsA("JointInstance") then
			d:Destroy()
		elseif d:IsA("Constraint") then
			d:Destroy()
		end
	end
end

local function weldAllToHandle(handle: BasePart, root: Instance)
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.Massless = true

			local w = Instance.new("WeldConstraint")
			w.Part0 = handle
			w.Part1 = d
			w.Parent = d
		end
	end
end


local function applyAppearanceToTool(tool: Tool, weaponLevel: number)
	clearOldAppearance(tool)

	local handle = ensureHandle(tool)
	local targetPart = handle
	
	-- [修改内容] 注释/移除了 `tool.Grip = CFrame.identity`。
	-- Tool 从 Workspace.weaponModle 克隆后，自带了你在 Studio 中调试好的 Grip 属性（握持位置）。
	-- 移除这一行后，系统将严格遵循你模板中的 GripPos、GripRight、GripUp 和 GripForward。
	-- tool.Grip = CFrame.identity

	local template = getAppearanceTemplate(weaponLevel)
	if not template then
		-- 没有外观：至少让 Handle 可见，避免玩家以为武器“消失”
		handle.Transparency = 0
		handle.Size = Vector3.new(0.4, 0.4, 1.6)
		handle.Material = Enum.Material.Metal
		handle.Color = Color3.fromRGB(180, 180, 180)
		return
	end

	local appearanceFolder = Instance.new("Folder")
	appearanceFolder.Name = "Appearance"
	appearanceFolder.Parent = tool

	local clone = template:Clone()
	clone.Parent = appearanceFolder

	-- 清理模板里自带的 Weld/Constraint（例如焊在 Baseplate 上的 Weld）
	stripJointsAndConstraints(clone)

	local function toModelLike(inst: Instance): (Model?, BasePart?)
		if inst:IsA("Model") then
			return inst, nil
		end
		if inst:IsA("BasePart") then
			return nil, inst
		end
		if inst:IsA("Folder") then
			local m = Instance.new("Model")
			m.Name = inst.Name
			m.Parent = inst.Parent
			for _, ch in ipairs(inst:GetChildren()) do
				ch.Parent = m
			end
			inst:Destroy()
			return m, nil
		end
		return nil, nil
	end

	local model, part = toModelLike(clone)
	local applied = false

	local function moveHierarchyToTarget(rootPart: BasePart, rootInstance: Instance, targetCFrame: CFrame)
		local delta = targetCFrame * rootPart.CFrame:Inverse()
		for _, d in ipairs(rootInstance:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CFrame = delta * d.CFrame
			end
		end
		rootPart.CFrame = targetCFrame
	end

	-- 让武器模板中的“同名 Part（或兼容根 Part）”直接对齐到 Tool.Handle；
	-- 同时通过整体位移/旋转保持模型与该 Part 的相对位置不变。
	if model then
		local rootPart = findTemplateRootPart(model)
		if rootPart then
			moveHierarchyToTarget(rootPart, model, targetPart.CFrame)
			rootPart.Anchored = false
			rootPart.CanCollide = false
			rootPart.CanTouch = false
			rootPart.CanQuery = false
			rootPart.Massless = true

			local rootWeld = Instance.new("WeldConstraint")
			rootWeld.Part0 = handle
			rootWeld.Part1 = rootPart
			rootWeld.Parent = rootPart

			weldAllToHandle(handle, model)
			applied = true
		end
	elseif part then
		-- 如果模板本体就是 Part，则直接把该 Part 对齐到 Tool.Handle。
		moveHierarchyToTarget(part, part, targetPart.CFrame)
		part.Anchored = false
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = true

		local w = Instance.new("WeldConstraint")
		w.Part0 = handle
		w.Part1 = part
		w.Parent = part

		-- 关键：如果模板是“Part 作为根，子元件也是 Part/MeshPart”，需要把子元件也 Weld 到 Handle
		weldAllToHandle(handle, part)
		applied = true
	end

	-- 成功应用外观后，隐藏 Handle
	handle.Transparency = if applied then 1 else 0
end

function WeaponAppearanceService.ApplyToTool(tool: Tool, weaponLevel: number)
	applyAppearanceToTool(tool, weaponLevel)
end


local function tryApplyForPlayerTools(player: Player)
	--获取兜底武器等级（如果 Tool 上没有 WeaponLevel 属性，就用玩家身上装备的武器等级；如果玩家身上也没有，就默认为 1）
	local fallbackLevel = getEquippedWeaponLevel(player)
	--尝试给玩家当前背包和角色里所有 Tool.Apply 外观
	local function applyInContainer(container: Instance)
		for _, ch in ipairs(container:GetChildren()) do
			if isWeaponTool(ch) then
				local tool = ch :: Tool
				local lvl = getToolWeaponLevel(tool) or fallbackLevel
				applyAppearanceToTool(tool, lvl)
			end
		end
	end

	-- 首先尝试给 Backpack 里的 Tool 应用外观，这样玩家打开背包时就能看到正确的武器外观了
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		applyInContainer(backpack)
	end

	local character = player.Character
	if character then
		applyInContainer(character)
	end
end

function WeaponAppearanceService.ApplyForPlayerTools(player: Player)
	tryApplyForPlayerTools(player)
end

function WeaponAppearanceService.Init()
	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			-- 等 StarterPack 下发 Tool
			task.delay(0.25, function()
				tryApplyForPlayerTools(player)
			end)
		end)

		-- 武器升级后刷新外观
		player:GetAttributeChangedSignal("WeaponLevel"):Connect(function()
			tryApplyForPlayerTools(player)
		end)
		player:GetAttributeChangedSignal("EquippedWeaponLevel"):Connect(function()
			tryApplyForPlayerTools(player)
		end)

		-- 初次进来补一次
		task.delay(0.25, function()
			tryApplyForPlayerTools(player)
		end)
	end

	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		hookPlayer(p)
	end
end

return WeaponAppearanceService
