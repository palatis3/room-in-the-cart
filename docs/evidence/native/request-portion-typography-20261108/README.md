# Request portion typography · light qualification · 2026-11-08

Essential protected-portion labels and quantities now use native **body** type instead of caption in the S24 meal context. The two existing light-mode journeys pass with their original checkout, protected-lunch, cancellation and no-write assertions intact. This package covers **iPhone17Pro Simulator, iOS26.2 build23C54, light appearance**, at standard Large and AX5. Dark appearance, minimum iOS and physical VoiceOver remain pending.

## Exact change and run

[Product patch](provenance/product.patch) changes only the portion fact’s `.font(.caption)` to `.font(.body)`. [Test overlay](provenance/test-only.patch) adds exact label/value measurements to the existing two cases without scrolling away from the standard combined viewport. Each target must have one exact label, be hittable and wholly inside the usable viewport, have sufficient native-body text bounds (existing2pt tolerance), and pass the existing actual-pixel contrast assertion. Other preview/focus/disclosure behavior is unchanged.

Source manifest: `d55bb442efa527fad09edb2e83297a4b6458be92358996774fe7cd8779c60f18` (556inputs). [Verified input pins](provenance/verified-inputs.json) match both current affected files to the executed source. The preparation source-pin receipt is retained as historical; the separate installation receipt records its subsequent installation.

| Original test | Result | Duration |
|---|---|---|
| `testCerealCheckoutAndTwoProtectedLunchesAreVisibleTogetherAndCancelDoesNotWrite` | Pass |78.29s|
| `testLargestTextShowsCompleteProtectedLunchNamesAndDates` | Pass |130.14s|

[Strict verification](run/strict.txt): native0/strict0,2/2, no recorded runtime warnings, no observed animation-idle messages or runner restarts. [Run receipt summary](run/receipt-summary.json) preserves the exact command, local Xcode27.1 build27A9275, runtime/system-version identity, light/Large/increased-contrast-disabled setup, source fingerprint and preservation results. The AX5 case requests its larger category inside the existing journey. These are local Simulator results, not hosted or physical-device qualification.

## Rendered evidence

The exporter selected exactly **eight portion PNGs and eight matching frame attachments**, then a separate bounded export selected **one existing standard viewport PNG**. This packaging did not repeat either export or inspect any xcresult.

[Capture summary](capture-summary.json) retains every original target/selector/name/timestamp, byte count, SHA-256 and exact first frame line. Full AX debug trees and activity exports remain private in `.build`; they are not included here. Every copied PNG and all16source attachments were independently hashed against the original export receipts.

| Captured target, for both Sam and Mia | Actual frame height | Native body line height |
|---|---:|---:|
| Standard label and value |20.333pt|20.287pt|
| AX5 single-digit value |63.333pt|63.248pt|
| AX5 label, two full lines |125.333pt|63.248pt per native line|

These are element-frame measurements, not measured glyph heights. Required text bounds and the exact2pt assertion tolerance remain in the first-line records and test patch; no stronger typography precision is claimed.

[Root’s direct visual review](root-review.json) covers all eight crops plus the [standard full viewport](images/standard-checkout-and-two-lunches.png): complete labels and digits, with $40.69total, $2.69overage, $37.20prior total, $1.99fee and both named dated protected lunches still together. AX5 labels wrap fully; quantities remain visible. The selected captures do not prove every row/action or continuous scroll state.

## Original-pixel contrast

[Independent file-only measurements](measurement/results.json) use the existing [safe PNG decoder/measurement method](measurement/measure_field.py), with PNG CRC checks and no resizing, compositing or color conversion. All eight cropped text elements have white background and most frequent nonbackground core RGB23/41/37, giving **15.2138498279:1**. Their PNGs explicitly identify sRGB and are opaque.

The four label crops have repeated component support. Each of the four digit crops is only **one glyph**: `distributedColorSupport=false` remains recorded. Its numerical core/background contrast is evidence for that observed digit only, not a multiglyph or twelve-component claim. Contrast of these text crops is not a whole-screen, disabled-control, or accessibility-audit pass.

## Preservation and limits

[Copy/verification receipt](copy-and-verification-receipt.json) hashes the exact copied files. Sanitized summaries retain original receipt hashes; full large records remain private. The existing export receipts report source/original unchanged and inspection-copy-only use. No native commands, simulator interactions, new exports, reinspection, source edits, deployment or commit occurred during packaging.

This evidence does not close the original36/fresh41 accessibility reports wholesale, English animation timeout, broader accessibility, physical assistive testing, dark/minimum-iOS qualification or Release. The package manifest covers all published files except itself.
