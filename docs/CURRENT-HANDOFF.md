# Room in the Cart current handoff

Updated November 8, 2026 (local time). This file is the actionable checkpoint;
older chronology is preserved verbatim in [the November 8 archive](CURRENT-HANDOFF-HISTORY-20261108.md).
Historical running/blocked statements there do not describe current processes.

## Objective and authoritative checkout

Finish the complete first version: Foundation 2.1's 52 requirements, 27 screen
contracts and B11 acceptance. The goal is active and incomplete. Read
[APP-BASELINE](product/APP-BASELINE.md), then [CODEX-MASTER](product/foundation-gen2.1/CODEX-MASTER.md)
and [MASTER-GENERATION](product/MASTER-GENERATION.md). The requirement and route
maps remain in [CURRENT-ACCEPTANCE](CURRENT-ACCEPTANCE.md#launch-requirement-traceability).

Use `/Users/palatis/Room in the Cart`, branch `codex/parallel-ios-ci`, with an
explicit working directory. The ambient `spanish-done-diagnostic` worktree is old.
App code checkpoint before this documentation update: `e9bbff4c`.
Draft PR 1 remains a separate integration candidate; no full batch was pushed
for this focused work. Recheck remote state before publishing.

## Current execution

- Hosted billing run [42544579944](https://github.com/palatis3/room-in-the-cart/actions/runs/42544579944)
  is **terminal success**, source `d1705d920595be12a3eb8c378f50ad04dbf65ccd`.
  All seven jobs pass, including both sanitizers and both 15-scenario locale
  suites with strict verification. The shared build and final gate pass.
  Logs and terminal inventory were collected once. Do not dispatch a duplicate.
  [Billing proof](evidence/native/membership-pending-reconciliation-20261108/README.md).
- Both local dinner journeys and their inspectors are terminal. The safe-area
  followup passed native/strict with zero idle misses, but visual review still
  rejects its missing supply title. No local native job is active.
- Helper `english_keyboard_review` is preparing a two-file top-inset proposal
  against the current isolated source. No helper owns native execution or Git.
  Root must review that proposal before source changes or execution.

## Dinner candidate and next action

Canonical Dinner sources are unchanged. Isolated working source and reusable DD:
`.build/EnglishKeyboardReviewNov08/current-r1/execution-r1/{source,dd}`.
Current 561-file manifest is `.build/DinnerTopDoneSafeAreaNov08/source.json`,
SHA256 `94c871796090b737893661a45ab10117fbce1ee9c06cea48a4aab1cb7e923a5a`.
It includes the current Membership changes, unlike obsolete `8d0eb48f` inputs.

The reviewed three-file proposal moves focused Done to an owned top-content row
for dinner ideas and supply only. Manual/reusable editing retains its current
behavior. Done dismisses focus without committing, cancelling or changing values.
The original five symmetric touch samples and complete business/relaunch
assertions are retained. Draft: `.build/EnglishKeyboardReviewNov08/top-content-done-proposal-r1`.

First candidate `.build/DinnerTopDoneNov08`: build/bundle pass; complete original
English journey native0/strict0/zero idle misses, all five samples and persistence
pass. Visual review rejected the missing supply title while focused. Its row
background extended into the navigation safe area. Source/products and original
results are preserved; do not re-export or rerun that unchanged candidate.

Current followup changes only that row to
`.background(Theme.canvas, ignoresSafeAreaEdges: [])`. Source/products from the
first candidate are APFS-preserved under the followup's `preserved/` directory.
The followup's original English run and inspector are terminal: native0/strict0,
zero idle misses and all five touch/persistence checks pass. Root reviewed Yield
and Price before screenshots; the title is still absent even though the background
now respects the safe area. Do not re-export or rerun this unchanged candidate.
Background overpaint alone is not the explanation. The next distinct hypothesis
is a top safe-area inset on the Form, preserving the same Done control while
keeping the Form as primary navigation content instead of inserting a VStack
sibling. It must preserve visible titles and the original full journey.
After that correction passes, next checks are the original Spanish journey at largest Dynamic
Type on current iOS, Spanish at Large text on iOS17, and an unsigned Release
build/bundle check. The prepared runner supports those two Spanish scopes;
set/read back the intended content size and restore it afterward. Do not bypass
failed behavior or replace full integration/release acceptance with these checks.

## Other open failures and workflow

- Scroll performance: original metric cardinality4→3 failure; missing producer
  is unproven. `.build/ScrollMetricReviewNov08/README.md` is a conditional proposal,
  not permission to run interposition without review. Do not drop required metrics.
- Cook readback: standalone render-only generation reproduced framework-main
  waits before playback. That direction is rejected; no cap increase/player
  implementation is justified. One XCTest warning still lacks its required
  attachment. [Proof](evidence/native/cook-render-only-20261108/README.md).
- Broader accessibility findings, physical interaction and full combined CI remain
  open; the dinner samples are not exhaustive hit-region or accessibility proof.
- CI changes: independent contributor/dinner build dependencies; one shared billing
  compilation; focused diagnostics; five global slots; strict aggregate gates.
  [Working loop](CI-VALIDATION.md), [validation](evidence/native/ci-bottleneck-update-20261108/README.md).
  Use one coordinator, one owner per root cause, cheap checks first, exact-run
  monitoring and one full regression batch for combined qualified fixes. Collect
  artifacts once. Keep full release coverage and privacy restrictions intact.

## Environment, ownership and remaining release gates

Owned current simulator: `858A2244-001F-4BAD-AFE0-A6E7AF02F41A`, iOS26.2/23C54.
Owned minimum-OS simulator: `D420C2CA-0E73-4213-9B96-1EB62EB061F6`, iOS17.0.
Protected preview: `5FDE1E82-1FF7-4556-9C14-0746F6295944`; never reset or use it
for fixtures. Recheck owned devices before use. Local Xcode27.1 CLI27A9275;
hosted Xcode26.3 differs. Keep8GiB disk reserve and preserve original evidence.
Do not repurpose existing PostgreSQL port55432 or delete unowned resources.

Do not use Dot/Lumpy. Astra High helpers are authorized; Sol6.1 Extra High can
handle simpler delegated work. Root owns integration and hosted operations.
Operator: Venture House Group LLC; public support: hello@roominthecart.com.
Apple paid team/signing/StoreKit/TestFlight/AppStore and SMTP remain owner-deferred;
do not repeatedly ask. Epic terms accepted; real KWS activation is still separate.
Encrypted backup location and login-Keychain custody remain as authorized. Last
verified staging approval/state covers041;042 is separate. No deployment occurred
in this work. Check exact current state and approval scope before a future rollout.

Full [production/release gates](CURRENT-ACCEPTANCE.md#remaining-production-work-and-release-gates)
remain: provider verification and erasure, independent recovery/alerts, policies
and support operations, live mixed-phone household flows, human US-Spanish,
physical camera/audio/share/widgets/printing/reminders and VoiceOver/Switch Control,
signed distribution and complete route/App Store acceptance. Simulator and
synthetic-provider passes do not establish those gates.
