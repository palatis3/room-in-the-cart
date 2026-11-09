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
- The original Spanish dinner journey at largest Dynamic Type is **terminal failed**:
  native65/strict1, zero idle misses. Testcase193.448s, full command800.080585s.
  Accept idea was not discovered after the first successful Done and unknown-
  quantity review. Its complete result and inspection are retained under
  `.build/DinnerInlineTitleNov08/spanish-ax5`; do not rerun/export that result.
  The settings receipt confirms restoration to Large. No native run is active.
- Source/log review confirms Review succeeded and the unknown-quantity text was
  found. CTA discovery used16upward then8downward drags without scroll-progress
  evidence. Root viewed the final failure image: it shows the large-text supply
  review content, with no Accept action in the viewport. That does not establish
  the furthest scroll position or absence of the app control. Underreach remains
  plausible, not proven. All ten English screens were previously reviewed.
- Latest app commit: `556d69e5`. Workflow improvements now add a Linux release
  preflight, a local-only lighter diagnostic option and read-only exact-run CI
  reporting. All274 Python checks and workflow validation pass.
  [Workflow evidence](evidence/native/ci-feedback-efficiency-20261108/README.md).
  See [working loop](CI-VALIDATION.md). They do not qualify the failed
  Spanish scope or trigger a new full regression automatically.

## Installed Dinner repair and next action

Three files are installed locally: DinnerEditors.swift, DinnerIdeaSupplyViews.swift
and FreeJourneyUITests.swift. Isolated source and reusable DD remain at
`.build/EnglishKeyboardReviewNov08/current-r1/execution-r1/{source,dd}`.
The 561-file manifest `.build/DinnerInlineTitleNov08/source.json` has SHA256
`1b4696e19ef030cb754148b23eb3bd9b65f0c3f9a617c2ad9b2e99e4fde7a0b5`.
It matches the installed app/test bytes and includes the current Membership fix.
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

Next: classify/fix the Spanish missing-CTA failure using the retained screenshot
and scroll evidence before another native run. Keep the original business
assertions; do not blindly increase attempts or claim AX5 qualification. For the
next focused local layout experiment, use targeted diagnostics as documented in
CI-VALIDATION. Then run the original Spanish journey at Large text on owned
iOS17 (`run_native.py spanish-ios17`), followed by an unsigned Release
build/bundle check. These variants are still unproven. Preserve compatible
products before changing build profiles. Full combined hosted and release
acceptance remains required. No deployment occurred in this workflow work.

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
