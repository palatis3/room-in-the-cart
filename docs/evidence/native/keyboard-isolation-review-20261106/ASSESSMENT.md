# Read-only fixture-isolation assessment — 2026-11-06

No attributable source defect or root cause is established. Original d0 stock failure and isolated event-instrumented success have materially different predecessor/keyboard history. The evidence argues against a surviving app model or an unfinished stock save as the cause. Simulator/XCTest history remains a testable hypothesis, not a diagnosis. The separate single-case quote failure means preceding test cases are not necessary for the general Done/animation-stall symptom.

All source references below refer to d0b0b12ee0cb8412f17e82c92a91013217560670, preserved under `d0-source/`; they do not refer to the concurrently changing main checkout. `source-manifest.json` records source and original-trace hashes. No native runs, hosted operations, source edits, or additional agents were used.

## Actual order and retained state

Original job127681902052 used one xcodebuild invocation, parallel testing NO, six selectors, one iPhone17/iOS26.2 device BC7CEBFB-6B90-4D7E-B85E-BB0102C99F06. Its `Tests.log` records this execution order (line numbers):

1. Contributor Spanish large-text original wording (17–761), passed189.224s.
2. Contributor English typed/structured request (762–2640), passed397.254s.
3. Measurement authenticated consent/send/delete/withdrawal (2644–3096), passed109.491s.
4. Measurement local consent/restart/workspace scoping (3097–3424), passed63.803s.
5. Stock changed-meal revision (3428–3507), failed201.755s before preview/stale mutation.
6. Stock preview/cancel/confirm/restart (3508–4011), passed99.307s.

The Spanish predecessor **actually showed and dismissed** the iOS “Type español e inglés” onboarding card at76.93–82.43s (log360–378). The following English test reports the card absent (e.g.823,843). This is direct evidence of prior keyboard interaction on the original device, not proof of a particular persisted OS preference. Spanish also supplied accessibility XXXL; later tests supply English/en_US but stock does not explicitly set a content-size argument (`ContributorRequestUITests.swift:15–20,40–42`; `StockReviewUITests.swift:72–75`). Command-line defaults are not evidence that XXXL persisted, and failure AX is not sufficient to claim that.

Each case creates a new XCUIApplication and terminates the app. Logged app PIDs differ: contributor24050/28997; final measurement52613; failed stock53345; sibling63669/66464. Thus the shared XCTest runner/device is real, but a shared *live app/fixture/model instance* is contradicted by the log. No preceding app animation-completion timeout appears; the only three such lines in the whole stock shard are3471/3486/3494, starting immediately after the failed stock Done tap.

The original workflow selects an already available simulator and boots it; it does not create/erase one (`.github/workflows/ios-fixtures.yml:155–159`, `scripts/select_ci_iphone.py:8–25`). That does **not** prove the hosted image was dirty. The diagnostic explicitly creates its own iPhone17 (`169613bf:diagnostics/keyboard-events/prepare.sh:17`) and runs only stock changed-meal; its known keyboard history is different. The original uninstrumented process and diagnostic instrumented process are also different timing conditions.

## App initialization, persistence, and animations

- Both use the contributor compilation profile and the same fixture @main; regular app initialization, foreground tasks, navigation restoration, membership, and device-surface setup are excluded (`RoomInTheCartApp.swift:4–7`; `ContributorRequestUIFixture.swift:5–45`). The argument router constructs the stock root, not all other fixture roots.
- Every stock test starts with reset:true. `StockReviewUIFixture.swift:14–23` removes its own temp `StockReviewUIFixture` directory and dedicated defaults domain, then creates its PickupModel and HouseholdModel. Its database/outboxes do not overlap contributor UUID temp paths or measurement UUID application-support paths. Reset errors are swallowed (`try?`), a latent observability weakness, but no failed removal is evidenced and no predecessor uses this directory. It is not an established cause.
- Measurement intentionally writes a legacy feedback preference into UserDefaults.standard and preserves scoped preferences (`MeasurementUIFixture.swift:132–147`); stock WorkspaceAccess uses its separate suite. No stock initialization/identity-toggle path found reads that feedback preference. App-container/OS persistence is not universally erased, but a relevant product-state leak was not found.
- Stock readiness is published only after awaited load and three successful seed mutations (`StockReviewUIFixture.swift:25–41`). Save uses `saving = true; defer { saving = false }`, clears pending state on success, then returns (`PickupModel.swift:395–432`). The readiness gate removes the initial ProgressView. The batch form's only explicit progress indicator is conditional on model.saving (`PickupHomeView.swift:83–96`). There is no repeating animation/timer in the stock fixture/batch view. Final AX shows batch5/revision3 and no “Saving on this device”/ProgressIndicator. Combined with startup completion and no save action before the failure, a stock save spinner is unsupported.
- Identity `checked` resets on amount/food/date/useFirst changes, not on model revision or presentation refresh (`PickupSavedStockSection.swift:154–174`). A delayed field change could still reset it; original lacks event logging. The successful event-only diagnostic establishes healthy ordering and no recorded post-setter reset for that run only.
- Passing sibling uses the same openBatchAndPreview helper and reset. It has two extra read assertions before opening the batch, plus a new app launch. Its Done at22.16s returns to queries by23.00s, versus failed Done13.08s followed by60s wait. That is an observed timing difference, not justification to add waits or claim initialization raced.

## Separate quote failure

Original job127681902133 selected **only** stale-review quote, on a different device8C9F4118-331E-4250-B1FC-194972BA6726. Its log has no preceding case and no onboarding dismissal. It has23 “Bilingual keyboard onboarding absent” markers, including immediately before the first stalled Done (log629,t208.66s); no “Dismiss the identified bilingual” or before-dismissal screenshot marker. Card absence neither proves first-use keyboard state nor proves past dismissal. The original select-existing-device preparation still leaves pre-test simulator history unspecified.

The quote test uses a unique workspace UUID/reset environment (`SharedStoreQuoteUITests.swift:8–17`); fixture data uses S27-UUID and only presents content after adult/shopper creation (`StoreQuotesUIFixture.swift:154–164,197–200`). It entered many fields before stalling on second.storeID Done at209.87s. The retained activity evidence says focus/keyboard persisted, unlike final stock AX. This rules out preceding *cases* as a necessary explanation for both failures, and does not establish a common mechanism. See authoritative `docs/evidence/native/ci-d0b0b12-20261106/stale-quote-timeout.json`; the stale-save behavior was never reached.

## At most one next diagnostic, if pursued

Run the **original six-selector contributor-balanced-02 sequence once**, in one runner invocation on one newly created iPhone17/iOS26.2/23C54, using the already preserved exact169613bf products and existing opt-in instrumentation/capture. Do not rebuild with the geometry fix. Keep original selectors, XCTest quiescence, time allowances, and test helpers. Verify actual log order, whether the Spanish onboarding appears/dismisses, distinct app PIDs, and then correlate target Done/focus/keyboard/setter/reset events; retain passing sibling as an internal comparison. Stop after that one invocation, retaining failures as failures. No dispatch was performed here.

This compares a deliberately reconstructed predecessor history against the existing isolated169613bf pass, while holding the product artifact fixed. It does not reproduce unknown original hosted-image history. A reproduced target failure with events can distinguish missing Done entry, focus/keyboard transition stall, missing toggle setter, or later reset. A pass is nonreproduction, not a fix or proof that predecessor history is harmless. Because the prefix bundles language, keyboard use, elapsed time, and app launches, even a failure would establish history sensitivity before it identifies a particular predecessor cause.

## Original trace references

- `.build/CIResearch20261105/candidate-d0b0b12/iphone-fixture-results-contributor-balanced-02-1/Tests.log`; selected extracts are in `original-stock-excerpts.txt`.
- `.build/CIResearch20261105/candidate-d0b0b12/stock-identity-failure-attachments/516AA97C-D1E6-4530-8335-9261D389E2EC.txt`.
- `.build/CIResearch20261105/candidate-d0b0b12/iphone-fixture-results-SharedStoreQuoteUITests-testStaleReviewedSaveCannotBeRebasedAndLockedShopHasNoNewComparisonAction-1/Tests.log`.
- `docs/evidence/native/ci-d0b0b12-20261106/{stock-identity-failure,stale-quote-timeout}.json`.
- `docs/evidence/native/keyboard-events-d0b0b12-20261106/summary.json` and `.build/KeyboardDiagnostic20261106/hosted-run42176801822/verification.json` (exact169613bf product provenance and diagnostic-only limits).
