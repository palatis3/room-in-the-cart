# UI04 comparison-entry focus review

**No causal product defect is established by the retained failure.** The first comparison-entry pass failed typing `6` after the Pack B quantity tap, before comparison results or the accessible Edit control were reached. Keep this separate from Edit layout and the Spanish UI07 Done/idle investigation. Read-only source/log review only; no native action, tests, source/Git change, media extraction or network. Collector owns archive/source/run provenance verification.

## Source and retained observation

Current `RoomInTheCartUITests.swift`, `ComparisonView.swift` and `Theme.swift` byte-match their retained 0d5 candidate-verifier copies. Hashes are in `source-references.json`.

- Test `RoomInTheCartUITests.testLargestTextEditActionGrowsInContentAndReturnsToEntry` (`ios/UITests/RoomInTheCartUITests.swift:207–225`) launches English, dark, accessibility XXXL (`:460–469`), opens the blank comparison and enters all values before comparing/editing.
- `enterComparison:481–488` fills item, needed, A quantity, A price, then B quantity. `type:556–567` reveals/taps the field and immediately calls `app.typeText`; it does not positively observe focus/keyboard acquisition between those actions. It deliberately types through the application because keyboard layout can recycle large Form rows, then verifies the intended value after Done. Those value checks should remain.
- `reveal:581–599` stops on exists+hittable, selecting the first native collection/table/scroll container. It is not a full-viewport/settled-frame assertion. A synthesized tap is not proof of first-responder acquisition. This is an observability gap, not sufficient evidence that the helper caused the failure.
- `ComparisonView.swift:91–92,110–135` uses the same numeric entry implementation for both packs: decimal TextField, unique `aQuantity`/`bQuantity` focus IDs and identifiers. The surrounding VStack label is separate from the field. No `bQuantity`-specific handler, duplicate binding or explicit scroll-dismiss modifier is present. `inputFocused` is cleared by Done (`:42`) and Compare (`:99`), not by a custom background tap gesture. `Theme.keyboardDoneAction:24–40` conditionally adds the bottom Done inset and invokes the supplied synchronous dismissal closure; no delayed/asynchronous dismissal is scheduled there.

Retained `Tests.log` local sequence:

- `:2624–2643`: A price receives `3`, Done taps successfully, and its value is read before proceeding.
- `:2644–2653`: B quantity is not initially available to the helper, one collection swipe runs, and the subsequent exists/hittable path returns.
- `:2654–2660`: tap B quantity begins at t77.86; event synthesis t79.59; app-idle wait t79.94; type `6` begins t79.95.
- `:2660–2670`: XCTest searches for keyboard focus, then fails at t81.38. Automatic type-event retries at t82.52 and t85.04 also fail. There is no helper re-tap. These retries therefore do not establish whether a second user tap would work.
- First failure hierarchy `:2672–2810` contains one `bQuantity` TextField at x32,y489,w338,h64. Navigation bottom is y116; tabs start y791. The field is fully inside that visible vertical region at failure time. There is no Keyboard, Done button or Alert node in that snapshot; later failure snapshot repeats the same field geometry. Pack B unit control is below it, not an obvious overlapping node in the retained hierarchy.

The hierarchy is **after** the event. It does not supply tap-time hit point, pre-tap geometry, first-responder transitions, or the SwiftUI focus value. The broad identifier query/firstMatch is theoretically ambiguous in other states, but this retained snapshot supplies only one B quantity candidate and does not support a wrong-duplicate diagnosis. Likewise, visible final geometry does not prove the tap-time geometry was stable. No retained evidence establishes hardware-keyboard configuration as the cause; the preceding numeric inputs worked.

## Smallest discriminating diagnostic for the owner

Preserve the same selector, launch flags, field order, native tap, gestures, timeouts and final assertions. Scope diagnostic capture to the transition from A-price Done to B-quantity input; do not introduce a retry, coordinate tap, focus setter, text injection or longer wait as a purported fix.

1. Immediately before the existing B tap, retain field match count, exists/hittable/enabled, frame, collection frame, navigation/tab boundaries, current keyboard and Done presence, plus a screenshot. After the existing tap returns and **before** `app.typeText`, record the same facts. Record timestamps/order and a failure snapshot. These are synthetic-fixture diagnostics; values need not be logged.
2. This separates a partial/unstable/obscured pre-tap target from a fully visible target that still has no observable input UI. Keyboard or Done appearance after the tap would establish more than the current log, but Done visibility is only a proxy for nonnil SwiftUI focus and neither proxy alone proves UIKit first responder.
3. If that single-tap capture still cannot distinguish never-acquired from acquired-then-lost focus, use a separate compile-guarded, diagnostic-only app trace of `inputFocused` transitions (allowlisted field IDs/nil) and keyboard will/did show/hide notifications with monotonic sequence/time. No text, draft values or global production instrumentation. An ID transition to `bQuantity` followed by nil would distinguish loss from no observed SwiftUI acquisition; keyboard events still do not prove exact UITextField responder identity. Do not claim the previous Done caused loss unless the ordering/source event supports it.

Extra snapshots/tracing can perturb timing, so a diagnostic pass is not a fix or proof that the original failure disappeared. A new isolated failure or pass should retain its changed instrumentation/source identity. Do not narrow assertions to skip initial entry or mark the later Edit behavior passed based on this failed test.

Outcome: source shows a missing focus-acquisition observation at the harness boundary; retained evidence proves no keyboard focus at dispatch, but not why. No source change is recommended from this evidence alone.
