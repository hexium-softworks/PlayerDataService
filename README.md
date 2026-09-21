# PlayerDataService

Schema-driven player data for Nevermore Roblox games.

`PlayerDataService` is a high-level wrapper around Nevermore's
`PlayerDataStoreService`. It does not replace Nevermore's datastore system.
Instead, it uses Nevermore for the hard persistence work, then adds a small,
game-agnostic layer for schemas, migrations, validated writes, active profile
objects, and owner-only replication.

## What It Adds

- Template-first schemas with simple field helpers.
- Reconciliation for missing or structurally invalid saved data.
- Versioned migrations before data is exposed to game code.
- Runtime validation for every write.
- Active server profile objects with path APIs and accessor trees.
- Read-only client access to replicated owner-visible fields.
- Owner-only replication through `ReplicationService`.
- Isolation inside one configured Nevermore datastore namespace.

## What Nevermore Still Owns

This package intentionally keeps Nevermore in charge of persistence mechanics.
Internally, the server service loads data with:

```lua
serviceBag:GetService(PlayerDataStoreService):PromiseDataStore(player)
```

That means Nevermore still owns:

- the underlying Roblox datastore connection
- per-player datastore sessions
- session locking behavior
- autosave behavior
- save retries
- shutdown save handling
- datastore mocks via `PlayerDataStoreService:SetRobloxDataStore()`

`PlayerDataService` only works inside the configured namespace of the returned
Nevermore datastore. By default, that namespace is `Profile`.

```lua
{
	Profile = {
		Data = {
			Currency = {
				Coins = 100,
			},
		},

		Metadata = {
			SchemaVersion = 2,
		},
	},

	Settings = {
		-- owned by another package
	},
}
```

Normal profile mutations write through Nevermore `DataStoreStage` substores, so
changing `Currency.Coins` stores only that nested value. Whole-namespace writes
are reserved for the initial migration/reconciliation commit.

## Install

```sh
pnpm add @hexium-softworks/playerdataservice
```

The package is designed for Nevermore `ServiceBag` projects and expects
Nevermore datastore packages plus `@hexium-softworks/replicationservice`.

## Quick Start

Create a schema module:

```lua
local Schema = require("PlayerDataSchema")

return Schema.define({
	Version = 1,

	Template = {
		Currency = Schema.Owner({
			Coins = Schema.Int(0, { Min = 0 }),
			Gems = Schema.Int(0, { Min = 0 }),
		}),

		Progression = Schema.Owner({
			Level = Schema.Int(1, { Min = 1 }),
			Experience = Schema.Int(0, { Min = 0 }),
		}),

		Internal = {
			LastReceiptId = "",
			PurchaseHistory = {},
		},
	},
})
```

Configure the server service before `ServiceBag:Start()`:

```lua
local require = require(script.Parent.loader).load(script)

local PlayerDataService = require("PlayerDataService")

function GameDataConfiguration:Init(serviceBag)
	self._playerData = serviceBag:GetService(PlayerDataService)
	self._playerData:SetSchema(require("GamePlayerDataSchema"))
	self._playerData:SetNamespace("Profile")
end
```

Use the loaded profile on the server:

```lua
local profile = playerDataService:GetProfile(player)
if not profile then
	return
end

profile:Increment("Currency.Coins", 100)
profile.Data.Progression.Level:Set(2)
```

Read replicated owner-visible data on the client:

```lua
playerDataClient.Data.Currency.Coins:Observe(function(coins)
	coinsLabel.Text = tostring(coins)
end)
```

## Key Concepts

### Schema

The schema is the contract for the data this package owns. It defines:

- `Version`: the current saved data version.
- `Template`: the default shape for valid profile data.
- `Migrations`: optional versioned transforms for older saved data.
- validation rules for individual fields.
- which fields may replicate to the owning player.

Plain template values are persisted and server-only by default. A field must be
wrapped in `Schema.Owner(...)` to replicate to the owning client.

### Profile

A profile is the active server object for one loaded player. It is not a raw
table. It is a safe wrapper that validates changes, persists changes into the
Nevermore data stage, emits observers, and patches replicated state.

### Path API

Every profile supports string paths:

```lua
profile:Get("Currency.Coins")
profile:Set("Currency.Coins", 50)
profile:Increment("Currency.Coins", 5)
```

Paths are useful for dynamic systems such as inventory items, quest ids, and
other data where static accessor names are awkward.

### Accessor Tree

For fixed schema fields, profiles and clients also expose safe accessors:

```lua
profile.Data.Currency.Coins:Increment(5)
playerDataClient.Data.Currency.Coins:Observe(function(coins)
	print(coins)
end)
```

Accessors are wrappers over the same path API. They are not raw mutable data
tables. Field names that collide with accessor methods, such as `Get`, `Set`,
`Observe`, or `Increment`, are rejected during schema validation.

### Reconciliation

When saved data loads, the package reconciles it against the current template:

- valid existing values are preserved
- missing fields are added from the template
- unknown saved fields are preserved for compatibility
- arrays are treated as complete values
- structurally incompatible values are logged and replaced with template values

New writes to unknown schema paths are rejected.

### Migrations

Migrations run before reconciliation. A migration with key `[2]` transforms data
from version `1` into version `2`.

```lua
Migrations = {
	[2] = function(data)
		data.Currency = data.Currency or {
			Coins = data.Coins or 0,
			Gems = 0,
		}
		data.Coins = nil
		return data
	end,
}
```

Migrations run in ascending order until the saved profile reaches the current
schema `Version`. If a required migration is missing or throws, loading fails
and the stored schema version is not advanced.

### Replication

Replication is opt-in. Only owner-visible fields are projected:

```lua
Currency = Schema.Owner({
	Coins = Schema.Int(0, { Min = 0 }),
	Gems = Schema.Int(0, { Min = 0 }),
}),

Internal = {
	LastReceiptId = "",
},
```

The owning client can read `Currency`, but cannot see `Internal`.

Replication patches are computed from a filtered projection, not the raw profile
table. This prevents private sibling fields from leaking when a parent table is
mutated.

### Failure Policy

Load, migration, or validation failures do not create replacement profiles over
possibly valid saved data. By default, the player is kicked with a generic
message. Games can install their own policy:

```lua
playerDataService:SetLoadFailureHandler(function(player, failure)
	player:Kick("Your data could not be loaded. Please rejoin.")
end)
```

## Schema Interface

### `Schema.define(config)`

Defines a schema.

```lua
Schema.define({
	Version = 2,
	Template = {},
	Migrations = {},
})
```

`Version` must be a positive integer. `Template` must be a table. `Migrations`
is optional.

### Plain Values

Plain values become persisted defaults and are server-only.

```lua
Template = {
	Internal = {
		LastReceiptId = "",
		PurchaseHistory = {},
	},
}
```

Valid datastore-safe values are supported: strings, numbers, booleans, arrays,
dictionaries, and nested tables.

### `Schema.Owner(value)`

Marks a field or subtree as visible to the owning player.

```lua
Currency = Schema.Owner({
	Coins = Schema.Int(0, { Min = 0 }),
})
```

All descendants inherit owner visibility unless a nested wrapper changes the
visibility.

### `Schema.ServerOnly(value)`

Explicitly marks a field or subtree as private server data.

```lua
Stats = Schema.Owner({
	Level = Schema.Int(1, { Min = 1 }),
	SecretRoll = Schema.ServerOnly(0),
})
```

Plain values are already server-only, so this is mainly useful inside an
owner-visible subtree.

### `Schema.Int(default, options?)`

Declares an integer field.

```lua
Coins = Schema.Int(0, { Min = 0, Max = 999999 })
```

Options:

- `Min`: minimum allowed value
- `Max`: maximum allowed value

### `Schema.Number(default, options?)`

Declares a finite number field.

```lua
WalkSpeedMultiplier = Schema.Number(1, { Min = 0.5, Max = 2 })
```

Options:

- `Min`: minimum allowed value
- `Max`: maximum allowed value

### `Schema.String(default, options?)`

Declares a string field.

```lua
DisplayTitle = Schema.String("", { MaxLength = 24 })
```

Options:

- `MaxLength`: maximum string length

### `Schema.Boolean(default)`

Declares a boolean field.

```lua
TutorialComplete = Schema.Boolean(false)
```

### `Schema.Enum(default, members)`

Declares a string field restricted to a known set of values.

```lua
Rarity = Schema.Enum("Common", { "Common", "Rare", "Epic" })
```

The default must be one of the members.

### `Schema.Optional(inner)`

Declares a leaf field that may be absent.

```lua
Nickname = Schema.Optional(Schema.String("", { MaxLength = 20 }))
```

Optional fields are not inserted into new profiles by default. Setting an
optional field to `nil` deletes it. `Delete` is only allowed for optional fields;
required fields cannot be deleted.

### `Schema.Dynamic(factory)`

Declares a field whose default is produced per profile.

```lua
CreatedAt = Schema.Dynamic(function()
	return os.time()
end)
```

The factory runs for new profiles and for missing dynamic fields during load.
The returned value must be datastore-safe.

### `Schema.Check(default, checker)`

Declares a field with a custom checker.

```lua
FiveStepValue = Schema.Check(0, function(value)
	return typeof(value) == "number" and value % 5 == 0, "Expected a multiple of 5"
end)
```

The checker receives the candidate value and returns:

```lua
boolean, string?
```

This works with checker libraries such as Osyris `t` if your game imports them.
`t` is intentionally not a dependency of this package.

## Raw Schema Compatibility

The older raw schema shape is still supported:

```lua
return {
	Version = 1,

	Template = {
		Currency = {
			Coins = 0,
		},
	},

	Replication = {
		Owner = {
			"Currency.Coins",
		},
	},

	Validators = {
		["Currency.Coins"] = function(value)
			return typeof(value) == "number" and value >= 0
		end,
	},
}
```

New code should prefer `PlayerDataSchema.define(...)` because visibility and
validation live beside the fields they describe.

## Server API

### Service

```lua
playerDataService:SetSchema(schema)
playerDataService:SetNamespace(namespace)
playerDataService:SetLoadFailureHandler(callback)
playerDataService:SetProfileReleasedHandler(callback)
playerDataService:SetReplicationEnabled(enabled)

playerDataService:IsLoaded(player)
playerDataService:GetProfile(player)
playerDataService:PromiseProfile(player)
playerDataService:ObserveProfile(player)
playerDataService:ObserveLoadedPlayers()
```

Configuration methods must be called before `Start()`.

### Profile

```lua
profile:Get(path?)
profile:GetSnapshot()
profile:Set(path, value)
profile:Update(path, callback)
profile:Increment(path, amount?)
profile:Delete(path)
profile:Batch(callback)
profile:Mutate(callback)
profile:Observe(path?)
profile:ObserveSnapshot()
profile:GetPlayer()
profile:IsActive()
profile:PromiseSave()
profile:Destroy()
```

`Get` returns cloned data. `GetSnapshot` and observer payloads return readonly
snapshots. Callers cannot mutate the authoritative profile table by editing a
returned value.

Use `Batch` when applying several path changes that should validate and commit
together:

```lua
profile:Batch(function(transaction)
	transaction:Increment("Currency.Coins", 500)
	transaction:Set("Progression.Level", 2)
end)
```

Use `Mutate` when the shape of the change is easier to express against a draft:

```lua
profile:Mutate(function(data)
	data.Currency.Coins += 100
	data.Progression.Experience += 25
end)
```

The draft is validated before it is committed. Unknown new schema paths are
rejected.

## Client API

`PlayerDataServiceClient` is read-only and targets the local player's replicated
state.

```lua
playerDataClient:SetSchema(schema)

playerDataClient:IsReady()
playerDataClient:PromiseReady()
playerDataClient:Get(path?)
playerDataClient:GetSnapshot()
playerDataClient:Observe(path?)
playerDataClient:ObserveSnapshot()
playerDataClient:ObserveSelector(selector)
```

`SetSchema` is optional, but useful when you want the client accessor tree to be
built from the same owner-visible schema paths as the server. It must be called
before `Start()`.

`Get` and `GetSnapshot` raise before readiness. Observers may be created before
readiness and will emit when the replicated state arrives.

The client has no write API.

## Lifecycle

For each player:

1. Nevermore opens or reuses the player's datastore session.
2. `PlayerDataService` reads `{Namespace}.Data`.
3. `PlayerDataService` reads `{Namespace}.Metadata.SchemaVersion`.
4. New profiles receive schema defaults.
5. Existing profiles run migrations.
6. Data is reconciled against the current template.
7. Validators run on the completed profile.
8. The completed data and current schema version are staged into Nevermore.
9. The active `PlayerProfile` is exposed on the server.
10. Owner-visible fields are projected into `ReplicationService`.
11. Later server mutations validate, stage nested writes, notify observers, and
    patch replicated owner-visible data.

When the player leaves, the active profile is released, replicated state is
destroyed, and Nevermore continues to handle the datastore session close/save
flow.

## Current Limits

- Derived replicated fields are not included yet.
- Offline profile handles are not included yet.
- Cross-player or public profile replication is not included yet.
- Accessor trees are runtime wrappers; generated static accessor types are not
  included yet.

## References

- Nevermore DataStore:
  https://quenty.github.io/NevermoreEngine/api/DataStore/
- Nevermore DataStoreStage:
  https://quenty.github.io/NevermoreEngine/api/DataStoreStage/
- Nevermore PlayerDataStoreService:
  https://quenty.github.io/NevermoreEngine/api/PlayerDataStoreService/
- Nevermore PlayerDataStoreHandle:
  https://quenty.github.io/NevermoreEngine/api/PlayerDataStoreHandle/
