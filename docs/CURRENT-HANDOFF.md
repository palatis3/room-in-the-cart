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
- Backend/native checkpoint: `4f5efb100a1b901d2e8e09f1f0dbe30f5a058f75`,
  published to the candidate branch. Current dispatch state is recorded in
  `.build/HostedAppObservationNov09/active-handoff.json`.
  Quote/item editor build and59 strict model tests passed; the real PostgreSQL
  privacy/expired-quote case and original S17/S26 UI journeys passed.
- Reviewed request integration, meal review and graph-editor UI are installed locally.
  Combined-r6 passed122 client-package tests (3 expected database-only skips),
  build,148 strict model tests, and both original English/Spanish editor journeys.
  Cancel no longer crashes; quote/source preservation and relaunch exact retry
  pass with one saved write. First failures and exact r6 products/results remain
  under `.build/SharedDemandNativeRequestsNov09/combined-r6`.
- Reviewed `native-meal-action-r3` adds server-exact edge trimming and explicit new
  conversion evidence after changed authoritative meal amounts. Review caught and
  corrected a missing `try` in a new test before execution. Installed
  `native-meal-action-wire-r2` adds four actual Swift HTTPS/PostgreSQL scenarios
  for catalog Cancel, protected quantification with lost-reply retry, revoked
  proposal authority, and conversion reconfirmation. No migrations/deployment.
- Combined-r7 passed client package, build,153 strict models and English UI.
  R8 corrected only the Spanish expected title and passed the full Spanish journey;
  app and model-test product bytes are identical. Original failures are retained.
  Known-direction UI searches reduced observed test-process times from316.8/300.6s
  to252.3/246.5s (EN/ES), without removing assertions or changing time limits.
  [Exact scope/hashes](evidence/native/shared-food-editor-20261109/graph-meal-r7-r8-verification.json).
- Full typed-client HTTP/PostgreSQL wire qualification r5 passes all10 Node cases
  and27 exact Swift scenarios, zero failures/skips. One fresh test build exercised
  the corrected assertions; service code was unchanged. Original r4 first failure
  remains retained. The successful database stopped and private fixture state was
  removed. [Exact proof](evidence/service/shared-demand-action-sources-20261109/native-wire-verification.json).
- Publication requires both complete performance preflight profiles in a clean
  checkout of the exact committed successor and verified remote parity before one
  changed scroll observation. Native qualification is complete within the scopes
  above; full regression, minimum-iOS and performance acceptance remain open.
- Backend `action-source-catalog-r3` is installed locally: strict compile116 offline
  controls pass. R2 passed91 actual HTTP/PostgreSQL cases; R3's affected protected
  quantification scenario passes separately. Both isolated databases stopped.
  Conversion retention and protected quantification findings are fixed without
  relaxing reducer or authorization gates. No migrations/deployment occurred.
- The complete current backend regression passes595 offline and292 PostgreSQL
  tests, with one database-only offline skip and three optional browser skips.
  All239 sources and137 compiled entries were verified; the original privacy
  journal harness fenced correctly and the database stopped. Private fixture
  state remains local in its0700 directory. No deployment occurred.
  [Exact proof](evidence/service/shared-demand-action-sources-20261109/backend-regression-verification.json).
- Hosted42728845944 passed324 early checks and Release producer, then exposed a
  five-second cutoff on initial installed-app lookup. The reviewed successor
  covers initial app and runner lookups with the original binding deadline;
  all155 observer controls pass. Complete final-commit profiles and a changed
  hosted run remain required. Sol monitors hosted work; Astra helpers prepare
  separately reviewed producer-reuse and complete-operation Undo slices.
- Preserve existing untracked historical evidence. Stage named files, not all
  working-tree changes. Keep 8 GiB free; the last observation was about 167 GiB.

## Current local successor

Reviewed backend `operation-undo-r2` is installed. The complete run passes 625
offline and 300 PostgreSQL tests, including all eight new HTTP cases, with the
same one-plus-three expected skips. All 243 sources and verified compiled products
remained unchanged. The journal harness fenced and the owned database stopped;
private fixture state remains local with 0700 permissions. Migration 044 ran only
in that fixture, never staging. [Exact proof](evidence/service/shared-food-operation-undo-20261109/README.md).

The bounded inverse covers newly recorded eligible graph/basket/pack/quote patches;
meal/request/adoption/store and other documented scopes remain unfinished. Both
directions of historical-price/quote mismatch were found and corrected in review.
Native r1 is prepared but not installed; independent review is correcting a
URLProtocol conformance and removal-versus-restoration expiry check before its
first build. A separate UI successor addresses initialization/access-change races.
Shared-record snapshot r2 is prepared with six unexecuted HTTP tests; portable
export/guardian authorization and managed recovery remain separate implementation.

Root owns integration and all native execution. No local native or database job
is currently active. Astra helpers prepare native Undo UI, independent native
review, and a separate tiny-helper hosted collector control. Sol's previous
monitoring and backend-runner preparation are complete.

## Current hosted question

Latest [42732878538](https://github.com/palatis3/room-in-the-cart/actions/runs/42732878538)
at `0cdfaa51b437af9f2e7c0aa42aae34f231384bad` is terminal failure after all 332
preflight checks and the Release producer passed. All three initial lookups
succeeded; app/runner binding completed at +66.741s and ARM at +118.702s. The
Logging collector failed to notify readiness within 15 seconds. No GO was sent;
ABORT caused the subsequent XCTest failure. No required metric or recording was
qualified. The partial result has no Info.plist and cannot be recovered as a pass.

Root verified 22 retained files, both diagnostic ZIPs and all 1,400 TAR members.
Both saved source and product copies match their declared bytes/modes. Separate
postprocessing failures applied the 128 MiB source cap to 206 MB products and
treated copied original diagnostic logs as phase stdout. Corrections are prepared
in `.build/HostedAppObservationNov09/postprocessing-r1` with 169 observer controls;
they are not installed. No unchanged full-app retry. The proposed next discriminator
is the separately labeled tiny-helper Logging/notification control on the exact
hosted environment, retaining its 15-second readiness bound and avoiding a full
Release app rebuild. Preparation is in `hosted-helper-control-r1`. Active dispatch
state remains in `.build/HostedAppObservationNov09/active-handoff.json`.

Earlier diagnostic:
Focused observer [42728845944](https://github.com/palatis3/room-in-the-cart/actions/runs/42728845944)
failed at exact `4f5efb100a1b901d2e8e09f1f0dbe30f5a058f75` after all324 early
checks, helper typecheck and Release producer passed. The original scroll XCTest
started and initial data discovery succeeded. The initial installed-app query
then hit its separate five-second cutoff with92.434 seconds left in the original
binding budget. No XCTest verdict, required metric or trace was established.
The previous same-process acquisition fault did not recur. Root verified21 files,
both ZIP digests and all77 archive members. The reviewed correction covers all
three initial container lookups within the existing180-second binding deadline;
later queries keep five seconds. No deadline, identity or metric gate is relaxed.
[First-fault and correction proof](evidence/ci/performance-dispatch-parity-20261109/initial-bundle-verification.json).
The active-handoff file records any subsequent dispatch; do not repeat unchanged4f.

Earlier diagnostic:
Focused observer [42717128576](https://github.com/palatis3/room-in-the-cart/actions/runs/42717128576)
finished with failure at exact `7a55a376349340d803e99668b54acf05b1dc5057`.
The298-check preflight, helper typecheck and Release producer passed. The tenth
container query emitted ENOENT but had neither verified process identity nor
terminal exit at the supervisor's independent two-second image-binding cutoff.
Failure occurred43.588s after native dispatch, before any180/120/120/420 phase
budget expired. Custody correctly withheld signals from that unverified process.
No selected-case verdict, trace or required duration was established. Root verified
23 retained files, both ZIPs and all54 TAR members. Evidence:
`.build/HostedAppObservationNov09/hosted-42717128576/root-verification.json`.
The diagnostic is inconclusive; no unchanged retry or baseline approval.

Previous observer run [42711707477](https://github.com/palatis3/room-in-the-cart/actions/runs/42711707477)
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
153 focused strict native model tests plus122 client-package tests (3 expected
integration skips). The current backend passes595 offline tests (1 expected
DB-only skip) and292 PostgreSQL tests (3 optional browser skips). Localization
structure and project generation pass. These are scoped results, not final
combined acceptance.
[Native proof](evidence/native/shared-food-manual-flow-20261109/README.md),
[backend proof](evidence/service/shared-demand-adoption-20261109/README.md).

The first native flow supports authoritative legacy-source adoption, exact manual
needs, explicit product/relationship review, server totals and durable retry.
Protected null-product clarification changes only that identity, preserving the
same source and all other facts. The original graph-editor UI journey now passes in both languages (r6 scope).

The existing quote/item editor now preserves the exact reviewed candidate,
including expired-quote replacement after privacy recovery. Added lines require
explicit sources; rename/removal require review. Meal/request/protected commitments
require explicit restoration. Build and all 59 focused model checks pass, plus the
real privacy/expired-quote recovery case. Independent review found the two legacy
fixture gaps above; both original legacy routes pass; r6 also qualifies the graph-editor fixture journeys. [Editor proof](evidence/native/shared-food-editor-20261109/README.md).

Request Add/Link and meal/proposal editing are installed and pass the scoped native
and complete typed-wire qualification above. Request review must retain
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
