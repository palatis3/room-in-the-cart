# Selected-text review cancellation — bounded finding

One concrete gap in the pre-fix implementation: changing a duplicate-resolution picker silently persists that unconfirmed choice, and Cancel or swipe dismissal does not revert it. Reopening the same selected-text entry returns the changed choice. This is a review-draft persistence issue, not evidence that Cancel itself commits shopping lines.

## Contract and UI interpretation

`docs/product/foundation-gen2.1/03-screens.md:5` says: “A sheet carries a proposed change. Dismissing it discards edits unless the screen explicitly saves a draft.” S02 at lines 19–21 requires an editable selected-text preview and preservation of existing lines/search/position when cancelling. The faster-shopping acceptance called D39 in the request is present at `02-features.md:331` (E07) and `CODEX-MASTER.md:196`: a cancelled share import leaves the draft intact. These requirements can coexist: retain the shopping draft and the explicitly staged inbox source, while dropping later unconfirmed sheet edits. That sentence does not explicitly authorize autosaving every later duplicate-picker change.

The extension offers **Save for review** (`ios/Extensions/Share/ShareViewController.swift:85`), authorizing the source entry. The pre-fix app review has **Add reviewed list**, recovery wording, and **Cancel**, but no explicit Save review draft action (`ios/Features/DeviceSurfaces/DeviceSurfacesEntry.swift:45–109`, inspected before root edits). Internal `saveDraft` naming and the journal's interruption comment are not user-visible saved-draft consent. **Apply line edits** at line 200 explicitly applies a row edit to the preview, making its interpretation less clear; the duplicate picker has no equivalent save action and establishes the narrow finding without relying on that ambiguity.

## Source chain and evidence limits

- Pre-fix `DeviceSurfacesEntry.swift:57,90–109`: picker setter calls composition.saveDraft immediately. Sheet binding at line 41 has no cancellation persistence handler; interactive dismissal is disabled only while busy.
- Frozen pre-fix composition at `negative-source/ios/App/DeviceSurfacesComposition.swift:256–282`: saveDraft calls bridge.saveReview; editDraftLine also reaches it; cancelReview only sets draft to nil.
- Frozen bridge at `negative-source/ios/Features/DeviceSurfaces/SurfaceImportBridge.swift:149–184`: open returns the saved journal; saveReview validates then saves it. Journal.save at lines 74–89 atomically writes, synchronizes, and verifies readback. This is durable storage, not merely retained SwiftUI state.
- Existing normal-app/system-extension evidence: `docs/evidence/native/system-selected-text-20261104/validation.json`, source `3e2558c5186173d679adde10903ab7340ce51177`, simulator iOS 27.0, Xcode 27.1. The retained harness `testSystemSelectedTextCancelsAndCommitsOnlyTheReviewedBatch`, lines 43–56, cancels while the duplicate is still undecided, then chooses merge after reopening. It proves source retention and later explicit import; it does not prove cancellation of an already changed choice.
- Root's new composition/SQLite negative control is independently readable in `negative.log:305–312`: one test failed at the exact post-Cancel journal-equals-baseline check, 0.373 seconds, no other reported test failure. Its first Cancel branch returns at that failure; it is not runtime evidence of the later swipe branch. I ran no tests or native tools.

## Bounded correction and regression boundary

Keep unconfirmed sheet edits in memory; retain an immutable saved baseline and use the existing compare-and-swap journal operation only for explicit **Save review draft** or **Add reviewed list**. Cancel and binding-to-nil dismissal should reopen the last saved baseline, retaining source, IDs, and untouched shopping records. An explicit save affordance makes the draft exception unambiguous. This is a design recommendation, not certification of root's concurrent implementation.

Do not delete/reset the whole journal on dismissal. Commit freezes `.committing` before asynchronous ledger mutation; failure before acknowledgment can already have a real ledger receipt. `refreshReview` can return `.review` with nonempty `confirmedAttempts`; those identities still recognize a racing earlier receipt. Preserve that history, scope/digest/base checks, and receipt matching. Existing `SurfaceIntegrationTests` at `ios/Tests/NativeDeviceSurfacesTests.swift:29,45,112,130` cover interrupted acknowledgment, interrupted commit, fresh-review prior intent and racing old receipts. Their retention intent remains valid.

Smallest missing regression: change an unresolved duplicate choice, Cancel and reopen, assert baseline choice and same IDs/source plus unchanged ledger; separately exercise sheet-binding nil. Add explicit-save/reopen and edit-after-save/Cancel cases. Keep commit/retry/old-receipt regressions. Real swipe gesture behavior remains a native UI coverage question; assignment to the binding tests composition behavior only. Repeating the old unedited system-share Cancel scenario alone adds no proof of this gap.

## Provenance and scope

Review began against parent-reported main `2e0f60f`. Root started the fix concurrently; this finding is pinned to the retained negative-source copies below, inspected directly, not to the changing working files. No Git command verified HEAD. No tracked edits, build, network, native execution, media or raw Records access performed. Only this scratch report was written.

SHA-256:
- `.build/SelectedTextCancellationFix20261106/negative-source/ios/App/DeviceSurfacesComposition.swift`: `c64f70ddae45aa328e878486e5ccf0cd2eeb67ee229b579b567a7e39f3230b9b`
- `.build/SelectedTextCancellationFix20261106/negative-source/ios/Features/DeviceSurfaces/SurfaceImportBridge.swift`: `61b304dfcc7cb3b6964e7b62f2448af370f87aca8fab4df16682dd25547f6051`
- `.build/SelectedTextCancellationFix20261106/negative-source/ios/Tests/NativeCompositionStartupTest.swift`: `7a3c8599dc0c526e54839cb03aa0fcbb8139ccb5ca67b72f2acf2cb59c59bf17`
- `.build/SelectedTextCancellationFix20261106/negative.log`: `6f41c8737d3b5ad3c33447c2918ce0ae90f607ffaf2b6c5ea2b3bae3e913824b`
- `docs/evidence/native/system-selected-text-20261104/validation.json`: `996b65d439c72c1478ad3fad0709773a883e859647b2bcce1505b0f19b04e169`
- `.build/SelectedTextSystem20261104/selected-text-system-test.swift`: `aea3520676da85f174faf7857c7ffc7c34fb6f510ad8c7cea62f225de746886c`
