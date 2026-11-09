# One hosted scroll observation

The default-off manual performance profile now tests one question: do the app's
named UIKit scroll intervals exist on the separate hosted consumer while the
original XCTest duration is missing? The producer/consumer split, original
measurement, fixture, strict result checks and baseline requirements remain.

Before compilation, the profile validates its inputs, tool/source identities,
runtime, public Logging template, exact SDK helper declarations and build settings.
It runs the original scroll selector once. Collection, trace export, XCTest,
fixture and required metrics have separate outcomes. A failed transport check
cannot suppress inspection of an available test result or make it pass.

The workflow seals evidence before simulator cleanup. A bounded file-only archive
preserves executable modes across artifact download and excludes disposable copies.
Successful upload sends that archive and its receipt once. A bounded raw fallback
is explicitly unqualified. Disk checks reserve 8 GiB plus archive headroom.
Normally collected evidence can support a separately reviewed export-only recovery,
without rebuilding or rerunning the app; no retry is automatic.

Root verified all 22 canonical files, the frozen payload and retained test-log
hashes. Preparation recorded **281 passing controls across incremental checkpoints**.
Those logs did not establish a final combined preflight after workflow edits;
the first hosted run exposed stale assertions and inherited diagnostic settings.
[Complete profile checks now supersede that count for dispatch readiness](../performance-dispatch-parity-20261109/README.md).
Workflow lint and all 17 queue definitions pass. Complete gated helper declarations
typecheck against arm64 simulator SDK 27.1, Swift 5, with no warnings or errors.
The helper process exited normally. This is not a complete app build or a hosted
transport result.

Local originals are under `.build/HostedAppObservationNov09/implementation-r4/`.
Earlier failed controls and r1–r3 checkpoints remain unchanged. The compact
`verification.json` binds validation to source and retained originals. Raw trace
and result data are diagnostic artifacts, not public Git evidence.

The next scoped run requires `case=scroll`, `enforce_baselines=false`,
`fresh_performance_simulator=true`, `observe_app_scroll_signposts=true`, and all
other collectors false. A missing required duration still fails. If the duration
appears only with observation enabled, that does not establish a fix. No baseline,
full combined-revision acceptance, minimum-iOS acceptance or release is approved.
