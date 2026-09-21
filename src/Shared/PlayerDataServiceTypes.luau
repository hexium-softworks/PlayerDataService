--!strict
--[=[
	Shared public types for PlayerDataService.

	@class PlayerDataServiceTypes
]=]

local PlayerDataServiceTypes = {}

export type PathSegment = string
export type Path = string | { PathSegment }
export type NormalizedPath = { PathSegment }
export type PlayerDataSnapshot = any

export type Migration = (data: any) -> any
export type Validator = (value: any, data: any?) -> (boolean, string?)
export type Checker = (value: any) -> (boolean, string?)

export type PlayerDataSchema = {
	Version: number,
	Template: any,
	Migrations: { [number]: Migration }?,
	Replication: {
		Owner: { Path }?,
	}?,
	Validators: { [string]: Validator }?,
}

export type PlayerDataFieldOptions = {
	Min: number?,
	Max: number?,
	MaxLength: number?,
}

export type PlayerDataAccessor = {
	Get: (PlayerDataAccessor) -> any,
	Set: (PlayerDataAccessor, any) -> (),
	Update: (PlayerDataAccessor, (any) -> any) -> (),
	Increment: (PlayerDataAccessor, number?) -> (),
	Delete: (PlayerDataAccessor) -> (),
	Observe: (PlayerDataAccessor) -> any,
}

export type PlayerDataFailure = {
	Kind: string,
	Player: Player?,
	UserId: number?,
	StoredVersion: number?,
	TargetVersion: number?,
	MigrationVersion: number?,
	Cause: any?,
}

export type PlayerDataTransaction = {
	Set: (PlayerDataTransaction, Path, any) -> (),
	Update: (PlayerDataTransaction, Path, (any) -> any) -> (),
	Increment: (PlayerDataTransaction, Path, number?) -> (),
	Delete: (PlayerDataTransaction, Path) -> (),
}

export type PlayerProfile = {
	Get: (PlayerProfile, Path?) -> any,
	GetSnapshot: (PlayerProfile) -> PlayerDataSnapshot,
	Set: (PlayerProfile, Path, any) -> (),
	Update: (PlayerProfile, Path, (any) -> any) -> (),
	Increment: (PlayerProfile, Path, number?) -> (),
	Delete: (PlayerProfile, Path) -> (),
	Batch: (PlayerProfile, (PlayerDataTransaction) -> ()) -> (),
	Mutate: (PlayerProfile, (any) -> ()) -> (),
	Observe: (PlayerProfile, Path?) -> any,
	ObserveSnapshot: (PlayerProfile) -> any,
	GetPlayer: (PlayerProfile) -> Player,
	IsActive: (PlayerProfile) -> boolean,
	PromiseSave: (PlayerProfile) -> any,
	Destroy: (PlayerProfile) -> (),
	Data: PlayerDataAccessor,
}

return PlayerDataServiceTypes
