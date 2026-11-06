# Keyboard event instrumentation proposal

Base: `d0b0b12ee0cb8412f17e82c92a91013217560670`, extracted with `git show`; current persistent-label and FreeJourney helper changes are intentionally absent. Only the two requested files are modified. `original/`, `modified/`, `instrumentation.patch`, and `manifest.json` retain exact content and SHA-256 provenance.

Enable only in a DEBUG app by setting its process environment `RITC_KEYBOARD_DIAGNOSTIC=1`. The parent owns launch configuration, compilation and execution. No test or workflow is changed here. When the flag is absent, observers are not installed and the stock Toggle receives the original `$checked` binding. Release compilation excludes the diagnostic helper and observers.

Event sink: OSLog subsystem `dev.roominthecart.keyboarddiagnostic`, category `events`, info level. Capture with an external narrow predicate matching both fields and info logging enabled, starting before app launch. `observer.installed` confirms activation; retain capture startup/finalization status so absent logs cannot be interpreted as absent UI events.

The trace contains only an event enum's fixed name, `ProcessInfo.processInfo.systemUptime`, and static file/line context. It never reads text, identifiers, user/household/food/lot identities, notification objects, notification userInfo, keyboard payloads, or account/model data. No wall-clock input data is emitted. Host OSLog timestamps provide wall-clock correlation; uptime orders app events within that process.

Events:
- `done.enter` and `done.exit` wrap the unchanged dismiss closure. Exit means the synchronous focus write returned, not that dismissal completed.
- `focusIndicator.on/off` observes the existing modifier's `visible` argument. Its static call site distinguishes callers. This is an aggregate focus-present indicator; it does not observe changes between two non-nil quote focus identifiers.
- `stock.focus.on/off` directly observes the existing amount FocusState.
- UIKit keyboard will/did show/hide/change-frame and UITextField/UITextView begin/end editing notifications. They are process-wide events, not attributed to a specific field; no notification payload is captured.
- `stock.toggle.setter.true/false` records the existing identity Toggle's setter before forwarding the same value and transaction synchronously to the original binding.
- `stock.reset.amount/food/observedAt/useFirst` records each of the four existing reset handlers immediately before its original `checked = false; cancelPreview()`. A reset event may occur while already false; it does not itself assert a true-to-false transition.

Isolation/lifetime:
- The helper is `@MainActor`; the shared modifier is explicitly `@MainActor`.
- NotificationCenter observers use `queue: .main`; their Sendable callbacks capture only the fixed Sendable event enum and enter `MainActor.assumeIsolated` synchronously. No Notification crosses actors or enters a Task.
- The Toggle's UI setter enters `MainActor.assumeIsolated`, preserves its supplied Transaction, then writes immediately. This assumes the existing UI Toggle setter runs on the main actor; the parent must validate compilation under the hosted Swift toolchain. There are no asynchronous hops that reorder the recorded state write.
- Observers install once from the existing modifier's onAppear and live for the app process lifetime. No timer, polling, repeated registration, hidden view, layout measurement, gesture, responder resignation, or animation modification is introduced.

Interpretation: Done delivery absent versus FocusState clearing absent versus keyboard ending absent versus completed transitions followed by XCTest idling are separate outcomes. A Toggle setter followed by a named reset differs from no setter delivery. Notification absence alone is inconclusive unless activation and continuous capture are proven. Instrumentation can alter timing; a pass is not a causal diagnosis or replacement for retained failures.

Recommended parent validation: compile the exact scratch sources under the hosted profile, keep original test assertions/idleness/720–900 second allowances, select the original StockReview failing test once, and retain OSLog plus result/AX/screenshots and immutable source/product hashes. Do not repeat merely to obtain a pass. UIKit resignation remains unimplemented and unproven.

Validation performed here: source inspection, exact-base/diff manifest generation, and patch dry-run only. No Swift parsing/typechecking, build, simulator, hosted/network action, commit, or shared-source modification.
