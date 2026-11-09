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
verified head was `1d7f938b`. Recheck current Git
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
   No hosted work remains active in this cohort. Producer plans agree on the
   allowlisted settings. The new producer/consumer provenance gate passed409offline
   checks and17queue-node validation; its hosted consumer observation is pending.
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
   with0warnings. All561canonical product inputs match source manifest
   `f0706a9cd416a0fa738e973f1bbb516dc5ac3a751a8b2d2e4db395dc58ea2559`.
   [Proof and workflow follow-through](evidence/native/ci-workflow-followthrough-20261109/README.md).
5. **Optional signpost collector:** predicate-bound framing/footer and duplicate-key
   handling are corrected at ebbbdb30;64focused/378offline checks passed.
   UID501 stderr remains a qualification failure; no suppression or new transport
   acceptance. [Proof](evidence/native/scroll-capture-framing-20261109/README.md).

## Current isolated product follow-up

Retained clarification-screen pixels measure guidance3.11:1 and empty Question
prompt1.72:1, below the existing4.5:1 check. `.build/ClarificationContrastNov09/`
contains source-bound measurements, preserved native custody and guarded runners. A two-line style fix uses Theme.secondary
and the existing native workingTextField. Canonical product remains unchanged.
The focused test proposal also exposed a fixture blind spot: rejected clarification
attempts could leave visible posts at0. R2 adds command-attempt observation and a
rejected-send control; it remains isolated, not installed into canonical product.

Baseline1 full-contributor compilation and enumeration passed (68 contributor
cases). Its new test failed before contrast assertions: a swipe gesture area's
24-point horizontal inset incorrectly rejected a fully visible Form row at x16.
The row also includes native padding, so its frame is not a text-ink rectangle.
The 19.915-second test finalized normally after629.308seconds, including broad
failure diagnostics. Native65/strict1, screenshots, geometry and original hashes
are retained. This is a harness failure, not accepted negative contrast proof.
Source/products and executable modes were verified in
`.build/NativeQualificationArchivesNov09/5d323e329534e8c46baec7659d4af415ed5b3bec5e02278d9838e56f05178b68/`.
Baselines1–4 are terminal and their source/products/modes are archived. Baseline2
found native placeholder-vs-label identity; baseline3 found that placeholder
identity disappears after typing. R5 adds `household.decision.question` to both
original-color and styled candidates and retains exact empty-title/draft checks.

Baseline4 is accepted **negative-control proof**, not a passing app test: it
completed normally in85.628seconds with exactly the two intended native contrast
assertion failures (3.111655:1 guidance,1.723392:1 empty prompt against4.5), no
additional assertion failures, and no observed runtime warnings/restarts/idle
messages. Multiline editing and Cancel reach0fixture attempts/applied/lines; an
intentional rejected-send control reaches1attempt/0applied/0lines. Full/target
screenshots, geometry, traits and control attachments are retained; Large full
screenshots were manually reviewed for complete wording and no target clipping.
This does not prove zero local-file writes or cancel the rejected pending operation.
Receipt: `.build/ClarificationContrastNov09/baseline-r4/negative-control.json`.
Source manifest: `e078096286ceaf0806189a70808197ccf2b2767bbba16ca5aac59a9975163d83`.

All nine identified compiler warning sites are absent in the isolated candidate.
Clarification/test/fixture changes remain isolated. The CoreDomain source-removal fix below is installed and verified.

Positive1 source `77b380afdf17d90659f19fd4b94d6ade1fdba8afa131b2efc6e1ec1ad84359c5`
passed light/Large native+strict, with7.083026:1 for both targets. Dark/Large failed
its unchanged actual-palette check: API readback was dark but pixels remained
light. Preconfiguring and verifying simulator dark before XCTest also failed;
that original completed normally after638.363seconds and is retained. All three
positive1 cases are terminal, inspected once; source/products/modes are archived.
This is not a qualified dark-mode result or a proven product system-mode defect.

Reviewed `appearance-parity-r2/appearance-parity.patch` adds the ordinary app's
appearance preference path only for explicit light/dark opt-in in S24 fixture.
All assertions remain; other roots and absent-argument S24 behavior are unchanged.
Stable source is now positive2 manifest
`14215009e8ce6d6af649d1c859801eb981971d8321f492fd095d3488c39e8894`.
`positive-r2/` full contributor compilation passed in24.194seconds. Dark/Large
passes native/strict with8.295239:1 for both targets and actual dark pixels;
light/Large is executing. Finish exact-source four traits plus original Cancel,
inspect pixels/geometry, then install canonical byte-verified changes and planner
fixture count73. Positive/CI diagnostics remain on-failure. System-following
appearance propagation is not qualified by explicit app-preference tests.

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
Finish positive2 before changing the stable native profile for F02.

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

Owned iPhone17/iOS27.0 device: `A50C91FC-4966-47FF-A8CB-7640FBD513EB` (booted; positive1 is terminal, traits restored to light/Large). Launch-only4C01A9AC was deleted after preserving proof.
Protected preview `5FDE1E82-1FF7-4556-9C14-0746F6295944`: never reset or use for fixtures.
Owned minimum17.0 deviceD420C2CA and17.5 device9DE280AC remain available; recheck state.
Multiple26.2 runtime builds are installed, so version alone is insufficient identity.

Latest observed free storage is14.98GiB, replacing earlier41GiB readings.
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
