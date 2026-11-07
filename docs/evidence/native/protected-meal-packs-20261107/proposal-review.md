# S04 exact portions and protected-need visibility review

Assessment: evidence/assertion gap; no demonstrated product defect. No product patch proposed. Main remained read-only; no Git commands, native compilation/test, simulator, hosted or network actions performed for this review.

## Existing implementation and evidence

- `LedgerIngredientView.swift:25,75-86`: `showProtectedNeeds` is view-local State. The toggle changes only contribution-row filtering. The displayed total at line35 always uses `shop.quantity(forLineID:)`. Shop/line navigation resets the display preference; nothing saves the preference into demand or checkout state.
- The pack sheet receives only the original model/shop/line. `LedgerPackChoiceView` calls `LedgerPackRequirement.review` and `LedgerPackReview.prepare` with the full ledger and actual PickupModel. `LedgerPackRequirement` calculates protected demand inside, not in addition to, the total. `LedgerPackStockReview.evidence` only supplies stock for a real matching saved journey/allocation; a fresh empty pickup has no stock evidence.
- `LedgerCheckoutAdapterTests/testTwelveExistingWrapsProjectSixFourTwoExactlyOnce` uses an existing 12-wrap line, chooses Tacos6 and Quesadillas4, links those demands inside12, then reserves Lunch2 inside12. It checks the exact three demand identities/amounts and stable repeated projection. It previously stopped before actual pack review.
- `FreeJourneyAcceptanceTests/testFreeManualJourneySurvivesRestartFromMealsThroughNextShop` also sets up6/4/2 and asserts the eight-pack offer needs2, but selects the six-pack offer afterward. This is already meaningful combined model coverage; the historical ledger did not map it. The new focused extension makes no-stock and purchased16 explicit, keeps demand12, and retains the chosen eight-pack outcome across reopening.
- `LedgerConfirmedStockPackUITests/testHidingProtectedLunchKeepsTotalAndTwoWholePacksWithoutStock` already exercises ordinary unseeded import/protect/hide/review/unhide/relaunch views. It asserts total12, protected2 even while hidden, and exactly2 eight-packs. It does not set up separately named taco/quesadilla contributions. Preserve it unchanged.
- `docs/evidence/native/protected-need-visibility-20261106` retains that UI pass1/1,99.040695s,strict0,zero recorded runtime warnings/restarts on iPhone17/iOS27.0(24A434),Xcode27.1. All three retained file hashes (ingredient view, catalog, UI class) exactly match current main. Preparatory failures are explicitly retained. This supplies S04.02 scoped evidence beyond the older804 ledger; do not rewrite that historical804 execution as though it ran the newer case.

## Scratch regression proposal

`s04-six-four-two-pack-regression.patch` changes only the existing native model method in `ios/Tests/LedgerCheckoutAdapterTests.swift`. Existing assertions and fixture are preserved. The same selector becomes MainActor async and continues through actual persisted LedgerModel/PickupModel, production prepare/save, checkout projection and fresh LedgerModel reopen.

Additional assertions: no pickup journey; no stock evidence/confirmed-at-home input; requirement12/protected2; eight-pack count2, purchased16,leftover4,itemcost600c; prepare is read-only; saving pack choice leaves the exact shop and pickup unchanged; checkout supplies16 while the exact named6/4/2 demand remains unchanged; reopening retains both pack selection and original needs. SQLiteFixtureDirectory tracks all owners for existing bounded teardown policy.

This is model integration evidence, not a claim that a newly executed UI journey created named taco/quesadilla contributions or that physical stock of four leftovers exists. Pack remainder is a mathematical purchase result until actual receipt/usable-stock confirmation. The existing independent UI test supplies the real toggle interaction evidence.

## Root execution and integration

1. Hash-check source-manifest and overlay the single proposed test file onto an isolated source copy. No production file needs a change.
2. Compile/enumerate under the existing native lane. Require this unchanged selector exactly once: `RoomInTheCartTests/LedgerCheckoutAdapterTests/testTwelveExistingWrapsProjectSixFourTwoExactlyOnce`. Run it with the existing strict checker and exact expected count1. If running the complete class instead, obtain its exact compiled inventory (source currently has10 methods; source count is not an execution receipt).
3. Keep current timeout/restart/warning policy. Do not add jobs, selectors or duration entries: the existing compiled ordinary model inventory already discovers this same method. Ten UI shards and720/900second test limits stay unchanged. No extra fixture/profile or project-file entry is needed.
4. The unchanged existing hide test can be selected separately if current cohort native UI evidence is required; expected count1 must refer to its compiled selector. Its old99.04second receipt remains valid only for its retained source/environment, not as a new run.
5. After passing, record the exact tested source hashes, native result, strict receipt and scope. A current acceptance overlay may map S04.01 to the new focused model receipt and S04.02 to the existing ordinary UI receipt (plus any new exact reexecution), keeping the historical804 ledger immutable. These bounded clauses do not establish fullV1/release readiness or every locale/device/VoiceOver scenario.

Validation performed here: read-only source/evidence inspection; source hashes; existing selector list preserved; no compile or runtime pass claimed. Candidate full-file SHA256:939929a83d02f1041f3cab38d36ce8252eddb898df2f645eec60229d1121a571.
