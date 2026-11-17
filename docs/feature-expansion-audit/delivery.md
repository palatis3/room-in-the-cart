# Independent delivery recheck — draft v2

Verdict: **approved as an implementation plan from the delivery perspective**. No unresolved material delivery finding. Approval is for the plan's contracts and sequence, not evidence that features, migrations, integrations or release gates already pass.

Reviewed immutable SHA256 `491d032c7f246c89de6d02d677bf2e35c527ff7cbcf2b9a0717fe628c1c2b813` against v1, the prior source inspection at `e06bde5cf463fd299deefed456f94f0cefcaeb73`, and delivery-v1 findings. No implementation, tests, provider changes or CI dispatches.

## Findings resolved

- **P1 durable projection replay:** §2 now correctly says `change(key:)` is not restart-durable idempotency. It requires a ledger-side receipt/result binding in the same transaction as the exact payload, stable inventory operation/scope/digest identity, receipt lookup before stale-base rejection, current-head reload and no recreation of a subsequently edited/deleted effect. It explicitly tests process death between ledger COMMIT and inventory completion, changed-body replay and erasure/replacement. This resolves the concrete lost-acknowledgment duplication risk in the plan.
- **P2 FoodKeeper dependency:** H1 now delivers matching/package use and manual/date-based use-soon without FoodKeeper; H2 retains the honest content-verification gate for estimates. L can use H1's real explicit status. Other feature delivery need not wait for the unresolved reference download, and #3 is not falsely marked complete.
- **Sizing recommendation:** C has an authority/conservation versus request-UX boundary; J1–J4 now have distinct usable outcomes. The table is explicitly workstreams rather than a mandatory twelve-PR schedule. This permits focused reviews without either an app-wide branch or speculative infrastructure-only scaffolds.

## Added contracts assessed

The revision strengthens, rather than changes direction on, legacy stock migration: live claims, exact pins, all carryover phases, source-head-bound cutover, conservative unresolved holds and disabled old writers are explicit. It also clarifies that ComparisonStore opens unrelated comparison databases, uses monotonically increasing schemas for later table additions, and activates inventory ownership only at the pickup composition root. These are necessary compatibility obligations for this design.

The non-shop shared schema now names authority scope, grant epochs, batch/event identities and preserved legacy constraints. The initial implementation remains a significant slice and needs the focused database/native-wire/old-client tests already required. No separate sync engine or broad datastore rewrite is newly introduced. Compound stock/meal authority and private price visibility remain explicitly separated.

Native-first capture/import, bounded provider adapters, optional OFF, verified-reference estimates, iOS 17 compatibility, actual protected summary widgets and local-first CI remain appropriately constrained. The final exact-candidate qualification and owner-deferred external setup stay separate. PR10's final merge identity still needs recording before implementation starts; this recheck does not substitute for merge review.

## Nonblocking editorial cleanup

Several inserted v2 paragraphs retain a literal leading `+` (lines 24–47, 78–83, 182–183), including `+### #1`, which prevents that heading from rendering normally. Remove those patch markers before presenting the final document. This is formatting only; no substantive re-review is needed for marker removal plus accurate final-baseline/review-status updates. Preserve this immutable reviewed v2 and report the final artifact's hash separately.
