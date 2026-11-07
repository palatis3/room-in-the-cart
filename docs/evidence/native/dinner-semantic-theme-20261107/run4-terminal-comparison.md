# Run4 failed Dark and passed Light comparison

No production fix is justified by this evidence. Recommend the already prepared **event-only** Dinner diagnostic next, retaining optional app-layer inspection for a later, separately chosen question. The terminal trace positively shows keyboard hide completion in the failed case, while unmatched animation-stop warnings also occur repeatedly in the passing case. Neither absent app-handler instrumentation nor those warnings alone identifies a cause.

## Provenance and terminal outcome

Read only root's filter-receipt.json and552514-byte selected-events.json, not the1.18GB raw log. The selected SHA2562036060597c660930df5671e0f5432e1c2e8f8e242931b8b3b2a32d49aa9d150 matches the receipt; all626 entries were parsed. The receipt reports762922 original objects, complete bounded filtering and unchanged original digestc7b4a863d3ac8bf75778ce6541536f9e6a0f7016f06254cc0cc3bc1f9423c142. That original-byte verification belongs to root's collector; this agent did not independently load/hash the large raw log.

Root reports native65/strict1 and owned-simulator cleanup. The terminal native log independently records Dark exceeding its original12-minute allowance, one implicit runner restart, and Light passing195.075seconds. The restarted runner's final Selected tests suite says passed; it must not be used to erase the earlier timeout or call the whole invocation passing. Native logging continues to+760.61 after the12-minute allowance message as an already-running action finishes its wait; this is not evidence that the limit was raised or a second Dark attempt occurred.

| Observed trace | Dark PID30046 | Light PID32426 |
| --- | ---: | ---: |
| Selected events |117|509|
| Idle-notification requests |35|163|
| Idle replies |22|163|
| Unmatched animation-stop warnings |13|64|
| Native missing-completion notices |12, including one after allowance report|0|

Counts describe this retained filter, not uniquely identified request/reply pairs: framework messages have no correlation ID. Both incarnations have executable UUIDC0F621A6-D8EF-34AE-A82C-DDB7BA1FFC5C and the same simulator boot UUID. This supports a common app executable; exact product/source binding remains with root's build manifests. Original case assertions and visual-v4 input remained unchanged.

## First title Done is the informative boundary

Dark's title Done event is synthesized at test+29.18. The bounded system chronology is:

-01:52:43.934218-0500: idle request; reply43.934269.
-01:52:44.223139: TextInputUI tracking begins an offscreen keyboard transition.
-01:52:44.226735: keyboard willHide notification is posted.
-01:52:44.406055: another idle-notification request.
-01:52:44.642199: keyboard didHide notification is posted.
-No later idle reply appears in the captured Dark PID trace, although requests continue through02:04:55.970236 and keyboard transitions/notifications continue.

Light's equivalent first title Done is synthesized at test+21.96:

-02:05:23.069268: idle request; reply23.069317.
-02:05:23.332482: offscreen keyboard transition begins.
-02:05:23.336058: willHide is posted.
-02:05:23.516879: idle-notification request.
-02:05:23.752513: didHide is posted.
-02:05:23.756756: an idle reply follows,4.243ms after didHide, and ordinary queries proceed.

These exact windows are retained in first-done-windows.json. Dark's willHide→didHide interval is415.464ms; Light's is416.455ms. The similar posted-hide intervals and later screenshot showing servings3/caret/keyboard argue against declaring the keyboard failed to hide or all input froze. Framework posting is not proof that DinnerTemplateEditor's subscriber/Done closure/focus binding observed the transition, that all remote rendering completed, or that every frame was responsive. No app-handler event instrumentation was enabled in these products.

Dark's unmatched-stop messages occur01:52:38.041–40.253, before the first stalled Done, with several successful idle replies afterward. Light records64 such warnings yet completes every assertion and capture. Therefore warning occurrence is not sufficient to cause the observed failure; it remains useful contextual evidence, not a repair target by itself. Do not infer that exactly13outstanding requests correspond to exactly13warnings—matching totals are not causal correlation and the request stream has no IDs.

## Difference from interim evidence

The earlier live-observation default-level subset contained animation requests and keyboard state-start messages but no complete framework-posted hide pair for the problematic Done. The terminal query added --info/--debug and exposes willHide/didHide positively. This updates the boundary from merely an attempted offscreen transition to an observed posted hide completion. It does not retroactively prove the earlier capture delivered all events. The original interim report remains unchanged, with its narrower observation limits.

The terminal subset includes only the two app PIDs, even though the filter predicate allowed bounded KeyboardArbiter completion messages from other processes. No cross-process keyboard-service continuity or complete process coverage can be inferred from the absence of those selected rows. The framework's event timestamps, native test-relative timestamps and logs are correlated by known process/test windows; this is not instrumentation of the same call stack.

## Confounds preserved

Dark is the first case; Light follows the timeout and a new XCTest runner/app incarnation. Appearance, OS/keyboard history, elapsed warm-up, process state and recovery effects all differ. Earlier Dark run2/run3 executions reached the much later added idea probes, so this is not evidence of a deterministic Dark-only defect. Passing Light shares runtime/device/executable but is not a randomized appearance control. The read-only live screenshot/log export adds observer overhead after the initial failure boundary; the larger terminal export happened after the invocation ended. None is assigned causal responsibility without evidence.

The stall precedes all added v2/v3/v4 idea-review helper/reveal probes. Source preservation checks already establish the early v4 path matches v3. Later lazy-row/test-interaction corrections do not explain an unexecuted earlier path. Theme composition can still affect timing in principle, but previous progress plus no controlled comparison means neither exoneration nor blame is proven.

## Minimal next diagnostic decision

Use the existing DinnerKeyboardDiagnostic20261107 candidate with DEBUG and DINNER_KEYBOARD_DIAGNOSTIC, **without DINNER_KEYBOARD_LAYER_DIAGNOSTIC**. It observes the presently missing app-level boundaries around the unchanged Done focus write and focus transitions, plus received public keyboard notifications. Those observations can distinguish "handler returned/focus changed/received didHide yet XCTest waits" from a missing or delayed app-level boundary. Preserve exact visual-v4 harness and product parents, original two selectors/serial ordering and existing allowances; no retry, prewarm, altered responder behavior or quiescence override. Root chooses the separately identified experiment; this report executes nothing.

Layer inspection is not needed to establish those app-level events and adds synchronous hierarchy traversal, serialization and UIKit/CoreAnimation getter overhead. Keep its12-snapshot/512-layer/64-configuration bounds and explicit remote-keyboard limits if root later needs to ask whether attached app-owned timing configurations persist after positively observed focus/hide completion. Even then it cannot see remote keyboard animations or XCTest's tracking state, and attached finite/infinite configurations are not a causal proof. A passing instrumented run remains nonreproduction, not a keyboard fix.

Source review of the candidate found no justification to broaden or change it now: compile/runtime gates exclude ordinary builds; only the original focus-nil statement changes formatting; all later product logic and the full v4 harness remain byte-identical; no product strings/state are logged; events are capped. MainActor.assumeIsolated in notification callbacks remains the documented diagnostic runtime precondition requiring actual build/runtime review. The code is source-only, not compiled/typechecked. OSLog loss, subscription/coalescing, event caps and diagnostic timing effects must remain explicit in interpretation. No production patch is prepared.

The separate IdeaSupplyTheme proposal is preserved and excluded from this experiment. Full V1 and final two-mode theme acceptance remain open; a single healthy Light case does not close the failed Dark case.
