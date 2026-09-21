--!strict
--[=[
	Builds safe replicated projections from private profile data.

	@class PlayerDataProjectionUtils
]=]

local require = require(script.Parent.loader).load(script)

local PlayerDataPathUtils = require("PlayerDataPathUtils")
local PlayerDataTableUtils = require("PlayerDataTableUtils")

local PlayerDataProjectionUtils = {}

type NormalizedPath = PlayerDataPathUtils.NormalizedPath
type DiffOperation = PlayerDataTableUtils.DiffOperation

function PlayerDataProjectionUtils.project(data: any, ownerPaths: { NormalizedPath }): any
	local projection = {}

	for _, path in ownerPaths do
		local value = PlayerDataPathUtils.get(data, path)
		if value ~= nil then
			PlayerDataPathUtils.set(projection, path, PlayerDataTableUtils.deepClone(value))
		end
	end

	return projection
end

function PlayerDataProjectionUtils.diff(oldData: any, newData: any, ownerPaths: { NormalizedPath }): { DiffOperation }
	local oldProjection = PlayerDataProjectionUtils.project(oldData, ownerPaths)
	local newProjection = PlayerDataProjectionUtils.project(newData, ownerPaths)
	local operations = PlayerDataTableUtils.diff(oldProjection, newProjection)
	local filtered = {}

	for _, operation in operations do
		if #operation.Path > 0 then
			table.insert(filtered, operation)
		end
	end

	return filtered
end

return PlayerDataProjectionUtils
