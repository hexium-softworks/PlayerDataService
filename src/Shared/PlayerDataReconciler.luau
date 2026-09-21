--!strict
--[=[
	Reconciles loaded profile data against a schema template.

	@class PlayerDataReconciler
]=]

local require = require(script.Parent.loader).load(script)

local PlayerDataPathUtils = require("PlayerDataPathUtils")
local PlayerDataTableUtils = require("PlayerDataTableUtils")

local PlayerDataReconciler = {}

type NormalizedPath = PlayerDataPathUtils.NormalizedPath

export type ReconcileIssue = {
	Path: string,
	Expected: string,
	Actual: string,
}

export type ReconcileResult = {
	Data: any,
	Issues: { ReconcileIssue },
}

local function pathToString(path: NormalizedPath): string
	local pathString = PlayerDataPathUtils.toString(path)
	return if pathString == "" then "<root>" else pathString
end

function PlayerDataReconciler.reconcile(savedData: any, template: any): ReconcileResult
	local issues = {}

	local function visit(saved: any, defaultValue: any, path: NormalizedPath): any
		if saved == nil then
			return PlayerDataTableUtils.deepClone(defaultValue)
		end

		local savedType = typeof(saved)
		local defaultType = typeof(defaultValue)
		if savedType ~= defaultType then
			table.insert(issues, {
				Path = pathToString(path),
				Expected = defaultType,
				Actual = savedType,
			})
			return PlayerDataTableUtils.deepClone(defaultValue)
		end

		if defaultType ~= "table" then
			return saved
		end

		if PlayerDataTableUtils.isArray(defaultValue) then
			return PlayerDataTableUtils.deepClone(saved)
		end

		local result = PlayerDataTableUtils.deepClone(saved)
		for key, childDefault in defaultValue do
			if typeof(key) == "string" then
				local childPath = table.clone(path)
				table.insert(childPath, key)
				result[key] = visit(result[key], childDefault, childPath)
			end
		end

		return result
	end

	return {
		Data = visit(savedData, template, {}),
		Issues = issues,
	}
end

return PlayerDataReconciler
