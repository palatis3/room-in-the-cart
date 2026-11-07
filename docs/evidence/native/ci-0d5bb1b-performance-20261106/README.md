# Original candidate 0d5bb1b performance result

Run 42316648635 attempt 1 is terminal failure. All three native cases executed and passed with strict XCTest exit 0, zero runtime warnings and no restarts. Launch and rendered-interaction measurement gates passed; scroll failed the required measurement-structure gate. No rerun, baseline relaxation or missing-series substitution occurred.

| Gate | Original result |
|---|---|
| Responsive launch | Median 4.413463292 seconds, maximum 5.5: passed |
| Search round trip | p95 4605.475375 ms, maximum 4750: passed |
| Checkoff round trip | p95 3744.534833 ms, maximum 3750: passed with narrow margin |
| Scroll duration | Required Scroll_DraggingAndDeceleration.duration series absent: failed |

Rendered timings include XCTest dispatch, idle synchronization and accessibility observation; they are not app-only latency. The separate persisted-pickup evidence retains 500 lines/contributions, 20 checked identities and revision 22 for rendered, and 500 lines/contributions, zero checked identities and revision 2 for scroll. These checks do not substitute for performance measurements.

The scroll native case passed in 282.440 seconds. Original artifact 13554828191 has SHA256 `b52fda2b97833c50f809385879426b98b57bd52f0e6794cafc64832cad5555ef`. A read-only copy of original XCTest SQLite metadata contains exactly three memory series with five samples each and no duration row. Exported JSON agrees exactly; SQLite quick_check is ok. This is an original collection omission, not merely a JSON-parser omission.

Current signpost diagnostics find complete pairs in six swipe activity windows (warm-up plus five measured actions), unlike the earlier 807 run's missing early pairs. These enclosing activities do not identify XCTest's internal collection boundaries. The pairs cannot replace its absent duration series or establish the cause. Apple's [signpost metric documentation](https://developer.apple.com/documentation/xctest/xctossignpostmetric) describes measuring matched begin/end intervals; it does not guarantee that events observed independently were included in a particular XCTest measurement.

All setup receipts and product transport checks passed, with baseline enforcement enabled. Tests used the unchanged optimized products, Xcode 26.3 / 17C529 and iPhone 17 / iOS 26.2 / 23C54. Root rehashed all 732 frozen files without mismatch. The compact audit records exact API artifact digests, native lifecycle, measurement structure, persistence and remaining limits separately. Original archives, bundles, diagnostics and frozen inputs remain under `.build/CIResearch20261106/candidate-0d5bb1b/core-collection/`; freeze paths refer to that directory.

Other core and fixture jobs continue independently. The unpushed selected-text cancellation correction is not part of this source. Release acceptance remains open.
