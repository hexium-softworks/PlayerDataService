--!strict
--[=[
	Builds safe accessor trees for server profiles and client replicated data.

	@class PlayerDataAccessorBuilder
]=]

local require = require(script.Parent.loader).load(script)

local PlayerDataPathUtils = require("PlayerDataPathUtils")

local PlayerDataAccessorBuilder = {}

type NormalizedPath = PlayerDataPathUtils.NormalizedPath

local ACCESSOR_METHODS = {
	Get = true,
	GetSnapshot = true,
	Set = true,
	Update = true,
	Increment = true,
	Delete = true,
	Observe = true,
	ObserveSnapshot = true,
	ObserveSelector = true,
	Batch = true,
	Mutate = true,
	PromiseSave = true,
	Destroy = true,
	IsActive = true,
	GetPlayer = true,
}

local function splitPath(pathString: string): NormalizedPath
	if pathString == "" then
		return {}
	end

	return PlayerDataPathUtils.normalize(pathString)
end

local function pathToString(path: NormalizedPath): string
	return PlayerDataPathUtils.toString(path)
end

local function makeServerNode(profile: any, path: NormalizedPath): any
	local node = {}

	function node:Get()
		return profile:Get(path)
	end

	function node:Set(value: any)
		return profile:Set(path, value)
	end

	function node:Update(callback: (any) -> any)
		return profile:Update(path, callback)
	end

	function node:Increment(amount: number?)
		return profile:Increment(path, amount)
	end

	function node:Delete()
		return profile:Delete(path)
	end

	function node:Observe()
		return profile:Observe(path)
	end

	return node
end

local function makeClientNode(client: any, path: NormalizedPath): any
	local node = {}
	local children = {}

	function node:Get()
		return client:Get(path)
	end

	function node:Observe(callback: ((any) -> ())?)
		local observable = client:Observe(path)
		if callback then
			return observable:Subscribe(callback)
		end

		return observable
	end

	setmetatable(node, {
		__index = function(_table, key)
			if typeof(key) ~= "string" or ACCESSOR_METHODS[key] then
				return nil
			end

			local child = children[key]
			if child == nil then
				local childPath = table.clone(path)
				table.insert(childPath, key)
				child = makeClientNode(client, childPath)
				children[key] = child
			end

			return child
		end,
	})

	return node
end

function PlayerDataAccessorBuilder.createServerAccessors(profile: any, schemaInfo: any): any
	local nodes = {
		[""] = makeServerNode(profile, {}),
	}

	local pathStrings = {}
	for pathString in schemaInfo.SchemaPathSet do
		if pathString ~= "" then
			table.insert(pathStrings, pathString)
		end
	end

	table.sort(pathStrings, function(left, right)
		return #left < #right
	end)

	for _, pathString in pathStrings do
		local path = splitPath(pathString)
		local node = makeServerNode(profile, path)
		nodes[pathString] = node

		local parentPath = PlayerDataPathUtils.parent(path)
		local parent = nodes[pathToString(parentPath)]
		if parent then
			local key = PlayerDataPathUtils.last(path)
			if key and not ACCESSOR_METHODS[key] then
				parent[key] = node
			end
		end
	end

	return nodes[""]
end

function PlayerDataAccessorBuilder.createClientAccessors(client: any, schemaInfo: any?): any
	if schemaInfo == nil then
		return makeClientNode(client, {})
	end

	local nodes = {
		[""] = makeClientNode(client, {}),
	}

	local pathSet = {}
	for _, ownerPath in schemaInfo.OwnerReplicationPaths do
		for index = 1, #ownerPath do
			local prefix = table.create(index)
			for pathIndex = 1, index do
				prefix[pathIndex] = ownerPath[pathIndex]
			end
			pathSet[pathToString(prefix)] = true
		end
	end

	local pathStrings = {}
	for pathString in pathSet do
		table.insert(pathStrings, pathString)
	end
	table.sort(pathStrings, function(left, right)
		return #left < #right
	end)

	for _, pathString in pathStrings do
		local path = splitPath(pathString)
		local node = makeClientNode(client, path)
		nodes[pathString] = node

		local parent = nodes[pathToString(PlayerDataPathUtils.parent(path))]
		if parent then
			local key = PlayerDataPathUtils.last(path)
			if key and not ACCESSOR_METHODS[key] then
				parent[key] = node
			end
		end
	end

	return nodes[""]
end

function PlayerDataAccessorBuilder.isReservedName(name: string): boolean
	return ACCESSOR_METHODS[name] == true
end

return PlayerDataAccessorBuilder
