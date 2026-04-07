--!strict
-- ServerScriptService.Modules.Util

local Util = {}

function Util.ensureFolder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if f and f:IsA("Folder") then
		return f
	end
	local newF = Instance.new("Folder")
	newF.Name = name
	newF.Parent = parent
	return newF
end

function Util.ensureNumberAttribute(inst: Instance, name: string, defaultValue: number)
	if inst:GetAttribute(name) == nil then
		inst:SetAttribute(name, defaultValue)
	end
end

function Util.randomPointOnTop(area: BasePart, margin: number): Vector3
	local half = area.Size * 0.5
	local usableX = math.max(0, half.X - margin)
	local usableZ = math.max(0, half.Z - margin)
	local localX = (math.random() * 2 - 1) * usableX
	local localZ = (math.random() * 2 - 1) * usableZ
	local localPos = Vector3.new(localX, half.Y, localZ)
	return area.CFrame:PointToWorldSpace(localPos)
end

function Util.isPointInsideZoneXZ(part: BasePart, point: Vector3, maxAbove: number?): boolean
	local localPos = part.CFrame:PointToObjectSpace(point)
	local half = part.Size * 0.5
	local above = maxAbove or 50

	return math.abs(localPos.X) <= half.X
		and math.abs(localPos.Z) <= half.Z
		and localPos.Y >= -half.Y - 10
		and localPos.Y <= half.Y + above
end

-- weights: array of numbers, indexes correspond to result values in values array (or 1..n)
function Util.weightedPick(weights: {number}): number?
	local total = 0
	for _, w in ipairs(weights) do
		if w > 0 then
			total += w
		end
	end
	if total <= 0 then
		return nil
	end
	local r = math.random() * total
	local acc = 0
	for i, w in ipairs(weights) do
		if w > 0 then
			acc += w
			if r <= acc then
				return i
			end
		end
	end
	return #weights
end

function Util.clamp(n: number, a: number, b: number): number
	return math.max(a, math.min(b, n))
end

return Util
