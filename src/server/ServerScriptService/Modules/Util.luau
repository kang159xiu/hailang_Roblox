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

function Util.FormatMoney(amount: number): string
    if type(amount) ~= "number" then return "0" end
    local abs = math.abs(amount)
    if abs < 1000 then return tostring(math.floor(amount)) end

    -- 欧美常见数值单位，最高支持到 Vg (10^63)
    local suffixes = {"K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd", "Td", "Qd", "Qid", "Sxd", "Spd", "Ocd", "Nod", "Vg"}
    
    local suffixIndex = 0
    local value = abs
    
-- 【修复核心】将进位阈值降低到 999.5。防止 999.5~999.99 之间的数字被 %.0f 四舍五入成 1000
    while value >= 999.5 and suffixIndex < #suffixes do
        value /= 1000
        suffixIndex += 1
    end

    if value >= 1000 then
        -- 当数值爆炸超过上限时，自动退化为安全的科学计数法
        return string.format("%.2fe%d", value, suffixIndex * 3)
    end
    
    local formatted = (value >= 100) and string.format("%.0f", value) 
                   or (value >= 10 and string.format("%.1f", value) 
                   or string.format("%.2f", value))

    -- 优化正则，安全去除末尾多余的0和小数点，防止整百数值误删
    if string.find(formatted, "%.") then
        formatted = string.gsub(formatted, "0+$", "")
        formatted = string.gsub(formatted, "%.$", "")
    end

    return (amount < 0 and "-" or "") .. formatted .. suffixes[suffixIndex]
end


return Util
