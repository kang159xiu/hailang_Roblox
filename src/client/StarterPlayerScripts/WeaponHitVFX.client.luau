--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local playWeaponHitVFXRemote = remotes:WaitForChild("PlayWeaponHitVFX") :: RemoteEvent

local VFX_FOLDER_NAME = "武器VFX"
local VFX_LIFETIME = 0.6

local function getEffectNameForWeaponLevel(weaponLevel: number): string
	return string.format("武器命中特效%02d", weaponLevel)
end

local function getWeaponVFXFolder(): Folder?
	local folder = ReplicatedStorage:FindFirstChild(VFX_FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end
	return nil
end

local function configureEffectPart(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
end

local function enableVisualDescendants(root: Instance)
	for _, descendant in ipairs(root:GetDescendants()) do
		if descendant:IsA("ParticleEmitter") then
			descendant.Enabled = true
		elseif descendant:IsA("Trail") then
			descendant.Enabled = true
		elseif descendant:IsA("Beam") then
			descendant.Enabled = true
		end
	end
end

local function weldPartToTarget(part: BasePart, targetPart: BasePart)
	if part == targetPart then
		return
	end

	configureEffectPart(part)
	local offset = targetPart.CFrame:ToObjectSpace(part.CFrame)
	part.CFrame = targetPart.CFrame * offset

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = targetPart
	weld.Part1 = part
	weld.Parent = part
end

local function attachEffectInstance(effectInstance: Instance, targetPart: BasePart)
	if effectInstance:IsA("BasePart") then
		effectInstance.CFrame = targetPart.CFrame
		effectInstance.Parent = workspace
		weldPartToTarget(effectInstance, targetPart)
		return
	end

	if effectInstance:IsA("Model") then
		effectInstance:PivotTo(targetPart.CFrame)
		effectInstance.Parent = workspace
		for _, descendant in ipairs(effectInstance:GetDescendants()) do
			if descendant:IsA("BasePart") then
				weldPartToTarget(descendant, targetPart)
			end
		end
		return
	end

	effectInstance.Parent = targetPart
	for _, child in ipairs(effectInstance:GetChildren()) do
		if child:IsA("BasePart") then
			weldPartToTarget(child, targetPart)
		end
	end
end

local function playWeaponHitVFX(targetPart: BasePart, weaponLevel: number)
	if weaponLevel <= 0 then
		return
	end

	local weaponVFXFolder = getWeaponVFXFolder()
	if not weaponVFXFolder then
		return
	end

	local effectName = getEffectNameForWeaponLevel(weaponLevel)
	local template = weaponVFXFolder:FindFirstChild(effectName)
	if not template then
		return
	end

	local cloned = template:Clone()
	attachEffectInstance(cloned, targetPart)
	enableVisualDescendants(cloned)

	task.delay(VFX_LIFETIME, function()
		if cloned.Parent then
			cloned:Destroy()
		end
	end)
end

playWeaponHitVFXRemote.OnClientEvent:Connect(function(targetPart: Instance, weaponLevel: number)
	if not targetPart or not targetPart:IsA("BasePart") then
		return
	end

	if type(weaponLevel) ~= "number" then
		return
	end

	playWeaponHitVFX(targetPart, weaponLevel)
end)