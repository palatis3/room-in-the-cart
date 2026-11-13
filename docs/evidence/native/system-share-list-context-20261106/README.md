# System share cancellation preserves list context

Current app source `d0594211ba8e5d29f9118958e6e29ded1a55d0b6` passed the literal S02 extension-cancellation / filtered-list / ingredient-return sequence on the first native execution: **1/1, 98.66 seconds**, strict result 0, zero recorded XCTest runtime warnings or restarts.

The test uses a fresh normal local workspace (no `--ui-testing`) with 30 reviewed typed rows: 24 Wrap rows and six interleaved Soap rows. It searches for Wrap, scrolls to an initially offscreen stable row, and records its position. A separate disposable UIKit sender presents the real system share sheet, opens Room in the Cart's embedded extension with fictional Carrots/Apple text, and cancels. Immediately after reactivating the app, the test checks the unchanged query, hittable row identity and position within four points, before any corrective scrolling. Ingredient detail and native Back preserve the same context. A complete-list search finds no cancelled Carrots.

An independent read-only copy of the synthetic ledger verifies all 30 original names, order, quantities, units, line and contribution identities against the persisted original import preview. Only creation and initial import revisions exist (1 and 2); there is one typed batch. The configured share App Group's inbox has zero entries. This is a post-run comparison to the original durable receipt, not a separately captured pre-action SQLite snapshot.

## Reproduction and boundaries

`preparation.json` hashes all 457 files from the committed iOS tree plus the scratch-only test overlay; `test-overlay.patch` contains that overlay. No production code changed for this check. The retained sender is the same three-file signed UIKit app used by the earlier selected-text acceptance, with its hashes pinned here. `invocation.json` records the complete signed Debug command. Simulated app and extension entitlements share their existing configured inbox group; no direct inbox injection or privacy bypass was used.

Environment: Xcode 27.1 / 27A9275, iPhone 17 simulator / iOS 27.0, English, standard text. Original result and log remain at `.build/S02SystemShareContext20261106/SystemShareContext.xcresult` and `native.log`; only an inspection copy was exported. `root-review.json` pins the 511-file evidence freeze and confirms unchanged source hashes. SDK/compiler console diagnostics are retained in the raw log; zero recorded XCTest warnings does not mean every tool emitted no warning.

This proves extension Cancel **before staging**. The distinct containing-app saved-review cancellation, protected-account authentication, cold-launch viewport restoration, physical iPhone and third-party sender variants are not claimed. The older saved-review/commit/undo proof retains its own source boundary. This result is outside the running hosted `0d5bb1b` cohort and is not full release acceptance.
