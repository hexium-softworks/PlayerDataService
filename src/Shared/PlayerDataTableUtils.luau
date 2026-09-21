--!strict
--[=[
	Table cloning, freezing, equality, and diff helpers.

	@class PlayerDataTableUtils
]=]

local require = require(script.Parent.loader).load(script)

local PlayerDataPathUtils = require("PlayerDataPathUtils")

local PlayerDataTableUtils = {}

type NormalizedPath = PlayerDataPathUtils.NormalizedPath

export type DiffOperation = {
	Operation: "Set" | "Delete",
	Path: NormalizedPath,
	Value: any?,
}

function PlayerDataTableUtils.deepClone(value: any, seen: { [table]: table }?): any
	if typeof(value) ~= "table" then
		return value
	end

	local visited = seen or {}
	if visited[value] then
		return visited[value]
	end

	local copy = {}
	visited[value] = copy

	for key, child in value do
		copy[PlayerDataTableUtils.deepClone(key, visited)] = PlayerDataTableUtils.deepClone(child, visited)
	end

	return copy
end

function PlayerDataTableUtils.deepEquals(left: any, right: any, seen: { [table]: { [table]: boolean } }?): boolean
	if left == right then
		return true
	end

	if typeof(left) ~= typeof(right) then
		return false
	end

	if typeof(left) ~= "table" then
		return false
	end

	local visited = seen or {}
	visited[left] = visited[left] or {}
	if visited[left][right] then
		return true
	end
	visited[left][right] = true

	for key, leftValue in left do
		if not PlayerDataTableUtils.deepEquals(leftValue, right[key], visited) then
			return false
		end
	end

	for key in right do
		if left[key] == nil then
			return false
		end
	end

	return true
end

function PlayerDataTableUtils.deepFreeze(value: any, seen: { [table]: boolean }?): any
	if typeof(value) ~= "table" then
		return value
	end

	local visited = seen or {}
	if visited[value] then
		return value
	end
	visited[value] = true

	for _, child in value do
		PlayerDataTableUtils.deepFreeze(child, visited)
	end

	table.freeze(value)
	return value
end

function PlayerDataTableUtils.readonlySnapshot(value: any): any
	return PlayerDataTableUtils.deepFreeze(PlayerDataTableUtils.deepClone(value))
end

function PlayerDataTableUtils.isArray(value: any): boolean
	if typeof(value) ~= "table" then
		return false
	end

	local count = 0
	for key in value do
		if typeof(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end

	for index = 1, count do
		if value[index] == nil then
			return false
		end
	end

	return count > 0
end

function PlayerDataTableUtils.diff(oldValue: any, newValue: any, basePath: NormalizedPath?): { DiffOperation }
	local operations = {}

	local function append(path: NormalizedPath, segment: string): NormalizedPath
		local nextPath = table.clone(path)
		table.insert(nextPath, segment)
		return nextPath
	end

	local function visit(left: any, right: any, path: NormalizedPath)
		if PlayerDataTableUtils.deepEquals(left, right) then
			return
		end

		if
			typeof(left) ~= "table"
			or typeof(right) ~= "table"
			or PlayerDataTableUtils.isArray(left)
			or PlayerDataTableUtils.isArray(right)
		then
			if right == nil then
				table.insert(operations, {
					Operation = "Delete",
					Path = table.clone(path),
				})
			else
				table.insert(operations, {
					Operation = "Set",
					Path = table.clone(path),
					Value = PlayerDataTableUtils.deepClone(right),
				})
			end
			return
		end

		local visitedKeys = {}
		for key, leftChild in left do
			if typeof(key) == "string" then
				visitedKeys[key] = true
				visit(leftChild, right[key], append(path, key))
			end
		end

		for key, rightChild in right do
			if typeof(key) == "string" and not visitedKeys[key] then
				visit(nil, rightChild, append(path, key))
			end
		end
	end

	visit(oldValue, newValue, basePath or {})
	return operations
end

return PlayerDataTableUtils
