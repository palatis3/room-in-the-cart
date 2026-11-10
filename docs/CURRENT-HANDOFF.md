# Room in the Cart — current handoff

Updated November 10, 2026. Active goal: finish the complete Foundation 2.1 first release: 52 requirements, 27 screen contracts and B11. Not complete or paused. Read [APP-BASELINE](product/APP-BASELINE.md), [Foundation](product/foundation-gen2.1/README.md), [MASTER-GENERATION](product/MASTER-GENERATION.md), [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md) and [RELEASE-EXECUTION](RELEASE-EXECUTION.md). Scoped passing components do not establish one qualified release candidate.

## Workspace and ownership

Canonical repository `/Users/palatis/Room in the Cart`, branch `codex/parallel-ios-ci`; ambient Spanish worktree is stale. Publish non-force to `codex/combined-candidate-20261109`. After grouped fixes pass, fast-forward the existing PR branch once to the same candidate; use its automatic integration batch instead of also dispatching a duplicate manual core run. Records native/UI integration is included in this grouped candidate commit. Use `git log -1` and the remote candidate ref for current commit identity; do not dispatch a broad run solely for these focused changes.

No Dot/Lumpy. Astra helpers edit explicitly assigned, nonoverlapping files in the canonical checkout; root reviews, integrates, commits and dispatches. Do not create scratch-install approval steps for already authorized local implementation. Root owns the single local native/PostgreSQL execution slot. Preserve original failures, private fixtures and unrelated untracked evidence. Stage named paths only. Do not re-request owner-deferred provider or signing setup.

## Development priority

User explicitly requested less engineering overhead and fewer repeated tests on
November 10. Finish product behavior first; use affected build/tests per edit,
batch broad regression at integration/release, and stop optional hosted diagnostic
work for now. Follow the new priority section in [CI-VALIDATION](CI-VALIDATION.md).
Do not erase known failures or represent deferred checks as passed.

## Active execution and next actions

1. Local backend r3 is terminal PASS: `.build/SharedDemandGraphNov09/root-records-protected-backend-r3`. All eight new Records-v2 HTTP cases pass. Full regression: 1,031 offline plus one database-only skip; 441 PostgreSQL plus three separately assigned browser skips. Root verified309inputs/phase hashes and byte-identical compiled production against qualified r1; signed restore/erasure passed; database stopped. [Proof](evidence/service/records-protected-conversion-20261110/records-http-verification.json).
2. Records import-review correction builds and passes BOTH original EN/ES journeys (2passed,0failed,0skipped,0reported runtime warnings), session82335 terminal0. Original build/test logs and result bundle: `.build/SharedRecordsNov10/review-focus`. Screenshots inspected for review dates/actions and recovered disclosure. r12's failure is retained: opening a later import left the viewport below its details; the view now scrolls and moves accessibility focus to the import review. A subsequent generated-heading localization correction uses the existing Records catalog; final build validation passed (session45626 terminal0). No backend/wire/model suite was unnecessarily repeated.

3. Combined core successor [42905420428](https://github.com/palatis3/room-in-the-cart/actions/runs/42905420428) at `a19c5cf7` passes source checks (970Python), TypeScript service/web, all1,054service unit,447database integration and15maintenance tests. PostgreSQL17 tools fixed all three restore failures. This older run is now terminal failure:12jobs passed and8failed including the aggregate gate. Its failures are summarized below; do not rerun its unchanged revision. Swift package tests all passed, but its post-run gate rejected an added regression against an old exact inventory. The local checker now treats the reviewed inventory as a required minimum while requiring every compiled test to execute, pass and obey the same skip policy. Nine focused checker tests pass; rechecking the original hosted artifact passes196CoreDomain,30DeviceSurfaces,241HouseholdClient,74LocalStore and33RecordArchive, with the same three deliberate wire skips. This does not change the failed hosted job's recorded status. Existing logs/artifacts are under `.build/CombinedCoreNov10`; no package tests were rerun. Optional performance diagnostic42892918759 remains deferred and failed.
4. Selected and carried history now includes exact food graph/pack/tracking revisions, stock corrections and carried delivery ancestry. Old files remain readable with explicit capture coverage. Cross-shop cook text requires current shopper scope on each recorded source; stock-only physical evidence never includes source budgets/other meals. Backend12focused and client11focused checks pass. Database passes444,0fail,3separate browser skips (session77437 terminal0; owned cluster stopped and removed). Native app build and11focused archive/erasure checks pass (sessions74688/60719 terminal0) in `.build/SharedRecordsNov10/carried-history-native`,0skips/0reported runtime warnings. Database logs: `.build/SharedRecordsNov10/carried-history-database`. Localization passes30catalogs/4,751entries. No local process is active.
5. Qualify the grouped feature and CI repairs with one full core CI batch; use focused existing checks for any diagnosed failure, then batch its repair. Existing local restore erasure reconciliation was inspected and verified, including pending cleanup across restart, stale recovery opens, media erasure and deleted-source import refusal; do not invent a second recovery subsystem. Remaining work is combined regression, actual authenticated/deployed household and deletion acceptance, plus the release boundaries below. No household authority is restored from these files.

6. Dinner proposal group editing is installed locally: explicit ingredient/group quantities can be edited independently; exact totals are checked before planner review or shopper seed review. Protected lunch, IDs, original evidence and unknowns remain explicit. SharedMealChangeTests passes15/15, including the9wrap/7dinner+2lunch regression, Cancel, exact retry and scope changes. Production app builds through `.build/SharedMealGroupEditingNov10/native/Build-r4.xcresult`. Direct Device Hub walkthrough verified9total,7dinner,2protected lunch, unchanged original after Cancel, then1proposal/0applications. The newly attempted automated UI case was removed from the pending diff after test-input/selector failures and repeated60-second XCTest animation-idle waits; originals `Tests.xcresult`, `UI-r2.xcresult`, `UI-r3.xcresult` remain unqualified. UI-r2's post-test diagnostic collector was interrupted by exact PID; UI-r3 was interrupted and its driver exited75. No hosted/native diagnostic qualification is claimed. The scoped model regression remains automated; the flag-only fixture remains available for direct UI reproduction.
7. The five model fixture suites that failed43cases in the hosted914-case shard are repaired locally: current `/demand/tracking` projections, v2 request review/retry and truthful legacy/recovery expectations. Production authorization and expiry guards are unchanged. Build-for-testing passes. The initial61-case focused run passed47/47 across the four non-request suites and12/14 request cases; after correcting the request fixture’s invalid far-future candidate expiry, only its14cases were rerun and all pass. Strict result validation confirms14executed/14passed,0runtime warnings. Existing transport, Cancel, protected quantity, exact-byte retry and apply-once assertions remain. Logs/results: `.build/TrackingFixtureRepairNov10`. No unrelated service/database/package suite or broad CI was repeated.
8. Hosted run42905420428 remains unqualified: iOS Debug/test build and unsigned Release build pass; UI-01/03/05/06 and Swift CodeQL pass. Hosted UI-02/07/08 failures now have local focused passing repairs (below). UI-04 timed out after720seconds in `FreeJourneyUITests/testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop`; other6cases passed. Astra’s read-only audit of job130150130793 found cumulative runtime, not a demonstrated stuck route: settlement at689s, next-shop dinner Apply at715s, and a reused-dinner capture at748s after the720s timeout fired. Final relaunch/Records assertions never completed. The small test-only correction now uses typed button queries and returns directly to `dinnerWeekEntry` instead of first revealing the unrelated library. Normal Debug build passes; the original journey passes locally in427.655seconds, including final relaunch and Records assertions, with the original720-second allowance. Strict validation confirms1executed/1passed,0runtime warnings. Logs/results: `.build/FreeJourneyQueryRepairNov10`. Local iOS27.0/SDK27.1 success does not qualify hosted timing or the combined candidate. UI-10 passes all8cases. UI-09 finished with7/8passing; its reminder journey timed out evaluating the known `ledgerReviewImport` Button through an Any query after successful typing. The two-line typed-button correction now builds and passes the original reminder journey locally in146.534seconds,1/1executed with0runtime warnings and every assertion/time limit retained. Results: `.build/ContextualReminderQueryRepairNov10`; original failure: `.build/CombinedCoreNov10/ui-09.log`. Batch all verified corrections into the existing PR head for one integration batch. Shared-meal fixture review is now repaired and all three original S17 UI journeys pass locally: planner proposal/Cancel/separate shopper Apply once; shopper seed/Cancel/Apply; repeated clock-time review and day move without extending the deadline. The fixture explicitly starts with tracked manual soup of unknown usable quantity, not legacy adoption. Current v2 read and v1 review/command responses retain exact proposal identity and preview binding. Strict result checks pass with0runtime warnings. Originals are `.build/FocusedUIRepairsNov10/Shopper-r2.xcresult` and `ProposalDeadline-r2.xcresult`. The initial setup/title-selector failures remain preserved in `Tests.xcresult`. This is isolated-fixture acceptance, not deployed mixed-device verification.
9. Focused normal-app UI repairs pass: typed Compare-button lookup avoids the saved XCTest Any-query traversal fault; comparison entry waits for its existing focus-driven Done control before typing; share cancellation waits separately for dismissal and the unchanged frozen snapshot. Hosted UI-07 failed the old share-dismissal wait despite a visible frozen snapshot; UI-08 failed typing before the save/viewport assertions because no input had focus. Native normal Debug build passes. All3original failed journeys pass in `.build/FocusedUIRepairsNov10/CoreTests-r2.xcresult`: large-text Edit112.84s, share cancellation107.45s, save/viewport56.12s. Strict validation confirms3executed/3passed and0runtime warnings. Share cancellation retains exact frozen text, persisted cancellation history and unplaced state after relaunch. Comparison tests retain exact input, whole control visibility and known totals. These local passes do not rewrite the historical failed hosted jobs or qualify the complete candidate. No model/service/database suite was repeated for these test-only edits; no broad successor dispatched.

## Staging recovery preparation

A fresh encrypted041backup and two actual restores now pass. The second restore
upgraded through048, preserving all129original non-registry tables, original
shop columns and41registry records/timestamps. The baseline stayed byte-identical;
both local servers stopped and both Keychain-backed images reopened and detached.
The two historical backfills matched expected empty sets in this staging snapshot;
existing populated integration cases remain separate evidence. Current immutable
Vercel application/worker entrypoints require authentication. Dry upload inspection
now excludes Supabase CLI temporary metadata; all211regular inputs are tracked.
[Review preparation](evidence/b11/staging-048-preparation-20261110/README.md).
No hosted migration/deployment occurred. Prepare compatible maintenance and the
final promotion commands before asking for the048rollout approval; do not repeat
backup/restore solely for unrelated UI-test edits.

## Qualified product work

November 10 runtime/rollout check: the existing Supabase CLI can access Room in
the Cart Staging even though the connector currently cannot. Live registry has
41 entries, all matching current source; the alias still resolves to ready
deployment `dpl_F2S6YE9JQ7rhoYWr67wbZHDJo9v2`. All six existing public API/auth
smoke checks pass. Read-only results are in `.build/Staging048Nov10`; no hosted
mutation was performed. Pending migrations remain042–048.

The rollout review caught missing production activation of shared-food tracking:
fixtures enabled `trackingV2`, but `createRuntime` did not. The new actual-runtime
regression reproduced404, then passed after enabling the existing feature in the
production composition. Build and21focused runtime/privacy/tracking checks pass
in `.build/RuntimeTrackingNov10`; the local PostgreSQL cluster is stopped. The
read does not adopt food, and anonymous/revoked sessions remain denied. Existing
guardian/provider activation is unchanged. Current service must follow migrations;
after new-state writes, the041 service is not a safe rollback. Prepare compatible
maintenance/forward recovery and verify046 label-provenance and047 meal-identity
backfills during the actual restore rehearsal before requesting rollout approval.

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

Finish promised meal edits/proposals with preserved reservations and Undo; permitted historical Records and selected backup/recovery; authenticated/deployed deletion acceptance (existing local erasure/recovery checks pass); verified guardian-scoped access/export/deletion; actual authenticated mixed-device household/provider lifecycle; operational restore and alerts; physical iPhone features; human English/Spanish accessibility; actual mailbox and policy operation; signed TestFlight/billing/App Store gates. Follow [CI-VALIDATION](CI-VALIDATION.md), freeze one combined revision and run complete regression before merge. Green CI alone is not release authorization.

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
