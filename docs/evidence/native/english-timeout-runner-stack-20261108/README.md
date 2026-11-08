# English dinner timeout: retained runner stack

A single bounded extraction of the already-recorded timeout spindump reached its 4,000,000-byte limit. The partial remains private because it includes unrelated host processes. No retry or larger export occurred. The original result was not supplied to the exporter; all pinned inputs remained unchanged.

The scoped excerpt binds test runner PID 56247 to 15:38:45.453–15:38:50.456 UTC on November 8. It shows `reviewAndApprovePattern` filling Source and waiting in XCTest's app-quiescence path, including animation-idle checks. It contains 114 samples with an explicit 3698 ms sampling gap.

This is the late Source action near the test deadline. It does not explain the first Yield Done stall roughly 510 seconds earlier. The captured prefix lacks the app process section, so it does not establish the app's state or the animation owner. No claim of absence applies to the full attachment. `REVIEW.md`, the scoped excerpt, exact plan and failure receipt preserve these distinctions. A product fix is not established.
