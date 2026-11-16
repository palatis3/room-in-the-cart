# Room in the Cart — current handoff

Updated November 16, 2026, 06:00 UTC. Active goal: **finish the complete Foundation 2.1 first release**, including all 52 requirements, 27 screen contracts and B11. Not complete, paused or blocked. A scoped passing component is not one qualified release candidate.

Read [APP-BASELINE](product/APP-BASELINE.md) first, then [Foundation 2.1](product/foundation-gen2.1/README.md), [MASTER-GENERATION](product/MASTER-GENERATION.md), the requirement/screen maps in [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md), and [RELEASE-EXECUTION](RELEASE-EXECUTION.md). Historical dated component checkpoints in those documents do not supersede the current revision and results below.

## Current checkpoint

The frozen a746 cohort is terminal. Core, fixtures and deep failed; wire and security passed. The app compiled, all 1,045 model tests passed, and the unsigned iPhone Release archive passed. The remaining qualification gap is predominantly hosted simulator setup/stability, plus one locally corrected shared-meal XCTest query failure. Do not label the candidate green or merge yet.

| Scope | Original run | Proven outcome |
| --- | --- | --- |
| Core | 43798242948 | 73 planned UI cases: 34 passed, 1 keyboard-service failure, 38 never started in five runtime-setup failures. UI01 finished strict 5/5 with stable runtime. Models 1,045/1,045; Swift packages, Swift CodeQL, source, service/database, web and unsigned Release build passed. |
| Fixtures | 43798242911 | 93 planned: 41 passed, 1 shared-meal query failure, 51 never started. 26 consumers: 11 success, 15 failure. Three jobs passed app tests but failed runtime postchecks. |
| Deep | 43798242892 | Both sanitizers passed 623 cases plus 3 declared wire-only skips each. Spanish StoreKit 15/15 with stable runtime; English started zero scenarios after runtime loss. |
| Native wire | 43798242897 | Passed. |
| Security | 43798242915 | Passed. |

Original logs, hashes, inventories and receipts are retained in `.build/PR7-a746ff60/`. Core discovery artifact 14196720437 proves the exact 73 UI/1,045 model inventory; fixture expected-vs-observed reconciliation records all 93 selections. Across core and fixtures: 166 planned, 75 passed, 2 failed after starting, 89 never started. Separate diagnostic/local passes do not rewrite these original outcomes.

### Qualified local successor changes

Local development HEAD is `053f0e7b` before this documentation consolidation; the remote PR remains a746. The successor contains no production app/service/web change:

- `31179bcb`: exact iOS27 runtime deletion handling, including bounded observation of an already-Deleting registration and one validated recovery for explicit MobileAsset purge error30. Native assertions/deadlines unchanged.
- `86dab6a5`: physical image/mount/bundle observations before unchanged strict runtime checks. Missing registry metadata is still a failure.
- `ba20a3fa`: SharedMealChange XCTest reads acknowledgement from a fresh snapshot; original cancellation, application-count and outcome assertions remain. All 3 affected journeys passed locally with zero runtime warnings/restarts. Evidence `.build/SharedMealAcknowledgementNov16/`.
- `a8d33476`: check actual idle GitHub Mac concurrency groups before a one-off diagnostic. Never create a sixth group or restart an executing job for scheduling.
- `9585bcc9`: normal GitHub StoreKit setup imports the exact exported DMG and requires a standalone image, no parent, and stable physical paths. 13 helper checks, 26 workflow checks and workflow lint pass. Evidence `.build/StoreKitDirectDMGNov16/adoption-review.json`.
- `053f0e7b`: preserve bounded captured simulator-creation stderr in the ownership receipt; 14 ownership checks pass. No retry or creation behavior changes.

Full combined hosted qualification remains pending. Do not push status-only changes or repeat passing focused work unchanged.

### Runtime diagnostics and active execution

**Passed:** iOS27 recovery diagnostic `43808478043` / `133104588798`, commit `d121fa6e`, strict 8/8 original UI09 cases. Its preexisting-Deleting wait genuinely ran; exit24-response and exit30-recovery branches did not. Target, after-test and final UUID/image/mount/bundle matched. No warnings or native restarts. Largest-text import passed 112.606 seconds. Evidence `.build/GitHubRuntimeRecoveryNov16/slot2/{branch-evidence.json,original.zip}`.

**Passed:** StoreKit direct-DMG diagnostic `43809785943` / `133108636687`, commit `9f446862`, strict 15/15 English. Exact exit30 recovery ran, with one deletion retry and ten absent-asset observations. Standalone image `68326E70…` stayed Ready with no parent and stable paths; no native recovery/restarts. This supports local adoption9585bcc9. Evidence `.build/StoreKitDirectDMGNov16/slot0/{branch-evidence.json,original.zip}`.

**Active:** iOS27 exact-path diagnostic `43813499773` / `133120189839`, commit `875ce29221ffdc7ec98689be5c9b2271209b3e10`, branch `codex/ios27-direct-dmg-canary-nov16`, shared Mac slot2. It uses the original a746 produce-focus test, unchanged source/products/assertions and 720/900-second case limits. It checks actual RuntimeRoot existence and uses Apple's documented exact `.simruntime` path argument for creation. Astra reviewed it. Read `.build/IOS27DirectDMGNov16/exact-path/{review,dispatch}.json`; poll the actual run before deciding its state.

Its two predecessors `43812336286` and instrumented `43812847512` are terminal before tests. Standalone iOS27 import succeeded, but device creation returned145. The second retained the exact cause: SimError401, “runtime path not found,” despite an available runtime inventory and existing image/mount/bundle. Actual RuntimeRoot was not probed then. This does not prove stale ID resolution or unsupported DMG import. No unchanged retry, daemon restart or normal iOS27 import change is justified without the active diagnostic's evidence.

All diagnostic branches replace the normal CI workflow with manual-only experiments and **must not be merged**. Native products/source remain pinned to a746. The normal iOS27 helper still imports an exported bundle, with the reviewed deletion corrections above.

### Native failure diagnosis

Original UI03 produce-focus failed after its editor successfully displayed the keyboard. InputUI timed out its keyboard connection at05:08:03.892UTC, then forced `resignFirstResponder` before the test's original focus check. Runtime duplication/loss overlaps this event, but the complete causal chain is unproven. No app/helper edit or relaxed focus assertion is justified. Evidence `.build/ProduceFocusA746Nov16/{diagnosis.md,keyboard-timeout-excerpt.log}` and `.build/PR7-a746ff60/ui03-runtime-correlation.json`. Verify the unchanged original after runtime correction.

The SharedMealChange failure was different: its original screenshot/hierarchy already showed acknowledgement on while the live XCTest lookup stalled. The scoped snapshot correction is locally qualified as described above. Three native-pass fixture jobs still failed runtime postchecks; these are retained as failures, not false positives. The new physical observations help determine future missing-mount metadata cases without relaxing acceptance.

## Workspace and ownership

Canonical checkout: `/Users/palatis/Room in the Cart`; development branch `codex/records-import-undo`. Ambient Spanish worktree is not the authoritative checkout. Stage explicit paths; preserve unrelated `.srl`, profiling output and historical untracked evidence.

Frozen remote development and [PR7](https://github.com/palatis3/room-in-the-cart/pull/7) branch `codex/printed-list-footer`: `a746ff60d13cfae205a743a481ed9248ef559d54`. Tested merge `042d1d97f182f7f5437ac158626cede2f07cd3b8` has the same tree `1c579cedc8c604634f73ed0a06a0660f0c595461`. Last verified main is `a5d9c773f470ceebf49b703eb568736b10f0d516`. Recheck before publication/merge.

Protection requires CI gate, CodeQL JS/TS, CodeQL actions and Dependency review; strict branch freshness, admin enforcement and conversation resolution are enabled. Last review audit found no unresolved conversations. Plan-required fixtures/deep/wire qualification also remains necessary; a narrow required-check list is not complete release acceptance.

No Dot/Lumpy. Existing Sol agent `pr7_watch` monitors original GitHub logs/receipts read-only. Astra agents own only assigned nonoverlapping files; root reviews/integrates/dispatches. Other completed agents' historical “uncommitted” summaries may already be integrated. Root owns the single local native/PostgreSQL slot. No local native run is currently active.

Mac: Xcode27.1, macOS27.2. Preserve booted Preview simulator `FADCAE77-904F-4191-B29D-AE7F91789A3C`. Last free space was about3.4GiB; check before native work. Normal `.build/NativeNormal/dd/Build/Products` remain; its intermediates/module/index caches were cleared. Contributor `.build/Frozen45MealIdeaNov14/dd` remains. Original archives/results are preserved; only verified reconstructible extracts and unused caches were removed.

## Provider routing and staging

Keep `RITC_GITHUB_MAC_ONLY=true` until Bitrise actually executes. The user's requested cancellation/retry was done once: run43772341810 attempt2/job133070915940 remained queued without steps; replacement VM `vm-pool-g2-mac-m4-5c-14g-b9bb1dc-f084d6d7-4c7d` remained Warmup/Pending. A cache-off save was rejected by Bitrise permissions and discarded; no cache setting changed. Do not launch duplicate retries or infer recovery from website availability. Receipts `.build/BitriseRecoveryCanaryNov15/`.

CircleCI is not a free fallback: last verified cancellation-period plan still had automatic minimum$15 refills at2%. Check current credit/refill settings and conservative full job/storage cost before dispatch; user does not want more charges. No recent CircleCI run was started.

Last verified staging: schema049, deployment `dpl_CAz2NdsL33JHrTT6Gh8z3pAMNJM3`, rollback `dpl_CBjEXutNyvvYJbfNA8GoeJh5HBfM`. Project `prj_MsdHyy06CKCuFeAvoOCpnJRQ1vGa`, team `team_zkjaW5rtwPK9URZDeSoybwXB`. Current CI changes require no deployment. Preserve approval boundaries for later distinct staging packages.

The November16 scheduled-maintenance observation is prepared in `.build/ScheduledStagingNov16/`. During08:00–09:08UTC, run its one-shot `observe.py` about every5minutes while working until the actual scheduler request/runtime outcome is captured. No automation/daemon exists. CLI log access works with explicit project/team/deployment scope; the connector returned403. Preserve only content-free counters, requestID, timestamps/status and scheduler agent. A manual invocation or later clean worker state cannot prove the scheduled outcome.

## Development priority and next actions

1. Finish the active exact-path runtime diagnostic and inspect original artifacts. Do not equate a healthy image inventory with successful simulator creation or native execution.
2. Adopt only justified runtime correction; keep original failures and strict native/runtime gates. Do not add speculative app changes or optional test infrastructure.
3. Review the combined successor, run affected local checks and required preflight, then freeze one published candidate for the complete planned qualification. Do not mix results from different revisions into a green claim.
4. Merge only after exact-candidate requirements and protection pass. Continue the independent scheduled-maintenance observation when its real window arrives.
5. Advance the release checklist with actual signed/device/provider/human evidence. CI completion does not authorize public release.

## Remaining full-release boundaries

Preserve the complete first-release scope. Use the52requirement/27screen maps and [RELEASE-EXECUTION](RELEASE-EXECUTION.md) to reconcile each item against current evidence; older implementation notes are not proof of unfinished or finished current behavior. Outstanding release boundaries include signed TestFlight/App Store distribution and billing, actual physical iPhone features, human English/Spanish accessibility/localization review, authenticated mixed-device/provider lifecycle, operational hosted restore/alert delivery, required performance qualification/baseline approval, and real support/mailbox/policy operation.

Owner-deferred: paid Apple membership/signing, SMTP setup, KWS activation. Do not repeatedly request them. Apple signing account details stay outside public repository files. Operator: Venture House Group LLC. Support: hello@roominthecart.com. KWS integration preparation and prior terms acceptance do not constitute activation or live guardian verification. Separate StoreKit Apple-report submission was declined; keep its draft private.

Scope guard: S20/P07 cover saved pickups, notes, approvals, actual fills and unresolved outcomes; selected authorized history belongs in personal backup. They do not require an exhaustive internal event browser. S21 permits independently held exported dated copies to remain. Guardian-scoped access/export/erasure is required, while restoring consent/live authority from backup is forbidden. Do not invent remote recall or a separate guardian-recovery subsystem. E05 direct retailer connection is scheduled after this release.

## Earlier checkpoints

Historical results remain in their original evidence directories and Git history. The previous committed handoff is recoverable with `git show 053f0e7b:docs/CURRENT-HANDOFF.md`. The complete pre-consolidation text, including uncommitted checkpoint additions, is preserved locally as `.build/HandoffNov16/before-current-state-consolidation.md`; `.build/HandoffNov16/archive.json` records its SHA-256. It contains superseded active-run/branch statuses and must not be used as current state.
