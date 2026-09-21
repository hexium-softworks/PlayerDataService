--!strict
--[=[
	Constants for PlayerDataService.

	@class PlayerDataServiceConstants
]=]

local require = require(script.Parent.loader).load(script)

local Table = require("Table")

export type PlayerDataServiceConstants = {
	DEFAULT_NAMESPACE: string,
	DATA_KEY: string,
	METADATA_KEY: string,
	SCHEMA_VERSION_KEY: string,
	REPLICATED_STATE_PREFIX: string,
}

return Table.readonly({
	DEFAULT_NAMESPACE = "Profile",
	DATA_KEY = "Data",
	METADATA_KEY = "Metadata",
	SCHEMA_VERSION_KEY = "SchemaVersion",
	REPLICATED_STATE_PREFIX = "PlayerData",
} :: PlayerDataServiceConstants)
