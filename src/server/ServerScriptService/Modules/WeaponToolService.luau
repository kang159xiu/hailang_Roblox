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
	local t = StarterPack:FindFirstChild("Weapon")
	if t and t:IsA("Tool") then
		return t
	end
	warn("[WeaponToolService] StarterPack.Weapon template missing")
	return nil
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
		ensureToolMeta(newTool, desiredWeaponLevel)
		connectEquipSync(player, newTool)
		newTool.Parent = backpack
		return newTool
	end

	-- Normalize meta to desired level (so appearance/skills follow EquippedWeaponLevel)
	ensureToolMeta(keep, desiredWeaponLevel)
	connectEquipSync(player, keep)

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
	ensureSingleWeaponTool(player, desiredLevel)

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
