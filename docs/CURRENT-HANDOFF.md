# Room in the Cart — current handoff

Updated November 10, 2026. Active goal: finish the complete Foundation 2.1 first release: 52 requirements, 27 screen contracts and B11. Not complete or paused. Read [APP-BASELINE](product/APP-BASELINE.md), [Foundation](product/foundation-gen2.1/README.md), [MASTER-GENERATION](product/MASTER-GENERATION.md), [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md) and [RELEASE-EXECUTION](RELEASE-EXECUTION.md). Scoped passing components do not establish one qualified release candidate.

## Workspace and ownership

Canonical repository `/Users/palatis/Room in the Cart`, branch `codex/parallel-ios-ci`; ambient Spanish worktree is stale. Publish non-force to `codex/combined-candidate-20261109`; PR branch remains separate. Current committed product checkpoint `f877f352`; last published candidate `46a3e6bf0c4f90ed3f36d7baff25936c7867bdf1`. Records native/UI work remains uncommitted pending qualification.

No Dot/Lumpy. Astra helpers prepare scratch work; root integrates, commits and dispatches. Root owns the single local native/PostgreSQL execution slot. Preserve original failures, private fixtures and unrelated untracked evidence. Stage named paths only. Do not re-request owner-deferred provider or signing setup.

## Development priority

User explicitly requested less engineering overhead and fewer repeated tests on
November 10. Finish product behavior first; use affected build/tests per edit,
batch broad regression at integration/release, and stop optional hosted diagnostic
work for now. Follow the new priority section in [CI-VALIDATION](CI-VALIDATION.md).
Do not erase known failures or represent deferred checks as passed.

## Active execution and next actions

1. Local backend r3 is terminal PASS: `.build/SharedDemandGraphNov09/root-records-protected-backend-r3`. All eight new Records-v2 HTTP cases pass. Full regression: 1,031 offline plus one database-only skip; 441 PostgreSQL plus three separately assigned browser skips. Root verified309inputs/phase hashes and byte-identical compiled production against qualified r1; signed restore/erasure passed; database stopped. [Proof](evidence/service/records-protected-conversion-20261110/records-http-verification.json).
2. Records UI r12 is terminal FAILED, session63831: `.build/TrackingFlowUIQualificationNov10/r12`. App build passed; English journey failed after118seconds because the expected `records.importDisposition.00000000-0000-4000-8000-000000000002` element was not found. Spanish did not run. Source remained unchanged; original result/logs retained. Cause is not yet classified. No automatic retry is queued; the source freeze has ended.
3. No hosted run is active. Latest diagnostic42892918759 at46a3e6bf is terminal failure; original artifacts verified. No repeat dispatched. See CI findings below before choosing another experiment.
4. Once the new Records HTTP and UI successors pass, verify source/log/product evidence, commit named native/test paths, update acceptance and publish the integrated candidate. Do not repeat the already-qualified unchanged 24/80 wire lane solely because new test-only coverage is added.

## Qualified product work

Fresh combined backend r1 passes **1,031 offline / 433 PostgreSQL** with one/three declared skips. Includes 40 protected-conversion tests, 21 actual API cases, 12 Records projection tests and signed restore/erasure. Root independently verified 308 current/archived source inputs, phase hashes and compiled products; PostgreSQL stopped. Actual Swift client transport passes **24 Node cases / 80 Swift scenario invocations**, zero failures/skips, retaining the original21/70. Root verified428inputs; successful private wire fixture removed after shutdown. [Backend and wire proof](evidence/service/records-protected-conversion-20261110/README.md).

Protected tracked/transferred cross-unit meal edits now use current exact source proof through review and command recomputation. Whole Undo restores original bytes while comparing with the immutable accepted-forward conversion, including explicit missing evidence. An independent review caught the older-basis precedence defect before installation. Historical line-order collision in the wire fixture is fixed. Proposal-backed protected conversion, plain-unbound cross-unit edits and whole protected aggregates remain unfinished.

Shared Records server v2 exports current partial/erased facts without authority/replay tokens; explicit v1 stays separately guarded. Native current-shop adapter, independent encrypted recovery and explicit unknown source dates are installed. Initial package qualification passes230client tests plus three real-wire skips and33archive tests. Native r9 app build and135selected model tests pass with zero runtime warnings. [Native component proof](evidence/native/shared-records-20261110/verification.json).

## Records successor findings

The new real-route suite first passed439database tests, failed two new cases and skipped three browser cases. All preceding433passed. The failures were fixture assumptions: authority transfer requires the organizer and increments authority epoch without changing shop revision. Test-only correction is installed; r3 above now passes all eight cases and the full441database regression. Original r2 private fixture and evidence retained. [First failure](evidence/service/records-protected-conversion-20261110/records-http-first-failure.json).

UI r10 built but found a real repeated-export error visibility defect. `prepareExport` now requests a fresh action outcome so the existing view reveals/focuses each error; background-refresh behavior is unchanged. r11 rebuilt and the focused model regression passed, including cleared private documents and unchanged registry bytes. Its English journey passed private export, encrypted save and import Cancel, then a test-only wrong-direction search failed. Two post-outcome Choose file calls now search below the result; all assertions and32-attempt/20-second bounds remain. r12 failed later at the expected import-disposition element; diagnosis remains open. [Original UI failure](evidence/native/shared-records-20261110/ui-first-failure.json), [direction failure](evidence/native/shared-records-20261110/ui-direction-first-failure.json).

## Hosted and minimum-iOS status

CI46a3e6bf passes295portable helper controls and all three exact-commit658-check workflow profiles,793inputs/50pins. [Profile proof](evidence/ci/launcher-startup-timing-20261110/profiles.json).

Hosted42892918759 booted normally in55.214seconds. Supported-launcher inventory acquisition observed about13.5seconds of bash residency, followed by about15.7seconds of zero-output bound simctl before the original30-second deadline. Startup validation/Popen were fast. Owned SIGINT, terminal children, later scoped cleanup and device deletion were verified. Original ZIP19/TAR20/50source pins retained. [Hosted proof](evidence/ci/launcher-startup-timing-20261110/hosted-42892918759.json). A supported, unsampled runtime-plus-exact-device query pair under one unchanged deadline is a possible next experiment, not a proven fix; earlier targeted queries also timed out. No app performance or baseline qualification follows from these helper controls.

Minimum-iOS Spanish XCTest callback fault remains open. Approved Apple report showed Sent with three attachments; feedback ID/transfer completion was not observed. Do not resubmit or repeat unchanged. [Fault](evidence/native/minimum-os-first-fault-20261109/README.md), [host feasibility](evidence/ci/minimum-os-host-feasibility-20261109/README.md).

## Remaining full-release boundaries

Complete shared-food/proposal/plain-unbound/aggregate paths and matching screens; full historical shared Records, remote-erasure reconciliation and guardian-scoped recovery; actual authenticated mixed-device household/provider lifecycle; operational restore and alerts; physical iPhone features; human English/Spanish accessibility; actual mailbox and policy operation; signed TestFlight/billing/App Store gates. Follow [CI-VALIDATION](CI-VALIDATION.md), freeze one combined revision and run complete regression before merge. Green CI alone is not release authorization.

Staging approval extends through041 only. Local042–048 and subsequent code are not deployed and require their reviewed rollout/recovery process. Paid Apple membership/signing, SMTP and KWS activation remain owner deferred. Operator: Venture House Group LLC. Support: hello@roominthecart.com.

Historical originals remain in their evidence folders and git history. Previous handoff text is preserved at `.build/HandoffNov10/before-records-checkpoint-consolidation.md`.
