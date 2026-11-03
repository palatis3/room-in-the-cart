# S23 duplicate-request grouping and comparison

Implementation evidence for Foundation 2.1 S23 / N01 and finding 4 in `current-launch-gap-review.md`. Source validation recorded 2026-11-03. This is focused implementation evidence; integrated iPhone UI execution is assigned to the lead and is not claimed here.

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

## Ready for integrated iPhone verification

`RequestDuplicateComparisonUITests` contains an English split-page → compare → cancel → individually defer flow and a US-Spanish largest-accessibility-text comparison/cancel flow. Launch arguments: `--ui-testing --request-duplicates-fixture`. The fixture contains Sam's **1 box for breakfasts**, unrelated wraps on page one, Lee's **2 boxes for the school snack drive** on page two, and Pat's independently handled cereal request. Counters expose applied decisions, actual saved basket line count and currently loaded request count. Real service hosts are rejected. Shared server support is DEBUG-only; the UI root itself requires the existing dedicated fixture compilation flag and explicit launch arguments.

The lead's native run should confirm visible/accessible grouped rows, the incomplete-page notice, current-request marker, both original uses, independent completed statuses, check-more focus/selection continuity, separate clarification and decision controls, and zero writes on inspect/cancel. These UI tests were prepared but not executed by this lane, per the assignment's no-device/no-heavy-Xcode-build limit.

## First native run and harness follow-up

The lead's first integrated run used the frozen `.build/RequestReviewSource-20261103` source and `.build/RequestReview-20261103.xcresult`. The actual eight S23 model tests passed natively with zero failures (0.350 seconds). Both prepared S23 UI tests failed before completing acceptance; this evidence does not relabel them as passes.

The US-Spanish failure screenshot `7D51E3AB-C911-4617-B149-D6D841890641.png` and hierarchy `E388F8CA-C7C0-4D70-834B-A61505F60C2F.txt` in `.build/RequestReview-20261103-attachments` show that test fixture counters inherited largest accessibility text. They occupied y=47 through y=421 of an 844-point display; the product NavigationStack began at y=453. The test waited for Sam's lazy offscreen row to exist without first scrolling it into the loaded viewport. The fixture now bounds **only its three instrumentation counters** to fixed 11-point text / medium Dynamic Type. Product content retains the original largest accessibility text. The test deliberately reveals the row inside its active collection before requiring existence and hittability.

The English failure log shows repeated application-wide drags from y=734 to y=150, followed by reversals from y=150 to y=734. Its final screenshot `A20E107E-1973-4A92-A2C6-D63507C01A10.png` shows the inbox, with the decision sheet dismissed. The issue text `FD326B40-BD92-44FE-A28D-0E210D10BDEC.txt` reports that `household.duplicates.loadMore` no longer exists. This proves the old search lost its required modal context; it does not by itself establish that the product's check-more action is absent or broken.

The revised search uses the frontmost hittable CollectionView (then native table/scroll fallbacks), clips every short gesture below its visible navigation bar and above any keyboard, and never falls back to whole-application swipes. It observes native scroll percentages and unchanged visible content at boundaries. It stops instead of down-dragging at the beginning of a modal list, and explicitly fails if the expected decision sheet disappears. Initial opening, pre/post-page load, repeated search milestones, final state and teardown now retain both screenshots and full accessibility hierarchies. All original positive assertions for page boundaries, original author/use text, separate outcomes, cancellation with zero commands and one individual decision remain.

The section's existing accessibility marker was moved from the enclosing Section to its header Text, retaining `household.duplicates.comparison` while avoiding possible container identifier inheritance over explicit descendant controls. The check-more button keeps its exact `household.duplicates.loadMore` identifier. This is an accessibility identifier placement change, with no copy, state or decision change; identifier inheritance remains a hypothesis pending the next native hierarchy.

The revised dedicated UI test source passed a direct arm64 iPhone Simulator SDK typecheck with the platform XCTest Swift overlay. Dedicated fixture/view parsing also passed. No device or heavy Xcode build was run by this lane. The lead must rerun the two S23 UI cases to establish actual visible interaction and layout acceptance.

## Stable source manifest

| File | SHA-256 |
|---|---|
| `ios/Features/Household/RequestDuplicateGroups.swift` | `ab15f4b51fff08b20025f4023c6a9272e05624f2708e210d36d3f80130e2d291` |
| `ios/Features/Household/RequestDuplicateComparisonView.swift` | `53a89afd2314c015bfc2d101aa6ced2d5eba317b495a120678f8711046d0527e` |
| `ios/Features/Household/RequestDuplicates.xcstrings` | `7cf9b71511c318379bb78d0be2a5d874686554732b59d5fe90c1ac6e5b9dd87b` |
| `ios/Tests/RequestDuplicateComparisonTests.swift` | `2e840912977076b6c1c7933349b1a68e9bddf8262f0859ff7f1519cc21aca58e` |
| `ios/UITestSupport/RequestDuplicateFixtureSupport.swift` | `b71669682e7f8212ecf1298caf7b48762b9dda5fcfd50641ee4023e70b419d4b` |
| `ios/UITestSupport/RequestDuplicateUIFixture.swift` | `002e9216dbe0087de8079360a53f2a339aa128175eeb082068db83ded7e5ac45` |
| `ios/UITests/RequestDuplicateComparisonUITests.swift` | `70aa48532e93ac17ffdde81684af6c66fd9f7e4d3d072ef0333d0928f1d55a70` |
