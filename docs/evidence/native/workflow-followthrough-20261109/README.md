# Workflow follow-through — November 9, 2026

Parent revision: `4bc86e26961bb6857e519951410d1358eb5f5d26`.
Scope: release dispatch identity and bounded performance capability discovery.
No full regression, merge, native performance measurement or release acceptance.

## Changes

- Full `release-checks.yml` dispatch requires `candidate_sha`, a full lowercase
  SHA matching both the event revision and checked-out HEAD. Linux checks this
  immediately after checkout, before the native jobs can allocate a slot.
  Inputs enter through an environment variable, not shell interpolation.
- The performance collector filters runtime inventory by its configured runtime.
  Exact identity, uniqueness, availability, version/build and device checks remain.
  Output caps, command deadlines, source pins and metrics are unchanged.
- Existing policy remains: measurements before baseline approval, one frozen
  combined revision, five shared Mac slots, retained compact evidence and separate
  merge/distribution readiness. No additional shard or duplicate suite was added.

## Observed diagnostic

A fresh owned iPhone 17 simulator uses installed iOS 27.0 build 24A434 with local
Xcode 27.1 build 27A9275. No runtime download was needed. Boot passed in 42.297s.
Three prior owned test simulators were shut down; the protected preview was untouched.
Available storage was 19.89 GiB before creation and 18.08 GiB after validation,
above the existing 8 GiB reserve.

The unchanged collector passed device discovery in 2.046s but failed runtime
discovery at its 64 KiB output cap. The installed `simctl help list` documents
runtime substring filtering. A filtered smoke returned exactly the required
runtime in 20,033 bytes. The corrected capability probe passed all seven stages
in 4.557s, including all three logging help checks. The first failure is retained.
This establishes local capability discovery only: no log transport or XCTest was
executed, and it does not resolve the hosted discovery stalls or missing metrics.

## Validation and retained originals

- All 371 offline tests passed in 14.657s, including malformed/mismatched candidate
  inputs and misleading/missing/duplicate/unavailable runtime results.
- Focused collector: 57 tests passed. Focused release preflight: 7 tests passed.
- Pinned actionlint and all 17 queue-node checks passed. Whitespace check passed.
- Independent review found no blocker in runtime filtering. The first release-test
  invocation lacked PyYAML; the existing pinned virtual environment passed,
  without installing dependencies.

Private/local originals remain under `.build/LocalPerformanceCaptureNov09/` and
`.build/ReleaseCandidateGuardNov09/`. Retain these for project lifetime; this report
does not replace or authorize deletion of them. These locations are local-only.

| Original | SHA-256 |
| --- | --- |
| `LocalPerformanceCaptureNov09/capabilities.json` (first failure) | `95e6e439e3950a987e2fb6afa5f113fcc10688d46c997eef6ed638f305f90f5f` |
| `LocalPerformanceCaptureNov09/capabilities-r2.json` | `15b437efd9a38eb20347e8c56434f15ec3bfa2806621fbf70d4a25ba5f94f223` |
| `LocalPerformanceCaptureNov09/capabilities-r2-execution.json` | `7708513cc9d1224350ce85302cee34c009b13e52589437e2f3672cc8d1e8c921` |
| `LocalPerformanceCaptureNov09/offline-tests.log` | `b98bf067363d516194fccb475f66bbba71c83e908e5d3938c78b677d481a2147` |
| `ReleaseCandidateGuardNov09/validation-receipt.json` | `3ab433ac652d915dee39404932308d97e4bd6815057bfe00950b6e48f27a00da` |

Next: preserve the current stable-workspace source and products before preparing
the original Release scroll capture on the dedicated simulator. Minimum-iOS
qualification and complete measurements still precede the frozen full batch.
