# UI01 launch failure: retained-session review

Core run [42457092386](https://github.com/palatis3/room-in-the-cart/actions/runs/42457092386), job 128660927505, failed `ContextualNavigationUITests/testUnknownProduceWeightUsesSavedWholePickupCapAndBillingIncrement` inside `app.launch()`. The four subsequent tests passed. This remains a failed job.

The original session narrows the failed operation to XCTest's target-app background-assertion acquisition after activation:

| UTC, November 8 | Recorded event |
| --- | --- |
| 07:24:53.562–53.579 | App process launched and recorded as Running Foreground. |
| 07:24:55.362 | Activation expectation completed; the 10-second background-assertion wait began. |
| 07:24:59.618 | The target sent Shop navigation/tab `ViewDidAppear` events during the wait. |
| 07:25:05.372–05.375 | Assertion acquisition timed out after 10.012 seconds. |
| 07:25:06.202–06.608 | The same app subsequently established an automation session and completed a UI query during teardown. |

The requested spindump was unsupported, rather than evidence of a fault-free process. The later signal 15 followed explicit test teardown. This evidence shows launch progress before the timeout; it does not establish uninterrupted responsiveness, the underlying service cause, or an infrastructure-only classification. No application behavior correction or retry is justified from this inspection alone.

The original artifact ZIP is unchanged (SHA-256 `33a80ceb392d2669d857bd90231f7281a19bf5b050107ec2b9def5bc27380c73`). A separate inspection copy exported only the session object. Export hit its explicit 16 MiB limit and retained an incomplete prefix covering the first launch interval; no completeness claim is made for later events. Exact line-numbered excerpts and receipts are private under `.build/CI14AC1E3Nov08/ui-01/launch-interval-inspection/`. No app stdout, simulator actions or reruns were involved.

If this signature recurs in a normal cohort, narrowly scoped existing simulator service logs around assertion acquisition may distinguish the remaining causes. The two-shard owned-device pilot is separately qualified isolation work, not a demonstrated repair for this failure.
