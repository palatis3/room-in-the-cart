# Hosted standalone scroll witness

[One manually dispatched run](https://github.com/palatis3/room-in-the-cart/actions/runs/42332357700) tests diagnostic commit `ab149a7f27d9366db61c4fe2d9047095f166be3d`, based on original `0d5bb1b`. Root explicitly supplied `enforce_baselines=true`; collection must also verify enforcement from the case logs.

Only the standalone test metric and previously reviewed schema-2 endpoint parser/tests differ. App, built-in metrics, measured closure, fixture, checker, baselines and all workflows are unchanged. The original workflow runs a build and all three performance cases. The original complete cohort finished before this dispatch.

This is a dispatch checkpoint, not a pass or a fix. Local Xcode 27.1 qualification does not prove hosted Xcode 26.3 behavior. Full collection is retained separately under `.build/ScrollReportWindowHosted20261106/collection`; no terminal conclusion is recorded here yet. The PR candidate remains unchanged at 0d5.
