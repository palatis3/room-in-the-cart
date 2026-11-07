# Hosted standalone scroll witness

[One manually dispatched run](https://github.com/palatis3/room-in-the-cart/actions/runs/42332357700) tests diagnostic commit `ab149a7f27d9366db61c4fe2d9047095f166be3d`, based on original `0d5bb1b`. Root explicitly supplied `enforce_baselines=true`; collection must also verify enforcement from the case logs.

Only the standalone test metric and previously reviewed schema-2 endpoint parser/tests differ. App, built-in metrics, measured closure, fixture, checker, baselines and all workflows are unchanged. The original workflow runs a build and all three performance cases. The original complete cohort finished before this dispatch.

The original dispatch receipt remains as a historical checkpoint. The full, now-terminal collection is retained under `.build/ScrollReportWindowHosted20261106/collection`. Hosted verification below is separate from the earlier local Xcode 27.1 qualification. The PR candidate remains unchanged at 0d5.

## Terminal outcome

The run completed successfully: all three native cases and unchanged measurement gates passed, with strict checks and zero runtime warnings/restarts. Root rehashed all 696 frozen collection files; [terminal review](terminal-root-review.json) pins the full audit and freeze. Launch median was 3.95231225 seconds; scroll median was 2.5836895 seconds with all five required native samples; rendered search/check P95 was 2298.72025/2254.152375 ms. Rendered values are XCTest interaction round trips, not app-only latency. The source app and rendered/launch test bodies are unchanged from 0d5, so the changed timings are not an app speedup claim.

The [scroll correlation](scroll-review.md) binds all six report windows and scoped endpoint pairs. Hosted Xcode 26.3 compatibility is established for this instrumentation. The original missing-series failure is still unexplained; adding observation can change collection behavior. The original PR candidate has not been relabeled, and this isolated diagnostic is not release acceptance. No repeat dispatch was performed.
