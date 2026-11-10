# Room in the Cart — current handoff

Updated November 10, 2026. Active goal: finish the complete Foundation 2.1 first release: 52 requirements, 27 screen contracts and B11. Not complete or paused. Read [APP-BASELINE](product/APP-BASELINE.md), [Foundation](product/foundation-gen2.1/README.md), [MASTER-GENERATION](product/MASTER-GENERATION.md), [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md) and [RELEASE-EXECUTION](RELEASE-EXECUTION.md). Scoped passing components do not establish one qualified release candidate.

## Workspace and ownership

Canonical repository `/Users/palatis/Room in the Cart`, branch `codex/parallel-ios-ci`; ambient Spanish worktree is stale. Publish non-force to `codex/combined-candidate-20261109`; PR branch remains separate. Records native/UI integration is included in this grouped candidate commit. Use `git log -1` and the remote candidate ref for current commit identity; do not dispatch a broad run solely for these focused changes.

No Dot/Lumpy. Astra helpers prepare scratch work; root integrates, commits and dispatches. Root owns the single local native/PostgreSQL execution slot. Preserve original failures, private fixtures and unrelated untracked evidence. Stage named paths only. Do not re-request owner-deferred provider or signing setup.

## Development priority

User explicitly requested less engineering overhead and fewer repeated tests on
November 10. Finish product behavior first; use affected build/tests per edit,
batch broad regression at integration/release, and stop optional hosted diagnostic
work for now. Follow the new priority section in [CI-VALIDATION](CI-VALIDATION.md).
Do not erase known failures or represent deferred checks as passed.

## Active execution and next actions

1. Local backend r3 is terminal PASS: `.build/SharedDemandGraphNov09/root-records-protected-backend-r3`. All eight new Records-v2 HTTP cases pass. Full regression: 1,031 offline plus one database-only skip; 441 PostgreSQL plus three separately assigned browser skips. Root verified309inputs/phase hashes and byte-identical compiled production against qualified r1; signed restore/erasure passed; database stopped. [Proof](evidence/service/records-protected-conversion-20261110/records-http-verification.json).
2. Records import-review correction builds and passes BOTH original EN/ES journeys (2passed,0failed,0skipped,0reported runtime warnings), session82335 terminal0. Original build/test logs and result bundle: `.build/SharedRecordsNov10/review-focus`. Screenshots inspected for review dates/actions and recovered disclosure. r12's failure is retained: opening a later import left the viewport below its details; the view now scrolls and moves accessibility focus to the import review. A subsequent generated-heading localization correction uses the existing Records catalog; final build validation passed (session45626 terminal0). No backend/wire/model suite was unnecessarily repeated.

3. No hosted run is active. Latest diagnostic42892918759 at46a3e6bf is terminal failure; original artifacts verified. No repeat dispatched. See CI findings below before choosing another experiment.
4. Candidate b6f5103f is published. The S20 review found existing financial/decision/placement/delivery/cook history screens, but Records lacked a direct past-shared-pickup entry. The small navigation change now links those existing routes from Records; its picker starts with assigned shops including closed pickups. Localization passes30catalogs/4,745entries; syntax passes. App build passed (session72352 terminal0); log/result in `.build/SharedRecordsNov10/history-navigation`. This navigation change has no new runtime walkthrough yet. Next product gap: selected authorized shared historical backup content; inspect existing projections before extending the archive. No optional diagnostics or broad CI repeat.

## Qualified product work

Fresh combined backend r1 passes **1,031 offline / 433 PostgreSQL** with one/three declared skips. Includes 40 protected-conversion tests, 21 actual API cases, 12 Records projection tests and signed restore/erasure. Root independently verified 308 current/archived source inputs, phase hashes and compiled products; PostgreSQL stopped. Actual Swift client transport passes **24 Node cases / 80 Swift scenario invocations**, zero failures/skips, retaining the original21/70. Root verified428inputs; successful private wire fixture removed after shutdown. [Backend and wire proof](evidence/service/records-protected-conversion-20261110/README.md).

Protected tracked/transferred cross-unit meal edits now use current exact source proof through review and command recomputation. Whole Undo restores original bytes while comparing with the immutable accepted-forward conversion, including explicit missing evidence. An independent review caught the older-basis precedence defect before installation. Historical line-order collision in the wire fixture is fixed. Proposal-backed protected conversion, plain-unbound cross-unit edits and whole protected aggregates remain unsupported specialized cases. They are not automatically release blockers: qualify the promised edit/proposal using supported original-unit entry before adding machinery.

Shared Records server v2 exports current partial/erased facts without authority/replay tokens; explicit v1 stays separately guarded. Native current-shop adapter, independent encrypted recovery and explicit unknown source dates are installed. Initial package qualification passes230client tests plus three real-wire skips and33archive tests. Native r9 app build and135selected model tests pass with zero runtime warnings. [Native component proof](evidence/native/shared-records-20261110/verification.json).

## Records successor findings

The new real-route suite first passed439database tests, failed two new cases and skipped three browser cases. All preceding433passed. The failures were fixture assumptions: authority transfer requires the organizer and increments authority epoch without changing shop revision. Test-only correction is installed; r3 above now passes all eight cases and the full441database regression. Original r2 private fixture and evidence retained. [First failure](evidence/service/records-protected-conversion-20261110/records-http-first-failure.json).

UI r10 built but found a real repeated-export error visibility defect. `prepareExport` now requests a fresh action outcome so the existing view reveals/focuses each error; background-refresh behavior is unchanged. r11 rebuilt and the focused model regression passed, including cleared private documents and unchanged registry bytes. Its English journey passed private export, encrypted save and import Cancel, then a test-only wrong-direction search failed. Two post-outcome Choose file calls now search below the result; all assertions and32-attempt/20-second bounds remain. r12 failed later because the import details were above the retained viewport. The review-focus successor above passes both journeys. [Original UI failure](evidence/native/shared-records-20261110/ui-first-failure.json), [direction failure](evidence/native/shared-records-20261110/ui-direction-first-failure.json).

## Hosted and minimum-iOS status

CI46a3e6bf passes295portable helper controls and all three exact-commit658-check workflow profiles,793inputs/50pins. [Profile proof](evidence/ci/launcher-startup-timing-20261110/profiles.json).

Hosted42892918759 booted normally in55.214seconds. Supported-launcher inventory acquisition observed about13.5seconds of bash residency, followed by about15.7seconds of zero-output bound simctl before the original30-second deadline. Startup validation/Popen were fast. Owned SIGINT, terminal children, later scoped cleanup and device deletion were verified. Original ZIP19/TAR20/50source pins retained. [Hosted proof](evidence/ci/launcher-startup-timing-20261110/hosted-42892918759.json). A supported, unsampled runtime-plus-exact-device query pair under one unchanged deadline is a possible next experiment, not a proven fix; earlier targeted queries also timed out. No app performance or baseline qualification follows from these helper controls.

Minimum-iOS Spanish XCTest callback fault remains open. Approved Apple report showed Sent with three attachments; feedback ID/transfer completion was not observed. Do not resubmit or repeat unchanged. [Fault](evidence/native/minimum-os-first-fault-20261109/README.md), [host feasibility](evidence/ci/minimum-os-host-feasibility-20261109/README.md).

## Remaining full-release boundaries

Finish promised meal edits/proposals with preserved reservations and Undo; permitted historical Records and selected backup/recovery; deletion reconciliation in controlled caches and restored files; verified guardian-scoped access/export/deletion; actual authenticated mixed-device household/provider lifecycle; operational restore and alerts; physical iPhone features; human English/Spanish accessibility; actual mailbox and policy operation; signed TestFlight/billing/App Store gates. Follow [CI-VALIDATION](CI-VALIDATION.md), freeze one combined revision and run complete regression before merge. Green CI alone is not release authorization.

Scope clarification from the November 10 Foundation audit: S20 and P07 require
saved pickups, notes, approvals, actual fills and unresolved outcomes; the personal
backup contract includes selected authorized history. They do not require an
exhaustive internal event browser. S21 explicitly permits previously exported
dated copies to remain; do not build remote recall of independently held files.
The service authorization matrix requires guardian-scoped access/export/erasure,
while S20/Restore forbid recovering consent or live authority from a backup.
Use ordinary permitted-record recovery rather than inventing a separate guardian
recovery subsystem. Preserve these actual user requirements; do not turn every
specialized implementation limitation into extra launch scope.

Staging approval extends through041 only. Local042–048 and subsequent code are not deployed and require their reviewed rollout/recovery process. Paid Apple membership/signing, SMTP and KWS activation remain owner deferred. Operator: Venture House Group LLC. Support: hello@roominthecart.com.

Historical originals remain in their evidence folders and git history. Previous handoff text is preserved at `.build/HandoffNov10/before-records-checkpoint-consolidation.md`.
