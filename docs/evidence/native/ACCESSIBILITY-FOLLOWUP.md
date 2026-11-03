# Accessibility follow-up — 2026-11-03

This report records the baseline run before the later [viewport boundary improvement](VIEWPORT-BOUNDARY-FOLLOWUP.md).

The accessibility audit remains **unresolved**. The final run has four passing functional UI tests and one failing audit test, with no skipped or expected failures. Production comparison UI and theme changes were reverted because the attempted changes did not establish a passing audit.

Tested on iPhone 17 Simulator, iOS 27.0 (24A434), device `5FDE1E82-1FF7-4556-9C14-0746F6295944`. The local result bundle is `.build/AccessibilityFinalUI.xcresult`, with command/output in `.build/accessibility-final-ui.log`.

## Retained test changes

`ios/UITests/RoomInTheCartUITests.swift` now audits Shop, the initial known result, and the lower results after scrolling. The audit-only test continues after failures to retain findings from all three viewports. Its issue handler records the full description and supplied element hierarchy and always returns `false`, so every issue remains a test failure. No categories or elements are excluded.

## Results

| Check | Result |
| --- | --- |
| Known comparison, item-only scope, save and restart | Pass |
| Unknown usable quantity stays unresolved after save and restart | Pass |
| Spanish entry, original food name, saved answer after restart | Pass |
| Largest accessibility text size, dark appearance, comparison and save | Pass |
| Full automated accessibility audit | Fail |

Shop reported no issues in this run. The initial and scrolled results produced 13 reports: five contrast, six Dynamic Type support, and two possible clipping reports. These are reports across two viewports, not 13 proven distinct defects.

The initial contrast report identifies the Pack B header with frame `{{16.0, 761.7}, {370.0, 40.3}}`, including the bottom navigation edge. The scrolled contrast report identifies `saveComparison`; its label is visibly overlapped by the floating tab bar in the retained screenshot. Three contrast reports supply no element. Dynamic Type reports identify Pack A/B headers, Edit (in both viewports), the source text, and Save comparison. Both clipping reports supply no element. Do not classify these findings as platform artifacts without further evidence.

The largest-text functional pass verifies the tested entry, totals, and save flow; it does not establish that every label/date is fully visible at each scroll position, nor does it override the audit. The run also retains five `Invalid frame dimension (negative or non-finite)` runtime warnings.

## Retained evidence

- [Xcode test summary](accessibility-followup-summary.json)
- [All audit descriptions and supplied element hierarchies](accessibility-followup-issues.json)
- [Relevant source hashes before and after the final run](accessibility-followup-source-hashes.json)
- [Initial result before audit](audit-followup-initial.png)
- [Scrolled result before audit](audit-followup-scrolled.png)
- [Largest-text dark saved state](audit-followup-largest-dark-saved.png)

ComparisonView.swift, Theme.swift, and the UI test source hashes match before and after the final run. Other integration work was concurrent; these hashes are scoped evidence, not a whole-repository immutable checkpoint.

Physical-device VoiceOver reading order/focus, Switch Control, increased contrast, Reduce Motion, and complete large-text visibility have not been certified by this follow-up. The unsuppressed audit and visible overlap require further work before accessibility acceptance.
