# S23 duplicate-request grouping and comparison

Implementation evidence for Foundation 2.1 S23 / N01 and finding 4 in `current-launch-gap-review.md`. Source validation recorded 2026-11-03. This is focused S23 implementation and native simulator evidence; it does not certify the complete application or a release candidate.

**Current S23 result:** the lead's final native simulator run passed both dedicated UI cases: English split-page comparison / cancel / individual deferral (114.800 seconds) and US-Spanish largest-accessibility-text comparison / cancel (338.314 seconds). The eight focused model tests had also passed in the earlier native run. Passing screenshots and accessibility trees were inspected against unchanged S23 source/test hashes. The final six-test bundle itself remains failed because two unrelated S21 device-management cases failed. Exact build identity, captures and scope are recorded in **Final native S23 verification** below; prior failure diagnoses remain as history.

## Result

The authorized shopper's already loaded current-shop requests are grouped together by original item name after case, whitespace and canonical Unicode normalization. The original `OwnRequest` values remain intact, including each alias, amount/use text, original food wording, route, server-received time, revision, clarification and outcome. Completed outcomes remain in the comparison. Names with different exclusions or other meaningful words are not inferred to be equivalent.

The existing inbox's individual row/action/focus identities and individual decision flows are preserved. `RequestDuplicateGroupHeading` labels adjacent same-name rows. `RequestDuplicateComparisonSection` shows the selected request alongside the other matching requests in its decision sheet. It does not select another request, aggregate quantities, manufacture package coverage, change the basket or enqueue a command.

Pagination remains explicit. While `nextCursor` exists, the sheet explains that only loaded requests are shown; even a currently unmatched request gets the incomplete-scan notice. **Check more requests** invokes the existing read-only `load(more: true)` while retaining the selected request and its draft. It never claims the full inbox contains no duplicate before remaining pages are checked. The helper filters any supplied row from another shop and returns no projection when authorization is absent; it receives no contributor-private basket data or prices.

## Installed hooks and remaining installer action

The `request_meal_context` lane installed these three hooks in `HouseholdInboxView.swift`:

1. Iterate `model.duplicateRequestGroups`, then each `group.requests`, preserving the existing per-request button/action identifiers.
2. Render `RequestDuplicateGroupHeading(group: group)` for a duplicated group and remove the old generic duplicate notice.
3. Insert `RequestDuplicateComparisonSection(model: model, requestID: request.id)` after the selected Request section, before choices (also visible for completed requests).

No additional inbox hook is required for pagination: the comparison section owns its check-more action.

The lead must regenerate the Xcode project to include new sources/catalog/tests and install the isolated fixture dispatcher inside the existing `DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE` branch:

```swift
else if ProcessInfo.processInfo.arguments.contains("--ui-testing") &&
        ProcessInfo.processInfo.arguments.contains("--request-duplicates-fixture") {
    S23DuplicateRequestFixtureRoot()
}
```

No App, guardian, service, journal, git index or commit was changed by this lane.

## Executed validation

A temporary, isolated macOS Swift package at `.build/S23DuplicateHarness` compiled the actual `HouseholdInboxModel.swift`, actual request-pack review/domain, both duplicate helper/view sources, and shared S23 fixture support against the repository CoreDomain and HouseholdClient packages. Minimal display-only `ht`, `householdTime`, and `shopperRequestStatus` implementations replaced the rest of the application for this focused harness. The actual comparison view was typechecked; no iPhone layout or assistive technology result is inferred from that typecheck.

Command:

```sh
swift test --package-path .build/S23DuplicateHarness --filter RequestDuplicateComparisonTests --jobs 2
```

Result: **8 tests passed, 0 failures**, final run build 5.18 seconds, test execution 0.027 seconds. The suite verifies:

- Nonadjacent same-name authors become adjacent without losing original uses, separate quantities or completed outcomes.
- Case/whitespace/canonical Unicode matching does not remove meaningful words or diacritics.
- Absent authorization, foreign shops and empty names cannot create private or false groups.
- Overlapping pages represent one latest revision of each request and preserve stable group identity.
- The isolated fixture rejects unexpected network hosts.
- Same-name authors across a page boundary become inspectable together; checking more preserves selection and draft fields, produces zero previews/commands/outbox records, and cancellation writes nothing.
- Explicitly linking Sam then deferring Lee records separate outcomes while the existing basket retains exactly one line and one pack; a repeated Apply adds nothing.
- Clarifying Sam affects only Sam; after a fresh explicit review, linking Sam leaves Lee's request and original amount/use untouched.

Swift frontend parsing also passed for the dedicated UI fixture and UI tests with `DEBUG` and `CONTRIBUTOR_CAPTURE_UI_FIXTURE` enabled. All 23 added strings have matching English/Spanish catalog values.

## Initial integrated iPhone verification setup

`RequestDuplicateComparisonUITests` contains an English split-page → compare → cancel → individually defer flow and a US-Spanish largest-accessibility-text comparison/cancel flow. Launch arguments: `--ui-testing --request-duplicates-fixture`. The fixture contains Sam's **1 box for breakfasts**, unrelated wraps on page one, Lee's **2 boxes for the school snack drive** on page two, and Pat's independently handled cereal request. Counters expose applied decisions, actual saved basket line count and currently loaded request count. Real service hosts are rejected. Shared server support is DEBUG-only; the UI root itself requires the existing dedicated fixture compilation flag and explicit launch arguments.

At the initial implementation handoff, these UI tests were prepared but not executed by this lane, per the assignment's no-device/no-heavy-Xcode-build limit. The lead subsequently executed them; the historical diagnoses and final passing S23 evidence are recorded below. Independent clarification and link behavior are covered by the focused model tests; the native UI cases exercise comparison, cancellation and individual deferral.

## First native run and harness follow-up

The lead's first integrated run used the frozen `.build/RequestReviewSource-20261103` source and `.build/RequestReview-20261103.xcresult`. The actual eight S23 model tests passed natively with zero failures (0.350 seconds). Both prepared S23 UI tests failed before completing acceptance; this evidence does not relabel them as passes.

The US-Spanish failure screenshot `7D51E3AB-C911-4617-B149-D6D841890641.png` and hierarchy `E388F8CA-C7C0-4D70-834B-A61505F60C2F.txt` in `.build/RequestReview-20261103-attachments` show that test fixture counters inherited largest accessibility text. They occupied y=47 through y=421 of an 844-point display; the product NavigationStack began at y=453. The test waited for Sam's lazy offscreen row to exist without first scrolling it into the loaded viewport. The fixture now bounds **only its three instrumentation counters** to fixed 11-point text / medium Dynamic Type. Product content retains the original largest accessibility text. The test deliberately reveals the row inside its active collection before requiring existence and hittability.

The English failure log shows repeated application-wide drags from y=734 to y=150, followed by reversals from y=150 to y=734. Its final screenshot `A20E107E-1973-4A92-A2C6-D63507C01A10.png` shows the inbox, with the decision sheet dismissed. The issue text `FD326B40-BD92-44FE-A28D-0E210D10BDEC.txt` reports that `household.duplicates.loadMore` no longer exists. This proves the old search lost its required modal context; it does not by itself establish that the product's check-more action is absent or broken.

The revised search uses the frontmost hittable CollectionView (then native table/scroll fallbacks), clips every short gesture below its visible navigation bar and above any keyboard, and never falls back to whole-application swipes. It observes native scroll percentages and unchanged visible content at boundaries. It stops instead of down-dragging at the beginning of a modal list, and explicitly fails if the expected decision sheet disappears. Initial opening, pre/post-page load, repeated search milestones, final state and teardown now retain both screenshots and full accessibility hierarchies. All original positive assertions for page boundaries, original author/use text, separate outcomes, cancellation with zero commands and one individual decision remain.

The section's existing accessibility marker was moved from the enclosing Section to its header Text, retaining `household.duplicates.comparison` while avoiding possible container identifier inheritance over explicit descendant controls. The check-more button keeps its exact `household.duplicates.loadMore` identifier. This is an accessibility identifier placement change, with no copy, state or decision change; identifier inheritance remains a hypothesis pending the next native hierarchy.

The revised dedicated UI test source passed a direct arm64 iPhone Simulator SDK typecheck with the platform XCTest Swift overlay. Dedicated fixture/view parsing also passed. No device or heavy Xcode build was run by this lane. At that stage, the lead's rerun remained required. The final passing native S23 run is recorded below.

## Second native run and typed comparison-value follow-up

The lead's `.build/IntegratedFixture-20261103.xcresult` run used `.build/IntegratedFixtureSource-20261103T223750Z`. Both S23 UI cases advanced through opening the modal and deliberately checking the next page. The previous fixture viewport and accidental-dismissal failures did not recur. The two cases still failed acceptance in that run; the later passing native run below verifies this follow-up.

The English author failure is explained by the actual accessibility tree: the comparison's native LabeledContent produces a static-text node whose label is **Requested by, Lee**, not a bare **Lee** node. The prior bare-label query matched only Lee's covered inbox text and could never satisfy visible author inspection in the modal. The same native grouping applies to outcome fields, such as **This request's outcome, Handled**. The relevant full trees include `E4CC3EF3-78C2-43E6-B567-4141EEAE2ED9.txt` and `D14E223A-26FE-4469-AB35-704CF651D4A3.txt` in `.build/IntegratedFixture-20261103-attachments`.

The Spanish original-amount search started after page insertion while Lee's comparison row was onscreen. Native AX contains a **horizontal** scrollbar named **Barra de desplazamiento horizontal, 1 página** with value **0%**. The old percentage helper accepted any scrollbar, mistook that horizontal 0% for the beginning of the vertical list when it reversed, and stopped before returning to Sam. The failure screenshots and retained step trees show the modal still open; this was not disappearance of Sam's original request. The percentage helper now explicitly accepts only **vertical** scrollbars, in both launch languages.

The view now gives request-scoped identifiers directly to each comparison selection marker, original food wording, amount/use caption and value, author LabeledContent and outcome LabeledContent. Its unused broad row identifier was removed while retaining native contained accessibility grouping. UI assertions use typed static-text queries with those request and field identifiers. Original amounts and role text still require the exact complete label. Author and outcome fields require their actual native combined labels to contain the expected alias/status, scoped to the exact request field. This strengthens the checks against accidentally passing on a covered inbox row or the selected request's separate summary. Sam, Lee and Pat remain distinct; the English case retains Pat's handled outcome, Sam's individual saved outcome, Lee's pending outcome, and the later Lee selection marker. The Spanish case retains both original English use strings unchanged, Spanish field captions, both aliases and the zero-command cancellation checks.

The revised test source passes direct arm64 iPhone Simulator SDK/XCTest Swift-overlay typechecking, and the dedicated view passes frontend parsing. No model, service, inbox flow, request data, decision behavior or product copy changed in this follow-up. No simulator, heavy Xcode build or git operation was run by this lane. At that stage, native visible interaction, largest-text screenshots and the complete two-case result remained assigned to the lead's rerun; its final passing result follows.

## Final native S23 verification

The lead's finalized **FinalNative470** run used frozen source SHA-256 **`4b91cfce67372ca1b047985ce3531cd806d627c0eb4a60311ed0bead9beb7af0`**. The seven S23 source/catalog/test hashes in the stable manifest below were re-read and are unchanged. This follow-up changed only this dedicated evidence document; it did not alter production code, tests, fixture behavior, promoted artifacts or the git index.

Authoritative run artifacts are `.build/FinalFixture-20261103.xcresult`, `.build/FinalFixture-20261103.log`, `.build/FinalFixture-20261103-summary.json`, and `.build/FinalFixture-20261103-attachments/manifest.json`. The summary identifies **iPhone 17e, arm64, iOS Simulator 27.0 (24A434)**. The two-case S23 suite completed successfully at 2026-11-03 18:11:52 America/New_York. The lead owns artifact promotion and git operations.

| Dedicated S23 case | Result | Duration | Exercised scope |
|---|---|---|---|
| `testSplitPageComparisonPreservesBothUsesAndCancelHasNoWriteThenDecidesOnlySam` | Passed | 114.800 s | Initially incomplete scan; deliberate second page in the same selected request; exact author/use fields; independently handled Pat; zero-write Cancel; one explicit Sam deferral; unchanged single basket line; Lee selected later with his original use and pending outcome. |
| `testSpanishLargeTypeKeepsOriginalRequestWordsAndReadOnlyComparison` | Passed | 338.314 s | US-Spanish interface at `UICTContentSizeCategoryAccessibilityXXXL`; second-page inspection; Sam's selected marker, both aliases and complete unchanged original English use strings; Spanish amount/use caption; separate-outcome explanation; Cancel with zero applied decisions and one unchanged basket line. |

These are **2 S23 UI passes**, not six overall passes. The full bundle has four passes and two failures; both failures are `HouseholdDevicesUITests` (S21), as named in the summary. The earlier eight native S23 model passes are a separate prior run and were not re-executed in this six-case UI bundle.

### Inspected passing captures

All filenames below are under `.build/FinalFixture-20261103-attachments/`; the manifest associates each capture with its exact dedicated S23 test. Screenshots were opened for visual inspection and their paired full accessibility trees were read. Offscreen nodes in a tree were not treated as simultaneous on-screen proof.

| Evidence | Screenshot | Paired accessibility tree | Observed result |
|---|---|---|---|
| English initial page | `833D4AA5-B4FB-4C72-A2CC-9B5145130965.png` | `B45CB6AB-1620-4D6F-A88A-264261C11644.txt` | Selected Sam remains visible with **1 box for breakfasts** and the explicit statement that other requests have not yet been checked. Counters are 0 decisions / 1 basket line / 2 loaded requests. |
| English second page, same decision sheet | `11A2C0D0-376A-4221-AD21-723781FC65B7.png` | `AB801EFC-D0E9-417A-98EC-9992372626A9.txt` | Sam's **Deciding this request** marker and original breakfast use appear above Lee's **Other request** marker and **2 boxes for the school snack drive**. Both aliases and distinct original food spellings are visible. Counters are 0 / 1 / 4. No combined quantity or pack-coverage assertion appears. |
| Previously completed outcome retained | `F2F5A4A5-33C7-42CA-AB61-AD8DB2FEC737.png` | `94C56BE4-1EB8-4739-82B8-19605D6C6883.txt` | Lee's pending request and original use remain separate from Pat's **Handled** request and **1 box for the weekend**. The footer explains that comparing changes nothing and quantities are not added together. |
| One explicit decision, other author unchanged | `21ACA229-5F9B-47F0-98B7-501DFA7E8CBB.png` | `3224134C-E53E-430E-9FDA-8E28EF0149F3.txt` | Sam is now revision 2 / Next shop / **Saved for next shop**; Lee is the selected request, revision 1 / This shop / **Received, waiting for review**. Both original uses remain visible. AX counters show exactly 1 applied decision and 1 saved basket line. |
| Largest-text product viewport | `6616E839-F14F-41E3-A94E-A63F5289A9AD.png` | `D963372A-936D-49C0-9F15-0E9C790A74E8.txt` | Only instrumentation counters use small fixed text. Spanish product text retains the launched largest accessibility size, with native vertical scrolling. |
| Largest-text Sam original use | `54389F2B-C690-4283-8A29-C1EACE60D6FD.png` | `34935DE4-C03E-4D27-841F-6B552B145F38.txt` | **Decidiendo esta solicitud**, Sam, Cereal and **1 box for breakfasts** remain readable. The full Spanish amount/use caption and exact original amount value have their own request-scoped AX identifiers. |
| Largest-text Lee original use | `9231471D-A711-4B69-B2AA-99E6C927D966.png` | `5EA0FC0F-CB4B-4244-841A-A86068CC422F.txt` | Lee, CEREAL and the complete **2 boxes for the school snack drive** value remain readable after scrolling. The full Spanish caption is present in AX; the long visual caption ellipsizes in this retained frame. |
| Spanish Cancel leaves state unchanged | `7AB232AF-D7AF-441A-85AF-CAC0522B1F8B.png` | `9749D9B2-077E-4E2A-9B1E-AC781AB754BB.txt` | Returned to the grouped inbox with 0 applied decisions, 1 saved basket line and 4 loaded requests. The decision modal is dismissed deliberately by Cancel. |

The passing typed-value assertions require the exact original amount/use strings and the exact selected marker in the visible comparison. Author and outcome checks use the corresponding request-scoped native static-text field, accounting for LabeledContent's combined caption/value accessibility label. They do not pass on a same-word node in the covered inbox. The English final screenshot and AX independently corroborate the separate Sam/Lee outcomes.

### Scope of acceptance

This is focused fixture-based native simulator acceptance for S23 duplicate grouping/comparison, pagination, original author/use preservation, inspection without writes, cancellation and individual deferral, combined with earlier model acceptance for independent clarification, explicit reviewed linking, stable identities and authorization/shop filtering. It is not deployed-service, physical-device, live human VoiceOver, Switch Control, all-language typography or full-release acceptance. The longest Spanish field caption can ellipsize in a captured largest-text frame; its original request value is complete, the full caption remains in AX, and this evidence does not claim flawless large-text typography. No new source or test change was made during the passing-capture review.

## Stable source manifest

| File | SHA-256 |
|---|---|
| `ios/Features/Household/RequestDuplicateGroups.swift` | `ab15f4b51fff08b20025f4023c6a9272e05624f2708e210d36d3f80130e2d291` |
| `ios/Features/Household/RequestDuplicateComparisonView.swift` | `11088e22ac1bea6960a771fb078b774ab9f62ff6b4a1f014bc23a3a10f272330` |
| `ios/Features/Household/RequestDuplicates.xcstrings` | `7cf9b71511c318379bb78d0be2a5d874686554732b59d5fe90c1ac6e5b9dd87b` |
| `ios/Tests/RequestDuplicateComparisonTests.swift` | `2e840912977076b6c1c7933349b1a68e9bddf8262f0859ff7f1519cc21aca58e` |
| `ios/UITestSupport/RequestDuplicateFixtureSupport.swift` | `b71669682e7f8212ecf1298caf7b48762b9dda5fcfd50641ee4023e70b419d4b` |
| `ios/UITestSupport/RequestDuplicateUIFixture.swift` | `002e9216dbe0087de8079360a53f2a339aa128175eeb082068db83ded7e5ac45` |
| `ios/UITests/RequestDuplicateComparisonUITests.swift` | `b3e4cf1033a5bd396969600c9d65a3e24e6814c93ce89852ded0b840b6cfd0af` |
