--!strict
--[=[
	@class PlayerDataReconciler.spec
]=]

local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")
local PlayerDataReconciler = require("PlayerDataReconciler")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

describe("PlayerDataReconciler", function()
	it("adds missing fields without mutating the template", function()
		local template = {
			Currency = {
				Coins = 0,
				Gems = 0,
			},
		}
		local saved = {
			Currency = {
				Coins = 50,
			},
			Legacy = true,
		}

		local result = PlayerDataReconciler.reconcile(saved, template)

		expect(result.Data.Currency.Coins).toBe(50)
		expect(result.Data.Currency.Gems).toBe(0)
		expect(result.Data.Legacy).toBe(true)
		expect(template.Currency.Gems).toBe(0)
	end)

	it("replaces structurally incompatible values", function()
		local result = PlayerDataReconciler.reconcile({
			Currency = "bad",
		}, {
			Currency = {
				Coins = 0,
			},
		})

		expect(result.Data.Currency.Coins).toBe(0)
		expect(#result.Issues).toBe(1)
		expect(result.Issues[1].Path).toBe("Currency")
	end)

	it("does not share template table references", function()
		local template = {
			Inventory = {
				Items = {},
			},
		}

		local left = PlayerDataReconciler.reconcile({}, template).Data
		local right = PlayerDataReconciler.reconcile({}, template).Data

		left.Inventory.Items[1] = "Sword"
		expect(right.Inventory.Items[1]).toBeNil()
	end)
end)
