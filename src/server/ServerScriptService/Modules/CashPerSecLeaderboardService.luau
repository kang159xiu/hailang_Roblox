--!strict
-- ServerScriptService.Modules.CashPerSecLeaderboardService
-- 当前服务器实时 Cash/s 排行榜：
-- Cash/s = 玩家已放置怪物 GoldPerSec 总和 * 玩家重生金币倍率。

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local PlacementService = require(script.Parent:WaitForChild("PlacementService"))
local Util = require(script.Parent:WaitForChild("Util"))

local CashPerSecLeaderboardService = {}

local REFRESH_SECONDS = 2
local MAX_ROWS = 50
local TEMPLATE_NAME = "EntryTemplate"
local ROW_ATTRIBUTE = "CashPerSecLeaderboardRow"

local started = false
local warnedMissingBoard = false
local warnedMissingTemplate = false

type LeaderboardRow = {
	Player: Player,
	CashPerSec: number,
}

local function formatCashPerSec(value: number): string
	return Util.FormatMoney(math.max(0, math.floor(value)))
end

local function getBoardList(): GuiObject?
	local regionFolder = Workspace:FindFirstChild("区域")
	local displayFolder = regionFolder and regionFolder:FindFirstChild("排行榜显示")
	local boardPart = displayFolder and displayFolder:FindFirstChild("排行part")
	local surfaceGui = boardPart and boardPart:FindFirstChild("SurfaceGui")
	local list = surfaceGui and surfaceGui:FindFirstChild("List")

	if list and list:IsA("GuiObject") then
		return list :: GuiObject
	end

	if not warnedMissingBoard then
		warn("[CashPerSecLeaderboard] 找不到排行榜 List：Workspace.区域.排行榜显示.排行part.SurfaceGui.List")
		warnedMissingBoard = true
	end
	return nil
end

local function getCashPerSec(player: Player): number
	local baseIncome = PlacementService.GetPlayerBaseGoldPerSec(player)
	local multiplier = PlayerData.GetRebirthMultiplier(player)
	if type(multiplier) ~= "number" then
		multiplier = 1
	end
	return math.max(0, math.floor(baseIncome * math.max(1, multiplier)))
end

local function syncPlayer(player: Player): number
	local value = getCashPerSec(player)
	PlayerData.SetCashPerSec(player, value)
	return value
end

local function setAvatar(rowGui: Instance, player: Player)
	local avatar = rowGui:FindFirstChild("Avatar", true)
	if avatar and avatar:IsA("ImageLabel") then
		local ok, thumb = pcall(function()
			return Players:GetUserThumbnailAsync(player.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and type(thumb) == "string" then
			(avatar :: ImageLabel).Image = thumb
		end
	end
end

local function setRowText(rowGui: Instance, rank: number, player: Player, cashPerSec: number)
	local displayName = if player.DisplayName ~= "" then player.DisplayName else player.Name

	local nameLabel = rowGui:FindFirstChild("NameLabel", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		(nameLabel :: TextLabel).Text = string.format("#%d  %s", rank, displayName)
	end

	local valueLabel = rowGui:FindFirstChild("ValueLabel", true)
	if valueLabel and valueLabel:IsA("TextLabel") then
		(valueLabel :: TextLabel).Text = string.format("%s/s", formatCashPerSec(cashPerSec))
	end
end

local function clearOldRows(list: GuiObject)
	for _, child in ipairs(list:GetChildren()) do
		if child:GetAttribute(ROW_ATTRIBUTE) == true then
			child:Destroy()
		end
	end
end

local function render()
	local list = getBoardList()
	if not list then
		return
	end

	local template = list:FindFirstChild(TEMPLATE_NAME)
	if not (template and template:IsA("GuiObject")) then
		if not warnedMissingTemplate then
			warn("[CashPerSecLeaderboard] 找不到行模板 EntryTemplate")
			warnedMissingTemplate = true
		end
		return
	end

	(template :: GuiObject).Visible = false
	clearOldRows(list)

	local rows: {LeaderboardRow} = {}
	for _, player in ipairs(Players:GetPlayers()) do
		local value = syncPlayer(player)
		table.insert(rows, {
			Player = player,
			CashPerSec = value,
		})
	end

	table.sort(rows, function(a: LeaderboardRow, b: LeaderboardRow): boolean
		if a.CashPerSec == b.CashPerSec then
			return a.Player.UserId < b.Player.UserId
		end
		return a.CashPerSec > b.CashPerSec
	end)

	for rank, row in ipairs(rows) do
		if rank > MAX_ROWS then
			break
		end

		local clone = (template :: GuiObject):Clone()
		clone.Name = string.format("Entry_%02d_%d", rank, row.Player.UserId)
		clone:SetAttribute(ROW_ATTRIBUTE, true)
		clone.Visible = true
		clone.LayoutOrder = rank
		clone.Parent = list

		setAvatar(clone, row.Player)
		setRowText(clone, rank, row.Player, row.CashPerSec)
	end
end

function CashPerSecLeaderboardService.Init()
	if started then
		return
	end
	started = true

	Players.PlayerAdded:Connect(function(player)
		task.defer(syncPlayer, player)
	end)

	Players.PlayerRemoving:Connect(function(_player)
		task.defer(render)
	end)

	task.spawn(function()
		while true do
			render()
			task.wait(REFRESH_SECONDS)
		end
	end)
end

return CashPerSecLeaderboardService