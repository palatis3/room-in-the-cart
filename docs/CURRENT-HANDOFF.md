# Room in the Cart — current handoff

Updated November 17, 2026. Goal: **finish Foundation 2.1: all 52 requirements, 27 screen contracts and B11**. A passing CI batch and merge are checkpoints, not release completion.

Read [APP-BASELINE](product/APP-BASELINE.md) first, then [Foundation 2.1](product/foundation-gen2.1/README.md), [MASTER-GENERATION](product/MASTER-GENERATION.md), [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md), [RELEASE-EXECUTION](RELEASE-EXECUTION.md) and [CI-VALIDATION](CI-VALIDATION.md). Historical statements that the app is unbuilt are superseded by inspected code and results.

## Active work and ownership

Canonical checkout: `/Users/palatis/Room in the Cart`, branch `codex/records-import-undo`. PR [#7](https://github.com/palatis3/room-in-the-cart/pull/7) uses `codex/printed-list-footer`. Do not work in the old producer-wait-diagnostic checkout supplied by the desktop. Preserve unrelated untracked evidence and `default.profraw`.

Published candidate is `46e79a4ef62df3133c0664b468c18ae75a71362c`; base is `a5d9c773f470ceebf49b703eb568736b10f0d516`, actual PR merge `ec504dd642ef9b1220d7f87c6c2171a7bd03a9ee`. Current five normal runs:

| Workflow | Run |
| --- | --- |
| Core | 44025196614 |
| Fixtures | 44025196478 |
| Deep | 44025196552 |
| Native wire | 44025196467 |
| Security | 44025196586 |

Read `.build/Bal01M4Nov17/STATUS.md` and the observer's `latest.json` for live state; verify the observer process before restarting it. Keep this candidate frozen while healthy jobs finish. Security and native wire have passed; wire verified 80 Swift invocations. Thread Sanitizer failed on a test-fixture data race, so the whole candidate is not qualified. Do not retry that unchanged failure.

**Prepared successor:** `66f12aaa4968250f3b543714aeeef02464c7d6c5` in `/private/tmp/ritc-device-fixtures-nov17`, branch `codex/device-management-fixtures-nov17`. It includes DeviceManagement correction `6f6d235c` and the bounded same-cause fixture pass. Hosted job `133843715164`, artifact `14303310036`, reported a helper Boolean write racing with a URL callback read. Seventeen test files now synchronize shared state with per-install locks. No production source, selector, expected assertion, deadline or sanitizer suppression changes. No production race was established.

Astra and root cross-reviewed the patch. Full combined HouseholdClient TSan passed **250 cases with exactly three approved wire skips**, strict compiled-inventory reconciliation, no TSan warnings and unchanged source hashes. The original focused local run passed once, so no local reproduction is claimed. Evidence: `.build/DeviceManagementRaceNov17/{README.md,combined-household-thread.json,combined-source-parity.json}`. Do not repeat these unchanged local checks or start another broad audit merely to fill time.

Next: retain all terminal results and timings from 46e; include the reviewed fixture fixes and this concise handoff in one successor; fast-forward canonical and both published branches, update the PR and qualify its normal full batch. Recheck exact head/base, protection and resolved conversations before merging. Require complete core, fixtures, deep, wire and security qualification even if branch protection lists a smaller subset. No force push or protection bypass.

Root owns mutations and local native work; no local native process remains. Sol monitors the current hosted batch; Astra's bounded fixture review is complete. No Lumpy. User prefers Astra high for demanding reviews/fixes and Sol 6.1 xhigh for monitoring when useful.

## Last completed batch and runner policy

The `08c20509` batch passed 1,046 models, 74 ordinary UI cases, both 15-case StoreKit locales, sanitizers, 80 native-wire invocations and exact-merge security. Fixtures passed 25 groups / 81 of 94 cases. Balanced-01 stopped before XCTest on GitHub twice at the identical original watchOS runtime-retirement guard. Preserve both attempts; no third unchanged retry. Its exact hosted contributor artifact `14300017058` passed all 13 cases locally without rebuilding on iOS 27.0/24A434, zero runtime warnings; `.build/HostedBalanced0108cNov17/verification.json`.

The 46e routing change moves only balanced-01 to M4 slot 5, retaining all 26 groups / 94 selectors, order, profiles and GitHub-only fallback. Sixty targeted checks, strict pinned workflow lint and independent parity review passed. The assignment still needs its current hosted result. Dinner and Records moves already passed all seven cases on M4. Details and all original receipts are in `.build/CombinedCandidate08cNov17/`; `terminal-timing.json` records the 54m16s batch and final M2 UI04 job (30m38s queue / 17m41s runner).

Use useful capacity on **six M4 + three M2 Bitrise and five standard GitHub macOS runners**. All 14 overlapped in 08c; there is no need to manufacture duplicate jobs to keep them busy. Keep recovered Bitrise compilation caching enabled. On 46e, Release reused 1,727/1,727 cache blobs and archived in 16 seconds; the core producer reused 2,378/2,378 and compiled in 46 seconds. Those are observations, not whole-batch speed guarantees. Consumers restore exact products without recompiling.

After a major batch compare queue delay, setup, cache transfer, execution and the last required result. Prefer a measured redistribution or cheaper repeated interaction over adding shards. Freeze candidates during healthy work; batch diagnosed corrections, preserve first failures and do not push status-only commits. CircleCI is not a free fallback; no new paid dispatch/refill is authorized.

## Local machine and retained diagnostics

Use Xcode 27.1; no speculative toolchain switch. Preserve booted Preview simulator `FADCAE77-904F-4191-B29D-AE7F91789A3C`, installed runtimes and retained products/results. Delete only newly owned disposable simulators after collecting evidence. Prior storage cleanup is complete; AssetRounds remains online-only in Dropbox, not deleted. See `.build/StorageRecoveryNov16/`.

The Release launch sample in `.build/ReleaseLaunchThreadsNov17/` did not establish an app-code hotspot. Local iOS 27 launch and iOS 17 measurements use different runtime/device conditions; do not approve a baseline, relax thresholds or rerun unchanged solely for better numbers. Compatible performance qualification and physical lowest-device/hitch acceptance remain open.

Keep raw Records, JWS and provider payloads private. The runtime helper's original-identity checks, bounded mutation/cleanup, verified payload copy, retirement and native postchecks remain required. Unknown errors and missing results never become passes.

## Staging and remaining release work

Last verified staging: schema 049, deployment `dpl_CAz2NdsL33JHrTT6Gh8z3pAMNJM3`, rollback `dpl_CBjEXutNyvvYJbfNA8GoeJh5HBfM`; https://room-in-the-cart-staging.vercel.app. Current changes need no deployment. Preserve separate approval boundaries for distinct future staging packages. The November 16 scheduled maintenance request returned 200 with all five auth/privacy counters zero and attentionRequired=false; [receipt](evidence/b11/scheduled-maintenance-20261116/receipt.json). Do not repeat it unchanged.

After combined CI/merge: complete performance qualification, physical-iPhone capture/audio/share/widgets/print/reminders, human English/Spanish accessibility/localization, deployed authenticated mixed-device and guardian/provider lifecycle, independent hosted restore and owner alert delivery, real support/policy operation, signed distribution/billing/App Store metadata, final B11 and release authorization. Use CURRENT-ACCEPTANCE's requirement/screen maps to close each obligation; simulator and component passes cannot substitute for these checks.

**Owner deferred:** paid Apple membership/signing, SMTP and KWS activation. Do not repeatedly prompt or simulate completion. Operator: Venture House Group LLC; support: hello@roominthecart.com. Mailbox receipt/policy approval remain open. No public release authorization. Preserve the private StoreKit Apple-report draft; its submission was declined.

Scope guard: S20/P07 require permitted saved pickups, notes, approvals, actual fills and unresolved outcomes, not a new exhaustive internal event browser. S21 permits independently held exported copies to remain; do not invent remote recall. Backups must not restore consent/live authority. Direct retailer integration E05 is deferred.

## Historical evidence

The previous full handoff, including earlier run IDs, local fixes and evidence locations, is preserved [at immutable commit 46e79a4e](https://github.com/palatis3/room-in-the-cart/blob/46e79a4ef62df3133c0664b468c18ae75a71362c/docs/CURRENT-HANDOFF.md). It is historical evidence, not a current work queue. Older pre-consolidation notes remain in `.build/HandoffNov16/before-current-state-consolidation.md`. Original logs and result bundles have not been moved or removed.
