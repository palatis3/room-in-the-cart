# S07 short-fill fee review

**No concrete product defect found in this bounded area.** Current receipt/usable-food operations do not add a placement fee, rewrite the checkout quote or append a settlement charge. A separately reviewed top-up has its own entered charges and trip agreement; it is not inferred from the shortage. Existing exact-804 model evidence supports several meaningful parts of this rule. Do not create another test merely because the original acceptance ledger called the whole clause unmapped.

## Contract and implementation

`docs/product/foundation-gen2.1/03-screens.md:47` requires: “Never assign a new placement fee just because the retailer later shorts the order.” This does not promise the retailer refunds the original fee or prohibit the household from agreeing to another trip. S09 at line 54 requires explicit agreement before another trip, and S11 at line 64 separately records posted charges, credits and top-ups. `02-features.md:165–167` likewise separates expected, posted, credited and top-up amounts.

- `ios/Features/Pickup/PickupModel.swift:550–563`: receive and confirmUsable mutate only the journey's PickupLedger. `CoreDomain/Pickup.swift:111–163` stores order lines, receipt fragments and usable observations; these operations have no fee/settlement fields. `PickupModel.change:433–436` saves that edited value; persistence does not synthesize another checkout. The original quote and existing settlement entries therefore survive these operations unchanged by source construction.
- `PickupModel.swift:293–295` evaluates the saved quote, not a lower merchandise total reconstructed from actual fill. `setQuote:438–444` also refuses direct quote replacement once the basket is reported placed. Thus a later shortfall does not re-run a threshold-fee decision against reduced fill through this route.
- `PickupOfferEvaluation.swift:173–196` combines explicitly entered otherCheckoutCost once with each selected replacement and retained original charge. It does not introduce a new placement-fee line. `PickupOfferForecastViews.swift:172` tells the shopper to include the applicable existing charges once and explicitly states that later shortfall does not create another placement fee. This is entered estimate evidence, not an assertion about what a retailer actually bills.
- `PickupFallbackOptions.swift:187–205` treats a proposed extra purchase separately: its merchandise plus explicitly entered top-up fees/tax must fit a separately entered top-up budget, with entered travel time. It does not reuse the original pickup cap as available funds or add these estimates to posted settlement. `PickupFallbackReviewView.swift:99–115` requires agreement for the exact currently reviewed option and rechecks it at selection. `PickupFallbackOptions.swift:32–60` invalidates stale consent through canUse. Choosing the option fills manual repair instructions; saving those instructions (`PickupRepairView.swift:189–192`) appends a repair, not a charge.
- `PickupSettlementView.swift:38–53` offers an explicit Posted top-up purchase record alongside Posted charge and credits, with amount/evidence ID. `PickupModel.settle:603–608` appends only the supplied entry. An actual separately incurred expense can be recorded as evidence; the acceptance rule must not be misread as forbidding such an entry or requiring automatic inference from trip consent.

## Exact retained proof worth binding

All four model selectors below are **Passed** in `.build/CIResearch20261106/candidate-804030e/core-collection/iphone-results-models-1/test-details.json`, run `42272379454`, attempt 1, source `804030e68473d022e72b464940061c01c611a0bd`. Scope: iPhone 17 simulator, iOS 26.2 (23C54), Xcode 26.3 (17C529), synthetic local data. Their complete test method bodies were compared read-only with retained candidate-verifiers sources and are unchanged in current source. This binds test assertions; it is not a claim that all current production files are byte-identical to 804.

| Exact selector (prefix RoomInTheCartTests/) | Direct assertion and limit |
|---|---|
| PickupOfferEvaluationTests/testRetainedOriginalAndExplicitFixedFeesConsumeJointAndLineHeadroom | `ios/Tests/PickupOfferEvaluationTests.swift:38–54`: entered 600 cents other cost (including retained fees) + 100 retained original + 300 replacement equals 1,000, with a 300 replacement maximum; tighter line cap also checked. Proves combined original charges are counted once in offer arithmetic. It does not execute a subsequent actual short-fill transition. |
| FreeJourneyAcceptanceTests/testFreeManualJourneySurvivesRestartFromMealsThroughNextShop | `ios/Tests/FreeJourneyAcceptanceTests.swift:11–181`: starts with explicit fixed pickup fee 240, total 1,100 then 640 after deferral; places once, records/replays partial fill and usable food, repairs and restarts; explicitly posts net charge 440 and checks paidSoFar exactly 440 before and after credit reconciliation (`:134–146`). This would catch an additional persisted paid charge introduced by the exercised short-fill path. It does not explicitly compare quote/fee arrays immediately before and after arrival. |
| AcceptedDinnerOptionsTests/testLatestUsableCorrectionChangesSmallestTopupWhilePreservingProtectedLunch | `ios/Tests/AcceptedDinnerOptionsTests.swift:87–101`: top-up merchandise 250 plus separately entered charges 25 equals extraCash 275; budget 274 rejects it. Correcting usable food removes trip need. This proves separate prospective top-up arithmetic, not a posted purchase. |
| AcceptedDinnerOptionsTests/testTripConsentOnlyAuthorizesReviewedDraftAndExactRepairAtSelection | `ios/Tests/AcceptedDinnerOptionsTests.swift:103–153`: selection rejected before consent; exact reviewed option accepted after consent; missing/changed option and stale draft invalidate agreement. Proves explicit scoped trip consent for assisted recovery, not retailer billing or native toggle activation. |

Retained durations respectively: 0.004487037658691406, 0.3127720355987549, 0.024731040000915527 and 0.004387974739074707 seconds.

Additional package evidence is already present, not absent: `CoreDomainTests.PickupTests/testIndependentEqualPurchasesSurviveWhileSameEvidenceDeduplicates` passes in both exact-804 `swift-address-1/CoreDomain.log:317–318` and `swift-thread-1/CoreDomain.log:317–318`. Current source at `ios/Packages/CoreDomain/Tests/CoreDomainTests/PickupTests.swift:186–196` explicitly distinguishes a 500-cent original purchase from a separate 500-cent postedTopUp, preserves both, deduplicates replay, and totals 1,000. `DinnerPlanningTests/testConfirmedStockProtectsLunchAndFallbackRequiresTimeAndTripConsent` passes at lines 188–189 in both logs and exercises the extra-trip-confirmation requirement. I did not locate frozen package source copies within this bounded lookup; do not promote the current package assertion text to exact frozen-source proof from those log lines alone.

The 804 native `FreeJourneyUITests/testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop` already mapped by the acceptance ledger traverses partial fill and settlement. Its frozen UI fixture uses an inclusive checkout total of 3.00 rather than a separately asserted retained placement-fee line. Keep it as related journey evidence; it does not independently close the complete S07 fee clause. Later unrelated setup/navigation failures do not prove a fee regression.

## Recommendation and remaining limit

Bind the four exact model cases to their narrower outcomes instead of treating S07.04 as missing implementation. Retain the original conservative whole-clause classification unless review policy accepts the combination of direct arithmetic/settlement tests and the source-level nonmutation argument. No product change or new fixture/test is justified by this review. The remaining literal evidence gap is a single before/after assertion of original quote/fee identity across actual short fill; no failing behavior was found, and that omission alone does not warrant inventing a new product task.

No native execution, source/Git/hosted modification, network or agents. Existing frozen ledger/evidence untouched; only this scratch report written.

## Principal file hashes
- `docs/product/foundation-gen2.1/03-screens.md`: `c8110a8f8f2d6f2d36f32305a158ecd9b2e1a34f998abbd79f38a95debf7c7e7`
- `ios/Features/Pickup/PickupModel.swift`: `c57b837b2983d7c0c565817b3d0598b862f043cc901ffde3890849d207a102c1`
- `ios/Features/Pickup/PickupOfferEvaluation.swift`: `e58f43f2477624df8c1967cabae925202d2f5b8f69e5ccb12f7775f15e3a90c6`
- `ios/Features/Pickup/PickupFallbackOptions.swift`: `cfc31ed1b038c358f53800c46de0fbd7d34543293dcff81da2a3e987208c5ce5`
- `ios/Tests/PickupOfferEvaluationTests.swift`: `e5cc7d1d6e6d8ff023cc166b3877992f2e87cc35a178e52f25f94313922c286c`
- `ios/Tests/FreeJourneyAcceptanceTests.swift`: `736ddc0813453f3fa7fef7930ec0ae8197b8049e85f11d301176c701cd0d34cd`
- `ios/Tests/AcceptedDinnerOptionsTests.swift`: `370ca294821455e0b93266cc831a25effe072e1b610bf17e9f854c50d6ce0536`
- `.build/CIResearch20261106/candidate-804030e/core-collection/iphone-results-models-1/test-details.json`: `0c4a51ff38d0ebe0afecdd5840310486449b6e9931eaa0d48eab9ea4fc5e05a3`
- `.build/CIResearch20261106/candidate-804030e/core-collection/swift-address-1/CoreDomain.log`: `6cfabeb390031e85971e41bd84d1a93904fe02ac0db0fa3310a38827c1fae0c2`
- `.build/CIResearch20261106/candidate-804030e/core-collection/swift-thread-1/CoreDomain.log`: `94ad980c7b176758ea746aab2a1003288e54a53c8c2852705e8d602c8b401d0b`

Unchanged exact-804/current test-method hashes (from func declaration through its balanced closing brace):
- `testRetainedOriginalAndExplicitFixedFeesConsumeJointAndLineHeadroom`: `9d175da8bc6c99fea8d62757637cb697c848bdf73bfdffa12c93cc12ec52992b`
- `testFreeManualJourneySurvivesRestartFromMealsThroughNextShop`: `a34a4c12b1a6e038cb1a76df3490cad6251988cc23226616e178bc82c5a026c1`
- `testLatestUsableCorrectionChangesSmallestTopupWhilePreservingProtectedLunch`: `64713f2728ed89966c2c3d0099c32e877a58505fe0c495a6d839923d3cd50b48`
- `testTripConsentOnlyAuthorizesReviewedDraftAndExactRepairAtSelection`: `9f3ff0721bcfb328a008112ff74b6248b33be77179f5b7ea30759c4ecb69a66d`
