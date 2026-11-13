# Scratch-only matched-state diagnostic proposal

The original failure remains unresolved; this patch is instrumentation, not a causal fix. It has not been installed, compiled, or executed. `git apply --check` passes against source HEAD and file hashes pinned in `proposal-receipt.json`. The original screenshot, runner delivery receipts and source audit are in the parent directory.

The existing `DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE` support file gains an opt-in `S24PackTrace` helper. The existing test setup passes its XCTest case name through `S24_PACK_TRACE_SCOPE`. Logging additionally requires the existing `--ui-testing` and `--request-pack-fixture` arguments. Marker fields contain only monotonic system uptime, PID, the test name, fixed event/pack tags, already-generated draft UUIDs, and Bools. No request IDs, labels, prices, source text, network payload or private user text is logged.

The matched Toggle's diagnostic binding forwards the original value and transaction once. It records setter-enter (old/requested) and setter-return (old/current). Existing first/second onChange callbacks log before their unchanged reset(); appearance/disappearance callbacks log existing draft UUIDs and matched values. No new @State, view identity, UI element, action, query, delay, retry or timeout is introduced. Non-fixture/release builds use the original binding and compile no trace helper/lifecycle hooks. Logging and wrapping the binding can still affect timing in the diagnostic build, so a pass cannot resolve the original failure.

All case bodies and helpers are byte unchanged. The only test edit is the setup environment marker; the original coordinate tap, immediate readback and full journey assertions remain exact. Preserve the original shard context: the failed case is FIFTH overall, after both HouseholdDevices cases and the cereal/protected-lunch and largest-text pack cases. `original-shard-selectors.txt` retains all10 original selectors, and `original-prefix-through-failure.txt` retains that exact five-case prefix. Preserve actual execution order in the native receipts; selector-list order alone is not a scheduling guarantee.

| Trace around the unchanged tap/readback | What it supports | What it does not establish |
|---|---|---|
| Successful trace initialization/appearance, completed app touch event, no setter-enter for that draft | The diagnostic binding did not observe a setter invocation in the retained trace | Which UIKit/SwiftUI hit handling path consumed the touch; absent/truncated logs cannot prove absence |
| setter-enter requested true; setter-return true; same UUID change true | Binding received true and local state exposed true at those observations | Accessibility value must already be current, or state cannot change later |
| True followed by false for the same UUID | A later observed write/state change reverted matched | Which code caused it unless paired setter markers identify the write; onChange may coalesce intermediate updates |
| Disappear/appear with new draft UUIDs | Pack-editor draft storage was reconstructed between observations | Why the ancestor identity/condition changed; appearance alone with same UUID is not reconstruction |
| True retained for same UUID, immediate XCTest readback0 | A discrepancy between observed model and accessibility state | A framework cause or safe wait/retry fix without further evidence |
| Same-context full journey passes | This diagnostic attempt did not reproduce | The hosted failure is resolved, or the original event/reset cause is known |

Review and run only after the current ordinary journey completes. Preserve original OS settings and all warning/count gates. Collect stdout alongside native result so marker delivery can be checked; retain any runtime diagnostics even if structured warning count is zero. Remove the temporary instrumentation after investigation; do not ship it as a fix.
