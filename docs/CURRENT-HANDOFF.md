# Room in the Cart current handoff

Updated November 9, 2026. Active goal: finish the complete first version—Foundation
2.1's 52 requirements, 27 screen contracts and B11. Not complete or paused.
Read [APP-BASELINE](product/APP-BASELINE.md), then the Foundation 2.1 master and
[MASTER-GENERATION](product/MASTER-GENERATION.md). The detailed prior checkpoint
and all earlier native preservation paths remain at
[immutable 21f69b5f](https://github.com/palatis3/room-in-the-cart/blob/21f69b5f7f81dc2ab11767c8de83d7c42d1c746b/docs/CURRENT-HANDOFF.md).

## Workspace and execution ownership

Canonical checkout: `/Users/palatis/Room in the Cart`, local branch
`codex/parallel-ios-ci`. Publish to `codex/combined-candidate-20261109`; its verified
head before this feature update was 5d1ca0a5. Recheck current Git/run state before dispatch.
The ambient `spanish-done-diagnostic` worktree is stale. Draft PR1 is an older
candidate. No full combined qualification or merge has passed.

No Dot/Lumpy. Astra High helpers and Sol6.1 Extra High monitoring are authorized.
Root owns integration and dispatch. One owner per cause, one local native process,
no source/product mutation during execution. Historical attempts below are terminal;
all optional-night native and wire attempts are now terminal. No debugger remains. Disk last reported approximately 32 GiB free;
keep 8 GiB reserve and avoid downloads/duplicate raw archives.

## Implemented workflow

[CI-VALIDATION](CI-VALIDATION.md) governs the feedback loop: diagnose before
repeating, preserve the first failure, reuse compatible build products, and freeze
one revision before full regression. Baseline compatibility is checked before Mac
fan-out; full-release dispatch rejects mismatched candidate/event/checkout SHAs.
Five shared native slots remain. Reports separate measured pre-start waits from
execution, and compact evidence binds hashes to retained originals. Merge and App
Store gates remain separate in [RELEASE-EXECUTION](RELEASE-EXECUTION.md).

New: copy only changed source bytes/modes when assembling successors, preserving
unchanged modification times. The performance simulator producer now explicitly
builds arm64 only, removing unused Intel compilation from that lane. Generated
Release defaults, device archives, consumers and strict gates are unchanged.
438 offline checks and all 17 workflow queue definitions pass. The optimized hosted producer, actual arm64 products and original native scroll
now pass. Required hosted scroll duration remains missing; the 451-versus-618-second
build observation is not a controlled speed comparison.

New workflow gates catch Swift syntax before compilation and database fixture
problems before integration setup. Collector readiness/readable output/expected
events must pass on a small control before full app diagnostics. 109 Python,
18 harness and 7 actual PostgreSQL checks pass; 17 queue contracts remain intact.
[Validation](evidence/ci/workflow-preflight-20261109/README.md).

Primary CI: Xcode 27.1/27A9275, arm64 `xcode-27`, iPhone 17 / iOS 27.0/24A434. Swift
CodeQL retains its required macOS15/Xcode 26.3 exception. Minimum iOS remains 17.0.
The only approved performance profile is 26.3/17C529 with iOS 26.2/23C54; 27.1 remains
unapproved. Do not dispatch full release expecting this mismatch to pass.

## New verified changes

0. **Shared recovery ordering:** a real original-product HTTP negative control
   reproduced a feasible repair rejected because coverage and recovery assigned
   scarce stock in different orders. Both now preserve protected/named priorities,
   exact connected-shop precedence, then deadline and reviewed need identity.
   Numeric scope ordinals preserve SQL microsecond ordering. Strict verifier and
   reviewed UUID generation unchanged. Seven focused HTTP, 93 domain, 452 fast
   (one DB-only skip) and 257 broad integration checks (three browser-only skips)
   pass. Disposable DB stopped/removed; no migration/deployment/native change.
   [Proof](evidence/service/shared-recovery-order-20261109/README.md).

1. **Shared exclusion matches:** original HTTP negative controls reproduced two
   incorrect 200 responses. Pantry/delivery now reject explicit conflicts with 409
   `match_exclusion_conflict`, including effective recovery restrictions. Local
   focused PostgreSQL/HTTP: 38 pass; broad integration: 250 pass / 3 browser skips; fast
   service: 450 pass / 1 database skip. Native localized feedback no longer reports a
   terminal rejection as saved, while retaining durable review cleanup and uncertain
   waiting retries. Debug build and all 19 SharedShopFlowTests pass native/strict.
   No migration or hosted deployment occurred.
   [Exact proof](evidence/native/shared-match-exclusions-20261109/README.md).
2. **Performance loaded-image observer:** reviewed same-file helper and explicit
   collector pin installed; original 3 selectors/measurements/assertions preserved.
   20 synthetic parser controls pass; Release build/bundle/inventory pass. Full local
   scroll passes native/strict and required metrics: 5 durations, median 2.581955166 s;
   memory complete, hitches unavailable. Saved 500 rows / 500 contributions / 0 checkoffs / rev 3.
   Post-measure runner observes MTC UUID E40A186A-8D7D-3029-B5CD-D42C967992C0 once;
   RPAC has no match. The hosted runner now reports the same post-measure identity.
   No during-measure loading/activity or metric-cause inference.
   [Exact proof and inspection caveat](evidence/native/performance-loaded-images-20261109/README.md).

The last fully qualified 561-input native snapshot used source manifest
`a357a09918cf6dc15093dccb8dc992dc16e5baaff789b8eb490fddb5f9708791`.
Execution workspace `.build/Xcode27WarningReviewNov09/execution-r1/{source,dd}` now
has since advanced to the unqualified optional-night successor described below.
The following products and executors are historical; their archived proof remains valid.
Debug products manifest f51f027c66f299c08f8c719076bd956a8af631d025bcf283bbf432f7f954ff55
is archived with source under `.build/NativeQualificationArchivesNov09/<source-SHA>/shared-match-debug-products-f51f027c66f299c0/`.
Release products manifest 3de01fde66170f6ffdbcf9b3fe7d7fa2bdd477e3a0a44e220e4fb6c5d58138a8
is also archived under the same source-SHA directory in
`performance-observer-release-products-3de01fde66170f6f/products`, with a preservation
receipt referencing the already-verified Debug source archive. Do not overwrite it. Both source and
products stayed unchanged during their test executions.

The initial scroll setup failed before XCTest because an old Release test app was
installed. Its complete app/data were verified and preserved before uninstalling
only that owned installation. Successful attempt is `run_scroll_r2.py`; inspect once
with `inspect_scroll_r2.py` (already completed). Its original custody check returned 1
because a new `database.sqlite3` appeared in the result during inspection. Separate
`inspection-observer-r2/custody-review.json` proves all original members unchanged,
no removals, stable added Xcode results database and successful SQLite check. Do not
rewrite the first receipt or rerun native work for that addition. Local Release used
the prior dual-architecture command, so it does not qualify the optimized producer.

## Pending optional-night implementation

Local shared meals now accept a required `day` key with explicit null, preserving
identities when later scheduled. The backend passes 3 focused HTTP, 98 domain,
454 fast (1 DB skip), and 260 integration checks (3 browser skips). No migration
or deployment. Source and evidence hashes: `.build/SharedUndatedNov09/verification.json`.
Older native clients cannot decode null days; coordinate native/service rollout.

The optional-night implementation is locally verified and ready for the combined
candidate. [Compact proof](evidence/native/shared-optional-night-20261109/README.md)
binds retained source/test evidence. Ordinary Debug build passes;69 affected model
tests pass native/strict;108 HouseholdClient package cases pass with3 approved wire
skips;24 inventory checks and structural localization pass. The two unchanged
EN/ES civil-date journeys passed in the initial run. The two new optional-night
journeys now pass completely (native/strict), including same IDs, date/deadline
availability, unassignment, review, and a fresh selection starting unscheduled.
The initial bracket and optional Placement facts compile failures are preserved.
UI failures were diagnosed from retained events/video/accessibility: centre-row
switch taps did not change its state, and the review marker needed scrolling.
Tests now target the visible thumb, assert its state, use a generic compact-date
identifier and reveal the marker. No production behavior/assertion was suppressed.

Current native source manifest:
`a1aba92422d05be5eecc332240939c59b01b134e22e5763caff39fc64409c8f6`.
Current executor/results: `.build/SharedUndatedNov09/native-fixture-r3/`.
Stable source/DD: `.build/Xcode27WarningReviewNov09/execution-r1/`.
Current fixture products manifest:
`94d798eeeb35e7ee577b4ed53c06f408801edc637f8b62a6f67c3a1771d12af4`.
Every successor preserved prior source/products with verified bytes/modes under
`.build/NativeQualificationArchivesNov09/`. Ordinary model proof is under
`native-r3/shared-models-r2/`; production native files did not change afterward,
only the UI test and native-wire test helper. Source/products remained unchanged
through their test runs. All native tool sessions are terminal.

The reviewed `wire-review-r2` test patch is now installed and executed. Full
native HTTPS/PostgreSQL lane passes all7 Node cases and12 exact Swift scenarios.
Two actual Swift processes persist null, reconstruct the client, read the same
meal, schedule with identical ingredient/group/protected-lunch allocations, and
retry a Codable-restored operation. SQL proves preserved history/snapshots and
two committed patches despite four sends. Original ordinary3-skip policy remains.
Evidence: `.build/SharedUndatedNov09/wire-r1/`; complete source manifest
`e8b57881f703afdd2c207d35b4763d9b4b01c9e5cb86b76be1e3de668ea09865`.
Owned PostgreSQL cluster/private fixture state were stopped and removed.
This proves native-client process restart, not a complete iPhone UI relaunch.
Physical/human/live-provider and final combined-hosted acceptance remain separate.
No migration, staging deployment or full-release dispatch occurred.

## Remaining diagnostic work

- New manual `enable_performance_diagnostics` is false by default, single launch/scroll
  only, baseline enforcement off, and incompatible with another live collector.
  Ordinary commands, original tests and same-run provenance remain intact. Available
  diagnostics export to existing evidence; failed export fails visibly.
  One local original scroll with the supported flag passes native (92.578s), strict
  and complete required metrics, but retains no trace. Session explicitly records
  `enablePerformanceTestsDiagnostics:1`, `traceCollectionEnabled:(null)`; eight
  exported files contain only logs, screenshot and loaded-image JSON. No proven
  transport error or capture-start. Do not dispatch a hosted repeat until a useful
  collection mechanism/discriminator is established. Source/products/original
  results unchanged; inspection used a verified clone. All processes terminal.
  [Proof](evidence/native/performance-diagnostics-20261109/README.md);
  originals `.build/PerformanceLoadedImagesNov09/execution-r1/.build/performance-trace-r1/`.

- A subsequent app-scoped Instruments control also failed capture: no readiness,
  tracer exit 1, unreadable trace/export exit 10. Original native scroll and required
  metrics passed; capture did not. Exact owned tracer cleanup completed. Do not
  repeat the full journey: qualify a small collector control first.
  [Preserved evidence](evidence/native/performance-instruments-20261109/README.md).

- Read-only collector follow-up confirms the prior command selected implicit
  **Blank + os_signpost** (recorded in instruments.log), so missing `--template`
  is not an established cause. Next discriminator: small owned host signpost
  emitter, explicit built-in Logging template,15-second readiness and5-second
  recording, two boundary events/three interval pairs, normal readable finalization
  and exact-PID cleanup. This qualifies host capture only; simulator proof remains
  separate. No tracing/compiler experiment has run for this proposal. Prepared source and a
  bounded supervisor are under `.build/HostSignpostControlNov09/r1/`. Python AST
  parsing only; root must review/compile and pin the exact helper/xctrace binaries.
  Its `captureQualified` deliberately stays false until actual exported event
  schema and expected events are verified.

- Latest hosted 42639339096 attempt 1 at dc343f3e is terminal failure: arm64-only
  producer, immutable plan/products, native 1/1 and cleanup pass; required scroll
  duration is absent, with only 3 memory series × 5. Selected-runtime bytes match
  producer. Crucially, the post-measure runner attachment matches local exactly
  except PID: MTC UUID E40A186A-8D7D-3029-B5CD-D42C967992C0 present, RPAC no match,
  1,130 callbacks / 5,263,912 bytes / complete. The declared producer path is still absent
  pre/post setup, but it does not establish absent runner loading.
  [Final report and retained hashes](evidence/native/hosted-arm64-observer-20261109/README.md).
  Coordinator independently verified all 3 GitHub ZIP digests and read actual Mach-O
  headers for app/tests/extensions and all 5 static package objects: arm64-only.
  Monitor originals: `.build/HostedLoadedImagesNov09/monitor/`; product original and
  architecture proof: `.build/HostedLoadedImagesNov09/products/`.
- The post-measure runner-image question is closed. Do not repeat filesystem/image
  probes, rewrite plans or disable checkers. Before another expensive run, identify
  one discriminator for measured-window collection/transport or relevant application
  environment. Screenshots already prove rendering; Simulator.app visibility and
  during-measure/AUT states remain unmeasured, not established causes. A post-hoc
  query found zero matching events but cannot distinguish emission from transport.
- Capability-only 42625593343 and earlier 42620394385 remain preserved historical
  results. No baseline or full combined acceptance follows from these diagnostics.
- Original Spanish iOS 17.0 journey still fails. Direct LLDB capture confirms null
  x0/strcmp → XCTest runtime_issue_os_log_fault_callback → libtrace quarantine
  during accessibility query. Null origin remains unknown. One exact-PID resume
  completed verified detach cleanup. Debugger timing is diagnostic-only.
  The later direct-label query experiment also failed and is not installed; its
  source/products are archived. No unchanged query/resource/checker-suppression retry.
  [First-fault proof](evidence/native/minimum-os-first-fault-20261109/README.md).
- The owner approved the private Apple report and completed Feedback Assistant's
  terms/sign-in. The native app now confirms **Feedback Sent** for the XCTest
  report with exactly the three approved attachments. No automatic system
  diagnostics were added. Apple says attachment transfer continues in the
  background; that upload completion and a feedback ID were not yet observed.
  Receipt: `.build/MinimumOSXCTestReproducerNov09/apple-report-draft/submission-confirmation-20261109.json`.
  Exact immutable approved package:
  `.build/MinimumOSXCTestReproducerNov09/apple-report-draft/reviewed-first-fault-package/`
  with REPORT.md, 10 KB capture and manifest only. Do not duplicate submission or
  reinterpret the old immutable manifest's `notSubmitted` field as current status.

Read-only minimum-OS follow-up: a separately built26.3 UI runner targeting the
same27.1 app is only a proposed diagnostic, not qualified acceptance. Apple lists
26.3 host support through macOS26.x; this Mac27.2 is outside that range, so any
probe needs a supported separate host. Do not run27.1-built XCTest bundles with
old xcodebuild. No retained26.3/iOS17 original-Spanish pass was found; older Spanish
passes used26.2 runtime. A27.1/iOS17 request journey has passed, so the fault is not
universal. Any experiment must preserve the exact app, original Spanish assertions,
checker settings and720/900 limits, and prove app/runner/runtime identity.

Then finish remaining fixes, freeze one final commit, run full combined regression,
review required checks and merge only when its gates pass. Focused results from
other revisions cannot be assembled into full acceptance.

## App release still separate

Current accepted local work includes ordinary F02 removal/Cancel/Apply/restart and
SQLite proof, clarification contrast/AX5 coverage, fixture isolation and corrected
SDK provenance; see the immutable prior checkpoint and CURRENT-ACCEPTANCE.
Authenticated mixed-device F02 and other B11/provider/physical-device/human review
gates remain incomplete. Staging approval extends through 041; 042 and subsequent
service rollout need their own reviewed scope. Paid Apple membership/signing, SMTP
and KWS activation are owner deferred; do not repeatedly request them. Operator:
Venture House Group LLC. Support: hello@roominthecart.com.
