# Room in the Cart — current handoff

Updated November 9, 2026. The active goal is to finish the complete first version:
Foundation 2.1's 52 requirements, 27 screen contracts and B11. It is not complete
or paused. Read [APP-BASELINE](product/APP-BASELINE.md), Foundation 2.1 and
[MASTER-GENERATION](product/MASTER-GENERATION.md) for product requirements.

This file contains current execution state. The previous 482-line history is
[preserved at ddf28659](https://github.com/palatis3/room-in-the-cart/blob/ddf28659e48a754504500b2d8fc86ab01e05b4dc/docs/CURRENT-HANDOFF.md).
[CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md) retains detailed component evidence;
[RELEASE-EXECUTION](RELEASE-EXECUTION.md) separates merge and App Store gates.

## Workspace and ownership

- Canonical checkout: `/Users/palatis/Room in the Cart`; local branch
  `codex/parallel-ios-ci`. Publish non-force to `codex/combined-candidate-20261109`.
  Verify the remote head and existing runs before dispatch. Draft PR1 is older.
  The ambient `spanish-done-diagnostic` worktree is stale.
- No Dot/Lumpy. Astra High helpers and Sol6.1 Extra High monitoring are authorized.
  Root owns integration/dispatch and the sole local native execution slot.
- The first shared-food native slice is committed at `176a8480`, its backend at
  `4f188b26`, and the latest observer correction at `ca3cf777`.
- The quote/item editor
  build and 59 strict model tests passed; one real PostgreSQL privacy/expired-quote
  case passed. Astra `astra_release_gap` owns the next request integration in scratch;
  `astra_editor_review` prepares graph-editor UI coverage in scratch. Its independent
  review found two legacy UI fixture routes missing explicit demand status; root
  corrected them and owns the sole contributor build/original S17/S26 UI attempt
  at `.build/SharedDemandNativeEditorNov09/legacy-ui-r1`. The phased-startup observer
  correction is reviewed and passes both complete 298-check profiles.
- Preserve existing untracked historical evidence. Stage named files, not all
  working-tree changes. Keep 8 GiB free; the last observation was about 167 GiB.

## Current hosted question

Focused observer run [42711707477](https://github.com/palatis3/room-in-the-cart/actions/runs/42711707477)
targets exact commit `ca3cf777c93196300bf5045b9d60a8e41315eabe`. It passed the
279-check Ubuntu planner, observer preparation and Release producer. The consumer
failed the original 120-second app-data startup deadline before selected-case
execution; runner installation began at +118.057 seconds. Root verified both ZIP
digests and all 54 consumer archive members. Local terminal state is
`.build/HostedAppObservationNov09/active-handoff.json`. No unchanged retry is pending.
A retained earlier successful journey reached fixture readiness at about +133.8
seconds, already beyond the old observer ARM deadline. The reviewed
correction uses fixed 180-second binding, 120-second fixture-to-ARM and 120-second
completion phases, with an absolute 420-second cap. Its hosted outcome is unproven.

The previous run 42707391568 passed observer typecheck and Release producer
build/upload. Its consumer's ninth app-data lookup exceeded five seconds while
runner installation was underway, about 19.55 seconds after native dispatch.
It did not establish a selected-case verdict or trace. Later export/custody errors
follow that interruption. Both diagnostic ZIPs and the consumer archive are verified.

The correction uses the remaining original 120-second startup budget only for
initial app-data discovery. Later queries retain five seconds. Live identities,
output/disk budgets, exact known-absence handling, ARM/GO order and rejection of
all signaled processes remain enforced. All 102 observer controls and both complete
279-check workflow profiles pass. No performance baseline is approved.
[Compact proof](evidence/ci/performance-dispatch-parity-20261109/README.md).

Earlier run 42639339096 passed the original scroll XCTest but lacked required
scroll-duration measurements. Its post-measure image comparison is already closed;
do not repeat those probes. The observer's question remains whether expected UIKit
intervals reach hosted collection. It is diagnostic only, not a metric substitute.

## App work and verified boundary

At the committed checkpoints above, the app builds under Xcode 27.1 and passes
45 strict native model tests plus 122 client-package tests (3 expected integration
skips). The combined backend passes 569 offline tests (1 expected DB-only skip)
and 285 PostgreSQL tests (3 optional browser skips). Localization structure and
project generation pass. These are scoped results, not final combined acceptance.
[Native proof](evidence/native/shared-food-manual-flow-20261109/README.md),
[backend proof](evidence/service/shared-demand-adoption-20261109/README.md).

The first native flow supports authoritative legacy-source adoption, exact manual
needs, explicit product/relationship review, server totals and durable retry.
Protected null-product clarification changes only that identity, preserving the
same source and all other facts. The screen has not passed an original UI journey.

The existing quote/item editor now preserves the exact reviewed candidate,
including expired-quote replacement after privacy recovery. Added lines require
explicit sources; rename/removal require review. Meal/request/protected commitments
require explicit restoration. Build and all 59 focused model checks pass, plus the
real privacy/expired-quote recovery case. Independent review found the two legacy
fixture gaps above; original-route UI acceptance remains. [Editor proof](evidence/native/shared-food-editor-20261109/README.md).

Then integrate request Add/Link and meal/proposal editing. Request review must retain
its exact `ShopperDecision`, including the generated add-line UUID; recreating that
decision changes identity. Changed meal bindings need authoritative proposed-action
sources from the server; do not duplicate protected-group enumeration in Swift.
Authenticated mixed-device F01/F02, UI/accessibility/localization review, scoped
projections and shared export/import remain open in the acceptance map.

## Other release gates

Minimum-iOS Spanish qualification still fails in XCTest's runtime-log callback.
The first null-pointer fault and exact cleanup are preserved. The direct-label
experiment also failed and is not installed. Feedback Assistant confirmed Sent
with exactly three approved attachments; transfer completion/feedback ID was not
observed. Do not resubmit or repeat an unchanged journey.
[First-fault proof](evidence/native/minimum-os-first-fault-20261109/README.md).

The static iOS 17.5 callback study identifies a record-offset-16 null load before
strcmp; it does not prove the producer/null cause or equivalence to iOS 17.0.
A separate supported hosted environment is only a feasibility candidate: exact
runtime availability and unchanged app/test artifact execution must be verified
before another journey. [Read-only host audit](evidence/ci/minimum-os-host-feasibility-20261109/README.md).
Rebuilding under another SDK is not shipping-binary
qualification. Preserve original assertions, checker settings and 720/900 limits.

Staging approval extends through migration 041. Migration 043 and intervening local
work are not deployed. A later rollout needs a concrete reviewed scope and verified
restore path. Paid Apple membership/signing, SMTP and KWS activation are owner
deferred; do not repeatedly request them. Operator: Venture House Group LLC.
Support: hello@roominthecart.com. Physical-device and App Store gates remain open.

Follow [CI-VALIDATION](CI-VALIDATION.md): one owner per cause, complete cheap profile
checks before Mac work, preserve the first failure, reuse verified products and
validate exact compiled selectors/test plans. Freeze one combined revision for
full regression and merge only after its own gates pass. Do not assemble a full
pass from unrelated revisions or weaken required measurements to make it green.
