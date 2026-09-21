--!strict
--[=[
	Validation helpers for datastore-safe profile values.

	@class PlayerDataValueValidator
]=]

local require = require(script.Parent.loader).load(script)

local PlayerDataPathUtils = require("PlayerDataPathUtils")
local PlayerDataTableUtils = require("PlayerDataTableUtils")

local PlayerDataValueValidator = {}

type NormalizedPath = PlayerDataPathUtils.NormalizedPath

export type ValidationResult = {
	Ok: boolean,
	Message: string?,
}

local DEFAULT_LIMITS = {
	MaxDepth = 32,
	MaxNodes = 10000,
	MaxStringLength = 400000,
}

local function pathToString(path: NormalizedPath): string
	local pathString = PlayerDataPathUtils.toString(path)
	return if pathString == "" then "<root>" else pathString
end

local function isFinite(numberValue: number): boolean
	return numberValue == numberValue and numberValue > -math.huge and numberValue < math.huge
end

local function fail(message: string): ValidationResult
	return {
		Ok = false,
		Message = message,
	}
end

local function ok(): ValidationResult
	return {
		Ok = true,
	}
end

function PlayerDataValueValidator.isValid(value: any): boolean
	return PlayerDataValueValidator.validateValue(value).Ok
end

function PlayerDataValueValidator.validateValue(value: any, path: NormalizedPath?, limits: any?): ValidationResult
	local resolvedLimits = limits or DEFAULT_LIMITS
	local seen = {}
	local nodeCount = 0

	local function visit(item: any, itemPath: NormalizedPath, depth: number): ValidationResult
		local itemType = typeof(item)

		if item == nil or itemType == "boolean" then
			return ok()
		elseif itemType == "number" then
			if not isFinite(item) then
				return fail(`Number at {pathToString(itemPath)} must be finite`)
			end
			return ok()
		elseif itemType == "string" then
			if #item > resolvedLimits.MaxStringLength then
				return fail(`String at {pathToString(itemPath)} is too long`)
			end
			return ok()
		elseif itemType ~= "table" then
			return fail(`Unsupported datastore value type at {pathToString(itemPath)}: {itemType}`)
		end

		if seen[item] then
			return fail(`Table at {pathToString(itemPath)} contains a cycle`)
		end

		if depth > resolvedLimits.MaxDepth then
			return fail(`Table at {pathToString(itemPath)} is too deep`)
		end

		seen[item] = true
		nodeCount += 1
		if nodeCount > resolvedLimits.MaxNodes then
			return fail("Profile contains too many table nodes")
		end

		for key, child in item do
			local keyType = typeof(key)
			if keyType ~= "string" and keyType ~= "number" then
				return fail(`Unsupported table key type at {pathToString(itemPath)}: {keyType}`)
			end

			if keyType == "number" and (not isFinite(key) or key % 1 ~= 0) then
				return fail(`Numeric key at {pathToString(itemPath)} must be a finite integer`)
			end

			if keyType == "string" and key == "" then
				return fail(`String key at {pathToString(itemPath)} must not be empty`)
			end

			local childPath = table.clone(itemPath)
			table.insert(childPath, tostring(key))
			local result = visit(child, childPath, depth + 1)
			if not result.Ok then
				return result
			end
		end

		seen[item] = nil
		return ok()
	end

	return visit(value, path or {}, 1)
end

function PlayerDataValueValidator.validateShape(
	value: any,
	template: any,
	path: NormalizedPath?,
	allowUnknownFields: boolean?
): ValidationResult
	local valueResult = PlayerDataValueValidator.validateValue(value, path)
	if not valueResult.Ok then
		return valueResult
	end

	local itemPath = path or {}
	local valueType = typeof(value)
	local templateType = typeof(template)

	if template == nil then
		return fail(`Unknown schema path: {pathToString(itemPath)}`)
	end

	if templateType ~= valueType then
		return fail(`Expected {templateType} at {pathToString(itemPath)}, got {valueType}`)
	end

	if templateType ~= "table" then
		return ok()
	end

	if PlayerDataTableUtils.isArray(template) then
		if not PlayerDataTableUtils.isArray(value) and next(value) ~= nil then
			return fail(`Expected array-like table at {pathToString(itemPath)}`)
		end

		return ok()
	end

	for key, childTemplate in template do
		if typeof(key) == "string" and value[key] == nil then
			local childPath = table.clone(itemPath)
			table.insert(childPath, key)
			return fail(`Missing required schema field at {pathToString(childPath)}`)
		end

		if childTemplate == nil then
			return fail(`Invalid nil template field at {pathToString(itemPath)}.{tostring(key)}`)
		end
	end

	for key, child in value do
		if typeof(key) == "string" then
			local childTemplate = template[key]
			if childTemplate == nil then
				if not allowUnknownFields then
					return fail(`Unknown schema field at {pathToString(itemPath)}.{key}`)
				end

				continue
			end

			local childPath = table.clone(itemPath)
			table.insert(childPath, key)
			local result = PlayerDataValueValidator.validateShape(child, childTemplate, childPath, allowUnknownFields)
			if not result.Ok then
				return result
			end
		end
	end

	return ok()
end

return PlayerDataValueValidator
