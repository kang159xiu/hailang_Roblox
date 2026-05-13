--!strict
-- StarterPlayerScripts.HomeGlowClient
-- 只在本客户端修改自己 HOME 的发光颜色，避免服务端改 Workspace 导致全服可见。

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local setHomeGlowLocalColor = remotes:WaitForChild("SetHomeGlowLocalColor") :: RemoteEvent

local HOME_GLOW_INSIDE_COLOR = Color3.fromRGB(0, 140, 255)
local HOME_GLOW_OUTSIDE_COLOR = Color3.fromRGB(255, 255, 255)

local currentHomeRoot: Instance? = nil
local currentIsInsideHome = true

local function findHouse(homeRoot: Instance, level: number): Instance?
	return homeRoot:FindFirstChild(string.format("%d级房屋", level))
end

local function isGlowInstance(inst: Instance): boolean
	local lowerName = string.lower(inst.Name)
	if string.find(inst.Name, "发光") ~= nil or string.find(lowerName, "glow") ~= nil then
		return true
	end

	if inst:IsA("BasePart") and inst.Material == Enum.Material.Neon then
		return true
	end

	return false
end

local function setHouseGlowColor(house: Instance?, color: Color3)
	if not house then
		return
	end

	if house:IsA("BasePart") and isGlowInstance(house) then
		house.Color = color
	end

	for _, d in ipairs(house:GetDescendants()) do
		if d:IsA("BasePart") and isGlowInstance(d) then
			d.Color = color
		elseif d:IsA("PointLight") or d:IsA("SurfaceLight") or d:IsA("SpotLight") then
			local parent = d.Parent
			if isGlowInstance(d) or (parent ~= nil and isGlowInstance(parent)) then
				d.Color = color
			end
		end
	end
end

local function setHomeGlowColor(homeRoot: Instance, color: Color3)
	for lvl = 1, 3 do
		setHouseGlowColor(findHouse(homeRoot, lvl), color)
	end
end

local function applyCurrentGlowColor()
	local homeRoot = currentHomeRoot
	if not homeRoot or not homeRoot.Parent then
		return
	end

	setHomeGlowColor(homeRoot, if currentIsInsideHome then HOME_GLOW_INSIDE_COLOR else HOME_GLOW_OUTSIDE_COLOR)
end

setHomeGlowLocalColor.OnClientEvent:Connect(function(homeRoot: Instance, isInsideHome: boolean)
	if not homeRoot or not homeRoot.Parent then
		return
	end

	currentHomeRoot = homeRoot
	currentIsInsideHome = isInsideHome
	applyCurrentGlowColor()
end)
