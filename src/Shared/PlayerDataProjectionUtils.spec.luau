--!strict
--[=[
	@class PlayerDataProjectionUtils.spec
]=]

local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")
local PlayerDataProjectionUtils = require("PlayerDataProjectionUtils")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

describe("PlayerDataProjectionUtils", function()
	it("projects only declared owner-visible paths", function()
		local projection = PlayerDataProjectionUtils.project({
			Currency = {
				Coins = 10,
				LastFraudReview = "private",
			},
			Internal = {
				LastReceiptId = "secret",
			},
		}, {
			{ "Currency", "Coins" },
		})

		expect(projection.Currency.Coins).toBe(10)
		expect(projection.Currency.LastFraudReview).toBeNil()
		expect(projection.Internal).toBeNil()
	end)

	it("diffs filtered projections without leaking private siblings", function()
		local operations = PlayerDataProjectionUtils.diff({
			Currency = {
				Coins = 10,
				LastFraudReview = "private",
			},
		}, {
			Currency = {
				Coins = 20,
				LastFraudReview = "changed",
			},
		}, {
			{ "Currency", "Coins" },
		})

		expect(#operations).toBe(1)
		expect(operations[1].Path).toEqual({ "Currency", "Coins" })
		expect(operations[1].Value).toBe(20)
	end)
end)
