# Shared-demand persistence: local verification

The shared-demand graph now persists through the original household command
transaction. Migration 043 adds tenant-isolated revisions, bound expiring previews,
server-derived source provenance and privacy erasure. Preview/Apply, exact retry,
conflict-aware Undo, source removal, reviewed pack capacity and protected unknown
quantities retain their original identities. Legacy shops remain unchanged until
explicit adoption; adopted shops reject unreviewed pack-only writes.

Privacy tests cover copied labels, pending previews held by another shopper,
historical snapshots, direct and reconciled placement, and an actual private
dump/restore with signed-journal replay. An erased frozen shop can reopen for fresh
review; its erased snapshot cannot regain placement authority. Unrelated committed
contributions remain intact. The service contract is
[shared-demand-api.md](../../../../shared/contracts/shared-demand-api.md).

## Verified scope

- Clean isolated TypeScript build passed. All 63 final TypeScript inputs match it.
- 527 offline tests passed, zero failures, one expected database-only skip.
  The 54 pure domain tests are included in that total.
- 281 PostgreSQL tests passed, zero failures, three existing optional browser
  skips. The 21 shared-demand cases are included in that total; billing's database
  check runs here.
- A real 2,000-source graph used 58 runtime queries for adoption and 59 for unchanged
  review, below the 120-query bound per preview/Apply. This is query-count evidence,
  not a production latency or capacity claim.
- Root independently verified all 14 canonical source files (bytes, sizes and
  modes), all 112 final database-run inputs, 21 frozen package payloads and seven
  retained proof files. Canonical service/dist was not rebuilt by these tests.

The private originals remain under
`.build/SharedDemandGraphNov09/persistence-freeze-r1/` and the sibling attempt
directories. [source-manifest.json](source-manifest.json) identifies the exact
implementation; [verification.json](verification.json) binds the retained logs and
review package. Private databases, keys, journals and dumps are not public evidence.
All owned test databases are stopped. Failed attempts remain preserved, including
the initial serialization defect, test-fixture alias error, legacy no-data erasure
regression and omitted isolated fixtures; later passes did not overwrite them.

## Remaining acceptance

This completes a local persistence boundary, not the full shared-demand feature.
Swift DTO/client and real HTTPS mixed-client proof, native typed entry and
review/Cancel/Apply/relaunch, protected binding and restriction-mapping UI,
mixed-device changes, protected transfers, scoped downstream projections, and
shared export/import recovery remain required. No native acceptance, performance
baseline, hosted deployment, signing or provider activation is claimed here.

Migration 043 is local only; staging authorization remains through 041. Once a
shop adopts a graph, an older server without its writer and privacy fences is not
a safe rollback. Preserve history and roll forward or stop affected writes.
