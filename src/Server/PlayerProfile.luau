--!strict
--[=[
	Active server-side profile object.

	@class PlayerProfile
]=]

local require = require(script.Parent.loader).load(script)

local Maid = require("Maid")
local Observable = require("Observable")
local PlayerDataAccessorBuilder = require("PlayerDataAccessorBuilder")
local PlayerDataPathUtils = require("PlayerDataPathUtils")
local PlayerDataSchemaUtils = require("PlayerDataSchemaUtils")
local PlayerDataTableUtils = require("PlayerDataTableUtils")
local PlayerDataValueValidator = require("PlayerDataValueValidator")
local Signal = require("Signal")

type NormalizedPath = PlayerDataPathUtils.NormalizedPath
type SchemaInfo = PlayerDataSchemaUtils.SchemaInfo
type DiffOperation = PlayerDataTableUtils.DiffOperation

export type PlayerProfile = typeof(setmetatable(
	{} :: {
		_player: Player,
		_rootDataStore: any,
		_dataStage: any,
		_data: any,
		_schemaInfo: SchemaInfo,
		_active: boolean,
		_committing: boolean,
		_maid: Maid.Maid,
		_changed: Signal.Signal<any>,
		_destroying: Signal.Signal<()>,
		_onChanged: ((any, any, { DiffOperation }) -> ())?,
		_onReleased: ((any) -> ())?,
		Data: any,
	},
	{} :: typeof({ __index = {} })
))

local PlayerProfile = {}
PlayerProfile.ClassName = "PlayerProfile"
PlayerProfile.__index = PlayerProfile

local function pathToString(path: NormalizedPath): string
	local pathString = PlayerDataPathUtils.toString(path)
	return if pathString == "" then "<root>" else pathString
end

function PlayerProfile.new(config: any): PlayerProfile
	assert(typeof(config) == "table", "PlayerProfile config must be a table")
	assert(config.Player ~= nil, "PlayerProfile requires Player")
	assert(config.RootDataStore ~= nil, "PlayerProfile requires RootDataStore")
	assert(config.DataStage ~= nil, "PlayerProfile requires DataStage")
	assert(config.SchemaInfo ~= nil, "PlayerProfile requires SchemaInfo")

	local self: PlayerProfile = setmetatable({} :: any, PlayerProfile)
	self._player = config.Player
	self._rootDataStore = config.RootDataStore
	self._dataStage = config.DataStage
	self._data = PlayerDataTableUtils.deepClone(config.Data or {})
	self._schemaInfo = config.SchemaInfo
	self._active = true
	self._committing = false
	self._maid = Maid.new()
	self._changed = self._maid:Add(Signal.new())
	self._destroying = self._maid:Add(Signal.new())
	self._onChanged = config.OnChanged
	self._onReleased = config.OnReleased
	self.Data = PlayerDataAccessorBuilder.createServerAccessors(self, self._schemaInfo)

	return self
end

function PlayerProfile:_assertActive()
	assert(self._active, "PlayerProfile is released")
end

function PlayerProfile:_normalizeKnownPath(path: any): NormalizedPath
	local normalized = PlayerDataPathUtils.normalize(path)
	assert(#normalized > 0, "Profile mutation requires a non-root path")
	PlayerDataSchemaUtils.assertKnownPath(self._schemaInfo, normalized)
	return normalized
end

function PlayerProfile:_validateValue(path: NormalizedPath, value: any)
	if value == nil and PlayerDataSchemaUtils.isOptionalPath(self._schemaInfo, path) then
		return
	end

	local template = PlayerDataSchemaUtils.getTemplateAtPath(self._schemaInfo, path)
	local result = PlayerDataValueValidator.validateShape(value, template, path, true)
	assert(result.Ok, result.Message or `Invalid player data value at {pathToString(path)}`)

	local pathString = PlayerDataPathUtils.toString(path)
	local validator = self._schemaInfo.Validators[pathString]
	if validator then
		local ok, message = validator(value, self._data)
		assert(ok == true, message or `Validator rejected player data value at {pathString}`)
	end
end

function PlayerProfile:_stageForParentPath(path: NormalizedPath): any
	local stage = self._dataStage
	for index = 1, #path - 1 do
		stage = stage:GetSubStore(path[index])
	end
	return stage
end

function PlayerProfile:_persistOperation(operation: DiffOperation)
	if #operation.Path == 0 then
		self._dataStage:Wipe()
		if typeof(operation.Value) == "table" then
			for key, value in operation.Value do
				self._dataStage:Store(key, PlayerDataTableUtils.deepClone(value))
			end
		end
		return
	end

	local stage = self:_stageForParentPath(operation.Path)
	local key = PlayerDataPathUtils.last(operation.Path)
	assert(key ~= nil, "Operation key is missing")

	if operation.Operation == "Delete" then
		stage:Delete(key)
	else
		stage:Store(key, PlayerDataTableUtils.deepClone(operation.Value))
	end
end

function PlayerProfile:_assertNoNewUnknownFields(draft: any, oldData: any, template: any, path: NormalizedPath)
	if typeof(draft) ~= "table" or typeof(template) ~= "table" or PlayerDataTableUtils.isArray(template) then
		return
	end

	for key, child in draft do
		if typeof(key) == "string" then
			local childTemplate = template[key]
			local childPath = table.clone(path)
			table.insert(childPath, key)

			local childPathString = PlayerDataPathUtils.toString(childPath)
			if
				childTemplate == nil
				and not self._schemaInfo.SchemaPathSet[childPathString]
				and (typeof(oldData) ~= "table" or oldData[key] == nil)
			then
				error(`Unknown player data path: {pathToString(childPath)}`, 3)
			elseif childTemplate ~= nil or self._schemaInfo.SchemaPathSet[childPathString] then
				local oldChild = if typeof(oldData) == "table" then oldData[key] else nil
				self:_assertNoNewUnknownFields(child, oldChild, childTemplate, childPath)
			end
		end
	end
end

function PlayerProfile:_commitDraft(draft: any)
	self:_assertActive()
	assert(not self._committing, "Nested PlayerProfile commits are not supported")

	local oldData = self._data
	self:_assertNoNewUnknownFields(draft, oldData, self._schemaInfo.Template, {})

	local rootResult = PlayerDataValueValidator.validateShape(draft, self._schemaInfo.Template, {}, true)
	assert(rootResult.Ok, rootResult.Message or "Invalid player profile data")

	local operations = PlayerDataTableUtils.diff(oldData, draft)
	if #operations == 0 then
		return
	end

	for _, operation in operations do
		local pathString = PlayerDataPathUtils.toString(operation.Path)
		assert(
			self._schemaInfo.SchemaPathSet[pathString] == true,
			`Cannot mutate unknown player data path: {pathString}`
		)

		if operation.Operation == "Delete" then
			assert(
				PlayerDataSchemaUtils.isOptionalPath(self._schemaInfo, operation.Path),
				`Cannot delete required schema field {pathString}`
			)
		else
			self:_validateValue(operation.Path, operation.Value)
		end
	end

	self._committing = true
	local ok, err = pcall(function()
		for _, operation in operations do
			self:_persistOperation(operation)
		end
	end)
	self._committing = false
	if not ok then
		error(err, 2)
	end

	self._data = PlayerDataTableUtils.deepClone(draft)

	local snapshot = self:GetSnapshot()
	self._changed:Fire(snapshot, operations)
	if self._onChanged then
		self._onChanged(oldData, self._data, operations)
	end
end

function PlayerProfile:GetPlayer(): Player
	return self._player
end

function PlayerProfile:IsActive(): boolean
	return self._active
end

function PlayerProfile:Get(path: any?): any
	self:_assertActive()

	local normalized = PlayerDataPathUtils.normalize(path)
	return PlayerDataTableUtils.deepClone(PlayerDataPathUtils.get(self._data, normalized))
end

function PlayerProfile:GetSnapshot(): any
	self:_assertActive()
	return PlayerDataTableUtils.readonlySnapshot(self._data)
end

function PlayerProfile:Set(path: any, value: any)
	self:_assertActive()

	local normalized = self:_normalizeKnownPath(path)
	if value == nil and PlayerDataSchemaUtils.isOptionalPath(self._schemaInfo, normalized) then
		self:Delete(normalized)
		return
	end

	self:_validateValue(normalized, value)

	local current = PlayerDataPathUtils.get(self._data, normalized)
	if PlayerDataTableUtils.deepEquals(current, value) then
		return
	end

	local draft = PlayerDataTableUtils.deepClone(self._data)
	PlayerDataPathUtils.set(draft, normalized, PlayerDataTableUtils.deepClone(value))
	self:_commitDraft(draft)
end

function PlayerProfile:Update(path: any, callback: (any) -> any)
	self:_assertActive()
	assert(typeof(callback) == "function", "Update callback must be a function")

	local current = self:Get(path)
	self:Set(path, callback(current))
end

function PlayerProfile:Increment(path: any, amount: number?)
	self:_assertActive()

	local incrementAmount = amount or 1
	assert(typeof(incrementAmount) == "number", "Increment amount must be a number")
	assert(
		incrementAmount == incrementAmount and incrementAmount > -math.huge and incrementAmount < math.huge,
		"Increment amount must be finite"
	)

	local current = self:Get(path)
	assert(typeof(current) == "number", "Increment target must be numeric")
	assert(current + incrementAmount == current + incrementAmount, "Increment result must be finite")

	self:Set(path, current + incrementAmount)
end

function PlayerProfile:Delete(path: any)
	self:_assertActive()

	local normalized = self:_normalizeKnownPath(path)
	assert(
		PlayerDataSchemaUtils.isOptionalPath(self._schemaInfo, normalized),
		`Cannot delete required schema field {pathToString(normalized)}`
	)

	local draft = PlayerDataTableUtils.deepClone(self._data)
	PlayerDataPathUtils.delete(draft, normalized)
	self:_commitDraft(draft)
end

function PlayerProfile:Batch(callback: (any) -> ())
	self:_assertActive()
	assert(typeof(callback) == "function", "Batch callback must be a function")
	assert(not self._committing, "Nested PlayerProfile commits are not supported")

	local profile = self
	local draft = PlayerDataTableUtils.deepClone(self._data)
	local transaction = {}

	function transaction.Set(_transaction: any, path: any, value: any)
		local normalized = profile:_normalizeKnownPath(path)
		if value == nil and PlayerDataSchemaUtils.isOptionalPath(profile._schemaInfo, normalized) then
			PlayerDataPathUtils.delete(draft, normalized)
			return
		end

		profile:_validateValue(normalized, value)
		PlayerDataPathUtils.set(draft, normalized, PlayerDataTableUtils.deepClone(value))
	end

	function transaction.Update(_transaction: any, path: any, updateCallback: (any) -> any)
		assert(typeof(updateCallback) == "function", "Update callback must be a function")

		local normalized = profile:_normalizeKnownPath(path)
		local current = PlayerDataTableUtils.deepClone(PlayerDataPathUtils.get(draft, normalized))
		transaction.Set(transaction, normalized, updateCallback(current))
	end

	function transaction.Increment(_transaction: any, path: any, amount: number?)
		local incrementAmount = amount or 1
		assert(typeof(incrementAmount) == "number", "Increment amount must be a number")

		local normalized = profile:_normalizeKnownPath(path)
		local current = PlayerDataPathUtils.get(draft, normalized)
		assert(typeof(current) == "number", "Increment target must be numeric")
		transaction.Set(transaction, normalized, current + incrementAmount)
	end

	function transaction.Delete(_transaction: any, path: any)
		local normalized = profile:_normalizeKnownPath(path)
		assert(
			PlayerDataSchemaUtils.isOptionalPath(profile._schemaInfo, normalized),
			`Cannot delete required schema field {pathToString(normalized)}`
		)
		PlayerDataPathUtils.delete(draft, normalized)
	end

	local ok, err = pcall(callback, transaction)
	if not ok then
		error(err, 2)
	end

	self:_commitDraft(draft)
end

function PlayerProfile:Mutate(callback: (any) -> ())
	self:_assertActive()
	assert(typeof(callback) == "function", "Mutate callback must be a function")

	local draft = PlayerDataTableUtils.deepClone(self._data)
	local ok, err = pcall(callback, draft)
	if not ok then
		error(err, 2)
	end

	self:_commitDraft(draft)
end

function PlayerProfile:Observe(path: any?)
	local normalized = PlayerDataPathUtils.normalize(path)

	return Observable.new(function(sub)
		local maid = Maid.new()
		local hasLastValue = false
		local lastValue = nil

		local function emitIfChanged()
			if not self:IsActive() then
				return
			end

			local nextValue = PlayerDataPathUtils.get(self._data, normalized)
			if not hasLastValue or not PlayerDataTableUtils.deepEquals(lastValue, nextValue) then
				hasLastValue = true
				lastValue = PlayerDataTableUtils.deepClone(nextValue)
				sub:Fire(PlayerDataTableUtils.readonlySnapshot(nextValue))
			end
		end

		emitIfChanged()
		maid:GiveTask(self._changed:Connect(emitIfChanged))
		maid:GiveTask(self._destroying:Connect(function()
			sub:Complete()
		end))

		return maid
	end)
end

function PlayerProfile:ObserveSnapshot()
	return Observable.new(function(sub)
		local maid = Maid.new()

		if self:IsActive() then
			sub:Fire(self:GetSnapshot())
		end

		maid:GiveTask(self._changed:Connect(function(snapshot)
			sub:Fire(snapshot)
		end))
		maid:GiveTask(self._destroying:Connect(function()
			sub:Complete()
		end))

		return maid
	end)
end

function PlayerProfile:PromiseSave()
	self:_assertActive()
	assert(typeof(self._rootDataStore.Save) == "function", "Underlying Nevermore datastore does not expose Save()")
	return self._rootDataStore:Save()
end

function PlayerProfile:Destroy()
	if not self._active then
		return
	end

	self._active = false
	self._destroying:Fire()
	if self._onReleased then
		self._onReleased(self)
	end

	self._maid:DoCleaning()
end

return PlayerProfile
