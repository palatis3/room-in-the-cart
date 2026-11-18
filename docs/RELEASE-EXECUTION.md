# First-release execution checklist

This checklist orders the remaining work; it does not replace Foundation 2.1's
52 requirements, 27 screen contracts or B11 acceptance. The authoritative scope
is [the build contract](product/foundation-gen2.1/08-build.md) and the requirement
and route maps in [current acceptance](CURRENT-ACCEPTANCE.md). A successful merge
is one checkpoint, not release authorization. Updated November 18, 2026.

The user has added a 28-feature expansion before signing/distribution. Its
[audited implementation plan](FEATURE-EXPANSION-PLAN.md) and
[three-judge disposition](FEATURE-EXPANSION-AUDIT.md) now define the additional
work. PR #10 merged as `3b767679`; plan approval and passing PR CI do not close
original release obligations or certify unimplemented features. PR #29 merged after 61 checks passed. The remaining combined feature work is
in [PR #60](https://github.com/palatis3/room-in-the-cart/pull/60).
[Current handoff](CURRENT-HANDOFF.md) tracks its qualification and staging revision.

Xcode produced an unsigned arm64 iPhone Release archive at `b2e58601`.
The app and both extensions matched their crash symbols. Package checks verified
the embedded extensions, assets and privacy manifests. Signed distribution still
requires the production subscription product ID, Supabase URL and publishable
key, household service URL, and public privacy, terms and support URLs.

An iPhone 17e simulator running iOS 27.0 installed the Release build from `b2e58601` over merged main `bcca63b0`. The earlier app saved and reopened a synthetic pickup before the update. After pantry setup and a second relaunch, the same two lots still had four and two units reserved, respectively, with zero available. A new three-unit lentil lot also reopened. SQLite integrity and foreign keys passed in each of the three original databases, and every prior revision payload matched. The detailed readback is in `.build/in-place/result.json` in the update-bcca-b2e5 worktree.

On November 18, the installed Staging app from `95d8c40f` reached the live schema 059 service anonymously on an iPhone 17 simulator running iOS 27.0. English Support opened in Safari. Spanish Help passed on replay after a first-run Safari prompt disappeared during the initial tap. Screenshots and local text recognition verified the complete barcode privacy paragraph in both languages. The original screenshots and hashes are in `.build/staging-iphone-95d8c40f/result.json` in the integration checkout. [Staging deployment](evidence/b11/staging-059-feedback-20261118/deployment.json)

The full web dependency audit on that revision blocks automated release. The web build tools resolve picomatch 4.0.7, and the advisory listed no patched version on November 18. The four high-severity entries trace to this single dependency. The service audit and the production-only web audit returned zero findings. Once a fix is available, verify the resolved web lockfile, run the complete dependency audit and exercise the built web screens. [GitHub advisory](https://github.com/advisories/GHSA-fc5q-39xc-vjpf)

The November 15 staging update rehearsal preserved the original saved comparison
byte-for-byte, then saved and reopened a second revision after changing the
confirmed stock. The iOS 17 simulator also reached the staging service and
opened Spanish Help and English Support in Safari. The staging UI helper now
returns to the Shop root when launch restores a saved comparison. The Mac's
staging preview was updated after verification, preserving its seven durable
files at installation. See `.build/StagingUpgrade6c60Nov15/qualification.json`.
Signed distribution and physical-device update checks remain open.

The B05 unreadable-recipe-photo walkthrough used the system photo picker and
the Release app on an iPhone SE simulator running iOS 17.0. Before the fix,
the unreadable result was below the visible capture controls. The revised
screen brought the explanation into view, including the full Spanish sentence
at maximum Dynamic Type. Keeping the typed draft, cancelling and relaunching
preserved the saved wrap dinner. All rows of the three shopping databases
matched the original fixture, including both meal occurrences. Selecting a
real QR image showed its identifier and the manual-match message. See
`.build/UnreadableRecipePhotoNov15/{final-spanish,detected-code}/strict.log`
and `final-spanish-stores.json` in the same evidence directory.

On November 15, the Release app on the iPhone SE simulator running iOS 17.0
read a bilingual package photo through the system photo picker. The shopper’s
typed “2 Wraps” stayed in place until they explicitly used the OCR text. Cancel
preserved the original list. A separate regression reproduced a provider file
being replaced by a link to a different file of the same size. The corrected
reader rejected that link and preserved the size-limit error for oversized
photos. See `.build/PhotoSelectionNov15/{before.log,strict.log,picker/strict.log}`.

At `61a2631e`, the Debug app on an iPhone SE simulator running iOS 17.0 saved
an encrypted shopping list through the Files picker. Canceling the save kept
the file ready. Canceling import left the records alone, and opening the same
backup twice produced one recovered copy. After uninstalling the app, a fresh
installation rejected the file without its key and recovered it with the key.
After relaunch, the separate list showed two pears and one unit of rolled oats.
The current shopping workspace still had zero revisions. The four UI runs and
the database verification are under `.build/RecordsSystemFilesNov15`. The
physical-iPhone check remains open.

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

On the iPhone SE simulator running iOS 17.0, someone entering a recipe at the
largest accessibility text size could read the Spanish source-address error
through its last word, dismiss it with Listo, correct the address, save, and
reopen the recipe with the corrected address. The first attempt showed clipped
text in a fixed banner. The updated editor uses a scrollable system alert at
accessibility sizes. See `.build/ManualRecipeSECorrectionNov14/read-to-end-strict.log`
and the rendered `before-error.png`, `after-error.png` and `end-error.png` there.

The Share extension now checks the type and size of the file it actually opens.
A regression test reproduced a replaced file returning another file’s contents
through a symbolic link. After the fix all 39 DeviceSurfaces tests passed.
On iOS 17.0, the system share sheet opened both a UTF-8 file provider and a
plain-text file URL in the Release extension. Cancel followed by Save for
review left exactly one pending entry with its original two lines. See
`.build/SelectedTextDescriptorNov14/selection-strict.log` and `inbox-check.json`
in the same directory.

On iOS 17.0, the Spanish Release app at `60d28bbc` saved a recipe from
Files. After installing the `8f793e1f` Release build over it, the editor
reported one saved duplicate, one new recipe and one skipped row in a mixed
file. Saving, undoing that import and relaunching preserved the earlier recipe.
The on-disk recovered record, receipt and payload matched the pre-update
values. See `.build/RecipeUpdate8f79Nov14/updated-strict.log` and
`registry-verified.txt` in the same directory.

On iOS 17.0 and 26.2, the reviewed request stayed open while a fictional service
held its receipt. The sheet showed the waiting status, blocked Cancel and resisted
a downward drag. Each run recorded one request. The child pickup journey also
cancelled a withdrawal, checked the original request, then explicitly withdrew it.
Both cases passed on each simulator with zero runtime warnings. On iOS 17,
finishing text entry before opening review resolved a warning from disabling an
active text field. See `.build/ContributorSendReceiptNov14/alert-17/ui-strict.log`
and `.build/ContributorSendReceiptNov14/alert-26/ui-strict.log`.

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
| Targeted regression | Finish product paths and fix observed defects using affected checks. Defer optional hosted diagnostic experiments; revisit minimum-iOS and required performance gaps for candidate/release qualification. Root coordinates one investigation per cause. | Original selectors/assertions and strict validation pass on the preserved candidate; complete measurements before performance baseline approval. | PR #1 passed its full combined checks. The English Free pickup walkthrough on `1875321f` verified the partial delivery, protected lunch, cook repair, settlement and next shop after relaunch. The Spanish iOS 17 settlement check reproduced a duplicate receipt conflict, retained the original $2 charge and accepted a distinct $7 charge after the shopper corrected the ID. See `.build/FreePickup1875321fNov14/qualification.json` and `.build/SpanishReceiptB6Nov14/fixed/qualification.json`. The Release app at `d4204478` reached its first responsive frame in a median 1.084 s across five cold launches on an iPhone SE (3rd generation) simulator running iOS 17.0. See `.build/MinimumLaunchD420Nov14/launch/calibration.json`. The release timing budget still needs physical-device measurements. |
| Shared-food integration | Validate original-unit editing, planner proposals, shopper Apply and whole Undo across the iPhone screens and shared service. | Exact sources, quantities, authority, Cancel and durable retry. | On `3977750b` the Swift client and real local service passed a two-adult original-unit edit from four to five dinner portions while preserving the protected lunch. Cancel preserved both meals. Apply and whole Undo survived lost responses, recovered their saved receipts and restored the original food facts and basket. See `.build/RealFoodUndo397Nov12/qualification.json`. Two separately signed-in adults also completed the original-unit proposal, shopper approval and whole Undo on the ordinary Release iPhone simulator build. The protected half-cup lunch, original dinner, basket order and quote survived revisions 3, 4 and 5. See `.build/RealFoodIPhone397Nov12/qualification.json`. The signed distribution walkthrough remains open. |
| Combined integration | Qualify the combined feature revision. | Full core, fixture, deep, wire and security results for the same commit, plus the compact and large iPhone journeys. | [PR #60](https://github.com/palatis3/room-in-the-cart/pull/60) is open. Native Bitrise found that the compact cooking journey could not select Used after cancelling and reopening. The full suite must pass on the revision containing the correction. [Original compact run](https://app.bitrise.io/build/e484c600-84cb-4db2-9877-f86f344cabfd) |
| Merge | Merge the qualified PR head through branch protection, then verify main. | GitHub merge identity, matching tree and postmerge checks. | PR #29 merged as `bcca63b0`. Its [postmerge core](https://github.com/palatis3/room-in-the-cart/actions/runs/44256035116) and [security checks](https://github.com/palatis3/room-in-the-cart/actions/runs/44256035117) passed. PR #60 follows this checkpoint. |
| Staging parity | Exercise authenticated Records and cook flows on the current staging build. | Deployment identity, migration checksums, public and protected smoke checks, and a verified recovery path. | Staging serves schema 062 and service `21df1581`. Protected and public checks each passed 12 API, 21 web and four database-backed access checks. The daily worker points to the same deployment. Authenticated request comparisons, Undo and reported purchasers passed locally. Mixed-phone acceptance and hosted email remain open. [Current staging verification](evidence/b11/staging-062-request-pairs-and-buyers-20261118/deployment.json) |
| Authenticated household | Execute shopper, second planner, cook and contributor scenarios across the native iPhone app and companion mobile web; exercise stale edits, reconnects and revoked grants. | Actual authenticated mixed-device task records with role/privacy outcomes and exact service/build identity. | A Release iPhone simulator organizer signed in with a real local Supabase email code, created a household and issued an adult invitation. A separate Chrome user joined it in Spanish, reopened the same contributor membership after reload and signed out. PostgreSQL recorded one member named “Miembro del hogar.” The service denied the contributor the household roster. The local receipt is `.build/LocalProviderNov12/mixed-device-qualification.json`. On Mobile Safari the cook read and proposed a correction, the organizer published it, and revocation concealed the instructions after Back and a fresh visit. See `.build/MobileCook397Nov12/qualification.json`. The planner and organizer also completed the proposal and approval in the Release iPhone app on iOS 27 with separate local email sign-ins and a billing fixture. Six protected portions and the saved basket survived, and revocation denied further reads and proposals. Hosted email and deployed physical-device qualification remain open. See `.build/RealCookA807Nov12/qualification.json` and `.build/RealPlanner397Nov12/qualification.json`. |
| Child/provider lifecycle | Configure actual guardian verification/notice and verify consent, withdrawal, scoped access and provider erasure with approved test identities. | Provider-backed records, denied unauthorized access and verified removal/reconciliation. | Real KWS activation/configuration remains separate; prepared integration and accepted terms are not activation evidence. |
| Recovery and alerts | Execute independent hosted restore and alert-delivery cases with approved private backup/key custody; verify operating-owner response. | Recovery target, data invariants, delivery and reconciliation receipts, and retrieval of the retained proof. | The November 16 scheduled GET at 08:21:00 UTC returned HTTP 200 on the expected staging deployment. Its matching runtime result at 08:21:02 reported all five auth/privacy counters at zero and attentionRequired=false. The request ID and vercel-cron/1.0 agent correlate the two records; no manual maintenance invocation was used. See the [content-free receipt](evidence/b11/scheduled-maintenance-20261116/receipt.json). An optional HTTPS heartbeat passed local transport checks for success, failure, redirects and a stalled monitor; see `service/OPERATIONS.md`. Neither staging heartbeat destination is configured. Alert delivery to the operating owner and the independent hosted restore still need verification. |
| Performance qualification | Resolve missing hosted scroll measurements and obtain compatible candidate limits plus physical-device launch/hitch evidence. | Complete required duration/memory series for the exact environment; physical-device results for device-only acceptance. | Both prior Bitrise M2 and isolated M4 experiments passed the XCTest case but failed strict validation because scroll duration was missing. The M4 job is `131676825146` in run `43358180772`; a local replay of its same products emitted five duration samples. On November 18 the iPhone 17 simulator at `b2085d9d` produced all three required measurement series. Median responsive launch was 6.876 s and median scrolling was 2.583 s. Median absolute scroll memory rose 5,521 kB against November 16 on the same simulator profile. XCTest emitted no hitch samples. Hosted measurement, an approved Xcode 27.1 baseline and physical-device qualification remain open. [Local samples and build identity](evidence/native/release-500-item-b2085d9d.json) |
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
