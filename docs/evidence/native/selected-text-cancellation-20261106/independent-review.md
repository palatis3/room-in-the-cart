# Independent selected-text cancellation fix review

**No blocking regression found in the bounded five-file review.** The change separates unconfirmed sheet edits from the durable review, exposes an explicit save action, and retains the existing acknowledged-import recovery path. This is source approval for the stated behavior; I did not run native tests or certify the pending suite.

## Reviewed behavior

- `DeviceSurfacesComposition.swift:11–14,253–271`: opening a review installs its exact durable baseline. In-memory editing uses the extracted validation guard. Explicit Save uses journal compare-and-swap against that baseline and advances it only after successful durable save. A stale/different on-disk review cannot be overwritten; failed Save leaves the baseline unchanged.
- `DeviceSurfacesComposition.swift:289–308`: explicit Add saves the reviewed content against the same baseline before calling the existing commit. Once Add is selected, a later failure may retain those confirmed edits for recovery; that is intentional, not an unconfirmed Cancel. A committing retry skips review rewriting. Recovered drafts install the refreshed baseline, including prior confirmed attempts.
- Every assignment of nil to draft also clears the baseline, covering Cancel, SwiftUI binding dismissal, background and scope teardown. Neither dismiss route removes the journal/source or overwrites a prior explicit save. Clearing this memory does not discard acknowledged intent.
- `SurfaceImportBridge.swift:173–187`: the existing review identity/scope/phase/pending-save checks were extracted intact; durable saves still go through journal validation, lock, compare-and-swap and readback. Read-only text comparison confirmed the entire bridge tail from `commit` through `refreshReview` and receipt validation is byte-identical to retained negative-source. `.committing`, old receipt recognition and `confirmedAttempts` remain intact, including refreshed `.review` drafts with history.
- `DeviceSurfacesEntry.swift:75–88`: Save is disabled for committing imports and the whole form is disabled while busy. Copy explains unsaved cancellation. EN/ES strings for Save, saved confirmation and Cancel semantics are present and translated in the parsed catalog. The existing row editor still requires **Apply line edits** before its local text becomes part of the review; Save persists the reviewed model, not unapplied text-field buffers.

## Regression evidence scope

`DeviceSurfacesCompositionStartupTests/testCancelledSelectedTextChoicesAndLineEditsDoNotBecomeSavedReview` (`NativeCompositionStartupTest.swift:142–208`) meaningfully changes both a duplicate decision and a row, checks the complete journal baseline, unchanged ledger workspace/revision, retained inbox entry, and reopened exact draft for both Cancel and binding-to-nil routes. It then explicitly saves a choice, verifies a later cancelled edit does not replace that save, and commits a different confirmed merge with a consumed inbox receipt, removed journal, two lines/two batches, and exactly one new ledger revision. This goes beyond success wording or final-screen assertions.

The inspected negative log fails exactly at the post-Cancel journal comparison. Pending positive model execution is root-owned. Binding-to-nil exercises the model path used by swipe, not a real native swipe gesture. This test uses the isolated test inbox and actual model/SQLite paths, not system extension activation; prior normal-app/system-share evidence retains that separate scope. New Save affordance visibility, keyboard layout and activation are not proven by this model test. Direct stale-baseline/save-failure and background-during-commit interleavings are not newly exercised here; reviewed source retains fail-closed writes and existing bridge recovery tests remain relevant.

## Existing scope-race limitation, not introduced by this patch

The pre-existing `addReviewedList` catch reads the old operation's journal back into draft without checking the starting nonce. If background/scope teardown occurs during the awaited commit, this can repopulate in-memory draft after it was cleared. The new baseline follows that same restored draft; it does not add a wrong-scope write path because Save/commit still validate current scope and generation. Private UI rendering also checks authorization. I have not established a disclosure or a changed failure here, and do not treat it as a blocker for this narrow correction. A future nonce-guard hardening must preserve the durable journal for legitimate recovery rather than deleting it.

## Provenance

Reviewed current working files below and read-only diffs against root's retained `negative-source` composition/bridge. The retained test copy already contains the new regression. Reviewed the added UI/copy and full regression directly; no Git commands were used. No edits to source, build, native execution, network or additional agents. Only this scratch report was written. Parent-reported starting revision: `2e0f60f`; working source identity is the hashes below, not an assertion of committed content.

SHA-256:
- `ios/App/DeviceSurfacesComposition.swift`: `6c55c3a9160c6dd2d6837a4d47972c109fcf3dfd601d4df641ec738aefbcbfa1`
- `ios/Features/DeviceSurfaces/SurfaceImportBridge.swift`: `10dc1cf5d75c928251e178d85ea439f7f0a6dec81d032c96fe8eded45c9d82ed`
- `ios/Features/DeviceSurfaces/DeviceSurfacesEntry.swift`: `eb3ceb4e1cc66fadd6aaa7ad10969ab915a20ab8082af82764d2d2d5ee58e889`
- `ios/Features/DeviceSurfaces/DeviceSurfaces.xcstrings`: `319f55b29a12f2b4eae2c01078f81642ad6f12c8546437680340138f2acbd04a`
- `ios/Tests/NativeCompositionStartupTest.swift`: `749f3059357b03fa49971b51dd78956592fac91ab84f80fd7b4921b5a765df5c`

## Terminal result verification addendum

The root-owned fixed run is now terminal: `fixed-summary.json` and all 30 case nodes in `fixed-tests.json` report **30 passed, zero failed/skipped/expected failures**, on iPhone 17 simulator iOS 26.2 (23C54). `fixed-exit.json` and `fixed-strict-exit.json` both record exit 0. `fixed-strict.log` confirms all 30 selected tests executed, one start and one passing completion per selector, and **zero runtime warning occurrences**. The new cancellation regression passed in **0.216035962 seconds** (0.216 seconds in the native log). The interruption, stale-review/prior-attempt, racing receipt, and real-ledger restart tests also passed in this same scoped run.

All five reviewed file hashes above still equal both the current files and their entries in `fixed-source.json`; the executed source manifest records base `2e0f60f391c74abb08f1fcc6c0d35958bac3206f`. No reviewed source drift found.

Warning qualification: neither run was compiler-warning-free. `fixed.log` contains **10 warning lines representing five compiler diagnostics**, each repeated in a source excerpt: four unavailable-Sendable-conformance warnings in unrelated test fixtures and one unnecessary-try warning in an existing portion of `NativeCompositionStartupTest.swift:348`. The negative log contains the same five diagnostic kinds/locations (the latter at line 337 before later test additions), also ten rendered warning lines. Runtime warnings are zero; no test-runner restart lines were found, consistent with strict's one-start/one-pass check. The negative result remains one deliberate post-Cancel assertion failure, not a build failure.

This updates the earlier pending-result status only. It does **not** prove a physical/native swipe gesture, the new Save control's visibility or activation, system-share-extension entry, or resolve the pre-existing asynchronous scope-race limitation described above. Review consisted of reading retained exports/logs and hashing files; no tests, native tools, network or Git actions were run.

Retained result SHA-256:
- `fixed-source.json`: `112f5f10a882f7d1ef3ac3da41e5eea6331b8374b4682c5f91bb65d4bf0f3f2a`
- `fixed-summary.json`: `2c427c71b905487eb15e52da9bb85c686392e842fffe66413b50189cd65b38f9`
- `fixed-tests.json`: `e5e6741e5df13f56b671c8101890d562dcb4709d39073a02a7ee316eb29f1523`
- `fixed-strict.log`: `f798b46531f53ce13db5a502780bcfe88bbf5c7b44479c4aee702b86fc33c7da`
- `fixed-strict-exit.json`: `982b9e9bfb10ffe83cad665807abcfd3fa97b37822db5ab7831157a499548a9e`
- `fixed.log`: `b576ad65029f1c379dc0380db158921533e404ac90fe489e9ba8a49b6a9039cd`
- `fixed-exit.json`: `b5f3e522ac8ad01f041ce30de8cd9939768c74cf8eacc14c5a941ef0e74fa6b6`
