# UI01 return-navigation source review

**The failure establishes that the generic test return helper could not find its target after two Back taps. It does not establish that placement failed or that the arrival route is broken.** There is a concrete asynchronous/conditional-navigation boundary worth observing before changing either product or helper.

Only the four bounded metadata/log/selector files and current/frozen source were read. Their sizes/hashes match `evidence/ui01-bounded-summary/receipt.json`; `source-references.json` records this check. No ZIP, oversized opaque member, raw Records, image or native tool was opened. Collector retains authority for full artifact/source chronology. The receipt explicitly is not strict full-XCResult acceptance.

## Exact failed step

Frozen `candidate-verifiers/ios/UITests/FreeJourneyUITests.swift`, test `testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop` (`:256`): after creating/choosing the dinner and protected lunch, saving packs, reviewing checkout, freezing/copying and restarting, the case opens “Pickup, repairs and handoffs”, verifies “Frozen · placement unconfirmed”, opens “Prepare retailer handoff”, taps “I placed this order”, then immediately calls `back(to: "Record what came home")` (`:400–408`). Arrival quantities, stock repair, settlement and next-shop assertions have not run when it fails. The current method body equals the frozen method body; later added tests shift helper line numbers but do not change these methods.

`back(to:)` uses `app.buttons.matching(identifier: label).firstMatch`. Its `returnToVisibleAnchor` loop (frozen `:1297–1322`, current `:1364–1389`) only tries content scrolling if the target already exists. Otherwise it selects the first visible/hittable navigation-bar button left of screen center, excluding identifier `settings`, and taps it. It does not scope the candidate to an expected navigation bar/title or await a model transition. A lazy offscreen target absent from the tree and a target not yet inserted by saving are indistinguishable to this logic.

The retained `Tests.log:1309–1356` shows:

- Placement tap t323.98, synthesized t324.14, idle wait t324.48.
- Target existence check t324.49; BackButton tap t325.13.
- Target check t325.98; another BackButton tap t326.90.
- Target check t328.23; navigation candidates end with `settings`; helper fails at t328.83/line1316. Teardown captures the failure and terminates.

No helper content-scroll action occurs between those target checks, consistent with its target-exists branch not being entered. Log names do not reveal the Back buttons' containing navigation titles. Ending with only the excluded settings candidate is consistent with reaching a tab root, but the bounded files do not contain the hierarchy needed to prove the final screen. No claim is made from an uninspected screenshot.

## Product/source boundary

`PickupHomeView.swift:24–32` shows “Prepare retailer handoff” only while the basket is not reportedPlaced, and “Record what came home” only when `value.pickup != nil`. `PickupHandoffView`'s placement button at `:435` starts `Task { await model.reportPlaced() }`; the test's tap return is not a durable-save assertion. `PickupModel.reportPlaced:535–548` updates basket placement and creates PickupLedger together within the model change/save path. A successful commit therefore removes the presenting handoff NavigationLink and makes the arrival link eligible in the parent List. Both Pickup views are disabled while saving (`PickupHomeView:63`, handoff `:451`); errors/progress render through PickupSaveStatus (`:79–95`).

This yields competing explanations that the bounded evidence cannot distinguish:

1. The helper navigates before the asynchronous placement result/current parent hierarchy is ready, then continues backing out because the target is still absent.
2. Removing the currently active handoff NavigationLink changes navigation during the same interval, so a generic Back tap operates on a different level than expected.
3. The correct parent remains, but its arrival link is not instantiated/visible in the current lazy List viewport, and the helper interprets absence as a need to pop again.
4. Placement reports an error or remains pending, so arrival never becomes eligible. There is no retained state assertion/hierarchy proving or disproving this.

These are source-supported discriminating cases, not causal conclusions. A successful native Back event itself does not identify the destination reached. The current PickupHomeView and RoomInTheCartApp byte-match frozen 0d5 source; the model's later fresh-closing edit is unrelated to reportPlaced.

## Next diagnostic, not a proposed fix

Preserve the exact scenario and save/placement gates. For one owner-controlled diagnostic, retain a synthetic-only state checkpoint immediately after the existing placement tap and at each return-loop iteration: visible navigation titles and Back-button labels/identifiers/frames, target match count/exists/hittable/frame, placement-status text, Save error/progress presence, and screenshot/hierarchy. Record which candidate is selected and what navigation title exists after each unchanged Back action. If visible state cannot establish the save boundary, a separately identified diagnostic model trace may record only save started/completed/failed and basket phase/pickup presence—no full ledger payload.

That sequence distinguishes a pending/failed save from automatic navigation change, an absent lazy row, or a helper overshoot. Do not add blind extra Back taps, retries, sleeps, relaxed gates or a direct app-state route as a fix. If placement is not yet durable, asserting its successful visible state is a candidate synchronization contract for review, not a justified implementation change until the diagnostic establishes it. If the arrival target is merely uninstantiated on the correct parent, the helper needs a source-aware reveal strategy, not more popping; if navigation truly disappears on commit, investigate the product's conditional link lifetime.

Bounded result: navigation-test failure confirmed; root cause unresolved. No new execution or tracked changes performed.

## Addendum — retained frames and narrow one-tap correction

Independently viewed only root-provided `frames/frame-323.png` through `frame-326.png`. Frames 323/324 show the Retailer handoff report-placement control mostly under the floating tab bar; frames 325/326 show Pickup with **Frozen · placement unconfirmed**, no arrival link, and the ordinary checkout/handoff links still present. This narrows the earlier hypotheses: the failed return is consistent with an ineffective/occluded placement tap followed by the helper backing out of the unchanged parent. It is not evidence that a successful placement removed the arrival route. Root separately reports the digest-verified event UUID `3ABF2E7D-EF04-4127-AC0B-5BB542A8A613`, time `1794012111.818`, point `(17,786)` matching the t323.98 placement tap. This review did not independently parse that event or reopen the archive; pixel frames are not used as point coordinates.

**Approve the proposed bounded test correction in principle:** reveal this specific report control fully above the measured content bottom, verify real enabled/hittable state and nonempty frame, then invoke exactly one unchanged native `.tap()`. Retain the whole journey, input/quantity/state checks, and existing time budgets. No production change, second tap, direct placement call, state seeding or sleep is justified. The current generic `reveal` returns on hittability alone (`FreeJourneyUITests.swift:1274–1289`), which is insufficient for this demonstrated occlusion.

Geometry detail: `scrollableArea():1291–1310` intentionally insets horizontal bounds by 24 points for safe drag gestures. That is not the actual width of every full-row control. A button accessibility frame may start at x16, so requiring `scrollableArea().contains(button.frame)` could never succeed even when the control is fully visible. Require the entire vertical frame within its measured top/bottom, with horizontal containment against the app/content viewport rather than the narrower drag corridor. Keep the direction adaptive from the target frame; fail if full visibility cannot be obtained within the existing bounded attempts. Record the final frame/viewport once for review.

**Strongest existing public-UI posttap assertion:** on Pickup, require the exact status text **“Placement reported · original order locked”**, then require **“Record what came home”** to be actionable. The former directly reflects `.reportedPlaced`; the latter requires a nonnil PickupLedger (`PickupHomeView.swift:21,29–32`). Those states are published only after the model's durable save succeeds. They are stronger than the report button becoming disabled: that can also mean transient `model.saving` or stale stock, and therefore is not placement proof.

To observe that state without repeating the failure's blind navigation loop, use the current named navigation bar: if still on **Retailer handoff**, tap its native Back once; if already on **Pickup**, do not pop. If neither expected route is established, retain a failure rather than tapping an arbitrary leading control. Await the positive placed status using the existing bounded assertion policy, then access arrival; do not navigate farther simply because arrival has not yet appeared. The owner should preserve these steps as an explicit outcome assertion, not silently broaden generic navigation behavior. In the expected small Pickup list the status and arrival row are near the top; a reveal, if needed, must stay on this verified parent route.

Do not substitute `Reopen draft and recheck prices` disappearance alone: lazy offscreen absence or leaving the handoff screen can satisfy it without placement. It can supplement a positive status assertion if its prior presence was established, but cannot replace the durable state text. No new persistent-status wording is needed.

Limits: frames prove occlusion and subsequently unconfirmed placement; they do not directly prove whether the app's placement action callback was invoked. A successful corrected one-tap journey will be the runtime check, not this source approval. No native execution or tracked edits performed.
