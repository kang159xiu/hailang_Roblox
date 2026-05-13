--!strict
-- 客户端本地播放“收钱时放置怪物向上跳一下”的表现动画。
-- 金币结算仍在服务端 PlacementService 中完成；这里不处理任何经济数据。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local playPlacedMonsterJumpRemote = remotes:WaitForChild("PlayPlacedMonsterJump") :: RemoteEvent

local jumping: {[BasePart]: boolean} = {}

local function getPlacedMonsterContainer(rootPart: BasePart): Instance
	local current: Instance? = rootPart
	while current do
		if current ~= rootPart and current:GetAttribute("IsPlacedMonsterContainer") == true then
			return current
		end
		current = current.Parent
	end
	return rootPart
end

local function getPivot(rootPart: BasePart): CFrame
	local container = getPlacedMonsterContainer(rootPart)
	if container:IsA("Model") then
		return (container :: Model):GetPivot()
	elseif container:IsA("BasePart") then
		return (container :: BasePart).CFrame
	end
	return rootPart.CFrame
end

local function pivot(rootPart: BasePart, targetCFrame: CFrame)
	local container = getPlacedMonsterContainer(rootPart)
	if container:IsA("Model") then
		(container :: Model):PivotTo(targetCFrame)
	elseif container:IsA("BasePart") then
		(container :: BasePart).CFrame = targetCFrame
	elseif rootPart.Parent ~= nil then
		rootPart.CFrame = targetCFrame
	end
end

local function playLocalJump(rootPart: BasePart)
	if jumping[rootPart] then
		return
	end
	if rootPart.Parent == nil then
		return
	end

	jumping[rootPart] = true

	local originalCFrame = getPivot(rootPart)
	local peakCFrame = originalCFrame * CFrame.new(0, 2, 0)
	local cframeValue = Instance.new("CFrameValue")
	cframeValue.Value = originalCFrame

	local conn = cframeValue:GetPropertyChangedSignal("Value"):Connect(function()
		if rootPart.Parent ~= nil then
			pivot(rootPart, cframeValue.Value)
		end
	end)

	local tween = TweenService:Create(
		cframeValue,
		TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true),
		{ Value = peakCFrame }
	)

	tween:Play()
	tween.Completed:Wait()
	conn:Disconnect()
	cframeValue:Destroy()

	if rootPart.Parent ~= nil then
		pivot(rootPart, originalCFrame)
	end
	jumping[rootPart] = nil
end

playPlacedMonsterJumpRemote.OnClientEvent:Connect(function(rootPart: Instance)
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	if rootPart:GetAttribute("IsPlacedMonster") ~= true then
		return
	end

	task.spawn(playLocalJump, rootPart :: BasePart)
end)