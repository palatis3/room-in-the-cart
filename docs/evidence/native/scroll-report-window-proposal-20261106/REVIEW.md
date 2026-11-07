# Missing scroll series: bounded next diagnostic

**Recommend preparing one separately pinned, standalone public `XCTMetric` report-window witness beside the unchanged built-in metrics.** It records the start/end timestamps XCTest supplies to its reporting callback, then correlates those intervals with the existing schema-2 UIKit endpoint receipt. This is a proposal, not implemented, compiled, authorized for dispatch, or established to reproduce the omission. No repeat of the already-passing 775 public-call instrumentation is recommended.

## What the retained runs establish

| Source/run | Required five-sample duration | Retained swipe-window pairs | Meaning |
|---|---|---|---|
| 0d5bb1b / 42316648635 attempt 1 | Absent | 6/6, including warm-up | Complete activity-window pairs are insufficient to ensure reported duration. |
| 807aa3c / 42304515547 | Absent | 4/6; warm-up and first measured swipe lack pairs | Different diagnostic signature; not a necessary condition for missing duration. |
| 775961d / 42309808686 | Present | 6/6; 24 scoped endpoints retained | Instrumented nonreproduction; public stop-call time and endpoint chronology available only for this successful case. |

0d5's original artifact is `13554828191`, ZIP SHA-256 `b52fda2b97833c50f809385879426b98b57bd52f0e6794cafc64832cad5555ef`. Its native scroll case passes in 282.440 seconds. Original result metadata readback has exactly three memory rows, each with five samples, no scroll duration row, SQLite quick_check ok, and exact JSON agreement. The native console also prints only those memory metrics (`Performance.log:520–522`). This excludes an export-only JSON-parser omission; it does not identify a collector cause. Do not equate case elapsed time, gesture time or reconstructed signpost duration with the required metric.

The current full performance test SHA-256 is `c7954233968072b97fd5845d5c28877c9251495cfee33675169a960839d2625f`, matching the retained comparison's exact 807/0d5 file identity. At `ReleasePerformanceUITests.swift:153–183`, reset and position assertions precede `startMeasuring`; one native fast upward swipe occurs before `stopMeasuring`; movement is asserted afterward. Metrics remain the native scrolling metric, target-app memory metric, and availability-gated hitch metric. Options at lines 251–255 request five measured iterations and manual start/stop. These are not altered by this recommendation.

0d5's schema-1 summary has 104 parsed candidates, zero unparsed candidates, one matched process and six pairs of approximately 2.567–2.584 seconds. Its retained attachment manifest contains the final screenshot only. The summary discarded endpoint timestamps and identities, so those cannot be reconstructed from the counts or durations. 775's schema-2 receipt and public clock brackets show endpoints inside its approximate public-call bounds and locate most post-swipe delay in `stopMeasuring`. They cannot establish 0d5 or 807 boundaries, nor prove built-in collector receipt.

Apple describes signpost measurement as depending on a matching begin/end interval; independently retained UIKit events do not prove the metric received that pair. [Apple XCTOSSignpostMetric](https://developer.apple.com/documentation/xctest/xctossignpostmetric).

## Why this observation is different

The public `XCTMetric` report callback receives `XCTPerformanceMeasurementTimestamp` start/end arguments for an iteration. They are framework-supplied **report-window bounds**, unlike clocks read around public start/stop calls. A standalone custom witness can record its own supplied arguments without calling, replacing, copying on behalf of, subclassing, or delegating to the built-in signpost metric. The prior rejected wrapper replaced the built-in metric's runtime identity and produced a different null-date/framework-assertion failure; this proposal avoids that specific arrangement, but compatibility still needs validation.

Crucial limit: the witness cannot observe the private collector's receipt/delivery or prove that its report bounds equal all internal windows used by the built-in metric. Therefore it discriminates report-window alignment from mere activity-window containment; it does not directly diagnose the built-in collector. Adding a metric changes collector composition, callback scheduling and runner allocations even if existing metric instances/calls are untouched. All resulting runs are diagnostic, not release equivalence or a fix.

Public API basis: [XCTMetric](https://developer.apple.com/documentation/xctest/xctmetric), [reportMeasurements(from:to:)](https://developer.apple.com/documentation/xctest/xctmetric/reportmeasurements(from:to:)), and [XCTPerformanceMeasurementTimestamp](https://developer.apple.com/documentation/xctest/xctperformancemeasurementtimestamp). Read-only inspection of the installed Apple `XCTest.framework/Headers/XCTMetric.h:25–46,154–188` confirms per-iteration copying, report arguments, and date/mach-clock properties. That local header is from a different installed toolchain than hosted 26.3; it is API evidence, not target compilation proof.

## Public protocol sketch — not compiled code

```swift
final class ReportWindowWitness: NSObject, XCTMetric {
    private let recorder: WitnessRecorder
    private let copyID: UInt64

    init(recorder: WitnessRecorder) {
        self.recorder = recorder
        self.copyID = recorder.allocateCopyID()
        super.init()
    }

    func copy(with zone: NSZone? = nil) -> Any {
        // New metric object; same per-test, synchronized recorder.
        ReportWindowWitness(recorder: recorder)
    }

    func willBeginMeasuring() {
        recorder.lifecycle(copyID: copyID, kind: "willBegin")
    }

    func didStopMeasuring() {
        recorder.lifecycle(copyID: copyID, kind: "didStop")
    }

    func reportMeasurements(
        from startTime: XCTPerformanceMeasurementTimestamp,
        to endTime: XCTPerformanceMeasurementTimestamp
    ) throws -> [XCTPerformanceMeasurement] {
        recorder.report(copyID: copyID, start: startTime, end: endTime)
        return [] // Observation only: invent no metric/sample/duration.
    }
}
```

`WitnessRecorder` above is a design placeholder, not supplied implementation. Its reviewed implementation must use a per-test lock around ID/sequence allocation and fixed-capacity buffered values, never assume main-thread callbacks. Every copied metric gets a distinct ordinal; all share that test's recorder, never global state. Capture callback kind/order, copied-instance ordinal, raw supplied start/end `absoluteTime` and `absoluteTimeNanoSeconds`, and `date.timeIntervalSince1970`. Store UInt64 clock values as decimal strings for lossless JSON interoperability. Do not fabricate timestamp objects, IDs, measurement values or missing callbacks. Lifecycle callback times can locate callback arrival, but must not be relabeled as the supplied measurement bounds.

Use a modest explicit bound (e.g. 128 callback records) with total/retained/omitted counts and overflow status. Store scalar data only; do not retain framework objects beyond a callback. No disk I/O, logging, attachment serialization, UI query, gesture, waits or delegated metric calls inside callbacks. Serialize one diagnostic attachment after measure returns; missing attachment on exception/termination means unavailable, never no-callback proof. Any alternative teardown flush must be independently reviewed and cannot mask the native exception. Empty `[]` must first be validated on the intended toolchain; if rejected, stop this technique rather than adding a dummy sample, replacing the required metric, or swallowing framework assertions.

Keep the existing built-in metric objects in their original relative order and append the witness after them. No added clock probes in the measured body are needed. Preserve gesture/reset/assertion/options/fixture/baseline/checker bytes. This necessarily creates a different test source and collector set: freeze the exact base, patch, resulting file, test product, toolchain/runtime and invocation as a separate diagnostic identity, never relabel it 0d5 or reuse its acceptance result.

## Required correlation and validation

1. **Preparation only:** review exact protocol conformance/copy behavior and bounded recorder, typecheck/build against intended 26.3 before relying on it. A 27.1 local result is only wiring evidence. Offline recorder/parser checks should cover multiple copies, callback ordering/concurrency, overflow, duplicate reports, missing callbacks, invalid/reversed dates, lossless clocks and absent/invalid attachment. No native run is part of this review.
2. **Endpoint provenance:** reuse the already-reviewed schema-2 endpoint parser, not a new synthetic event source. Require complete receipt status, no truncation/unparsed candidates, numeric UTC origin, scope bounds, event kind and matching process/signpost ordinal tokens. Bind receipt, attachment, manifest, original result, exact selector, owned device/run and source/product hashes. Preserve reset and inter-window endpoints; no convenient pair selection or ordinal-only joins.
3. **Warm-up:** retain all witness copies/callbacks and all six expected gesture activities. Determine any report-to-gesture association using the recorded timestamp intervals and unique overlap; do not automatically label report 0 as warm-up or delete it. The public copy contract does not guarantee that every warm-up produces a report callback. Missing/extra/ambiguous mappings must be explicit and cannot repair metric cardinality.
4. **Clock semantics:** correlate endpoint UTC against witness date bounds directly; retain the original precision. Within each witness interval use mach nanoseconds for elapsed duration/ordering, not unconverted mach ticks. Compare date deltas with monotonic deltas for clock inconsistency; this detects some discrepancies but does not bound arbitrary intervening clock jumps or establish log-delivery time. Edge-overlapping events are indeterminate within log precision/clock uncertainty. A witness's callback arrival time is not an emission timestamp.
5. **Qualification/outcome:** retain native exit, strict selector cardinality, warnings/restarts, existing original SQLite/JSON metrics and all acceptance gates. Require ordinary built-in metric operation during wiring validation; a new assertion/null-date/empty-all-metrics result invalidates the probe. Do not run until root releases the active cohort and approves a distinct diagnostic execution. No automatic retries until failure or passing substitution.

## Interpretation table

| Fresh diagnostic outcome | Bounded conclusion |
|---|---|
| Original missing duration reproduced; some endpoint pair falls outside a uniquely mapped witness report interval | Witness report-window containment differs from enclosing activity containment. Supports investigating interval selection; does not prove the built-in collector used that same interval. |
| Original missing duration reproduced; all five measured pairs lie comfortably inside valid witness report intervals | Simple exclusion from the witnessed report windows is not supported. Built-in configuration, delivery/filtering or reporting remain unresolved; retain this for framework-owner analysis. Not a confirmed Apple defect. |
| Duration present, as in 775 | Diagnostic nonreproduction only; no explanation or fix for original omission. |
| Invalid clocks, missing/truncated receipts, ambiguous warm-up mapping, or new framework failure | Diagnostic unavailable/invalid. Original performance failure stands. |

A generic rerun of 775, a standalone log pair counter, more waiting, changing manual-stop position, removing hitch/memory metrics, or substituting wall time would not resolve this observation under the stated constraints. Historical Xcode release notes also mention automatic performance traces, but current-toolchain flag/support and bounded retention were not established here; no such flag or expanded capture is recommended by this review.

## Review actions and provenance

Read-only source, retained JSON/log/manifest and Apple public API documentation/header inspection only. No source/Git edits, builds, native tools, hosted dispatch or new agents. Only this report was written. Original evidence was not extracted, modified or reclassified. No media or raw application Records were accessed.

SHA-256 of principal reviewed files:
- `ios/UITests/ReleasePerformanceUITests.swift`: `c7954233968072b97fd5845d5c28877c9251495cfee33675169a960839d2625f`
- `scripts/ios_performance_baselines.json`: `38742a9b5f5eea668c608f117db602ac6a2b73aa56691c3ec3f90c291d15c38e`
- `docs/evidence/native/ci-0d5bb1b-performance-20261106/README.md`: `b9d74a8db8c0199ac42da3679433d6a594957eb926c0bf28a8fd2a2976cf33f1`
- `docs/evidence/native/ci-0d5bb1b-performance-20261106/scroll-diagnostic-comparison.json`: `df854389b3aaa7c6caeb247a30b7f85f1e7c5b765c87ca3a682e73f7e80e26d6`
- `.build/CIResearch20261106/candidate-0d5bb1b/core-collection/iphone-performance-scroll-1/scroll-signpost-diagnostic.json`: `fa681ea00cb2ce968824881416713e7483a2fe81132e49c0a440f6c8ec05bddc`
- `.build/CIResearch20261106/candidate-0d5bb1b/core-collection/iphone-performance-scroll-1/Performance.log`: `a6981b08b45ce10baf9e45e72e90ec3010e7694b0ea4ca71a1515493fb0ddad6`
- `.build/CIResearch20261106/candidate-0d5bb1b/core-collection/evidence/scroll-metric-sqlite.json`: `453dfc559922ba8685103d4e970ea1c9819023ab336285461438306657113f7d`
- `.build/CIResearch20261106/performance-boundaries-775961d/DIAGNOSTIC-REVIEW.md`: `f332833b54a9e18b87e9ca420a8997c9000fcacfe9963470fad50d62354754de`
- `.build/ScrollMeasurementBoundaryProposal20261106/proposal.patch`: `57d3d4d21619f5c24ff1db3eb748f9b3c44760313dc163c039d7c63f45e497db`
- `docs/evidence/native/scroll-report-probe-20261106/REVIEW.md`: `2b8bd3e904dc4b1b3b6a807df441e7b48fe7b8e60a236cf628649dc8696b93be`
