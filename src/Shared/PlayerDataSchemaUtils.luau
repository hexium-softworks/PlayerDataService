--!strict
--[=[
	Schema normalization and validation.

	@class PlayerDataSchemaUtils
]=]

local require = require(script.Parent.loader).load(script)

local PlayerDataAccessorBuilder = require("PlayerDataAccessorBuilder")
local PlayerDataPathUtils = require("PlayerDataPathUtils")
local PlayerDataSchema = require("PlayerDataSchema")
local PlayerDataTableUtils = require("PlayerDataTableUtils")
local PlayerDataValueValidator = require("PlayerDataValueValidator")

local PlayerDataSchemaUtils = {}

type NormalizedPath = PlayerDataPathUtils.NormalizedPath

export type SchemaInfo = {
	Version: number,
	Template: any,
	Migrations: { [number]: (any) -> any },
	Validators: { [string]: (any, any?) -> any },
	OwnerReplicationPaths: { NormalizedPath },
	SchemaPathSet: { [string]: boolean },
	OptionalPathSet: { [string]: boolean },
	DynamicDefaultFactories: { [string]: () -> any },
	DefaultByPath: { [string]: any },
}

local function assertValid(condition: boolean, message: string)
	if not condition then
		error(message, 3)
	end
end

local function isFinite(numberValue: number): boolean
	return numberValue == numberValue and numberValue > -math.huge and numberValue < math.huge
end

local function pathToString(path: NormalizedPath): string
	return PlayerDataPathUtils.toString(path)
end

local function displayPath(path: NormalizedPath): string
	local pathString = pathToString(path)
	return if pathString == "" then "<root>" else pathString
end

local function addOwnerPath(ownerPaths: { NormalizedPath }, seenOwnerPaths: { [string]: boolean }, path: NormalizedPath)
	local pathString = pathToString(path)
	if pathString == "" or seenOwnerPaths[pathString] then
		return
	end

	seenOwnerPaths[pathString] = true
	table.insert(ownerPaths, table.clone(path))
end

local function addPath(schemaPathSet: { [string]: boolean }, path: NormalizedPath)
	schemaPathSet[pathToString(path)] = true
end

local function makeShapeValidator(defaultValue: any, path: NormalizedPath)
	local pathCopy = table.clone(path)
	local defaultCopy = PlayerDataTableUtils.deepClone(defaultValue)

	return function(value: any)
		local result = PlayerDataValueValidator.validateShape(value, defaultCopy, pathCopy, true)
		return result.Ok, result.Message
	end
end

local function validateDeclaratorDefault(kind: string, defaultValue: any, options: any, members: { string }?)
	if kind == "Int" then
		assertValid(
			typeof(defaultValue) == "number" and isFinite(defaultValue) and defaultValue % 1 == 0,
			"Int default must be a finite integer"
		)
	elseif kind == "Number" then
		assertValid(typeof(defaultValue) == "number" and isFinite(defaultValue), "Number default must be finite")
	elseif kind == "String" then
		assertValid(typeof(defaultValue) == "string", "String default must be a string")
	elseif kind == "Boolean" then
		assertValid(typeof(defaultValue) == "boolean", "Boolean default must be a boolean")
	elseif kind == "Enum" then
		assertValid(typeof(defaultValue) == "string", "Enum default must be a string")
		assertValid(typeof(members) == "table" and #members > 0, "Enum requires at least one member")

		local found = false
		for _, member in members :: { string } do
			assertValid(typeof(member) == "string" and member ~= "", "Enum members must be non-empty strings")
			if member == defaultValue then
				found = true
			end
		end
		assertValid(found, "Enum default must be one of its members")
	elseif kind == "Check" then
		return
	else
		error(`Unsupported player data declarator type: {kind}`, 3)
	end

	if options then
		local supportsNumericBounds = kind == "Int" or kind == "Number"
		local supportsMaxLength = kind == "String"

		if options.Min ~= nil then
			assertValid(supportsNumericBounds, "Min is only supported by Int and Number fields")
			assertValid(typeof(options.Min) == "number" and isFinite(options.Min), "Min must be finite")
		end
		if options.Max ~= nil then
			assertValid(supportsNumericBounds, "Max is only supported by Int and Number fields")
			assertValid(typeof(options.Max) == "number" and isFinite(options.Max), "Max must be finite")
		end
		if options.Min ~= nil and options.Max ~= nil then
			assertValid(options.Min <= options.Max, "Min cannot exceed Max")
		end
		if options.MaxLength ~= nil then
			assertValid(supportsMaxLength, "MaxLength is only supported by String fields")
			assertValid(
				typeof(options.MaxLength) == "number" and options.MaxLength >= 0 and options.MaxLength % 1 == 0,
				"MaxLength must be a non-negative integer"
			)
		end
	end
end

local function makeDeclaratorValidator(declarator: any, path: NormalizedPath)
	local kind = declarator.Type
	local options = declarator.Options or {}
	local members = declarator.Members
	local checker = declarator.Checker
	local pathString = displayPath(path)

	return function(value: any)
		if kind == "Int" then
			if typeof(value) ~= "number" or not isFinite(value) or value % 1 ~= 0 then
				return false, `Expected integer at {pathString}`
			end
		elseif kind == "Number" then
			if typeof(value) ~= "number" or not isFinite(value) then
				return false, `Expected finite number at {pathString}`
			end
		elseif kind == "String" then
			if typeof(value) ~= "string" then
				return false, `Expected string at {pathString}`
			end
		elseif kind == "Boolean" then
			if typeof(value) ~= "boolean" then
				return false, `Expected boolean at {pathString}`
			end
		elseif kind == "Enum" then
			if typeof(value) ~= "string" then
				return false, `Expected enum string at {pathString}`
			end

			local found = false
			for _, member in members do
				if value == member then
					found = true
					break
				end
			end
			if not found then
				return false, `Unexpected enum value at {pathString}: {value}`
			end
		elseif kind == "Check" then
			local ok, result, message = pcall(checker, value)
			if not ok then
				return false, `Checker failed at {pathString}: {tostring(result)}`
			end
			if result ~= true then
				return false, message or `Checker rejected value at {pathString}`
			end
			return true
		end

		if (kind == "Int" or kind == "Number") and options.Min ~= nil and value < options.Min then
			return false, `Value at {pathString} is below minimum`
		end
		if (kind == "Int" or kind == "Number") and options.Max ~= nil and value > options.Max then
			return false, `Value at {pathString} is above maximum`
		end
		if kind == "String" and options.MaxLength ~= nil and #value > options.MaxLength then
			return false, `String at {pathString} is too long`
		end

		return true
	end
end

local function validateAccessorPath(path: NormalizedPath)
	for _, segment in path do
		assertValid(
			not PlayerDataAccessorBuilder.isReservedName(segment),
			`Player data field name "{segment}" collides with accessor API methods`
		)
	end
end

local function compileTemplate(template: any)
	local schemaPathSet = {
		[""] = true,
	}
	local optionalPathSet = {}
	local dynamicDefaultFactories = {}
	local defaultByPath = {}
	local validators = {}
	local ownerReplicationPaths = {}
	local seenOwnerPaths = {}
	local seenTables = {}

	local function compile(
		value: any,
		path: NormalizedPath,
		visibility: "Owner" | "Server",
		includeInTemplate: boolean
	): (any, boolean)
		validateAccessorPath(path)

		local kind = PlayerDataSchema._getKind(value)
		if kind == "Visibility" then
			local scope = if value.Scope == "Owner" then "Owner" else "Server"
			return compile(value.Value, path, scope, includeInTemplate)
		elseif kind == "Optional" then
			assertValid(#path > 0, "Optional cannot wrap the root template")
			assertValid(PlayerDataSchema._getKind(value.Inner) ~= "Dynamic", "Optional cannot wrap Dynamic")

			local defaultValue = compile(value.Inner, path, visibility, false)
			assertValid(typeof(defaultValue) ~= "table", "Optional only supports leaf fields")
			local pathString = pathToString(path)
			optionalPathSet[pathString] = true
			schemaPathSet[pathString] = true
			defaultByPath[pathString] = PlayerDataTableUtils.deepClone(defaultValue)
			validators[pathString] = validators[pathString] or makeShapeValidator(defaultValue, path)
			if visibility == "Owner" then
				addOwnerPath(ownerReplicationPaths, seenOwnerPaths, path)
			end

			return nil, false
		elseif kind == "Dynamic" then
			local ok, defaultValueOrError = pcall(value.Factory)
			assertValid(ok, `Dynamic default failed at {displayPath(path)}: {tostring(defaultValueOrError)}`)

			local result = PlayerDataValueValidator.validateValue(defaultValueOrError, path)
			assertValid(result.Ok, result.Message or `Dynamic default is invalid at {displayPath(path)}`)

			local pathString = pathToString(path)
			dynamicDefaultFactories[pathString] = value.Factory
			local compiledValue = PlayerDataTableUtils.deepClone(defaultValueOrError)
			addPath(schemaPathSet, path)
			defaultByPath[pathString] = PlayerDataTableUtils.deepClone(compiledValue)
			if visibility == "Owner" then
				addOwnerPath(ownerReplicationPaths, seenOwnerPaths, path)
			end

			return compiledValue, includeInTemplate
		elseif kind == "Declarator" then
			validateDeclaratorDefault(value.Type, value.Default, value.Options, value.Members)

			local result = PlayerDataValueValidator.validateValue(value.Default, path)
			assertValid(result.Ok, result.Message or `Declarator default is invalid at {displayPath(path)}`)

			local defaultValue = PlayerDataTableUtils.deepClone(value.Default)
			local pathString = pathToString(path)
			local validator = makeDeclaratorValidator(value, path)
			local defaultOk, defaultMessage = validator(defaultValue)
			assertValid(defaultOk == true, defaultMessage or `Declarator default is invalid at {displayPath(path)}`)

			addPath(schemaPathSet, path)
			defaultByPath[pathString] = PlayerDataTableUtils.deepClone(defaultValue)
			validators[pathString] = validator
			if visibility == "Owner" then
				addOwnerPath(ownerReplicationPaths, seenOwnerPaths, path)
			end

			return defaultValue, includeInTemplate
		end

		local valueType = typeof(value)
		if valueType ~= "table" then
			local result = PlayerDataValueValidator.validateValue(value, path)
			assertValid(result.Ok, result.Message or `Default value is invalid at {displayPath(path)}`)

			addPath(schemaPathSet, path)
			defaultByPath[pathToString(path)] = value
			if visibility == "Owner" then
				addOwnerPath(ownerReplicationPaths, seenOwnerPaths, path)
			end
			return value, includeInTemplate
		end

		assertValid(not seenTables[value], `Template contains a cycle at {displayPath(path)}`)
		seenTables[value] = true

		addPath(schemaPathSet, path)
		if PlayerDataTableUtils.isArray(value) then
			local clone = PlayerDataTableUtils.deepClone(value)
			defaultByPath[pathToString(path)] = clone
			if visibility == "Owner" then
				addOwnerPath(ownerReplicationPaths, seenOwnerPaths, path)
			end
			seenTables[value] = nil
			return clone, includeInTemplate
		end

		local compiled = {}
		local childCount = 0
		for key, child in value do
			assertValid(typeof(key) == "string", "Template dictionary keys must be strings")
			assertValid(key ~= "Metadata" or #path > 0, "Template may not reserve root Metadata")

			local childPath = table.clone(path)
			table.insert(childPath, key)
			local childValue, childIncluded = compile(child, childPath, visibility, true)
			if childIncluded then
				compiled[key] = childValue
			end
			childCount += 1
		end

		defaultByPath[pathToString(path)] = PlayerDataTableUtils.deepClone(compiled)
		if childCount == 0 and visibility == "Owner" and #path > 0 then
			addOwnerPath(ownerReplicationPaths, seenOwnerPaths, path)
		end

		seenTables[value] = nil
		return compiled, includeInTemplate
	end

	local compiledTemplate = compile(template, {}, "Server", true)

	return compiledTemplate,
		{
			SchemaPathSet = schemaPathSet,
			OptionalPathSet = optionalPathSet,
			DynamicDefaultFactories = dynamicDefaultFactories,
			DefaultByPath = defaultByPath,
			Validators = validators,
			OwnerReplicationPaths = ownerReplicationPaths,
		}
end

local function normalizeReplicationPaths(
	schema: any,
	schemaPathSet: { [string]: boolean },
	ownerPaths: { NormalizedPath }
)
	local replication = schema.Replication
	if replication == nil or replication.Owner == nil then
		return
	end

	assertValid(typeof(replication) == "table", "Replication must be a table")
	assertValid(typeof(replication.Owner) == "table", "Replication.Owner must be an array of paths")

	local seenPaths = {}
	for _, existingPath in ownerPaths do
		seenPaths[pathToString(existingPath)] = true
	end

	for _, path in replication.Owner do
		local normalized = PlayerDataPathUtils.normalize(path)
		local pathString = pathToString(normalized)

		assertValid(pathString ~= "", "Replication paths must not target the root")
		assertValid(not seenPaths[pathString], `Duplicate replication path: {pathString}`)
		assertValid(schemaPathSet[pathString] == true, `Replication path does not exist in template: {pathString}`)

		seenPaths[pathString] = true
		table.insert(ownerPaths, normalized)
	end
end

local function validateMigrations(schema: any): { [number]: (any) -> any }
	local migrations = {}

	if schema.Migrations == nil then
		return migrations
	end

	assertValid(typeof(schema.Migrations) == "table", "Migrations must be a table")
	for version, migration in schema.Migrations do
		assertValid(
			typeof(version) == "number" and version % 1 == 0 and version >= 1,
			"Migration indexes must be positive integers"
		)
		assertValid(version <= schema.Version, "Migration index cannot exceed schema version")
		assertValid(typeof(migration) == "function", `Migration {version} must be a function`)
		migrations[version] = migration
	end

	return migrations
end

local function validateValidators(
	schema: any,
	schemaPathSet: { [string]: boolean },
	validators: { [string]: (any, any?) -> any }
)
	if schema.Validators == nil then
		return
	end

	assertValid(typeof(schema.Validators) == "table", "Validators must be a table")
	for path, validator in schema.Validators do
		assertValid(typeof(path) == "string", "Validator keys must be string paths")
		assertValid(schemaPathSet[path] == true, `Validator path does not exist in template: {path}`)
		assertValid(typeof(validator) == "function", `Validator for {path} must be a function`)
		validators[path] = validator
	end
end

function PlayerDataSchemaUtils.normalize(schema: any): SchemaInfo
	assertValid(typeof(schema) == "table", "Player data schema must be a table")
	assertValid(
		typeof(schema.Version) == "number" and schema.Version % 1 == 0 and schema.Version >= 1,
		"Schema Version must be a positive integer"
	)
	assertValid(schema.Template ~= nil, "Schema Template is required")
	assertValid(typeof(schema.Template) == "table", "Schema Template must be a table")

	local template, compiled = compileTemplate(schema.Template)
	local migrations = validateMigrations(schema)
	validateValidators(schema, compiled.SchemaPathSet, compiled.Validators)
	normalizeReplicationPaths(schema, compiled.SchemaPathSet, compiled.OwnerReplicationPaths)

	return {
		Version = schema.Version,
		Template = template,
		Migrations = migrations,
		Validators = compiled.Validators,
		OwnerReplicationPaths = compiled.OwnerReplicationPaths,
		SchemaPathSet = compiled.SchemaPathSet,
		OptionalPathSet = compiled.OptionalPathSet,
		DynamicDefaultFactories = compiled.DynamicDefaultFactories,
		DefaultByPath = compiled.DefaultByPath,
	}
end

function PlayerDataSchemaUtils.createDefaultData(schemaInfo: SchemaInfo): any
	local data = PlayerDataTableUtils.deepClone(schemaInfo.Template)

	for pathString, factory in schemaInfo.DynamicDefaultFactories do
		local path = PlayerDataPathUtils.normalize(pathString)
		local value = factory()
		local result = PlayerDataValueValidator.validateValue(value, path)
		assert(result.Ok, result.Message or `Dynamic default is invalid at {displayPath(path)}`)
		PlayerDataPathUtils.set(data, path, PlayerDataTableUtils.deepClone(value))
	end

	return data
end

function PlayerDataSchemaUtils.applyMissingDynamicDefaults(schemaInfo: SchemaInfo, data: any, originalData: any)
	for pathString, factory in schemaInfo.DynamicDefaultFactories do
		local path = PlayerDataPathUtils.normalize(pathString)
		if PlayerDataPathUtils.get(originalData, path) == nil then
			local value = factory()
			local result = PlayerDataValueValidator.validateValue(value, path)
			assert(result.Ok, result.Message or `Dynamic default is invalid at {displayPath(path)}`)
			PlayerDataPathUtils.set(data, path, PlayerDataTableUtils.deepClone(value))
		end
	end
end

function PlayerDataSchemaUtils.getTemplateAtPath(schemaInfo: SchemaInfo, path: NormalizedPath): any
	local pathString = pathToString(path)
	if schemaInfo.DefaultByPath[pathString] ~= nil then
		return schemaInfo.DefaultByPath[pathString]
	end

	return PlayerDataPathUtils.get(schemaInfo.Template, path)
end

function PlayerDataSchemaUtils.assertKnownPath(schemaInfo: SchemaInfo, path: NormalizedPath)
	local pathString = pathToString(path)
	assert(schemaInfo.SchemaPathSet[pathString] == true, `Unknown player data path: {pathString}`)
end

function PlayerDataSchemaUtils.isOptionalPath(schemaInfo: SchemaInfo, path: NormalizedPath): boolean
	return schemaInfo.OptionalPathSet[pathToString(path)] == true
end

return PlayerDataSchemaUtils
