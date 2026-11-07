# S14 whole-library-batch undo — existing evidence binding

**S14.02 is directly proven in an existing scoped run. No new test is needed to fill this mapping gap.** The frozen ledger remains unchanged; this report supplies the missing binding for root review.

Exact Check clause (`docs/product/foundation-gen2.1/03-screens.md:83`): “Undoing a library import removes that batch’s changes without deleting unrelated records.”

The actual selector is **`RoomInTheCartUITests/RecipeLibraryAcceptanceUITests/testDocumentedLibraryPreviewCancelCorruptPreservationApplyAndWholeBatchUndo`**. `LibraryPrivacyUITests.swift` is the filename; `LibraryPrivacyUITests` is not its XCTest class.

## Authoritative retained execution

- Exact candidate: `804030e68473d022e72b464940061c01c611a0bd`; original fixture run **42272379477**, attempt **1**; job **128091087432**, `contributor-balanced-04`.
- Artifact **13534597432**, `iphone-fixture-results-contributor-balanced-04-1`; recorded verified archive SHA256 **`55944bcf84c5c24d520d2e4ea4d752dbe2f695ef23ba55d9b6a8b718f64e1e8f`**, 9,050,290 bytes. This review uses the retained collection and its archive verification receipt; no download or new extraction occurred.
- Exact per-case `test-details.json` node: **Passed**, 333.8069689273834 seconds. The retained `Tests.log` independently has exactly one start at line 1232 and passing completion at line 4691. Its SHA256 matches the frozen evidence receipt. Strict replay exited **0**, with **4/4 selected cases passing, no skips**, and **0 runtime warning occurrences across the four examined detail exports**. The summary itself has no runtime-warning field.
- Actual environment: **iPhone 17, arm64 iOS Simulator, iOS 26.2 / 23C54, Xcode 26.3 / 17C529**. This shard passed; the overall fixture run failed in a different shard. This is not an all-green fixture or release claim.

The frozen test file is `.build/CIResearch20261106/candidate-804030e/fixture-collection/fixture-source/ios/UITests/LibraryPrivacyUITests.swift`, SHA256 **`068b3c6ac0065957cb5468a25f6d61313fa3b035f11b6423048b38d4680fdffe`**. It matches `fixture-source-manifest.json` for exact 804. The fixture readback implementation, RecordArchive test and production Records view/model also match their 804 entries in the immutable source manifest; `references.json` records each comparison and hash.

## Assertions that establish this clause

|Exact frozen source lines|What is actually checked|
|---|---|
|140–151|Starts with one saved recipe; previews two new recipes, then cancels without changing saved recipes or local source.|
|165–170|Reopens the documented library and explicitly applies it through the production action; saved recipe count changes **1 → 3**.|
|172–177|Opens the imported rice recipe and checks its original yield, ingredients, instructions and inert source URL.|
|179–185|Taps **Undo imported batch** through the production UI; saved recipe count returns **3 → 1**; both imported recipe buttons, **Arroz sin cambiar** and **Lemon pasta**, are absent; the undo outcome is visible.|
|201–206|Every `assertSavedRecipes` call also requires **original recipe preserved: yes**, **local source unchanged: yes**, no fixture failure and, except the deliberate malformed-input branch, no Records error.|

Those preservation values are not canned success labels. Exact-804 `ios/UITestSupport/LibraryPrivacyUIFixture.swift:138–163` seeds an unrelated local pickup and one pre-existing recovered recipe. `refreshEvidence()` at `:192–200` refreshes the real recovery registry, counts saved recipe records, checks that the original **entire recovered record** remains present, and compares the current canonical **live ledger export** with its original canonical value. The latter is a current-work/model projection comparison, not an assertion that every SQLite file byte is unchanged. The UI uses the normal `RecordsToolsEntryView` (`:226`); its fixture adapter (`:108–114`) replaces only the OS file selection. It does not call apply or undo for the test. Production undo is wired at `RecordsToolsView.swift:64` to `RecordsToolsModel.undoImport()` (`:217`).

## Supporting package proof

`RecordArchiveTests/RecordArchiveTests/testRecipeBatchUndoPreservesExistingCopyAndAllowsRetry`, source `ios/Packages/RecordArchive/Tests/RecordArchiveTests/RecordArchiveTests.swift:140–148`, applies an existing copy, applies another batch, undoes the inserted copy IDs, asserts only the original IDs remain, and verifies the removed item can be imported again. Exact source matches 804, SHA256 **`f01f96d8f37365ad858a53992ab2535d4442b2e4c8c1cc2a72627f935d163850`**.

Its named per-case pass is retained in ordinary core run **42272379454** (`RecordArchive.log:70–71`, 0.006 seconds), address sanitizer and thread sanitizer run **42272379472** (`:70–71`, 0.017 seconds; `:72–73`, 0.019 seconds). The helper constructs generic `.comparison` archive records despite the method name, so this is supporting registry isolation/reimport proof, **not** a substitute for the actual recipe UI case above.

## Scope limits

This establishes successful whole-batch undo with preservation of the seeded unrelated recipe and current local pickup, in the pinned English Debug fixture and simulator. It does not quantify every record type, concurrent edit, batch size, crash/relaunch state or later source revision. Actual physical Files selection, human/VoiceOver and deployed-provider acceptance are separate. The fixture uses `OS_ACTIVITY_MODE=disable`; retain that logging accommodation. No raw Records/media were read. No new tests, native/browser/network/Git operations, tracked edits or simulator interaction occurred. The previous 123-clause ledger is untouched.
