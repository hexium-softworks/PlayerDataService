--!strict
--[=[
	@class PlayerDataPathUtils.spec
]=]

local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")
local PlayerDataPathUtils = require("PlayerDataPathUtils")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

describe("PlayerDataPathUtils", function()
	it("normalizes dotted and array paths", function()
		expect(PlayerDataPathUtils.normalize("Currency.Coins")).toEqual({ "Currency", "Coins" })
		expect(PlayerDataPathUtils.normalize({ "Inventory", "Items" })).toEqual({ "Inventory", "Items" })
	end)

	it("rejects malformed paths", function()
		expect(function()
			PlayerDataPathUtils.normalize("Currency..Coins")
		end).toThrow()

		expect(function()
			PlayerDataPathUtils.normalize({ "Currency.Coins" })
		end).toThrow()
	end)

	it("gets, sets, deletes, and compares paths", function()
		local data = {
			Currency = {
				Coins = 5,
			},
		}

		expect(PlayerDataPathUtils.get(data, { "Currency", "Coins" })).toBe(5)
		PlayerDataPathUtils.set(data, { "Currency", "Gems" }, 2)
		expect(data.Currency.Gems).toBe(2)
		PlayerDataPathUtils.delete(data, { "Currency", "Coins" })
		expect(data.Currency.Coins).toBeNil()

		expect(PlayerDataPathUtils.isPrefix({ "Currency" }, { "Currency", "Gems" })).toBe(true)
		expect(PlayerDataPathUtils.overlaps({ "Currency" }, { "Currency", "Gems" })).toBe(true)
	end)
end)
