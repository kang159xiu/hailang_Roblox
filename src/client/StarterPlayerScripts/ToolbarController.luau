--!strict
-- StarterPlayerScripts.ToolbarController
-- 自定义底部快捷栏：用 ViewportFrame 直接展示武器/怪物 3D 形象。
-- 形象来源：
--   武器：ReplicatedStorage.WeaponAppearances
--   怪物：ReplicatedStorage["Monster image"] 或 ReplicatedStorage.MonsterAppearances

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local ToolbarController = {}

local MAX_SLOTS = 10
local SLOT_SIZE = 70
local SLOT_GAP = 8
local GUI_NAME = "CustomViewportToolbar"
local TEMPLATE_GUI_NAME = "ToolbarTemplates"
local TEMPLATE_SLOT_NAME = "ToolbarSlotTemplate"

local player = Players.LocalPlayer

local toolbarGui: ScreenGui? = nil
local toolbarFrame: Frame? = nil
local slots: {Frame} = {}
local slotTools: {[number]: Tool} = {}
local activeConnections: {RBXScriptConnection} = {}
local refreshQueued = false
local initialized = false

local KEY_TO_SLOT: {[Enum.KeyCode]: number} = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.Zero] = 10,
}

local function disconnectAll()
	for _, connection in ipairs(activeConnections) do
		connection:Disconnect()
	end
	table.clear(activeConnections)
end

local function appendUniqueInstance(list: {Instance}, inst: Instance?)
	if not inst then
		return
	end
	for _, existing in ipairs(list) do
		if existing == inst then
			return
		end
	end
	table.insert(list, inst)
end

local function isRenderableTemplate(inst: Instance): boolean
	return inst:IsA("BasePart")
		or ((inst:IsA("Model") or inst:IsA("Folder") or inst:IsA("Tool")) and inst:FindFirstChildWhichIsA("BasePart", true) ~= nil)
end

local function scoreTemplate(inst: Instance): number
	if not isRenderableTemplate(inst) then
		return -1
	end

	local score = #inst:GetDescendants()
	if inst:IsA("Model") then
		score += 1000000
	elseif inst:IsA("Folder") then
		score += 200000
	elseif inst:IsA("Tool") then
		score += 150000
	elseif inst:IsA("BasePart") then
		score += 100000
	end
	return score
end

local function findBestNamedTemplate(root: Instance, names: {string}): Instance?
	local nameSet: {[string]: boolean} = {}
	for _, name in ipairs(names) do
		nameSet[name] = true
	end

	local best: Instance? = nil
	local bestScore = -1

	local function consider(candidate: Instance?)
		if not candidate then
			return
		end
		local score = scoreTemplate(candidate)
		if score > bestScore then
			best = candidate
			bestScore = score
		end
	end

	for _, name in ipairs(names) do
		consider(root:FindFirstChild(name))
	end
	if best then
		return best
	end

	for _, inst in ipairs(root:GetDescendants()) do
		if nameSet[inst.Name] then
			consider(inst)
			local cur = inst.Parent
			while cur and cur ~= root do
				if cur:IsA("Model") then
					consider(cur)
					break
				end
				cur = cur.Parent
			end
		end
	end

	return best
end

local function findWeaponTemplate(level: number): Instance?
	local folder = ReplicatedStorage:FindFirstChild("WeaponAppearances")
	if not folder or not folder:IsA("Folder") then
		return nil
	end

	local safeLevel = math.max(1, math.floor(tonumber(level) or 1))
	local strNormal = tostring(safeLevel)
	local strZero = string.format("%02d", safeLevel)
	return findBestNamedTemplate(folder, {
		"武器" .. strZero,
		"武器" .. strNormal,
		"武器 " .. strZero,
		"武器 " .. strNormal,
		"Weapon" .. strZero,
		"Weapon" .. strNormal,
		"Weapon " .. strZero,
		"Weapon " .. strNormal,
	})
end

local function getMonsterAppearanceFolders(): {Instance}
	local folders = {}
	appendUniqueInstance(folders, ReplicatedStorage:FindFirstChild("Monster image"))
	appendUniqueInstance(folders, ReplicatedStorage:FindFirstChild("MonsterAppearances"))
	return folders
end

local function findMonsterTemplate(level: number): Instance?
	local safeLevel = math.max(1, math.floor(tonumber(level) or 1))
	local strNormal = tostring(safeLevel)
	local strZero = string.format("%02d", safeLevel)
	local names = {
		"怪物形象" .. strNormal,
		"怪物形象" .. strZero,
		"怪物形象 " .. strNormal,
		"怪物形象 " .. strZero,
		"Lv" .. strNormal,
		"Lv" .. strZero,
		"Lv " .. strNormal,
		"Lv " .. strZero,
		strNormal,
		strZero,
	}

	for _, root in ipairs(getMonsterAppearanceFolders()) do
		local found = findBestNamedTemplate(root, names)
		if found then
			return found
		end
	end
	return nil
end

local function findTemplateForTool(tool: Tool): Instance?
	local monsterLevel = tool:GetAttribute("MonsterLevel")
	if tool:GetAttribute("IsMonsterItem") == true and type(monsterLevel) == "number" then
		return findMonsterTemplate(monsterLevel) or tool
	end

	local weaponLevel = tool:GetAttribute("WeaponLevel")
	if (tool:GetAttribute("IsWeaponTool") == true or type(weaponLevel) == "number") and type(weaponLevel) == "number" then
		return findWeaponTemplate(weaponLevel) or tool
	end

	return tool
end

local function stripViewportClone(root: Instance)
	for _, inst in ipairs(root:GetDescendants()) do
		if inst:IsA("BaseScript") or inst:IsA("Humanoid") or inst:IsA("Animator") then
			inst:Destroy()
		elseif inst:IsA("BasePart") then
			inst.Anchored = true
			inst.CanCollide = false
			inst.CanTouch = false
			inst.CanQuery = false
			inst.CastShadow = false
		end
	end

	if root:IsA("BasePart") then
		root.Anchored = true
		root.CanCollide = false
		root.CanTouch = false
		root.CanQuery = false
		root.CastShadow = false
	end
end

local function isLikelyVisualPart(part: BasePart): boolean
	local lowerName = string.lower(part.Name)
	if lowerName == "rootpart" or lowerName == "root" or lowerName == "weaponroot" then
		return false
	end
	if part.Transparency >= 1 then
		return false
	end
	return true
end

local function getVisualBounds(root: Instance): (CFrame?, Vector3?)
	local parts: {BasePart} = {}
	for _, inst in ipairs(root:GetDescendants()) do
		if inst:IsA("BasePart") and isLikelyVisualPart(inst) then
			table.insert(parts, inst)
		end
	end
	if root:IsA("BasePart") and isLikelyVisualPart(root) then
		table.insert(parts, root)
	end

	if #parts == 0 then
		for _, inst in ipairs(root:GetDescendants()) do
			if inst:IsA("BasePart") then
				table.insert(parts, inst)
			end
		end
		if root:IsA("BasePart") then
			table.insert(parts, root)
		end
	end

	if #parts == 0 then
		return nil, nil
	end

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, part in ipairs(parts) do
		local cf = part.CFrame
		local half = part.Size * 0.5
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local p = (cf * CFrame.new(half.X * x, half.Y * y, half.Z * z)).Position
					minX = math.min(minX, p.X)
					minY = math.min(minY, p.Y)
					minZ = math.min(minZ, p.Z)
					maxX = math.max(maxX, p.X)
					maxY = math.max(maxY, p.Y)
					maxZ = math.max(maxZ, p.Z)
				end
			end
		end
	end

	local center = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
	local size = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
	return CFrame.new(center), size
end

local function getRootBounds(root: Instance): (CFrame?, Vector3?)
	if root:IsA("Model") then
		return root:GetBoundingBox()
	elseif root:IsA("BasePart") then
		return root.CFrame, root.Size
	end
	return getVisualBounds(root)
end

local function normalizeCloneRoot(clone: Instance, worldModel: WorldModel): Instance
	if clone:IsA("Folder") or clone:IsA("Tool") then
		local wrapper = Instance.new("Model")
		wrapper.Name = clone.Name .. "_ViewportModel"
		wrapper.Parent = worldModel
		for _, child in ipairs(clone:GetChildren()) do
			child.Parent = wrapper
		end
		clone:Destroy()
		clone = wrapper
	end

	local visualModel = clone:FindFirstChild("Model", true)
	if visualModel and visualModel:IsA("Model") and visualModel:FindFirstChildWhichIsA("BasePart", true) then
		visualModel.Parent = worldModel
		clone:Destroy()
		clone = visualModel
	end

	return clone
end

local function getOrCreateIconViewport(targetContainer: GuiObject): ViewportFrame
	local existing = targetContainer:FindFirstChildWhichIsA("ViewportFrame", true)
	if existing then
		return existing
	end

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "IconViewport"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	viewport.Parent = targetContainer
	return viewport
end

local function clearViewportContents(viewport: ViewportFrame)
	for _, child in ipairs(viewport:GetChildren()) do
		if child:IsA("WorldModel") or child:IsA("Camera") then
			child:Destroy()
		end
	end
	viewport.CurrentCamera = nil
end

local function loadViewport(targetContainer: GuiObject, modelSource: Instance?)
	local viewport = getOrCreateIconViewport(targetContainer)
	clearViewportContents(viewport)
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(230, 230, 230)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-0.5, -1, -0.5)

	if not modelSource then
		return
	end

	local worldModel = Instance.new("WorldModel")
	worldModel.Parent = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = 35
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local clone = modelSource:Clone()
	clone.Parent = worldModel
	stripViewportClone(clone)
	clone = normalizeCloneRoot(clone, worldModel)

	local boundsCF, boundsSize = getVisualBounds(clone)
	if not boundsCF or not boundsSize then
		warn("[ToolbarController] Viewport 渲染失败：模板中没有可显示 BasePart - " .. modelSource:GetFullName())
		return
	end

	if clone:IsA("Model") then
		local modelCF, modelSize = getRootBounds(clone)
		if modelCF and modelSize then
			clone:PivotTo(CFrame.new(0, modelSize.Y * 0.5, 0) * modelCF:Inverse() * clone:GetPivot())
		else
			clone:PivotTo(CFrame.new(0, boundsSize.Y * 0.5, 0) * boundsCF:Inverse() * clone:GetPivot())
		end
	elseif clone:IsA("BasePart") then
		clone.CFrame = CFrame.new(0, boundsSize.Y * 0.5, 0)
	end

	boundsCF, boundsSize = getVisualBounds(clone)
	if not boundsCF or not boundsSize then
		return
	end

	local maxDim = math.max(boundsSize.X, boundsSize.Y, boundsSize.Z)
	if maxDim < 0.1 then
		maxDim = 5
	end

	local rootCF = getRootBounds(clone)
	local center = if rootCF then rootCF.Position else boundsCF.Position
	local distance = maxDim * 1.15
	local height = math.max(boundsSize.Y * 0.08, maxDim * 0.18)
	camera.CFrame = CFrame.new(center + Vector3.new(-distance, height, -distance), center)
end

local function getToolDisplayName(tool: Tool): string
	local monsterLevel = tool:GetAttribute("MonsterLevel")
	if tool:GetAttribute("IsMonsterItem") == true and type(monsterLevel) == "number" then
		return "怪 Lv." .. tostring(monsterLevel)
	end

	local weaponLevel = tool:GetAttribute("WeaponLevel")
	if (tool:GetAttribute("IsWeaponTool") == true or type(weaponLevel) == "number") and type(weaponLevel) == "number" then
		return "武器 Lv." .. tostring(weaponLevel)
	end

	return tool.Name
end

local function getCharacter(): Model?
	return player.Character
end

local function getHumanoid(): Humanoid?
	local character = getCharacter()
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function isEquipped(tool: Tool): boolean
	local character = getCharacter()
	return character ~= nil and tool.Parent == character
end

local function isWeaponTool(tool: Tool): boolean
	return tool:GetAttribute("IsWeaponTool") == true or type(tool:GetAttribute("WeaponLevel")) == "number"
end

local function equipSlot(slotIndex: number)
	local tool = slotTools[slotIndex]
	if not tool or not tool.Parent then
		return
	end

	local humanoid = getHumanoid()
	if not humanoid then
		return
	end

	if isEquipped(tool) then
		humanoid:UnequipTools()
	else
		humanoid:EquipTool(tool)
	end

	task.defer(function()
		ToolbarController.Refresh()
	end)
end

local function getSlotKeyText(slotIndex: number): string
	return if slotIndex == 10 then "0" else tostring(slotIndex)
end

local function findSlotTemplate(): Frame?
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	local playerTemplates = if playerGui then playerGui:FindFirstChild(TEMPLATE_GUI_NAME) else nil
	local playerTemplate = if playerTemplates then playerTemplates:FindFirstChild(TEMPLATE_SLOT_NAME, true) else nil
	if playerTemplate and playerTemplate:IsA("Frame") then
		return playerTemplate
	end

	local sharedTemplates = ReplicatedStorage:FindFirstChild(TEMPLATE_GUI_NAME)
	local sharedTemplate = if sharedTemplates then sharedTemplates:FindFirstChild(TEMPLATE_SLOT_NAME, true) else nil
	if sharedTemplate and sharedTemplate:IsA("Frame") then
		return sharedTemplate
	end

	return nil
end

local function ensureViewportHolder(slot: Frame): GuiObject
	local existing = slot:FindFirstChild("ViewportHolder", true)
	if existing and existing:IsA("GuiObject") then
		getOrCreateIconViewport(existing)
		return existing
	end

	local viewportHolder = Instance.new("Frame")
	viewportHolder.Name = "ViewportHolder"
	viewportHolder.BackgroundTransparency = 1
	viewportHolder.Position = UDim2.fromOffset(6, 6)
	viewportHolder.Size = UDim2.new(1, -12, 1, -18)
	viewportHolder.ClipsDescendants = true
	viewportHolder.Parent = slot
	getOrCreateIconViewport(viewportHolder)
	return viewportHolder
end

local function ensureNameLabel(slot: Frame): TextLabel
	local existing = slot:FindFirstChild("NameLabel", true)
	if existing and existing:IsA("TextLabel") then
		return existing
	end

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.AnchorPoint = Vector2.new(0.5, 1)
	nameLabel.Position = UDim2.new(0.5, 0, 1, -3)
	nameLabel.Size = UDim2.new(1, -6, 0, 14)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
	nameLabel.TextStrokeTransparency = 0.35
	nameLabel.TextScaled = true
	nameLabel.Text = ""
	nameLabel.Parent = slot
	return nameLabel
end

local function ensureKeyLabel(slot: Frame): TextLabel
	local existing = slot:FindFirstChild("KeyLabel", true)
	if existing and existing:IsA("TextLabel") then
		return existing
	end

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "KeyLabel"
	keyLabel.Position = UDim2.fromOffset(4, 3)
	keyLabel.Size = UDim2.fromOffset(18, 18)
	keyLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	keyLabel.BackgroundTransparency = 0.35
	keyLabel.Font = Enum.Font.GothamBold
	keyLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	keyLabel.TextScaled = true
	keyLabel.Parent = slot

	local keyCorner = Instance.new("UICorner")
	keyCorner.CornerRadius = UDim.new(1, 0)
	keyCorner.Parent = keyLabel
	return keyLabel
end

local function ensureStateStroke(slot: Frame): UIStroke
	local existing = slot:FindFirstChild("StateStroke", true)
	if existing and existing:IsA("UIStroke") then
		return existing
	end

	local stroke = Instance.new("UIStroke")
	stroke.Name = "StateStroke"
	stroke.Color = Color3.fromRGB(95, 95, 105)
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.Parent = slot
	return stroke
end

local function ensureClickButton(slot: Frame, slotIndex: number): TextButton
	local existing = slot:FindFirstChild("ClickButton", true)
	local clickButton: TextButton
	if existing and existing:IsA("TextButton") then
		clickButton = existing
	else
		clickButton = Instance.new("TextButton")
		clickButton.Name = "ClickButton"
		clickButton.BackgroundTransparency = 1
		clickButton.Size = UDim2.fromScale(1, 1)
		clickButton.Text = ""
		clickButton.AutoButtonColor = false
		clickButton.Parent = slot
	end

	clickButton.Activated:Connect(function()
		equipSlot(slotIndex)
	end)
	return clickButton
end

local function prepareSlot(slot: Frame, slotIndex: number): Frame
	slot.Name = "Slot" .. tostring(slotIndex)
	slot.LayoutOrder = slotIndex
	slot.Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
	slot.Visible = true

	ensureViewportHolder(slot)
	ensureNameLabel(slot)
	local keyLabel = ensureKeyLabel(slot)
	keyLabel.Text = getSlotKeyText(slotIndex)
	ensureStateStroke(slot)
	ensureClickButton(slot, slotIndex)
	return slot
end

local function usesToolbarTemplate(slot: Frame): boolean
	return slot:GetAttribute("UsesToolbarTemplate") == true
end

local function createSlot(slotIndex: number): Frame
	local template = findSlotTemplate()
	if template then
		local slot = prepareSlot(template:Clone(), slotIndex)
		slot:SetAttribute("UsesToolbarTemplate", true)
		return slot
	end

	local slot = Instance.new("Frame")
	slot.Name = "Slot" .. tostring(slotIndex)
	slot.Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
	slot.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
	slot.BackgroundTransparency = 0.08
	slot.BorderSizePixel = 0
	slot.LayoutOrder = slotIndex
	slot:SetAttribute("UsesToolbarTemplate", false)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = slot

	local stroke = Instance.new("UIStroke")
	stroke.Name = "StateStroke"
	stroke.Color = Color3.fromRGB(95, 95, 105)
	stroke.Thickness = 2
	stroke.Transparency = 0.15
	stroke.Parent = slot

	local viewportHolder = Instance.new("Frame")
	viewportHolder.Name = "ViewportHolder"
	viewportHolder.BackgroundTransparency = 1
	viewportHolder.Position = UDim2.fromOffset(6, 6)
	viewportHolder.Size = UDim2.new(1, -12, 1, -18)
	viewportHolder.ClipsDescendants = true
	viewportHolder.Parent = slot

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.AnchorPoint = Vector2.new(0.5, 1)
	nameLabel.Position = UDim2.new(0.5, 0, 1, -3)
	nameLabel.Size = UDim2.new(1, -6, 0, 14)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
	nameLabel.TextStrokeTransparency = 0.35
	nameLabel.TextScaled = true
	nameLabel.Text = ""
	nameLabel.Parent = slot

	local keyLabel = Instance.new("TextLabel")
	keyLabel.Name = "KeyLabel"
	keyLabel.Position = UDim2.fromOffset(4, 3)
	keyLabel.Size = UDim2.fromOffset(18, 18)
	keyLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	keyLabel.BackgroundTransparency = 0.35
	keyLabel.Font = Enum.Font.GothamBold
	keyLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	keyLabel.TextScaled = true
	keyLabel.Text = getSlotKeyText(slotIndex)
	keyLabel.Parent = slot

	local keyCorner = Instance.new("UICorner")
	keyCorner.CornerRadius = UDim.new(1, 0)
	keyCorner.Parent = keyLabel

	local clickButton = Instance.new("TextButton")
	clickButton.Name = "ClickButton"
	clickButton.BackgroundTransparency = 1
	clickButton.Size = UDim2.fromScale(1, 1)
	clickButton.Text = ""
	clickButton.AutoButtonColor = false
	clickButton.Parent = slot
	clickButton.Activated:Connect(function()
		equipSlot(slotIndex)
	end)

	return slot
end

local function ensureSlot(slotIndex: number): Frame
	local slot = slots[slotIndex]
	if slot and slot.Parent then
		return slot
	end

	local parent = toolbarFrame
	assert(parent, "Toolbar frame must exist before creating toolbar slots")
	slot = createSlot(slotIndex)
	slot.Parent = parent
	slots[slotIndex] = slot
	return slot
end

local function ensureGui()
	if toolbarGui and toolbarGui.Parent then
		return
	end

	local playerGui = player:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild(GUI_NAME)
	if existing and existing:IsA("ScreenGui") then
		existing:Destroy()
	end

	toolbarGui = Instance.new("ScreenGui")
	toolbarGui.Name = GUI_NAME
	toolbarGui.ResetOnSpawn = false
	toolbarGui.IgnoreGuiInset = true
	toolbarGui.Enabled = true
	toolbarGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	toolbarGui.Parent = playerGui

	toolbarFrame = Instance.new("Frame")
	toolbarFrame.Name = "Toolbar"
	toolbarFrame.AnchorPoint = Vector2.new(0.5, 1)
	toolbarFrame.Position = UDim2.new(0.5, 0, 1, -18)
	toolbarFrame.Size = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
	toolbarFrame.Visible = false
	toolbarFrame.BackgroundTransparency = 1
	toolbarFrame.Parent = toolbarGui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, SLOT_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = toolbarFrame

	table.clear(slots)
end

local function collectTools(): {Tool}
	local ordered: {Tool} = {}
	local seen: {[Tool]: boolean} = {}

	local function appendFrom(container: Instance?)
		if not container then
			return
		end
		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") and not seen[child] then
				seen[child] = true
				table.insert(ordered, child)
			end
		end
	end

	appendFrom(player:FindFirstChildOfClass("Backpack"))
	appendFrom(player.Character)

	local primaryWeapon: Tool? = nil
	for _, tool in ipairs(ordered) do
		if isWeaponTool(tool) and isEquipped(tool) then
			primaryWeapon = tool
			break
		end
	end
	if not primaryWeapon then
		for _, tool in ipairs(ordered) do
			if isWeaponTool(tool) then
				primaryWeapon = tool
				break
			end
		end
	end

	local result: {Tool} = {}
	if primaryWeapon then
		table.insert(result, primaryWeapon)
	end
	for _, tool in ipairs(ordered) do
		if tool ~= primaryWeapon then
			table.insert(result, tool)
		end
	end

	return result
end

local function setSlotEmpty(slot: Frame)
	local viewportHolder = slot:FindFirstChild("ViewportHolder", true)
	if viewportHolder and viewportHolder:IsA("GuiObject") then
		local viewport = viewportHolder:FindFirstChildWhichIsA("ViewportFrame", true)
		if viewport then
			clearViewportContents(viewport)
		end
	end

	local nameLabel = slot:FindFirstChild("NameLabel", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = ""
	end

	local stroke = slot:FindFirstChild("StateStroke", true)
	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = Color3.fromRGB(95, 95, 105)
		stroke.Thickness = 2
		stroke.Transparency = 0.45
	end
	if not usesToolbarTemplate(slot) then
		slot.BackgroundTransparency = 0.32
	end
end

local function setSlotTool(slot: Frame, tool: Tool)
	local viewportHolder = slot:FindFirstChild("ViewportHolder", true)
	if viewportHolder and viewportHolder:IsA("GuiObject") then
		loadViewport(viewportHolder, findTemplateForTool(tool))
	end

	local nameLabel = slot:FindFirstChild("NameLabel", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = getToolDisplayName(tool)
	end

	local equipped = isEquipped(tool)
	local stroke = slot:FindFirstChild("StateStroke", true)
	if stroke and stroke:IsA("UIStroke") then
		stroke.Color = if equipped then Color3.fromRGB(255, 218, 76) else Color3.fromRGB(135, 135, 150)
		stroke.Thickness = if equipped then 4 else 2
		stroke.Transparency = if equipped then 0 else 0.15
	end
	if not usesToolbarTemplate(slot) then
		slot.BackgroundTransparency = if equipped then 0 else 0.08
	end
end

function ToolbarController.Refresh()
	ensureGui()
	table.clear(slotTools)

	local tools = collectTools()
	local visibleCount = math.min(#tools, MAX_SLOTS)

	if toolbarFrame then
		toolbarFrame.Visible = visibleCount > 0
		local width = if visibleCount > 0 then (SLOT_SIZE * visibleCount) + (SLOT_GAP * math.max(visibleCount - 1, 0)) else SLOT_SIZE
		toolbarFrame.Size = UDim2.fromOffset(width, SLOT_SIZE)
	end

	for i = 1, visibleCount do
		local slot = ensureSlot(i)
		local tool = tools[i]
		if tool then
			slot.Visible = true
			slotTools[i] = tool
			setSlotTool(slot, tool)
		end
	end

	for i = visibleCount + 1, #slots do
		local slot = slots[i]
		if slot then
			slot.Visible = false
			setSlotEmpty(slot)
		end
	end
end

local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		ToolbarController.Refresh()
	end)
end

local function hookTool(tool: Tool)
	table.insert(activeConnections, tool:GetAttributeChangedSignal("WeaponLevel"):Connect(queueRefresh))
	table.insert(activeConnections, tool:GetAttributeChangedSignal("MonsterLevel"):Connect(queueRefresh))
	table.insert(activeConnections, tool:GetAttributeChangedSignal("IsWeaponTool"):Connect(queueRefresh))
	table.insert(activeConnections, tool:GetAttributeChangedSignal("IsMonsterItem"):Connect(queueRefresh))
end

local function hookContainer(container: Instance?)
	if not container then
		return
	end

	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") then
			hookTool(child)
		end
	end

	table.insert(activeConnections, container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			hookTool(child)
		end
		queueRefresh()
	end))
	table.insert(activeConnections, container.ChildRemoved:Connect(queueRefresh))
end

local function rebuildHooks()
	disconnectAll()
	hookContainer(player:FindFirstChildOfClass("Backpack"))
	hookContainer(player.Character)
	queueRefresh()
end

function ToolbarController.Init()
	if initialized then
		return
	end
	initialized = true

	ensureGui()
	rebuildHooks()

	player.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then
			rebuildHooks()
		end
	end)

	player.CharacterAdded:Connect(function()
		task.defer(rebuildHooks)
	end)

	player.CharacterRemoving:Connect(function()
		queueRefresh()
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent or input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end

		local slotIndex = KEY_TO_SLOT[input.KeyCode]
		if slotIndex then
			equipSlot(slotIndex)
		end
	end)
end

return ToolbarController