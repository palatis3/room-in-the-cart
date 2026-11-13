# Native result-finalization timing

The shared shard runner now writes a log-bound timing report before JSON export,
even after a native failure. The original test selection, deadlines, diagnostics
in CI, retry eligibility and strict acceptance checks are unchanged. A timing
report failure cannot replace a native or strict failure with success.

The report distinguishes the root test-suite wall interval from the interval
until Xcode’s test observer completes. Missing, repeated, restarted or inconsistent
boundaries stay unknown. The latter interval includes diagnostics and teardown;
it does not measure pure export overhead. An infrastructure retry keeps a separate
report. Existing `test-*.json` artifact paths already include both files.

Validation: 457 Python checks pass with no skips, including parser and actual shell
entry-point controls for native failure, strict failure, unavailable timing and
separate retry receipts. Shell syntax, localization and diff checks pass. Applied
the parser to retained real logs: the eight-case batch has 344.985 seconds in its
root suite and 600.335 seconds after the suite, including an explicit 600-second
simulator-diagnostic timeout. Its focused successor has 35.304 and 0.287 seconds.
These runs cover different inputs and test counts; this is no speedup benchmark.

The workflow policy permits `never` only for focused local retries of explained UI
assertions with retained evidence. Unexplained crashes, hangs and framework faults
retain `on-failure`; hosted defaults remain unchanged. Full result bundles, logs,
recordings, assertions and strict selector accounting remain required.

[Verification and retained hashes](verification.json) bind the local evidence.
No hosted execution of this timing addition or full combined acceptance is claimed.
