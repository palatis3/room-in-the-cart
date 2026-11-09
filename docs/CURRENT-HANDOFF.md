# Room in the Cart current handoff

Updated November 9, 2026. Active goal: finish the complete first version—Foundation
2.1's 52 requirements, 27 screen contracts and B11. Not complete or paused.
Read [APP-BASELINE](product/APP-BASELINE.md), then the Foundation 2.1 master and
[MASTER-GENERATION](product/MASTER-GENERATION.md). The detailed prior checkpoint
and all earlier native preservation paths remain at
[immutable 21f69b5f](https://github.com/palatis3/room-in-the-cart/blob/21f69b5f7f81dc2ab11767c8de83d7c42d1c746b/docs/CURRENT-HANDOFF.md).

## Workspace and execution ownership

Canonical checkout: `/Users/palatis/Room in the Cart`, local branch
`codex/parallel-ios-ci`. Publish to `codex/combined-candidate-20261109`; verify its
current remote head and run state before dispatch. The last verified remote
checkpoint before this update was 2e3ef60e.
The ambient `spanish-done-diagnostic` worktree is stale. Draft PR1 is an older
candidate. No full combined qualification or merge has passed.

No Dot/Lumpy. Astra High helpers and Sol6.1 Extra High monitoring are authorized.
Root owns integration and dispatch. One owner per cause, one local native process,
no source/product mutation during execution. Historical attempts below are terminal;
all optional-night native and wire attempts are now terminal. No debugger remains. Disk last reported approximately 166 GiB free;
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
That earlier update passed 438 offline checks and all 17 workflow queue definitions.
The optimized hosted producer, actual arm64 products and original native scroll
now pass. Required hosted scroll duration remains missing; the 451-versus-618-second
build observation is not a controlled speed comparison.

New workflow gates catch Swift syntax before compilation and database fixture
problems before integration setup. Collector readiness/readable output/expected
events must pass on a small control before full app diagnostics. 109 Python,
18 harness and 7 actual PostgreSQL checks pass; 17 queue contracts remain intact.
[Validation](evidence/ci/workflow-preflight-20261109/README.md).

Follow-through now retains core/fixture build logs and checkout/toolchain receipts,
plus unique native-wire attempts with bounded per-scenario output and structured
failures. Failed database/journal state stays owner-only outside upload paths;
success removes it. Scenario helpers remove their TLS files during cleanup.
449 Python source contracts, output/custody controls and 17 queue
definitions pass. The actual revised wire harness passes 7 Node/12 Swift scenarios
in 134.77 seconds, with every scenario output/hash verified, sources unchanged and
private fixture state removed. `.build/WorkflowFollowthroughNov09/native-wire-r1/`
and `.build/native-wire-results/attempt.IXnzY7/` retain the terminal proof. New upload
execution remains for a future hosted run; no full batch was dispatched.
[Compact evidence](evidence/ci/workflow-followthrough-20261109/README.md).

Primary CI: Xcode 27.1/27A9275, arm64 `xcode-27`, iPhone 17 / iOS 27.0/24A434. Swift
CodeQL retains its required macOS15/Xcode 26.3 exception. Minimum iOS remains 17.0.
The only approved performance profile is 26.3/17C529 with iOS 26.2/23C54; 27.1 remains
unapproved. Do not dispatch full release expecting this mismatch to pass.

## November 9 workflow follow-through

Native shards now retain log-bound timing before result export, including failed
attempts and separate infrastructure retries. The report distinguishes test-suite
execution from post-suite observer work and leaves missing/ambiguous boundaries
unknown. The real retained eight-case run has a 344.985-second suite followed by
600.335 seconds, including a system-diagnostic timeout. All 457 Python checks,
shell syntax, localization and diff checks pass. Hosted diagnostic defaults,
selector coverage, deadlines and strict acceptance remain unchanged. Focused local
UI retries may omit a duplicate verbose system dump only with an explained failure
and retained evidence. [Proof](evidence/ci/native-finalization-timing-20261109/README.md).

The exact shared-demand contract/reducer slice is committed as 5d5676a7: rational
quantities, stable original sources, bounded duplicate/within-existing allocations,
aggregate exclusion checks, protected-source conservation and conflict-aware Undo.
50 focused tests and isolated TypeScript compilation pass. This is pure domain
work, not F01/F02 route completion, database integration or deployment.
[Proof](evidence/service/shared-demand-domain-20261109/README.md).
The following local persistence boundary is now implemented: migration043,
atomic/replay-bound graph previews and Apply, legacy writer fences, server-derived
provenance, privacy erasure and actual backup restore/replay protection. Final
verification passes 527 offline tests (one database-only skip) and 281 PostgreSQL
tests (three existing optional browser skips). Root independently verified all 14
owned source files and all 112 final database-run inputs against the frozen
manifests. A 2,000-source graph uses 58/59 runtime queries for adoption/review.
The original 26-input plan and failed attempts remain retained; native DTO/UI,
mixed-client HTTPS, downstream projections and shared export/import acceptance
remain open. [Proof and limits](evidence/service/shared-demand-persistence-20261109/README.md).
Migration043 is not deployed; staging authorization remains through041.

New local diagnostic rules in CI-VALIDATION require exact SDK/architecture helper
typechecks before full compilation and export-only recovery after normal collection.
The latest app-signpost attempt reused verified source/products and completed both
XCTest and its 60-second trace normally. Only the XML export exceeded its 8 MiB cap;
the original failed receipt remains unchanged. Root audit confirms terminal native
processes and stable artifacts. Export recovery and independent strict/fixture/
measurement inspection are pending under `.build/AppSignpostCaptureNov09/`.
This historical diagnostic does not qualify the combined app or hosted baseline.

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
Execution workspace `.build/Xcode27WarningReviewNov09/execution-r1/{source,dd}` has
advanced through optional-night and locale work to the date-sheet successor below.
Focused verification does not establish a full combined regression pass.
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

## Verified optional-night implementation

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

Last optional-night native source manifest (preserved before the locale successor):
`a1aba92422d05be5eecc332240939c59b01b134e22e5763caff39fc64409c8f6`.
Optional-night executor/results: `.build/SharedUndatedNov09/native-fixture-r3/`.
Stable source/DD: `.build/Xcode27WarningReviewNov09/execution-r1/`.
Optional-night fixture products manifest:
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

## Shared source-removal regression

The additional reviewed test case now passes the entire real wire lane: 8 Node
cases and 15 exact Swift scenarios, zero failures/skips, in 132.90 seconds. The
original 7/12 remain required. Cancellation sends no command; a Codable-restored
retry commits removal once; another authorized planner reads the exact survivors
without basket or budget access. Protected lunch rejection, meal identities,
quantities, manual packs, quotes and immutable prior snapshots are checked.
Source hashes stayed unchanged, all scenario logs/hashes were verified, and the
owned PostgreSQL/private fixture state was stopped and removed.
[Compact proof](evidence/native/shared-meal-removal-wire-20261109/README.md).

This is not full shared F02: Cancel is a discarded native operation, not a UI tap;
manual input is twelve basket packs, not a typed twelve-wrap contribution. Shared
UI Apply/relaunch and manual/meal contribution merging remain separate acceptance.
No production changes, migration, deployment or full hosted batch in this patch.

## Remaining diagnostic work

- The compact native date control's Spanish-label problem was reproduced and
  inherited-locale forwarding did not resolve it. The successor renders a full
  locale-aware civil date and stages calendar changes in a separate sheet.
  Cancel/dismiss preserve the original day/deadline; confirming a changed day
  clears its former deadline. Full confirmation still goes through shop review.
  Earlier diagnostic evidence remains at
  [locale observation](evidence/native/shared-picker-locale-20261109/README.md).

  Current date-sheet source manifest:
  `eb4b6e7985938b990edff722328eddc2a36289b0a5c3826752f8d9a9d931e0bd`;
  products `c5b9d4500c3e377905c44d1d138a1d9ffd9cd4b7a73090d13d38dc090cc5d327`.
  Root executor/results: `.build/SharedMealDaySheetNov09/execution-r6/`.
  R6 Debug build/bundle verification pass. Earlier r4 build succeeded but copied
  validation initially lacked resource links. Its separate
  `build-debug/bundle-verification-r2/receipt.json` verifies the unchanged products
  after correcting those links; no recompilation. A mistaken r4 test selector was
  rejected by compiled-symbol preflight before native execution.

  Prior date attempts remain preserved: r1 exposed a too-short test dismissal
  gesture; r2 passed six of eight tests but AX5 fixture instrumentation left only
  123 points for the Form; r3 removed that clutter and exposed the real sheet
  disappearing after a valid tap. R4 moves presentation state outside lazy rows.
  All nine r4 affected journeys pass native/strict on one immutable build. Screenshot
  review then found Spanish AX5 month-header chevrons overlapping despite passing
  interaction tests. R5 uses native adjustable date wheels at accessibility sizes,
  preserving graphical calendars otherwise and all staged day/deadline assertions.
  R5's English AX5 and both default-language cases pass, but Spanish AX5 failed:
  its duplicate visible wheel label wrapped almost one character per line. Retained
  screenshot proves the cause. R6 hides only that duplicate visible label, retaining
  the localized accessibility label, full preview, title and original assertions.
  All four final r6 date-sheet journeys pass native/strict on the same unchanged
  source/products: English/Spanish at ordinary/AX5 sizes. All four saved screenshots
  were reviewed and are readable. All 562 source members match canonical.
  [Final scope and retained proof](evidence/native/shared-day-sheet-20261109/README.md).
  R4's complete nine-case result remains historical, not a full r6 regression claim.
  Prior source/products are verified under `.build/NativeQualificationArchivesNov09/`.
  Human localization/accessibility review and minimum-OS qualification remain open.

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
  is not an established cause. The standalone host control now qualifies: explicit
  Logging template, readiness in the 15-second budget, 5-second recording, two
  boundary events and three ordered matching positive intervals in the actual
  exported table. Helper, tracer and TOC export exit 0 without signals. Ten offline
  parser controls and independent root review pass; source/trace/export originals
  are unchanged. `.build/HostSignpostControlNov09/validation-r1/qualification.json`
  SHA256 `32d80b9156265983f6586de90e6125f57d1ebd1f920d3e8bde3c2b65c8dfa707`.
  Original `capture-r1/receipt.json` remains unmodified and unqualified; the later
  receipt supplies event verification. First compile failed because resolving the
  swiftc symlink invoked swift-frontend directly; preserved `compile-r2.json`
  records successful driver-path compilation. The simulator successor below now
  qualifies collection, without establishing an app or hosted metric repair.

- Standalone simulator control r3 now qualifies: readiness, exact owned helper
  events (two boundaries/three matching positive intervals), normal zero exits,
  no signals, 13 offline controls and independent root hash review. The r1
  supervisor falsely compared a launcher-script path with the actual process;
  r2 verifies both launcher and final executable but needed finalization cleanup.
  Those failures remain preserved. R3 changed only the local finalization allowance
  from 15 to 30 seconds and finished normally in 21.75 seconds overall.
  [Compact proof](evidence/native/simulator-collector-control-20261109/README.md).
  Authoritative receipt: `.build/SimulatorSignpostControlNov09/capture-r3-validation/qualification.json`,
  SHA256 `ed30721e3685682c2faf2bed055ec6a71173e140d3f80dab4c00193b86b995d6`.
  The successor app-process capture is implemented in scratch at
  `.build/AppSignpostCaptureNov09/implementation-r1/`: 45 offline controls pass;
  frozen 19-file manifest SHA256
  `e78670f3638a48140adb49e21597b59bee482aa11f5ccaaa25d2ab7de77730c3`.
  It uses a fresh historical Release source/build with app/runner handshakes outside
  the original measured block, exact owned process identities and bounded capture.
  Swift compilation, native protocol verification and independent metric checks
  remain. It is diagnostic only, not the current candidate or baseline acceptance.
  Root preparation is frozen at `.build/AppSignpostCaptureNov09/root-execution-r1/`.
  Source manifest `8bf01c2ee81c65e4f4ce8519cf512771ff52f0fbc224c84a13c87a72c06784e9`;
  preparation manifest `9b835afa8d70e5adf86c00f0c359079a6762b4aab1f733b2b398777e2f320037`.
  Root verified all seven preparation files and 561 source members. Read
  `CHECKLIST.md`; first phase is `root_execute.py settings --native-slot-released`
  with the exact interpreter in `tools.json`, only after prior native owners finish.
  Future DD is absent; no native capture/setup/build phase has run. The first
  file-only SDK-directory assumption failed and was corrected using bound SDK
  metadata without recopying source. Canonical/stable Debug source is untouched.
  Root owns the next native slot; no capture runs concurrently with the date tests.
  Do not repeat the helper unchanged or infer hosted metrics/baseline qualification.

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
