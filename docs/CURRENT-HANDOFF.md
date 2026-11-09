# Room in the Cart current handoff

Updated November 9, 2026. This is the active checkpoint, not a chronology.
The [complete prior checkpoint](https://github.com/palatis3/room-in-the-cart/blob/ebbbdb30c187d66da7104d34eecc0bff317e7e85/docs/CURRENT-HANDOFF.md)
is preserved at its immutable commit; its older running/status statements are historical.
Local preservation receipt: `.build/Xcode27ScrollDiagnosticNov09/handoff-cleanup/preservation.json`.

## Scope and authoritative checkout

Finish the complete first version: Foundation 2.1's 52 requirements, 27 screen
contracts and B11 acceptance. Read [APP-BASELINE](product/APP-BASELINE.md), then
[CODEX-MASTER](product/foundation-gen2.1/CODEX-MASTER.md) and
[MASTER-GENERATION](product/MASTER-GENERATION.md). The goal is active and incomplete.

Use `/Users/palatis/Room in the Cart`, branch `codex/parallel-ios-ci`, with explicit
working directories. The ambient `spanish-done-diagnostic` worktree is stale.
Publication target is `codex/combined-candidate-20261109`; before this update its
verified head was `02aaed31d77eac837ce08217fd31276f2ef9bd3e`. Recheck current Git
and run state before publishing. Draft PR1 is a separate older candidate.
No complete combined regression or merge has passed.

No Dot/Lumpy. Astra High helpers and Sol6.1 Extra High monitoring are authorized.
Root owns integration and hosted dispatch. Assign one owner per cause; never run
competing local native processes or mutate a candidate while it is executing.

## Implemented workflow policy

[CI-VALIDATION](CI-VALIDATION.md) is the working procedure:

- Resolve missing measurements before approving a new performance baseline.
- Full release source preflight now checks configured baseline compatibility
  before all native fan-out, reusing performance workflow pins. Focused
  calibration remains available; no new jobs or relaxed limits.
- Finish focused fixes, freeze one source SHA, then qualify the complete candidate.
  Full release dispatch rejects an input/event/checkout SHA mismatch before Macs.
- Preserve original failures, exact source/product/environment identities and
  strict assertions. No unchanged retries, warning suppression or reduced coverage.
- Keep the five shared native slots. Measure repeated setup, queries and scrolling
  before adding shards; the last full batch used 91.22% of five-slot capacity.
- Retain originals once; commit compact reports with verified links and hashes.
- Track merge and App Store requirements separately in [RELEASE-EXECUTION](RELEASE-EXECUTION.md).

The latest [workflow follow-through](evidence/native/workflow-policy-followthrough-20261109/README.md)
adds a compact ranking of measured pre-start delays and a selected-runtime checker
observer in existing performance scopes. It adds no jobs or native slots.
Capability-only run42625593343 now passes: the selected runtime contains exactly
the producer checker bytes. Effective test-host loading is still unobserved.
Disk currently reports about16GiB available; avoid unnecessary downloads and
duplicated raw evidence. Known local failures can reuse retained system diagnostics
while collecting fresh full test results/logs/attachments and strict validation;
see CI-VALIDATION. Final CI retains on-failure diagnostics.
All431 offline checks and workflow validation of17 native job definitions pass
for this update. The existing full-release preflight correctly rejects the still
unapproved27.1 performance profile. No new full regression was dispatched.

Primary CI is Xcode27.1/27A9275 on `xcode-27`, iPhone17 arm64, iOS27.0; observed
runtime build24A434. Swift CodeQL remains the required macOS15/Xcode26.3 exception.
The iOS17 deployment floor is unchanged. The only approved performance profile is
still Xcode26.3/17C529 with iOS26.2/23C54; it cannot approve the new environment.

## Current findings and next work

All current local/hosted attempts are terminal; no debugger or native process
remains. The original missing-stack uncertainty is resolved by a direct first-fault
capture, while one narrowly scoped query optimization failed and is not installed.

1. **Hosted performance:** capability-only run42625593343 at02aaed31 passes without
   build/XCTest. Selected iPhone17/iOS27.0/24A434 checker338880bytes exactly matches
   the earlier producer SHA1ab99e516a208f4ce91fcde55af17ee83a4aedfc9687ec1eeade456943ea32e8;
   arm64 UUIDE40A186A-8D7D-3029-B5CD-D42C967992C0. The3465-byte ZIP is digest-verified.
   [Proof](evidence/native/selected-runtime-checker-20261109/README.md).
   Earlier native42620394385 still fails required scroll duration despite1/1test
   pass and valid500/500/0/revision3 store. Matching filesystem bytes do not prove
   test-host loading or metric causation. No baseline, plan rebinding or checker
   disabling is justified. Existing screenshots prove hosted rendering; a local
   versus headless difference is unmeasured, not an established cause. Next review
   a bounded post-measure test-host loaded-image/UUID observation if it resolves the
   provenance question; preserve original metric gates and identify the changed
   diagnostic executable. Do not rerun the unchanged library probe.
2. **Local performance:** original Release launch and scroll have complete required
   metrics on27.1/iOS27.0; hitches remain unavailable. Host27.2 differs from hosted27.0.1.
   [Proof and limitations](evidence/native/local-performance-metrics-20261109/README.md).
3. **Minimum iOS:** direct r2 LLDB capture confirms EXC_BAD_ACCESS/null x0 in strcmp,
   then XCTest runtime_issue_os_log_fault_callback and libtrace logging quarantine
   during an accessibility query. Source/products were verified; capture is complete.
   Detach(False) succeeded; the untraced app retained a stop and one exact-PID
   SIGCONT completed cleanup. Debugger timing makes this diagnostic-only.
   [Full proof and cleanup](evidence/native/minimum-os-first-fault-20261109/README.md).
   Subsequent one-line containing-to-matching experiment built16.090seconds but
   full uninstrumented Spanish17.0 failed145.596seconds/native65/strict1. Xcode
   finalized naturally752.058seconds; no unchanged retry or source installation.
   No demonstrated safe logging/checker-preserving configuration remedy was found.
   An archived quarantine query returned empty JSON; its derived-only receipt is
   explicit that raw output was not retained, and cannot disprove the captured stack.
   Updated private Apple submission package is ready at
   `.build/MinimumOSXCTestReproducerNov09/apple-report-draft/reviewed-first-fault-package/`.
   Approval question is pending for only report/10KBcapture/hashes; nothing sent.
   No more query guesses, resource-pressure reruns or claim that a reduced pass
   qualifies the original journey.

4. **Fixture isolation:** Membership/Restoration corrections are installed byte-for-byte
   from the independently reviewed and natively qualified candidate. Both old-API
   controls failed as predicted; all74affected tests then passed native/strict checks
   with0warnings. At that integration,561canonical product inputs matched source manifest
   `f0706a9cd416a0fa738e973f1bbb516dc5ac3a751a8b2d2e4db395dc58ea2559`.
   [Proof and workflow follow-through](evidence/native/ci-workflow-followthrough-20261109/README.md).
5. **Optional signpost collector:** predicate-bound framing/footer and duplicate-key
   handling are corrected at ebbbdb30;64focused/378offline checks passed.
   UID501 stderr remains a qualification failure; no suppression or new transport
   acceptance. [Proof](evidence/native/scroll-capture-framing-20261109/README.md).

## Installed clarification follow-up

Clarification guidance and empty Question originally measured3.111655:1 and
1.723392:1 against the unchanged4.5:1 requirement. Baseline4 is retained accepted
negative-control proof with exactly those two failures and all behavioral controls
reached. Product candidate uses Theme.secondary and existing workingTextField,
plus a stable Question identifier. Fixture instrumentation observes every command
attempt, including rejected sends, without claiming pending-operation cancellation.
Nine compiler warning sites are corrected without changing synchronization behavior.

The clarification-qualified source is positive-r5:
`2f880895b40c37e3662f83ffedae2ae0d0f45169857f9669cdcd0f8f7a63b84f`.
Its contributor build and bundle check pass in7.061seconds. The full largest-text
light diagnostic passes93.660seconds; separate on-failure positive qualification
passes native/strict in98.699seconds. DarkAX5, lightLarge, darkLarge and original
Cancel also pass native/strict on the same source. All native processes are terminal.
All four trait captures received independent visual review with no target clipping.
Compiled inventory68contributor cases assigns the new selector once to balanced03.

Retained failures changed the next action: initial AX5 needed scrolling to
materialize the request; the guidance helper incorrectly considered background
navigation bounds; final rejected-send dismissal needed bounded request existence
search without tapping a possibly disabled row. The new test alone opts into the
foreground Review request bounds and existing fine positioning. All original
assertions, contrast thresholds and deadlines remain. Layout investigation may
omit verbose sysdiagnose per CI-VALIDATION; positive qualification/CI retain
on-failure diagnostics. Original results and strict checks remain required.
Positive-r3 testcase81.806seconds finalized normally after691.807seconds; it was
not interrupted. Positive-r4's layout investigation finalized after100.678seconds.

Positive-r2/3/4/5 source and products, including executable modes, are archived
under `.build/NativeQualificationArchivesNov09/<source-SHA>/`. Old executors are
historical. Exact records and one-time exports remain in
`.build/ClarificationContrastNov09/`. Explicit app-preference appearance tests do
not qualify system-following appearance propagation.

The ten-source-file allowlist plus planner patch is installed byte-for-byte;
canonical CoreDomain fixes are preserved. All409offline tests and17queue checks
pass after integration and the after-setup provenance workflow addition.
[Compact product proof](evidence/native/clarification-contrast-fix-20261109/README.md).
At that integration, combined native inputs had manifest
`f9d4f7717b3b19967be7f24466b36c2c31973ba14361e47f4b4c37d4ceb80ba6`;
full combined CI remains outstanding. F02 native/SQLite now passes as recorded below.
The declared reference remains missing in the prior consumer, while the latest
capability-only run proves matching bytes at its selected runtime mount. Effective
loading remains unknown. No checker disabling or baseline weakening is justified.

## Source-removal acceptance follow-up

The four reviewed files are installed: reset-only fixture variant, ordinary
FreeJourney regression, exact saved-SQLite verifier and its eight controls.
All561canonical native inputs match source manifest
`bbe56492fa0890d1705b44b8e63f805621eaf5637152735d6ffa0cc971a629fd`.
The qualified products have manifest
`780efdedff4d84bfb126d14a412c3e357addc80a16d5baf5206264fc328b372e`
and are now archived under the build-qualified subdirectory described below.
All419offline tests pass; compiled discovery740models/69UI assigns the new case
once to existingui-07. This is inventory, not a claim all cases executed.
[Compact proof](evidence/native/source-removal-journey-20261109/README.md).

Actual final execution is `.build/SourceRemovalAcceptanceNov09/native-r3/`:
- Clean Debug build/bundle pass142.079seconds.
- Full removal/Cancel/Apply/restart passes native0/strict0 in77.516seconds.
- Owned SQLite online backup and final UI IDs pass whole-document comparison:
  exactly seed/removal revisions, manual12/other dinner4/Lunch2 preserved, old
  tombstones unchanged. Snapshot SHA304ac3297f0b24862dab6a6529e411e2174c961e5c194b76a343da69f060e4b3.
- Existing receipt correction/private-pickup control passes native0/strict0 in
  57.436seconds. All result exports are complete; no native process remains.

The original native-r1 failure was a new-test label mismatch: expected12units,
actual quantity control12items. Original result/store are retained. The corrected
native-r2 passed native/strict and persisted readback; its source/products/modes
are archived under `.build/NativeQualificationArchivesNov09/bbe56492.../` before
native-r3's clean SDK correction. The r3source/products/modes are separately
cloned and verified under that source directory
`/sdk27.1-products-780efdedff4d84bf/`; never overwrite the older r2archive.
The installed CoreDomain tombstone fix previously passed all196model tests and
its original negative control. [Model proof](evidence/native/source-removal-tombstones-20261109/README.md).
Native/SQLite proof here closes only ordinary local removal; shared-device F02
and final combined regression remain separate. The helper is not wired as a
hosted SQLite gate; the UI regression joins the existing compiled inventory.

## Corrected local SDK environment and retained minimum-OS evidence

Inherited SDKROOT selected macOS27.0 in the generated dynamic package linker.
Driver probes under `.build/SDKRootDiagnosisNov09/` reproduced the warning and
wrongSDK27.0 metadata. Unsetting SDKROOT instead selectedSDK17.0. Explicit
`xcrun --sdk iphonesimulator --show-sdk-path` in the build subprocess selected27.1.
The clean r3 build verifies all five actual frameworks as
IOSSIMULATOR/minimum17.0/SDK27.1 and removes the incompatible-sysroot warning.
No Swift compiler warnings were observed. AppIntents extraction and signed
extension stripping warnings remain retained; do not claim a warning-free build.
CI-VALIDATION now documents target-scoped SDK selection for future local work.

Astra verified the five archived R4 package products used SDK27.0 and match
R4/build/products.json. The justified corrected-product qualification has now run
on iPhoneSE3/iOS17.0/21A328/D420C2CA-0E73-4213-9B96-1EB62EB061F6, Spanish es_US,
light/Large, full original selector and720/900allowances. It still fails: appPID67561
SIGSEGV11 at12:53:28.964Z, then app-not-running XCTest assertion. Source/products
and original result unchanged. The on-failure run, strict failure,159attachments,
968diagnostic files and compact positive OS events are preserved in
`.build/MinimumOSCorrectSDKNov09/r1/`. Relevant app output is110MB of AX diagnostics;
its volume alone does not prove cause. No new app stack was recovered.

Host ReportCrash logs show interrupted service connections, missing post-reporting
data and no saved app report; they do not establish a reporter crash. That uninstrumented attempt alone did not establish the earlier XCTest mechanism;
the later direct r2capture now records it on the same corrected source/products.
The first-fault capture is now complete as recorded above. Its controller r1
initially failed before attachment because monotonic origins differ across these
Python processes; preserved r2uses an epoch deadline converted to local monotonic.
All22offline controller checks pass; clocks/deadlines and API cleanup limits are
explicit. No further debugger run is justified by the same observed fault.

**Current scratch execution paths differ from canonical source.**
`.build/Xcode27WarningReviewNov09/execution-r1/source` and its sibling DD now hold
only the rejected direct-label experiment, not the qualified F02r3products.
Candidate `.build/MinimumOSDirectLabelNov09/` has source manifest
`83cb0b28776cd26cc0d6458600d76647f0abd9ba90bce391f77f38db257ac32e` and product manifest
`a666b70e53e9a97fdbfaa75000143a0818badf8e5e4fe71b40389ea6b95e932f`.
Its terminal result was inspected/exported once; source/products/original are
unchanged. Canonical FreeJourney is unchanged. Archive this failed candidate before
any further scratch mutation, or restore the separately verified r3archive with
an explicit custody receipt; never run a historical executor against successor
paths and describe it as the old source. No product change from this investigation
has been integrated.
R4/preservation/source is not exact R4 source: do not use it as such without
manifest verification. Old product hashes were independently verified.

## Installed product fixes and evidence boundaries

Combined Dinner/audio R4 is installed at e7ba6ab4. Original English and Spanish AX5
Dinner journeys pass on iOS26.2;64audio cases pass on17.0 and26.2, two affected
Dinner flows pass, and unsigned Release compiles. These are scoped local results,
not full combined hosted or physical-device acceptance.
Five fixture declaration corrections (55cases) and S24 isolation (28cases plus
actual old-API failures) are installed at ed92a993 and4bc86e26.
[Product proof](evidence/native/dinner-accessible-fields-20261109/README.md) and
[S24 custody](evidence/native/s24-fixture-isolation-20261109/README.md).

Focused hosted core42561415704 at df49 passed11jobs,717models and2Dinner journeys.
Do not rerun that unchanged focused success or treat it as current combined coverage.
Broader accessibility, physical audio routes and the framework QoS warning still
require qualification; no synthetic or screenshot sample closes those gates.

## Native custody, devices and storage

Stable source: `.build/Xcode27WarningReviewNov09/execution-r1/source`; DerivedData:
its sibling `dd`. Before the Membership successor,561source inputs had manifest
`7e9f3a6c427ff90dd2b35f56acdbd78179e1ac28ab08c459b27e89c83ac7ff7a`;
376Debug/Release products had manifest
`6053a60d6f0f953fa35633216c3892c4a8d7e921a9d7c7fef9f8f5e13c2cd419`.
Both are preserved under `.build/NativeQualificationArchivesNov09/<source-SHA>/`,
with the latest product archive at `builds/<product-SHA>/products`.
Verify complete manifests and executable modes before mutation; each successor
needs its own custody/source/product receipts. Old executors become historical.

Owned iPhone17/iOS27.0 device: `A50C91FC-4966-47FF-A8CB-7640FBD513EB` (booted; F02 native-r3 is terminal, light/Large verified). Launch-only4C01A9AC was deleted after preserving proof.
Protected preview `5FDE1E82-1FF7-4556-9C14-0746F6295944`: never reset or use for fixtures.
Owned minimum17.0 deviceD420C2CA and17.5 device9DE280AC remain available; recheck state.
Multiple26.2 runtime builds are installed, so version alone is insufficient identity.

Latest observed free storage is13.3GiB, replacing earlier41GiB readings.
Keep8GiB reserve; no SDK download is needed. Do not broadly delete evidence/caches,
repurpose PostgreSQL port55432 or remove unowned resources.

## Remaining release requirements and approval boundaries

Follow [RELEASE-EXECUTION](RELEASE-EXECUTION.md) and
[CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md#remaining-production-work-and-release-gates).
Outstanding work includes mixed-device authenticated households, actual provider
verification/erasure, independent recovery/alerts, human accessibility/localization,
physical iPhone camera/audio/share/widgets/printing/reminders, policy/support
operations, signed distribution and complete B11 route/listing acceptance.

Apple paid membership/signing and SMTP remain owner deferred; do not repeatedly
request them. Real KWS activation is separate from the prepared integration and
accepted terms. Staging approval/state is verified through041;042 requires its
separate reviewed rollout. No Apple feedback has been sent; external submission
requires explicit instruction. Preserve authorized encrypted-backup/login-Keychain
custody. Operator: Venture House Group LLC; support: hello@roominthecart.com.
