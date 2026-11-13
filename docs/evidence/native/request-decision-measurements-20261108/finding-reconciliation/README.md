# S24: individual reconciliation of the original36 findings

This is an evidence disposition, not an audit waiver. No finding is marked audit-closed. Current source reviewed at 97c9ef9828d840f81b2065594e6ab4d0b621833d. No product defect is established by the remaining audit records after the source/capture review. No native/simulator command, product edit or style change was performed.

## What has materially advanced

- **9 Dynamic Type findings have exact current semantic-target captures at Small/Large/AX5:** #3,4,8,9,10,11,12,22,27. The missing exact-target rendered evidence is supplied; no more screenshot-only qualification is needed before re-auditing. Cancel is complete but its expected framework scaling curve remains unproven. #10 is the current replacement disclosure control, not the original raw node.
- **2 contrast findings now have properly attributed exact captures:** #34,35. The old Review decision screenshot missed its glyphs; the new captures fix that evidence gap. Contrast estimates alone do not resolve XCTest failures.
- **4 title/date findings have existing exact AX5 wrapping tests:** #1,5,13,23. No new title/date test is needed before re-audit. **#33** also has prior exact-heading visual completeness evidence; it is a separate clipping-audit question.
- **16 findings are attributable but lack isolated current-target measurements:** #2,7,14,15,16,17,18,19,20,24,25,26,28,29,30,32. Their source/ancestry and contextual or older evidence are preserved; do not count sibling amount crops as label measurements. Re-audit first rather than measure all16 speculatively.
- **4 remain unattributed:** #6,21,31,36. Original reports literally contain no public element. None is assigned to a guessed icon/control.

The fixture has ten distinct measured semantic targets across three sizes (30 groups), which reconcile eleven finding records because Review before applying appears in two issue categories. The evidence inventory does not represent thirty distinct controls. Original21 groups use the qualified measurement-final evidence; additional9 use the completed additional-control R2 evidence. All120 referenced attachment hashes were verified file-only.

## Identity corrections worth retaining

Original hierarchy resolves duplicate public text: #15/#20 are Mia’s Protected portions/value1; #28/#19 are Sam’s. #18 is the Whole checkout value under Cap scope; #25 is the value under Scope. These are separate findings, not duplicates to drop. #22 is the preview heading, not the Outcome picker child; R1 Small failure and r2 structural selector correction remain preserved.

The retained original-audit source snapshot differs from current code only in the reviewed disclosure-style additions in HouseholdInboxView.swift/Theme.swift among the affected views. Current Checkout calculation details uses LabeledFormDisclosureStyle with an explicit full-row44pt button, identifier and accessible expansion value; original report10 is a text child under the older framework button. The source diff is retained. HouseholdRequestMealContext.swift is byte-identical. This is a reason to audit the actual current control, not to carry forward or dismiss an obsolete-node classification.

## Per-finding ledger

Full exact attributes, original report hash, current source path/line/hash, capture references and remaining acceptance are in findings.json; findings.csv is the compact machine-readable version. capture-pins.json binds every crop/screen/metric/ancestry file to its target and category.

| # | Original target | Disposition |
|---|---|---|
| 1 | Sam’s wrap lunch | prior-exact-target-wrapping-test |
| 2 | After this decision | attributed-context-not-isolated |
| 3 | $38.00 | current-exact-target-rendering |
| 4 | $3.49 | current-exact-target-rendering |
| 5 | Lunch · November 5, 2026 | prior-exact-target-wrapping-test |
| 6 | UNATTRIBUTED | unattributed |
| 7 | Before this decision | attributed-context-not-isolated |
| 8 | $40.69 | current-exact-target-rendering |
| 9 | $37.20 | current-exact-target-rendering |
| 10 | Checkout calculation details | current-exact-target-rendering |
| 11 | Cancel | current-exact-target-rendering |
| 12 | $2.69 | current-exact-target-rendering |
| 13 | Mia’s wrap lunch | prior-exact-target-wrapping-test |
| 14 | Cap scope | attributed-context-not-isolated |
| 15 | Protected portions | attributed-context-not-isolated |
| 16 | Cap | attributed-context-not-isolated |
| 17 | Scope | attributed-context-not-isolated |
| 18 | Whole checkout | attributed-context-not-isolated |
| 19 | 1 | attributed-context-not-isolated |
| 20 | 1 | attributed-context-not-isolated |
| 21 | UNATTRIBUTED | unattributed |
| 22 | Add packs to this shop | current-exact-target-rendering |
| 23 | Lunch · November 4, 2026 | prior-exact-target-wrapping-test |
| 24 | Over cap | attributed-context-not-isolated |
| 25 | Whole checkout | attributed-context-not-isolated |
| 26 | Cost change | attributed-context-not-isolated |
| 27 | Review before applying | current-exact-target-rendering |
| 28 | Protected portions | attributed-context-not-isolated |
| 29 | Protected meal commitments | attributed-context-not-isolated |
| 30 | Check usable food separately; this review does not confirm meal coverage. | attributed-context-not-isolated |
| 31 | UNATTRIBUTED | unattributed |
| 32 | Expected total | attributed-context-not-isolated |
| 33 | Protected meal commitments | prior-exact-heading-visual |
| 34 | Review decision | current-exact-target-contrast-open |
| 35 | Review before applying | current-exact-target-contrast-open |
| 36 | UNATTRIBUTED | unattributed |

## Next useful action: one current-product unfiltered audit

Use the existing checked-in **diagnostics/request-review-accessibility/unfiltered-review.patch** on an isolated archive of the current reviewed HEAD. This is smaller and more decisive than another measurement overlay. Run exactly **RoomInTheCartUITests/HouseholdRequestPackUITests/testCerealCheckoutAndTwoProtectedLunchesAreVisibleTogetherAndCancelDoesNotWrite**. Do not run the three measurement selectors for this step. No new test suite or styling change is proposed.

The unchanged journey opens the synthetic request fixture, reviews one cereal pack, and reaches the original audit boundary immediately after the simultaneous checkout/two-lunch viewport capture. State: before37.20, after40.69, cap38, over2.69, Sam/Mia dated protected lunches, no applied decision or saved line. The patch calls unfiltered app.performAccessibilityAudit, attaches detailed description plus public element hierarchy, and **returns false for every issue**. Keep all existing contrast/cancellation/zero-write/access-ended assertions and their original timeouts. Do not add an issue allowlist, expected-failure declaration or audit-type exclusion.

Build: RoomInTheCart scheme, Debug, arm64 simulator, CODE_SIGN_IDENTITY=-; conditions exactly **DEBUG CONTRIBUTOR_CAPTURE_UI_FIXTURE STOCK_REVIEW_UI_FIXTURE AWAY_CARRYOVER_UI_FIXTURE** (verify against current fixture planner and both targets). Serial testing, jobs2, fresh source/DD/result/log. Use the established run guard8GiB/no-active-xcodebuild and720/900 allowances without retries; the original normal.zsh did not explicitly supply those allowances, so record this current execution guard rather than claiming byte-identical original argv. No new runner is prepared here.

Original state/identity supported by retained files: English/en_US, light appearance, starting system Large, Xcode27.1/27A9275, iOS26.2 build23C54. The old normal.zsh actually targeted **07E34CE9-E86C-456F-8682-0D6BE4E53E7D**. Adjacent grouped-normal native summary identifies **iPhone17 Pro**, although older prose calls it iPhone17; the old command/resize receipts restore Large. A contemporaneous exact increased-contrast settings receipt for the unfiltered action was not found. Preserve that uncertainty. Before a future run, root records actual booted runtime root/version/build, model, dimensions, appearance, content size and contrast. If root uses the currently owned4C7F device instead of the original07E device, label it a current-product qualification on the recorded model, not an exact-device replay. Do not use the currently busy iOS17 SE lane as a proxy for this26.2 audit. No simulator acquisition/boot/state change is authorized or performed by this ledger.

After the native lane releases and root reviews a concrete run package: retain native exit, one exact case start/completion and raw audit failures; copy/hash the completed result before any tool reads, then run strict case/warning verification and export all issue descriptions/screenshots. Correlate by issue category + exact parent/child identity, not ordinal alone, because ordering/count may change. Preserve new issues as well as disappearances. A fresh audit with any reported issue remains failing; a zero-issue current audit supports only its recorded surface/environment and is not physical VoiceOver acceptance.

If element=nil persists for any of the four unattributed classes, stop at that explicit attribution gap. A separately reviewed minimal diagnostic could record a bounded issue ordinal/type plus issue-time screenshot/full hierarchy when element is nil, still returning false and changing no product. That is a follow-up only if current audit output still cannot attribute the failure; do not start another broad instrumentation framework.

This next action tests whether historical classifications still apply to current controls and yields actionable current targets. It cannot be replaced by stock-control similarity, screenshot contrast ratios, or an assumption that existing source modifiers guarantee every intermediate Dynamic Type category.
