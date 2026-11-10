# First-release execution checklist

This checklist orders the remaining work; it does not replace Foundation 2.1's
52 requirements, 27 screen contracts or B11 acceptance. The authoritative scope
is [the build contract](product/foundation-gen2.1/08-build.md) and the requirement
and route maps in [current acceptance](CURRENT-ACCEPTANCE.md). A successful merge
is one checkpoint, not release authorization. Updated November 10, 2026.

## Candidate identity and evidence

Before the final full CI batch, record the immutable source commit, configuration,
Xcode build, runtime/device, service deployment and migration state. Focused local
candidates additionally need a source manifest hash and product hashes. Do not
combine separate passing revisions into a claim that one candidate passed.

For every execution below, retain: exact candidate identity, case/requirement IDs,
executor, environment, date, expected result, actual result, evidence location and
hash, and next action. Use `not run`, `passed`, `failed`, or `owner deferred`.
Missing or indirect proof is not a pass. Keep sensitive backup/provider originals
in their approved private location; commit only redacted receipts and hashes.

## Execution order

| Gate | Next action and environment | Completion evidence | Current state / dependency |
| --- | --- | --- | --- |
| Targeted regression | Diagnose missing performance measurements and the repeated iOS17 XCTest logging crash; finish the combined Dinner/audio qualification. Root coordinates one investigation per cause. | Original selectors/assertions and strict validation pass on the preserved candidate; complete measurements before performance baseline approval. | In progress; focused core success does not cover the combined candidate. |
| Shared-food integration | Finish complete-operation Undo scopes, scoped projections and shared export/import; qualify the remaining native flows through original routes. | Native, real-service and UI evidence preserving exact sources, quantities, authority, Cancel and durable retry. | Creation Undo backend passes 736 offline/332 PostgreSQL tests with declared skips; native150+3 expected skips and app/model/UI compilation pass. Its expanded16-Node/50-Swift lane passes with zero failures/skips; both creation UI journeys and their model pass; original-resolution review found no confirmed label/value overlap. Prior174 native models, six EN/ES fixture journeys and15/45 real wire scenarios remain scoped historical proof. Tracking persistence r3 adds qualified17HTTP+1signedrestore and full753offline/350PG regression; tracking read contracts pass165client+3expectedskips. Request/adoption/store inverses, native tracking write/UI, portable authorization/recovery and authenticated mixed-device acceptance remain unfinished. |
| Combined integration | Exact reviewed Dinner/audio product inputs are installed locally. Finish remaining corrections, freeze one commit and run full CI/regression using CI-VALIDATION's exact-revision process. | Full gate and required security/dependency checks for that commit; no focused-scope substitution, unresolved failures or skipped required cases. | Local consolidation complete; final combined regression not run. |
| Merge | Recheck current branch protection, base freshness and resolved conversations against the qualified PR head. | GitHub required checks and merge state for the exact head. | Pending combined qualification. |
| Staging parity | Inventory current staging code/schema against the candidate; prepare any outstanding rollout and recovery evidence. | Deployment identity, migration checksums, smoke results and verified recovery receipts. | Verified approval scope through041; local042–047 and subsequent code need their separate reviewed rollout approval. Do not infer approval from this checklist. |
| Authenticated household | Execute shopper, second planner, cook and contributor scenarios across the native iPhone app and companion mobile web; exercise stale edits, reconnects and revoked grants. | Actual authenticated mixed-device task records with role/privacy outcomes and exact service/build identity. | Incomplete; public/synthetic page checks do not establish this gate. |
| Child/provider lifecycle | Configure actual guardian verification/notice and verify consent, withdrawal, scoped access and provider erasure with approved test identities. | Provider-backed records, denied unauthorized access and verified removal/reconciliation. | Real KWS activation/configuration remains separate; prepared integration and accepted terms are not activation evidence. |
| Recovery and alerts | Execute independent hosted restore and alert-delivery cases with approved private backup/key custody; verify operating-owner response. | Recovery target, data invariants, delivery and reconciliation receipts, and retrieval of the retained proof. | Earlier local/hosted rehearsals remain scoped; remaining operational scenarios require explicit evidence. |
| Physical iPhone | Use the signed candidate for camera/OCR, microphone/readback and audio routes, share/import, widgets, print and reminders; include denied permissions and interruptions. | Device/build-specific results for each promised path and typed/manual fallback. | Incomplete; simulator and mocked-provider checks are insufficient. |
| Accessibility and languages | Human US-English/US-Spanish walkthrough; VoiceOver, Switch Control, Dynamic Type and Reduce Motion across complete applicable routes. Attribute automated findings to visible elements before closure. | Tester/device/build/locale records; resolved findings or a documented product decision consistent with requirements. | Incomplete; sampled screenshots and catalog checks do not prove all routes. |
| Policies and support | Review final operator/privacy/retention/terms copy and verify support delivery and operating ownership. | Approved policy versions and actual contact/delivery evidence for hello@roominthecart.com, Venture House Group LLC. | Incomplete; a rendered support address does not prove mailbox operation. SMTP setup is owner deferred. |
| Apple distribution and billing | When owner setup is ready, configure paid team, products/signing and test purchase/restore/seat/revocation scenarios on the distribution candidate. | Signed archive/TestFlight identity and StoreKit/provider results; reviewer-access instructions. | Owner deferred; do not repeatedly request activation or treat unsigned compilation as distribution readiness. |
| Final B11 walkthrough | Reconcile every requirement and route against the signed candidate; execute promised listing behaviors and the required mobile/usability acceptance. | Complete traceability with direct proof; no unsupported listing claims. | Not complete. Business experiments remain separate from software correctness and do not authorize spending. |
| Release and monitoring | Prepare release notes, staged monitoring, rollback and queue reconciliation; obtain distribution authorization at the reviewable final step. | Owner-authorized release identity, monitoring/rollback record and verified release checks. | Not authorized by CI success or this checklist. |

## Invalidation and handoff

A later change invalidates the evidence it can affect. Record that impact before
reusing a result. Do not reset unrelated checks automatically, but the final full
regression and release aggregation must still identify one exact source revision.
Environment changes require compatible evidence and genuine performance profiles;
never relabel old measurements. Preserve the first failure before a changed,
question-driven diagnostic. Do not repeat an unchanged successful focused run.

Keep [current handoff](CURRENT-HANDOFF.md) concise: active owners, exact source/run
identities, newest result, next executable action and remaining authorization
boundaries. Historical logs stay in their original evidence locations. No provider
activation, deployment outside its approved scope, paid setup or App Store release
is authorized by merely marking a row ready to execute.
