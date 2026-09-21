--!strict
--[=[
	Runs schema migrations in ascending order.

	@class PlayerDataMigrationRunner
]=]

local require = require(script.Parent.loader).load(script)

local PlayerDataTableUtils = require("PlayerDataTableUtils")

local PlayerDataMigrationRunner = {}

export type MigrationResult = {
	Data: any,
	Changed: boolean,
}

function PlayerDataMigrationRunner.run(
	data: any,
	storedVersion: number,
	targetVersion: number,
	migrations: { [number]: (any) -> any }
): MigrationResult
	assert(
		typeof(storedVersion) == "number" and storedVersion % 1 == 0 and storedVersion >= 0,
		"Stored schema version must be a non-negative integer"
	)
	assert(
		typeof(targetVersion) == "number" and targetVersion % 1 == 0 and targetVersion >= 1,
		"Target schema version must be a positive integer"
	)
	assert(storedVersion <= targetVersion, "Stored schema version is newer than target schema version")

	local draft = PlayerDataTableUtils.deepClone(data)
	local changed = false

	for version = storedVersion + 1, targetVersion do
		local migration = migrations[version]
		assert(migration ~= nil, `Missing player data migration for schema version {version}`)

		local migrated = migration(draft)
		if migrated ~= nil then
			draft = migrated
		end
		changed = true
	end

	return {
		Data = draft,
		Changed = changed,
	}
end

return PlayerDataMigrationRunner
