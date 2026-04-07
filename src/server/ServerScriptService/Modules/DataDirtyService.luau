--!strict
-- ServerScriptService.Modules.DataDirtyService
-- A tiny dependency-free module for marking player data as "dirty" and requesting saves.
-- Other services call MarkDirty() without depending on the persistence implementation.

export type DirtyHandler = (userId: number, saveSoonSeconds: number?) -> ()

local DataDirtyService = {}

local handlers: {DirtyHandler} = {}

function DataDirtyService.Bind(handler: DirtyHandler)
	table.insert(handlers, handler)
end

function DataDirtyService.MarkDirty(playerOrUserId: Player | number, saveSoonSeconds: number?)
	local userId: number
	if type(playerOrUserId) == "number" then
		userId = playerOrUserId
	else
		userId = (playerOrUserId :: Player).UserId
	end

	for _, h in ipairs(handlers) do
		task.spawn(h, userId, saveSoonSeconds)
	end
end

return DataDirtyService
