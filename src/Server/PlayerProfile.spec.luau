--!strict
--[=[
	@class PlayerProfile.spec
]=]

local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")
local PlayerDataSchema = require("PlayerDataSchema")
local PlayerDataSchemaUtils = require("PlayerDataSchemaUtils")
local PlayerProfile = require("PlayerProfile")
local Promise = require("Promise")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

local function createStage(name: string?)
	local stage = {
		Name = name or "Root",
		Stores = {},
		Deletes = {},
		Wiped = false,
		Children = {},
	}

	function stage:GetSubStore(key)
		if not self.Children[key] then
			self.Children[key] = createStage(key)
		end

		return self.Children[key]
	end

	function stage:Store(key, value)
		table.insert(self.Stores, {
			Key = key,
			Value = value,
		})
	end

	function stage:Delete(key)
		table.insert(self.Deletes, key)
	end

	function stage:Wipe()
		self.Wiped = true
	end

	return stage
end

local function createProfile()
	local rootDataStore = {
		Saved = false,
	}

	function rootDataStore:Save()
		self.Saved = true
		return Promise.resolved(true)
	end

	local dataStage = createStage("Data")
	local schemaInfo = PlayerDataSchemaUtils.normalize({
		Version = 1,
		Template = {
			Currency = {
				Coins = 0,
				Gems = 0,
			},
			Progression = {
				Level = 1,
			},
			Nickname = PlayerDataSchema.Optional(PlayerDataSchema.String("", { MaxLength = 12 })),
		},
		Replication = {
			Owner = {
				"Currency.Coins",
			},
		},
	})

	return PlayerProfile.new({
		Player = {
			Name = "TestPlayer",
			UserId = 1,
		},
		RootDataStore = rootDataStore,
		DataStage = dataStage,
		Data = {
			Currency = {
				Coins = 10,
				Gems = 1,
			},
			Progression = {
				Level = 1,
			},
		},
		SchemaInfo = schemaInfo,
	}),
		dataStage,
		rootDataStore
end

describe("PlayerProfile", function()
	it("sets and increments nested fields through sub-stores", function()
		local profile, dataStage = createProfile()

		profile:Set("Currency.Coins", 20)
		profile:Increment("Currency.Gems", 4)
		profile.Data.Currency.Coins:Increment(5)

		expect(profile:Get("Currency.Coins")).toBe(25)
		expect(profile:Get("Currency.Gems")).toBe(5)
		expect(dataStage.Children.Currency.Stores[1].Key).toBe("Coins")
		expect(dataStage.Children.Currency.Stores[2].Key).toBe("Gems")

		profile:Destroy()
	end)

	it("supports optional fields and deletes through accessors", function()
		local profile, dataStage = createProfile()

		profile.Data.Nickname:Set("Hex")
		expect(profile:Get("Nickname")).toBe("Hex")

		profile.Data.Nickname:Delete()
		expect(profile:Get("Nickname")).toBeNil()
		expect(dataStage.Deletes[1]).toBe("Nickname")

		profile:Destroy()
	end)

	it("does not commit failed batches", function()
		local profile = createProfile()

		expect(function()
			profile:Batch(function(transaction)
				transaction:Set("Currency.Coins", 99)
				error("nope")
			end)
		end).toThrow()

		expect(profile:Get("Currency.Coins")).toBe(10)
		profile:Destroy()
	end)

	it("rejects unknown paths and new unknown mutate fields", function()
		local profile = createProfile()

		expect(function()
			profile:Set("Currency.Private", 1)
		end).toThrow()

		expect(function()
			profile:Mutate(function(data)
				data.Currency.Private = 1
			end)
		end).toThrow()

		profile:Destroy()
	end)

	it("returns read-only snapshots", function()
		local profile = createProfile()
		local snapshot = profile:GetSnapshot()

		expect(function()
			snapshot.Currency.Coins = 999
		end).toThrow()
		expect(profile:Get("Currency.Coins")).toBe(10)

		profile:Destroy()
	end)

	it("invalidates after destroy", function()
		local profile = createProfile()
		profile:Destroy()

		expect(profile:IsActive()).toBe(false)
		expect(function()
			profile:Get("Currency.Coins")
		end).toThrow()
	end)
end)
