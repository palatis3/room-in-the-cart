# Independent shared Records v2

Foundation 2.1 D15, S20, F07, N06. This slice is a current-shop snapshot and
independent recovery representation, not history replay, a helper grant or
household reattachment. It does not complete guardian-managed recovery.

## Service and scope

`GET /v1/households/:household/shops/:shop/records/snapshot/v2` runs inside the
existing authorized household transaction. It requires the currently assigned
adult shopper before reading any private contents; helpers, children and other
planners are denied, even when they hold a paid seat. Assigned shoppers already
have current-shop budget authority. No partial-budget alternate projection or
period aggregate is returned. There is no entitlement gate.

The existing `/records/snapshot` selects v2 when trackingV2 is enabled, otherwise
retains its v1 behavior. Explicit `/records/snapshot/v1` keeps all existing v1
partial-state, integrity and erasure gates. `/records/tracking-snapshot` is the
existing internal live projection (`portableExportAllowed:false`), unchanged.
Neither new client nor reader downgrades a failed v2 read to v1.

The reader rechecks the current source catalog (including request authors and
consent), current graph and source meals under the lock. Erased projections must
match that current catalog, not their previous cached assertion. Prior erased
pack reviews never return. Pure projection rejects mismatched revision, digest,
partition, source scope, source meals and extra schema fields.

## Independent record

The envelope contains schemaVersion=2, asOf (observation only), recordDigest
(tracking canonical SHA-256) and record. The record uses fixed projection
`assigned-shopper-independent-record-v2`, origin household/shop IDs, shop revision,
privacy revision, phase, store-review state, exact quote and meal occurrences.
Food contains exact graph, basket, source catalog, bindings, unbound facts and
transferred assertions, legacy basket IDs, pack review and coverage. No quantity
or pack count is inferred. Protected unknown and unbound quantities remain
unknown/unbound, never free supply; tracked subtotals do not establish complete
food coverage. Review-required pack values and coverage are null. Legacy review
is explicitly notRecorded with an empty pack array.

Allowlisted data excludes actor/device IDs, credentials, memberships, guardian
consent evidence, grants, entitlement, authorityEpoch, quote/basis digests,
preview/candidate/review tokens, replay windows, command bodies and operation
receipts. Stable food/reference IDs are provenance, not authorization. Archived
bytes are not accepted by any mutation or session-binding API.

This current snapshot supplies no historical save timestamp or verified parent
revision. Native archives use savedAtMilliseconds=0 and parentRevision=nil;
never label asOf as save/sync/export time or invent revision ancestry. Full
historic sent copies, approvals, fills, credits and lineage are outside this
slice and remain separate required Records work.

## Native and archive integration

`HouseholdService.sharedRecordSnapshot` refreshes shopper authorization and checks
session generation/selected scope before and after the explicit v2 read. DTOs
reject unknown nested fields and invalid partitions. `SharedIndependentRecord`
is separate from live tracking types and exports canonical allowlisted bytes.
The carried service digest is informational (same policy as existing tracking
client); archive integrity uses ArchiveCodec's canonical payload digest.

RecordsComposition requests the selected shared shop during existing listing and
export refresh, rechecks the existing private-view lease, and omits it with an
unavailable row on failure. It never falls back to a cached shared projection.
Native .sharedShop records use origin household+projection, source shop ID, and
`shop-N-privacy-P` revision; observation time is not part of identity. All parsing,
staging, preview, AES-GCM encryption, dedupe, sibling/conflict quarantine, local
known-erasure markers and independent persistence reuse RecordArchive and
RecoveryRegistry. .sharedShop refuses generic helper projections. Readable owner
copies and recovered viewing are read-only. No live shop store, household grant
or replay queue is created during recovery.

A received file is untrusted evidence even when it has a valid digest. Current
server erasure reconciliation and managed recovery must be integrated separately
before household reattachment; this slice does not attach recovered copies.
The existing registerErasedSources/registerErasedOrigins APIs block known local
erasures. Automatic reconciliation of remote erasure into saved independent
shared copies is not implemented here and must not be claimed.

## Remaining guardian surface

Enrollment/consent and child request submission are not guardian record access.
Required follow-on work: a provider-verified current guardian-to-child relation;
explicit child/household/request scope authorization independent of shopper or
paid-seat status; child-only redacted export with no household money or other
children's data; correction/delete reviews with provenance and dependent food
revalidation; immutable independent recovery identity/diff/conflict; current
withdrawal/deletion checks and local erasure reconciliation before showing or
reattaching any recovered data. Imports must never reestablish consent, enrollment,
child credentials, household membership or a request mutation grant. Require
actual authorized/unauthorized guardian, withdrawn consent, erased source and
repeat-import tests plus provider-backed acceptance. None are implied by v2 here.

## Qualification

Scratch TypeScript build and 26 focused Node tests passed (12 new, 14 existing).
New native DTO/read tests and archive/Records tests are prepared, not run.
The existing real-PG tracking test now requires inert v2 export in partial state
and keeps explicit v1 denial. It is prepared, not run. Root must qualify actual
service/PG, native package/app/model/UI builds, EN/ES export/import and conflict/
erasure journeys against one exact source identity. No deployment or release
claim follows from the scratch checks.
