# Shared-food adoption and protected identity clarification

The shopper can read the exact existing meal and accepted-request sources before
adopting shared food tracking. Stable IDs, accepted request revisions, original
quantity wording, exact rational meal amounts and unresolved restrictions survive.
The same server enumeration supplies the catalog and validates preview/apply.
Revoked request-author access prevents returning private source text.

An explicit `clarifyReservationProductIds` intent allows a protected reservation's
unknown product identity to be confirmed. Every other field must remain identical;
unlisted changes and replacement of an already known identity fail. Undo cannot
erase that accepted protected identity. Review/Undo requests cannot smuggle this
intent into an otherwise empty change.

One isolated combined source compiles and passes **569 offline tests** (one
expected database-only skip) and **285 PostgreSQL tests** (three existing optional
browser skips), with zero failures. Actual HTTP scenarios cover source adoption,
preview cancellation, protected identity confirmation alongside a new source,
exact persisted facts/totals and rejected review/Undo misuse. An independent
read-only review found no concrete defects in the source enumeration refactor.

The first PostgreSQL attempt retained two fixture failures: a missing Foundation
routing JSON and a new test that had not explicitly confirmed matching products.
The successor includes the required asset and explicit fixture confirmation. The
standard database harness now checks that asset before connecting or mutating a
fixture; twenty harness controls pass as part of the offline suite. The successor
also checks it before local initdb.

Originals remain under `.build/SharedDemandLegacySourcesNov09/` (compile-r1/r2,
postgres-r1 and combined-r1), with protected-domain negative controls under
`.build/ProtectedReservationProductClarificationNov09/r1/`. Private fixture state
remains owner-only outside committed evidence. Verification binds source, compiled
output and receipts; no credentials, database dump or raw archive are published.

No staging deployment, native UI acceptance, combined release qualification or
App Store readiness is claimed. Migration043 remains local. Existing shared meal,
request and quote editors still need complete graph-aware integration.
