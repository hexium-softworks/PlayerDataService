--!strict
--[=[
	@class PlayerDataMigrationRunner.spec
]=]

local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")
local PlayerDataMigrationRunner = require("PlayerDataMigrationRunner")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

describe("PlayerDataMigrationRunner", function()
	it("runs migrations in ascending order", function()
		local order = {}
		local result = PlayerDataMigrationRunner.run(
			{
				Value = 1,
			},
			1,
			3,
			{
				[2] = function(data)
					table.insert(order, 2)
					data.Value += 1
					return data
				end,
				[3] = function(data)
					table.insert(order, 3)
					data.Value *= 10
					return data
				end,
			}
		)

		expect(order).toEqual({ 2, 3 })
		expect(result.Data.Value).toBe(20)
	end)

	it("fails when a required migration is missing", function()
		expect(function()
			PlayerDataMigrationRunner.run({}, 1, 3, {
				[3] = function(data)
					return data
				end,
			})
		end).toThrow()
	end)
end)
