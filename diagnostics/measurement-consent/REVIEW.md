# Exact-candidate consent diagnostic patch

Prepared against `804030e68473d022e72b464940061c01c611a0bd`, not current HEAD 0500ca3. `original/`, `modified/`, `instrumentation.patch`, `manifest.json`, and `static-review.json` contain the complete reviewable overlay and proof. It is a diagnostic proposal, not a consent fix. Shared checkout remains clean. No source installation, native build/run, Git mutation, hosted operation, or retry occurred.

## Four source changes

- `ios/Features/Pickup/PickupFeedback.swift:89–94`: emit consent setter enter/exit, rejected missing workspace, and explicit reset events around existing operations. Keep the nil guard, notice-version lookup, dictionary mutation, and UserDefaults write. A new DEBUG-only MainActor OSLog helper accepts only a fixed event enum and optional booleans; it cannot accept workspace IDs, hashes, freeform values, storage keys or payloads.
- `ios/App/RoomInTheCartApp.swift:399`: expand only the existing Settings binding setter, keeping the getter and one-argument Binding initializer. Emit entry/exit around the single original synchronous call. Snapshot workspace locally only for a same-workspace Boolean; the production write still evaluates `pickup.sourceWorkspaceID` as before. No Task, transaction override, observer, gesture, or view modifier is added.
- `ios/UITestSupport/MeasurementUIFixture.swift:160–161`: emit `fixture.ready` after original successful setup, immediately before publishing household. The file already requires DEBUG and the fixture compilation flag. Ready/present/distinct booleans describe both local models without emitting their IDs.
- `ios/UITests/MeasurementUITests.swift:106–110`: forward the explicit `RITC_MEASUREMENT_CONSENT_DIAGNOSTIC` runner variable into every app launch as `1` only when the runner says exactly `1`; otherwise `0`. No tests, taps, reveal loops, assertions, restart order, launch arguments, existing workspace/reset environment, or timeouts change. Static comparison confirms the entire test source is identical after removing these three added forwarding lines/comment.

The app logger additionally requires DEBUG, `--ui-testing`, and the forwarded app variable equal to `1`. Release excludes the helper and log calls. Disabled Debug logging avoids added consent/workspace getter evaluation; the nil/reset hooks enter a helper that immediately returns. No production preference or household consent scope broadens.

## Structural schema and interpretation

Subsystem: `dev.roominthecart.measurementconsentdiagnostic`; category: `events`; level: info. Each event has a process-local sequence starting at 1, monotonic system uptime, fixed event name, and these fixed Boolean fields encoded 1=true/0=false/-1=not applicable:

`requested`, `ready`, `workspacePresent`, `enabledValue`, `sameWorkspace`, `otherReady`, `otherWorkspacePresent`, `workspacesDistinct`.

No domain identity, text, number from app content, dictionary contents, errors, file paths, or actual timestamps from saved data is emitted. OSLog's own process metadata distinguishes launches. Sequence is only a diagnostic counter, not an identity. Logger activity itself may perturb timing.

A positively captured `binding.enter(true)` → `consent.set.enter(true)` → `consent.set.exit(enabledValue=true)` → `binding.exit(enabledValue=true,sameWorkspace=true)` proves that synchronous write/readback occurred for that delivery. It does not prove disk durability, animation completion, UI update, or exact timing of a later accessibility read. A later captured false/reset is a potential reversal only if it precedes the failed read. A captured missing-workspace rejection supplies a concrete branch. Absence of setter logs is never automatically evidence that no setter ran.

## Capture plan: retain live and persisted evidence separately

Prior evidence is concrete: `.build/KeyboardDiagnostic20261106/baseline-independent-review/REVIEW.md:29` reports live 74/export 39 baseline events and live 110/export 87 candidate events, with entire app launches missing from persisted exports. Both live capture processes were alive before stop. Alive status therefore does not establish delivery completeness; successful export does not establish completeness either.

If root later authorizes execution:

1. Use only the reviewed overlay and freeze source/product hashes. Explicitly set the flag in the XCTest runner environment (for example in a separately retained diagnostic xctestrun copy's test-target EnvironmentVariables). Do not assume a shell/xcodebuild variable reaches that runner or app. Retain the sanitized opt-in configuration, keeping other environment values/credentials out of evidence. Require the positive per-launch fixture marker to establish app opt-in was active.
2. Before the single original contributor-balanced-02 invocation, start simulator `log stream` with info events and the exact subsystem/category predicate. Capture stdout and stderr to separate files. Record capture command/start outcome and process liveness around the invocation; do not insert sleeps, readiness polling, new app events, or additional XCUI observations into the test sequence. The root owns hosted configuration and preservation of all seven selectors/predecessor ordering.
3. Keep the live stream through the invocation and app teardowns. Export the same narrow predicate from persisted logs for the bounded invocation time window before simulator cleanup. Retain export exit/stderr, live-capture liveness and termination outcomes, XCTest logs/result bundle, and source/product hashes. Stream and export are independent artifacts; never overwrite the live stream with the export. This proposal adds no collector/workflow command or execution.
4. Reconcile each stream by OS process metadata plus sequence/uptime/event and Boolean fields. Retain counts, duplicate/conflicting tuples, missing process markers, internal sequence gaps, and events present only in one source. Keep raw originals and parser output. Missing markers, gaps, collection errors or reported dropped logs make a negative inference especially unsafe.
5. Even agreement, gap-free observed sequences, healthy stream exit and fixture markers **do not prove exhaustive delivery**. An unseen final suffix or whole launch can be omitted without an internal sequence gap. In the failed-first-toggle case, fixture.ready may be the last visible event; lack of a later setter remains “not observed,” not “did not run.” Positive events are stronger evidence than absence. Do not label a no-setter result a framework bug or a targeting fault.

The original tap coordinates/AX frames and retained failure screenshot support geometry and visible state, not the actual UIKit delivered hit target. Without setter evidence, hit routing, gesture cancellation, UIKit control activation, SwiftUI forwarding, and log loss remain distinct possibilities. Actual runtime target/action tracing would require a separately reviewed probe; no hitTest call, swizzle, custom recognizer, replacement control, overlay or touch hook is introduced here.

## Static validation and limits

All four originals match exact 804030e; proposed-file and patch SHA-256 values match `manifest.json`. Patch dry-run succeeds against scratch originals. Static checks preserve the original getter and one binding write, consent mutation/defaults write, and every test action/assertion apart from explicit launch-environment forwarding. Shared `git status --porcelain` is empty. No Swift parse/typecheck or build was performed; root must review and compile the overlay under the selected toolchain before any diagnostic execution. The unchanged local control's pass remains nonreproduction, and any diagnostic pass would likewise leave the original hosted failure unresolved.
