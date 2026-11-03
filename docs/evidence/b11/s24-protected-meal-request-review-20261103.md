# S24 request review with protected meal commitments

Focused Foundation 2.1 S24 and four-walkthrough cereal evidence, recorded 2026-11-03. The lead executed the native tests. This lane inspected the retained results and screenshots and wrote this document; it ran no simulator, device, Xcode build or model suite during this evidence update.

## Result and source scope

The authorized shopper can inspect the current shop's protected meal commitments beside the inclusive before/proposed checkout, cost change, cap and overage. The meal projection is read only and bound to the selected request's shop, request revision, shop revision and authority epoch. Missing meals remain unavailable; a known empty meal list is a distinct state. Recorded protected portions are commitments, and the view explicitly says this review does not confirm meal coverage.

The decision model now ignores identical binding commits when deciding whether to invalidate a preview. Actual changes still invalidate the in-flight or reviewed decision and clear its required acknowledgments. The view retains leaf accessibility identifiers for each total and named meal. Unused identifiers on the enclosing summary and meal stacks were removed after retained native AX proved that they replaced the descendant identifiers.

The final UI run compiled the frozen **470-input** source at `.build/FinalNativeSource-20261103T230030Z`, aggregate SHA-256 **`4b91cfce67372ca1b047985ce3531cd806d627c0eb4a60311ed0bead9beb7af0`**. The lead's promoted source manifest is [current-build source-manifest.json](../native/current-build-20261103/source-manifest.json). This evidence applies to that source and the isolated shopper fixture, not to a hosted household or release acceptance.

## Executed native UI proof

The lead's result bundle is `.build/FinalFixture-20261103.xcresult`; its summary is `.build/FinalFixture-20261103-summary.json`, log is `.build/FinalFixture-20261103.log`, and exported attachment index is `.build/FinalFixture-20261103-attachments/manifest.json`.

Device: **iPhone 17e simulator, arm64, iOS 27.0 (24A434)**. These S24 tests launch US English (`en_US`) at the default text size with `--ui-testing --request-pack-fixture --request-meal-fixture`; the unknown case additionally uses `--request-meals-unknown`. The fixture uses the actual `HouseholdInboxModel` and service client with intercepted `.invalid` URLs. Unexpected hosts are rejected. No live household, contributor response or retailer order is involved.

| Case | Result | Duration |
|---|---|---:|
| `HouseholdRequestPackUITests.testCerealCheckoutAndTwoProtectedLunchesAreVisibleTogetherAndCancelDoesNotWrite` | Passed | 71.241 s |
| `HouseholdRequestPackUITests.testUnavailableMealFactsRemainUnknownInRequestDecision` | Passed | 23.061 s |

The S24 suite therefore passed **2 tests, 0 failures, 0 skips**. The complete six-case bundle finished **4 passed / 2 failed / 0 skipped**. Its two failures were the separate S21 device-management launch/refresh cases. The bundle is not labeled an overall pass here.

All substantive S24 assertions were retained:

- After Review, the proposed-total, overage, before-total and both named lunch nodes must exist and be hittable in one viewport. The test requires the exact `$40.69`, `$2.69` and `$37.20` values in their respective accessible fields, plus both original lunch names, protected-portions wording and one portion each.
- Cancel must return to the same pending cereal request with **zero applied decisions and zero saved lines**. Ending the fixture's shopper access through the actual refresh path must show the access-ended state, remove the request and both lunch nodes, and leave the command count at zero.
- Missing meal facts must show the unavailable warning and must not expose either named lunch node. Cancel again leaves both write counters at zero.

The passing log resolves the individual `household.decision.after-total`, `household.decision.over-cap`, `household.decision.before-total`, both `household.decision.meal.<occurrence-id>` nodes, and `household.decision.meals.unknown`. The passing S24 attachment entries contain three PNGs and **no standalone full AX dump**. Accessibility evidence for this passing run is the successful native per-node existence, label and same-viewport hittability assertions and their retained activity log; earlier failing AX captures are diagnostic evidence only. No VoiceOver navigation claim is inferred from those assertions.

## Visual inspection of passing captures

All three exported PNGs were opened and visually inspected after the result bundle completed.

| Capture | Exported file | Observed result |
|---|---|---|
| `S24-cereal-checkout-with-two-named-protected-lunches` | `28713C68-84EB-4BEA-ACA0-4B184838464F.png` | One viewport shows proposed `$40.69`, `$2.69` over cap, whole-checkout scope, before `$37.20`, change `$3.49`, cap `$38.00`, and both named lunches. **Sam’s wrap lunch** is November 4, 2026; **Mia’s wrap lunch** is November 5, 2026. Each has one protected portion. The coverage caveat is visible, and overage acceptance is off. |
| `S24-unavailable-meal-commitments-stay-unknown` | `C02DB3F9-7FF4-45E9-A414-145ACCC0B884.png` | The unavailable-meal warning and coverage caveat are legible. No named lunch appears. Overage acceptance is off and Apply is disabled. |
| `S24-shopper-access-ended-clears-private-context` | `0377D91E-30FB-4813-BB00-7C036523F805.png` | The screen says shopper access has ended. No request, private checkout values or lunch facts remain. Fixture applied decisions and saved lines both read zero. |

The captures show legible amounts and named commitments without overlap or clipped text in the inspected viewport. This is default-size English simulator proof. It does not establish S24 largest Dynamic Type, Spanish layout, VoiceOver interaction or physical-device acceptance.

## Separate model regression proof

The lead's earlier `.build/IntegratedFixture-20261103.xcresult` run passed all **six `HouseholdRequestMealContextTests`** with zero failures in 0.131 seconds. The integrated source aggregate was `bb0fbbde8c1c184ace9979a1da339bd23682d5bab8f95fd525f780b77c7023f5`. Its InboxModel, S24 test and test-support hashes match the final frozen source; the later view change removes only the masking parent accessibility identifiers.

Those cases verify the two named protected lunches and exact cereal costs; missing versus known-empty meals; rejection of absent authorization, another shop or stale revision; refresh requiring a fresh review; Cancel and service access loss without commands or outbox writes; unchanged binding commits preserving a reviewed preview and explicit acknowledgments; and a held HTTP response where an identical price commit preserves the response while a real price change discards it. Meal names and meal fields are absent from the request-preview payload. These are lead-run results, not a model execution by this lane.

The final two UI cases cancel rather than applying or deferring the cereal request. This document does not claim that they newly prove an accepted cereal overage, cereal deferral, backend idempotency, live sharing, a complete ordinary pickup or release readiness.

## Retained fingerprints

| Source file | SHA-256 |
|---|---|
| `ios/Features/Household/HouseholdInboxModel.swift` | `81e92b810e8e47c4734443c3f0288b87c746f2392d69ebcd6d37c9999e725f45` |
| `ios/Features/Household/HouseholdInboxView.swift` | `11c274e820957af4e1533df5b45c1b8e6a4c3d5bfe5112f5943905e5ac055e27` |
| `ios/Features/Household/HouseholdRequestMealContext.swift` | `7f24cc32c776a2a77f4c268ef9a9c452631e2fc5cc4456e8cae73caf8d6b1e64` |
| `ios/Features/Household/Household.xcstrings` | `6e00370963dd10945ece9d10158b9e442dd08a10c423aa59a8c9fa3e0b94fecb` |
| `ios/Tests/HouseholdRequestMealContextTests.swift` | `87d5ed6f15672a24a3e1a1da629797916e228e0de8e0facfaaccda3896758858` |
| `ios/Tests/HouseholdRequestPackFixtureSupport.swift` | `3e0cc181d08b31a896f3050e8a8d37b6a2b2695855987c128f9336c646f16c0a` |
| `ios/UITestSupport/HouseholdRequestPackUIFixture.swift` | `294570cdf6c0f513c9a248363d0216237e4bdab3adf1177ea089468ce0d95d8a` |
| `ios/UITests/HouseholdRequestPackUITests.swift` | `d1f758d1aa51c640a8bc9a8770b2687be88fdb6a0940808111eadb5d5b65e00f` |

| Retained result or capture | SHA-256 |
|---|---|
| `.build/FinalFixture-20261103-summary.json` | `d986357636f74ad10082b2318c045606ac395913ff31e6aa66ca986383e5c632` |
| `.build/FinalFixture-20261103.log` | `a18df9cadb97d905d1d6a88d56bba1a3bd2e4d64524b0027eb829085c0de1f2d` |
| `.build/FinalFixture-20261103-attachments/manifest.json` | `406f363bc634bb736fe9c70f5a657074a693806d9f7eb2f9547992317991b75f` |
| `28713C68-84EB-4BEA-ACA0-4B184838464F.png` | `0debebdd81adbc5fab91a6b8c98eaf99da5cf7c3f6c74d37c80172f8a2c7206b` |
| `C02DB3F9-7FF4-45E9-A414-145ACCC0B884.png` | `a74ed58f464a9c21c18138158ace4fc52bae3a0fcc5dddb01fc6e6ff647e59cb` |
| `0377D91E-30FB-4813-BB00-7C036523F805.png` | `6082ec74dc421febd3eb8a0284c64e5ef76d12c49781a9de924b2acd1de07ca6` |

Artifact promotion, root evidence indexes and Git remain owned by the lead. This update changes only this dedicated S24 evidence document.
