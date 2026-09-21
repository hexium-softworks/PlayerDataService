--!strict
--[=[
	@class PlayerDataAccessorBuilder.spec
]=]

local require = require(script.Parent.loader).load(script)

local Jest = require("Jest")
local PlayerDataAccessorBuilder = require("PlayerDataAccessorBuilder")

local describe = Jest.Globals.describe
local expect = Jest.Globals.expect
local it = Jest.Globals.it

describe("PlayerDataAccessorBuilder", function()
	it("builds dynamic client accessors", function()
		local observedPath = nil
		local fakeClient = {}

		function fakeClient:Get(path)
			return table.concat(path, ".")
		end

		function fakeClient:Observe(path)
			observedPath = path
			return {
				Subscribe = function(_observable, callback)
					callback("value")
					return {
						Destroy = function() end,
					}
				end,
			}
		end

		local data = PlayerDataAccessorBuilder.createClientAccessors(fakeClient, nil)
		local observed = nil
		local subscription = data.Currency.Coins:Observe(function(value)
			observed = value
		end)

		expect(data.Currency.Coins:Get()).toBe("Currency.Coins")
		expect(observed).toBe("value")
		expect(observedPath).toEqual({ "Currency", "Coins" })

		subscription:Destroy()
	end)
end)
