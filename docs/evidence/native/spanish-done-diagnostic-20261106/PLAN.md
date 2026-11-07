# Next Spanish Done diagnostic

Recommendation: prepare one diagnostic-only build from exact b359d0743c2db77bb81a00a1c7e69036aa12ab77, then run only the complete original Spanish comparison selector once on the original hosted toolchain/runtime. Capture app events and visible layout independently of XCTest, so the first 60-second idle wait cannot prevent the evidence from being recorded. This assessment prepares a concrete plan, not an implemented overlay or a dispatch.

## What the existing evidence establishes

UI02's original order is recipe capture, PickupOffer, comparison deletion, then Spanish comparison. The first and third passed, PickupOffer failed at its out-of-viewport approval, and Spanish then timed out. Spanish typed bQuantity = 6 at 49.47–50.29 seconds. Listo's event was synthesized at 52.217, followed by idle from 52.549 to 112.599. Eleven 60-second animation waits are recorded. The event point (364, 544) is known, but the retained snapshot has only the app root, with no button/field/keyboard frame. There is no retained PNG; the screen-recording attachment is a 60-byte pending-attachment error. The later bQuantity readback does not establish that Done was delivered or the keyboard disappeared.

Relevant evidence: `.build/CIResearch20261105/candidate-b359d07/core-collection/evidence/ui02-failure-triage.json`, `iphone-results-ui-02-1/Tests.log:1717`, and the Spanish attachments named by that triage file. All read input hashes are in `source-and-evidence-sha256.json`.

## Why prior diagnostics do not settle this

- Stock diagnostic 169613b was built from d0b0b12, before the later Done-label hit geometry change. b359's Theme already places minWidth 44, minHeight 44 and contentShape on the Text inside the Button. Replacing b359 Theme wholesale with the old diagnostic Theme would silently undo that change. Adapt only event hooks around the existing b359 closure; preserve its exact view hierarchy and modifiers.
- ComparisonView and RoomInTheCartUITests have identical SHA-256 at d0, 169 and b359. The current checkout also matches b359 for these two files and Theme, but this is not an equivalence claim for the entire current tree.
- The earlier single-stock run had matching 23 live and 23 exported events. The six-case history run passed all six tests but had 46 live events and zero persisted events; analysis correctly failed. Exit 0 from `log show`, and a live stream process, do not prove event capture completeness.
- Only StockReviewUITests forwarded the opt-in environment into the app in the 169 source. The first four history cases had no event PIDs. Their absence must not be read as proof that those screens emitted no keyboard events. The Spanish test needs its own explicit opt-in forwarding.
- Prior history used contributor fixture binaries and a different six-case prefix. It did not execute the Spanish core comparison failure. Its passes are nonreproduction of another experiment, not a fix or a Spanish control.
- Original UI02 used Xcode 26.3 / iOS 26.2 (23C54), iPhone 17. The prior hosted diagnostic recorded Xcode build17C529 and macos-15 image20261028.0489.1. Local tooling was27.1/27A9275; a local27.x pass can validate instrumentation wiring but cannot replace the representative hosted26.3/26.2 observation. Record actual hosted image drift rather than claiming identical VM state.

## Small source overlay to prepare

Keep all three files based on exact b359; restrict additions to DEBUG plus an explicit `RITC_SPANISH_DONE_DIAGNOSTIC=1` environment flag. No UI appearance, accessibility identifier, timing allowance, action, assertion, focus write, or gesture is replaced.

1. **Theme.swift:** reuse the existing public UIKit notification-observer design, recording keyboard will/did show/hide/change-frame and text-field/text-view editing begin/end. Wrap the existing dismiss closure with done.enter and done.exit events, leaving its original synchronous invocation exactly once between them. Observe the existing aggregate `visible` argument. Retain b359's Button(action:) + Text label geometry verbatim. All records include a fixed call-site tag so only the comparison modifier is attributed to this experiment; process-wide notifications remain explicitly unattributed.
2. **ComparisonView.swift:** add a DEBUG, opt-in observer of its existing inputFocused state. Emit only a whitelist of fixed focus tokens: itemName, needed, aQuantity, aPrice, bQuantity, bPrice, none, other. Do not log model/field contents. This distinguishes a transition from bQuantity to nil from merely observing aggregate focus present. Leave `inputFocused = nil` and all keyboard/body modifiers unchanged.
3. **RoomInTheCartUITests.swift:** forward the diagnostic opt-in to app.launchEnvironment in the existing launch function. Inside `type`, bracket the existing done.tap() with a flushed runner marker only for id == bQuantity. Include runner PID, uptime and before/after labels; no extra accessibility query, screenshot, tap, wait, or result assertion is inserted between typing and Done. Keep the original waitForExistence(3), the single done.tap(), reveal(field) and exact value readback. All business, persistence, deletion and restart assertions remain.

Do not copy the stock Toggle instrumentation; it is unrelated. No private XCTest/quiescence APIs, focus manipulation, responder resignation, animation changes, keyboard-default changes, reset beyond the original test launch, or tap retry.

## Capture that survives an idling test runner

Use two app-event sinks from the same opt-in record function: narrow OSLog and a small per-process append-only journal under the app's diagnostic directory. Each record contains only monotonically increasing sequence, PID, process uptime, fixed event, fixed site/focus token. Write each complete line through FileHandle without a process-side buffer; surface any open/write error and mark capture incomplete. No per-event fsync is needed for this non-power-loss experiment; copy files while the owned simulator is still present. A partial final line or failed extraction remains incomplete. File writes/observers and recording may alter scheduling; retain that limitation even on a pass.

Start live OSLog and a host-owned simulator video process before the test invocation. Record child PIDs/start times and command exits. Validate the capture processes are alive before launch; the journal's observer.installed and PID establish the actual app activation. The external video must not be an XCTest attachment, which already failed to finalize in this run. A host watcher may take a bounded pair of simulator stills at approximately 5 and 15 seconds after the flushed before-bQuantity-Done marker. These are observations only: no tap, UI activation, or extra XCTest query. Continuous video supplies the actual pre-tap and transition frames; timed stills alone do not establish those exact instants.

Preserve default XCTest idling and the complete selector. If it stalls, allow the existing 720/900 allowances to apply, then use an always-run host collection step even on timeout. Collect the app journal from the exact owned app container before simulator cleanup, raw live log, independent log export, Tests.log, xcresult and available attachments. Stop only the owned video process with its supported graceful stop signal and wait for finalization; record status. Verify a decodable, nonempty video or valid still images, not merely a path/extension. Bound collection separately without widening test deadlines. Keep source/product/selector hashes before and after execution and all command exit statuses.

Compare journal sequence against live/exported events per PID and call site. An empty export still means export capture failed even when the journal/live path is usable; preserve both the original test outcome and the independent capture outcome. No absent-event conclusion is allowed when the app journal failed, the relevant process wasn't opted in, or the observation interval is unbounded.

## One narrow run, then an evidence decision

Build the original core Debug scheme once, with no contributor compilation-condition override. Rebuild from b359 plus the reviewed instrumentation; 169's compiled products have the wrong source/layout/profile. Freeze these new products and enumerate to confirm the original selector exists exactly once. Run `selectors-singleton.txt` using test-without-building, one runner invocation, parallel testing NO, test timeouts YES, default720/max900, collect-test-diagnostics never. Keep the original strict result/warning validator. Record fresh owned simulator identity and guarded boot evidence; do not erase or touch a preview device.

A singleton removes UI02's three-case predecessor history and is deliberately the smallest causal-observation attempt. A pass is nonreproduction. Do not automatically repeat or claim the issue fixed. If the singleton has complete captures but no stall, a separately reviewed next experiment can execute only `selectors-original-ui02-history.txt` once, on the same frozen instrumented products in a newly owned simulator. Preserve its exact order and the original PickupOffer failure; do not silently apply the new viewport fix, which would lengthen/change predecessor history. That four-case diagnostic is still separate from full CI and cannot be reported as all-pass release acceptance.

## Interpretation of a captured stall

| Observation at the bQuantity Done | What it supports / what remains unknown |
|---|---|
| Synthesized tap, no done.enter | Delivery or app responsiveness is unresolved. With complete capture and subsequent app events, supports that the existing closure was not entered; it does not prove a hit-test cause. Use video to place the touch relative to Listo. |
| done.enter/exit, focus remains bQuantity | Dismiss closure ran and returned; the expected focus transition was not observed. Does not establish which layer prevented it. |
| focus none, keyboard hide missing | Logical focus cleared; UIKit keyboard transition is incomplete or unobserved. Journal/capture continuity and video are necessary. |
| done.enter/exit, focus none, editing ended, didHide and stable keyboard-free view, but XCTest waits60s | App-side dismissal completed observationally while XCTest still waited for animation completion. Does not by itself prove an XCTest bug or exclude another app animation. |
| No stall with complete evidence | Nonreproduction under the recorded source/toolchain/history/instrumentation. |
| Capture incomplete | Preserve the test result; diagnosis remains incomplete. Do not classify absent delivery/focus/keyboard events. |

No causal conclusion, production fix, retry, workflow dispatch, simulator action or native test was performed in this assessment. `experiment-plan.json` is the machine-readable scope. The source overlay and runner still need implementation/review before this plan is executable.
