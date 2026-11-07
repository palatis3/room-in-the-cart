# S24 request review accessibility

The contributor fixture exercises the ordinary shopper flow. At standard size it requires the current and proposed totals, the over-cap amount and both named protected lunches in one viewport. It measures the rendered total and coverage guidance against their backgrounds. At the largest accessibility size it brings each entire meal into view and checks the rendered title and date against the space required by the corresponding system text style. Both journeys cancel without writing a decision or a line.

## Unfiltered product audit

In a separate checkout of this revision, apply the diagnostic overlay and run the indicated test on an iPhone simulator. It records each issue and returns it to XCTest as a failure. The overlay preserves the existing simultaneous-visibility, consent and cancellation checks.

```sh
git apply diagnostics/request-review-accessibility/unfiltered-review.patch
xcodebuild -project ios/RoomInTheCart.xcodeproj -scheme RoomInTheCart \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$EVIDENCE/product-build" -resultBundlePath "$EVIDENCE/product.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGN_IDENTITY=- \
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(python3 scripts/plan_ios_fixture_tests.py conditions contributor)" \
  -only-testing:RoomInTheCartUITests/HouseholdRequestPackUITests/testCerealCheckoutAndTwoProtectedLunchesAreVisibleTogetherAndCancelDoesNotWrite test
```

## Standalone stock controls

These sources reuse the standalone diagnostic Xcode project. Use a disposable simulator and fresh evidence directory. The application displays stock SwiftUI controls, the scrolled form inside a sheet and a UIKit body label. It has no household data or service.

```sh
mkdir -p "$EVIDENCE/stock"
cp -R diagnostics/swiftui-toggle/FormToggleDiagnostic.xcodeproj "$EVIDENCE/stock/"
cp diagnostics/request-review-accessibility/StockApp.swift "$EVIDENCE/stock/FormToggleDiagnostic.swift"
cp diagnostics/request-review-accessibility/StockUITests.swift "$EVIDENCE/stock/FormToggleDiagnosticUITests.swift"
sed -i '' 's/org.roominthecart.diagnostics.formtoggle/org.roominthecart.diagnostics.s24text/g' \
  "$EVIDENCE/stock/FormToggleDiagnostic.xcodeproj/project.pbxproj"
xcodebuild -project "$EVIDENCE/stock/FormToggleDiagnostic.xcodeproj" -scheme FormToggleDiagnostic \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$EVIDENCE/stock-build" -resultBundlePath "$EVIDENCE/stock.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never CODE_SIGN_IDENTITY=- test
```

On iPhone 17 with iOS 26.2 and Xcode 27.1 the original product audit failed with 34 findings. The independent scrolled sheet failed with 32, including the same heading, portion, button and contrast diagnostics. The simpler top-level form reported a Dynamic Type finding on a standard button. Its separate size comparison shows that the stock heading and portion row grow as the system size increases. The original product also truncated both meal names and dates on screen at AX5 despite exposing their full accessibility labels.

## Verified results on iOS 26.2

All eight focused ordinary cases passed with zero runtime warnings. The original standard-size comparison and the new largest-size test both preserved the no-write checks. On the original screen, changing the system from Small to AX5 produced ellipses for each lunch name and date. With the wrapping fix, Sam’s title grew from 58.7 to 116.7 points at AX5 and its date grew from 51.3 to 102.3 points. The final AX5 captures show both full titles and both full dates. Using the rendered glyph and background luminance, the guidance improved from 4.00:1 to 7.08:1. The final expected total measured 7.08:1.

The final **unfiltered audit failed with 36 findings**. It reported 31 partially unsupported Dynamic Type elements, one unsupported element, one possible clipping issue, two contrast issues and one potentially inaccessible text element. The final protected-meal heading wraps on screen at AX5. The standalone sheet also flags that heading for clipping. Of the 36 findings, 14 match the same issue category and public label in the standalone sheet. Four lack a public target. The checked-in [individual findings](remaining-findings.csv) record each comparison and the limits of its evidence.

For the “Review decision” contrast finding, the element screenshot contains the navigation title and Cancel button. The scrolled-off button’s glyphs are absent from that capture. For “Review before applying”, the captured heading is visible and its reported rectangle measures 6.40:1 using the same percentile method as the ordinary test. XCTest still reports both failures. Auditing the stock controls and measuring visible text do not establish the cause of every warning. Physical VoiceOver testing remains open.
