--!strict
--[=[
	User-facing schema declaration helpers.

	@class PlayerDataSchema
]=]

local PlayerDataSchema = {}

local MARKER = "__PlayerDataSchemaKind"

export type FieldOptions = {
	Min: number?,
	Max: number?,
	MaxLength: number?,
}

local function tagged(kind: string, fields: any): any
	fields[MARKER] = kind
	return table.freeze(fields)
end

function PlayerDataSchema.define(config: any): any
	assert(typeof(config) == "table", "PlayerDataSchema.define expects a table")

	local schema = table.clone(config)
	schema[MARKER] = "Schema"
	return table.freeze(schema)
end

function PlayerDataSchema.Owner(value: any): any
	return tagged("Visibility", {
		Scope = "Owner",
		Value = value,
	})
end

function PlayerDataSchema.ServerOnly(value: any): any
	return tagged("Visibility", {
		Scope = "Server",
		Value = value,
	})
end

function PlayerDataSchema.Int(defaultValue: number, options: FieldOptions?): any
	return tagged("Declarator", {
		Type = "Int",
		Default = defaultValue,
		Options = options or {},
	})
end

function PlayerDataSchema.Number(defaultValue: number, options: FieldOptions?): any
	return tagged("Declarator", {
		Type = "Number",
		Default = defaultValue,
		Options = options or {},
	})
end

function PlayerDataSchema.String(defaultValue: string, options: FieldOptions?): any
	return tagged("Declarator", {
		Type = "String",
		Default = defaultValue,
		Options = options or {},
	})
end

function PlayerDataSchema.Boolean(defaultValue: boolean): any
	return tagged("Declarator", {
		Type = "Boolean",
		Default = defaultValue,
		Options = {},
	})
end

function PlayerDataSchema.Enum(defaultValue: string, members: { string }): any
	return tagged("Declarator", {
		Type = "Enum",
		Default = defaultValue,
		Members = table.clone(members),
		Options = {},
	})
end

function PlayerDataSchema.Optional(inner: any): any
	return tagged("Optional", {
		Inner = inner,
	})
end

function PlayerDataSchema.Dynamic(factory: () -> any): any
	assert(typeof(factory) == "function", "Dynamic expects a factory function")

	return tagged("Dynamic", {
		Factory = factory,
	})
end

function PlayerDataSchema.Check(defaultValue: any, checker: (any) -> (boolean, string?)): any
	assert(typeof(checker) == "function", "Check expects a checker function")

	return tagged("Declarator", {
		Type = "Check",
		Default = defaultValue,
		Checker = checker,
		Options = {},
	})
end

function PlayerDataSchema._getKind(value: any): string?
	if typeof(value) ~= "table" then
		return nil
	end

	return value[MARKER]
end

return PlayerDataSchema
