# Room in the Cart — current handoff

Updated November 9, 2026 (latest receipts November 10 UTC). The active goal is to finish the complete first version: Foundation 2.1's 52 requirements, 27 screen contracts and B11. It is not complete or paused. Read [APP-BASELINE](product/APP-BASELINE.md), [Foundation 2.1](product/foundation-gen2.1/README.md) and [MASTER-GENERATION](product/MASTER-GENERATION.md). Detailed acceptance and release gates remain in [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md) and [RELEASE-EXECUTION](RELEASE-EXECUTION.md).

## Workspace and ownership

- Canonical checkout: `/Users/palatis/Room in the Cart`; local branch `codex/parallel-ios-ci`. The ambient `spanish-done-diagnostic` worktree is stale.
- Publish non-force to `codex/combined-candidate-20261109`. Remote currently holds `608b3de46ffa42790a887654b3fe555ff15bcf19`; native Undo and its wire qualification are additionally committed locally at `aa32d37f` and `19cecf90`. No full combined acceptance or merge is established.
- No Dot/Lumpy. Use a few focused Astra High helpers and Sol 6.1 Extra High monitoring. Root owns integration, commits, hosted dispatch and the sole local native/database execution slot. Helpers prepare scratch changes; root reviews and installs.
- No root native/database process remains active after the successful wire run. No hosted run remains active after the helper failure. Confirm current receipts before changing this state.
- Preserve historical untracked evidence and first failures. Stage named paths only. Keep at least 8 GiB free. Original source/product/result bundles remain under `.build`; committed reports link and hash those originals.

## Current qualified slices

1. **Backend:** complete latest regression passes 639 offline tests and 306 PostgreSQL tests, including six Records and eight Undo HTTP cases. One database-only offline skip and three optional browser skips are explicit. All 246 inputs and verified compiled products matched; the journal fenced and database stopped. [Records/backend proof](evidence/service/shared-records-snapshot-20261109/README.md).
2. **Native Undo:** 133 package tests pass with three expected wire-only skips, exact inventory 136. The app builds and 167 selected native model tests pass strict checks. Original English and Spanish Undo journeys pass, including Cancel, explicit pack review, lost-response relaunch/exact retry, and later unrelated food. The test-only directional scrolling correction preserves assertions/limits; all 121 app/model product files match the model-qualified build. Original failure remains retained. [Native proof](evidence/native/shared-food-operation-undo-20261109/README.md).
3. **Real typed-client boundary:** all 11 Node cases and 33 exact Swift HTTPS/PostgreSQL scenarios pass, zero failures/skips, including six new Undo scenarios. The unchanged wrapper builds Swift once, reuses 141 backend entries from 76 identical inputs, verifies all 330 source inputs and removes successful private fixture state. PostgreSQL stopped. [Wire proof](evidence/service/shared-food-operation-undo-20261109/native-wire-verification.json).
4. **Earlier editor coverage:** request Add/Link, meal/proposal editing, quote/source preservation and the original English/Spanish food-editor journeys passed their separately scoped runs. Their 153-model and earlier 10-Node/27-Swift proofs remain historical; the expanded wire lane includes all original 27 scenarios. [Editor proof](evidence/native/shared-food-editor-20261109/README.md).

These are component results, not one final frozen release candidate. Undo currently covers newly recorded eligible graph/basket/pack/quote patches. Meal/date/proposal, request acceptance, first adoption and store inverse scopes remain unfinished. Shared Records has an authorized atomic snapshot; portable export, guardian authorization and managed recovery remain unfinished. The existing English food-source navigation title truncates and Spanish unknown-unit wording is awkward; a small reviewed copy proposal is prepared for the next UI integration.

## Current hosted question

[Standalone helper run 42741213081](https://github.com/palatis3/room-in-the-cart/actions/runs/42741213081) at exact `608b3de46ffa42790a887654b3fe555ff15bcf19` is terminal failure. All three local actual preflight profiles and the hosted planner passed 389 checks; local guards and 721-file commit parity passed. Ordinary app build/test jobs were correctly skipped.

Helper compilation, fresh simulator creation and the boot request passed. `bootstatus` exhausted the new helper's 90-second allowance before the collector started. Preservation/upload passed. Cleanup separately stopped on `helper_unbound_live_no_signal`; exact owned-device deletion is not verified. Root verified the ZIP digest, all 20 TAR members (440365 bytes/modes), and all 44 saved source pins against the hosted commit. [Proof](evidence/ci/standalone-collector-prerequisite-20261109/hosted-verification.json).

Astra is preparing a correction: align boot preparation with the existing three-minute diagnostic boot policy; retain the known migration-failure rejection; permit the same owned lifecycle query to acquire identity within its original command budget; emit compact first-fault console output. Collector readiness/recording/finalization remains 15/5/30 seconds. No unchanged retry or qualified trace is claimed. Current dispatch identity is `.build/HostedAppObservationNov09/active-handoff.json`.

The previous full-app observation [42732878538](https://github.com/palatis3/room-in-the-cart/actions/runs/42732878538) passed its Release producer and all initial lookups, but collector readiness failed before GO. No required metrics were qualified. Root verified both ZIPs and all 1400 TAR members. Separate artifact-bound corrections are committed and pass 174 observer controls. [Postprocessing proof](evidence/ci/hosted-observation-postprocessing-20261109/README.md). Earlier diagnoses remain in Git history and preserved run directories; do not repeat an unchanged expensive probe or relabel old performance baselines.

## Active preparation and next root actions

- Astra `simulator_capture_control`: isolated hosted helper correction and offline controls, scratch only.
- Astra `astra_editor_review`: complete existing-meal edit/skip/date inverse and backend tests. Scratch migration 045 is reserved; no deployment or canonical installation. Accepted proposals remain historical/consumed. Latest occurrence revisions include null tombstones; unrelated current meals/staples survive.
- Astra `astra_release_gap`: strict native meal Undo contracts, validation, model/view and EN/ES coverage against the frozen server contract; keep the earlier copy correction as a separate incremental patch. No canonical writes or native execution.
- Sol `hosted_app_observation_monitor`: completed monitoring and compact first-fault evidence; reuse when the next reviewed hosted run is dispatched.
- Root next: review prepared changes, perform appropriate cheap controls and complete actual workflow profiles at the exact committed CI successor, verify remote parity, then dispatch one changed helper diagnostic. Integrate/test the next coherent meal Undo slice independently; preserve qualified current sources/products before new compilation.

## Other release gates and authorization boundaries

Minimum-iOS Spanish qualification still fails in XCTest's runtime-log callback. The captured null-pointer fault and failed direct-label experiment remain preserved. Feedback Assistant showed Sent with three approved attachments; transfer completion/feedback ID was not observed. Do not resubmit or repeat unchanged. The separate iOS 17.5 callback study does not prove iOS 17.0 cause equivalence. [First-fault proof](evidence/native/minimum-os-first-fault-20261109/README.md), [host feasibility](evidence/ci/minimum-os-host-feasibility-20261109/README.md).

Staging approval extends only through migration 041. Local 042–044 and future 045 are not deployed. A later rollout needs a concrete reviewed scope and verified restore path. Paid Apple membership/signing, SMTP and KWS activation remain owner deferred; do not repeatedly request them. Operator: Venture House Group LLC. Support: hello@roominthecart.com.

Authenticated mixed-device paths, provider-backed lifecycle, recovery/alerts, physical-device checks, human accessibility/localization, mailbox/policy operation and signed distribution remain separate release gates. Follow [CI-VALIDATION](CI-VALIDATION.md): one owner per cause, complete cheap profiles before Mac allocation, exact selectors, preserved first failures and verified product reuse. Freeze one combined revision for full regression and merge only after its own gates pass.
