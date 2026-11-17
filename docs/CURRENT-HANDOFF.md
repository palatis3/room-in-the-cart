# Room in the Cart — current handoff

Updated November 17, 2026. Goal: **finish Foundation 2.1: all 52 requirements, 27 screen contracts and B11**. A passing CI batch and merge are checkpoints, not release completion.

Read [APP-BASELINE](product/APP-BASELINE.md) first, then [Foundation 2.1](product/foundation-gen2.1/README.md), [MASTER-GENERATION](product/MASTER-GENERATION.md), [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md), [RELEASE-EXECUTION](RELEASE-EXECUTION.md) and [CI-VALIDATION](CI-VALIDATION.md). Historical statements that the app is unbuilt are superseded by inspected code and results.

## Active work and ownership

Canonical checkout: `/Users/palatis/Room in the Cart`, branch `codex/records-import-undo`. PR [#7](https://github.com/palatis3/room-in-the-cart/pull/7) uses `codex/printed-list-footer`. Do not work in the old producer-wait-diagnostic checkout supplied by the desktop. Preserve unrelated untracked evidence and `default.profraw`.

The next combined candidate contains the reviewed fixture corrections and one Spanish fixture runner change. Its final head, base/merge identity and normal workflow IDs are maintained in `.build/CombinedFixtureFixesNov17/STATUS.md`. Keep that revision frozen while useful jobs run; inspect the actual observer process/handle before restarting monitoring.

The previous `46e79a4ef62df3133c0664b468c18ae75a71362c` batch is fully terminal. Core `44025196614`, native wire `44025196467` and security `44025196586` passed. Fixtures `44025196478` and deep `44025196552` failed for the original issues below. Exact merge `ec504dd642ef9b1220d7f87c6c2171a7bd03a9ee` has zero Swift, JavaScript/TypeScript and Actions CodeQL findings/errors/warnings. Base was `a5d9c773f470ceebf49b703eb568736b10f0d516`. Original attempts and terminal/capacity receipts remain in `.build/Bal01M4Nov17/`.

## Reviewed corrections and validation

- **HTTP fixture state:** commits `6f6d235c` and `66f12aaa` synchronize shared state in 17 test files. Hosted TSan job `133843715164` reported a test-owned helper Boolean racing with a URL callback. Full combined HouseholdClient TSan passes 250 cases with exactly three approved native-wire skips, complete compiled inventory and zero warnings. No production race was established. `.build/DeviceManagementRaceNov17/` retains originals, source hashes and review.
- **Delivery reservation transition:** `607e3b9b` waits for the existing review-sheet navigation query to disappear after Save, as the same test already does after release/removal. Original hosted job `133845458310` attempted hit testing while the sheet was dismissing. The complete corrected journey passed locally in 111.354 seconds, strict 1/1 with zero runtime warnings, on iPhone 17/iOS 27.0/24A434. `.build/DeliverySaveDismissalNov17/verification.json` retains proof; the initial zero-case wrong-profile attempt is explicitly invalid.
- **Spanish keyboard setup:** a separate local replay encountered the system's first-use bilingual keyboard card. The test now recognizes the exact title/body and uses the existing narrowly scoped Continue handling from other Spanish tests. The original Done, five-second keyboard-disappearance, typed-value and business assertions remain. The complete Spanish SavedChange and English skipped-dinner Undo journeys each pass strict 1/1 on fresh iPhone 17/iOS 27.0/24A434 simulators, with zero runtime warnings and verified cleanup. The Spanish run exercised the exact card. `.build/DeliverySaveDismissalNov17/keyboard-verification.json` retains source identity and results.
- **Spanish SavedChange runner:** GitHub job `133845457194` lost server communication after runtime preparation. No result bundle, native result or runtime artifact was produced; this is not an established app assertion failure or a pass. The unchanged selector now uses Bitrise M2 slot 0, with its original GitHub-only fallback retained. Fifty-four affected planning/workflow checks and pinned strict workflow lint pass. All 26 groups / 94 selectors, ordering, profile conditions and fallback matrix remain unchanged. Spanish execution on M2 still needs hosted qualification.

Next: qualify the normal full batch on the exact published combined head recorded in the successor status. No local native process remains. Do not retry either original failure unchanged or substitute component passes for combined qualification. Recheck current head/base, protection and resolved conversations before the authorized merge. Require full core, fixture, deep, wire and security results even if protection lists a smaller subset. No force push or protection bypass.

Root owns mutations and local native work. Astra reviewed the bounded fixes and routing; Sol retained terminal hosted results. No local native process remains; check current ownership in the scratch status before any new run. No Lumpy. Use Astra high for demanding reviews/fixes and Sol 6.1 xhigh for monitoring when useful. Do not launch another broad audit merely to occupy idle time.

## Last completed batch and runner policy

The 46e batch passed **1,046 model tests, all 74 ordinary UI cases, both 15-case StoreKit locales and 80 native-wire invocations**. Twenty-four fixture groups qualified all 89 assigned cases. The failed four-case stock group added three observed passes and one failure; the lost Spanish runner left one outcome unverified. Thus 92 fixture cases visibly passed, one failed and one has no result. This is not a full fixture pass. The M4 balanced-01 change qualified all 13 cases with zero runtime warnings; Dinner and Records qualified all seven cases too.

All five workflows finished in **58m06s**. M4 slot 4/UI02 was last: 35m15s queue, 17m09s runner, finished 06:33:36 UTC. M2 slot 0 finished 13m31s earlier, compared with 9m35s spare in the prior batch. The English equivalent SavedChange journey used 5m09s on M2; Spanish M2 duration is unproved. This supports the one-row reliability move without promising a specific whole-batch speedup. No further remap is justified by the current evidence.

Prioritize useful capacity on **six M4 + three M2 Bitrise and five standard GitHub macOS runners**. Current peak was 13; all nine Bitrise machines overlapped for 8m20s. Earlier 08c reached 14. These are observed overlaps, not a promise that all machines remain busy throughout. Do not add duplicate tests solely to fill capacity. Keep recovered Bitrise compilation caching enabled; repository variables were checked as cache=true and GitHub-only=false. Release reused 1,727/1,727 cache blobs and archived in 16 seconds; the core producer reused 2,378/2,378 and compiled in 46 seconds. Consumers restore exact products without recompiling.

After a major run compare queue delay, setup, cache transfer, execution and the last required job. Prefer measured redistribution or cheaper repeated interaction to extra shards. Batch diagnosed fixes, preserve original failures and do not push status-only commits during useful qualification. CircleCI is not a free fallback; no new paid dispatch/refill is authorized.

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
