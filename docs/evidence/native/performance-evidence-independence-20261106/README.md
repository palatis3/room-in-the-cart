# Independent performance evidence checks

When XCTest omits the required scroll duration, the checker previously exited before reading the saved pickup. It now retains independent measurement and SQLite outcomes in `evidence-validation.json`, while either failure still returns exit 1 and prevents a calibration report. Rendered-case readback still requires valid attachment-derived checkoff and search identities; missing attachments never authorize an empty expected set. Each invocation removes stale calibration/evidence outputs first.

The new subprocess tests exercise a real fictional 500-line SQLite fixture across missing/present scroll metrics and valid/corrupt payload digests, including simultaneous failures and a stale success report. They verify read-only database bytes and unchanged failure exit codes. Missing rendered attachments produce an explicit unperformed readback. Existing calibration, baseline rejection/regression, metric units/cardinality and saved-import checks remain covered.

All 10 tests pass. The exact old checker fails the added tests in five subcases because it cannot produce the independent report. Root compares 17 acceptance functions/constants by AST and finds no changes. Independent review reports no actionable findings. [Validation](validation.json) · [Review](review.md). Full old/new test logs and the preserved old checker are under `.build/PerformanceEvidenceIndependence20261106/`.

This changes evidence collection, not the native app, test actions, required metric series, limits or release acceptance. It does not recover missing XCTest metrics or retroactively establish app-ledger readback for the failed hosted qualification. The change is locally validated and has not been published or executed on a hosted runner.
