# Room in the Cart current handoff

Updated November 9, 2026 (local time). This file is the actionable checkpoint;
older chronology is preserved verbatim in [the November 8 archive](CURRENT-HANDOFF-HISTORY-20261108.md).
Historical running/blocked statements there do not describe current processes.

## Objective and authoritative checkout

Finish the complete first version: Foundation 2.1's 52 requirements, 27 screen
contracts and B11 acceptance. The goal is active and incomplete. Read
[APP-BASELINE](product/APP-BASELINE.md), then [CODEX-MASTER](product/foundation-gen2.1/CODEX-MASTER.md)
and [MASTER-GENERATION](product/MASTER-GENERATION.md). The requirement and route
maps remain in [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md#launch-requirement-traceability).

Use `/Users/palatis/Room in the Cart`, branch `codex/parallel-ios-ci`, with an
explicit working directory. The ambient `spanish-done-diagnostic` worktree is old.
The canonical app now contains the exact reviewed eight-file combined Dinner/audio
candidate. All 561 product inputs match the preserved R4 source identified below.
Combined-candidate publication target: `codex/combined-candidate-20261109`.
The earlier CI-only diagnostic branch remains pinned to its own tested revisions.
Draft PR 1 remains a separate integration candidate; no full batch was pushed
for this focused work. Recheck remote state before publishing.

## Current authorized improvements

User explicitly requested upgrading primary CI to Xcode 27.1, replacing the
initial additive-lane plan. Build/test jobs migrated to the official
xcode-27 preview image with the existing five-slot policy. Swift CodeQL is the
necessary narrow exception: GitHub documents Xcode 27 / Swift 6.4 traced scanning
as unsupported, so that required security job stays on macOS 15 / Xcode 26.3.
No local 26.3 installation is planned. Exact performance calibration remains a
release requirement; do not relabel the existing 26.3 baseline as 27.1 evidence.
Minimum deployment remains iOS 17, with minimum-OS native qualification local;
there is no existing hosted iOS 17 lane. Shared audio-session ownership/route
fencing is now installed byte-for-byte from the reviewed R4 candidate; physical
audio-route qualification remains open. No Dot/Lumpy. Helpers own CI migration and audio; root owns native
execution. The additive proposal/validation receipts are preserved in
`.build/Xcode27CompatibilityNov09` but are superseded by this migration plan.

## Latest active work — November 9

- Workflow follow-up separates device/runtime discovery into bounded30-second
  infrastructure commands; help/version remain10seconds, capability step3minutes.
  No app limits or acceptance gates changed. All366 offline checks and17 native
  queue-node checks pass. One capability-only hosted probe is pending; no full
  regression or baseline acceptance.
  [Change and evidence](evidence/native/ci-inventory-budget-20261109/README.md).

- Combined product consolidation is complete locally: exact8reviewed R4 files,
  all561product inputs equal the tested frozen source. Project/theme/localization
  checks pass; scoped native evidence is reused by byte equality, not rerun merely
  for installation. No full combined CI, PR/main merge or release acceptance.
  [Integration evidence](evidence/native/combined-candidate-integration-20261109/README.md).
- Selected-UUID inventory follow-up `e2bbdad0564c071e6bdf272bcce3bea7972f3485`
  is published;363offline tests pass and local CLI search smoke returns the exact
  owned device. Hosted42578578778 is terminal failure at unchanged10s inventory
  deadline: spawn0.740s, childrunning, no normal/late pipe bytes, stage10.352s.
  Runtime/help/build/transport/XCTest were not reached. Artifact/terminal collection
  complete once under `.build/Xcode27ScrollDiagnosticNov09/uuid-inventory-r1`.
  Narrowing results did not resolve the timeout; no automatic repeat or speed claim.
  Next decide a separate bounded inventory-readiness budget or a specifically
  supported service-readiness check; these censored timings do not calibrate a limit.
- Apple framework report draft is local only at
  `.build/MinimumOSXCTestReproducerNov09/apple-report-draft/REPORT-DRAFT.md`.
  It labels R3 non-reproducing and keeps raw messages private. Nothing submitted.

- Latest follow-up `259c42ba8d9db264c76e21a2f8ae9f71fd5de975` adds bounded
  process/pipe phase timings and discarded late-byte counts on deadline, with
  unchanged failure, cleanup, runtime and metric gates. Independent review clear;
  all361offline tests pass. Capability-only run42576978686 is terminal failure
  at the device inventory deadline. Spawn took1.419s; at10.237s from command entry
  the child was still running with no normal/late pipe bytes. Cleanup completed
  at10.980s; stage11.063s. No runtime/help/build/transport/XCTest was reached.
  Terminal/artifact collection is complete once; no duplicate dispatch/download.
  Evidence root `.build/Xcode27ScrollDiagnosticNov09/phase-timing-r1`.
  This rules out unread pipe output in that immediate observation, not a service
  or scheduling cause. Review a bounded next improvement before another run.
- Independent minimum-OS reduction R3 now passes native/strict on17.5:38.93s test,
 44.25s command, zero reported warnings,92query entrypoints/17actions/4gestures/
 8snapshots/4screenshots. Actual sibling controls restore311x22pt field geometry;
  the cached pre-typing attachment is retained. Root reviewed all4screens.
  Original callback crash is NOT reproduced or resolved; no full-app compatibility
  pass. Source/products/original unchanged, exports complete once. R3 source
  manifest594e352389c94b849818a3ce0a4a48d8555c0c01f0ee15d3811bf8883b0f1e38.
  [Bound execution and limitations](evidence/native/minimum-ios-reduction-20261109/README.md).
- One exact original-PID67330 historical17.5 log query for05:45:09–05:45:15UTC
  stopped at4MiBstdout cap in0.913s,exit143; no app rerun. Private raw prefix and
  receipt under `r3/execution/original-pid-retained-logs`, relative to
  `.build/MinimumOSXCTestReproducerNov09`. Prefix review is complete:2678complete
  objects spanning0.128840s, allDefault/com.apple.dt.xctest and exact crash-image
  XCTAutomationSupport;2579on the original faulting main thread. Counts are only
  retained-prefix lower bounds; its tail ends5.404440s before crash. No larger query
  or retry. Raw messages stay private. Original17.5MTC/RPAC UUIDs match actual17.5
  runtime libraries, despite an older path in the generated plan. No injection
  workaround justified. Upstream report preparation is local only, not submission.
  No native app execution or hosted monitoring remains active.

- Workflow improvements are published through `d2016380cbac0a49497c79806ea64431800394d6`
  on `codex/xcode27-ci-migration-20261109`. All **353 offline tests** pass;
  the unchanged workflow passes **17 native queue-node checks**. Commit219d2f66
  reuses a bounded, freshly verified same-job toolchain identity; invalid receipts
  fail closed, and live runtime checks remain. Commitd2016380 recognizes exit64
  only for exact log-help commands with expected usage/tokens and no collector error.
- Both new capability-only runs are terminal failures before compilation/XCTest.
  Run42573256459 at219d2f66 passed identity and runtime discovery, then exposed
  log-help stream exit64 (2116 stderr bytes). Local help-only checks confirmed
  valid usage exits64; equal hosted byte count alone does not establish equal text.
  Run42574682497 atd2016380 passed source and identity checks, then device discovery
  exceeded its unchanged10s collector budget (exit-15,10.459s,zero captured bytes).
  Runtimes/help were not reached: the help correction remains hosted-unqualified.
  No transport, products or native tests ran, and no baseline is approved.
  Originals retained once under `.build/Xcode27ScrollDiagnosticNov09/identity-reuse-r1/hosted-42573256459`
  and `help-exit-r1/hosted-42574682497`. Do not repeat downloads or unchanged runs.
  Earlier42570562637's duplicate-version failure is preserved under `preflight-r2`.
  Next add bounded collector phase timings and a nonblocking late-byte observation
  on timeout, keeping the failure/deadline unchanged. This can distinguish startup,
  scheduling and collection from readiness; zero captured bytes do not prove zero
  emitted output. Do not substitute pre-boot inventory for fresh post-boot state.
- Hosted diagnostic42566724355 at230f503a137290b626a193c612da6ef4ff5625bc
  is terminal. Attempt1 setup failed at pasteboard; one failed-job retry reused
  the build, passed setup, then failed capability preflight (no command identity).
  Neither attempt executed XCTest. Monitor receipts/artifacts retained once under
  `.build/Xcode27PrimaryMigrationNov09/hosted-42566724355`. The stage-receipt
  correction is now published and exercised above; no unchanged rerun. Previous42561415704 core is green;42561773341 performance
  retains missing launch/scroll metrics and passing rendered strict evidence.
- Combined product R4 is now integrated locally; preserved source manifest
  ea06e1901c7921deb33eb322d667053de2f47534c8273f7487413457540fd968 at
  `.build/DinnerAudioCombinedNov09R4`. Build/source checks pass. Original English
  journey passes native/strict (238.47s); all13images/10geometry receipts reviewed:
  stock quantity now wraps fully, all5Done probes retain input and dismiss keyboard.
 64audio regressions pass on both26.2 and17.0. Now integrated byte-for-byte; frozen originals preserved.
- R4 Spanish17.0 failed in the same XCTest logging callback/quarantine, now before
  the narrowed confirmation query, during Done geometry. Native65/strict1; inspector
  completed once; crash SHA dee6d11407b2e84191b57d55ebe8a59c0eb765e4e1657a60f5f58efee595eb54.
  Stop query-only reruns. R3/R4 originals and source/product preservations retained.
- Short native sequence35280 completed successfully:64audio both OS versions,
  original Free repair and original meal move, native/strict pass. All inspections
  completed once. Source/DD remain frozen. Spanish AX5 session25694 now passed
  native/strict,696.241s test /712.819s command; all13screens/10geometry reviewed.
  Stock-summary AX5 wrapping remains unsampled. Large text size restored.
  Unsigned Release session26401 is terminal native0/bundle0 in418.832s, same
  frozen source, separateDD. R4/qualification-checkpoint.json binds per-case receipts.
  Now integrated byte-for-byte; full qualification remains open.
- Official iOS17.5/21F79 installed and new owned SE3 device
  9DE280AC-A466-4FD4-8BDE-426C149D3F36 created. Original Spanish run session31974
  is terminal native65/strict1 (144.923s); inspector75326 completed once. Review
  confirms the same XCTest callback/quarantine fault family during ledger review
  lookup, not the confirmation query. Crash review manifest SHA256
  b5abefeebff7cd86789484cdce7a62db1d061a202ddbb8852e5e3cfdb3870e1c.
  Next diagnostic should be a bounded independent reproducer; no compatibility pass.
  Receipt root `.build/DinnerAudioCombinedNov09R4/spanish-ios17_5`.
  CUA completed; no pending GUI handoff. Free space20.5GiB after Release; reserve8GiB retained.

- Independent minimum-OS reduction is retained under `.build/MinimumOSXCTestReproducerNov09`.
  R1 built, failed its field reveal, then reached the600s outer driver deadline;
  its incomplete bundle was inspected once. R2 built in25.15s and returned native65
  in24.14s (strict1): amount typing lacked keyboard focus before either Done probe.
  The exported field frame includes the whole84.5pt row. This does not reproduce
  the original XCTest logging crash or qualify minimum OS. R2 reduced the actual
  multi-control ingredient row to one field. Original17.5 exposes a22pt amount
  child; the reduction exposes the84.5pt whole cell. Restore actual sibling-control
  structure for the next reduction, keeping center taps and original assertions.
  Custom deferred diagnostic attachments are absent from the failure export;
  the measured evidence here is the retained issue description and hierarchy.
  R2 uses `-collect-test-diagnostics never` only in this local reduction, keeping
  runtime logging/checkers enabled. Production workflows are unchanged. Both
  original result sets/source/products remain preserved; no re-export needed.
  No local native execution or hosted monitoring remains active at this checkpoint.
  Free space is approximately20GiB, above the8GiB native reserve.

- A test-only startup-readiness correction was committed at5157b785;
 327offline tests pass again. It separates a bounded fake-CLI startup handshake
  from the unchanged1second hang assertion, with a delayed-startup control.
  Production deadlines are unchanged. This fix is published with b29d9993; hosted230f503a is terminal.

Earlier checkpoint details below retain their own revision/scope; this latest
block supersedes their active-process and not-yet-pushed statements.

## Current execution

- Primary CI migration and first-class manual Dinner scope committed at
  `df49c37d6aa6e77cf4504890f3b2e840eea7b0e0`, published on the non-PR branch
  `codex/xcode27-ci-migration-20261109`. 286 Python checks, pinned workflow lint
  (17 native queue nodes), generation, localization and shell checks pass.
  First hosted run [42561415704](https://github.com/palatis3/room-in-the-cart/actions/runs/42561415704)
  is TERMINAL SUCCESS at that exact SHA with `ios_scope=dinner`: all11jobs,
  717 model tests, two original dinner UI journeys, release compilation, Swift
  CodeQL and strict diagnostic gate pass. This is focused qualification, not
  full release acceptance; no repeat is needed. Sol helper
  `xcode27_monitor` owns read-only status/log collection; do not duplicate dispatch.
  Performance collection run42561773341 is terminal on the same SHA (`case=all`,
  `enforce_baselines=false`): scroll and launch native tests passed but strict
  evidence validation failed; rendered passed strict validation with20persisted
  checkoffs and complete measurements. Scroll lacks the
  required stored signpost metric on27.1 too; launch lacks the expected metrics
  entry: metrics.json is empty and original SQLite stores zero metric rows.
  Scroll stores three memory series only; neither is a proved parser rename. Sol monitor owns status/single artifact reads;
  scroll_metric_next_step owns read-only diagnosis. Do not rerun or drop metrics.
  Draft PR1 remains atfe3e1430; do not imply the full integration branch is pushed.


- Hosted billing run [42544579944](https://github.com/palatis3/room-in-the-cart/actions/runs/42544579944)
  is **terminal success**, source `d1705d920595be12a3eb8c378f50ad04dbf65ccd`.
  All seven jobs pass, including both sanitizers and both 15-scenario locale
  suites with strict verification. The shared build and final gate pass.
  Logs and terminal inventory were collected once. Do not dispatch a duplicate.
  [Billing proof](evidence/native/membership-pending-reconciliation-20261108/README.md).
- Dinner R6 now passes BOTH original Spanish AX5 and English Large journeys:
  native0/strict0, zero runtime warnings/idle misses. Spanish command683.920s
  (test676.083s); English command230.930s (test223.560s). All five Done probes,
  heading, selected-food summary, native Edit names, approval and restart
  persistence pass. Both inspections completed once in sequence85919. Large
  restored. Helper reviewed all13 images and10 receipts per locale; root sampled
  keyboard/Edit frames. One separate English stock-summary ellipsis remains
  documented; no whole-screen or global accessibility acceptance is claimed.
- Combined Dinner+audio R2 compiled native0/bundle0 with the new implicit-capture
  warning corrected. Exact64 audio/capture/projection regressions pass native0 and
  strict0 on BOTH iOS26.2 and iOS17. Source manifest:
  `e8c0a6b3985eb2256f3fe40770567687e3ec156608fa4d32043c5924bde1b73a`.
  Every inspector completed once; originals/source/products are unchanged.
  An initial remaining-sequence attempt stopped BEFORE native start at the8GiB
  disk guard; preserved as remaining-sequence-disk-preflight.json. Space then
  recovered (latest about41GiB), and Spanish iOS17 resumed. It failed native65 /
  strict1 after142.51seconds: typing into ideaSupplyYield failed because neither
  the element nor a descendant had keyboard focus (native.log:1611). Cause is
  unclassified; no unchanged rerun. The inspector completed once, preserving
  original bundle/source. remaining-sequence.json now records this actual native
  failure and stops before the two affected Dinner cases and unsigned Release.
  Native is idle. Owned current858A was reset before storage recovered; boot it
  before its cases. Protected preview was untouched. Do not repeat cleanup.
  No canonical app candidate installation yet.
  Earlier Spanish scroll R2 is
  terminal native65/strict1: all five Done probes and approval passed, followed by
  a failure recovering the lazy root/library after relaunch. Large text restored.
  The isolated retained-state root-recovery R4 probe passes native/strict checks;
  it is nonhermetic diagnostic evidence, not the original journey's acceptance.
  [Evidence](evidence/native/dinner-scroll-progress-20261109/README.md).
- The isolated product correction `.build/DinnerAccessibleFieldsNov09` adds
  wrapping ingredient labels, persistent supply labels and a full body heading.
  Build and the complete original English journey pass native/strict checks with
  zero idle misses. Root/helper reviewed all 11 English Large screenshots and
  ten geometry/target records. This is not Spanish AX5 or global visual acceptance.
  Its source manifest SHA256 is
  `7f68068a87a58630d4875a48bd9bbf40a39d8a42594d55a57a3c94523d3e1e1c`.
  Source checks and the UI automation contract pass. No product candidate changes
  are installed in the canonical app yet.
- Reused source/DD remain at `.build/EnglishKeyboardReviewNov08/current-r1/execution-r1`.
  SOURCE is combined Dinner+audio R2 manifest
  `e8c0a6b3985eb2256f3fe40770567687e3ec156608fa4d32043c5924bde1b73a`. Dinner R6 manifest was
  `dc1b3def23b3f631aa613cc11ec7b1671335430143ea85063057dac323c19c9c`
  and is preserved under combinedR1/preservation/source.
  Each prior source/product pair is verified in the next candidate preservation directory. All three exact
  source validators pass; a read-only review found no regression/assertion waiver.
  [Product candidate proof](evidence/native/dinner-accessible-fields-20261109/README.md).
- Workflow improvements at1e632421 are published on
  `codex/ci-feedback-efficiency-20261108`;274Python/workflow checks pass. No full
  PR batch was triggered. [Workflow evidence](evidence/native/ci-feedback-efficiency-20261108/README.md).

## Installed Dinner repair and next action

Three files are installed locally: DinnerEditors.swift, DinnerIdeaSupplyViews.swift
and FreeJourneyUITests.swift. The reusable source/DD paths now hold the scratch test candidate above.
The 561-file manifest `.build/DinnerInlineTitleNov08/source.json` has SHA256
`1b4696e19ef030cb754148b23eb3bd9b65f0c3f9a617c2ad9b2e99e4fde7a0b5`.
This baseline matches the installed app/test bytes and includes the Membership fix;
it is distinct from the current scratch test manifest above.
The old `8d0eb48f` native pin is obsolete.

Focused Done has its own top-content row for dinner ideas and supply, a rectangular
minimum 44-point target and 8-point vertical padding. It clears focus without
changing values, saving or cancelling. The supply screen uses a native inline
localized title. Manual/reusable editing keeps its existing behavior.

Build and Debug bundle checks pass. The original English journey passes native
and strict checks with zero idle misses, all five symmetric coordinate samples,
unknown-quantity rejection, supply approval and relaunch persistence. All ten
screens and five geometry records are reviewed. All 261 Python checks (including 20 app-configuration tests)
and generated-project validation pass. [Evidence and rejected alternatives](evidence/native/dinner-top-done-20261108/README.md).
Earlier sibling-row/background-only candidates failed visual review; top-inset
failed the Review postcondition. Their source/products/results remain preserved.
All earlier inspectors and exports are complete; do not repeat them.

Next product work: after free disk exceeds8GiB, run the final combined source
for Spanish17 and the original Dinner cases
`testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop` and
`testDinnerMoveAcrossDisplayedWeeksKeepsLunchAndOccurrence` using prepared
run_affected.py/inspect_affected.py. Run unsigned Release via run_release.py after
native tests. Source/DD remain immutable while testing. No candidate installation
or deployment yet; full combined hosted coverage is still required.

Workflow follow-up: compact failure-first monitoring and the documented feedback
loop are validated by 276 Python checks, workflow lint and live read-only billing
reporting. Shared archives already avoid recompression; no further shard changes
are justified until the next comparable full batch is measured.

## Other open failures and workflow

- N03 route handling: complete shared ownership proposal is frozen at
  `.build/ReleaseGapCurrentNov09/audio-owner-proposal-r3`. Patch SHA
  `8826b751d599c58f9e7832dd0918e0b5419f524b825055afc045beb55cae5460`, manifest
  `d99d2c6168ba7cd3b5e1161511614839c13e0db2047babc857c166b668ac0c6f`.
  Four existing Swift files, no project addition. Independent review resolved
  playback option normalization and two unsupported legacy capture arguments;
  no remaining source blocker. Original16 readback tests are byte-identical.
  Exact regression selection is64:35 readback,14 capture,15 cook projection.
  Combined R1 compiled, R2 is qualifying the one-line warning correction; neither
  is installed canonically. Before any future overlay, verify those
  four base hashes before overlaying into owned SOURCE/DD, preserve prior products,
  and freeze a NEW combined manifest (proposal49a546 describes canonical-only
  overlay, not Dinner). Compile first, then exact64 strict tests. Physical route,
  Pause/Resume and VoiceOver remain separate; this does not solve the existing
  framework QoS warning. Earlier r1/r2 partial proposals remain rejected history.

- Scroll performance: original metric cardinality4→3 failure; missing producer
  is unproven. Read-only SQLite inspection now confirms zero archived metric rows,
  not merely an empty JSON export. [Unsubmitted addendum](evidence/native/apple-scroll-feedback-20261106/FOLLOWUP-NOV08.md).
  `.build/ScrollMetricReviewNov08/README.md` is a conditional proposal,
  not permission to run interposition without review. Do not drop required metrics.
- Cook readback: standalone render-only generation reproduced framework-main
  waits before playback. That direction is rejected; no cap increase/player
  implementation is justified. One XCTest warning still lacks its required
  attachment. [Proof](evidence/native/cook-render-only-20261108/README.md).
- Broader accessibility findings, physical interaction and full combined CI remain
  open; the dinner samples are not exhaustive hit-region or accessibility proof.
- CI changes: independent contributor/dinner build dependencies; one shared billing
  compilation; focused diagnostics; five global slots; strict aggregate gates.
  [Working loop](CI-VALIDATION.md), [validation](evidence/native/ci-bottleneck-update-20261108/README.md).
  Use one coordinator, one owner per root cause, cheap checks first, exact-run
  monitoring and one full regression batch for combined qualified fixes. Collect
  artifacts once. Keep full release coverage and privacy restrictions intact.

## Environment, ownership and remaining release gates

Owned current simulator: `858A2244-001F-4BAD-AFE0-A6E7AF02F41A`, iOS26.2/23C54.
Owned minimum-OS simulator: `D420C2CA-0E73-4213-9B96-1EB62EB061F6`, iOS17.0.
Protected preview: `5FDE1E82-1FF7-4556-9C14-0746F6295944`; never reset or use it
for fixtures. Recheck owned devices before use. Local Xcode27.1 CLI27A9275;
hosted primary CI now qualifies27.1/27A9275 on iOS27.0; only Swift CodeQL remains
on26.3. Local current runtime is still26.2. Keep8GiB disk reserve and preserve
original evidence; latest observed free space about41GiB. No additional SDK is needed.
Do not repurpose existing PostgreSQL port55432 or delete unowned resources.

Do not use Dot/Lumpy. Astra High helpers are authorized; Sol6.1 Extra High can
handle simpler delegated work. Root owns integration and hosted operations.
Operator: Venture House Group LLC; public support: hello@roominthecart.com.
Apple paid team/signing/StoreKit/TestFlight/AppStore and SMTP remain owner-deferred;
do not repeatedly ask. Epic terms accepted; real KWS activation is still separate.
Encrypted backup location and login-Keychain custody remain as authorized. Last
verified staging approval/state covers041;042 is separate. No deployment occurred
in this work. Check exact current state and approval scope before a future rollout.

Full [production/release gates](CURRENT-ACCEPTANCE.md#remaining-production-work-and-release-gates)
remain: provider verification and erasure, independent recovery/alerts, policies
and support operations, live mixed-phone household flows, human US-Spanish,
physical camera/audio/share/widgets/printing/reminders and VoiceOver/Switch Control,
signed distribution and complete route/App Store acceptance. Simulator and
synthetic-provider passes do not establish those gates.

## User-requested remaining-bottleneck research

Astra's completed read-only audit is `.build/MergeBottleneckAuditNov09/README.md`.
It distinguishes merge requirements from release/B11 and confirms: known exact
performance-profile mismatch should fail before native build;49 commits await PR
integration; most diff volume is retained evidence; historical JS CodeQL extracted
archived evidence sources (current cost unmeasured); five-slot utilization already
91.22%. No blanket security exclusions or history/evidence deletion approved by
this audit. Root requested a bounded early performance guard as the next local
workflow improvement; current hosted df49 branch stays immutable while runs finish.

Early performance environment rejection is implemented and committed locally at
`9f4dfa227403498734109572743fc7dbfba8ef2d` after294 offline tests and17-slot workflow
validation. Calibration still validates identity, skipping only baseline matching.
Old baseline JSON and late exact metric gates remain unchanged. This follow-up has
NOT been pushed; active hosted branch remains immutable atdf49. Receipts and final
patch are `.build/PerformanceEnvironmentPreflightNov09/*-r2.*`.

Published research checkpoint: docs/evidence/native/ci-merge-bottleneck-audit-20261109/README.md. Remaining performance diagnosis: .build/Xcode27ScrollMetricReviewNov09/README.md. No new diagnostic has been dispatched.

## November 9 workflow implementation and next native candidate

The user authorized implementing the audit recommendations and confirmed storage
was freed. Latest observed reserve is about40GiB. `RELEASE-EXECUTION.md` now orders
the remaining merge, staged integration and B11 requirements with direct evidence
and owner-deferred setup kept explicit. Workflow helper owns a bounded exact-SHA
receipt checker and CI-VALIDATION changes; performance helper owns an isolated
capture proposal. Neither owns hosted dispatch or native execution.

Combined R2 Spanish17 failure is retained. Read-only review identifies a probable
labeled-row focus hit gap; the original tap coordinate was not captured, so this
is an inference. R3 adds only a whole supply-row content shape/tap that assigns the
existing native field focus binding. Original tests, assertions and time limits
are unchanged. R2 source/products are preserved before rebuilding.

R3 root: `.build/DinnerAudioCombinedNov09R3`; source manifest SHA256
`a23fd98d2fe0068e4d96172605a0ca7fa2a1d082e11086f68b1079537c342a71`.
Build/bundle checks pass (44.196s); project generation, localization and automation
source checks pass. Initial attempts to run absent scripts in the sparse isolated
source failed before checks; corrected canonical validators explicitly target
the isolated source, with both attempts retained. The original Spanish17 test
is terminal native65/strict1. All5Done probes complete, then app PID57226 crashes
in runtime_issue_os_log_fault_callback while XCTest queries ideaSupplyConfirm.
The captured stack includes logging-volume quarantine and XCElementSnapshot
label/identifier access. Native194.757s; original inspector completed once in
session48923 with original/source unchanged. Preserved crash SHA256:
0d76f40928e9b46a088526352fc113ce8360fc1c5897b72717a45a2eff077583.
Astra release-gap helper owns read-only cause review; no unchanged native retry.
Source/products remain frozen pending that review. Separate one-line stock-summary
wrapping proposal exists, not applied. Hosted performance is terminal; rendered
strict evidence passed, launch/scroll remain incomplete. No hosted jobs active
in this owned cohort and no new dispatch.
