--!strict
-- ServerScriptService.Modules.LavaService
-- 在拿取区域内随机生成“预警块”与“岩浆块”，并按区域等级造成不同 DPS。

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))

local Util = require(script.Parent:WaitForChild("Util"))
local ZoneService = require(script.Parent:WaitForChild("ZoneService"))

local LavaService = {}

-- 可调：每个区域多久来一次岩浆事件（秒）
local LAVA_EVENT_INTERVAL_MIN = 2
local LAVA_EVENT_INTERVAL_MAX = 5

-- 岩浆“落点”大小（studs）
local LAVA_PATCH_SIZE = Vector3.new(10, 1, 10)

-- 岩浆上升动画时间
local RISE_TIME = 1.25

local hazardsFolder: Folder

local function getHumanoidsInBox(cframe: CFrame, size: Vector3): {Humanoid}
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { hazardsFolder }

	local parts = workspace:GetPartBoundsInBox(cframe, size, params)
	local humanoids: {Humanoid} = {}
	local seen: {[Humanoid]: true} = {}

	for _, p in ipairs(parts) do
		local model = p:FindFirstAncestorOfClass("Model")
		if model then
			local hum = model:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 and not seen[hum] then
				seen[hum] = true
				table.insert(humanoids, hum)
			end
		end
	end

	return humanoids
end

local function pickPatchCFrame(zone: BasePart): CFrame
	local pos = Util.randomPointOnTop(zone, 2)
	-- 把 patch 对齐到区域朝向
	local y = zone.Position.Y + zone.Size.Y * 0.5
	return CFrame.new(Vector3.new(pos.X, y, pos.Z)) * CFrame.Angles(0, math.rad(zone.Orientation.Y), 0)
end

local function createWarning(cf: CFrame): BasePart
	local w = Instance.new("Part")
	w.Name = "LavaWarning"
	w.Anchored = true
	w.CanCollide = false
	w.CanQuery = false
	w.CanTouch = false
	w.Size = LAVA_PATCH_SIZE
	w.CFrame = cf + Vector3.new(0, 0.05, 0)
	w.Material = Enum.Material.SmoothPlastic
	w.Color = Color3.fromRGB(255, 0, 0)
	w.Transparency = 0.55
	w.Parent = hazardsFolder
	return w
end

local function createLava(cf: CFrame, finalHeightStuds: number): BasePart
	local lava = Instance.new("Part")
	lava.Name = "Lava"
	lava.Anchored = true
	lava.CanCollide = false
	lava.Material = Enum.Material.Neon
	lava.Color = Color3.fromRGB(255, 80, 0)
	lava.Transparency = 0.15
	lava.Size = Vector3.new(LAVA_PATCH_SIZE.X, 0.2, LAVA_PATCH_SIZE.Z)

	-- 初始从地面下方开始（隐藏）
	lava.CFrame = cf + Vector3.new(0, -finalHeightStuds * 0.5, 0)
	lava.Parent = hazardsFolder

	local goalSize = Vector3.new(LAVA_PATCH_SIZE.X, finalHeightStuds, LAVA_PATCH_SIZE.Z)
	local goalCF = cf + Vector3.new(0, finalHeightStuds * 0.5, 0)

	local tween = TweenService:Create(
		lava,
		TweenInfo.new(RISE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = goalSize, CFrame = goalCF }
	)
	tween:Play()

	return lava
end

local function runLavaEvent(zone: BasePart, zoneLevel: number)
	local range = Config.LAVA_HEIGHT_RANGE_GRIDS_BY_ZONE[zoneLevel]
	if not range then
		return
	end

	local minG, maxG = range[1], range[2]
	local minStuds = minG * Config.GRID_STUDS
	local maxStuds = maxG * Config.GRID_STUDS
	local finalHeight = math.random() * (maxStuds - minStuds) + minStuds

	local cf = pickPatchCFrame(zone)
	local warning = createWarning(cf)
	
	-- [修改内容] 获取我们在 Config 中设置的预警时间，如果没设置则默认保底 2 秒
	local warningTime = Config.LAVA_WARNING_TIME or 2

	-- [修改内容] 将原本写死的 2 改为使用 warningTime 变量
	task.delay(warningTime, function()
		if warning.Parent then
			warning:Destroy()
		end

		local lava = createLava(cf, finalHeight)
		lava:SetAttribute("ZoneLevel", zoneLevel)
		lava:SetAttribute("DPS", Config.LAVA_DAMAGE_PER_SEC_BY_ZONE[zoneLevel] or 100)

		-- 持续时间：升起完成后再存在 2 秒
		local alive = true
		task.delay(RISE_TIME + 2.0, function()
			alive = false
			if lava.Parent then
				lava:Destroy()
			end
		end)

		-- 伤害循环
		task.spawn(function()
			local dps = lava:GetAttribute("DPS")
			if type(dps) ~= "number" then
				dps = 100
			end

			local last = os.clock()
			while alive and lava.Parent do
				local now = os.clock()
				local dt = now - last
				last = now

				local humanoids = getHumanoidsInBox(lava.CFrame, lava.Size + Vector3.new(0, 6, 0))
				for _, hum in ipairs(humanoids) do
					hum:TakeDamage(dps * dt)
				end

				task.wait(0.15)
			end
		end)
	end)
end

function LavaService.Init()
	hazardsFolder = Util.ensureFolder(workspace, "Hazards")

	local zones = ZoneService.GetPickupZones()
	for _, z in ipairs(zones) do
		local zonePart = z.Part
		local zoneLevel = z.Level

		task.spawn(function()
			-- 1. 新增逻辑：游戏开始2秒后，大部分区域（80%概率）立刻生成一次岩浆
			task.wait(2)
			if math.random() <= 0.8 then
				runLavaEvent(zonePart, zoneLevel)
			end

			-- 2. 原有逻辑：之后恢复正常的随机间隔循环
			while true do
				local waitTime = math.random(LAVA_EVENT_INTERVAL_MIN, LAVA_EVENT_INTERVAL_MAX)
				task.wait(waitTime)
				runLavaEvent(zonePart, zoneLevel)
			end
		end)
	end
end

return LavaService
