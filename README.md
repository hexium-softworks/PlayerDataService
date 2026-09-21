# PlayerDataService

Schema-driven player data for Nevermore Roblox games.

PlayerDataService wraps Nevermore's `PlayerDataStoreService`; it does not
replace Nevermore persistence, session locking, autosave, retry behavior,
staging, mocks, or shutdown handling. Games provide a schema, and this package
loads one package-owned namespace, reconciles saved data, runs migrations,
validates mutations, and replicates only approved owner-visible fields through
ReplicationService.

## Install

```sh
pnpm add @hexium-softworks/playerdataservice
```

The package expects Nevermore ServiceBag and datastore packages plus
`@hexium-softworks/replicationservice`.

## Schema

Start with a normal template. Plain values are persisted on the server but are
not sent to the client. Wrap fields in `Schema.Owner(...)` when the owning
player may see them.

```lua
local Schema = require("PlayerDataSchema")

return Schema.define({
	Version = 2,

	Template = {
		Currency = Schema.Owner({
			Coins = Schema.Int(0, { Min = 0 }),
			Gems = Schema.Int(0, { Min = 0 }),
		}),

		Progression = Schema.Owner({
			Level = Schema.Int(1, { Min = 1 }),
			Experience = Schema.Int(0, { Min = 0 }),
		}),

		Inventory = {
			Items = Schema.Owner({}),
		},

		Internal = {
			LastReceiptId = "",
		},
	},
})
```

Optional migrations transform data into their key version:

```lua
Migrations = {
	[2] = function(data)
		data.Currency = data.Currency or { Coins = data.Coins or 0, Gems = 0 }
		data.Coins = nil
		return data
	end,
}
```

Useful declarators:

```lua
Schema.Int(0, { Min = 0, Max = 999999 })
Schema.Number(1, { Min = 0 })
Schema.String("", { MaxLength = 24 })
Schema.Boolean(false)
Schema.Enum("Common", { "Common", "Rare", "Epic" })
Schema.Optional(Schema.String("", { MaxLength = 20 }))
Schema.Dynamic(function()
	return os.time()
end)
Schema.Check(0, function(value)
	return typeof(value) == "number" and value % 5 == 0, "Expected a multiple of 5"
end)
```

`Schema.Check` accepts any checker function, including an Osyris `t` checker
that your game imports itself. `t` is not a package dependency.

## Server Setup

Configure before `Start()`:

```lua
local require = require(script.Parent.loader).load(script)

local PlayerDataService = require("PlayerDataService")

function GameDataConfiguration:Init(serviceBag)
	self._playerData = serviceBag:GetService(PlayerDataService)
	self._playerData:SetSchema(require("GamePlayerDataSchema"))
	self._playerData:SetNamespace("Profile")
end
```

The datastore layout is isolated to the configured namespace:

```lua
{
	Profile = {
		Data = {},
		Metadata = {
			SchemaVersion = 1,
		},
	},

	Settings = {},
}
```

PlayerDataService only writes inside `Profile`. Sibling settings data remains
owned by other packages.

## Server API

```lua
playerDataService:IsLoaded(player)
playerDataService:GetProfile(player)
playerDataService:PromiseProfile(player)
playerDataService:ObserveProfile(player)
playerDataService:ObserveLoadedPlayers()
```

Profiles expose safe path-based mutations:

```lua
profile:Get("Currency.Coins")
profile:Set("Currency.Coins", 500)
profile:Increment("Currency.Coins", 100)

profile:Batch(function(transaction)
	transaction:Increment("Currency.Coins", 500)
	transaction:Set("Progression.Level", 2)
end)

profile:Mutate(function(data)
	data.Currency.Coins += 100
end)
```

They also expose a friendly accessor tree for fixed schema fields:

```lua
profile.Data.Currency.Coins:Increment(100)
profile.Data.Progression.Level:Set(2)
profile.Data.Inventory.Items:Observe():Subscribe(function(items)
	renderInventory(items)
end)
```

Returned table values and snapshots are cloned/frozen so callers cannot mutate
the authoritative profile by accident. `Delete` is allowed for
`Schema.Optional(...)` fields and rejected for required fields.

## Client API

`PlayerDataServiceClient` wraps the local player's replicated state id.

```lua
playerDataClient:IsReady()
playerDataClient:PromiseReady()
playerDataClient:Get("Currency.Coins")
playerDataClient:GetSnapshot()
playerDataClient:Observe("Currency.Coins")
playerDataClient:ObserveSnapshot()
playerDataClient:ObserveSelector(function(data)
	return data.Progression.Experience
end)
```

Client code can use the same accessor style:

```lua
playerDataClient.Data.Currency.Coins:Observe(function(coins)
	coinsLabel.Text = tostring(coins)
end)
```

`Get` and `GetSnapshot` raise if called before readiness. Observers may be
created before readiness and emit once the initial replicated state arrives.
The client has no general write API.

## Reconciliation And Migrations

Loading order:

1. Load `Profile.Data` and `Profile.Metadata.SchemaVersion` through Nevermore.
2. For new profiles with no saved data, deep-copy the current template.
3. For existing profiles, run required migrations in ascending order.
4. Reconcile missing fields.
5. Log and replace structurally incompatible saved values with template values.
6. Validate the completed profile.
7. Commit `Profile.Data` and the current schema version into Nevermore's stage.
8. Create owner-only replicated state.

Unknown saved fields are preserved for compatibility, but new writes or changes
to unknown schema paths are rejected.

## Replication

Only fields wrapped in `Schema.Owner(...)` or listed in the legacy
`Replication.Owner` section are sent to the owning player. Metadata, receipt
state, anti-cheat fields, and anything not explicitly listed remain server-only.

Projection updates are path-aware: mutating a parent table does not leak private
sibling fields because replication diffs are computed against the filtered
projection, not the raw profile.

## Failure Policy

A datastore, migration, or validation failure never creates a new profile over
existing data. The default load failure handler kicks the player with a generic
message. Games can provide their own safe policy:

```lua
playerDataService:SetLoadFailureHandler(function(player, failure)
	player:Kick("Your data could not be loaded. Please rejoin.")
end)
```

## MVP Limits

- Derived replicated fields are not included yet.
- Offline profile handles are not included yet.
- Cross-player/public profile replication is not included yet.
