--!strict
-- ServerScriptService.Modules.WeaponToolService
--
-- 目的：用官方默认背包/热键栏展示“多把武器”Tool 图标。
-- 设计：
-- 1) 每个武器等级对应一把 Tool（都放在玩家 Backpack）。
-- 2) 玩家切换装备哪把 Tool，就同步 PlayerData.EquippedWeaponLevel。
-- 3) 购买新武器时给一把新 Tool，并可立即装备。
--
-- 注意：不要依赖 StarterGear，否则会和 StarterPack 的发放机制产生重复 Tool。

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPack = game:GetService("StarterPack")

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local WeaponAppearanceService = require(script.Parent:WaitForChild("WeaponAppearanceService"))

local WeaponToolService = {}

-- [修改内容] 移除对静态 Config 表的多余 type() 类型校验，改为利用短路求值实现极简获取
local function getWeaponName(level: number): string
	local name = Config.WEAPON_NAME_BY_LEVEL and Config.WEAPON_NAME_BY_LEVEL[level]
	return (name ~= nil and name ~= "") and name or string.format("武器%d", level)
end

local function getWeaponImageId(level: number): string?
	local img = Config.WEAPON_IMAGE_ID_BY_LEVEL and Config.WEAPON_IMAGE_ID_BY_LEVEL[level]
	return (img ~= nil and img ~= "") and img or nil
end

local function getTemplateTool(): Tool?
	-- 统一从模板 Tool 读取“武器握持基准”。
	-- 优先使用 Workspace.weaponModle：
	-- 1) 这是你在 Studio 里手动调试握持位置最方便的地方；
	-- 2) 你改它的 Grip / Handle / rootpart 结构后，玩家实际拿到的 Tool 也会跟着同步。
	-- 如果 Workspace 里没有，则退回 StarterPack.Weapon 作为兜底模板。
	local workspaceTemplate = workspace:FindFirstChild("weaponModle")
	if workspaceTemplate and workspaceTemplate:IsA("Tool") then
		return workspaceTemplate
	end

	local t = StarterPack:FindFirstChild("Weapon")
	if t and t:IsA("Tool") then
		return t
	end
	warn("[WeaponToolService] Tool template missing: 期望 Workspace.weaponModle 或 StarterPack.Weapon")
	return nil
end

-- [修改内容] 移除过度封装的子函数。Roblox 的 Tool.Grip 是 CFrame，可直接赋值，无需拆开四元组。
local function syncToolFromTemplate(tool: Tool, template: Tool?)
	if not template then return end

	-- 1. 同步持握基准
	tool.Grip = template.Grip
	tool.RequiresHandle = template.RequiresHandle

	-- 2. 同步 Handle 实体
	local templateHandle = template:FindFirstChild("Handle")
	if templateHandle and templateHandle:IsA("BasePart") then
		local currentHandle = tool:FindFirstChild("Handle")
		if currentHandle then
			currentHandle:Destroy()
		end
		local clonedHandle = templateHandle:Clone()
		clonedHandle.Name = "Handle"
		clonedHandle.Parent = tool
	end
end

local function isWeaponTool(inst: Instance): boolean
	return inst:IsA("Tool") and inst:GetAttribute("IsWeaponTool") == true
end

local function getWeaponLevelFromTool(tool: Tool): number?
	local v = tool:GetAttribute("WeaponLevel")
	if type(v) == "number" then
		return v
	end
	return nil
end

local function ensureToolMeta(tool: Tool, weaponLevel: number)
	tool:SetAttribute("IsWeaponTool", true)
	tool:SetAttribute("WeaponLevel", weaponLevel)
	tool.CanBeDropped = false

	local img = getWeaponImageId(weaponLevel)
	if img then
		tool.TextureId = img
	end
end


local function connectEquipSync(player: Player, tool: Tool)
	-- 避免重复连接
	if tool:GetAttribute("__WeaponEquipSyncBound") == true then
		return
	end
	tool:SetAttribute("__WeaponEquipSyncBound", true)

	tool.Equipped:Connect(function()
		local lvl = getWeaponLevelFromTool(tool)
		if not lvl then
			return
		end
		PlayerData.SetEquippedWeaponLevel(player, lvl)
	end)
end

local function ensureSingleWeaponTool(player: Player, desiredWeaponLevel: number): Tool?
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		return nil
	end

	local template = getTemplateTool()

	-- Collect candidates from Backpack + Character (equipped)
	local candidates: {Tool} = {}

	local function collect(container: Instance?)
		if not container then
			return
		end
		for _, ch in ipairs(container:GetChildren()) do
			if ch:IsA("Tool") then
				local t = ch :: Tool
				if t.Name == "Weapon" or isWeaponTool(t) or getWeaponLevelFromTool(t) ~= nil then
					table.insert(candidates, t)
				end
			end
		end
	end

	collect(backpack)
	collect(player.Character)

	-- Prefer keeping the original StarterPack tool named "Weapon"
	local keep: Tool? = nil
	for _, t in ipairs(candidates) do
		if t.Name == "Weapon" then
			keep = t
			break
		end
	end
	if not keep then
		keep = candidates[1]
	end

	-- Destroy duplicates
	for _, t in ipairs(candidates) do
		if keep and t ~= keep then
			t:Destroy()
		end
	end

	-- If nothing exists yet (rare timing), create one as a fallback.
	-- Next Sync() will still de-dup if StarterPack later delivers another.
	if not keep then
		if not template then
			return nil
		end
		local newTool = template:Clone()
		newTool.Name = getWeaponName(desiredWeaponLevel)
		-- 新建玩家武器时，立刻再做一次显式同步。
		-- 这么写的原因是：
		-- 1) 即便模板之后调整过，我们也明确以模板当前状态为准；
		-- 2) 让“创建新 Tool”和“复用旧 Tool”走同一套同步逻辑，便于后续维护。
		syncToolFromTemplate(newTool, template)
		ensureToolMeta(newTool, desiredWeaponLevel)
		connectEquipSync(player, newTool)
		newTool.Parent = backpack
		WeaponAppearanceService.ApplyToTool(newTool, desiredWeaponLevel)
		return newTool
	end

	-- 复用已有 Tool 时，同样强制按模板刷新一次。
	-- 这意味着：
	-- - 玩家重生后
	-- - 武器切换/同步时
	-- - 后端再次调用 Sync 时
	-- 都会把当前玩家武器重新校正到模板定义的手持基准上。
	syncToolFromTemplate(keep, template)

	-- Normalize meta to desired level (so appearance/skills follow EquippedWeaponLevel)
	ensureToolMeta(keep, desiredWeaponLevel)
	connectEquipSync(player, keep)
	WeaponAppearanceService.ApplyToTool(keep, desiredWeaponLevel)

	-- UI: only show one hotbar slot, and keep the name stable
	keep.Name = getWeaponName(desiredWeaponLevel)
	return keep
end

function WeaponToolService.GrantWeapon(player: Player, weaponLevel: number, equipNow: boolean?)
	PlayerData.AddOwnedWeaponLevel(player, weaponLevel)
	if equipNow then
		PlayerData.SetEquippedWeaponLevel(player, weaponLevel)
	end

	-- Always keep only ONE weapon button/tool.
	-- Upgrades/purchases only change EquippedWeaponLevel and appearance/damage.
	WeaponToolService.Sync(player, equipNow == true)
end


function WeaponToolService.Sync(player: Player, forceEquip: boolean?, dontEquip: boolean?)
	-- [修改内容] 增加 dontEquip 参数，用于控制同步时是否保持收起状态
	local stats = PlayerData.Get(player)
	local desiredLevel = stats.EquippedWeaponLevel or stats.WeaponLevel

	-- Ensure the single weapon tool exists and has correct level meta
	local weaponTool = ensureSingleWeaponTool(player, desiredLevel)
	if weaponTool then
		WeaponAppearanceService.ApplyToTool(weaponTool, desiredLevel)
	else
		WeaponAppearanceService.ApplyForPlayerTools(player)
	end

	local backpack = player:FindFirstChildOfClass("Backpack")
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not backpack or not humanoid then
		-- Backpack/character may not be ready yet - retry shortly
		task.delay(0.25, function()
			WeaponToolService.Sync(player, forceEquip, dontEquip)
		end)
		return
	end

	if forceEquip == true then
		humanoid:UnequipTools()
	else
		-- If player already holds a weapon tool, don't forcibly swap it.
		for _, ch in ipairs(character:GetChildren()) do
			if isWeaponTool(ch) then
				-- [修改内容] 如果明确要求不装备且玩家正拿着武器，则强制收起
				if dontEquip then
					humanoid:UnequipTools()
				end
				return
			end
		end
	end

	-- [修改内容] 如果要求不装备（例如开局），则直接返回，不再执行后续的 EquipTool
	if dontEquip then
		return
	end

	for _, ch in ipairs(backpack:GetChildren()) do
		if isWeaponTool(ch) then
			local tool = ch :: Tool
			if getWeaponLevelFromTool(tool) == desiredLevel then
				humanoid:EquipTool(tool)
				break
			end
		end
	end
end

function WeaponToolService.Init()
	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			-- 等 Backpack 和 StarterPack Tool 下发完成
			task.delay(0.25, function()
				ensureSingleWeaponTool(player, PlayerData.Get(player).EquippedWeaponLevel or 1)
				WeaponToolService.Sync(player)
			end)
		end)

		-- 初次进来补一次（有时 CharacterAdded 前 Backpack 已存在）
		task.delay(0.1, function()
			ensureSingleWeaponTool(player, PlayerData.Get(player).EquippedWeaponLevel or 1)
			WeaponToolService.Sync(player)
		end)

		-- 不监听 Backpack.ChildAdded：避免因排序/重入导致报错
	end

	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		hookPlayer(p)
	end
end



-- [修改内容] 引入 CollectionService 用于监听场景中的标签 Part
local CollectionService = game:GetService("CollectionService")

-- [修改内容] 新增方法：主动装备背包中的武器（用于离开 home/碰触 di_mian 时）
function WeaponToolService.EquipWeapon(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not humanoid or not backpack then return end

	-- 检查是否已经拿在手上，避免重复触发影响性能或打断动画
	for _, ch in ipairs(character:GetChildren()) do
		if isWeaponTool(ch) then
			return
		end
	end

	local stats = PlayerData.Get(player)
	local desiredLevel = stats.EquippedWeaponLevel or stats.WeaponLevel

	for _, ch in ipairs(backpack:GetChildren()) do
		if isWeaponTool(ch) then
			local tool = ch :: Tool
			if getWeaponLevelFromTool(tool) == desiredLevel then
				humanoid:EquipTool(tool)
				break
			end
		end
	end
end

-- [修改内容] 新增方法：主动收起手上的武器（用于进入 home 时）
function WeaponToolService.UnequipWeapon(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid then return end

	local isHolding = false
	for _, ch in ipairs(character:GetChildren()) do
		if isWeaponTool(ch) then
			isHolding = true
			break
		end
	end

	if isHolding then
		humanoid:UnequipTools()
	end
end

function WeaponToolService.Init()
	local function hookPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			-- 等 Backpack 和 StarterPack Tool 下发完成
			task.delay(0.25, function()
				ensureSingleWeaponTool(player, PlayerData.Get(player).EquippedWeaponLevel or 1)
				-- [修改内容] 传入 dontEquip = true，开局工具栏有武器但不自动拿到手上
				WeaponToolService.Sync(player, false, true)
			end)
		end)

		-- 初次进来补一次（有时 CharacterAdded 前 Backpack 已存在）
		task.delay(0.1, function()
			ensureSingleWeaponTool(player, PlayerData.Get(player).EquippedWeaponLevel or 1)
			-- [修改内容] 同上，传入 dontEquip = true
			WeaponToolService.Sync(player, false, true)
		end)

		-- 不监听 Backpack.ChildAdded：避免因排序/重入导致报错
	end

	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		hookPlayer(p)
	end

	-- [修改内容] 监听玩家碰触 "home" 标签的 Part -> 收起武器
	local function onHomePartAdded(part)
		part.Touched:Connect(function(hit)
			local player = Players:GetPlayerFromCharacter(hit.Parent)
			if player then
				WeaponToolService.UnequipWeapon(player)
			end
		end)
	end

	for _, part in ipairs(CollectionService:GetTagged("home")) do
		onHomePartAdded(part)
	end
	CollectionService:GetInstanceAddedSignal("home"):Connect(onHomePartAdded)

	-- 监听玩家碰触 "na_qu_area" 标签的 Part -> 拿起武器
	local function onDimianPartAdded(part)
		part.Touched:Connect(function(hit)
			local player = Players:GetPlayerFromCharacter(hit.Parent)
			if player then
				WeaponToolService.EquipWeapon(player)
			end
		end)
	end

	for _, part in ipairs(CollectionService:GetTagged("na_qu_area")) do
		onDimianPartAdded(part)
	end
	CollectionService:GetInstanceAddedSignal("na_qu_area"):Connect(onDimianPartAdded)
end

return WeaponToolService
