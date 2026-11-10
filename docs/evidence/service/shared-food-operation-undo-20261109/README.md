# Complete shared-food operation Undo — bounded backend slice

Eligible newly recorded draft patches can now reverse their complete graph,
basket, pack and quote effects together. The server derives the inverse from
validated historical references, preserves later untouched work and rejects
conflicts. History and candidate reads create no operation; explicit preview
supplies pack acknowledgments before the existing exact Apply/retry path.

The complete backend regression passes **625 offline tests and 300 PostgreSQL
tests**, including all eight new HTTP cases. One database-only offline case and
three optional browser cases remain explicitly skipped. The verified compiled
service was reused with all 243 source inputs unchanged. The original privacy
journal harness fenced successfully, and the owned PostgreSQL instance stopped.
Private fixture state remains local in a 0700 directory.

Review found and corrected both pricing-provenance directions: historical prices
cannot borrow a later quote, and an old quote cannot relabel later prices or
priced lines. Four new negatives reproduce the latter defect against frozen r1;
the corrected r2 retains budget-only changes and untouched pack counts. Its 129
focused controls and the complete regression above pass. No source preimage or
partial inverse comes from the client.

Migration 044 was applied only to the isolated fixture. Staging is unchanged.
Native client/UI acceptance is pending. Meal/proposal/date changes, request
acceptance, first-adoption batches, selected-store review effects, expired-price
replacement and inverse-of-inverse remain explicit unsupported scopes requiring
further work; this is not complete D02/D08 acceptance. History still has bounded
per-target evidence queries that need batching before UI release.

[Exact scope, cases and hashes](verification.json). Original candidate and first
failures remain under `.build/SharedDemandGraphNov09/operation-undo-r1` and `r2`.
