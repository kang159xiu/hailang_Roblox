--!strict
-- ServerScriptService.Modules.WeaponService
-- 处理：普通攻击、武器技能（18/19/20）

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("GameModules"):WaitForChild("Config"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local MonsterService = require(script.Parent:WaitForChild("MonsterService"))

local WeaponService = {}

local remotes = ReplicatedStorage:WaitForChild("Remotes")
local useSkillRemote = remotes:WaitForChild("RequestUseWeaponSkill") :: RemoteEvent

-- 玩家技能冷却
local lastSkillAt: {[number]: number} = {}

local function canUseSkill(player: Player): boolean
	local now = os.clock()
	local t = lastSkillAt[player.UserId] or 0
	if now - t < Config.SKILL_COOLDOWN_SECONDS then
		return false
	end
	lastSkillAt[player.UserId] = now
	return true
end

local function findMonstersInRadius(center: Vector3, radius: number): {BasePart}
	local monstersFolder = workspace:FindFirstChild("Monsters")
	if not monstersFolder then
		return {}
	end

	local parts = workspace:GetPartBoundsInRadius(center, radius, OverlapParams.new())
	local out: {BasePart} = {}
	local seen: {[BasePart]: true} = {}

	for _, p in ipairs(parts) do
		-- 现在怪是 Model（含 Root Part），因此用 IsDescendantOf 过滤，而不是 p.Parent==monstersFolder
		if p:IsA("BasePart") and p:GetAttribute("IsMonster") == true and p:IsDescendantOf(monstersFolder) then
			if not seen[p] then
				seen[p] = true
				table.insert(out, p)
			end
		end
	end

	return out
end

local function applyDamageToMonsterPart(_player: Player, monster: BasePart, damage: number)
	local hp = monster:GetAttribute("HP")
	if type(hp) ~= "number" or hp <= 0 then
		return
	end

	monster:SetAttribute("HP", math.max(0, hp - damage))
	if (monster:GetAttribute("HP") :: number) <= 0 then
		MonsterService.MarkDead(monster)
	end
end

local function cloneVFX(name: string): Instance?
	local folder = ReplicatedStorage:FindFirstChild("Folder_VFX3")
	if folder and folder:IsA("Folder") then
		local v = folder:FindFirstChild(name)
		if v then
			return v:Clone()
		end
	end
	return nil
end

local function cloneVFXFromFolderVfx(): Instance?
	local folder = ReplicatedStorage:FindFirstChild("Folder_vfx")
	if folder and folder:IsA("Folder") then
		local any = folder:GetChildren()[1]
		if any then
			return any:Clone()
		end
	end
	return nil
end

local function skill18(player: Player, hrp: BasePart)
	-- 三个投射物，分别用 Purple/Blue/Red
	local specs = {
		{ angle = 0, name = "Purple" },
		{ angle = -30, name = "Blue" },
		{ angle = 30, name = "Red" },
	}

	for _, s in ipairs(specs) do
		local vfx = cloneVFX(s.name)
		local part: BasePart
		if vfx and vfx:IsA("BasePart") then
			part = vfx
		else
			part = Instance.new("Part")
			part.Name = "Skill18Projectile"
			part.Size = Vector3.new(1, 1, 2)
			part.Anchored = true
			part.CanCollide = false
			part.Material = Enum.Material.Neon
			part.Color = Color3.fromRGB(180, 80, 255)
		end

		part.Anchored = true
		part.CanCollide = false
		part.Parent = workspace

		local start = hrp.CFrame * CFrame.new(0, 0, -Config.GRID_STUDS)
		local dirCF = hrp.CFrame * CFrame.Angles(0, math.rad(s.angle), 0)
		local dir = dirCF.LookVector
		part.CFrame = CFrame.new(start.Position, start.Position + dir)

		local maxDist = 10 * Config.GRID_STUDS
		local speed = 60 -- studs/s
		local traveled = 0
		local hit: {[BasePart]: true} = {}

		local conn: RBXScriptConnection?
		conn = RunService.Heartbeat:Connect(function(dt)
			if not part.Parent then
				if conn then conn:Disconnect() end
				return
			end

			local step = speed * dt
			traveled += step
			part.CFrame = part.CFrame + dir * step

			local monsters = findMonstersInRadius(part.Position, 3)
			for _, m in ipairs(monsters) do
				if not hit[m] then
					hit[m] = true
					applyDamageToMonsterPart(player, m, Config.SKILL18_PROJECTILE_DAMAGE)
				end
			end

			if traveled >= maxDist then
				if conn then conn:Disconnect() end
				part:Destroy()
			end
		end)

		task.delay(2.5, function()
			if part.Parent then
				part:Destroy()
			end
			if conn then conn:Disconnect() end
		end)
	end
end

local function skill19(player: Player, hrp: BasePart)
	-- 前方推进 10 格：每 0.1s 生成一个 vfx，存在 0.2s，每个伤害 7000
	local origin = (hrp.CFrame * CFrame.new(0, 0, -Config.GRID_STUDS)).Position
	local dir = hrp.CFrame.LookVector

	for i = 1, 10 do
		task.delay((i - 1) * 0.1, function()
			local pos = origin + dir * (i * Config.GRID_STUDS)
			local vfx = cloneVFXFromFolderVfx()

			local inst: Instance
			if vfx then
				inst = vfx
				inst.Parent = workspace
				if inst:IsA("BasePart") then
					inst.CFrame = CFrame.new(pos)
				elseif inst:IsA("Model") then
					inst:PivotTo(CFrame.new(pos))
				end
			else
				local p = Instance.new("Part")
				p.Anchored = true
				p.CanCollide = false
				p.Material = Enum.Material.Neon
				p.Color = Color3.fromRGB(160, 200, 255)
				p.Size = Vector3.new(2, 2, 2)
				p.CFrame = CFrame.new(pos)
				p.Parent = workspace
				inst = p
			end

			local monsters = findMonstersInRadius(pos, 4)
			for _, m in ipairs(monsters) do
				applyDamageToMonsterPart(player, m, Config.SKILL19_TICK_DAMAGE)
			end

			task.delay(0.2, function()
				if inst and inst.Parent then
					inst:Destroy()
				end
			end)
		end)
	end
end

local function skill20(player: Player, hrp: BasePart)
	-- 玩家中心生成 HollowPurple VFX，对周围 8 格怪造成伤害
	local radius = 8 * Config.GRID_STUDS
	local pos = hrp.Position

	local vfxTemplate = ReplicatedStorage:FindFirstChild("HollowPurple VFX")
	local inst: Instance
	if vfxTemplate then
		inst = vfxTemplate:Clone()
		inst.Parent = workspace
		if inst:IsA("BasePart") then
			inst.CFrame = CFrame.new(pos)
		elseif inst:IsA("Model") then
			inst:PivotTo(CFrame.new(pos))
		end
	else
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(180, 0, 255)
		p.Size = Vector3.new(radius * 0.25, 1, radius * 0.25)
		p.CFrame = CFrame.new(pos)
		p.Parent = workspace
		inst = p
	end

	local monsters = findMonstersInRadius(pos, radius)
	for _, m in ipairs(monsters) do
		applyDamageToMonsterPart(player, m, Config.SKILL20_AOE_DAMAGE)
	end

	task.delay(0.6, function()
		if inst and inst.Parent then
			inst:Destroy()
		end
	end)
end

function WeaponService.Init()
	useSkillRemote.OnServerEvent:Connect(function(player: Player)
		local stats = PlayerData.Get(player)
		local weaponLevel = stats.EquippedWeaponLevel or stats.WeaponLevel
		if weaponLevel < 18 then
			return
		end
		if not canUseSkill(player) then
			return
		end

		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		if not hrp or not hum or hum.Health <= 0 then
			return
		end

		if weaponLevel == 18 then
			skill18(player, hrp)
		elseif weaponLevel == 19 then
			skill19(player, hrp)
		elseif weaponLevel == 20 then
			skill20(player, hrp)
		end
	end)
end

return WeaponService
