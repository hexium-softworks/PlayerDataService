--!strict
--[=[
	Read-only client wrapper for the local player's replicated profile data.

	@class PlayerDataServiceClient
]=]

local Players = game:GetService("Players")

local require = require(script.Parent.loader).load(script)

local Log = require("Log")
local Maid = require("Maid")
local Observable = require("Observable")
local PlayerDataAccessorBuilder = require("PlayerDataAccessorBuilder")
local PlayerDataSchemaUtils = require("PlayerDataSchemaUtils")
local PlayerDataServiceConstants = require("PlayerDataServiceConstants")
local ReplicationServiceClient = require("ReplicationServiceClient")

local PlayerDataServiceClient = {}
PlayerDataServiceClient.ServiceName = "PlayerDataServiceClient"

local LOGGER = Log.new({
	name = "PlayerDataServiceClient",
	defaultContext = {
		Package = "PlayerDataService",
		Service = PlayerDataServiceClient.ServiceName,
	},
})

local function makeStateId(player: Player): string
	return `{PlayerDataServiceConstants.REPLICATED_STATE_PREFIX}:{player.UserId}`
end

function PlayerDataServiceClient:Init(serviceBag)
	assert(not self._serviceBag, "Already initialized")

	self._serviceBag = assert(serviceBag, "No serviceBag")
	self._maid = Maid.new()
	self._player = Players.LocalPlayer
	self._stateId = makeStateId(self._player)
	self._replicationServiceClient = serviceBag:GetService(ReplicationServiceClient)
	self._started = false
	self._schemaInfo = nil
	self.Data = PlayerDataAccessorBuilder.createClientAccessors(self, nil)
end

function PlayerDataServiceClient:Start()
	self._started = true
	LOGGER.Info("Started", {
		StateId = self._stateId,
	})
end

function PlayerDataServiceClient:SetSchema(schema: any)
	assert(not self._started, "PlayerDataServiceClient configuration is locked after Start()")

	self._schemaInfo = PlayerDataSchemaUtils.normalize(schema)
	self.Data = PlayerDataAccessorBuilder.createClientAccessors(self, self._schemaInfo)
end

function PlayerDataServiceClient:_getReadyState()
	local state = self._replicationServiceClient:GetState(self._stateId)
	assert(state ~= nil and state:IsReady(), "PlayerDataServiceClient is not ready")
	return state
end

function PlayerDataServiceClient:IsReady(): boolean
	local state = self._replicationServiceClient:GetState(self._stateId)
	return state ~= nil and state:IsReady()
end

function PlayerDataServiceClient:PromiseReady()
	local state = self._replicationServiceClient:GetState(self._stateId)
	if state then
		return state:PromiseReady()
	end

	return self._replicationServiceClient:PromiseState(self._stateId)
end

function PlayerDataServiceClient:Get(path: any?): any
	return self:_getReadyState():Get(path)
end

function PlayerDataServiceClient:GetSnapshot(): any
	return self:_getReadyState():GetSnapshot()
end

function PlayerDataServiceClient:Observe(path: any?)
	return Observable.new(function(sub)
		local maid = Maid.new()
		local subscription: any = nil
		local active = true

		local function attach(state)
			if not active then
				return
			end

			if subscription then
				subscription:Destroy()
				subscription = nil
			end

			if state then
				subscription = state:Observe(path):Subscribe(function(value)
					sub:Fire(value)
				end)
				maid:GiveTask(subscription)
			end
		end

		local state = self._replicationServiceClient:GetState(self._stateId)
		if state and state:IsReady() then
			attach(state)
		end

		maid:GiveTask(self._replicationServiceClient:ObserveState(self._stateId):Subscribe(function(nextState)
			if nextState and nextState:IsReady() then
				attach(nextState)
			elseif subscription then
				subscription:Destroy()
				subscription = nil
			end
		end))

		self:PromiseReady():Then(function(readyState)
			attach(readyState)
		end)

		maid:GiveTask(function()
			active = false
		end)

		return maid
	end)
end

function PlayerDataServiceClient:ObserveSnapshot()
	return Observable.new(function(sub)
		local maid = Maid.new()
		local subscription: any = nil
		local active = true

		local function attach(state)
			if not active then
				return
			end

			if subscription then
				subscription:Destroy()
				subscription = nil
			end

			if state then
				subscription = state:ObserveSnapshot():Subscribe(function(snapshot)
					sub:Fire(snapshot)
				end)
				maid:GiveTask(subscription)
			end
		end

		local state = self._replicationServiceClient:GetState(self._stateId)
		if state and state:IsReady() then
			attach(state)
		end

		maid:GiveTask(self._replicationServiceClient:ObserveState(self._stateId):Subscribe(function(nextState)
			if nextState and nextState:IsReady() then
				attach(nextState)
			elseif subscription then
				subscription:Destroy()
				subscription = nil
			end
		end))

		self:PromiseReady():Then(function(readyState)
			attach(readyState)
		end)

		maid:GiveTask(function()
			active = false
		end)

		return maid
	end)
end

function PlayerDataServiceClient:ObserveSelector(selector: (any) -> any)
	assert(typeof(selector) == "function", "ObserveSelector expects a function")

	return Observable.new(function(sub)
		local maid = Maid.new()
		local subscription: any = nil
		local active = true

		local function attach(state)
			if not active then
				return
			end

			if subscription then
				subscription:Destroy()
				subscription = nil
			end

			if state then
				subscription = state:ObserveSelector(selector):Subscribe(function(value)
					sub:Fire(value)
				end)
				maid:GiveTask(subscription)
			end
		end

		local state = self._replicationServiceClient:GetState(self._stateId)
		if state and state:IsReady() then
			attach(state)
		end

		maid:GiveTask(self._replicationServiceClient:ObserveState(self._stateId):Subscribe(function(nextState)
			if nextState and nextState:IsReady() then
				attach(nextState)
			elseif subscription then
				subscription:Destroy()
				subscription = nil
			end
		end))

		self:PromiseReady():Then(function(readyState)
			attach(readyState)
		end)

		maid:GiveTask(function()
			active = false
		end)

		return maid
	end)
end

function PlayerDataServiceClient:Destroy()
	if not self._maid then
		return
	end

	self._maid:DoCleaning()
end

return PlayerDataServiceClient
