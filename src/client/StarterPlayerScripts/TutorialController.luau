--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local TutorialController = {}

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("Remotes")
local tutorialUpdateRemote = remotes:WaitForChild("TutorialUpdate") :: RemoteEvent
local tutorialRequestRetargetRemote = remotes:WaitForChild("TutorialRequestRetarget") :: RemoteEvent
local tutorialClientReachedTargetRemote = remotes:WaitForChild("TutorialClientReachedTarget") :: RemoteEvent

local screenGui: ScreenGui? = nil
local mainLabel: TextLabel? = nil
local nearLabel: TextLabel? = nil
local beam: Beam? = nil
local playerAttachment: Attachment? = nil
local targetAttachment: Attachment? = nil
local targetBillboard: BillboardGui? = nil

local active = false
local currentStage = ""
local currentTarget: Instance? = nil
local currentText = ""
local currentNearText: string? = nil
local lastRetargetRequestAt = 0
local reachedMerchantSent = false

local function getHrp(): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function ensureGui()
	if screenGui and screenGui.Parent then
		return
	end

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "TutorialGuideGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = player:WaitForChild("PlayerGui")

	mainLabel = Instance.new("TextLabel")
	mainLabel.Name = "MainTip"
	mainLabel.AnchorPoint = Vector2.new(0.5, 0)
	mainLabel.Position = UDim2.fromScale(0.5, 0.08)
	mainLabel.Size = UDim2.fromOffset(560, 54)
	mainLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	mainLabel.BackgroundTransparency = 0.28
	mainLabel.BorderSizePixel = 0
	mainLabel.Font = Enum.Font.GothamBold
	mainLabel.TextColor3 = Color3.fromRGB(255, 235, 120)
	mainLabel.TextScaled = true
	mainLabel.TextWrapped = true
	mainLabel.Parent = screenGui

	nearLabel = Instance.new("TextLabel")
	nearLabel.Name = "NearTip"
	nearLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	nearLabel.Position = UDim2.fromScale(0.5, 0.72)
	nearLabel.Size = UDim2.fromOffset(420, 48)
	nearLabel.BackgroundColor3 = Color3.fromRGB(30, 20, 0)
	nearLabel.BackgroundTransparency = 0.18
	nearLabel.BorderSizePixel = 0
	nearLabel.Font = Enum.Font.GothamBold
	nearLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nearLabel.TextScaled = true
	nearLabel.TextWrapped = true
	nearLabel.Visible = false
	nearLabel.Parent = screenGui
end

local function destroyBeamAndArrow()
	if beam then
		beam:Destroy()
		beam = nil
	end
	if playerAttachment then
		playerAttachment:Destroy()
		playerAttachment = nil
	end
	if targetAttachment then
		targetAttachment:Destroy()
		targetAttachment = nil
	end
	if targetBillboard then
		targetBillboard:Destroy()
		targetBillboard = nil
	end
end

local function cleanup()
	active = false
	currentStage = ""
	currentTarget = nil
	currentText = ""
	currentNearText = nil
	reachedMerchantSent = false
	destroyBeamAndArrow()
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	mainLabel = nil
	nearLabel = nil
end

local function createTargetBillboard(target: BasePart)
	local bb = Instance.new("BillboardGui")
	bb.Name = "TutorialArrowBillboard"
	bb.AlwaysOnTop = true
	bb.Size = UDim2.fromOffset(110, 110)
	bb.StudsOffset = Vector3.new(0, math.max(4, target.Size.Y * 0.5 + 3), 0)
	bb.Parent = target

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBlack
	label.Text = "▼"
	label.TextColor3 = Color3.fromRGB(255, 230, 70)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Parent = bb

	targetBillboard = bb
end

local function rebuildGuideVisual()
	destroyBeamAndArrow()
	if not active then
		return
	end

	local hrp = getHrp()
	local target = currentTarget
	if not hrp or not (target and target:IsA("BasePart") and target.Parent) then
		return
	end

	playerAttachment = Instance.new("Attachment")
	playerAttachment.Name = "TutorialPlayerAttachment"
	playerAttachment.Parent = hrp

	targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "TutorialTargetAttachment"
	targetAttachment.Parent = target

	beam = Instance.new("Beam")
	beam.Name = "TutorialGuideBeam"
	beam.Attachment0 = playerAttachment
	beam.Attachment1 = targetAttachment
	beam.FaceCamera = true
	beam.Width0 = 0.35
	beam.Width1 = 0.75
	beam.LightEmission = 1
	beam.Color = ColorSequence.new(Color3.fromRGB(255, 220, 40))
	beam.Transparency = NumberSequence.new(0.08)
	beam.Parent = hrp

	createTargetBillboard(target)
end

local function requestRetarget()
	local now = os.clock()
	if now - lastRetargetRequestAt < 1 then
		return
	end
	lastRetargetRequestAt = now
	tutorialRequestRetargetRemote:FireServer()
end

local function isTargetInvalid(): boolean
	local target = currentTarget
	if not target or not target.Parent then
		return true
	end
	if currentStage == "FindMonster" then
		return target:GetAttribute("Dead") == true or target:GetAttribute("Collected") == true
	end
	return false
end

local function onUpdate(payload: any)
	if type(payload) ~= "table" then
		return
	end

	if payload.Active == false or payload.Stage == "Completed" then
		cleanup()
		return
	end

	ensureGui()
	active = true
	currentStage = tostring(payload.Stage or "")
	currentTarget = payload.Target
	currentText = tostring(payload.Text or "")
	currentNearText = if type(payload.NearText) == "string" then payload.NearText else nil
	reachedMerchantSent = false

	if mainLabel then
		mainLabel.Text = currentText
	end
	if nearLabel then
		nearLabel.Visible = false
		nearLabel.Text = currentNearText or ""
	end

	rebuildGuideVisual()
end

function TutorialController.Init()
	tutorialUpdateRemote.OnClientEvent:Connect(onUpdate)

	player.CharacterAdded:Connect(function()
		task.delay(0.25, function()
			if active then
				rebuildGuideVisual()
			end
		end)
	end)

	RunService.Heartbeat:Connect(function()
		if not active then
			return
		end

		if isTargetInvalid() then
			if currentStage == "FindMonster" then
				requestRetarget()
			else
				rebuildGuideVisual()
			end
			return
		end

		local hrp = getHrp()
		local target = currentTarget
		if not hrp or not (target and target:IsA("BasePart")) then
			return
		end

		local distance = (hrp.Position - target.Position).Magnitude
		if nearLabel then
			nearLabel.Visible = currentStage == "FindMonster" and currentNearText ~= nil and distance <= 12
		end

		if currentStage == "GoMerchant" and not reachedMerchantSent and distance <= 12 then
			reachedMerchantSent = true
			tutorialClientReachedTargetRemote:FireServer("GoMerchant")
		end
	end)
end

return TutorialController