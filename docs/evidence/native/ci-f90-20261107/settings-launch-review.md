# f90 Reduce Motion setup failure

The original UI01 case failed while activating system Settings, before the app or share-sheet journey. Settings launch began at 0.06 seconds; XCTest reported a launch timeout before automation setup at 36.03 seconds. Execution continued, tapped Accessibility at 49.18 seconds and failed to find Motion within its existing wait. Teardown began at 57.93 seconds; the test failed at 58.420 seconds. XCTest then reported an internal issue-handling assertion and restarted the runner.

The case never read or changed Reduce Motion, registered restoration, or entered the app/share assertions. Its entrypoint and Settings helper section are byte-for-byte unchanged from f90ad75 in the current source. The preceding large-text case uses an app launch argument rather than changing the global accessibility preference. Zero recorded runtime warnings does not negate this failure or restart.

This matches the boundary of the previously retained [Settings-launch failure](../ui10-settings-launch-20261106/proof.json). It does not establish the underlying Settings or launch-service cause. No app change, blind retry, timeout increase, simulated Reduce Motion setting, or relaxed acceptance is justified by the current evidence.

Next inspect the original xcresult failure activities, screenshot and runner diagnostics. The retained `test-details.json` is the test tree, not a complete activity or visible-state export. If another native diagnostic is needed, preserve the original two-case prefix, runtime, OS preference checks and existing limits, with bounded observations around the first Settings activation. A standalone pass would establish only nonreproduction under that altered order.

[Original run, exact failure and artifact paths](monitor.json). No retry, new native execution or workflow mutation was made for this review.
