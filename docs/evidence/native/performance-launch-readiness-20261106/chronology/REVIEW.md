# Offline scroll chronology review

The evidence narrows the anomaly to early measurement-associated activity in 807, but does not establish a measurement-delivery race. Both runs execute the same scroll method, fixture import method, measurement options and fixture bytes. All six reset-position and forward-movement assertions pass in each run. Only 807 lacks a complete diagnostic pair in the warm-up and first measured swipe; its later four windows contain pairs. f117 contains all six pairs and the required five-sample XCTest duration series. 807 has no XCTest duration row, independently confirmed in its original result SQLite. Diagnostic pairs do not replace that series or pass its gate.

## Source and actual chronology

Frozen `ReleasePerformanceUITests.swift:153–184` imports 500 fixture lines, obtains the first collection view, waits for it, constructs scrolling/memory/hitch metrics, and invokes `measure` with five iterations and manual start/stop (`:251–256`). Each invocation first resets via `swipeDown(velocity: 6_000)`, verifies the saved heading is onscreen and at the same resting Y (within 2 points), calls `startMeasuring()`, performs `swipeUp(velocity: .fast)`, calls `stopMeasuring()`, and verifies forward movement. The six observed invocations are the warm-up and five measured swipes. Import/review gestures earlier in the test are outside these six windows.

Both runs target CollectionView frame `{{0.0, 276.0}, {402.0, 598.0}}` in all six swipes. This is the target frame, not finger start/end coordinates. The test supplies a direction and velocity, not explicit coordinates. The SQLite attachments contain only the final screenshot, so exact synthesized paths and intermediate visual displacement cannot be reconstructed here. Passing assertions establish the specified accessibility-position conditions, not identical pixel trajectories.

The collection-view existence activity finishes at t=294.742 s in f117 and t=308.208 s in 807. First reset starts 35 ms and 12 ms later respectively; metric construction/entry occurs in that small uninstrumented interval according to source order. Before the first swipe-up, the last heading-query activity ends 35 ms (f117) and 11 ms (807) before the gesture activity starts. No activity timestamps directly record either measurement call.

Test starts are 22:17:22.946 UTC (f117) and 22:42:20.694 UTC (807), November 6, 2026. Times below are seconds relative to those starts. “After” is the gap between the swipe activity finishing and the next heading-check activity starting. “Window” is the entire enclosing swipe-start to following activity-start interval used by the diagnostic.

| Run | Invocation | Swipe start | Swipe duration | After | Window | Events/pairs |
|---|---|---:|---:|---:|---:|---:|
| f117 | warm-up | 296.279 | 3.140 | 2.639 | 5.779 | 2/1 |
| f117 | measured swipe 1 | 305.353 | 2.901 | 1.235 | 4.136 | 2/1 |
| f117 | measured swipe 2 | 312.887 | 3.000 | 1.153 | 4.153 | 2/1 |
| f117 | measured swipe 3 | 319.966 | 3.104 | 1.155 | 4.259 | 2/1 |
| f117 | measured swipe 4 | 327.374 | 2.947 | 1.158 | 4.105 | 2/1 |
| f117 | measured swipe 5 | 334.451 | 2.880 | 1.407 | 4.287 | 2/1 |
| 807 | warm-up | 309.197 | 2.866 | 16.908 | 19.774 | 1/0 |
| 807 | measured swipe 1 | 331.645 | 2.857 | 1.126 | 3.983 | 1/0 |
| 807 | measured swipe 2 | 340.393 | 3.422 | 1.141 | 4.563 | 2/1 |
| 807 | measured swipe 3 | 349.934 | 3.293 | 1.135 | 4.428 | 2/1 |
| 807 | measured swipe 4 | 357.695 | 3.117 | 1.300 | 4.417 | 2/1 |
| 807 | measured swipe 5 | 369.078 | 3.499 | 1.172 | 4.671 | 2/1 |

The conspicuous 807 warm-up interval is **after** the swipe: 16.908 s versus f117's 2.639 s. Its gesture takes only 2.866 s, including event synthesis 0.466 s and post-synthesis idle 2.257 s; f117's corresponding values are 3.140 s, 0.499 s and 2.243 s. Therefore the long interval is not a prolonged recorded gesture or idle wait. Source places `stopMeasuring()` between gesture return and the next heading query, but the gap can also include framework bookkeeping/scheduling; without call timestamps it cannot be assigned to `stopMeasuring()` itself. The first measured 807 swipe also lacks a pair, yet its after-gap is ordinary (1.126 s). A long after-gap is therefore not necessary for the missing-pair observation.

The sole test-source difference is four Shop-tab readiness lines in `openPickupList`, before fixture import. That wait took about 1.204 s near t=17.232–18.436 s in 807, roughly five minutes before measured gestures. It does not change the scroll method, reset, velocity, metrics, iteration count or thresholds. This temporal separation does not prove it has no downstream timing effect, but current evidence provides no causal link.

## What the signpost evidence can and cannot say

Both scoped diagnostic captures and activity exports report success, one matching process and zero unparsed candidates. f117 parsed 102 total events and 807 parsed 100; these totals include earlier fixture interactions and do not prove that exactly two events were globally lost. f117's six pairs last 2.598/2.584/2.583/2.583/2.584/2.584 s; 807's later four last 2.577/2.600/2.567/2.580 s.

The parser (`scroll_signpost_diagnostic.py:35–61`) selects inclusive swipe-start → following-activity-start windows, then requires exactly two endpoints with matching PID/signpost ID, begin then end. These windows are explicitly **not measurement boundaries**. The workflow (`ios-performance.yml:175–203`) deletes its temporary raw filtered log and exported activity JSON after saving summaries. We recovered activity timing from preserved XCTest SQLite copies, but the summary retains neither endpoint type nor timestamp/ID. A one-event window therefore cannot tell us whether begin or end was missing, shifted outside the window, omitted by capture, or affected by another instrumentation condition. Parse/capture success does not establish completeness. No root measurement-boundary activity was retained; the only activity title containing “measur” is the final screenshot attachment.

Passed movement/reset assertions, consistent frames, normal synthesis/idle durations and complete later pairs provide no evidence of a no-op initial gesture or wrong scroll target. They do not exclude subtle app scroll dynamics, UIKit emission behavior, window alignment, OS logging loss or XCTest collection behavior. Early-only incompleteness plus the first after-gap makes measurement startup/collection latency a plausible discriminator, not a demonstrated cause. This is a comparison of two single runs on separate runners, not a controlled causal experiment.

## Proposed bounded discriminator (not installed or executed)

A single diagnostic follow-up could retain timestamps immediately before/after each existing `startMeasuring()` and `stopMeasuring()` call, plus swipe entry/return, indexed by invocation. Buffer monotonic timestamps in memory and attach them after measurement; include one clock-correlation anchor if comparing to UTC signposts. Do not add waits, warm-ups, retries, alternate gestures, or change call order, limits, sample counts or acceptance gates. Any timestamp/array instrumentation has overhead and makes this diagnostic evidence, not proof that the uninstrumented run is equivalent.

Also retain a bounded, scoped endpoint receipt from the already captured log: begin/end type, relative timestamp, stable process/signpost correlation token, and window relation, including neighboring reset/inter-window events. Exclude unrelated logs and raw app records. This would distinguish a lone begin from a lone end or an endpoint outside the diagnostic window, while call timings would locate the unrecorded gap. Captured endpoints still cannot prove XCTest consumed them. A passing repeat alone would not establish a fix; a duration-series omission remains a failed gate regardless of endpoint pairs. Current evidence does not justify adding a delay or discarding an early measured sample.

## Integrity and limits

`proof.json` records input hashes, exact equal source segments, read-only SQLite checks and complete freeze revalidation: f117 357 files, 807 359 files, zero mismatches. `chronology.json` retains activity row IDs, UTC/relative timing and direct child activities; `test-source.diff` retains the exact four-line helper difference. SQLite reads used separate scratch copies; no frozen files were edited, no network or native execution occurred, and no application-ledger database was accessed. The retained activity timestamps have millisecond precision; they do not resolve scheduling or delivery mechanisms below that level.
