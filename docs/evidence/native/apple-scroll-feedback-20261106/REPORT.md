# Apple Feedback draft — not submitted

**Title:** Room in the Cart: unwrapped XCTest scroll metric sometimes absent despite passing performance test (Xcode 26.3 and 26.4.1, iOS Simulator)

**Suggested area:** Developer Tools & Resources → Xcode → XCTest / performance testing.

The built-in `XCTOSSignpostMetric.scrollingAndDecelerationMetric` is absent from retained results of an otherwise passing five-iteration Release UI performance test. Three memory series each contain five samples. A passing comparator using identical test-file bytes and the same recorded Xcode/runtime reports five scroll samples. We have not established deterministic reproduction, failure frequency, or an Apple framework defect. Please help identify whether collection, matching, reporting, or result aggregation explains this omission, and which supported diagnostic can distinguish these cases.

## Recorded environments and results

| Evidence | Source / workflow run, attempt 1 | Xcode | Simulator | Result |
|---|---|---|---|---|
| Original omission | `8f864ea`, `42234316869` | 26.3 / 17C529 | iPhone 17 arm64; iOS 26.2 / 23C54 | XCTest: 1 passed; scroll series absent |
| Passing comparator | `0d33c11`, `42215222404` | 26.3 / 17C529 | iPhone 17 arm64; iOS 26.2 / 23C54 | XCTest: 1 passed; five scroll samples |
| Additional unwrapped omission | `5376a01`, `42261730525` | 26.4.1 / 17E202 | iPhone 17 arm64; iOS 26.4.1 / 23E254a | XCTest: 1 passed; scroll series absent |

All three report zero failed/skipped tests. The original/comparator summary text says “Built with macOS 15.8.2.” Qualification build metadata labels macOS 26.6.2 / 25G83, while its XCTest summary says “Built with macOS 26.7.2”; these differently sourced descriptions are retained without conflating their meaning. Both Xcode and runtime changed in that qualification, so it does not isolate either variable. Full commits, job/artifact IDs, dates, hashes, source identities and build invocations are in `evidence-map.json`.

## Bounded observed procedure

These are the existing workflow's steps, not a guaranteed failing standalone reproduction. No new test was run to prepare this report.

1. Build the Release app and `RoomInTheCart-Performance` scheme; disable parallel testing, coverage and sanitizers as recorded in the build invocation.
2. Use a fresh iPhone Simulator installation. Put the bundled fictional `ReleaseLedger500.txt` fixture on its pasteboard; the test imports all 500 distinct lines through the app's native Paste/review/save flow.
3. Select only `RoomInTheCartUITests/ReleasePerformanceUITests/testScrollingPerformanceOnFiveHundredItemPickup` using `test-without-building`.
4. Use the actual built-in scroll metric, `XCTMemoryMetric(application: app)`, and `XCTHitchMetric(application: app)` on iOS 26+. Set five iterations with `.manuallyStart` and `.manuallyStop`.
5. Before each measurement, swipe downward and assert the same starting position. Execute `startMeasuring(); list.swipeUp(velocity: .fast); stopMeasuring()`, then assert the list moved. Export the result's metrics.

`UnwrappedScrollExcerpt.swift` contains verbatim measurement/options methods. It requires the existing app/test fixture helpers; it is not a newly validated minimal app. The complete test file has identical SHA-256 across all three commits: `bde26f21c934c1f7d0c8ff885592c2715c494cfb7ab832e286b8f1a93641484b`.

## Expected and actual

For iterations with matching signpost pairs received inside the collector's measurement interval, we expect the built-in scroll duration series, as observed in the comparator:

`com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration`

Comparator seconds: `[2.5789600000000004, 2.565552667, 2.583267875, 2.5816098750000003, 2.5663605410000003]`.

In the original omission, this series is absent from console measurements, exported JSON/CSV, and the original archived xcresult `PerformanceMetrics` table. The qualification also lacks it in JSON, console, and its archived metric table. Each failing result still contains all five samples in each memory series. This is an absent series, not a threshold failure or our parser discarding an existing result. Our separate required-metric gate remains failed; XCTest method success is not accepted as complete performance evidence.

## Limits and excluded observations

Apple documents that no matching begin/end pair produces no signpost result. Retained external UIKit duration summaries **do not prove collector receipt or inclusion within actual measurement boundaries**. Thus the omission is an observation, not a confirmed Apple defect or proof that the API contract was violated. We cannot distinguish collection/matching loss from reporting/aggregation behavior. No measurement-window, metric, sample-count or threshold change is inferred from the documentation. [Apple XCTOSSignpostMetric](https://developer.apple.com/documentation/xctest/xctossignpostmetric).

A later `804030e` run executed **zero native tests** after a pre-test setup timeout; it is not another missing-series reproduction. A rejected forwarding-wrapper experiment on Xcode 27.1 / 27A9275 caused a different assertion/manualStop failure and empty metrics; it is not evidence for the original unwrapped root cause. Neither is counted above.

Only curated scroll evidence, the fictional fixture and code excerpts are packaged. Original ZIPs remain locally referenced; no private/raw Records artifacts, credentials or unrelated artifacts are included. No fresh sysdiagnose or standalone minimized app is available. This draft has not been submitted or uploaded. Its structure follows [Apple's feedback guidance](https://developer.apple.com/feedback-assistant/).
