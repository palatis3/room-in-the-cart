# Exact 804030e fixture and native-wire terminal evidence

Candidate `804030e68473d022e72b464940061c01c611a0bd`, ordinary pull-request push, attempt 1. Fixture run `42272379477` ended **failure**; native-wire run `42272379461` ended **success**. Collector session `34355` stopped after terminal collection. Separate root-owned diagnostics are outside this proof.

## Execution and failure

All **45 fixture cases executed: 44 passed, 1 failed, 0 skipped, 0 expected failures**. No cancelled jobs, runner-acquisition failures, or unexecuted cases. The 44 passes are 37 ordinary cases in entirely passing shards, 6 passing cases in the failed contributor-balanced-02 shard, and 1 redacted Records result. The failing shard's strict verifier correctly exits 1.

The sole failed selector is `MeasurementUITests/testLocalSettingsConsentIgnoresLegacyBooleanPersistsRestartAndStaysWorkspaceScoped`. Its **first state-changing consent invocation** (test line 24) failed the helper assertion at `ios/UITests/MeasurementUITests.swift:125`: switch value `0`, expected `1`, after 27.365 seconds. This is an executed assertion failure, not a timeout. The recorded tap was `(356.4, 651.833)` and falls inside the teardown's inner-switch frame. The teardown screenshot and hierarchy show off/value 0. Later relaunch/workspace behavior was not verified by this failed case. Root cause remains undetermined; source/log/runtime/event and attachment hashes are retained in `fixture-measurement-assertion-failure.json` and `measurement-triage/triage-proof.json`.

KnownTrip passed on this candidate in 642.71 seconds under the unchanged 720-second default allowance. Its earlier 8f failure remains separate and unchanged.

## Exactness and warnings

56 frozen input/source files match the exact Git object. The duplicate-free union from both independently replayed result profiles is exactly **45 selectors**, equal to source inventory. All ordinary result logs retain the 720/900-second allowances and demonstrate exact serial case identities/start-completion lifecycles. There were **0 XCTest runner restarts and 0 hosted retry bundles**.

Every ordinary executed result independently verifies iPhone 17, arm64, iOS 26.2 build 23C54, Test Scheme Action. Build logs record Xcode 26.3 (17C529).

There are **6 actual runtime warning occurrences**, all matching unchanged scoped Menu allowances:

| Case | Count / cap | Exact tap | Activity phase |
| --- | --- | --- | --- |
| KnownTrip | 2 / 2 | `fixture.s27.controls` | Wait for app to idle |
| LostReply | 2 / 2 | `fixture.s27.controls` | Synthesize event |
| StaleReviewedSave | 2 / 2 | `fixture.s27.controls` | Synthesize event |

Each is the exact `_UIReparentingView` message and original device/configuration, supported by detailed test and activity exports. The other examined ordinary cases have zero warnings. Records' redacted report also records zero warnings. Passing within these allowances does not mean warning-free.

## Artifact and scheduling scope

All **15 result archives** (14 fixture results plus native-wire) have verified SHA-256, size, unique entries, path/type safety, per-member bounds, and expanded-size bounds. Default bounds were not enlarged. Build product metadata is pinned; product archive bytes were not downloaded/read. Records was restricted to the exact redacted report/compiled-plan allowlist; **no raw Records media was downloaded or read**.

Scheduling history preserves `pending` shared-slot admission separately from `queued`/runner execution. All admitted fixture work eventually executed, without cancellation. This lane's history does not independently certify repository-wide slot occupancy.

Native-wire independently verifies **4 Node cases and 6 exact Swift invocations in expected order**, no failed/skipped/cancelled TAP cases, and PostgreSQL shutdown. New-head artifact `13530906746` is pinned; no prior-candidate result was substituted.

`allEvidenceCollected=true`; **`allRequestedChecksPassing=false`** because the Measurement assertion failed. No retries, dispatch, cancellation, source/Git edits, or native execution were performed by the collector.

Primary proofs: `fixture-terminal-proof.json`, `fixture-terminal-summary.json`, `fixture-result-compiled-union.json`, `fixture-runtime-audit.json`, `fixture-execution-order-audit.json`, `fixture-archive-audit.json`, `fixture-scheduling-terminal.json`, `native-wire-order-audit.json`. `fixture-review-manifest.json` freezes compact evidence; archive digest pins cover large result bundles.
