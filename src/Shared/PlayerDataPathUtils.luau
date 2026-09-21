--!strict
--[=[
	Path normalization and table traversal helpers.

	@class PlayerDataPathUtils
]=]

local PlayerDataPathUtils = {}

export type NormalizedPath = { string }

local function assertSegment(segment: any, index: number): string
	assert(typeof(segment) == "string", `Path segment #{index} must be a string`)
	assert(segment ~= "", `Path segment #{index} must not be empty`)
	assert(string.find(segment, ".", 1, true) == nil, `Path segment #{index} must not contain "."`)

	return segment
end

function PlayerDataPathUtils.normalize(path: any): NormalizedPath
	if path == nil or path == "" then
		return {}
	end

	if typeof(path) == "string" then
		local normalized = {}
		for segment in string.gmatch(path, "[^%.]+") do
			table.insert(normalized, assertSegment(segment, #normalized + 1))
		end

		assert(#normalized > 0, "Path must not be empty")
		assert(table.concat(normalized, ".") == path, `Invalid path: {path}`)

		return normalized
	end

	if typeof(path) == "table" then
		local normalized = table.create(#path)
		for index, segment in path do
			assert(typeof(index) == "number", "Path arrays must not contain dictionary keys")
			normalized[index] = assertSegment(segment, index)
		end

		return normalized
	end

	error(`Path must be a string or array, got {typeof(path)}`, 2)
end

function PlayerDataPathUtils.toString(path: NormalizedPath): string
	return table.concat(path, ".")
end

function PlayerDataPathUtils.equals(left: NormalizedPath, right: NormalizedPath): boolean
	if #left ~= #right then
		return false
	end

	for index, segment in left do
		if right[index] ~= segment then
			return false
		end
	end

	return true
end

function PlayerDataPathUtils.isPrefix(prefix: NormalizedPath, path: NormalizedPath): boolean
	if #prefix > #path then
		return false
	end

	for index, segment in prefix do
		if path[index] ~= segment then
			return false
		end
	end

	return true
end

function PlayerDataPathUtils.overlaps(left: NormalizedPath, right: NormalizedPath): boolean
	return PlayerDataPathUtils.isPrefix(left, right) or PlayerDataPathUtils.isPrefix(right, left)
end

function PlayerDataPathUtils.get(root: any, path: NormalizedPath): any
	local cursor = root

	for _, segment in path do
		if typeof(cursor) ~= "table" then
			return nil
		end

		cursor = cursor[segment]
	end

	return cursor
end

function PlayerDataPathUtils.set(root: any, path: NormalizedPath, value: any)
	assert(#path > 0, "Set requires a non-root path")

	local cursor = root
	for index = 1, #path - 1 do
		local segment = path[index]
		local nextCursor = cursor[segment]

		if typeof(nextCursor) ~= "table" then
			nextCursor = {}
			cursor[segment] = nextCursor
		end

		cursor = nextCursor
	end

	cursor[path[#path]] = value
end

function PlayerDataPathUtils.delete(root: any, path: NormalizedPath)
	assert(#path > 0, "Delete requires a non-root path")

	local cursor = root
	for index = 1, #path - 1 do
		cursor = if typeof(cursor) == "table" then cursor[path[index]] else nil
		if typeof(cursor) ~= "table" then
			return
		end
	end

	cursor[path[#path]] = nil
end

function PlayerDataPathUtils.parent(path: NormalizedPath): NormalizedPath
	local parentPath = table.create(math.max(#path - 1, 0))

	for index = 1, #path - 1 do
		parentPath[index] = path[index]
	end

	return parentPath
end

function PlayerDataPathUtils.last(path: NormalizedPath): string?
	return path[#path]
end

return PlayerDataPathUtils
