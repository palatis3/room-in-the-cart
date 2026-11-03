# Results viewport boundary — 2026-11-03

The comparison result list now ends above the floating tab bar. A GeometryReader constrains a vertical layout to the safe viewport, and an eight-point opaque footer extends behind bottom navigation. The native List, Sections, text styles, identifiers, and save behavior are preserved. Scrolling content is clipped to the list's actual bounds.

The focused visibility test passes: the results collection's bottom edge is above the tab bar; the whole Save control can be scrolled into that viewport; and saving still publishes its durable success state. The collection's accessibility frame changed from `{{0, 0}, {402, 874}}` to `{{0, 0}, {402, 783}}`. Screenshot review confirms that result text no longer paints behind the tab bar and that the fully revealed Save label is readable.

The all-category accessibility audit **still fails**. This run reported three contrast, six Dynamic Type support, and three clipping findings across the initial and scrolled results. Some reported cells extend past the viewport edge in the accessibility hierarchy. That observation does not establish that the reports are platform artifacts. No issue categories or elements are filtered or suppressed.

The initial Shop audit additionally threw error `com.apple.accessibilityAudit -902: Invalid target app` while a SpringBoard “Sign in to Apple Account” alert covered the app. XCTest dismissed that alert on its next interaction. The results audits and the separate viewport/save test then ran. This interruption is distinct from the reported results-screen issues.

Tested on iPhone 17 Simulator, iOS 27.0 (24A434), device `5FDE1E82-1FF7-4556-9C14-0746F6295944`, using ad-hoc code signing (`CODE_SIGN_IDENTITY=-`). The first build attempt stopped because PickupCookProjection.swift was missing from the generated project; the project owner regenerated it before this run. No generator source was changed by this follow-up.

- [Focused test summary: one pass, one failing audit](viewport-boundary-focused-summary.json)
- [Audit descriptions and supplied element hierarchies](viewport-boundary-issues.json)
- [Matching before/after hashes for comparison view, theme, and UI tests](viewport-boundary-source-hashes.json)
- [Initial result viewport](viewport-boundary-initial.png)
- [Scrolled result viewport with no text behind the tabs](viewport-boundary-scrolled.png)
- [Entire Save control visible above the tabs](viewport-boundary-save-visible.png)

Local full evidence: `.build/ViewportBoundaryFocused2.xcresult` and `.build/viewport-boundary-focused-2.log`. Other integration work was concurrent, so the source hashes are scoped evidence rather than a whole-repository freeze.

The four existing full comparison regression flows then passed against the retained viewport change: known save/restart, largest Dynamic Type with dark appearance, Spanish/original-name persistence, and unknown usable quantity after restart. This run has four passes, zero failures, zero skips, and four retained `Invalid frame dimension (negative or non-finite)` runtime warnings. No audit was rerun or waived in this functional-only batch.

- [Four-flow regression summary](viewport-boundary-regression-summary.json)
- [Matching relevant source hashes during regression](viewport-boundary-regression-source-hashes.json)
- [Largest-text dark saved state](viewport-boundary-largest-dark-saved.png)
- [Spanish reopened comparison](viewport-boundary-spanish-reopened.png)
- [Unknown quantity after restart](viewport-boundary-unknown-reopened.png)

The regression bundle is `.build/ViewportBoundaryRegression.xcresult`, with output in `.build/viewport-boundary-regression.log`. **Its compiled app snapshot predates the parent's subsequent AppModel/Records listing changes and later full native test batch.** The proven ComparisonView viewport change remained unchanged. These comparison-flow passes must not be presented as validation of those later integration changes.

Physical-device VoiceOver and complete largest-text visibility remain unverified, and accessibility acceptance remains open.
