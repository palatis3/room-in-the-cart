# F07 selected-media recovery checkpoint · 2026-11-03

## Latest continuation · 2026-11-03 afternoon

The recovered-store capture extension now compiles and passes **49/49 affected native tests** on the reserved iPhone SE / iOS 17 simulator. RecordArchive passes **33/33**, including the retained v1.2 mapping fixture. The new integration regression imports a photo-bearing ledger, opens the real independent LedgerStore, persists a new normalized JPEG in that actual physical namespace, projects fresh records, explicitly selects/encrypts/re-exports it, recovers beside newer work, and verifies physical UUID/provenance, inert imported mappings, copy cleanup, correction retirement, denied late writes and unrelated source preservation. Receipt and recipe bindings, malformed/foreign/future journals, protected root IDs, symlinks, legacy journal derivation, source-media scrubbing and cancellation/draining are covered.

The stale registry-row race is resolved with shared runtime recovery leases, current receipt rechecks, invalidation before delete/undo, destination dismissal and draining before orphan directory removal. A cancelled open cannot overwrite a successful deletion outcome. Cleanup now checks a journal against the actual fixed SQLite store before retiring its physical namespace. Imported declarations still never authorize listing or cleanup.

**Final scoped screen verification passed.** `.build/F07-Recovered-UIFinal.xcresult` passed **50/50**: 49 native models and one actual Records media screen journey (205.989 seconds). All seven manually captured screenshots were inspected; the final separate Form rows have no overlapping photo/wording content. Import and deletion statuses are at y=95 and passed strict viewport assertions without test scrolling. The first screen rerun exposed a test ordering issue when passive review text became a lazy separate Form row; it now scrolls that review text into view before querying it. Automatic result checks remain unchanged. That failed attempt is preserved in `.build/F07-Recovered-FinalScoped-UI.xcresult` and attachments. [Final evidence and promoted screenshots](f07-recovered-20261103/evidence.json) include exact scope, manifests, limitations and remaining release gates.

Final runtime/test source is frozen at `.build/F07-Recovered-UIFinal-Source`: clean `ec1c243` plus the explicit F07 overlays in `f07-overlay-manifest.json`, excluding in-progress guardian and civil-date lane changes. Source manifest `.build/f07-recovered-uifinal-source-manifest.json` has aggregate SHA-256 `097d6c63b5e2d2fe57a733f9c3bc551f52d4cf480154b6dcb4e04a394ce31524`. The matching binary manifest is `.build/f07-recovered-uifinal-binary-manifest.json`. Whole-checkout integrated verification remains a root task.

## Historical restart state · superseded by the acceptance above

The following checkpoint is retained as history. Its required-next-work list is superseded by the latest scoped acceptance and remaining gates above.

Preserved for a Codex app restart. The feature is **not finished**: the approved recovered-store capture-namespace extension is implemented in source but still needs native compilation, targeted regressions and final screen verification. No long run should be inferred from the presence of its source.

## Executed and preserved

- Original RecordArchive/media package tests: 30/30 passed. After the new namespace DTO/schema changes, **32/32** package tests passed; log: `.build/f07-namespace-package.log`.
- Parent’s integrated native suite before the namespace extension: **438/438**, `.build/ResumedReviewedNative.xcresult`. This includes encrypted media recovery, JPEG corruption rollback, optional corrupt sidecar diagnostics, receipt/recipe owner binding and recovered-edit filtering.
- The new action-outcome model regression passed in `.build/F07-MediaUI-Reviewed.xcresult`. That mixed bundle’s UI case failed on native disclosure accessibility; it is not an overall successful bundle.
- Dedicated actual Records UI flow passed **1/1**, 134.017 seconds, `.build/F07-MediaUI-Accessible.xcresult`, log `.build/f07-media-ui-accessible.log`. It exercised default-off photo selection, real persisted JPEG and wording, nonzero size, private-content gate, encrypted preparation/save, sibling review cancellation with unchanged source/registry, confirmed import, readable recovered photo and automatic visible status after import/deletion. Actual AX trees show named disclosure Buttons at least 44 points high, with expanded/collapsed values. Status anchors appeared at y=95 without test scrolling to them.
- This passed UI revealed a visual overlap only in the nested selection/review preview. Two `VStack` wrappers were changed to transparent `Group`, preserving separate native Form rows. `.build/F07-Final-Source` and `.build/F07-Final-Products` successfully built that change, but **the final preview layout has not yet been visually confirmed**.
- Original diagnostics are retained unchanged: `.build/F07-MediaUI-Initial.xcresult`, `.build/F07-MediaUI-Initial-Attachments`, `.build/F07-MediaUI-Reviewed-Attachments`. Successful UI screenshots/AX trees are in `.build/F07-MediaUI-Accessible-Attachments` with their `manifest.json`. They have not been promoted to final accepted screenshots because of the later layout/namespace work.

## Current approved namespace representation

`ArchiveMediaAttachment.captureNamespace` is optional and mirrored in its media-manifest entry:

```text
formatMajor: 1
archiveOrigin: String
storeKind: ledger | pickup
physicalWorkspaceID: UUID
```

The captured `SourceMediaRecord.target.workspaceID` is never rewritten. The declaration maps the logical archive provenance to the actual physical recovered store. Existing unmapped attachments retain the exact original origin/UUID ownership rule. Declared attachments additionally require exact logical origin equality, matching store/media kind, matching physical UUID, and the native shop/line/recipe/receipt target binding. Existing bounded non-UUID logical archive origins remain valid through explicit declarations; this does not relax the legacy unmapped rule.

Only a private runtime `RecordsRecoveryCapture.Scope`, minted by opening the actual fixed `ledger.sqlite` or `pickup.sqlite` inside the app-owned recovery-copy directory, can declare fresh captured sidecars. Imported declarations remain inert embedded-data validation metadata; they never authorize a native listing, file path or cleanup.

Archives use v1.2 only when a selected attachment carries a declaration. Unselected mappings disappear with their attachment. v1.0/v1.1 encodings remain unchanged and existing media subset receipt identity remains unchanged; altered declaration/content under the same selected IDs changes the digest and cannot silently become identical.

The local `capture-scope-v1.json` is a separate bounded, canonical/digest-checked, complete-protected journal containing the recovery-copy UUID, actual physical store kind/UUID and format. It is generated from the opened store, not decoded archive declarations. It survives registry-row removal so cleanup can retire media/correction namespaces before removing the SQLite directory. Legacy directories derive their missing journal from the actual SQLite identity. Active root workspace IDs are protected during cleanup; malformed journals fail closed. Fresh recovered snapshots list only the actually opened store’s namespace using current authorization and filter the resulting sidecars against emitted native records. Recovered ledger views receive the actual isolated LedgerModel environment for recipe capture.

## Current source and verification scope

New/changed namespace source (package checked; app source **parse checked only**, not natively compiled yet):

- `ios/Packages/RecordArchive/Sources/RecordArchive/ArchiveMedia.swift`
- `ios/Packages/RecordArchive/Sources/RecordArchive/Archive.swift`
- `ios/Packages/RecordArchive/Tests/RecordArchiveTests/ArchiveMediaTests.swift` (two new mapping tests)
- `ios/Features/Records/RecordsMedia.swift`
- **New:** `ios/Features/Records/RecordsRecoveryCapture.swift`
- `ios/App/RecordsComposition.swift`
- `ios/Features/Records/RecordsToolsView.swift` (mapped provenance wording plus earlier focus/disclosure/layout fixes)
- `ios/Features/Records/Records.xcstrings`

Earlier F07 source, model/UI fixtures and tests remain in the shared checkout. The dedicated file adapter is unchanged: `RecordsMediaUITestFileAdapter(save:selectedURL:)`, compiled only under `DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE`. It replaces only the system file destination/selection; production encryption, validation, review and apply remain in use. Dispatcher `--records-media-fixture` is installed.

No v1.2 fixture file or native recovered-capture cleanup regression has been added yet. No claim is made that the current namespace extension passes native tests.

## Required next work

1. Root regenerated the project at this checkpoint, including `RecordsRecoveryCapture.swift` and the other lanes’ new files. Check it with `python3 scripts/generate_xcode_project.py --check` and compile the current app source. The previous isolated builds deliberately used the successful frozen shared baseline because another lane’s then-unregistered `CorrectionSettingsOutcome` was being edited in the live checkout. Do not overwrite another lane’s changes to fix that old snapshot issue.
2. Add a real native regression: import a valid ledger/photo, open its independent actual LedgerStore through the new factory, capture a normalized JPEG into that actual physical UUID, project fresh snapshots, explicitly select/re-export the new image, decrypt and verify its original captured UUID plus typed mapping, recover beside newer work, then delete the recovered copy/source and prove sidecars/embedded copies/corrections are scrubbed, late saves fail and unrelated namespaces survive. Cover pickup receipts and recipe source binding where appropriate.
3. Add malformed/foreign mapping and local-journal tests: wrong logical owner/kind/physical UUID, unknown/future fields, corrupt/different copy journal, protected root IDs, symlinks, stale authorization, legacy journal migration, and an inert imported declaration naming an unrelated real namespace that must never drive listing/cleanup.
4. Resolve/cover the reviewer’s lifecycle concern: a stale `RecoveredRecord` after registry deletion must not recreate its directory/sidecars. Current `RecordsComposition.open` checks the registry before several awaited store operations, while its authorization closure checks persona/main stores, not the recovery-row lifetime. The new factory validates the supplied record/receipt and actual native store but does not yet take a registry lease. Consider registry rechecks before/after opening plus confirmed-delete invalidation of in-flight composition generation, and clean up only genuinely orphaned app-owned folders. Do not delete a retained copy merely because its media-scrubbed revision changed.
5. Run package/native focused checks, then rerun `RecordsMediaUITests` against final current source and visually inspect selected-media, review, recovered-photo and result-anchor screenshots. The strict UI oracle must retain real hittability for actions and visible viewport frames for passive text; it must not manually scroll to make automatic action-result routing pass.
6. Add a v1.2 migration fixture, update `ios/Features/Records/INTEGRATION.md`, `ios/Packages/RecordArchive/README.md` and the privacy inventory to describe the verified namespace behavior. Promote final screenshots and write a scoped evidence JSON only after final verification.

## Resume commands and runtime ownership

At checkpoint, **no package/native/UI/build process from this lane is running**. The last package exec completed successfully. No simulator reset is needed. Root last granted SE iOS17 `65B8A2FE-51FE-44A5-A9C7-F2524E33179B` for final F07 checks; reconfirm team ownership after restart. 17e was released by the other lanes, but do not reset/use unrelated devices without coordination.

Quick checks:

```sh
python3 scripts/generate_xcode_project.py
python3 scripts/check_localization.py
git diff --check
swift test --package-path ios/Packages/RecordArchive --jobs 2
```

For a dedicated fixture build, make a new frozen source/DerivedData directory after new source/tests are registered. Do not mutate the preserved Products/source snapshots above. The working recipe is:

```sh
xcodebuild build-for-testing -project FROZEN_SOURCE/ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath NEW_DERIVED_DATA -jobs 2 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG CONTRIBUTOR_CAPTURE_UI_FIXTURE' CODE_SIGN_IDENTITY=-
```

Clone its Products to a unique immutable directory, use the copied `RoomInTheCart_iphonesimulator27.1-arm64.xctestrun`, and run with `-parallel-testing-enabled NO`, destination above, and `-only-testing:RoomInTheCartTests/RecordsMediaTests` plus `-only-testing:RoomInTheCartUITests/RecordsMediaUITests`. Use new result/log paths. Test-only `OS_ACTIVITY_MODE=disable` preserves XCTest assertion/action logs while avoiding the already-observed iOS17 instrumentation log-quarantine crash; it changes no production behavior or oracle.
