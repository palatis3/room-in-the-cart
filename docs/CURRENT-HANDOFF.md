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
verified head was `df2dbae5d29937c58346d5eac6e55001c745567b`. Recheck current Git
and run state before publishing. Draft PR1 is a separate older candidate.
No complete combined regression or merge has passed.

No Dot/Lumpy. Astra High helpers and Sol6.1 Extra High monitoring are authorized.
Root owns integration and hosted dispatch. Assign one owner per cause; never run
competing local native processes or mutate a candidate while it is executing.

## Implemented workflow policy

[CI-VALIDATION](CI-VALIDATION.md) is the working procedure:

- Resolve missing measurements before approving a new performance baseline.
- Finish focused fixes, freeze one source SHA, then qualify the complete candidate.
  Full release dispatch rejects an input/event/checkout SHA mismatch before Macs.
- Preserve original failures, exact source/product/environment identities and
  strict assertions. No unchanged retries, warning suppression or reduced coverage.
- Keep the five shared native slots. Measure repeated setup, queries and scrolling
  before adding shards; the last full batch used 91.22% of five-slot capacity.
- Retain originals once; commit compact reports with verified links and hashes.
- Track merge and App Store requirements separately in [RELEASE-EXECUTION](RELEASE-EXECUTION.md).

Primary CI is Xcode27.1/27A9275 on `xcode-27`, iPhone17 arm64, iOS27.0; observed
runtime build24A434. Swift CodeQL remains the required macOS15/Xcode26.3 exception.
The iOS17 deployment floor is unchanged. The only approved performance profile is
still Xcode26.3/17C529 with iOS26.2/23C54; it cannot approve the new environment.

## Current findings and next work

1. **Hosted performance:** fresh-device run42598431187 at040ec583 is terminal
   failure. Native1/1 and persisted500-row pickup pass; required scroll duration
   remains absent from originalSQLite andJSON. Device/runtime identity is bound;
   preservation and owned cleanup pass. Fresh device alone did not repair it.
   [Exact result](evidence/native/fresh-performance-simulator-20261109/README.md).
   Follow-up42611979729 atd3eb3ea is terminal failure: both producer/consumer
   provenance gates pass, native1/1 passes119.078seconds, preserved store and owned
   cleanup pass, but required Scroll_DraggingAndDeceleration.duration remains
   missing. Bounded artifact review is complete under hosted-42611979729.
   [Exact outcome and timing caveat](evidence/native/verified-performance-artifacts-20261109/README.md).
   Declared checker-library reference is readable producer/missing consumer
   pre-setup; loaded-process state and postboot availability remain unknown.
   No unchanged retry. The provenance gate passed409offline checks and17queue nodes.
   [Implementation proof](evidence/native/performance-plan-provenance-20261109/README.md).
   Do not retry an unchanged native experiment.
2. **Local performance:** both original Release launch and scroll have complete
   required metrics on Xcode27.1/iOS27.0; hosted omissions are not universal removal.
   Hitches remain unavailable. Local host27.2 differs from hosted27.0.1.
   [Proof and limitations](evidence/native/local-performance-metrics-20261109/README.md).
3. **Minimum iOS:** the supply focus correction is installed. Full Spanish17.0/17.5
   journeys remain failed in XCTest's logging callback/quarantine path. A reduced
   reproducer is nonreproducing, not acceptance. Apple support ranges include the
   current configuration; reviewed release notes did not establish a remedy.
   Two preserved17.5 IPS reports also show null x0 at strcmp, with x1 resolving
   to the exact framework's `com.apple.runtime-issues` string. This does not prove
   the null's origin. No justified query-only repair was found.
   Private report and new addendum: `.build/MinimumOSXCTestReproducerNov09/apple-report-draft/`.
   User permission to submit the reviewed report to Apple is pending; nothing sent.
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

Current frozen source is positive-r5:
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
Combined native inputs have manifest
`f9d4f7717b3b19967be7f24466b36c2c31973ba14361e47f4b4c37d4ceb80ba6`;
full combined CI remains outstanding. Next local work is F02 native/SQLite below.
Next performance question is unchanged library availability after setup; the
new separate receipt is installed but not yet observed in a hosted run. No rebinding,
checker disabling or baseline weakening is justified by the preboot discrepancy.

## Source-removal acceptance follow-up

Astra's product audit identified F02/B11 native source-removal proof as incomplete.
The actual route is Dinners → All chosen dinners → chosen dinner → Preview
removing → Cancel/Apply; retained LedgerMealsView's direct button is not live.
Proposal `.build/SourceRemovalAcceptanceNov09/proposal-r1/` contains a reset-only
variant of the existing private-recovery seed, one ordinary FreeJourney case and
an exact persisted SQLite verifier. Eight pure verifier controls passed; they do
not prove runtime storage. Native/SQLite acceptance has not run. No new CI jobs.

The proposed CoreDomain regression **confirmed** a product defect: removing one
linked dinner rewrites all three older orphan-row tombstone timestamps, while
remaining quantities and IDs survive. The unchanged product failed exactly this
one assertion; zero compiler warnings. Negative source/cache/result are retained
in `.build/SourceRemovalAcceptanceNov09/model/`; source manifest
`fe942c8181726c096e6767605d9d79ed5ac35658b223ce7d10919830e7fc0228`.
The one-line fix only timestamps an empty row that has no existing tombstone.
All196CoreDomain tests now pass on complete45-input manifest
`0f6ced9125af985a3759609e99b2e1b3dbc7eae95b1de962160b6d0532e30ac9`.
The initial full run omitted two external JSON fixtures; that failed preparation
and unchanged compiled products are preserved. Corrected-input execution passed
with no warnings. Fix and regression are installed byte-verified in canonical;
[compact proof](evidence/native/source-removal-tombstones-20261109/README.md).
No model process remains active. Native F02/SQLite acceptance remains pending.
Positive-r5 custody is complete; prepare the ordinary Debug F02 profile next.

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

Owned iPhone17/iOS27.0 device: `A50C91FC-4966-47FF-A8CB-7640FBD513EB` (booted; positive-r5 is terminal, light/Large restored). Launch-only4C01A9AC was deleted after preserving proof.
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
