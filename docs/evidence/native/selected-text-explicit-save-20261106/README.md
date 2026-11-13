# Native selected-text explicit Save, Cancel and dismissal

**Passed one real-extension journey on iOS Simulator 26.2 (23C54), iPhone 17 Pro, with Xcode 27.1 (27A9275), English/en_US.** The normal Debug app and its signed embedded share extension received the fixed synthetic `2 Wraps / 3 Pears` sample from the retained UIKit ShareProbe sender. No app fixture route, direct inbox injection or forced dismissal was used.

The exact test `FreeJourneyUITests/testSystemSelectedTextReviewCancelSaveAndDismissPreserveExplicitDraft` passed in **185.62 seconds**; the bounded supervisor completed in **192.62 seconds**, with native and read-only coordinator exit0. The copied-result strict check confirms one start and one passing completion, 1/1 selected tests, zero failures/skips/expected failures. All ten host checkpoints were independently reviewed. See [validation.json](validation.json), [checkpoints.json](checkpoints.json), [strict.log](strict.log) and [native-action-excerpts.log](native-action-excerpts.log).

| Checkpoint | UI and durable result |
|---|---|
| bootstrap | Fresh token bound to the actual installed runner/app and matching shared inbox containers after launch. |
| baseline | Real typed import created Wraps2. Ledger head2, one typed batch, no inbox entry/review. |
| initial-review | Real extension staged its sample; Wraps unresolved, Pears separate line, Add disabled. |
| cancel-reset | After choosing Merge and tapping actual navigation Cancel, reopening was unresolved again. Journal bytes and ledger matched the initial review/baseline. |
| saved-merge | One visible, enabled Save review draft tap retained the sheet and persisted the Wraps Merge decision. Saved-state copy appeared in the AX tree. Ledger remained head2; inbox stayed pending. |
| unsaved-skip | Native picker showed Skip, while durable journal bytes still matched the explicit saved Merge. |
| swipe-dismissed | One native header drag from (201,86) to (201,654.1) dismissed the sheet. Pending entry and saved Merge journal remained. No Cancel fallback. |
| restarted-before-add | Cold relaunch/reopen displayed Merge and enabled Add. The exact saved journal and ledger baseline were unchanged. |
| added | One Add tap committed one selected-text batch and advanced head2→3. The receipt became consumed, original/edited payloads were NULL and bytes0; review journal was removed. |
| final-restart | A second cold relaunch retained the exact committed ledger/history and consumed receipt, with no pending review or second commit. |

Final state has **two lines, three contributions, two total batches** (the original typed import plus one selected-text import), and one duplicate allocation. Wraps2 from the selected text points to the original Wraps2 supply as the same need; effective quantities remain **Wraps2 and Pears3**, not Wraps4. Batch/preview/contribution identities match the explicit saved review and consumed inbox operation. The coordinator used read-only SQLite connections and independently captured pre-Add baselines; final assertions do not rely solely on visible labels.

## Provenance and setup corrections

Root's frozen 459-file iOS source snapshot records baseline `8d1a79b22981148839c6e3d0827c6710f877a369`. Only `ios/UITests/FreeJourneyUITests.swift` differs, with a scratch overlay. A signed v1 build passed; before the **first and only native execution of this journey**, v2 changed three test helpers to materialize lazy rows before uniqueness checks and scroll actions until fully visible. The signed v2 build passed. Production bytes were unchanged between those builds. Independent review rehashed **459 source files, 179 product files, eight controller/plan files and three sender-product files** against frozen manifests.

The test plan differed from the freshly generated plan only by resolving product-root paths and adding the fresh token to the UI runner's EnvironmentVariables. It did not add a production-app launch flag or token to the unit-test target. Compiled enumeration included the exact selector. Built bundle IDs and new build simulated entitlements were rechecked: containing app and embedded extension share `group.dev.roominthecart.app.debug.share-inbox`; ordinary empty signing xcent files were not mistaken for missing simulated entitlements.

The first sender installation returned149 because the owned simulator was Shutdown. Installation after boot returned0, before native execution. This retained setup failure is not an app-test failure or a hidden test retry. The sender product was reused with its recorded hash; no byte-reproducible sender rebuild is claimed.

The purpose-specific read-only coordinator had **40 passing offline SQLite/journal/protocol checks** before execution. Those checks are supporting harness validation, distinct from the single native pass. The immutable original XCResult was not opened with inspection tools during this review; copied-result exports were used. [original-result-files.json](original-result-files.json) hashes the 97 original result files without copying products or exporting raw Records. [input-hashes.json](input-hashes.json) binds retained source/product manifests, controller, runtime, logs, request/ack and AX evidence; [provenance.json](provenance.json) records verification scope.

## Warnings and limits

The copied XCTest export records **zero runtime warning occurrences** across the one examined test, and the summary reports zero runtime warnings. The native log separately contains **12 Xcode operating-system-build parser notices, three debugger-version lookup notices and one duplicate simulator accessibility-class notice**. These are disclosed in [warnings.json](warnings.json); the run is not described as an entirely warning-free log.

No gap was found for this narrowly defined synthetic journey. This is **local native validation, not a permanent CI regression**. It does not reproduce the separate late-completion race, prove Spanish UI, physical-device behavior, third-party senders, keyboard/auto-scroll behavior, or any runtime other than actual26.2/23C54. No live database reread was needed for this review: retained checkpoint snapshots, native/AX evidence and frozen bytes were sufficient. Root removed only the owned simulator after retaining all checkpoint and native evidence; cleanup.json records the successful shutdown and deletion.

Root rehashed the prepared evidence and retained inputs before publishing this record. The reviewer performed no fresh native execution or shared-source mutation; root-review.json retains the original prepared manifest identity.
