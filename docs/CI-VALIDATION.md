# Local CI validation

## Consumer boot overlaps artifact transfer — November 12

In the `94d7aece` [core run](https://github.com/palatis3/room-in-the-cart/actions/runs/43347398002),
UI10 downloaded the 66.5 MB test artifact in 305 seconds, then spent another
49 seconds booting its simulator. UI09 spent 111 seconds downloading and
35 seconds booting. These were the last two native groups to finish. The logs
show successful downloads, not retries; the network delay's cause is unverified.

Core and fixture consumers now select their original simulator and start the
existing checked boot command before artifact download. They collect its saved
exit status after restoration, before any XCTest execution. Failed downloads
still fail the job; boot failures, including CoreSimulator's zero-exit migration
failure, still prevent testing. The eight-minute boot wait, test selections,
runner assignments and XCTest limits are preserved. A failed or missing boot
receipt cannot count as readiness. Ordinary result artifacts retain the boot log.

This overlaps startup with transfer rather than changing the download or adding
workers. The 49/35 seconds are overlap opportunities from that sample, not
measured savings. Compare consumer start-to-test time and the last required gate
on the next combined run. A local cold iOS 27.0/24A434 simulator returned from start in 0.005 seconds,
allowed independent archive creation to finish at 0.129 seconds and confirmed
boot at 25.474 seconds. This verifies overlap, not hosted transfer performance.
All 1,000 offline CI checks and workflow validation passed. Local evidence is
recorded in `.build/ConsumerBootNov12`. The subsequent calendar-dismissal
correction passed both original English and Spanish journeys under
`.build/FoodCalendar94dNov12/local`; include both changes in the next combined
regression instead of launching a separate full repeat for startup alone.

The combined `ccdad858` run exercised the overlap successfully. The first fixture
consumer started boot at 03:11:45 UTC, finished download/restoration at 03:11:53
and confirmed boot at 03:12:22: eight seconds of concurrent setup, not a measured
eight-second reduction in the entire run. All 26 fixture groups passed. Retain
the timings in `.build/FrozenCcdad858Nov12/first-consumer-boot.json`.

## Latest bottleneck review — November 12

The `ccdad858` batch took 56m45s. Its last job, UI05, spent about 600 seconds in
animation-idle waits after repeated keyboard dismissals in the saved-offer
reminder journey. The adjacent-field entry correction passed the original case
locally in 112.417 seconds with no runtime warnings, animation-idle messages or
runner restarts. It uses the ordinary Debug app, separately from household
fixture products, and retains every field value, saved-decision and reminder
assertion. The hosted gain is still unmeasured. UI05 finished 3m54s after UI09, so
removing its ten-minute stall could save at most 3m54s for this particular batch
with all other timings held constant; this is an estimate pending qualification.

The web failure was a Chrome startup timeout before the first browser assertion.
The targeted rerun passed in 46 seconds. GitHub assigned new job IDs to reused
results, but preserved the original timestamps for all 17 other jobs. Compare
timestamps when auditing reruns; new IDs alone do not establish repeated work.

Four fixture restore steps took 127–289 seconds against a one-second median.
Their cause is not established. Inspect existing restore/boot evidence before
changing compression or runner assignments. Median result upload was three
seconds, so another artifact redesign is not justified by this run. Timing
evidence: `.build/FrozenCcdad858Nov12/efficiency-review/timing-receipt.json`.
The restore steps now log elapsed time for the complete decode/extract pipeline
and for selection placement (including manifest validation in fixture jobs).
This uses the existing steps and will run with the next combined candidate.
Twenty-six existing workflow checks, shell syntax and actionlint passed.

The isolated M4 scroll qualification also lacked the required duration metric,
despite successful native execution and verified 500-row persistence. Stop
repeating the hardware hypothesis. Preserve its failed qualification and require
new evidence before another performance experiment; do not weaken metric gates
or replace approved baselines. Evidence: `.build/M4ScrollQualificationNov12/result`.

## Current development priority — November 12

The user has asked to stop overengineering and prioritize completing the app.
This policy takes precedence over routine repetition described below; existing
release requirements and known failures remain visible.

- Keep the first-release scope stable. Prioritize confirmed product defects,
  incomplete acceptance requirements and failures that block the combined
  candidate. Defer optional visual polish, new diagnostic tooling and speculative
  coverage unless they resolve one of those items. Do not start a side project
  simply because a hosted job is still running.
- Finish the current correction before opening another investigation for the
  same cause. Once its affected check passes, retain that result and move to the
  next unresolved item; do not expand validation without a changed dependency,
  new failure or the planned combined integration gate.
- During implementation, build the affected target and run the smallest relevant
  existing tests. Add regression coverage for a real defect or critical new
  behavior, not every reversible edit or hypothetical edge case.
- Select the app entry point before a native build: ordinary Shop journeys use
  the normal Debug app; dedicated household fixtures replace `@main`. Group tests
  by compatible build profile and reuse each completed build within that group.
- When the test opens the Share extension from a different app, install the
  containing app on the selected simulator before opening the share sheet.
  Verify the installed extension implementation matches the build. In Debug,
  compare the extension's debug dylib as well as the launcher. Starting an
  external host alone can leave an older installed extension in use.
- Keep separate local DerivedData directories for normal, StoreKit and fixture profiles.
  Switching `SWIFT_ACTIVE_COMPILATION_CONDITIONS` in the same directory invalidates
  dependency builds as well as the app. Use `.build/NativeNormal/dd` for the next
  normal build and `.build/NativeStoreKit/dd` for the next needed StoreKit build;
  retain `.build/TrackingFlowUIQualificationNov10/r1/dd` for the
  current contributor/stock/carryover profile. Other fixture flags need their own
  cache when used. StoreKit also enables coverage flags that the ordinary scheme
  does not, so sharing their cache forces recompilation even with identical source.
  Do not copy cached products between profiles or start an extra
  build just to populate a cache. Continue to serialize native execution. This
  changes local reuse only; hosted coverage and result retention stay unchanged.
- Before a native session, inspect booted simulators and active test/debugger
  processes. Shut down unused Room in the Cart diagnostic devices once ownership
  is clear; preserve their data and leave the active test device alone. Do not
  use a global shutdown or delete devices. Old minimum-iOS simulators were found
  consuming CPU in the background on November 10. This cleanup reduces avoidable
  host contention; it does not prove or fix XCTest animation-idle faults.
- For a focused local simulator build, select that simulator's destination instead
  of a generic destination that also compiles unused architectures. Keep hosted
  and release architecture coverage unchanged.
- Match the pinned Xcode build and the applicable simulator runtime/build locally.
  This Mac already runs macOS27.2/26B123; the November11 hosted image reports
  macOS27.0.1/26A434. They are not identical machines, so retain environment facts
  with failures. Do not change host OS versions merely to chase an unexplained
  test failure; there is no demonstrated benefit from doing so here.
- Keep cheap service/model checks. Avoid repeating native UI, database, wire and
  hosted suites for unrelated or test-only edits. Test a corrected fixture with
  its affected suite before scheduling a broader batch.
- Swift package checks retain the reviewed inventory as a required minimum.
  Newly discovered tests join automatically and must execute and pass; missing
  required tests, missing outcomes and unapproved skips still fail the job.
- For focused local form/selector checks, use `-collect-test-diagnostics never`
  and retain the test log, screenshots and result bundle. Use `on-failure` when
  investigating an unexplained crash, hang or simulator fault. Once the first
  failure has actionable crash evidence, use `never` for the focused correction
  check unless new system diagnostics are needed. The November11 shared-meal
  removal fault was captured in app stdout with `never`; a later visibility
  assertion under `on-failure` launched a600-second simulator diagnostic command
  after the45-second test body. Preserve both originals instead of collecting
  that same system evidence again. Routine assertion failures
  should not trigger a ten-minute simulator diagnostic collection. Hosted CI
  keeps its existing failure diagnostics.
- For a UI timeout, find the first long wait in the test's activity log and
  inspect its screenshot. In the November 12 checkout and recipe cases, the
  first minute-long wait followed a keyboard dismissal between adjacent fields.
  Enter related visible fields together and verify the values and saved result.
  When checking that a sheet closed, query its identified toolbar button and
  verify the underlying screen. Keep its existing deadline and assertions.
  When the failure snapshot already contains the intended control, use its
  recorded accessibility type and identifier in the affected query. The
  November 12 pickup, request and delivery logs show that a search across
  all descendants timed out while the button or text row was on screen.
  Rerun the original user journey and retain its saved-state assertions.
  In the shared delivery tests, check whether a control already exists before
  starting the three-second existence wait. On the same iOS 27.0 simulator,
  the freezer correction journey started 63 polling waits before this change
  and four afterward. It passed in 142.92s and 83.17s respectively. The
  remaining waits, scrolling and quantity checks still run when needed.
- Batch related fixes before one integration run. Run broad regression on the
  combined merge candidate and applicable release checks before distribution;
  do not require that full batch for every intermediate commit.
- Stop optional performance-observer and simulator-infrastructure experiments
  during feature completion. Revisit a diagnostic only when it blocks the next
  agreed milestone and has a concrete new hypothesis. Deferred checks are not
  passing checks.
- Reuse existing test commands, logs and result bundles. Do not create another
  bespoke qualification wrapper, receipt schema, source-copy pipeline or evidence
  document for an ordinary edit. A concise revision, command, result and known
  limitation are sufficient. Preserve existing failure artifacts and keep
  credentials and private fixtures out of committed evidence.

## When to run hosted checks

### Local simulator capacity

On the 24 GB development Mac, let a failing PR journey take the next free simulator slot. During the November 12 run, several simultaneous simulator sessions coincided with memory pressure warnings, 17 GB of swap use and a current-runtime calibration that spent minutes in XCTest startup. When that happens, run the optional calibration after a repair finishes. Backend checks and hosted jobs can continue.

### GitHub and Bitrise capacity

The reviewed capacity is five GitHub jobs, three M2 Pro Bitrise jobs and six
M4 Large Bitrise jobs: up to **14 simultaneous native jobs** when work is ready.
The existing M2 pool is `bitrise-runner-room in cart`; the new M4 pool is
`bitrise-runner-ci 2`. Its space is part of the exact label. Safari inspection
verified both pools connect to `palatis3/room-in-the-cart`, with the M4 pool on
`osx-tahoe-27`, six machines at 5 vCPU/14 GB each and GitHub Actions caching enabled.
The workspace has 36 M2 Pro vCPUs and 30 M4 vCPUs. The unused `tessss` and
`more ci` pools share that same M4 allowance: they do not add capacity on top
of the six smaller machines. Configuration evidence and its qualification limit
are recorded in `.build/BitriseM4Nov11/capacity-review.json`.

The native queues stay independent: `ritc-macos-slot-0..4`,
`ritc-bitrise-slot-0..2` and `ritc-bitrise-m4-slot-0..5`. The main app/model
producer uses the larger M2 slot 2 with its original GitHub 3 fallback. Both
fixture producers remain on M2 slots 0/1, and UI05 remains on M2 slot 0.
The native Swift HTTPS/PostgreSQL job uses GitHub slot 3. On `a5607f91`, it occupied slot 4 for 6m38s, overlapping the first 6m05s after source checks passed. Swift CodeQL also needed slot 4 and finished last after 49 minutes of work. The first slot 3 fixture started 43s before the wire job finished. On `9e9b42cc`, CodeQL started four seconds after the wire job finished, while the first slot 3 fixture overlapped only its final 1m17s. Compare the interval from source-check completion to CodeQL start, and the time to the last required result, on the next full PR run. [Completed core run](https://github.com/palatis3/room-in-the-cart/actions/runs/43275490695) · [Native wire run](https://github.com/palatis3/room-in-the-cart/actions/runs/43275488957) · [Fixture timings](https://github.com/palatis3/room-in-the-cart/actions/runs/43275488968).

The following jobs share the six M4 slots.

| Job or group | M4 slot | Original GitHub fallback |
| --- | --- | --- |
| Full core UI01 and UI03 | 0 | 1 and 3 |
| Unsigned Release, core UI06, Spanish expired quote and contributor balanced-04 | 1 | 1, 1, 4 and 0 |
| Contributor balanced-03, core UI07 and core UI10 | 2 | 4, 2 and 0 |
| Delivery recovery/cook/closeout, core UI04 and core UI08 | 3 | 1, 1 and 3 |
| Core UI02, English expired quote, filled financial fields and Spanish skipped-dinner Undo | 4 | 2, 3, 4 and 2 |
| Core UI09, stale quote save and contributor balanced-05 | 5 | 3, 0 and 2 |

The English expired-quote editor journey took 13m00s and 17m59s in its last two successful GitHub jobs. Its Spanish counterpart took 7m16s and 5m50s on Bitrise M4. M4 slot 4 finished its final job at least 27 minutes before the core gate in both batches. The English journey now uses that slot on trusted runs, freeing GitHub slot 3 for the wire test and Records fixture. Its selectors, assertions and GitHub fallback are unchanged. Compare the next English run's elapsed time and the other slot 4 jobs to measure the effect. [English GitHub job](https://github.com/palatis3/room-in-the-cart/actions/runs/43275488968/job/131386240228) · [Spanish M4 job](https://github.com/palatis3/room-in-the-cart/actions/runs/43275488968/job/131386240529).

UI01 finished last in two consecutive full builds. It waited 21m25s after the producer on `3977750b` and 26m09s on `099d6bf6`. M4 slot 0 took its first UI group after 51s and 53s on those builds. Full UI01 now shares slot 0 with UI03. UI10 moves to slot 2, whose last job finished 28m58s before UI01 in the latest run. The manual two-test Dinner dispatch continues on GitHub. Measure the next full build from producer completion to UI01 start and from workflow creation to the last required gate. The prior complete batches took 58m19s and 67m04s. [Previous UI01](https://github.com/palatis3/room-in-the-cart/actions/runs/43246467096/job/131285759950) · [Latest UI01](https://github.com/palatis3/room-in-the-cart/actions/runs/43259414250/job/131330863485)

On `cd85377c`, the bilingual StoreKit job waited 38m22s for GitHub slot 2 after the build finished. The Spanish skipped-dinner Undo journey occupied that slot for the last 15m37s of the wait. On trusted builds its existing selector now uses M4 slot 4. Compare the StoreKit start, the M4 job duration and the last required check when judging subsequent runs.

On `a807ecf9`, the moved journey waited 5m22s and ran in 5m36s on M4. The previous GitHub job waited 24m23s and ran in 15m37s. That reduced the time from queuing this job to its result by 29m02s. The bilingual StoreKit job passed after queueing for 20m42s and running for 19m08s. Previously it queued for 38m22s and ran for 26m50s. The deep-checks workflow passed all six jobs. Core and fixture jobs were still active at that point. [M4 job](https://github.com/palatis3/room-in-the-cart/actions/runs/43231482950/job/131230416661) · [StoreKit job](https://github.com/palatis3/room-in-the-cart/actions/runs/43231482917/job/131230870466).

The five workflows on `a807ecf9` finished in 1h16m30s, compared with 1h11m52s on `cd85377c`. Core UI08 was the last native group. It queued for 26m02s on GitHub, then its native step reached the 40-minute limit. In the preceding two batches this group had waited 26m48s and 32m03s. On each of those three batches M4 slot 3 finished its last assigned job before UI08 started on GitHub. The next combined build assigns UI08 to this M4 slot on trusted runs. Check the time to the last required result and the UI04 and UI08 results together on the next build. [UI08 job](https://github.com/palatis3/room-in-the-cart/actions/runs/43231483028/job/131231569606) · [UI04 job](https://github.com/palatis3/room-in-the-cart/actions/runs/43231483028/job/131231569792).

In the November 12 combined run, the final M4 test finished at 06:32 UTC.
UI04, UI07 and UI10 were still waiting for GitHub workers at 06:46 UTC.
The revised routing lets those three groups reuse M4 slots. Queue order and
the final elapsed-time change depend on the hosted run.

On `3390ad19`, the last M4 job finished at 10:04 UTC. The Spanish expired-quote
fixture started at 10:19. At 10:20 the filled financial fields and stale quote
save fixtures were still waiting on GitHub. On `37c34724`, all three started
within one second of one another on separate M4 machines and passed. The total
job times for expired quote, filled financial fields and stale save were 5m34s,
4m05s and 6m14s respectively. Their preceding GitHub jobs took 15m05s, 12m36s
and 16m36s. These times cover each job individually. The full batch also
depends on other suites. [GitHub fixture run](https://github.com/palatis3/room-in-the-cart/actions/runs/43191347210) · [M4 fixture run](https://github.com/palatis3/room-in-the-cart/actions/runs/43203604221)

Each consumer keeps its original `macos_slot` for GitHub fallback and adds a
separate `m4_slot` only when assigned to M4. Canonical trusted events select
the exact pool label and queue; external forks, other repositories and unsupported
events remain on GitHub. The complete source/compiled inventories, row ordering,
selectors, model-result gate, artifacts, timeouts and toolchain/runtime checks
remain unchanged. CodeQL keeps its existing supported GitHub toolchain.
Keep GitHub's external-contributor approval controls enabled; workflow expressions
alone are not a security boundary against changes in an untrusted PR.

On `37c34724`, all 14 native runners overlapped at 10:56:43 UTC.
The last M4 job finished at 11:26:56 UTC, and core UI05 started on M2
at 11:39:58 UTC. Two passing contributor groups had used the M2 queues for
17m26s (balanced-04) and 22m48s (balanced-05). Routing those groups to M4
slots 1 and 5 frees their former M2 slots for jobs such as UI05 and the
Spanish created-dinner Undo check. Measure the effect on the next combined run.
[Core jobs](https://github.com/palatis3/room-in-the-cart/actions/runs/43203604405) · [Fixture jobs](https://github.com/palatis3/room-in-the-cart/actions/runs/43203604221)

The two M2 fixture producers, main producer and M4 unsigned Release producer
activate Xcode compilation caching before their build in a separate step.
The CLI is pinned to 3.19.5 and its official archive SHA256; Build Hub supplies
workspace authentication without a repository token. Cache activation is optional
for build correctness and warns on failure; required compilation and test outcomes
still decide the gate. Consumers restore exact products and execute their selected
tests without recompiling. Cache activation there would add no compile work to reuse.

On640c0aef, the two fixture build invocations report Healthy remote cache and
280/293 task hits (95.56%): Dinner 24.850 seconds and contributor 28.153 seconds.
Their later test-enumeration invocations correctly report no cache activity;
do not mistake the job's last cache notice for the compilation report. Verified
original-log hashes and invocation identities are retained in
`.build/CombinedCandidate4cad300cNov11/cache-verification.json`. These are fixture
compilation measurements, not projected main-producer or whole-batch timings.

The owner activated trials on November11. Build Hub displayed an end date of
November25; the completed Build Cache wizard confirms November11–December11.
These are separate subscriptions. Review continued capacity before expiry. Toolchain/runtime guards
remain pinned; a different provider image must not silently upgrade them.

The isolated November11 pilot on beb02a1e built the same contributor profile in
144.5seconds cold and23.7seconds warm according to Bitrise invocation timing.
The cold build uploaded504.5MB; the warm build downloaded504.5MB and reported
Healthy reuse. Both builds, compiled discovery and product uploads passed. This
is one measured pair for compilation, not an84% whole-CI speedup. The Bitrise
consumer and full focused gate43064729384 pass: original Spanish quote journey
strict1/1 in81.713s, zero runtime warnings/idle messages/restarts. The GitHub consumer130681559128 and full focused gate43065528907 also pass: original financial-fields journey strict1/1 in237.759s, zero runtime warnings/idle messages/restarts. Both providers consume the Bitrise-produced products successfully on this exactbeb02a1e pilot. The next combined candidate remains separate qualification.

Keep ordinary edits local while running their affected checks. Publish grouped
changes to the candidate PR when ready for combined integration; its core and
fixture workflows still run complete coverage. Do not push status-only edits
while a useful candidate batch is running.

The large core and contributor matrices use their assigned global native-job
slot queues as their execution cap, without a second matrix `max-parallel` window.
On November 11 the five admitted contributor rows included three waiting on busy
slots3/4 and only two executing on slots0/3, while core UI09 occupied slot4.
The next quote rows for available slots1/2 had not been admitted. Removing that
redundant window let all rows reach their existing slot queues without changing
the then-five-job cap, coverage or cancellation policy. The Bitrise addition
above supplies separately capped M2 and M4 native slots.
Confirm utilization on the next combined run; no speedup is claimed from local
workflow validation alone. GitHub documents the separate
[matrix limit](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/run-job-variations#defining-the-maximum-number-of-concurrent-jobs)
and [concurrency queues](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

The14b75714 batch subsequently admitted all11core and25contributor rows to those
queues, with five native jobs executing. Admission behavior is now verified;
an elapsed-time or overall-utilization improvement has not yet been measured.

The next grouped candidate removes two repeated simulator setups. Core models
run on the existing build producer after enumeration and product upload; the
consumer matrix retains all ten UI rows and their original slots. The complete
compiled plan and model selectors remain unchanged. A failed model step allows
UI consumers to proceed, but the required CI gate checks its raw outcome and
rejects failed, skipped, cancelled or missing model results. The producer's outer
cap is75minutes, replacing separate35-minute build and55-minute model jobs; the
model step keeps its40-minute limit. UI admission now waits for this model step,
and producer infrastructure failure can block the UI consumers. Hosted elapsed
time remains to be measured.

Shard estimates use12 fresh timings from strict-passingaf3338 UI02/UI03 artifacts,
with provenance retained in `scripts/ios_test_durations.json`. Replanning preserves
the exact compiled selector inventory; estimates only rebalance work and do not
change execution deadlines or performance acceptance baselines.

The deep workflow automatically runs for billing/household integration, shared
Swift packages and their build/test inputs. Unrelated UI-test or diagnostic-script
edits no longer start StoreKit and both sanitizers. Use its existing manual action
when a change outside those paths warrants investigation. The full release
workflow always invokes deep checks regardless of changed paths.
GitHub compares the whole PR diff, so a large PR that already changes billing or
packages will still select deep checks on later pushes. These filters primarily
save work on subsequent, smaller PRs; do not restart a useful batch for them.

PR StoreKit regression uses the qualified iPhone17/iOS26.2 build23C54 compatibility
environment with Xcode27.1 build27A9275. Both original15-case locale suites passed
strict local verification with unchanged source, products and deadlines in
`.build/StoreKitFullCompatibilityNov11/{en-booted,es}`. The initial English attempt
executed zero tests because simulator app-preflight was busy; it remains retained
under `en`. The existing explicit boot helper completed before the passing run.
This is an explicit merge-stage compatibility baseline, not current-OS billing
qualification or proof of an SDK root cause. The af3338 hosted suites each execute
all15cases and pass14; English approval ordering and Spanish observer delivery
remain failed. CURRENT-HANDOFF records their evidence and scoped next actions.

The shared StoreKit producer still builds once against the27.0 destination with
SDK27.1 and the iOS17 deployment target; its inventory records SDK/toolchain identity.
The next candidate runs English then Spanish in one consumer, restoring products
and preparing the exact runtime once. Each locale retains a distinct result
bundle, artifact, exact-configuration check and all15 selectors. Spanish remains
eligible after an English native/export/verification failure; a required six-outcome
gate rejects any incomplete or unsuccessful locale phase. Shared runner/device
failure can still affect both locales. The outer job cap becomes90minutes in
place of two45-minute jobs; each native step keeps35minutes and each case120seconds.
The local sequential rehearsal passes strict15/15 in each configuration on26.2/23C54
in `.build/StoreKitSharedSetupNov11/{en,es}`, with zero recorded runtime warnings,
idle notices or restarts and matching source/product hashes at completion. Its
first enumeration reported Busy before running tests and remains retained; the
existing explicit boot helper preceded the successful discovery. This qualifies
the successful shared sequence, not hosted throughput, failure recovery or current-OS billing.

The compatibility consumer installs exactly23C54 using Apple's bounded
`xcodebuild -downloadPlatform iOS -buildVersion 23C54 -architectureVariant arm64`
command when missing, then validates installed runtime/build and the actual result
device/runtime/build. It creates only its job-local iPhone17 if needed. Missing,
unavailable or mismatched runtimes fail setup without fallback. The command resolves
locally. Both af3338 hosted consumers installed/validated23C54 and their result
identities match. English runtime preparation took approximately3m28s; its cold
simulator boot took6m53s. These setup observations do not establish suite success.

Manual and reusable deep-workflow calls default `require_current_storekit` to true;
release-checks explicitly passes true and requires both full locale suites on
iOS27.0 build24A434. That input wins even when a reusable caller originates from a
PR. All15selectors per locale, strict result checks,120-second execution allowances
and aggregate gates remain required. Main app/UI jobs remain on27.0. The retained
current-OS failures still block release, alongside signed-device/sandbox acceptance;
PR compatibility success cannot clear them. Do not submit the owner-held Apple
report or repeat unchanged runtime diagnostics as part of this policy.

Performance runs through the existing manual action or full release workflow,
not on every PR update. Manual calibration is not release acceptance. The release
workflow still requires approved baselines, complete measurements and the same
frozen source; the current missing baseline remains an open release requirement.

For a suspected framework problem, test one concrete hypothesis with the smallest
relevant original case. If it fails to explain the behavior, preserve the result
and stop repeating it. Resume only for new evidence or a required release decision.
Native execution allowances, assertions, required core checks and release
requirements remain enforced. The combined job budgets are documented above.

The November 11 candidate's UI05 and SharedFallback jobs both crashed in XCTest
bootstrap before any selected case started. The next candidate gives just these
two jobs the existing job-owned simulator setup used by UI01 and
contributor-balanced-01. Both pilots completed their selected cases and deleted
only their owned device. The change tests whether fresh device state avoids the
startup failure; it does not establish its cause or resolution. Runtime, device
type, selectors, deadlines and failure gates remain unchanged. No automatic retry
or fallback to the image device is added. Judge the result on the next hosted
execution, not on a local product-test pass.

## Default feedback loop

1. Read the existing run's compact report before scheduling more work:
   `python3 scripts/ci_feedback.py --run RUN_ID --format text`.
   Assign one owner per independent cause; the coordinator owns dispatches and integration.
2. Validate changed source and workflow contracts locally. Use one focused original
   journey to qualify a fix, with a recorded source revision, question and expected
   result. Reuse compatible build products; retain the first failure's evidence.
3. Inspect the existing result once. If the experiment did not distinguish causes,
   investigate source or use a smaller reproducer before repeating a long journey.
4. Combine verified fixes into one PR regression batch. Full release checks must
   pass at the final combined revision; focused passes are supporting evidence.

### Daily triage and next-batch decision

Use CURRENT-HANDOFF's current checkpoint as the single work queue. Group failures
by demonstrated cause, not by the number of red jobs. Record the original run or
bundle, classification, next action and affected check in that existing checkpoint.
An unexplained failure stays unclassified until its evidence supports a cause.

| Observed failure | Next action before another expensive run |
| --- | --- |
| App behavior or data differs from its contract | Fix the behavior and run the affected original test; add a focused regression only if existing coverage misses the defect. |
| Selector, fixture or transition synchronization is wrong | Inspect the screenshot, result and current UI/API contract; correct the harness while retaining the outcome assertions. |
| Runner fails before selected tests execute | Report the cases as unexecuted. Inspect runner/setup evidence; do not infer app defects or rerun the entire workflow. A targeted retry needs a concrete setup correction or evidence of a transient failure. |
| Export, parser or artifact processing fails after execution | Reprocess the retained output first. Missing or incomplete evidence remains a failed qualification. |
| Known SDK or environment limitation | Retain the smallest reproducer and park repeated experiments until new evidence or the applicable release decision requires them. |

Keep one active investigation per cause and one local native execution at a time.
Parallel helpers, when requested, should own independent source changes or reviews;
the coordinator alone integrates and dispatches. Do not add workers or test shards
without an independent task or measured capacity benefit.

Before publishing the next grouped candidate, review the pending diff, finish the
affected checks and confirm the current hosted batch has yielded its useful results.
Run the existing cheap source-validation step once on that combined revision,
including the complete Python suite (`.build/ci-yaml/bin/python -m unittest
discover -s scripts -p 'test_*.py'` locally), generated-file checks and localization.
Focused checks did not catch a stale diagnostic hash and removed-trigger expectation
on November11; the complete Python suite takes seconds locally and catches dependencies
outside the edited test module. This is a pre-push source check, not another native
regression batch. Reuse it while its source inputs remain unchanged.
Push once for combined integration; do not follow it with status-only pushes or a
duplicate manual run. If cheap source validation fails before the expensive fixture
builds or tests start, inspect their live state and qualify the source correction
locally, then supersede the queued batch once. Record the reason and retain the
original failure; do not spend a full fixture run on an already-disqualified
candidate only to repeat it immediately. If an urgent correctness/security fix supersedes that batch,
record why and preserve its available evidence before replacement. During the next
batch, prepare diagnosed fixes locally; successful unchanged focused checks need
no repetition. Keep merge qualification, deferred owner setup and App Store release
acceptance separate. These rules add no new test suite, wrapper or approval step.

Wait for every producing build to finish before starting checks that consume its
output. This also applies to TypeScript service tests: do not start database/HTTP
tests while `tsc` is still replacing `dist` files. Bind the source and compiled
output hashes to the finished attempt, and serialize source changes, builds and
dependent tests. Independent read-only reviews can continue in parallel.

Export a fresh xcresult bundle's summary and test details sequentially. Concurrent
exports have collided while xcresulttool initialized its database. If only export
processing fails, retry that processing against the retained bundle, then run the
existing strict result check; do not repeat the native tests for an export error.

When reusing DerivedData, select the exact test plan produced by the completed
build and bind its hash. An older plan for another architecture may share the same
SDK version. Preserve test class names when assembling focused selectors, then
verify each selector against the compiled inventory before launching XCTest. A
selection-only failure should reuse the verified build after correction.

### Validate the contract before escalating

Before changing application behavior, compare the failure with the current API,
schema/migration, fixture or selector contract. Classify a stale harness, invalid
setup and an application defect separately. Run the smallest relevant contract
check first; escalate to a build or original journey only when the cheaper check
passes and a written question remains. For changed iOS Swift, run
`python3 scripts/check_swift_syntax.py --changed` before compilation. This catches
syntax errors such as the observed missing bracket; parsing does not establish
type correctness, successful linking or UI behavior.

For a new platform API helper, typecheck its complete declarations against the
selected SDK, deployment target, Swift version and required framework/overlay
search paths before a full app build. Include every architecture that the next
build actually compiles. Missing imports are semantic errors that syntax parsing
cannot catch. Retain setup failures separately from API failures; a malformed
extraction or missing XCTest Swift overlay does not establish an application
defect. A passing helper probe still needs the original app build and journey.

Bind each attempt to its source and finished build outputs. Reuse terminal logs,
exports and failure receipts before requesting new evidence. A failed control
needs a changed input or a smaller experiment, not another unchanged full run.
Focused evidence qualifies only its exact source and scope; the final combined
candidate still needs its own complete qualification.

For the database suite, run
`node --test service/tests/database-test-preflight.test.mjs` first, then use
`npm --prefix service run test:integration` with the declared local fixture URLs.
The harness checks required Foundation routing assets before opening a connection.
Missing or malformed external test data is a setup failure. It also checks local
disposable `ritc_` targets, consistent database
scope, actual bounded runtime/worker/verifier connections and the restricted app,
worker, verifier and combined negative-test roles before auth DDL, migrations, journal provisioning or child tests. It does not
create roles or repair permissions; use the explicit fixture setup in `ci.yml`.
Missing credentials or incorrect memberships are setup failures, not application
regressions.

Use a fresh disposable database for each integration-suite attempt. The real
fixture journal is single-use: an existing `ritc.privacy_journal_origin` blocks
reuse. Preserve the failed database and retained journal evidence; never delete
the origin, replace its lineage or substitute a no-op journal to rerun the suite.
Keep private keys outside evidence. A fresh database fixes isolation only; it
does not clear an application failure or qualify a different source revision.

### Separate diagnostic setup from measurement

An observer must allow the original successful journey to reach its measurement
boundary. Compare retained stage timings before changing a timeout; installation,
app/runner binding, fixture preparation and measurement are different phases.
Record each phase's monotonic start, fixed deadline and elapsed time. A status poll
or repeated missing-container response must never reset a deadline. Check expiry
after expensive identity or hash checks as well as before them, and preserve a
fixed total wall limit. Startup allowance does not qualify performance or change
required metrics, original assertions, failure handling or cleanup ownership.

The opt-in hosted scroll observer now allows 180 seconds from native dispatch to
verified app/runner binding, 120 seconds from binding to ARM, and 120 seconds from
ARM to normal native completion, with a 420-second absolute limit. Its existing
15-second collector readiness, 60-second recording and 90-second post-readiness
wait limits remain. A prior successful hosted journey reached fixture readiness
at about 133.8 seconds, beyond the old absolute 120-second ARM limit. Current
whole-profile preflight passed324 checks in each ordinary/observer profile before
the installed-bundle correction added eight observer controls. Both complete
profiles must pass again on the exact committed successor before dispatch.
All three initial container queries (app data, installed app and installed test
runner) use the remaining original binding budget. Each may continue observing
its same owned process beyond
the shared supervisor’s two-second image-acquisition window, within the original
180-second binding deadline. Only an exact verified target identity permits
signaling; an interpreter stays pending, and output requires a real terminal
exit. Unknown identities/errors still reject. Bounded first/last identity samples
make the next failure diagnosable. Queries after binding still have five seconds;
native/tracer acquisition, all phase deadlines and required metrics remain unchanged.
[Verified checks and first-failure evidence](evidence/ci/performance-dispatch-parity-20261109/initial-bundle-verification.json).
Only a new hosted attempt can establish collection success.

### Retain the first failure before retrying

Core and fixture simulator builds now save `build.log` and a small `receipt.txt`
under `.build/ios-build-evidence/`. The receipt records the actual checkout SHA,
run and attempt, build configuration/profile and selected Xcode. The build's
`pipefail` preserves compiler failures when output passes through `tee`. A
best-effort artifact upload after an attempted build keeps diagnostics available
without changing the existing build/test gates. An upload failure remains visible;
it is not proof that the logs were retained. Keep the relevant originals with
hashes before the seven-day Actions retention expires.

The native Swift HTTPS/PostgreSQL harness creates a fresh
`.build/native-wire-results/attempt.*` directory for every invocation. It retains
bounded stdout/stderr and a receipt for each launched Swift invocation, including
failures; later attempts never replace those files. The original 180-second subprocess
limit and 2 MB per-stream bound remain unchanged. The exact required case and
scenario lists are in `service/scripts/test-native-wire.mjs`; its exact roster is
checked against the observed Node and Swift results. Use that roster rather than
a copied count when adding coverage. On failure, the wrapper preserves its
owner-only attempt directory and any database or journal state already created,
outside the uploaded artifact tree. Per-scenario TLS files are removed when their
helpers clean up. Private custody metadata records retained paths; public results
report shutdown and retention status without those paths.
Successful attempts remove their private state. A failed stop remains a failure
and preserves the state for investigation. On GitHub-hosted runners, private
state disappears when the runner is destroyed; it is not a durable backup.

Inspect the retained build or scenario failure before retrying. Do not rerun a
long journey just to recover output that was available in its first attempt.

When collection completes normally but export or inspection fails, recover from
the retained recording/result before repeating the app. Verify terminal process
state and stable artifact hashes, then inspect a fresh copy with explicit time,
size and disk bounds. Keep the original failed receipt unchanged. A successor
report must bind the original collection to the new export and report collection,
transport, strict XCTest, fixture and measurement checks separately; overall
qualification still requires every applicable gate. Size limits may change only
with recorded evidence, such as exported rows and their recording-time coverage.
An export-only correction does not qualify another source revision or baseline.
Give raw test logs and checker logs distinct descriptive names, such as
`Performance.log` and `performance-checker.log`; case alone does not distinguish
files on a default Mac filesystem. If a checker fails before evaluating retained
exports, preserve that failure and run the missing check against verified copies.
Do not re-export the result or repeat the app solely to fix the checker log path.

The optional `observe_app_scroll_signposts` profile is a single manual diagnostic,
not part of ordinary PR or release acceptance. It keeps the separate performance
producer and consumer, builds the gated observer once, and schedules only the
original scroll selector. Admission requires baseline enforcement off, a fresh
owned simulator, and the other collectors off. Cheap profile, source, SDK and
helper typechecks precede the build. Preserve the ordinary test environment;
record only allowlisted diagnostic settings, never a complete environment dump.

Report collection, trace export, XCTest, fixture, required metrics and final
qualification separately. Preserve evidence before deleting the owned simulator.
The observer uploads one bounded archive with file modes preserved, excluding
disposable inspection copies; a raw fallback is explicitly unqualified. Reserve
8 GiB plus archive headroom before writing. This keeps later inspection possible
without another test run or duplicate raw uploads.
An observed UIKit interval is not a replacement XCTest duration sample. If adding
the observer makes the missing duration reappear, that is an interaction to
investigate, not a confirmed fix. No outcome from this profile approves the
Xcode 27.1 baseline. Review the one terminal result before proposing another run.

For local UI follow-ups, distinguish XCTest's result evidence from its optional
system diagnostic collection. A completed eight-case date batch spent additional
minutes in an owned `simctl diagnose --timeout=600` after two setup assertions had
already failed. The parent stack confirmed simulator-diagnostic collection, not
continued test execution. Retain that first attempt, its result bundle and the
diagnostic outcome separately from the test duration.

Once retained screenshots/hierarchy and the test log explain an ordinary UI
assertion failure, a focused local follow-up may explicitly use
`-collect-test-diagnostics never`. Record the prior evidence and reason in its
receipt. Keep the result bundle, test logs, screenshots/recording, original
assertions, selector accounting and strict validation. This avoids another full
simulator system dump; it does not waive a failed test or missing evidence. Use
`on-failure` for an unexplained crash, hang or framework fault. Hosted CI defaults
remain unchanged. Measure result-finalization time separately before changing
their policy.

The shared native shard runner now writes `test-run-timing.json` before result
export, including on a failed native attempt. It separates the root test-suite
window from the interval until Xcode's test observer completes and records explicit
diagnostic timeouts. Both values come from the same retained, hashed log; the latter
includes remaining diagnostics/teardown and is not pure export time. Missing,
restarted or inconsistent boundaries remain unknown. Timing reporting cannot turn
a failed native or strict check green. An infrastructure retry gets a separate
`test-run-timing-retry.json`; both files use the existing artifact upload paths.
[Validation and retained timing evidence](evidence/ci/native-finalization-timing-20261109/README.md).

For changed layout, localization or Dynamic Type behavior, inspect the affected
retained English/Spanish screenshots at ordinary and largest text sizes as well
as the test outcome. A successful date-selection journey still exposed overlapping
Spanish calendar controls in its saved image. Native wheels then exposed a
duplicate visible label wrapping into a narrow column. Fix the observed layout
without capping production text size or removing behavior assertions. Export from
a verified result copy; do not rerun an unchanged journey just to view its images.

### Candidate qualification order

Before a manual performance dispatch, run the entire existing cheap workflow step
with the exact planned inputs, not only the changed test module. For the current
observer profile:

```sh
.build/ci-yaml/bin/python scripts/check_performance_dispatch.py \
  --case scroll --fresh-performance-simulator --observe-app-scroll-signposts \
  --evidence .build/performance-dispatch-NEW-ATTEMPT
```

Use a new evidence directory each time. The tool needs PyYAML, as does the existing
workflow validator. It reads the workflow's actual step/environment, bounds local
execution and records source hashes before/after. Before dispatch, verify the
receipt still matches current inputs. Test fixtures must explicitly declare their
own profile instead of inheriting diagnostic flags. A workflow edit can invalidate
an unchanged test's previous result; incremental passing logs are not a combined
preflight pass. Check the ordinary profile as well when changing profile routing.
[First complete profile checks](evidence/ci/performance-dispatch-parity-20261109/README.md).

A rejected toolchain preflight must retain the expected and observed identities
before returning failure. Collect the bounded inventory in one pass, including
tool file hashes, architecture/container details and SDK/version metadata. Preserve
that report through the existing always-upload path even if no build log exists.
Diagnostic inventory does not admit a mismatched tool or replace the original
compatibility gate; review the difference before another expensive run.

Use this order for the combined candidate going forward:

1. Finish promised product behavior and repair observed defects. Use affected
   existing checks; optional measurement and simulator experiments do not hold
   up unrelated app work.
2. Batch the verified fixes, record one immutable candidate SHA, and run the
   combined regression once. Inspect a still-running batch before dispatching
   another. Keep the existing run URL and result bundles; ordinary development
   does not require a new qualification receipt or source archive.
3. Keep the missing launch/scroll measurements and original minimum-iOS failure
   visible for their applicable qualification gates. A reduced reproducer or
   passing XCTest without required metrics does not close them. Do not approve
   an unmeasured performance baseline or relabel an unresolved check as passed.
4. Review required merge gates on that candidate. Track physical-device, human
   accessibility/localization, provider and signed-distribution work separately in
   `RELEASE-EXECUTION.md`; green merge checks alone do not authorize App Store release.
   A later edit requires the checks it can affect; the final aggregate must still
   identify one qualified revision, rather than combining different revisions.

Keep one coordinator for dispatch and one owner per failure cause. Before an
expensive run, record the diagnostic question, changed input, expected distinction
and stopping condition. Reuse retained outputs and compatible products rather than
repeating an unchanged successful focused run. Add shards only after measured
critical-path improvements justify them within the existing five slots.

The compact report lists every unsuccessful or unfinished job, including skipped
and cancelled jobs with no failed step. It includes the five longest execution
windows and their longest steps, plus the five longest measured delays before
jobs started. These delays include dependency and scheduling waits, not just
runner queues; skipped jobs and jobs without a start timestamp do not enter
that ranking. Compare waiting with execution before changing slot allocation.
These are triage hints, not a critical-path calculation or a count of distinct
bugs. Omit `--format text` for complete JSON.
Neither format dispatches work or downloads logs.

Before changing shard allocation, compare like-for-like full batches: elapsed
time, Mac runner-minutes, build/setup/test/evidence time and time before jobs
start. The last measured batch already used 91.22% of five-slot capacity.
Shared archives already avoid recompression; additional splitting or caching
needs measured benefit. A new layout is not automatically a faster one.

## Reuse local build paths with preserved proof

For local iOS simulator builds, bind `SDKROOT` to the selected Xcode's simulator
SDK in the build subprocess. An inherited host macOS SDK can contaminate the
generated Swift package framework linker even when Swift receives `-sdk` for
iPhoneSimulator. Use the same `DEVELOPER_DIR` for SDK lookup and execution:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" xcodebuild \
  -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$RITC_DERIVED_DATA" CODE_SIGN_IDENTITY=- build-for-testing
```

Set `SIMULATOR_ID` to the owned device and `RITC_DERIVED_DATA` to the preserved
execution directory before using that command; retain the run's original profile
and test-selection settings when adapting it.

In a Python executor, resolve that path with `subprocess.check_output` using the
selected environment, then set `SDKROOT` only on the child environment. Record
the chosen path. Do not apply a simulator SDK to macOS package tests or device
archives. Merely unsetting the host variable is insufficient: the retained
Xcode27.1 driver probe then reported SDK17.0 metadata. The explicit simulator
setting produced SDK27.1, and a clean build verified all five package frameworks
as iOS Simulator/minimum17.0/SDK27.1. Preserve previous products before rebuilding
when their SDK provenance is wrong; an incremental no-op cannot validate a fix.
The original warning, driver probes and actual build readback remain under
`.build/SDKRootDiagnosisNov09/` and
`.build/SourceRemovalAcceptanceNov09/native-r3/build/`.

For a small native source change, keep the execution source and DerivedData paths
stable so Xcode can reuse compatible products. Before mutation, require the
previous process to be terminal, archive its complete source and products, and
verify content manifests plus executable modes. Preserve original result bundles,
logs and receipts; record archival custody and give the successor its own manifest
and output directory. Never overwrite an archive: the same source may have
different builds/configurations. The old execution script is historical once its
working paths contain a successor. Archived xctestruns may retain absolute paths,
so any independent replay requires a reviewed rebind and new receipt.

When assembling the successor, compare file contents and executable modes before
copying. Leave identical files and their modification times alone; rewriting an
unchanged source tree can trigger avoidable compiler work. Verify the complete
successor manifest after synchronization, including removed inputs. This is a
build-efficiency rule, not permission to reuse mismatched products. Record actual
build time before claiming a gain.

The S24 correction used this process: prior fresh-path builds took 211–213 seconds;
the changed-test builds took 13–16seconds. These are observations with different
inputs, not a performance guarantee. Do not reuse products with mismatched inputs
or skip the appropriate regression. [Custody and execution proof](evidence/native/s24-fixture-isolation-20261109/README.md).

## Reduce repeated UI traversal before increasing deadlines

The retained Spanish AX5 Dinner R3/R4 attempts measured repeated review traversal
as expensive work. The later isolated combined R4 candidate now passes the full
original Spanish AX5 journey on iOS26.2 in696.241 test seconds, including all five
Done probes and persistence. Its source manifest and qualification receipt bind
that result; it is not minimum-OS or final combined-hosted acceptance.
Keep every original assertion and deadline when optimizing queries and gestures.
Measure the same journey and environment before claiming a speedup; local/hosted
or different-revision focused results do not establish a like-for-like gain.
[Exact candidate and retained evidence](evidence/native/dinner-accessible-fields-20261109/README.md).

## Primary Xcode 27.1 toolchain

Existing native workflows now use Xcode 27.1 build 27A9275 at
`/Applications/Xcode_27.1.app` on the arm64 `xcode-27` hosted runner. Local Xcode
27.1 matches this exact compiler build; no local download is needed. Existing
PR, manual and release triggers retain their original coverage and strict gates.
There is no additional compatibility workflow or duplicate scheduled suite.
All 17 native job definitions still share the same five global slot queues;
16 migrate and the required Swift CodeQL job retains the security exception below.

The performance simulator producer explicitly uses `ARCHS=arm64
ONLY_ACTIVE_ARCH=YES`. Its runner and consumer already require arm64, so compiling
an unused Intel simulator slice adds no execution coverage to this lane. Keep this
override on the simulator producer command: generated Release defaults, device
archives and restored consumer commands retain their existing configuration.
Command-level tests verify the actual arguments and native failure propagation;
provenance tests preserve the arm64-only plan's name, bytes and product identities.
Qualify changed products on a frozen hosted revision before using them as release
evidence. Compare compile tasks, archive size and build time under recorded cache
conditions before claiming a speedup.
The first [hosted qualification](evidence/native/hosted-arm64-observer-20261109/README.md)
verified actual arm64-only products and unchanged producer/consumer identity. Its
native scroll case passed, while the required duration remained missing. This
qualifies the narrower build change, not performance completeness or release.

The official [runner catalog](https://github.com/actions/runner-images/blob/main/README.md)
and [Xcode 27 image](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
were checked November 9, 2026. `xcode-27` is a **public preview** runner, distinct
from `macos-26`. Published image `20261026.0314.1` includes the selected toolchain
and iPhone 17 on iOS 27.0. Each migrated job checks the exact Xcode version/build
and arm64 architecture after checkout. Simulator selection requires both
`com.apple.CoreSimulator.SimRuntime.iOS-27-0` and `iPhone 17`, including when
creating an owned device. It cannot silently select the image's newer iOS 27.1
runtime, which currently offers iPhone Duo instead. The actual runtime build is
recorded; the image documentation does not publish its build identifier.
The rolling preview label is not an immutable image pin. Runner availability and
successful hosted execution still need qualification at the migrated revision.

`ios-swift-codeql` remains required on `macos-15` with Xcode 26.3. GitHub's
[official CodeQL support notice](https://github.blog/changelog/2026-10-19-codeql-changes-for-macos-27-xcode-27-and-swift-6-4/)
explicitly excludes Swift 6.4 and traced Xcode 27 builds; `build-mode: none` is
not a Swift replacement. This hosted security exception preserves manual Swift
analysis and its gate. It does not inherit the iOS 27 runtime selector and does
not require installing Xcode 26.3 locally. Remove it only after official support
and a successful equivalent analysis are established.

The iOS 17 deployment contract and separately required local minimum-OS testing
remain unchanged. There was no hosted iOS 17 runtime lane to migrate, and the
preview image does not advertise that runtime. Compiler equality alone does not
establish OS/runtime or hardware equivalence; products must not cross incompatible
toolchains. Historical results and their original environment identities remain
historical evidence.

### Performance calibration blocks release until approved

For a missing launch or scroll measurement, the manual performance workflow has
an opt-in `enable_performance_diagnostics=true` setting. Use it with exactly one
`case=launch` or `case=scroll` and `enforce_baselines=false`. The Linux planner
rejects full-suite, release-enforced and concurrent live-collector combinations
before allocating a native runner. Ordinary runs keep the existing command.
The diagnostic adds Apple's `-enablePerformanceTestsDiagnostics YES`, preserves
the original test and strict measurement checks, and exports available diagnostics
alongside the result bundle. An export failure stays visible as a failed step;
successful export alone does not prove that a useful performance trace exists.
Apply the [collector qualification rule](#qualify-collectors-before-app-diagnostics)
before spending another original app journey on a new collection mechanism.

Inspect the retained trace for the application's events and actual measurement
windows before choosing another experiment. Missing events are inconclusive
without verified capture coverage. If enabling diagnostics makes a previously
missing metric appear, that is evidence of changed instrumentation behavior,
not an approved performance baseline. Diagnostic runs never substitute for the
ordinary combined candidate's regression and performance checks.

Preserve the same-run producer/consumer provenance contract. Reusing an artifact
from a different workflow run is not authorized merely because its source SHA
matches; do not spoof run identity or rewrite the plan to bypass that guard.
Use already-compatible local products for a local control, or one fresh hosted
producer when a changed workflow needs hosted qualification.

The approved performance profile remains byte-for-byte unchanged at Xcode
26.3/17C529, iOS 26.2/23C54, iPhone 17, arm64, Release/TestSchemeAction. It cannot
approve measurements from Xcode 27.1/iOS 27.0. PR and full release enforcement
remain enabled, so they fail closed without an exact approved new profile.
Use the existing manual `ios-performance.yml` workflow with `case=all` and
`enforce_baselines=false` to collect the new environment's complete metrics and
retained evidence. Review those actual measurements before adding an approved
profile; do not relabel the old baseline, drop a metric or treat collection as a
release pass. Missing metrics and test/warning failures still fail collection.

Enforced performance runs reject proven environment incompatibility before
expensive native work. The Linux planner compares configured Xcode version,
iOS version, device model and runner architecture with approved profiles. It
reuses the existing workflow pins; it cannot know the hosted runtime build.
After simulator selection, the build runner reads the actual runtime build,
device type, architecture and Xcode version/build before compiling. Test runners
repeat this read-only check before boot to detect image drift between jobs.
These checks neither boot a device nor run tests. A compatible profile at this
stage is only permission to proceed: the unchanged post-test validator still
requires the exact complete result environment, all metrics and approved limits.
Calibration-only runs skip baseline availability checks and retain every late
evidence requirement. The current 26.3 baseline therefore fails enforced Linux
planning immediately, while explicitly requested calibration remains available.

The full `release-checks.yml` entry point also runs
`check_release_performance_preflight.py` in its Linux source preflight, before
any native suite can start. It reads the existing performance workflow pins and
uses the same compatibility validator without a calibration bypass. A known
baseline mismatch therefore blocks the entire expensive release batch, not only
its performance jobs. Source security and dependency checks remain independent;
focused diagnostic workflows remain available. Actual runner identity and final
metric validation still run downstream after a compatible profile is approved.
[Change and verification](evidence/native/release-batch-preflight-20261109/README.md).

### First hosted migration qualification

After reviewing and publishing a candidate revision, use the already registered
core workflow's first-class manual Dinner scope:

```sh
gh workflow run ci.yml --ref codex/my-reviewed-fix -f ios_scope=dinner
```

Confirm the selected ref's immutable SHA and existing runs before dispatch and
record the returned run's `head_sha`. Full compiled inventory validation happens
before narrowing work. Every enabled ordinary model test is retained, plus exactly
these original UI journeys in `ui-01`:

- `FreeJourneyUITests/testFirstPickupCanStartFromDinnersAndReviewAnEditablePattern`
- `FreeJourneyUITests/testSpanishDinnerIdeaReviewsPacksAndLeavesListEmptyAfterApproval`

The original full manifest, selector files and compiled enumeration remain in the
retained test-plan artifact. The same runner verifies exact executed selectors,
counts and warnings with unchanged test allowances. Every other core job remains
required, including release compilation, package tests and Swift CodeQL. This
reduces core UI work; it is not a single-job smoke test or complete release coverage.

`ios_scope` defaults to `full` and is exposed only for manual dispatch, never as a
reusable workflow input. PR, push and release calls retain the full suite. The
focused run is named a Dinner diagnostic, has a distinct `Dinner diagnostic gate`,
and uses its own workflow concurrency group, so it cannot cancel a full run on the
same ref or present its success as the normal `CI gate`. Native jobs still share
the same five non-cancelling slot queues. Unknown scopes and attempted narrowing
outside manual dispatch fail closed. No temporary alias workflow is required.

Follow the focused run with performance collection and the full existing
core/deep/fixture/native-wire/release batch once the combined app revision is ready.
An independent fixture smoke remains available through `ios-fixtures.yml` with
`shard=DinnerDecisionSheetUITests`, retaining that entire original fixture group.
Keep the first failure and inspect it before repeating work. This migration has
no hosted pass until the corresponding run receipts are recorded.

## Independent fixture pipelines and shared billing build

Contributor and dinner fixture tests now wait only for their own profile build.
The planner partitions the existing 17 rows without changing their test selectors,
order within each profile, or assigned macOS slots. Both pipelines retain the
same runner, timeouts, warning checks and Records privacy handling. A failed
profile does not block evidence from the other profile; the final `Fixture gate`
still fails unless every selected build and test job succeeds. Only a profile
explicitly excluded by a focused manual selection may be skipped.

Local StoreKit English and Spanish checks share one compiled test product. Their
runtime language/storefront configurations and all 15 scenarios per language
remain required. The shared build and the two consumers use the existing global
five-slot limit; a shared build failure cannot pass the final billing gate.

These changes remove a cross-profile wait and one duplicate StoreKit build.
They do not establish a new full-suite duration: artifact transfer, simulator
startup and actual job scheduling still need hosted measurement.

## Fast validation before macOS work

Core macOS entry jobs now wait for `source-checks`: Swift packages, Release
compilation, Swift CodeQL and the shared UI-test build. The measured source job
took 24 seconds in the November 8 batch. A generated-file, workflow or product
contract failure therefore stops these expensive jobs before they claim a macOS
slot. The final `CI gate` still rejects any failed or skipped required job.
Independent service/web checks continue in parallel. This trades a short startup
dependency on passing runs for less wasted work on invalid revisions.

The pre-release entry point now has its own Linux `source-preflight` before core,
deep checks, fixtures, native-wire, performance and installed staging-app work.
It checks generated files, localization, workflow syntax, Python checks and shell
syntax. These native paths start in parallel after preflight; they do not wait
for the whole core suite. Security and dependency audits remain independent.
The release gate requires preflight success, so a failure or skip cannot turn the
release green. Standalone workflow checks and the core validation remain intact.
This deliberately repeats inexpensive checks at the release boundary.

Full release dispatch requires the reviewed, full lowercase commit SHA:

```sh
gh workflow run release-checks.yml --ref REVIEWED_BRANCH \
  -f candidate_sha=FULL_40_CHARACTER_REVIEWED_COMMIT_SHA
```

Use the frozen commit recorded for qualification, not a newly resolved branch tip.
Immediately after checkout, Linux preflight requires that input to match both
the dispatch event's `GITHUB_SHA` and the actual checkout's `HEAD`. A malformed
SHA or an advanced branch fails before native jobs can claim a slot. This check
does not replace the exact-revision evidence receipt or establish minimum-iOS,
merge or distribution acceptance. Existing workflow-level cancellation still
applies before preflight; do not dispatch another run to probe an active one.

Performance planning and Python evidence-validator tests also run on Linux before
the optimized build. The compiled XCTest inventory is still verified on macOS.

## Focused hosted feedback

`iOS fixture checks` now accepts an optional manual `shard` input. Leave it blank
for all fixture groups. An exact shard selects that complete group and only its
required build profile; it preserves the same compiled-inventory validation,
selectors, runtime-warning checks, privacy handling, timeouts and five-slot limit.
The run title names the selected group. A targeted pass is diagnostic evidence,
not full PR or release acceptance.

List valid groups with `python3 scripts/plan_ios_fixture_tests.py matrix`. The
workflow is published on development branches; dispatch a focused run on a branch
containing the change without an open PR, for example:

```sh
gh workflow run ios-fixtures.yml --ref codex/my-reviewed-fix \
  -f shard=SharedStoreQuoteUITests-testKnownTripUnknownBreakEvenPrivateProposalAndExplicitShopperAdoption
```

Use a separate development branch for this feedback. Pushing to an open PR still
starts its full required checks. PR runs and reusable release calls expose no
shard selection and retain all fixture coverage. Unknown manual names fail in
the Linux planning job before allocating a macOS build. A failed required build
cannot be bypassed by the optional-profile skip condition.

Work in this order: reproduce and isolate the failure; keep the original journey
and assertions; run the focused local/hosted check; then publish a coherent set
of qualified fixes to the PR for a full regression batch. Reuse a stable local
DerivedData directory when the toolchain/profile is unchanged, preserving the
tested source revision/diff and results. Avoid a fresh source path and cold build
for every small experiment. Keep CI failure diagnostics enabled; collect heavier
local diagnostics when they answer the failure being investigated.

The first hosted focused fixture run passed in 28m27s, including its build,
simulator setup and one original quote journey. The unused dinner build was
skipped. This confirms the focused path works; it does not establish a faster
full-suite duration. [Verified hosted result](evidence/native/ci-focused-known-trip-20261108/README.md).

A branch-only core dinner diagnostic is available on
`codex/core-dinner-ui-diagnostic-20261108`, using the already registered
`ios-toggle-diagnostic.yml` path. It builds ordinary core Debug products once,
validates the complete compiled inventory, then runs exactly one original
English (`en`) or Spanish (`es`) dinner journey through the unchanged strict
shard runner. Build and test share one of the five macOS slots, so products do
not need an upload/download round trip. The distinct diagnostic check is not a
required PR or release check.

Dispatch requires an explicit language and the full commit SHA of that branch.
Use a candidate branch containing this workflow; do not create a PR just to
launch it. The workflow rejects a mismatched SHA or the default `choose` input.
Do not merge the diagnostic-path substitution into the integration branch.
Static validation passed; its first hosted execution is still pending.

The performance workflow likewise accepts a manual `case`: `all` (default),
`launch`, `rendered` or `scroll`. For example:

```sh
gh workflow run ios-performance.yml --ref codex/my-reviewed-fix \
  -f case=scroll -f enforce_baselines=true
```

The complete compiled performance inventory must match before selection. A
focused case retains its original selector, slot, execution deadline and evidence
validation. PRs run all three cases. The reusable release workflow exposes no
case selector and enforces all approved baselines. A focused result cannot stand
in for the full release gate. The baseline-enforcement input retains its existing
behavior; keep it `true` when checking an environment with approved limits.

Do not dispatch repeated copies while a diagnostic is queued or running. Record
the branch SHA and run URL, inspect one terminal result, and group the resulting
qualified fixes into the next full PR batch. A rerun uses the original revision;
changed source needs a new run. Preserve the first failure's evidence before
retrying. Full release acceptance remains tied to one exact revision.

The November 8 baseline took 150.70 minutes across 43 macOS jobs and 687.37 macOS
runner-minutes, about 91.22% of five-slot capacity. More static shards alone cannot
remove most of that work. Source compilation, simulator startup, slow UI
interactions and unnecessary full diagnostic batches are separate optimization
targets. [Measured timing evidence](evidence/native/ci-workflow-efficiency-20261108/README.md).

The pre-release workflow launches the Staging scheme on an iPhone simulator. It verifies the installed build’s anonymous service and authentication responses and opens Help and Support from native Settings into Safari. The release gate requires all three cases to run and pass its runtime-warning checks. This job uses one of the existing five macOS slots.

The Linux source check runs the Foundation 2.1 verifier with Python 3.13. It checks the 52 launch requirements, 27 screen contracts, source checksums, SQLite constraints and reference grocery scenarios. The PostgreSQL job separately executes all twenty grocery inbox scenarios against the service.

After changing service code, run `npm test` in `service/` before pushing the combined candidate. On GitHub, `typescript (service)` runs those unit tests. The independent `service-postgres` job discovers `service/tests/*.integration.mjs` and also runs the PostgreSQL billing suite. It exercises browser retries, then runs maintenance and restore checks on a separate database. Both jobs feed the CI gate.

The workflow validator uses actionlint 1.7.12 plus the hash-pinned PyYAML requirements. Use an isolated environment; CI creates one before running the full Python suite. The lock currently covers CPython 3.12 on Linux x86_64 (Ubuntu 24.04) and CPython 3.9 on macOS arm64 (this Mac). Other interpreter/platform combinations require a reviewed wheel hash; source builds and unpinned fallback installs are disabled.

From the repository root:

```sh
python3 -m venv .build/ci-yaml
.build/ci-yaml/bin/python -m pip install --disable-pip-version-check --no-cache-dir --no-deps --require-hashes --only-binary=:all: -r scripts/ci_yaml_requirements.txt
.build/ci-yaml/bin/python -m unittest discover -s scripts -p 'test_*.py'
```

Run `scripts/check_ci_workflows.py` with that environment's Python, `--actionlint` pointing to the pinned 1.7.12 executable and `--report .build/workflow-lint.json`. The workflow contains the verified download and checksum for its Linux binary. Direct actionlint alone reports its known unsupported `queue` key; the paired validator exempts only the exact error at independently validated source positions and retains all other failures.

New macOS jobs must be added to the slot policy and tests. Keep slots on leaf jobs only; reusable-workflow callers and workflow roots must not own a slot while waiting for children. Existing non-native groups require a fixed prefix that is provably disjoint from reserved slot names, including case-insensitive comparisons. Every original test selection and final all-success gate remains required.

These are static checks. Hosted execution, native results, performance measurements, signed-device/provider acceptance and human review have separate evidence requirements. See [current acceptance](CURRENT-ACCEPTANCE.md).

## XCTest failure diagnostics

### Working rules for faster fixes

Use one coordinator to own dispatches and the integration branch. Give each
independent failure one investigation owner; helpers should return a patch and
its evidence before overlapping files are installed. Monitoring should reuse
the existing run ID rather than launch another copy.

Keep the working loop small:

1. Group failures by root cause before assigning helpers. One shared failure
   should have one owner, even when it appears in several jobs.
2. Run the affected cheap checks first, then one focused native diagnostic that
   answers a written question. Reuse compatible local build products and preserve
   the original failure. Avoid rebuilding unchanged products just to inspect logs.
3. Use a development branch without an open PR for focused hosted diagnostics.
   Record its exact commit, run ID, selected scope and next decision. Check for an
   existing queued/running copy before dispatching another.
4. If a run failed for an identified transient infrastructure reason, retry only
   the affected job and its dependents at the same revision. A product failure
   needs a fix, not repeated attempts until it turns green. Changed source needs
   a new run; retained products are evidence only for their original revision.
5. Combine independently verified fixes into one PR regression batch. Run the
   unfiltered release gate on the final combined revision before distribution.

After repeated experiments fail to distinguish the competing explanations,
switch to a smaller reproducer or source-level investigation before another long
journey. Add diagnostics only when they answer the current question. Update the
handoff at a meaningful result or ownership change, and reuse downloaded artifacts
instead of repeatedly exporting the same result bundle.

GitHub supports [rerunning one job or failed jobs with their dependents](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs).
Keep workflow supersession enabled so a newer branch revision cancels its stale
run; keep the shared macOS slot queues non-cancelling so unrelated jobs do not
evict each other. See [GitHub concurrency behavior](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).

| Situation | Next work |
| --- | --- |
| Source, generation or workflow validation fails | Repair and rerun the cheap validation before allocating a native build. |
| One fixture journey fails | Preserve its first failure and run its complete fixture group on a development branch. |
| One performance case fails | Select that case manually, retaining its original measurements and approved limits. |
| A native case passes but strict validation fails | Investigate the warning or missing evidence; do not count the native pass as acceptance. |
| Several fixes have focused proof | Publish them together for one full PR regression at the combined revision. |
| A release candidate is ready | Run the full release checks for that exact revision; focused passes cannot replace them. |

Before another diagnostic, record the question it will answer and what differs
from the retained run. Preserve source, products and original failure results
before reusing a local build directory. Keep one local simulator test active at
a time so competing tests do not distort animation or performance measurements.
Collect each terminal artifact once and reuse the retained copy for analysis.

Track time spent waiting for a runner, building, starting the simulator, executing
tests and collecting evidence separately. Compare full runs with full runs and
focused runs with the same focused scope. The measured 28m27s focused run is not
a new estimate for the full release suite. Rebalance shards only when their
measured critical path justifies it; the existing five-slot utilization is already
high.

The shared iOS shard runner, StoreKit and Release-performance workflows, and optional local UI check use `-collect-test-diagnostics on-failure`. This lets Xcode collect system diagnostics when XCTest encounters a failure or error. Test selections, warning gates, retries and execution deadlines remain unchanged.

For a focused **local layout or control-discovery investigation**, use
`-collect-test-diagnostics never` when screenshots, accessibility state, the native
log and the complete result bundle answer the question. The installed Xcode help
defines this switch as controlling verbose diagnostics such as a sysdiagnose.
Keep the original selectors, assertions, timeouts, result export and strict
checker. Opt into verbose diagnostics when the investigation needs system-level
evidence (for example a hang or infrastructure failure). CI keeps its existing
on-failure setting.

Use that same local-only `never` mode for a focused hypothesis about an already
preserved failure when fresh native logs, attachments, the full result bundle and
strict validation answer whether the failure cleared. Record the hypothesis and
the retained system-diagnostics original. A successful focused run supports
candidate integration; the final exact-revision regression still uses the normal
CI settings. Do not repeat an unchanged successful focused case solely to change
verbose capture mode. Use `on-failure` when new system-level evidence is needed.
The direct-label minimum-OS experiment took145.596test seconds but752.058seconds
to finalize with verbose failure collection: approximately606seconds outside the
testcase. That observation is overhead in this failed local run, not an app speed
comparison or a reason to remove assertions, warning gates or CI diagnostics.

For a local expected-negative contrast control, an explicit `never` override is
also appropriate when pixels, geometry and trait receipts answer the question.
Accept that control only after normal native completion with exactly the intended
contrast failures, both measured below the unchanged threshold, all required
attachments present, and no additional harness failure or runtime warning.
An unexpected failure is inconclusive, not successful negative proof. Record
omitted verbose diagnostics and preserve the prior failed attempt unchanged.
Positive qualification and CI continue to use `on-failure`.

This distinction has measured value: the Spanish AX5 control-discovery testcase
failed after 193.448 seconds; the whole command finished after 800.080585 seconds.
Its owned `simctl diagnose` child used `--timeout=600`. The native process was
left to finalize; it was not restarted, killed or relabeled as passing. Native65,
strict1 and the original evidence are preserved; text size is restored to Large. For another
local layout check, that broad capture does not answer whether a control was
scrolled into view. Preserve the failure artifacts once and use targeted evidence.

Existing CI result-bundle uploads retain those diagnostics for seven days, including after failures. The Records media shard continues to exclude raw bundles and logs from uploads; its sanitized artifacts remain the only published results. Collection can increase failure-run time and disk use, and an outer deadline may prevent complete finalization or upload. Inspect the actual failed-run artifacts before claiming complete evidence.

A later strict-checker rejection of an otherwise passing XCTest run is not itself an XCTest failure. This option therefore does not guarantee collection for a runtime-warning attachment that is missing from a passing test. Required issue descriptions remain mandatory; changing diagnostic collection does not repair or waive a warning.

## Contributor fixture balance — November 11

Run 42953140722 at 49bde552 exhausted the unchanged 40-minute test step in
contributor-balanced-03. Its 19 cases contained two device-management tests, nine
request/pack tests and eight civil-date tests. Eleven finished (nine passed, two
failed); the first civil-date case was interrupted and its remaining seven never
started. The uploaded bundle lacks Info.plist and is not a complete XCTest result.
Preserve its original log and artifact 13831526605; do not infer success for the
uncompleted selectors.

Move HouseholdDevicesUITests from 03 to 02 and SharedMealCivilDateUITests from 03
to 04. These remain whole suites in the existing five groups. The device cases
accounted for 339.636 seconds in that hosted run; groups 02 and 04 finished in 24.3 and
23.4 minutes respectively. These observations support moving work out of 03;
they do not establish the successor's wall time. Verify the new distribution in
one grouped candidate batch. Keep the same 26 fixture jobs, 89 selected tests, five
macOS slots, per-case assertions, strict execution checks and job deadlines.
The existing planner and workflow checks verify coverage and dispatch structure.

## Shared delivery fixture timing

The six shared-delivery cases at `3e96fe3` passed on a hosted iPhone 17 running iOS 26.2. The runner spent about 2m33s on setup before the test step, then about 16m54s running and checking the shard. The six XCTest case durations account for 860.646s of that step. The suite now includes three more journeys. The table groups each whole journey once, using the six hosted case durations and passing local iOS 17 simulator measurements for the additions. [Hosted job and test log](https://github.com/palatis3/room-in-the-cart/actions/runs/42390883332/job/128469594458).

| Contributor shard | Hosted cases (seconds) | Additional local cases (seconds) | Estimated case time |
| --- | --- | --- | ---: |
| `SharedDeliveryUITests-stock-and-purchase` | Record and correct delivery 168.852, Spanish fractional stock 134.521, freezer correction 180.859 | Linked family purchase 54.555 | 538.787 s |
| `SharedDeliveryUITests-recovery-cook-and-closeout` | Unresolved replacement 164.069, replace Wednesday 135.417, dated cook copy 76.928 | Edited cook wording 47.302, financial closeout 94.418 | 518.134 s |

Each job restores the contributor build, boots its simulator, and checks its own selector file against the completed XCTest result. The current fixture matrix has 26 jobs across both profiles, admitted through the five shared macOS slots. On the next hosted run, the `iphone-fixture-results-<shard>-<attempt>` artifacts record the per-case results. The two job timelines also include setup and result collection.

## Merge protection and release checks

As of November6, `main` requires a pull request, an up-to-date branch, resolved conversations, and the four GitHub Actions checks `CI gate`, `CodeQL (javascript-typescript)`, `CodeQL (actions)` and `Dependency review`. Admins follow the same rules; force push and deletion are disabled. Zero mandatory human approvals preserves the single-owner workflow. [Applied settings and independent verification](evidence/native/main-protection-20261106/README.md).

These are the unfiltered core/security PR gates. Path-filtered fixture, deep, performance and native-wire workflows are not directly required by branch protection: a documentation-only change can skip them. A merge passing the baseline therefore does not establish full regression acceptance.

Before distribution, run the unfiltered `Pre-release regression checks` workflow on the exact release branch head and require its `Automated release gate` to succeed. It includes all six workflow scopes, strict release metadata, full lockfile vulnerability audits and exact-commit CodeQL/open-finding checks. Source changes invalidate that candidate's release result. Actual signing, live-provider acceptance and physical/human gates remain required. The future distribution integration must enforce this boundary; this manual workflow does not itself upload or technically prevent an independent App Store upload.


The shared shard runner now implements the local option explicitly:

```sh
# Requires the existing compiled products and test-plan manifest for this shard.
# SIMULATOR_ID, TEST_SHARD and EXPECTED_TEST_COUNT must already identify that work.
LOCAL_TEST_DIAGNOSTICS=never bash scripts/run_ios_test_shard.sh
```

Default behavior stays `on-failure`. `never` is rejected before native execution
when either `CI` or `GITHUB_ACTIONS` is set. Invalid modes also fail early. The
mode is printed in the log; the original selectors, 720/900-second allowances,
full result bundle, strict checker and failure exit remain unchanged. This option
avoids verbose system capture; it does not skip XCTest evidence or make a failed
test pass. One-off local runners must record the same explicit flag in their new
command receipt; do not edit a retained run's provenance.

## Exact-run monitoring without repeated log downloads

### Performance artifact provenance

The Release build records the selected test-plan hash, the app/runner/test/share/
widget executable and Info.plist hashes and modes, plus source hashes for the
performance test, ledger fixture and scheme. The producer receipt travels inside
the existing Products archive. Each consumer verifies it before simulator setup;
missing or changed required products, plan, source or run identity fail early.
A retry may restore an earlier producer attempt from the same run and exact source,
with both attempt identities recorded. No extra macOS job or native test is added.

Compact receipts also record fixed, allowlisted instrumentation settings and
recognized library-path availability. Invoking-environment and host-library
changes are observations, not proof of the launched process environment or loaded
libraries. Unrecognized values are marked without retaining arbitrary environment
contents or absolute paths. Matching receipts do not restore missing measurements,
approve performance baselines or replace the existing strict checks.

Producer evidence is retained with the build log; consumer evidence is
`plan-provenance.json` in the existing performance artifact. Preserve the original
receipt with the first failure and inspect it before another experiment.
After successful simulator preparation, the same immutable comparison now runs
again and writes a distinct `plan-provenance-after-setup.json` before XCTest.
This preserves the original pre-setup observation and distinguishes a runtime
reference becoming available during setup from a persistent path difference.
The later receipt still observes filesystem availability, not loaded libraries.
Do not rebind a plan solely because its preboot reference was missing. Both
receipts remain in the existing artifact; no job, test or baseline rule changes.
[Observed discrepancy and limits](evidence/native/verified-performance-artifacts-20261109/README.md).

`observe_runtime_checker.py` separately observes the selected simulator runtime's
literal `libMainThreadChecker.dylib`: size, SHA256 and arm64 Mach-O UUID. The
existing capability-only scope can collect this without compilation or XCTest.
After normal consumer setup, it also binds the successful provenance receipt and
rechecks the unchanged plan hash before comparing the selected-runtime bytes
with the producer's declared checker. Both scopes retain `runtime-checker.json`
in their existing artifact. No extra job or native slot is added.

Keep three questions separate: whether the plan's declared path exists, whether
the selected runtime contains matching library bytes, and whether the test host
actually loaded that library. This observer answers only the second question;
`loadedState` stays `unknown`. The declared insertion is in the test-host
`TestingEnvironmentVariables` scope, not the UI target app's environment.
Matching bytes do not explain missing measurements or authorize plan rebinding,
checker disabling or a new performance baseline. A malformed identity or plan
binding fails the observer; a missing or different library remains an explicit
diagnostic observation requiring investigation.

### Fresh-simulator performance pilot

For the rendered and scrolling cases, the XCTest runner copies the bundled 500-item text to the simulator immediately before opening the import sheet. The Release app receives it through the system Paste button. The test compares the entire pasted string and the evidence checker verifies the saved import in SQLite. The cold-launch case skips clipboard setup. Version 1 setup receipts describe the earlier host clipboard command. Version 2 receipts verify the input file before XCTest starts.

For one controlled comparison, manually select `case=scroll`,
`fresh_performance_simulator=true`, `enforce_baselines=false`,
`capture_scroll_signposts=false` and `capture_preflight_only=false`. Linux admission
rejects other combinations before allocating Macs. The input defaults off and is
not exposed to reusable release calls; its run name and cancellation group are
separate from ordinary qualification.

Only the test consumer creates a new job-owned device of the configured runtime
and device type. The build, original scroll case, metrics and strict validators
stay unchanged; creation failure never falls back to the image device. Selection
has an eight-minute ceiling, cleanup two minutes, and existing job/test budgets
remain unchanged. Cleanup runs after exports, diagnostics and SQLite validation,
even on failure, and failures remain fatal. The performance artifact retains
`test-simulator-ownership.json`, including creation and cleanup outcomes.

Before the original XCTest command, the pilot writes a bound attempt marker. An
always-run preservation step checks the receipt's current job/owner/device/runtime,
then backs up only that owned app's synthetic ledger through a read-only SQLite
connection, including committed WAL data. `ledger-snapshot.sqlite` and
`store-preservation.json` retain its SHA-256 and outcome even when native or strict
validation fails. The collection step has a two-minute ceiling, a 90-second internal
budget, 30-second command limits and a 32 MiB store/snapshot cap. No-attempt and
no-created-device outcomes are explicit. Missing stores, ownership mismatch,
timeouts or unsuccessful preservation after an attempt remain failures and block
device deletion; cleanup requires the matching snapshot and hash. Artifact upload
still runs. An attempt marker is conservative intent, not proof XCTest started.

This probes the observed difference between successful local fresh-device runs
and hosted image-device runs. It does not establish simulator state as the cause,
approve a baseline, or replace normal coverage. Confirm the receipt's observed
runtime build matches the comparison target, inspect one result and stop before
choosing any further change.

### Qualify collectors before app diagnostics

First qualify the smallest owned emitter/collector control, separate from the
application journey. Define the expected event identity and count, selected
device/process, startup deadline, capture/output limits and cleanup deadline
before starting. Require actual readiness, a normally finalized readable artifact
and the expected events in exported data. CLI help, accepted options, a created
directory or a zero wrapper exit are insufficient. A failed control blocks app
and hosted escalation; retain its receipt and inspect the cause before changing
one input. Do not relax checkers, rewrite plans or enable private tracing flags.

The retained `performance-instruments-r1/capture-qualification.json` under
`.build/PerformanceLoadedImagesNov09/execution-r1/.build/` records a passing
original scroll test but no tracer readiness, tracer exit 1 and trace export 10
(`Document Missing Template Error`). That capture is unqualified. It establishes
neither missing app signposts nor a collector fix; do not repeat the full journey
to rediscover it.

The subsequent standalone macOS control now passes: the selected Logging
template reported readiness, recording and TOC export exited normally, and the
exported `os-signpost` table contains the exact owned helper's two boundary events
and three ordered positive intervals. Original trace bytes remained unchanged.
Evidence is under `.build/HostSignpostControlNov09/`; `validation-r1/qualification.json`
and `root-review.json` separately qualify this host control. Its initial capture
receipt remains unchanged. This is a starting point for a small simulator control,
not evidence that simulator/app collection works or that the hosted metric defect
is fixed. Do not launch another full app journey on the host result alone.

The subsequent standalone simulator control also passes readiness, normal exits
and exact exported events. [Evidence](evidence/native/simulator-collector-control-20261109/README.md)
records two preserved failures and the final bounded control. When a public CLI is
a launcher script, distinguish its invocation path/hash from the literal executable
it starts; process identity must match the latter. Keep both identities verified.
The successful control allowed thirty seconds for finalization; this does not
establish how much time it required. It is a local diagnostic setting, not a change
to hosted or application performance limits.
App-process/measurement-window coverage and hosted metrics remain unqualified.

Bind collector/helper binaries and outputs to their hashes, exact owned process
identity and runtime. Preserve original artifacts; inspect copies when tools may
modify them. Bound startup, recording, export and cleanup separately, retain
actual exits/timeouts, and verify owned-process cleanup without affecting unrelated
processes. A later app capture must additionally cover the relevant intervals;
gesture activity windows alone are not exact XCTest measurement boundaries.
Collection success remains separate from native, strict and release acceptance.

### Bounded scroll measurement diagnostic

The manual performance workflow has an optional `capture_scroll_signposts`
input, default off. It is permitted only with `case=scroll` and explicit
`enforce_baselines=false`. Linux checks reject other combinations before allocating
Macs; the wrapper independently rejects them. The run name and workflow cancellation
group distinguish this diagnostic from ordinary performance qualification. The
existing five native slots, original test command, assertions, metrics and strict
validators remain unchanged.

The wrapper checks the pinned source/toolchain/runtime, then requires a separate
signpost transport control before starting the original XCTest case. It retains
bounded metadata only, comparing live capture with persisted logs. Unsupported
capabilities, schema or a missing pre-control stop before the test; loss/caps or a
missing post-control make the diagnostic inconclusive. It does not change logging
configuration or retain raw messages. `live-signpost-diagnostic.json` records the
limits and outcome alongside the original evidence. An instrumented pass is not
an approved performance baseline or release acceptance. Run once for the written
capture question, inspect the result and stop; do not retry until green.

For a capability failure before XCTest, first use the default-off manual
`capture_preflight_only=true` with `capture_scroll_signposts=true`, `case=scroll`
and `enforce_baselines=false`. It uses the existing slot, boots the simulator and
checks the six CLI/runtime capabilities. It compiles nothing, reads no test
products, starts no log transport and invokes no XCTest. Its separate cancellation
group does not replace ordinary qualification. Success means
`capabilities_checked_not_transport`, never a performance pass.

Opted-in full captures also check these capabilities before compilation, then
repeat the guards on the actual test runner. Incremental atomic receipts retain
fixed command labels, status, exit code, elapsed time and bounded error categories;
raw command output and private payloads are not retained. An interruption may
leave a `running` stage, which is incomplete evidence. Preserve the first failure
and use the named stage to choose the next change instead of blindly extending
timeouts or rerunning unchanged. The capability artifact is
`iphone-scroll-capture-capabilities-<attempt>`; original capture/metric acceptance
requirements remain unchanged.

The collector also records ten fixed process/pipe phase offsets, a bounded
selector-return count and the largest observed loop gap. On a deadline it records
the immediate child state and makes at most one nonblocking read per pipe, capped
at8192 bytes each and sharing the remaining raw-byte budget. Only discarded-byte
counts and fixed status labels survive. These observations never enter normal
output buffers or parsers and cannot rescue the deadline failure. Use them to
distinguish slow process creation, collection delay and unread output; they do not
prove simulator readiness. Owned-process cleanup budgets remain unchanged, and
fresh post-boot device checks cannot be replaced by pre-boot data.
Device discovery now asks `simctl list devices <selected-UUID> -j` to narrow
returned rows. Its substring search is only a prefilter: exact UUID uniqueness,
availability, boot state, device type and the full runtime checks remain required.
This preserves admission; a hosted speed improvement has not been established.

Device and runtime inventory now each have a separate 30-second infrastructure
budget; version/help commands retain 10 seconds. The capability-only workflow step
allows 3 minutes to contain discovery, help and cleanup. These are bounded setup
policy limits, not performance measurements or approved app baselines. Prior
10-second failures were censored observations of a running child with empty pipes;
they do not establish a correct latency target. No retries, cached boot state,
app deadlines, runtime-warning exemptions or metric thresholds are added. If the
new bounded probe fails, preserve its stage receipt and diagnose that cause before
another dispatch. GitHub's [step timeout and concurrency syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
defines the outer workflow limits independently of the collector's commands.

For opted-in capture, the existing runner environment guard writes a fresh local
`runner-identity.json` after successful environment and applicable baseline
validation. The collector can reuse that exact version check within the same
job instead of making its fourth `xcodebuild -version` query. Bindings include
source SHA, run/attempt, job/runner, simulator, developer directory, enforcement
mode and observed architecture/version. The test consumer creates its own receipt;
it never restores one from the build job. Invalid supplied receipts fail closed.
Without a supplied receipt, the standalone direct query remains. Live simulator
and log capability checks still run. This is duplicate-work removal, not a fix or
acceptance claim for missing metrics. Receipt write time is reported separately.

### Exact-revision qualification receipt

Before scheduling the combined regression batch, create one receipt for the
immutable **tested** revision. Update it after inspecting each terminal attempt,
then check it before describing the revision as qualified:

```sh
python3 scripts/check_qualification_receipt.py --init FULL_40_CHARACTER_TESTED_SHA > .build/qualification.json
python3 scripts/check_qualification_receipt.py --receipt .build/qualification.json
```

The generated template is deliberately incomplete and defaults to `merge` scope.
The checker exits 1 for missing/unsuccessful qualification and 2 for inconsistent
or changed evidence. Exit 0 means only that the offline checklist is consistent
and complete for its declared scope. It does not fetch current branch protection,
approve a merge, or establish distribution readiness. Follow
[the release execution plan](RELEASE-EXECUTION.md) for the separate live-provider,
physical, language, accessibility and distribution requirements; the receipt
hashes that plan rather than duplicating its checklist.

The three scopes cannot substitute for one another:

| Scope | Required evidence |
| --- | --- |
| `focused` | Terminal successful diagnostic runs with exact checkout identity; supporting evidence only. |
| `merge` | PR runs supplying `CI gate`, both CodeQL language checks and `Dependency review` at the same tested revision. Live branch freshness and conversation resolution still require current GitHub review. |
| `automated_release` | The existing full `Pre-release regression checks` run and its successful `Automated release gate`; all separate release execution requirements remain. |

Reuse JSON already saved from `ci_feedback.py`; the new checker makes no API calls
and downloads nothing. Preserve the exact `run_id` and `attempt` when adding a
`runs` entry. Every file reference has this form, with paths relative to the
repository root (absolute paths are also supported):

```json
{"path": ".build/qualification/run-123-attempt-2.json", "sha256": "FULL_64_CHARACTER_FILE_SHA256"}
```

A run entry names `run_id`, `attempt`, `coverage` (one of the three scopes),
`feedback` (the saved reporter payload), `checkout_proof`, `question`, and
`change_since_prior_attempt`. The checkout proof is a small JSON identity record
with exactly these fields, transcribed from retained checkout/build provenance:

```json
{"run_id": 123, "attempt": 2, "head_sha": "FULL_40_CHARACTER_RUN_HEAD_SHA", "tested_sha": "FULL_40_CHARACTER_TESTED_SHA", "provenance": {"path": ".build/qualification/original-checkout-record.json", "sha256": "FULL_64_CHARACTER_FILE_SHA256"}}
```

For example, this `runs` entry records a focused attempt without upgrading it
to merge evidence. Replace every illustrative identity and digest with retained
values; `shasum -a 256 FILE` computes a local file digest.

```json
{
  "run_id": 123,
  "attempt": 2,
  "coverage": "focused",
  "feedback": {"path": ".build/qualification/feedback.json", "sha256": "FULL_FILE_SHA256"},
  "checkout_proof": {"path": ".build/qualification/checkout.json", "sha256": "FULL_FILE_SHA256"},
  "question": "Do both original Dinner journeys pass with the reviewed input fix?",
  "change_since_prior_attempt": "First qualification of the reviewed fix; previous failure retained separately",
  "prior_attempts": [{"path": ".build/qualification/first-failure.json", "sha256": "FULL_FILE_SHA256"}]
}
```

For PR runs, GitHub's head SHA and the checked-out merge SHA may differ. Record
both, and bind every contributing run to the same `tested_sha`; do not relabel
head-only evidence as a tested merge revision. For other events the head must
equal the tested revision. The checker verifies consistency with the saved
report and verifies the referenced original provenance file's digest. It does not
independently establish the truth of a hand-written checkout attestation: review
the linked source record. Unfilled `REPLACE:` template fields keep the checklist
incomplete. Keep the question concrete and record what changed since the prior
attempt, or state that this is its first qualification. Add prior failure file
references under `prior_attempts`; a later pass must not overwrite those bytes.
An unchanged repeat needs an explicit new diagnostic question before scheduling.

### Compact evidence for future batches

Commit the decision, source-change map, exact SHA/scope/run/attempt identities,
important readbacks, unresolved findings and digest-bound original locations.
Keep source changes in `source_changes`, separate from evidence inventory. Avoid
committing another complete source snapshot or repeated exported payload solely
to restate an existing result. This policy does not delete retained history,
rewrite commits or exclude executable evidence from security scanning.

Each contributing run needs an `originals` entry: `run_id`, `attempt`,
`retrieved_copy` (a verified local file reference), `immutable_uri`, `retention`
set to `project-lifetime`, `custodian`, and timezone-bearing
`retrieval_verified_at`. A private retained original may use an absolute local
archive path or `file:///absolute/archive/path`; the checker reads that file and
verifies the same digest, reporting it as **local-only**, not independently
archived. No external account, upload, publication or paid storage is required.
A remote URI must identify a committed blob at a full commit SHA, or a
digest-addressed archive containing the same SHA256 in its path, for example
`https://ARCHIVE_HOST/sha256/FULL_64_CHARACTER_FILE_SHA256`. Remote locations are
reported as attestations with checked local bytes, never independently fetched.
The original
should preserve the complete required raw evidence, including result bundles,
logs and inventory/provenance, not just a selected screenshot. A seven-day
Actions artifact link is not a durable original. Do not remove an existing local
or committed original merely because a receipt exists. If replacing its retained
location, first independently retrieve the proposed archive, verify its digest,
and confirm project-lifetime retention with the named custodian. The offline tool
checks the local archive/retrieved bytes and recorded attestation; it cannot
verify remote availability or a storage provider's retention promise. No archive
service or paid storage is provisioned by this workflow.

Optional `timing` on a run accepts a hash-bound `jobs` JSON reference containing
the complete `total_count`/`jobs` response and a `phase_steps` mapping. Map exact
observed step names to `setup`, `build`, `test_and_validation`, or `collection`.
For example, map `Run selected tests and verify complete execution` to
`test_and_validation`, preserving that combined work. The checker rejects
wrong run attempts, duplicate job IDs, incomplete counts and overlapping phase
assignments; it reports unmapped and untimed steps explicitly. These are sums of
whole step windows, which may overlap across jobs, not critical-path duration,
Mac runner-minutes or pure XCTest time. Reuse retained job metadata if available;
do not download another result bundle just to populate this optional table.
Use the existing reporter's execution/pre-start windows for scheduling context.

Use the read-only reporter before allocating more CI work:

```sh
python3 scripts/ci_feedback.py --run 42544579944
python3 scripts/ci_feedback.py --sha d1705d920595be12a3eb8c378f50ad04dbf65ccd
```

It reports the exact revision and attempt, all paginated jobs, failed step names,
three longest steps per job, execution time and time before starting. The latter
includes dependency/slot/scheduling delay, not just the runner queue. Repeated
failed step names are investigation leads, not a count of independent bugs.
Potential duplicate active runs share workflow, branch and SHA; compare manual
scope before cancelling anything. Active counts apply only to the requested
revision/run, not the whole repository.

Completed job summaries are cached in `.build/ci-feedback` by repository, run and
attempt; run metadata is refreshed before reuse. Live snapshots are not cached.
The reporter neither launches/retries/cancels runs nor downloads logs. Fetch the
specific failed job's log only when the summary identifies what needs inspection.
An empty revision result exits nonzero; absence of runs is not a green release.
Keep one coordinator for dispatches and one owner per independent root cause.
Batch qualified fixes for one full PR regression at the combined revision.
