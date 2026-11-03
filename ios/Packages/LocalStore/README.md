# LocalStore

B01 local comparison storage, using Foundation and the operating system SQLite library.
Swift tools 5.9; iOS 17 and macOS 13 deployment floors. No third-party dependencies.

```swift
let store = try ComparisonStore(url: databaseURL)
let saved = try await store.save(
    id: comparisonID,
    title: "Rice packs",
    payload: encodedComparison,
    savedAt: injectedClock.now
)
let records = try await store.list()
let reopened = try await store.load(id: saved.id)
```

Create the containing directory before opening the store. On iOS, assign that directory
`FileProtectionType.completeUntilFirstUserAuthentication` before opening SQLite so rollback
journals inherit protection. The store applies the same protection to the database file.
The composition root should use a private application-support path per persona; this is not
an App Group database, sync queue, household authority store, or backup importer.

The persisted installation workspace UUID is `store.workspaceID`. `SavedComparison` exposes
`id`, `title`, `payload`, `savedAt`, and an `Int64` `revision`. Payload is opaque `Data` up to
1 MiB; the feature owns its semantic Codable model and version. LocalStore adds a versioned
envelope. Titles are bounded to 4,096 UTF-8 bytes and dates must be finite.
Dates are stored as reference-epoch seconds, preserving Foundation `Date` precision exactly.

A changed save appends a complete immutable revision and updates its head in one immediate
transaction. An identical title/payload retry returns the original revision and timestamp.
An actor serializes calls; SQLite locking serializes independent connections. Foreign keys,
full synchronous writes, and fullfsync are enabled. The default rollback journal is used.
`close()` supports controlled replacement and deterministic close/reopen verification.

Schema v0 means an empty database. Its transactional migration creates schema v1 and one
random workspace UUID. Unknown unversioned files and future schemas are rejected without
resetting the database. Corruption and unsupported envelope versions surface as errors;
records are never silently discarded. Error messages exclude record contents and paths.

Run `swift test` from this package. Tests use real temporary SQLite files and deliberately
abort head mutations to verify rollback of previously inserted revisions. They also cover
reopening, schema migration, future-schema preservation, immutable history, concurrent
retries, bounds, corruption, independent workspaces, and parameterized SQL.
