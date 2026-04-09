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

local function getWeaponName(level: number): string
	local t = (Config :: any).WEAPON_NAME_BY_LEVEL
	if type(t) == "table" then
		local v = t[level]
		if type(v) == "string" and v ~= "" then
			return v
		end
	end
	return string.format("武器%d", level)
end

local function getWeaponImageId(level: number): string?
	local t = (Config :: any).WEAPON_IMAGE_ID_BY_LEVEL
	if type(t) == "table" then
		local v = t[level]
		if type(v) == "string" and v ~= "" then
			return v
		end
	end
	return nil
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

local function syncToolGripFromTemplate(tool: Tool, template: Tool)
	-- 核心逻辑：直接复制模板 Tool 的 Grip 四元组。
	-- Roblox 的手持朝向/位置，本质上由以下属性共同决定：
	-- - GripForward
	-- - GripRight
	-- - GripUp
	-- - GripPos
	--
	-- 这样做的目的，是让“玩家手上的武器位置”完全以模板为准。
	-- 以后你只需要在 Studio 中调整 Workspace.weaponModle 的握持效果，
	-- 玩家最终拿到的 Tool 就会在下次 Sync 时自动套用同样的参数。
	tool.GripForward = template.GripForward
	tool.GripRight = template.GripRight
	tool.GripUp = template.GripUp
	tool.GripPos = template.GripPos

	-- RequiresHandle 也同步，确保 Tool 的持握规则和模板一致。
	tool.RequiresHandle = template.RequiresHandle
end

local function syncToolHandleFromTemplate(tool: Tool, template: Tool)
	-- 核心逻辑：不再假设 Handle 是固定的 1x1x1 默认 Part，
	-- 而是直接克隆模板里的 Handle。
	--
	-- 这样可以保留你模板中 Handle 的：
	-- 1) 尺寸
	-- 2) CFrame / 朝向基准
	-- 3) 子物件结构（例如 TouchInterest、rootpart）
	--
	-- 这正是“以后改模板，玩家手持位置也会跟着改”的关键。
	local templateHandle = template:FindFirstChild("Handle")
	if not templateHandle or not templateHandle:IsA("BasePart") then
		return
	end

	local currentHandle = tool:FindFirstChild("Handle")
	if currentHandle then
		-- 先删除旧 Handle，避免旧结构残留。
		-- 否则可能会出现：
		-- - 老的 rootpart 还在
		-- - 尺寸/位置没有更新
		-- - 模板改过后玩家 Tool 仍沿用旧 Handle
		currentHandle:Destroy()
	end

	local clonedHandle = templateHandle:Clone()
	clonedHandle.Name = "Handle"
	clonedHandle.Parent = tool
end

local function syncToolFromTemplate(tool: Tool, template: Tool?)
	-- 统一同步入口：
	-- 让玩家 Tool 的“握持参数 + Handle 结构”都跟模板保持一致。
	--
	-- 注意：这里不会复制整把模板 Tool 的所有内容，
	-- 而是只同步“影响手持位置的关键部分”，避免把不必要的脚本/状态一并带过去。
	if not template then
		return
	end

	syncToolGripFromTemplate(tool, template)
	syncToolHandleFromTemplate(tool, template)
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

function WeaponToolService.Sync(player: Player, forceEquip: boolean?)
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
			WeaponToolService.Sync(player, forceEquip)
		end)
		return
	end

	if forceEquip == true then
		humanoid:UnequipTools()
	else
		-- If player already holds a weapon tool, don't forcibly swap it.
		for _, ch in ipairs(character:GetChildren()) do
			if isWeaponTool(ch) then
				return
			end
		end
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

return WeaponToolService
