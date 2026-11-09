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
Current Dinner changes are installed locally; their exact source proof is below.
Draft PR 1 remains a separate integration candidate; no full batch was pushed
for this focused work. Recheck remote state before publishing.

## Current execution

- Hosted billing run [42544579944](https://github.com/palatis3/room-in-the-cart/actions/runs/42544579944)
  is **terminal success**, source `d1705d920595be12a3eb8c378f50ad04dbf65ccd`.
  All seven jobs pass, including both sanitizers and both 15-scenario locale
  suites with strict verification. The shared build and final gate pass.
  Logs and terminal inventory were collected once. Do not dispatch a duplicate.
  [Billing proof](evidence/native/membership-pending-reconciliation-20261108/README.md).
- Current native work: AccessibleFields R4 Spanish AX5 is active, session99626,
  xcodebuildPID27880, `.build/DinnerAccessibleFieldsNov09R4/run_spanish_ax5.py`.
  Build/bundle and all three source checks pass. Poll this same handle; no competing
  native work. R3 fixed the proven wrong-ingredient restoration and passed all5Done
  and approval, but hit720s at relaunch; native65/strict1 with zero idle misses.
  All11screens reviewed, original evidence unchanged, Large text restored.
  R4 checks upper review facts before enabled Accept, then returns toward supply;
  R3 had49gestures in that block. It keeps every assertion/gesture/time allowance.
  A wrapping full selection summary fixes the observed truncated no-match value.
  Runtime savings and final R4 visual/persistence qualification remain unproven.
  Earlier Spanish scroll R2 is
  terminal native65/strict1: all five Done probes and approval passed, followed by
  a failure recovering the lazy root/library after relaunch. Large text restored.
  The isolated retained-state root-recovery R4 probe passes native/strict checks;
  it is nonhermetic diagnostic evidence, not the original journey's acceptance.
  [Evidence](evidence/native/dinner-scroll-progress-20261109/README.md).
- The isolated product correction `.build/DinnerAccessibleFieldsNov09` adds
  wrapping ingredient labels, persistent supply labels and a full body heading.
  Build and the complete original English journey pass native/strict checks with
  zero idle misses. Root/helper reviewed all 11 English Large screenshots and
  ten geometry/target records. This is not Spanish AX5 or global visual acceptance.
  Its source manifest SHA256 is
  `7f68068a87a58630d4875a48bd9bbf40a39d8a42594d55a57a3c94523d3e1e1c`.
  Source checks and the UI automation contract pass. No product candidate changes
  are installed in the canonical app yet.
- Reused source/DD remain at `.build/EnglishKeyboardReviewNov08/current-r1/execution-r1`.
  SOURCE matches the R4 manifest
  `58e371426c6080af493d3cc38a6f063ac68c73541a5c1f5c9e7bd63ed436ee35`.
  Each prior source/product pair is verified in the next candidate preservation directory. All three exact
  source validators pass; a read-only review found no regression/assertion waiver.
  [Product candidate proof](evidence/native/dinner-accessible-fields-20261109/README.md).
- Workflow improvements at1e632421 are published on
  `codex/ci-feedback-efficiency-20261108`;274Python/workflow checks pass. No full
  PR batch was triggered. [Workflow evidence](evidence/native/ci-feedback-efficiency-20261108/README.md).

## Installed Dinner repair and next action

Three files are installed locally: DinnerEditors.swift, DinnerIdeaSupplyViews.swift
and FreeJourneyUITests.swift. The reusable source/DD paths now hold the scratch test candidate above.
The 561-file manifest `.build/DinnerInlineTitleNov08/source.json` has SHA256
`1b4696e19ef030cb754148b23eb3bd9b65f0c3f9a617c2ad9b2e99e4fde7a0b5`.
This baseline matches the installed app/test bytes and includes the Membership fix;
it is distinct from the current scratch test manifest above.
The old `8d0eb48f` native pin is obsolete.

Focused Done has its own top-content row for dinner ideas and supply, a rectangular
minimum 44-point target and 8-point vertical padding. It clears focus without
changing values, saving or cancelling. The supply screen uses a native inline
localized title. Manual/reusable editing keeps its existing behavior.

Build and Debug bundle checks pass. The original English journey passes native
and strict checks with zero idle misses, all five symmetric coordinate samples,
unknown-quantity rejection, supply approval and relaunch persistence. All ten
screens and five geometry records are reviewed. All 261 Python checks (including 20 app-configuration tests)
and generated-project validation pass. [Evidence and rejected alternatives](evidence/native/dinner-top-done-20261108/README.md).
Earlier sibling-row/background-only candidates failed visual review; top-inset
failed the Review postcondition. Their source/products/results remain preserved.
All earlier inspectors and exports are complete; do not repeat them.

Next product work: finish the same AccessibleFields R4 Spanish AX5 run and inspect
its terminal bundle once; confirm Large restoration and review screenshots.
Then qualify final English, Spanish Large on owned iOS17, and original cases
`testFreeDinnerProtectedLunchShortFillRepairSettlementAndNextShop` and
`testDinnerMoveAcrossDisplayedWeeksKeepsLunchAndOccurrence` using prepared
run_affected.py/inspect_affected.py. Run unsigned Release via run_release.py after
native tests. Source/DD remain immutable while testing. No candidate installation
or deployment yet; full combined hosted coverage is still required.

Workflow follow-up: compact failure-first monitoring and the documented feedback
loop are validated by 276 Python checks, workflow lint and live read-only billing
reporting. Shared archives already avoid recompression; no further shard changes
are justified until the next comparable full batch is measured.

## Other open failures and workflow

- N03 actual code gap: CookReadbackView/model do not subscribe to audio route changes.
  `.build/ReleaseGapCurrentNov09/route-change-proposal` r1 is rejected: blanket
  category exclusion and delayed-generation races. revision-r2 has a synchronous
  generation fence plus six notification tests, but all-category stopping still
  conflicts with own activation. It is uncompiled and NOT ready to install.
  Coordinate the two category writers (CookAudioSession/OnDeviceSpeechCapture)
  without timing/origin guesses; see revision-r2/DESIGN-REVIEW.md. No patch applied.
  This is separate from framework Cook wait/QoS evidence below.

- Scroll performance: original metric cardinality4→3 failure; missing producer
  is unproven. Read-only SQLite inspection now confirms zero archived metric rows,
  not merely an empty JSON export. [Unsubmitted addendum](evidence/native/apple-scroll-feedback-20261106/FOLLOWUP-NOV08.md).
  `.build/ScrollMetricReviewNov08/README.md` is a conditional proposal,
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
