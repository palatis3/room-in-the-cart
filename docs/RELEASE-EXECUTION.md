# First-release execution checklist

This checklist orders the remaining work; it does not replace Foundation 2.1's
52 requirements, 27 screen contracts or B11 acceptance. The authoritative scope
is [the build contract](product/foundation-gen2.1/08-build.md) and the requirement
and route maps in [current acceptance](CURRENT-ACCEPTANCE.md). A successful merge
is one checkpoint, not release authorization. Updated November 14, 2026.

On November 12, the `099d6bf6` native Records adapters and real local service
exported the shopper’s current shop and history. The named planner received 404
for both exports. The encrypted file required the correct key. Restoring it
created two independent copies, and retrying after reopening created zero.
Removing history preserved the current copy. A separate registry-level source
erasure check blocked reimport after reopening. Retiring history through the
service left the current record readable. The local run used real email codes
and a billing fixture for the planner seat. The deployed lifecycle and signed
iPhone walkthrough remain open. See `.build/RealRecords099Nov12/qualification.json`.

At `239d979e`, the Release app on an iOS 27 simulator exported an encrypted
comparison and recovered one copy from Files. Deleting the source removed both
records. Importing the same file again showed a conflict, and neither record
returned after relaunch. On an iPhone SE simulator running iOS 17, the English
and Spanish deletion warnings could be read through the final line at maximum
Dynamic Type in dark appearance. Both actions were reachable, and cancelling
preserved the comparison. The local results are in
`.build/ErasedBackupNov13/qualification.json` and
`.build/AccessibleRecordsDeletionNov14/qualification.json`.

At `3dc272c3`, all 47 Records adapter and recovery tests passed on the iPhone SE
simulator running iOS 17.0, with zero skips or reported runtime warnings. The
app rejected a symbolic link selected for import and preserved the valid recipe
when another recipe in the same file had an oversized ingredient. The saved batch
reopened successfully. The XCTest result and selector check are in
`.build/RecordsMinimum3dc2Nov14/`.

## Candidate identity and evidence

Before the final full CI batch, record the immutable source commit, configuration,
Xcode build, runtime/device, service deployment and migration state. For ordinary development, retain the revision/configuration, existing logs and
result bundles; do not create additional source archives or receipt machinery.
Follow the current lean-development priority in CI-VALIDATION.md. Do not
combine separate passing revisions into a claim that one candidate passed.

For final release acceptance below, retain: exact candidate identity, case/requirement IDs,
executor, environment, date, expected result, actual result, evidence location and
hash, and next action. Use `not run`, `passed`, `failed`, or `owner deferred`.
For routine development, a short command/result note and the existing log or
result bundle are enough; do not produce this full record for every edit.
Missing or indirect proof is not a pass. Keep sensitive backup/provider originals
in their approved private location; commit only redacted receipts and hashes.

## Execution order

| Gate | Next action and environment | Completion evidence | Current state / dependency |
| --- | --- | --- | --- |
| Targeted regression | Finish product paths and fix observed defects using affected checks. Defer optional hosted diagnostic experiments; revisit minimum-iOS and required performance gaps for candidate/release qualification. Root coordinates one investigation per cause. | Original selectors/assertions and strict validation pass on the preserved candidate; complete measurements before performance baseline approval. | PR #1 passed its full combined checks. The English Free pickup walkthrough on `1875321f` verified the partial delivery, protected lunch, cook repair, settlement and next shop after relaunch. The Spanish iOS 17 settlement check reproduced a duplicate receipt conflict, retained the original $2 charge and accepted a distinct $7 charge after the shopper corrected the ID. See `.build/FreePickup1875321fNov14/qualification.json` and `.build/SpanishReceiptB6Nov14/fixed/qualification.json`. Minimum-iOS and Release performance qualification continue. |
| Shared-food integration | Validate original-unit editing, planner proposals, shopper Apply and whole Undo across the iPhone screens and shared service. | Exact sources, quantities, authority, Cancel and durable retry. | On `3977750b` the Swift client and real local service passed a two-adult original-unit edit from four to five dinner portions while preserving the protected lunch. Cancel preserved both meals. Apply and whole Undo survived lost responses, recovered their saved receipts and restored the original food facts and basket. See `.build/RealFoodUndo397Nov12/qualification.json`. Two separately signed-in adults also completed the original-unit proposal, shopper approval and whole Undo on the ordinary Release iPhone simulator build. The protected half-cup lunch, original dinner, basket order and quote survived revisions 3, 4 and 5. See `.build/RealFoodIPhone397Nov12/qualification.json`. The signed distribution walkthrough remains open. |
| Combined integration | Collect the existing frozen-candidate batch; fix observed failures with affected checks and batch any successor once. | Full gate and required security/dependency checks for that commit; no focused-scope substitution or skipped required cases. | All 60 checks passed on `af876b3f`, including both StoreKit locales. Release performance and signed distribution billing remain open. [Combined checks](https://github.com/palatis3/room-in-the-cart/pull/1/checks) |
| Merge | Recheck current branch protection, base freshness and resolved conversations against the qualified PR head. | GitHub required checks and merge state for the exact head. | Merged at `a5d9c773` with the tested file tree. [PR #1](https://github.com/palatis3/room-in-the-cart/pull/1) |
| Staging parity | Exercise authenticated Records and cook flows on the current staging build. | Deployment identity, migration checksums, public and protected smoke checks, and a verified recovery path. | Staging serves the maintenance monitoring update from `ab33d6cd` on deployment `dpl_6UJrGUTucYgRwx3183TfV2Ww29xd` with schema 048. The protected deployment and public alias each passed 20 checks, and all 27 public contract checks passed. The read-only worker check returned healthy with all five queues at zero. Rollback is the verified cook-access deployment `dpl_2n4ZtMtjDuNG49pz6HMq8QrroiwZ`. Four browser cases on that earlier deployment verified access revocation. Hosted email and authenticated mixed-phone acceptance remain open. See `.build/OperationsStagingAb33Nov14/deployment-receipt.json` and `.build/CompanionGrantEff3444Nov13/deployment-receipt.json`. |
| Authenticated household | Execute shopper, second planner, cook and contributor scenarios across the native iPhone app and companion mobile web; exercise stale edits, reconnects and revoked grants. | Actual authenticated mixed-device task records with role/privacy outcomes and exact service/build identity. | A Release iPhone simulator organizer signed in with a real local Supabase email code, created a household and issued an adult invitation. A separate Chrome user joined it in Spanish, reopened the same contributor membership after reload and signed out. PostgreSQL recorded one member named “Miembro del hogar.” The service denied the contributor the household roster. The local receipt is `.build/LocalProviderNov12/mixed-device-qualification.json`. On Mobile Safari the cook read and proposed a correction, the organizer published it, and revocation concealed the instructions after Back and a fresh visit. See `.build/MobileCook397Nov12/qualification.json`. The planner and organizer also completed the proposal and approval in the Release iPhone app on iOS 27 with separate local email sign-ins and a billing fixture. Six protected portions and the saved basket survived, and revocation denied further reads and proposals. Hosted email and deployed physical-device qualification remain open. See `.build/RealCookA807Nov12/qualification.json` and `.build/RealPlanner397Nov12/qualification.json`. |
| Child/provider lifecycle | Configure actual guardian verification/notice and verify consent, withdrawal, scoped access and provider erasure with approved test identities. | Provider-backed records, denied unauthorized access and verified removal/reconciliation. | Real KWS activation/configuration remains separate; prepared integration and accepted terms are not activation evidence. |
| Recovery and alerts | Execute independent hosted restore and alert-delivery cases with approved private backup/key custody; verify operating-owner response. | Recovery target, data invariants, delivery and reconciliation receipts, and retrieval of the retained proof. | On November 14 the daily staging request returned HTTP 200. Its matching worker event reported zero queued auth and privacy work and no attention condition. See `.build/ScheduledStagingNov14/receipt.json`. Delivery of a failure or missing-run alert to the operating owner and the independent hosted restore still need verification. |
| Physical iPhone | Use the signed candidate for camera/OCR, microphone/readback and audio routes, share/import, widgets, print and reminders; include denied permissions and interruptions. | Device/build-specific results for each promised path and typed/manual fallback. | Incomplete; simulator and mocked-provider checks are insufficient. |
| Accessibility and languages | Human US-English/US-Spanish walkthrough; VoiceOver, Switch Control, Dynamic Type and Reduce Motion across complete applicable routes. Attribute automated findings to visible elements before closure. | Tester/device/build/locale records; resolved findings or a documented product decision consistent with requirements. | Incomplete; sampled screenshots and catalog checks do not prove all routes. |
| Policies and support | Review final operator/privacy/retention/terms copy and verify support delivery and operating ownership. | Approved policy versions and actual contact/delivery evidence for hello@roominthecart.com, Venture House Group LLC. | On November 12 the public domain returned five mail-forwarding MX records. Delivery to `hello@roominthecart.com` and the operator’s receipt still need verification. Transactional SMTP setup is owner deferred. |
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
