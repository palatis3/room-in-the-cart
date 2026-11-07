# Independent footer native-result review

The retained fixed result supports the reviewed footer change for the three selected native UI journeys. Native and strict exports exit 0; all three tests pass, with no skipped/expected-failure cases, runtime warnings or runner restarts. This review only read retained files and hashed source; it performed no native action or test rerun.

## Result and source binding

`fixed-invocation.json` selects precisely the largest-text 500-line preview, long filtered cancellation/detail return, and duplicate/original-text/restart journeys, with parallel testing disabled and the unchanged 720/900-second allowances. Invocation, summary and runtime agree on owned simulator CF6099BC-F92B-427C-8985-895AF8D24F8D, iPhone 17 / iOS 26.2 (23C54). Compiler receipt is local Xcode 27.1 (27A9275), Debug, CODE_SIGNING_ALLOWED=NO. This is local UI-test scope, not a hosted toolchain or ordinary-installation qualification.

| Exact selector (RoomInTheCartUITests prefix) | Exported duration | Result |
|---|---:|---|
| ContextualNavigationUITests/testLargeTextKeepsLongNativePasteEditableAndReviewReachable | 54.914900064468384 s | Passed |
| FreeJourneyUITests/testCancelledImportAndIngredientReturnPreserveLongFilteredListContext | 69.77464592456818 s | Passed |
| FreeJourneyUITests/testStagedListCanReturnToOriginalAndMergeADuplicateAfterRestart | 100.23696005344391 s | Passed |

`fixed.log` independently contains one start and one passing completion for each selected method (356/1182, 1186/1527, 1528/2000); the final execution total is three tests and zero failures. `fixed-details.json`, `fixed-summary.json`, `fixed-strict.log`, `fixed-result.json` and the strict exit in `fixed-export-results.json` agree. No native retry/restart is claimed or observed.

Independently rehashed all **457** current paths recorded in `fixed-source.json`: zero missing paths or mismatches. Both modified files match the exact hashes pinned in `implementation-review.md`. Comparing fixed and negative manifests finds no added/removed paths and exactly one changed file: `ios/Features/Ledger/LedgerSheets.swift`. Therefore the fixed run uses the same test that failed only at the new immediate-action-presence assertion on the old product; this is not a relaxed assertion. The 456 unchanged manifest entries include other tests and configuration, not solely shipping runtime code.

## Supported behavior and remaining limits

The largest-text native case retained its original 500-line Paste, edit/undo, Done, Review and editable-preview assertions, then passed the new single-action, immediate existence, hittability, enablement and vertical geometry checks without scrolling through preview rows. The other two cases passed the existing cancellation, filtered list context, duplicate decision and restart assertions. Combined with the source comparison, these support the intended accessible confirmation placement without an observed regression in those journeys.

Root separately reported viewing the scoped largest-text preview screenshot and observing a wrapped action below the reserved Form area with no clipping. This reviewer did not independently view media; the independent conclusion above rests on the retained assertions/results and source.

The results do **not** exercise a failed store save, pending-save disabled Add, Retry/Discard positioning/action, actual error-target programmatic scroll, or VoiceOver focus/announcement. The largest-text case dismisses the editor keyboard before Review; it does not prove footer/recovery layout with a preview keyboard retained. `recovery-validation-plan.md` remains the bounded proposed validation for these states. Do not broaden this success into every keyboard/locale/device or save-error layout.

Zero runtime warnings is accurate. The build portion of `fixed.log` retains four existing unavailable-Sendable-conformance diagnostics, rendered as eight `warning:` lines, in HouseholdRequestPackFixtureSupport.swift, MembershipTests.swift, NavigationRestorationTests.swift and PickupStockPrivateScopeIntegrationTests.swift. These are distinct from runtime warnings; there is no zero-compiler-warning claim. No warning points to either modified file.

## Evidence hashes

- `fixed-invocation.json`: `f3e31cf77a7be40837962c886747e6a4c6dc93068c0fdc999de2bd158a51fa78`
- `fixed-result.json`: `f8a20a782715a43db8a5a64052888375bb4e855a3f57a2ac9e846fcfffee0f3e`
- `fixed-summary.json`: `a758cc9554e0ad6dc863eff4c644444500dbbd6ceb4b97c12520e3f1c4c52fe3`
- `fixed-details.json`: `31f576b4ae28e2c4a9c4b992103a1dfdd8af84b3733cc42a684eeb564f271977`
- `fixed-strict.log`: `fb9b97d37f7232260a7d4237ec61fbdfdfd9d600db6ef82df61b5efe1ba041f3`
- `fixed-export-results.json`: `4b08469debfdb99a88b0b07b091d4f7f94bdff440c52a2a8634b3bb90119a0d1`
- `fixed-source.json`: `b8789d03c7d4bb8b05750b1a508de3f7f6cd03d67bcbad2a9e3455a943d44df6`
- `fixed.log`: `271cde55d0791e27512d8f17931b67df248750a83bcadf6be819881074d088f5`
- `runtime.json`: `a228ed1fb437619074014be5ca0d1e003a4b2d8d8da9b3d3133332580b8c8d65`
- Reviewed `ios/Features/Ledger/LedgerSheets.swift`: `5de62273f7549831cdfd44268cc24953d19e7507fc840d632d0a81a21551c878`
- Reviewed `ios/UITests/ContextualNavigationUITests.swift`: `ac70599b0e770d1c7eeb408c00912606c838fb27038671eadeea3ad9a13817fc`
