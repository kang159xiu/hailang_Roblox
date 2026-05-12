--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local HomeService = require(script.Parent:WaitForChild("HomeService"))
local MonsterService = require(script.Parent:WaitForChild("MonsterService"))
local ZoneService = require(script.Parent:WaitForChild("ZoneService"))
local DataDirtyService = require(script.Parent:WaitForChild("DataDirtyService"))

local TutorialService = {}

type Stage = "FindMonster" | "GoPlace" | "CollectGold" | "GoMerchant" | "Completed"

type TutorialState = {
	Stage: Stage,
	Target: Instance?,
	LastRetargetAt: number,
}

local statesByUserId: {[number]: TutorialState} = {}
local tutorialUpdateRemote: RemoteEvent
local tutorialRequestRetargetRemote: RemoteEvent
local tutorialClientReachedTargetRemote: RemoteEvent

local function getRootPart(player: Player): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function isMonsterTargetValid(target: Instance?): boolean
	return target ~= nil
		and target.Parent ~= nil
		and target:IsA("BasePart")
		and target:GetAttribute("IsMonster") == true
		and target:GetAttribute("Dead") ~= true
		and target:GetAttribute("Collected") ~= true
end

local function fireUpdate(player: Player, stage: Stage, target: Instance?, text: string, nearText: string?)
	tutorialUpdateRemote:FireClient(player, {
		Active = stage ~= "Completed",
		Stage = stage,
		Target = target,
		Text = text,
		NearText = nearText,
	})
end

local function sendCurrent(player: Player)
	local state = statesByUserId[player.UserId]
	if not state then
		return
	end

	if state.Stage == "FindMonster" then
		fireUpdate(player, state.Stage, state.Target, "Get the first monster: Defeat a monster to obtain it.")--获取第一个怪物： 击败怪物可获得怪物“
	elseif state.Stage == "GoPlace" then
		fireUpdate(player, state.Stage, state.Target, "After obtaining a monster, place it in your base/home.", nil)--获得怪物后放置到家园
	elseif state.Stage == "CollectGold" then
		fireUpdate(player, state.Stage, state.Target, "Earn your first coins.", nil) --获取你的第一笔钱币
	elseif state.Stage == "GoMerchant" then
		fireUpdate(player, state.Stage, state.Target, "Upgrade your stats at the upgrade shop.", nil) --升级商店升级属性
	else
		fireUpdate(player, "Completed", nil, "", nil)
	end
end

local function setStage(player: Player, stage: Stage, target: Instance?)
	statesByUserId[player.UserId] = {
		Stage = stage,
		Target = target,
		LastRetargetAt = 0,
	}
	sendCurrent(player)
end

local function chooseMonsterTarget(player: Player)
	local monster = MonsterService.GetRandomAliveMonsterInZoneLevel(1)
	setStage(player, "FindMonster", monster)
end

local function getFirstSlotTarget(player: Player): BasePart?
	local slot = HomeService.GetSlot(player, 1)
	return slot and slot.Part or HomeService.GetSlotPart(player, 1)
end

local function getFirstCollectorTarget(player: Player): BasePart?
	local slot = HomeService.GetSlot(player, 1)
	if slot and slot.Collector then
		return slot.Collector
	end
	return getFirstSlotTarget(player)
end

function TutorialService.Complete(player: Player)
	if player:GetAttribute("TutorialCompleted") == true then
		statesByUserId[player.UserId] = nil
		return
	end

	player:SetAttribute("TutorialCompleted", true)
	statesByUserId[player.UserId] = nil
	DataDirtyService.MarkDirty(player, 5)
	fireUpdate(player, "Completed", nil, "", nil)
end

function TutorialService.OnMonsterAcquired(player: Player)
	local state = statesByUserId[player.UserId]
	if not state or state.Stage ~= "FindMonster" then
		return
	end

	setStage(player, "GoPlace", getFirstSlotTarget(player))
end

function TutorialService.OnMonsterPlaced(player: Player, slotIndex: number)
	local state = statesByUserId[player.UserId]
	if not state or state.Stage ~= "GoPlace" or slotIndex ~= 1 then
		return
	end

	setStage(player, "CollectGold", getFirstCollectorTarget(player))
end

function TutorialService.OnGoldCollected(player: Player, slotIndex: number)
	local state = statesByUserId[player.UserId]
	if not state or state.Stage ~= "CollectGold" or slotIndex ~= 1 then
		return
	end

	setStage(player, "GoMerchant", ZoneService.GetMerchantPart())
end

local function waitForStartupPrerequisites(player: Player): boolean
	local deadline = os.clock() + 30
	while player.Parent and os.clock() < deadline do
		if player:GetAttribute("__DataLoaded") == true and HomeService.GetHome(player) ~= nil then
			return true
		end
		task.wait(0.25)
	end
	return false
end

local function startForPlayer(player: Player)
	if not waitForStartupPrerequisites(player) then
		return
	end
	if player:GetAttribute("TutorialCompleted") == true then
		fireUpdate(player, "Completed", nil, "", nil)
		return
	end

	chooseMonsterTarget(player)
end

local function retargetIfNeeded(player: Player)
	local state = statesByUserId[player.UserId]
	if not state or state.Stage ~= "FindMonster" then
		return
	end

	local now = os.clock()
	if now - state.LastRetargetAt < 1 then
		return
	end
	state.LastRetargetAt = now

	if not isMonsterTargetValid(state.Target) then
		chooseMonsterTarget(player)
	else
		sendCurrent(player)
	end
end

function TutorialService.Init()
	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	tutorialUpdateRemote = remotes:WaitForChild("TutorialUpdate") :: RemoteEvent
	tutorialRequestRetargetRemote = remotes:WaitForChild("TutorialRequestRetarget") :: RemoteEvent
	tutorialClientReachedTargetRemote = remotes:WaitForChild("TutorialClientReachedTarget") :: RemoteEvent

	tutorialRequestRetargetRemote.OnServerEvent:Connect(function(player: Player)
		retargetIfNeeded(player)
	end)

	tutorialClientReachedTargetRemote.OnServerEvent:Connect(function(player: Player, stage: any)
		local state = statesByUserId[player.UserId]
		if state and state.Stage == "GoMerchant" and stage == "GoMerchant" then
			local target = state.Target
			local hrp = getRootPart(player)
			if target and target:IsA("BasePart") and hrp and (hrp.Position - target.Position).Magnitude <= 14 then
				TutorialService.Complete(player)
			end
		end
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		task.spawn(startForPlayer, player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		statesByUserId[player.UserId] = nil
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(startForPlayer, player)
	end

	local lastCheck = 0
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		if now - lastCheck < 0.5 then
			return
		end
		lastCheck = now

		for userId, state in pairs(statesByUserId) do
			local player = Players:GetPlayerByUserId(userId)
			if not player then
				statesByUserId[userId] = nil
			elseif state.Stage == "FindMonster" then
				if not isMonsterTargetValid(state.Target) then
					chooseMonsterTarget(player)
				end
			elseif state.Stage == "GoPlace" then
				if not (state.Target and state.Target.Parent) then
					setStage(player, "GoPlace", getFirstSlotTarget(player))
				end
			elseif state.Stage == "CollectGold" then
				if not (state.Target and state.Target.Parent) then
					setStage(player, "CollectGold", getFirstCollectorTarget(player))
				end
			elseif state.Stage == "GoMerchant" then
				local target = state.Target
				if not (target and target.Parent and target:IsA("BasePart")) then
					setStage(player, "GoMerchant", ZoneService.GetMerchantPart())
				else
					local hrp = getRootPart(player)
					if hrp and (hrp.Position - (target :: BasePart).Position).Magnitude <= 12 then
						TutorialService.Complete(player)
					end
				end
			end
		end
	end)
end

return TutorialService