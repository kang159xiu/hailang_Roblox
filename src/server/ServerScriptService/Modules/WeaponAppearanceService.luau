--!strict
-- ServerScriptService.Modules.WeaponAppearanceService
-- 根据玩家 WeaponLevel，把对应“武器外观”焊到 Tool.Handle 上，让玩家真正手持武器。
-- 外观来源：ReplicatedStorage.WeaponAppearances（由 AppearanceBootstrapService 从 Workspace.武器1 复制生成）

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
	return inst:IsA("Tool") and inst:GetAttribute("IsWeaponTool") == true
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

	return folder:FindFirstChild(string.format("武器 %d", level))
		or folder:FindFirstChild(string.format("武器%d", level))
end

local function ensureHandle(tool: Tool): BasePart
	local h = tool:FindFirstChild("Handle")
	if h and h:IsA("BasePart") then
		return h
	end

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 1, 1)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool
	tool.RequiresHandle = true
	return handle
end

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

	-- 让外观对齐到 Handle 的位置
	if model then
		local anyPart = model:FindFirstChildWhichIsA("BasePart", true)
		if anyPart then
			model:PivotTo(handle.CFrame)
			weldAllToHandle(handle, model)
			applied = true
		end
	elseif part then
		-- 如果模板根是 Part 且带子元件：先把整棵层级整体移动到 Handle 位置
		local delta = handle.CFrame * part.CFrame:Inverse()
		for _, d in ipairs(part:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CFrame = delta * d.CFrame
			end
		end

		part.CFrame = handle.CFrame
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

local function tryApplyForPlayerTools(player: Player)
	local fallbackLevel = getEquippedWeaponLevel(player)

	local function applyInContainer(container: Instance)
		for _, ch in ipairs(container:GetChildren()) do
			if isWeaponTool(ch) then
				local tool = ch :: Tool
				local lvl = getToolWeaponLevel(tool) or fallbackLevel
				applyAppearanceToTool(tool, lvl)
			end
		end
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		applyInContainer(backpack)
	end

	local character = player.Character
	if character then
		applyInContainer(character)
	end
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
