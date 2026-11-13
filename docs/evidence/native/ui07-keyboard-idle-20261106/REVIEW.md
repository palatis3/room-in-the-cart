# UI07 next-shop timeout: bounded read-only review

**The test timed out while entering the initial urgent meal need, before exercising any next-shop cancel/create/open behavior.** The first sustained delay is XCTest's post-event idle wait after the second keyboard Done tap, following entry of `Dinner` into `Meal or purpose`. Retained evidence identifies the synchronization boundary but does not establish its cause.

Candidate: `804030e68473d022e72b464940061c01c611a0bd`; run `42272379454`, job `128116417997`, attempt 1; artifact `13542915084`. Original test allowance remains 720 seconds, maximum 900. Original six-case shard remains 5 passed / 1 failed, with an implicit XCTest restart. No retry or execution occurred during this review.

## Exact observed boundary

| Observation | Test-relative time | Original Tests.log lines |
| --- | --- | --- |
| Open urgent-repair shortcut and type `Rice` | 21.44–32.54 s | 1466–1487 |
| First Done tap completes its normal-speed idle wait; next field queried | 34.53–35.82 s | 1488–1495 |
| Last normal-speed completed input operation before onset: type `Dinner` | 39.05–40.62 s | 1503–1509 |
| Second Done tap / event synthesis | 41.58 / 42.06 s | 1511–1515 |
| **First stalled operation: post-event app-idle wait** | **42.38–102.42 s** | **1516–1517** |
| Required amount `3` event eventually synthesized | 291.50 s | 1533 |
| Available amount `1` event eventually synthesized | 658.48 s | 1561 |
| Timeout while helper proceeds toward the next Done tap | 720 s | 1566–1568 |

“Completed input operation” means the automation call returned to the next query; this helper makes no independent field-value assertion. There is no retained image/hierarchy to prove the visible values or focus state. The first and second Done synthesized events both target app PID 18435 at **(364, 517)** with a 0.05-second down/up interval. That rules out a changed recorded tap coordinate, but does not prove which handler ran or that dismissal finished.

The case continues making progress between 60-second idle waits: **11 animation-completion messages before the timeout and 1 afterward**. It never reaches the confirmation switch, `Save need and repair meal`, explicit app restart, next-shop dialog, Cancel, fresh-draft creation/opening, or final Records-tab action. The next-shop feature itself therefore has no acceptance evidence from this failed execution.

## Exact source route

All files below are frozen from the exact candidate under this directory, with hashes in `provenance.json`.

- `FreeJourneyUITests.swift.804030e:532`: test; initial field sequence at 534–538, intended next-shop actions at 542–553.
- `FreeJourneyUITests.swift.804030e:1185`: `fill` selects an editable field, types, finds the first `Done`/`Listo` button, and taps it at line 1196. No post-dismiss field/keyboard-state assertion is present here.
- `RoomInTheCartApp.swift.804030e:253`: `urgentRepairShortcut` navigates to `UrgentRepairView`.
- `PickupRepairView.swift.804030e:23`: four fields share `@FocusState`; line 37 invokes `keyboardDoneAction(visible: field != nil)` with `field = nil`.
- `Theme.swift.804030e:24`: shared Done control is a conditional bottom `safeAreaInset`; its Button invokes the supplied dismiss closure. No explicit animation is visible in this source path. This source shape is a candidate instrumentation boundary, not proof of a defect.

## What the retained attachments establish

The timeout spindump is stronger evidence than the generic log message, but is a **late sample**, not a recording of the first stall. It covers 21:11:06.233–21:11:11.218 UTC, with 307 samples / 3.33 seconds actually sampled, approximately 721 seconds after this case started.

- App **PID 18435**: main thread is in `CFRunLoop` → service Mach port → `mach_msg2_trap` for **307/307 samples**. The event-fetch thread is also waiting; the UIKit in-process animation-manager thread waits on a semaphore. No sampled app business-code busy loop or app-call lock stack appears.
- Test runner **PID 6304**: **307/307 samples** follow `FreeJourneyUITests.fill` → `XCUIElement.tap` → `_waitForQuiescenceAsPreEvent` → `waitForQuiescenceIncludingAnimationsIdle` → `XCTWaiter`.

This demonstrates a sampled **automation synchronization wait while the app main loop waits for events**. It does not establish whether an app, SwiftUI/UIKit, or XCTest state caused the missing idle completion, nor prove the UI was visually correct or responsive. The animation-manager semaphore alone is not a deadlock diagnosis. See `spindump-relevant-excerpts.txt`, original spindump lines 149–173 and 44378–44438.

The only “Screen Recording” payload is a **60-byte error stub**: `Unexpected Error: Finished test run with pending attachment.` There are **no screenshot or hierarchy attachments for this exact failed case**. Twelve synthesized-event attachments and the spindump are retained. No playable visual evidence is available to distinguish a visible keyboard/transition problem from stale synchronization accounting.

## Next discriminating diagnostic — proposed, not run

Keep the exact app/runtime and 720/900 gates. Observe the minimal `urgentRepairShortcut → Rice → Done → Dinner → Done` prefix with monotonic timestamps for the actual Done handler, FocusState changes, keyboard will/did-hide notifications, and a main-thread heartbeat; retain an independently finalized screen recording. Compare a fresh-launch prefix against the original preceding UI07 case history, without disabling XCTest idle waiting or animations.

If the handler runs, focus clears, keyboard visually disappears, and the main thread remains responsive while XCTest still waits, investigate animation/quiescence accounting at that boundary. If handler/focus/keyboard dismissal does not complete, the instrumentation identifies the earlier app/framework boundary needing investigation. Existing evidence cannot choose between those outcomes. No gate weakening or speculative production patch is justified by this review.

## Preservation

XCResult tooling operated **only on a copied bundle**. Original ZIP/log SHA-256 values and all **90 original bundle files**, sizes, and modification times were rechecked unchanged. No tracked-source/Git edits, native builds/tests, hosted mutations, or downloads occurred. No raw Records media was read. `provenance.json` and `observations.json` record exact inputs, limits, findings, and uncertainty.
