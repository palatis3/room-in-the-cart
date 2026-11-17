# Room in the Cart — current handoff

Updated November 17, 2026. Goal: **finish Foundation 2.1: all 52 requirements, 27 screen contracts and B11**. A passing CI batch and merge are checkpoints, not release completion.

Read [APP-BASELINE](product/APP-BASELINE.md) first, then [Foundation 2.1](product/foundation-gen2.1/README.md), [MASTER-GENERATION](product/MASTER-GENERATION.md), [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md), [RELEASE-EXECUTION](RELEASE-EXECUTION.md) and [CI-VALIDATION](CI-VALIDATION.md). Historical statements that the app is unbuilt are superseded by inspected code and results.

## Active work and ownership

PR [#7](https://github.com/palatis3/room-in-the-cart/pull/7) merged on November 17 at 07:49 UTC as `f17948ebea0653f4d800df6db15f5e48d08c9175`. Its tree exactly matches the fully qualified `589fb2d279fb7debbaffb343965ab380216dc62d` candidate. The canonical checkout `/Users/palatis/Room in the Cart` still holds that candidate on `codex/records-import-undo`; do not confuse its local branch with the current main ref. Preserve unrelated untracked evidence and `default.profraw`.

The postmerge main check found one intermittent accessibility audit failure. Core run `44041646744` completed in 52m18s with 1,046/1,046 model tests, 73/74 ordinary UI tests and zero runtime warnings. The only failed case is `testAutomatedAccessibilityAuditOnShopAndKnownResults`, at the scrolled comparison results. XCTest reported potentially inaccessible text without identifying an element. Swift, JavaScript/TypeScript and Actions CodeQL all passed with zero findings, errors or warnings; security run `44041646688` passed. Originals and terminal receipts remain in `.build/MainMergedNov17/`.

The unchanged hosted products passed a fresh local replay of the failing case in 86.01s, including the same initial clipped geometry. A separate alignment experiment passed but the audit still moved content by 57pt; it is not a demonstrated fix and must not be published as one. The diagnostic worktree is `/Users/palatis/.codex/worktrees/accessibility-audit-context/Room in the Cart`; scratch results, source identities and active native ownership are in `.build/MainAccessibilityNov17/STATUS.md`. Inspect that status before starting a native run. Preserve the first hosted failure. Do not filter audit categories, weaken assertions or repeat unchanged runs until green.

Root owns mutations and local native work. Astra reviews bounded changes; Sol retains hosted results and measured timing. No Lumpy. Use Astra high for demanding reviews/fixes and Sol 6.1 xhigh for monitoring when useful. No broad audit merely to occupy idle capacity. The current change improves audit attribution only; the original failure remains open until explained. The reviewed change passed the original focused case in 92.46s on a fresh iPhone 17/iOS 27.0 simulator, with all five audit activities present, exact 1,120-selector compiled inventory, zero runtime warnings and verified disposable-device cleanup. See `.build/MainAccessibilityNov17/attribution/run/verification.json`. No hosted run was started for this diagnostics-only change.

## Last completed batch and runner policy

Before merge, all five workflows on `589fb2d2` passed: core `44034014310`, fixtures `44034014301`, deep `44034014287`, native wire `44034014490` and security `44034014315`. Coverage was 1,046 model tests, 74 ordinary UI tests, 94 fixture cases across 26 groups, 30 StoreKit cases, 80 native-wire invocations, and 623 cases in each sanitizer with the three explicitly approved native-wire skips. Runtime-warning guards passed. Proof, exact analyzed merge identity and merge receipt remain in `.build/CombinedFixtureFixesNov17/`.

The full batch took 58m03s. Peak native concurrency was 13 for 46s; all nine Bitrise machines overlapped for 10m52s. This is only three seconds faster than the previous batch, not proof of a meaningful overall speedup. The Spanish fixture move to M2 qualified successfully. No further runner redistribution is justified by this measurement alone.

Prioritize useful capacity on **six M4 + three M2 Bitrise and five standard GitHub macOS runners**. Keep recovered compilation caching enabled. Producers compile once; consumers restore exact products. Do not duplicate tests just to occupy every runner. CircleCI is not a free fallback; no new paid dispatch/refill is authorized.

The postmerge main critical path was Swift CodeQL: 51m18s total, including 46m26s traced compilation and 3m analysis. The identical premerge source compiled under tracing in 33m25s. The required build already contains only the app, extensions and runtime packages, with one Swift analysis per revision. All main UI jobs finished earlier. More UI shards would not shorten this run, and no safe coverage-preserving reduction was established. Retain the supported security toolchain and uncached tracing; see `.build/MainMergedNov17/swift-codeql-efficiency.md`.

After a major run inspect queue delay, setup, transfer, execution and the last required job before changing scheduling. Batch diagnosed fixes. Avoid a full hosted run solely for logging or status edits; use affected local checks and retain diagnostics for the next justified qualification. Full release qualification must still identify one exact candidate.

## Local machine and retained diagnostics

Use Xcode 27.1; no speculative toolchain switch. Preserve booted Preview simulator `FADCAE77-904F-4191-B29D-AE7F91789A3C`, installed runtimes and retained products/results. Delete only newly owned disposable simulators after collecting evidence. Prior storage cleanup is complete; AssetRounds remains online-only in Dropbox, not deleted. See `.build/StorageRecoveryNov16/`.

The Release launch sample in `.build/ReleaseLaunchThreadsNov17/` did not establish an app-code hotspot. Local iOS 27 launch and iOS 17 measurements use different runtime/device conditions; do not approve a baseline, relax thresholds or rerun unchanged solely for better numbers. Compatible performance qualification and physical lowest-device/hitch acceptance remain open.

Keep raw Records, JWS and provider payloads private. The runtime helper's original-identity checks, bounded mutation/cleanup, verified payload copy, retirement and native postchecks remain required. Unknown errors and missing results never become passes.

## Staging and remaining release work

Last verified staging: schema 049, deployment `dpl_CAz2NdsL33JHrTT6Gh8z3pAMNJM3`, rollback `dpl_CBjEXutNyvvYJbfNA8GoeJh5HBfM`; https://room-in-the-cart-staging.vercel.app. Current changes need no deployment. Preserve separate approval boundaries for distinct future staging packages. The November 16 scheduled maintenance request returned 200 with all five auth/privacy counters zero and attentionRequired=false; [receipt](evidence/b11/scheduled-maintenance-20261116/receipt.json). Do not repeat it unchanged.

Remaining after merge: resolve the open accessibility finding and complete performance qualification, physical-iPhone capture/audio/share/widgets/print/reminders, human English/Spanish accessibility/localization, deployed authenticated mixed-device and guardian/provider lifecycle, independent hosted restore and owner alert delivery, real support/policy operation, signed distribution/billing/App Store metadata, final B11 and release authorization. Use CURRENT-ACCEPTANCE's requirement/screen maps to close each obligation; simulator and component passes cannot substitute for these checks.

**Owner deferred:** paid Apple membership/signing, SMTP and KWS activation. Do not repeatedly prompt or simulate completion. Operator: Venture House Group LLC; support: hello@roominthecart.com. Mailbox receipt/policy approval remain open. No public release authorization. Preserve the private StoreKit Apple-report draft; its submission was declined.

Scope guard: S20/P07 require permitted saved pickups, notes, approvals, actual fills and unresolved outcomes, not a new exhaustive internal event browser. S21 permits independently held exported copies to remain; do not invent remote recall. Backups must not restore consent/live authority. Direct retailer integration E05 is deferred.

## Historical evidence

The previous full handoff, including the reviewed fixture fixes, earlier runs and evidence locations, is preserved [at merged commit f17948eb](https://github.com/palatis3/room-in-the-cart/blob/f17948ebea0653f4d800df6db15f5e48d08c9175/docs/CURRENT-HANDOFF.md). It is historical evidence, not a current work queue. Older pre-consolidation notes remain in `.build/HandoffNov16/before-current-state-consolidation.md`. Original logs and result bundles have not been moved or removed.
