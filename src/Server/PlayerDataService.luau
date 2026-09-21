--!strict
--[=[
	Schema-driven player data service built on Nevermore PlayerDataStoreService.

	@class PlayerDataService
]=]

local Players = game:GetService("Players")

local require = require(script.Parent.loader).load(script)

local Log = require("Log")
local Maid = require("Maid")
local Observable = require("Observable")
local PlayerDataMigrationRunner = require("PlayerDataMigrationRunner")
local PlayerDataPathUtils = require("PlayerDataPathUtils")
local PlayerDataProjectionUtils = require("PlayerDataProjectionUtils")
local PlayerDataReconciler = require("PlayerDataReconciler")
local PlayerDataSchemaUtils = require("PlayerDataSchemaUtils")
local PlayerDataServiceConstants = require("PlayerDataServiceConstants")
local PlayerDataTableUtils = require("PlayerDataTableUtils")
local PlayerDataValueValidator = require("PlayerDataValueValidator")
local PlayerProfile = require("PlayerProfile")
local Promise = require("Promise")
local ReplicationService = require("ReplicationService")
local Signal = require("Signal")

local PlayerDataStoreService = require("PlayerDataStoreService")

type SchemaInfo = PlayerDataSchemaUtils.SchemaInfo
type ReconcileIssue = PlayerDataReconciler.ReconcileIssue

local PlayerDataService = {}
PlayerDataService.ServiceName = "PlayerDataService"

local LOGGER = Log.new({
	name = "PlayerDataService",
	defaultContext = {
		Package = "PlayerDataService",
		Service = PlayerDataService.ServiceName,
	},
})

local function makeStateId(player: Player): string
	return `{PlayerDataServiceConstants.REPLICATED_STATE_PREFIX}:{player.UserId}`
end

function PlayerDataService:Init(serviceBag)
	assert(not self._serviceBag, "Already initialized")

	self._serviceBag = assert(serviceBag, "No serviceBag")
	self._maid = Maid.new()
	self._records = {}
	self._schemaInfo = nil
	self._namespace = PlayerDataServiceConstants.DEFAULT_NAMESPACE
	self._started = false
	self._replicationEnabled = true
	self._profileChanged = self._maid:Add(Signal.new())
	self._loadedPlayersChanged = self._maid:Add(Signal.new())
	self._loadFailureHandler = function(player, _failure)
		if player.Parent == Players then
			player:Kick("Your data could not be loaded. Please rejoin.")
		end
	end
	self._profileReleasedHandler = nil

	self._playerDataStoreService = serviceBag:GetService(PlayerDataStoreService)
	self._replicationService = serviceBag:GetService(ReplicationService)
end

function PlayerDataService:_assertConfigurable()
	assert(not self._started, "PlayerDataService configuration is locked after Start()")
end

function PlayerDataService:SetSchema(schema: any)
	self:_assertConfigurable()

	local ok, schemaInfoOrError = pcall(function()
		return PlayerDataSchemaUtils.normalize(schema)
	end)
	if not ok then
		LOGGER.Error("Invalid player data schema", {
			Error = tostring(schemaInfoOrError),
		})
		error(schemaInfoOrError, 2)
	end

	self._schemaInfo = schemaInfoOrError
end

function PlayerDataService:SetNamespace(namespace: string)
	self:_assertConfigurable()
	assert(typeof(namespace) == "string" and namespace ~= "", "Namespace must be a non-empty string")
	assert(namespace ~= PlayerDataServiceConstants.DATA_KEY, "Namespace cannot be reserved Data key")
	assert(namespace ~= PlayerDataServiceConstants.METADATA_KEY, "Namespace cannot be reserved Metadata key")

	self._namespace = namespace
end

function PlayerDataService:SetLoadFailureHandler(callback: (Player, any) -> ())
	self:_assertConfigurable()
	assert(typeof(callback) == "function", "Load failure handler must be a function")

	self._loadFailureHandler = callback
end

function PlayerDataService:SetProfileReleasedHandler(callback: ((any) -> ())?)
	self:_assertConfigurable()
	assert(callback == nil or typeof(callback) == "function", "Profile released handler must be a function or nil")

	self._profileReleasedHandler = callback
end

function PlayerDataService:SetReplicationEnabled(enabled: boolean)
	self:_assertConfigurable()
	assert(typeof(enabled) == "boolean", "Replication enabled must be a boolean")

	self._replicationEnabled = enabled
end

function PlayerDataService:Start()
	assert(self._schemaInfo ~= nil, "PlayerDataService requires SetSchema() before Start()")
	self._started = true

	self._maid:GiveTask(Players.PlayerAdded:Connect(function(player)
		self:_ensureLoading(player)
	end))
	self._maid:GiveTask(Players.PlayerRemoving:Connect(function(player)
		self:_releasePlayer(player, "PlayerRemoving")
	end))

	for _, player in Players:GetPlayers() do
		self:_ensureLoading(player)
	end

	LOGGER.Info("Started", {
		Namespace = self._namespace,
		ReplicationEnabled = self._replicationEnabled,
	})
end

function PlayerDataService:_getProfileStage(rootDataStore: any)
	local profileStage = rootDataStore:GetSubStore(self._namespace)
	local dataStage = profileStage:GetSubStore(PlayerDataServiceConstants.DATA_KEY)
	local metadataStage = profileStage:GetSubStore(PlayerDataServiceConstants.METADATA_KEY)

	return profileStage, dataStage, metadataStage
end

function PlayerDataService:_runValidators(data: any, schemaInfo: SchemaInfo)
	for pathString, validator in schemaInfo.Validators do
		local path = PlayerDataPathUtils.normalize(pathString)
		local value = PlayerDataPathUtils.get(data, path)
		if value ~= nil or not PlayerDataSchemaUtils.isOptionalPath(schemaInfo, path) then
			local ok, message = validator(value, data)
			assert(ok == true, message or `Validator rejected player data path {pathString}`)
		end
	end
end

function PlayerDataService:_logReconcileIssues(player: Player, issues: { ReconcileIssue })
	for _, issue in issues do
		LOGGER.Warn("Replaced incompatible saved player data value during reconciliation", {
			Player = player.Name,
			UserId = player.UserId,
			Path = issue.Path,
			Expected = issue.Expected,
			Actual = issue.Actual,
		})
	end
end

function PlayerDataService:_prepareData(player: Player, savedData: any, storedVersion: any): any
	local schemaInfo: SchemaInfo = assert(self._schemaInfo, "No schema")
	local resolvedStoredVersion = if typeof(storedVersion) == "number" then storedVersion else 0
	assert(
		resolvedStoredVersion % 1 == 0 and resolvedStoredVersion >= 0,
		"Stored schema version must be a non-negative integer"
	)

	local loadedData = if typeof(savedData) == "table" then savedData else {}
	local hasSavedData = next(loadedData) ~= nil
	if not hasSavedData and resolvedStoredVersion == 0 then
		loadedData = PlayerDataSchemaUtils.createDefaultData(schemaInfo)
		resolvedStoredVersion = schemaInfo.Version
	elseif hasSavedData and resolvedStoredVersion == 0 then
		error("Saved player data exists without schema metadata")
	end

	local migrated =
		PlayerDataMigrationRunner.run(loadedData, resolvedStoredVersion, schemaInfo.Version, schemaInfo.Migrations)
	local reconciled = PlayerDataReconciler.reconcile(migrated.Data, schemaInfo.Template)
	PlayerDataSchemaUtils.applyMissingDynamicDefaults(schemaInfo, reconciled.Data, migrated.Data)
	self:_logReconcileIssues(player, reconciled.Issues)

	local result = PlayerDataValueValidator.validateShape(reconciled.Data, schemaInfo.Template, {}, true)
	assert(result.Ok, result.Message or "Loaded player data failed validation")
	self:_runValidators(reconciled.Data, schemaInfo)

	return reconciled.Data
end

function PlayerDataService:_commitInitialData(profileStage: any, metadataStage: any, data: any, schemaInfo: SchemaInfo)
	profileStage:Store(PlayerDataServiceConstants.DATA_KEY, PlayerDataTableUtils.deepClone(data))
	metadataStage:Store(PlayerDataServiceConstants.SCHEMA_VERSION_KEY, schemaInfo.Version)
end

function PlayerDataService:_createReplicatedState(player: Player, data: any)
	if not self._replicationEnabled then
		return nil
	end

	local schemaInfo: SchemaInfo = assert(self._schemaInfo, "No schema")
	local initialState = PlayerDataProjectionUtils.project(data, schemaInfo.OwnerReplicationPaths)

	return self._replicationService:CreateState({
		Id = makeStateId(player),
		InitialState = initialState,
		Audience = player,
	})
end

function PlayerDataService:_patchReplicatedState(record: any, oldData: any, newData: any)
	local replicatedState = record.ReplicatedState
	if not replicatedState then
		return
	end

	local schemaInfo: SchemaInfo = assert(self._schemaInfo, "No schema")
	local operations = PlayerDataProjectionUtils.diff(oldData, newData, schemaInfo.OwnerReplicationPaths)
	if #operations == 0 then
		return
	end

	replicatedState:Batch(function(transaction)
		for _, operation in operations do
			if operation.Operation == "Delete" then
				transaction:Delete(operation.Path)
			else
				transaction:Set(operation.Path, operation.Value)
			end
		end
	end)
end

function PlayerDataService:_finishLoad(player: Player, record: any, rootDataStore: any, dataStage: any, data: any)
	if self._records[player] ~= record or player.Parent ~= Players then
		error("Player left before profile became ready")
	end

	local replicatedState = self:_createReplicatedState(player, data)
	record.ReplicatedState = replicatedState

	local profile = PlayerProfile.new({
		Player = player,
		RootDataStore = rootDataStore,
		DataStage = dataStage,
		Data = data,
		SchemaInfo = assert(self._schemaInfo, "No schema"),
		OnChanged = function(oldData, newData, operations)
			self:_patchReplicatedState(record, oldData, newData)
			self._profileChanged:Fire(player, record.Profile, operations)
		end,
		OnReleased = function(releasedProfile)
			if self._profileReleasedHandler then
				self._profileReleasedHandler(releasedProfile)
			end
		end,
	})

	record.State = "Ready"
	record.Profile = profile
	record.Resolve(profile)
	self._profileChanged:Fire(player, profile)
	self._loadedPlayersChanged:Fire(self:GetLoadedPlayers())

	LOGGER.Info("Loaded player profile", {
		Player = player.Name,
		UserId = player.UserId,
		Namespace = self._namespace,
	})
end

function PlayerDataService:_handleLoadFailure(player: Player, record: any, failure: any)
	if self._records[player] ~= record then
		return
	end

	record.State = "Failed"
	record.Reject(failure)
	self._records[player] = nil
	self._profileChanged:Fire(player, nil)
	self._loadedPlayersChanged:Fire(self:GetLoadedPlayers())

	LOGGER.Warn("Failed to load player profile", {
		Player = player.Name,
		UserId = player.UserId,
		Kind = failure.Kind,
		Cause = tostring(failure.Cause),
	})

	self._loadFailureHandler(player, failure)
end

function PlayerDataService:_ensureLoading(player: Player)
	assert(self._started, "PlayerDataService has not started")
	assert(typeof(player) == "Instance" and player:IsA("Player"), "Expected Player")

	local existing = self._records[player]
	if existing then
		if existing.State == "Ready" then
			return Promise.resolved(existing.Profile)
		end

		return existing.Promise
	end

	local record = {
		State = "Loading",
		Promise = nil,
		Resolve = nil,
		Reject = nil,
		Profile = nil,
		ReplicatedState = nil,
	}
	self._records[player] = record

	record.Promise = Promise.new(function(resolve, reject)
		record.Resolve = resolve
		record.Reject = reject
	end)

	self._playerDataStoreService
		:PromiseDataStore(player)
		:Then(function(rootDataStore)
			if self._records[player] ~= record or player.Parent ~= Players then
				error("Player left during data load")
			end

			local profileStage, dataStage, metadataStage = self:_getProfileStage(rootDataStore)
			return dataStage:LoadAll({}):Then(function(savedData)
				return metadataStage:Load(PlayerDataServiceConstants.SCHEMA_VERSION_KEY, 0):Then(function(storedVersion)
					local schemaInfo: SchemaInfo = assert(self._schemaInfo, "No schema")
					local preparedData = self:_prepareData(player, savedData, storedVersion)
					self:_commitInitialData(profileStage, metadataStage, preparedData, schemaInfo)
					self:_finishLoad(player, record, rootDataStore, dataStage, preparedData)
				end)
			end)
		end)
		:Catch(function(err)
			local failure = {
				Kind = "LoadFailed",
				Player = player,
				UserId = player.UserId,
				TargetVersion = if self._schemaInfo then self._schemaInfo.Version else nil,
				Cause = err,
			}
			self:_handleLoadFailure(player, record, failure)
		end)

	return record.Promise
end

function PlayerDataService:_releasePlayer(player: Player, reason: string)
	local record = self._records[player]
	if not record then
		return
	end

	self._records[player] = nil
	record.State = "Released"

	if record.ReplicatedState then
		record.ReplicatedState:Destroy()
		record.ReplicatedState = nil
	end

	if record.Profile then
		record.Profile:Destroy()
		record.Profile = nil
	elseif record.Reject then
		record.Reject({
			Kind = reason,
			Player = player,
			UserId = player.UserId,
		})
	end

	self._profileChanged:Fire(player, nil)
	self._loadedPlayersChanged:Fire(self:GetLoadedPlayers())
end

function PlayerDataService:IsLoaded(player: Player): boolean
	local record = self._records[player]
	return record ~= nil and record.State == "Ready" and record.Profile ~= nil and record.Profile:IsActive()
end

function PlayerDataService:GetProfile(player: Player)
	local record = self._records[player]
	if record and record.State == "Ready" and record.Profile and record.Profile:IsActive() then
		return record.Profile
	end

	return nil
end

function PlayerDataService:PromiseProfile(player: Player)
	local profile = self:GetProfile(player)
	if profile then
		return Promise.resolved(profile)
	end

	if player.Parent ~= Players then
		return Promise.rejected("Player is not in Players")
	end

	return self:_ensureLoading(player)
end

function PlayerDataService:ObserveProfile(player: Player)
	return Observable.new(function(sub)
		local maid = Maid.new()

		sub:Fire(self:GetProfile(player))
		maid:GiveTask(self._profileChanged:Connect(function(changedPlayer, profile)
			if changedPlayer == player then
				sub:Fire(profile)
			end
		end))

		return maid
	end)
end

function PlayerDataService:GetLoadedPlayers(): { Player }
	local players = {}

	for player, record in self._records do
		if record.State == "Ready" and record.Profile and record.Profile:IsActive() then
			table.insert(players, player)
		end
	end

	table.sort(players, function(left, right)
		return left.UserId < right.UserId
	end)

	return players
end

function PlayerDataService:ObserveLoadedPlayers()
	return Observable.new(function(sub)
		local maid = Maid.new()

		sub:Fire(self:GetLoadedPlayers())
		maid:GiveTask(self._loadedPlayersChanged:Connect(function(players)
			sub:Fire(table.clone(players))
		end))

		return maid
	end)
end

function PlayerDataService:Destroy()
	if not self._maid then
		return
	end

	for player in self._records do
		self:_releasePlayer(player, "ServiceDestroyed")
	end

	self._maid:DoCleaning()
end

return PlayerDataService
