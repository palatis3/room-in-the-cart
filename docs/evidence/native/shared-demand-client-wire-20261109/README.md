# Typed shared-demand client and real wire checks

The native client now reads canonical shared-food totals, previews typed source
changes, and persists the reviewed action in the existing operation outbox. Apply
and relaunch retry retain the exact command bytes, actor, device, shop, preview,
base and reserved operation identity. Required nulls remain distinct from absent
fields; quantities remain reduced Int64 strings. The service remains the single
allocation calculator. No shared-demand UI or deployment is claimed here.

Root independently verified the 12 owned source files and the original 305-file
execution snapshot. Isolated TypeScript and Swift compilation passed. Package
tests passed 114 cases with three expected database-only skips, including six new
client cases. The original full wire attempt passed all eight pre-existing Node
cases and 15 Swift scenarios, then exposed a failure in the new Apply fixture.

The fixture's request logger switched the body into flowing mode before the API
finished authentication. Two small delayed-reader controls reproduced the lost
body and verified the correction. The retained operation itself passed both
original command schemas. Production Swift did not change.

The focused successor used the same verified compiled Swift client and a fresh
database. All eight demand phases passed: adoption Cancel, Apply with a lost reply
and exact durable retry, stale second device, targeted removal, compensating Undo,
request Apply, contributor denial and privacy revocation. Root checked every
scenario receipt and stream hash. The attempt took 19.518 seconds without another
compile; its database stopped and its private fixture state was removed.

Preserved attempts under `.build/SharedDemandGraphNov09/`:

- `root-wire-r1`: original build, package passes and original fixture failure.
- `root-wire-r2`: root's focused adapter still selected unrelated integration
  files. It was stopped before any demand Swift case ran; its database is stopped.
- `root-wire-r3`: corrected file selection and all eight successful phases.
- `swift-wire-r1` and `swift-wire-r2`: reviewed source, patches, manifests,
  schema proof and offline controls. Original failures remain unchanged.

The first two attempts retain private local state outside public evidence. No
keys, raw commands or private fixtures are committed. The compact
`verification.json` binds the sources and retained receipts. These scoped passes
do not represent a complete combined-revision CI pass. Native UI, downstream
projections, shared export/import and the remaining release gates are still open.
