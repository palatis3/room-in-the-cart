# Measurement-boundary diagnostic result

Run 42309808686, attempt 1, exact source `775961d11315eb5c0eeed94b4ce3da62a6eec285`, completed successfully. All three native cases passed with zero runtime warnings, no implicit restart and no synchronization-timeout log messages. Source is exactly 807 plus the reviewed three-file diagnostic; runtime remains iPhone 17 arm64 / iOS 26.2 build 23C54 / Xcode 26.3 build 17C529. All four checkout logs identify that exact source, all three case logs explicitly enforce baselines, and all three restore the same API-digest-verified product artifact.

The instrumented scroll case passed in 330.538 seconds. Its original result SQLite has four metric rows with five samples each, exactly matching exported JSON; quick_check is ok. Required duration median is 2.581787917 seconds (limit 3.25). Absolute-memory median is 116727.808 kB (150000), peak-memory median 117022.720 kB (155000), maximum peak 117366.784 kB (160000). Separate hosted pickup readback verifies 500 rows/contributions, one Paste import, zero checked rows, revision 2 and SQLite quick_check ok. No raw application-ledger database was downloaded. Animation-hitch samples remain unavailable on this simulator, so this run cannot evaluate frame hitches.

This is **instrumented nonreproduction**, not a fix or release acceptance. f117's passing duration series and 807's missing duration series remain preserved, along with earlier failures. Added clock reads/buffering can perturb behavior even though original gestures, call order, metrics, iterations, limits and gates are unchanged.

## What the new receipt establishes

The attachment records six completed invocations, matching six original SQLite swipe activity windows: expected warm-up plus five measured invocations. No invocation or sample was discarded. Schema-2 endpoint evidence retains all 24 scoped events without truncation; all six swipe windows contain exactly one matching begin/end pair. The wider original capture summary has 102 parsed candidates, zero unparsed candidates and one matching process. The independent audit recomputed every pair/count from the retained endpoint receipt and verified its UTC origin/window timestamps against the copied original SQLite activities.

| Invocation | startMeasuring call ms | Gesture call s | stopMeasuring call s | Post-swipe activity gap s | Diagnostic pairs |
|---|---:|---:|---:|---:|---:|
| warm-up | 0.970 | 2.881 | 3.586 | 3.586 | 1 |
| measured swipe 1 | 0.374 | 2.971 | 1.226 | 1.227 | 1 |
| measured swipe 2 | 0.254 | 2.916 | 1.168 | 1.171 | 1 |
| measured swipe 3 | 0.397 | 2.963 | 1.149 | 1.150 | 1 |
| measured swipe 4 | 0.206 | 3.002 | 1.143 | 1.144 | 1 |
| measured swipe 5 | 0.264 | 2.905 | 1.127 | 1.128 | 1 |

In this successful instrumented run, the public `stopMeasuring()` call accounts for almost all of the recorded gap between swipe completion and the following heading check. The warm-up call lasts 3.586 s; later calls last 1.127–1.226 s. This directly locates elapsed time within that public call here, but does not identify its internal work or waiting mechanism. It cannot retrospectively assign 807's uninstrumented 16.908-second warm-up gap to the same call. 807's first measured swipe also lacked a pair despite an ordinary 1.126-second activity gap, so a long gap was not necessary for that earlier diagnostic omission.

Using the initial test-side clock anchor, captured begin timestamps are approximately 295–416 ms after `startMeasuring()` returns, and end timestamps approximately 3.9–16.0 ms before `stopMeasuring()` is called. These are approximate timestamp relationships, not proof of when XCTest received or consumed events. Initial/final clock-anchor brackets are about 8.8/2.1 microseconds wide, with midpoint offset change about −3.3 microseconds. Those two anchors do not bound arbitrary intermediate wall-clock jumps; endpoint timestamp precision/rounding and public-call instrumentation also limit inference. Activity windows are not internal measurement boundaries.

The successful run therefore demonstrates that the proposed receipts can identify public-call latency and retained endpoint chronology. It did **not reproduce the missing endpoints or missing duration series**, so it does not distinguish the cause of that failure among emission/capture, window alignment, delivery or XCTest collection behavior. A complete pair receipt never substitutes for the duration-series gate. No delay, sample deletion, new baseline, retry or further experiment is implied by this result.

## Retained proof

- `evidence/measurement-boundary-diagnostic.json`: attachment mapping/hash, original timestamp receipts, independent endpoint/window checks and approximate clock alignment.
- `evidence/scroll-metric-sqlite.json`: copied original XCTest SQLite rows/sample equality; separate from application persistence.
- `evidence/scroll-signpost-comparison.json`: bounded f117/807/775 comparison with exact previous chronology hash.
- `evidence/performance.json`, `native-execution.json`, `outcomes.json`, `product-transport.json`: separate strict native, runtime, measurement, persistence, setup, source and product-transport checks.
- `FINAL-AUDIT.json` and `freeze.json`: original ZIP/pristine extraction checks, final immutable input hashes and run/runner-step timing. Total run wall time includes pending/admission and dependency time; job started_at is not treated as runner execution time.

No dispatch, retry, cancellation, tracked-source/Git modification or native app/test execution was performed by this collector. Original ZIPs/extractions remain preserved; xcresulttool inspection used separate copies.
