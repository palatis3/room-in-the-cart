# Room in the Cart — current handoff

Updated November 9, 2026 (latest receipts November 10 UTC). The active goal is to finish the complete first version: Foundation 2.1's 52 requirements, 27 screen contracts and B11. It is not complete or paused. Read [APP-BASELINE](product/APP-BASELINE.md), [Foundation 2.1](product/foundation-gen2.1/README.md) and [MASTER-GENERATION](product/MASTER-GENERATION.md). Detailed acceptance and release gates remain in [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md) and [RELEASE-EXECUTION](RELEASE-EXECUTION.md).

## Workspace and ownership

- Canonical checkout: `/Users/palatis/Room in the Cart`; local branch `codex/parallel-ios-ci`. The ambient `spanish-done-diagnostic` worktree is stale.
- Publish non-force to `codex/combined-candidate-20261109`. Remote currently holds `759ee5ab80099b0ff02e259c614acfae882a4ee4`; the qualified meal Undo backend is additionally committed locally at `6c7d834e`. No full combined acceptance or merge is established.
- No Dot/Lumpy. Use a few focused Astra High helpers and Sol 6.1 Extra High monitoring. Root owns integration, commits, hosted dispatch and the sole local native/database execution slot. Helpers prepare scratch changes; root reviews and installs.
- The native meal package passed 141 tests plus three expected skips (144 compiled). Root gracefully stopped its superseded build before model/UI execution after review found a mixed-letter UUID Codable roundtrip inconsistency. A narrow encoder correction and new regression are in preparation; no native/database process is active. The meal backend database stopped cleanly. No hosted run remains active. Confirm current receipts before changing this state.
- Preserve historical untracked evidence and first failures. Stage named paths only. Keep at least 8 GiB free. Original source/product/result bundles remain under `.build`; committed reports link and hash those originals.

## Current qualified slices

1. **Backend:** the meal Undo successor passes 650 offline and 315 PostgreSQL tests, including eleven new pure and nine new meal HTTP cases plus all eight prior Undo and six Records cases. One database-only offline skip and three optional browser skips remain explicit. Strict compiled products and all 251 inputs matched; the journal fenced and database stopped. Both fixture-only failed attempts are preserved. [Meal/backend proof](evidence/service/shared-food-meal-undo-20261109/README.md).
2. **Native Undo:** 133 package tests pass with three expected wire-only skips, exact inventory 136. The app builds and 167 selected native model tests pass strict checks. Original English and Spanish Undo journeys pass, including Cancel, explicit pack review, lost-response relaunch/exact retry, and later unrelated food. The test-only directional scrolling correction preserves assertions/limits; all 121 app/model product files match the model-qualified build. Original failure remains retained. [Native proof](evidence/native/shared-food-operation-undo-20261109/README.md).
3. **Real typed-client boundary:** all 11 Node cases and 33 exact Swift HTTPS/PostgreSQL scenarios pass, zero failures/skips, including six new Undo scenarios. The unchanged wrapper builds Swift once, reuses 141 backend entries from 76 identical inputs, verifies all 330 source inputs and removes successful private fixture state. PostgreSQL stopped. [Wire proof](evidence/service/shared-food-operation-undo-20261109/native-wire-verification.json).
4. **Earlier editor coverage:** request Add/Link, meal/proposal editing, quote/source preservation and the original English/Spanish food-editor journeys passed their separately scoped runs. Their 153-model and earlier 10-Node/27-Swift proofs remain historical; the expanded wire lane includes all original 27 scenarios. [Editor proof](evidence/native/shared-food-editor-20261109/README.md).

These are component results, not one final frozen release candidate. The backend now supports eligible recorded meal edits, dates, accepted proposals and skipped occurrences. The matching native meal/copy changes are installed and under qualification; prior native/wire proofs do not qualify them. Request acceptance, first adoption and store inverse scopes remain unfinished. Shared Records has an authorized atomic snapshot; portable export, guardian authorization and managed recovery remain unfinished.

## Current hosted question

[Latest helper run 42744325450](https://github.com/palatis3/room-in-the-cart/actions/runs/42744325450) at exact `759ee5ab80099b0ff02e259c614acfae882a4ee4` is terminal failure. All 426 hosted controls passed; ordinary app jobs were correctly skipped. The bootstatus command exited normally after 117.6 seconds, but the subsequent full simulator inventory exceeded its 30-second command budget. Exact process binding was established; this was not the prior acquisition failure. Archive/upload and verified owned-device deletion passed. Root verified the ZIP, all 22 TAR members and all 50 saved source pins. [Verification](evidence/ci/standalone-collector-prerequisite-20261109/hosted-42744325450-verification.json).

Astra prepared and root installed a narrower post-boot inventory: fresh runtimes plus the exact owned UUID, sharing the same absolute 30-second budget. Full creation inventory and all current-device checks remain. All 75 focused controls pass. Its efficiency on the hosted service is an unqualified hypothesis, not an established fix. Collector readiness/recording/finalization remains 15/5/30 seconds. Current dispatch identity is `.build/HostedAppObservationNov09/active-handoff.json`.

The earlier [42741213081](https://github.com/palatis3/room-in-the-cart/actions/runs/42741213081) failed the former 90-second bootstatus allowance and did not verify cleanup. Its originals and [proof](evidence/ci/standalone-collector-prerequisite-20261109/hosted-verification.json) remain intact.

The previous full-app observation [42732878538](https://github.com/palatis3/room-in-the-cart/actions/runs/42732878538) passed its Release producer and all initial lookups, but collector readiness failed before GO. No required metrics were qualified. Root verified both ZIPs and all 1400 TAR members. Separate artifact-bound corrections are committed and pass 174 observer controls. [Postprocessing proof](evidence/ci/hosted-observation-postprocessing-20261109/README.md). Earlier diagnoses remain in Git history and preserved run directories; do not repeat an unchanged expensive probe or relabel old performance baselines.

## Active preparation and next root actions

- Astra `simulator_capture_control`: narrow hosted inventory optimization and controls, scratch only.
- Astra `astra_editor_review`: real Swift/HTTPS/PostgreSQL meal Undo extension covering accepted proposal provenance, grouped protected reservations, skipped meals, durable retry and privacy. Preserve the original 11 Node/33 Swift lane.
- Astra `astra_release_gap`: strict Undo encoder correction and mixed-letter regression; prepare a revised native qualification after root review. No canonical writes or native execution.
- Sol `hosted_app_observation_monitor`: completed monitoring; reuse when the next reviewed hosted run is dispatched.
- Root: finish current native qualification and visual review, register newly discovered package selectors, then run the extended real wire lane. Separately review the helper successor, complete exact workflow preflights and dispatch one changed diagnostic. Do not run local native/database lanes concurrently.

## Other release gates and authorization boundaries

Minimum-iOS Spanish qualification still fails in XCTest's runtime-log callback. The captured null-pointer fault and failed direct-label experiment remain preserved. Feedback Assistant showed Sent with three approved attachments; transfer completion/feedback ID was not observed. Do not resubmit or repeat unchanged. The separate iOS 17.5 callback study does not prove iOS 17.0 cause equivalence. [First-fault proof](evidence/native/minimum-os-first-fault-20261109/README.md), [host feasibility](evidence/ci/minimum-os-host-feasibility-20261109/README.md).

Staging approval extends only through migration 041. Local 042–045 are not deployed. A later rollout needs a concrete reviewed scope and verified restore path. Paid Apple membership/signing, SMTP and KWS activation remain owner deferred; do not repeatedly request them. Operator: Venture House Group LLC. Support: hello@roominthecart.com.

Authenticated mixed-device paths, provider-backed lifecycle, recovery/alerts, physical-device checks, human accessibility/localization, mailbox/policy operation and signed distribution remain separate release gates. Follow [CI-VALIDATION](CI-VALIDATION.md): one owner per cause, complete cheap profiles before Mac allocation, exact selectors, preserved first failures and verified product reuse. Freeze one combined revision for full regression and merge only after its own gates pass.
