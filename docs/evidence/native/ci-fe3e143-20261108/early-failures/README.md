# Current CI: two observed failures, cohort unfinished

The published `fe3e143` cohort has two observed failed jobs at this checkpoint. This is not a terminal cohort count.

- [UI01](https://github.com/palatis3/room-in-the-cart/actions/runs/42509307282/job/128821441785): four cases pass; the English dinner-pattern case times out at 12 minutes after repeated keyboard-animation waits. It is the known selector previously assigned to UI09. The newly retained complete spindump supplies the previously missing app-process section. The runner waits for animation quiescence; the app main thread is in its event run loop for all 306 sampled stacks. A background preferences callback waits for cfprefsd and UIKit’s animation manager waits on a semaphore. These late samples do not identify the animation owner or prove that the preferences wait causes the timeout. No product repair is inferred.
- [Scroll performance](https://github.com/palatis3/room-in-the-cart/actions/runs/42509307171/job/128821661268): native XCTest rejects an iteration reporting three metrics instead of the initial four. The metrics export is empty. Separate UIKit diagnostics contain pairs for warm-up and all five measured swipes, but their windows do not establish XCTest collector receipt or measurement-boundary inclusion. Launch and rendered-screen performance passed.

Apple documents that the signpost metric records no result without a matching begin/end pair. That explains a possible missing-series condition, not the cause of this failure. [Apple documentation](https://developer.apple.com/documentation/xctest/xctossignpostmetric).

The complete 6,556,466-byte spindump remains private. Only the relevant numbered runner and app stacks are included here. The downloaded result was cloned and its original preserved; one bounded archived activity read and one exact spindump export succeeded. No tests, retries, thresholds or warning gates changed for this investigation.

The stackshot window is 19:00:43.071–19:00:48.064 UTC, with 3.09 seconds sampled. The test’s screen-recording attachment contains only a 60-byte pending-attachment error, so it cannot establish the visible keyboard state during the stall. Its exact single export is retained privately; it was not retried.
