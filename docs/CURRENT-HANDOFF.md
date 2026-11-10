# Room in the Cart — current handoff

Updated November 10, 2026. Active goal: finish the complete first release, Foundation2.1's52 requirements,27 screen contracts andB11. Not complete or paused. Read [APP-BASELINE](product/APP-BASELINE.md), [Foundation](product/foundation-gen2.1/README.md), [MASTER-GENERATION](product/MASTER-GENERATION.md), [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md) and [RELEASE-EXECUTION](RELEASE-EXECUTION.md). Component passes do not establish one qualified release candidate.

## Workspace and execution ownership

- Canonical repository: `/Users/palatis/Room in the Cart`, local branch `codex/parallel-ios-ci`; ambient Spanish diagnostic worktree is stale.
- Publish non-force to `codex/combined-candidate-20261109`. Latest verified remote head: `da8c893c3f092f9f90204c1443cf98d93c6bd417`; local documentation successor4277024c. The current SQL fix and expanded wire tests are qualified and being saved as the next local commit.
- No Dot/Lumpy. Astra High helpers prepare substantive scratch changes; Sol6.1 Extra High handles monitoring/preparation. Root reviews, integrates, commits and dispatches; root owns the sole local native/database slot.
- **No live local native/database run.** Session83800 is terminal PASS: `.build/SharedDemandGraphNov09/root-tracking-native-wire-r2`, all19Node/60Swift cases. Root verified366source files,151compiled entries and243result entries. PostgreSQL stopped and successful private state was removed. The execution freeze is released; do not repeat this unchanged passing run.
- Preserve first failures, private failed fixtures and unrelated untracked evidence. Stage named paths only. Keep8GiB reserve; latest disk check150GiB free.

## Latest completed qualification

- **Tracking history correction:** explicit household/shop/operation joins fix PostgreSQL duplicate-shop_id failure. Two new HTTP regressions cover empty/retained/reversed history, content-free response and shop/tenant/role isolation. Fresh strict TypeScript,753offline passes plus1expected skip,352PostgreSQL passes plus3expected browser skips; no failures.267source inputs and151compiled entries unchanged; database stopped and successful private state cleaned. [Proof](evidence/service/tracking-history-20261110/backend-verification.json).
- **Tracking native client:** installed typed read/write contracts, six intents, complete acknowledgments, distinct partial-freeze review, durable lost-reply/relaunch retry and scoped access-loss cleanup. Fresh package190passes+3expected wire skips. Generation/lease and conditional outbox removal tests protect later sessions and same-shop work. [Proof](evidence/native/tracking-write-contract-20261110/README.md).
- **Prior real wire:** creation successor16Node/50Swift passed with zero failures/skips. New tracking wire extends this to19/60. First tracking run passed18Node/58Swift, failed history GET503, and did not reach rebind; all original sources/results and stopped private fixture retained. The corrected r2 passes all19Node/60Swift with zero failures/skips using the unchanged wrapper and a fresh Swift build. [Wire proof](evidence/service/tracking-history-20261110/native-wire-verification.json). [First fault](evidence/service/tracking-history-20261110/first-fault.json).
- **Prior app/UI:** new-meal creation has fresh app/model/UI compilation, its model and bothEN/ES journeys passing. Earlier174models and sixEN/ES Undo/Meal/Quote journeys remain separately scoped fixture qualification. Original-resolution review disproved suspected label/value overlap. [Creation UI proof](evidence/native/created-meal-undo-20261110/ui-verification.json). No final combined app/UI or authenticated mixed-device acceptance is claimed.

## Next integration work

1. Preserve the qualified SQL/wire commit; current19/60result needs no unchanged rerun. Continue the composed backend and native UI successors below.
2. Review the frozen request/compound backend proposal, then install and qualify it as one composed change. `request-acceptance-repository-r1` owns14paths including048 and composed HTTP/demand hooks; strict compile and202pure/mock controls passed in its earlier composed snapshot,17HTTP cases are prepared but unexecuted. The final compound owner packet separately passes67focused controls and adds15HTTP cases; combined full execution is still required. Four dependency modules belong to `compound-tracking-undo-r1`; skip overlapping owner HTTP/demand whole-file versions. Do not apply obsolete domain-r1 patch. Editor/release agents coordinate exact pins; initial-adoption public action catalog must be real authenticated UI input, never test-only enumeration.
3. `astra_tracking_native` owns scratch `native-tracking-flow-r1`, dedicated request Undo transport/UI, and strict history reviewRoute successor. Full existing catalog adoption, preserved unknown/protected facts, current authority, complete changes/checkout disclosures, recovery and exact durable retry are required. No partial-v2-to-complete-v1 projection or generic unbinding. `astra_editor_review` independently reviews the source while root executes.
4. Hosted diagnostic correction is under review in `direct-inventory-r2` (245portable controls in scratch). Original budgets/readiness gates remain; r1 would have rejected local1174.9.2, so r2 adds explicit hosted-only opt-in and preserves local launcher behavior. Root still needs to review/install/qualify it. No unchanged hosted rerun.

## Hosted and minimum-iOS status

[42777206111](https://github.com/palatis3/room-in-the-cart/actions/runs/42777206111) is terminal failure at exactda8c893c after585Linux controls. Bootstatus succeeded160.498s; post-boot scoped runtime query exhausted its30s budget, including14.080s startup acquisition, with zero output. Capture/new readiness probe never ran. Root verified originalZIP19/TAR24members and50committed source contents; all8cleanup commands exited0 and owned device deletion passed. [Proof](evidence/ci/helper-lifecycle-acquisition-20261110/hosted-42777206111-verification.json). Earlier42774882605 reached capture but failed the original15s readiness gate; neither result qualifies performance. No measured baseline approval yet.

Minimum-iOS Spanish XCTest callback fault remains open. Approved Apple report showed Sent with three attachments; feedback ID/transfer completion was not observed. Do not resubmit or repeat unchanged. The separate17.5 study does not prove17.0 cause equivalence. [Fault](evidence/native/minimum-os-first-fault-20261109/README.md), [host feasibility](evidence/ci/minimum-os-host-feasibility-20261109/README.md).

## Remaining release boundaries

Staging approval only through041. Local042–047 and pending048 need reviewed rollout and verified restore; they are not deployed. Paid Apple membership/signing, SMTP and KWS activation are owner deferred; do not repeatedly request. Operator Venture House Group LLC; support hello@roominthecart.com.

Still required: complete shared-food/request/adoption/store inverses and screens, actual048 signed restore erasure replay, portable shared Records/export and guardian/managed recovery; authenticated mixed-device/provider lifecycle; operational restore/alerts; physical iPhone features; humanEN/ES accessibility; actual mailbox/policy operation; signed TestFlight/billing/App Store gates. Follow [CI-VALIDATION](CI-VALIDATION.md), freeze one combined commit and run complete regression before merge. No release authority follows merely from green CI.

Historical evidence remains in its original locations and git history. The pre-consolidation handoff is retained locally at `.build/HandoffNov10/before-tracking-history-consolidation.md`.
