# English supply-sheet dismissal: reproduced timeout

The original English dinner-pattern journey failed at its unchanged720-second
limit (native65, strict1), with eight in-case animation-idle misses and one
subsequent unattributed message, then one XCTest runner restart. Zero runtime
warnings were reported for this one selected case. Original results/log/receipt
were preserved; a cloned result was inspected exactly once.

The first stall is now **Yield Done**, with post-event idle starting at203.95s
and missing-completion notification at263.97s. The earlier hosted run first
stalled after Price Done. This reproduction therefore widens the affected dismissal
sequence. The Price-specific probe had not begun at the first stall and cannot
identify its initiating animation owner.

One123,820-byte probe binds to PID51410 and the selected original testcase. It
records the later Price dismissal, keyboard hide and zero observed responders in
its post-dismiss samples. The record retains only the first roughly4seconds of
post-dismiss snapshots: four later records were dropped at the fixed output cap.
The sink closes at67.21seconds with57.51ms measured inventory/encoding work;
that is not complete67-second trace coverage or total scheduling overhead.
No collection cap was increased, no retry occurred, and retained animation keys
are not treated as proof of an active animation or its owner.

The smallest untried product candidate identified by review moves Done only in
IdeaSupplyEditor to its native navigation bar. It removes that sheet's explicit
bottom safe-area inset while preserving `field = nil`, Cancel, and the separate
reviewed-details commit. It is not yet compiled or installed. The zero-height
stable-subtree family was already tried/rejected; do not repeat it. The new
candidate needs mandatory evidence of all three actual Done actions, control
reachability, retained values, keyboard dismissal, native/strict success and no
idle miss, followed by localized/largest-text/minimumOS qualification.

Private original source/products/results and the bounded monitor remain under
`.build/EnglishKeyboardReviewNov08/current-r1/execution-r1/`. Before any cache
reuse, preserve and verify its complete561-input source and built products.
Do not rerun its completed diagnostic or repeat result/probe collection.
