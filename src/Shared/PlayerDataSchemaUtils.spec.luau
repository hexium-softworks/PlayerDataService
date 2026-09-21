--!strict
--[=[
	@class PlayerDataSchemaUtils.spec
]=]

local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")
local PlayerDataSchema = require("PlayerDataSchema")
local PlayerDataSchemaUtils = require("PlayerDataSchemaUtils")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

describe("PlayerDataSchemaUtils", function()
	it("normalizes a valid schema", function()
		local schemaInfo = PlayerDataSchemaUtils.normalize({
			Version = 2,
			Template = {
				Currency = {
					Coins = 0,
				},
			},
			Migrations = {
				[2] = function(data)
					return data
				end,
			},
			Replication = {
				Owner = {
					"Currency.Coins",
				},
			},
		})

		expect(schemaInfo.Version).toBe(2)
		expect(schemaInfo.SchemaPathSet["Currency.Coins"]).toBe(true)
		expect(#schemaInfo.OwnerReplicationPaths).toBe(1)
	end)

	it("rejects invalid replication paths and duplicate paths", function()
		expect(function()
			PlayerDataSchemaUtils.normalize({
				Version = 1,
				Template = {
					Currency = {
						Coins = 0,
					},
				},
				Replication = {
					Owner = {
						"Currency.Gems",
					},
				},
			})
		end).toThrow()

		expect(function()
			PlayerDataSchemaUtils.normalize({
				Version = 1,
				Template = {
					Currency = {
						Coins = 0,
					},
				},
				Replication = {
					Owner = {
						"Currency.Coins",
						"Currency.Coins",
					},
				},
			})
		end).toThrow()
	end)

	it("compiles Scribe-like declarators into template, validators, and owner paths", function()
		local schemaInfo = PlayerDataSchemaUtils.normalize(PlayerDataSchema.define({
			Version = 1,
			Template = {
				Currency = PlayerDataSchema.Owner({
					Coins = PlayerDataSchema.Int(0, { Min = 0 }),
					Gems = PlayerDataSchema.Int(0, { Min = 0 }),
				}),
				Internal = {
					LastReceiptId = "",
				},
			},
		}))

		expect(schemaInfo.Template.Currency.Coins).toBe(0)
		expect(schemaInfo.Template.Internal.LastReceiptId).toBe("")
		expect(#schemaInfo.OwnerReplicationPaths).toBe(2)
		expect(schemaInfo.Validators["Currency.Coins"](-1)).toBe(false)
		expect(schemaInfo.Validators["Currency.Coins"](1)).toBe(true)
	end)

	it("supports optional, dynamic, enum, and custom check fields", function()
		local createdValue = 100
		local schemaInfo = PlayerDataSchemaUtils.normalize(PlayerDataSchema.define({
			Version = 1,
			Template = {
				Name = PlayerDataSchema.Optional(PlayerDataSchema.String("", { MaxLength = 8 })),
				Created = PlayerDataSchema.Dynamic(function()
					createdValue += 1
					return createdValue
				end),
				Rarity = PlayerDataSchema.Enum("Common", { "Common", "Rare" }),
				Even = PlayerDataSchema.Check(2, function(value)
					return typeof(value) == "number" and value % 2 == 0, "Expected even number"
				end),
			},
		}))

		local first = PlayerDataSchemaUtils.createDefaultData(schemaInfo)
		local second = PlayerDataSchemaUtils.createDefaultData(schemaInfo)

		expect(first.Name).toBeNil()
		expect(schemaInfo.OptionalPathSet.Name).toBe(true)
		expect(first.Created == second.Created).toBe(false)
		expect(schemaInfo.Validators.Rarity("Legendary")).toBe(false)
		expect(schemaInfo.Validators.Even(3)).toBe(false)
	end)

	it("rejects field options on unsupported declarator types", function()
		expect(function()
			PlayerDataSchemaUtils.normalize(PlayerDataSchema.define({
				Version = 1,
				Template = {
					Coins = PlayerDataSchema.Int(0, { MaxLength = 8 }),
				},
			}))
		end).toThrow()

		expect(function()
			PlayerDataSchemaUtils.normalize(PlayerDataSchema.define({
				Version = 1,
				Template = {
					Name = PlayerDataSchema.String("", { Min = 1 }),
				},
			}))
		end).toThrow()
	end)

	it("rejects accessor method name collisions", function()
		expect(function()
			PlayerDataSchemaUtils.normalize(PlayerDataSchema.define({
				Version = 1,
				Template = {
					Get = 1,
				},
			}))
		end).toThrow()
	end)
end)
