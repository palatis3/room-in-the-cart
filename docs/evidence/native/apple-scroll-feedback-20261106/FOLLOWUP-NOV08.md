# November 8 cardinality failure — local addendum, not submitted

This adds a different observed failure to the existing [Apple Feedback draft](REPORT.md). It does not identify a faulty producer or establish an Apple framework defect. No new native run, build, upload or external submission was performed.

Retained monitoring binds source `fe3e14306eee08f0464215b560dccaf21054c6a8` to performance run `42509307171`, attempt 1, scroll job `128821661268`. The artifact records Xcode 26.3 / 17C529 and iPhone 17 arm64, iOS 26.2 / 23C54. These identities come from retained files, not a fresh remote lookup. The [readback receipt](FOLLOWUP-NOV08-READBACK.json) records exact input paths, byte counts, SHA-256 hashes, query results, and source Git-object hashes.

The native log `.build/CIFe3e143Nov08/performance-scroll-artifact/Performance.log:258` reports at `ReleasePerformanceUITests.swift:172`:

> Received unexpected number of metrics: 3 in iteration with index 4. Got 4 in iteration with index 0

The last upward swipe starts at t=95.21s; the post-gesture existence check occurs at t=99.18s. The cardinality error follows, then teardown at t=100.65s and the failure screenshot at t=100.92s. The native case fails after 102.406s. The normal post-measure screenshot is absent. No precise report-callback time or framework failure stack is inferred from this activity log.

## Independent retained database readback

The database is `.build/CIFe3e143Nov08/performance-scroll-artifact/Performance.xcresult/database.sqlite3`, 294912 bytes, SHA-256 `e676aefd1c419a27bb2f3114adccdf333aff66bf9b6805c22a9bdda8c6eaa30b`. It was opened through Python sqlite3 using the file URI with `?mode=ro&immutable=1`; no SQLite sidecars were present. All ten inspected artifact/provenance files had identical hashes before and after the readback.

```sql
SELECT COUNT(*) FROM sqlite_master
WHERE type = 'table' AND name = 'PerformanceMetrics'; -- 1
SELECT COUNT(*) FROM PerformanceMetrics; -- 0
SELECT identifier, unitOfMeasurement, measurements FROM PerformanceMetrics; -- []
```

`SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'PerformanceMetrics'` returns:

```sql
CREATE TABLE PerformanceMetrics (identifier TEXT, orderInTestCase INTEGER, maxStandardDeviation REAL, displayName TEXT, polarity TEXT, maxPercentRegression REAL, baselineAverage REAL, testCaseRun_fk INTEGER NOT NULL REFERENCES TestCaseRuns, unitOfMeasurement TEXT, baselineName TEXT, maxRegression REAL, measurements TEXT, maxPercentRelativeStandardDeviation REAL)
```

`SELECT rowid, result, duration, testCase_fk FROM TestCaseRuns` returns one row: `[1, "Failure", 102.4055290222168, 1]`. `SELECT testCaseRun_fk, compactDescription, issueType FROM TestIssues` returns one issue for run 1, containing the same cardinality message and the native category `Performance Regression`. That category does not establish a timing-threshold regression; the observed issue is inconsistent measurement count.

The exported `metrics.json` is also `[]`. Empty archived `PerformanceMetrics` storage corroborates the export, ruling out an explanation confined to this JSON exporter dropping otherwise stored metric rows. It does **not** prove all individual producers returned empty, identify which measurement was absent, or distinguish report output from downstream aggregation/recording loss.

## Limits and preserved acceptance

The schema-1 signpost receipt records six paired gesture activity windows, 24 parsed candidates, zero unparsed candidates, and one matched process. It lacks raw endpoint timestamps and is based on enclosing swipe activity windows, not XCTest measurement boundaries. It cannot prove collector receipt, report contents, or correspondence between an activity label and the failing metric iteration. The 24 binary plist attachments are synthesized input events; they add no per-producer report evidence.

The original metric objects, five measured samples, assertions, fixture, strict required-metric checks and approved baseline limits remain unchanged. The native test remains failed and release acceptance remains incomplete. A future causal diagnostic must distinguish actual producer return arrays; another unchanged retry or reconstruction of a duration from these signposts would not answer that question. The separate observer proposal remains unqualified and is not authorized by this addendum.
