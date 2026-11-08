# Protected portions · dark iOS26.2 qualification

The same two original S24 journeys pass in **dark appearance on iPhone17Pro Simulator, iOS26.2 build23C54**, with native body portions at standard Large and AX5. This is a separate run of the exact source used by the [retained light proof](../../request-portion-typography-20261108/README.md); the light files and manifest were independently verified unchanged.

| Test | Result | Duration |
|---|---|---:|
| `testCerealCheckoutAndTwoProtectedLunchesAreVisibleTogetherAndCancelDoesNotWrite` |Pass|77.21s|
| `testLargestTextShowsCompleteProtectedLunchNamesAndDates` |Pass|130.57s|

[Strict result](run/strict.txt): native0/strict0,2/2, zero recorded runtime warnings, zero observed animation-idle messages and runner restarts. [Run summary](run/receipt-summary.json) retains exact argv, Xcode27.1 build27A9275, device/system version, dark/Large/increased-contrast-disabled settings, source and preservation fields. AX5 is selected inside its existing test. Source manifest remains `d55bb442efa527fad09edb2e83297a4b6458be92358996774fe7cd8779c60f18`; [affected source pins](source-pins.json) match the run and current files. Product/test patch is already preserved in the linked light proof.

## Targets and visible context

Exactly eight portion PNGs and eight first-line frame summaries are retained in [capture-summary.json](capture-summary.json), with original selector/attachment identity, timestamp, SHA-256 and byte counts. Raw AX trees and activity exports remain private. A separately exported [standard viewport](images/standard-checkout-and-two-lunches.png) is bound by its [context receipt summary](context-receipt-summary.json). No attachment export was repeated during packaging.

[Root directly reviewed](root-review.json) all nine images and eight frame first lines. Portion labels and digits are complete. Standard element frames are20.333pt high against native body20.287pt; AX5 quantities are63.333pt against body63.248pt; AX5 labels wrap across125.333pt. These are element frames, not glyph heights; native body text-bounds assertions retain their2pt tolerance. The standard full viewport retains $40.69total, $2.69overage, $37.20before, $1.99fee and both named dated protected lunches together. Original cancellation/no-write assertions remain part of the passing cases.

## Original-pixel contrast

[Independent measurements](measurement/results.json) of the eight existing original PNGs give foreground RGB244/245/236 against background28/41/35: **13.7464252613:1** for every selected crop. The copied safe method verifies PNG CRCs/opacity and uses exact original pixels with no resizing or color conversion. Each PNG identifies sRGB.

Label crops show repeated component support. Every digit crop is a single glyph, with `distributedColorSupport=false` deliberately retained: its observed core/background ratio is not a multiglyph claim or whole-screen contrast pass.

## Preservation and limits

[Copy/verification receipt](copy-and-verification-receipt.json) records byte-identical copied files, all16 original target hashes, the context image, and unchanged light-proof hashes. Existing completed receipts report original/source preservation and inspection-copy-only export. This packaging involved file reads/copies and pixel analysis only—no native/simulator/build/test, xcresult reinspection/export, source edits, deployment or commit.

This proof is dark26.2 only. It does not establish minimum-iOS behavior, physical VoiceOver, broader accessibility, closure of original36/fresh41audit findings, the English animation-timeout issue or Release. The original preparation/capture receipt’s “pending root” state is historical; root-review.json records the completed visual review. The dark manifest is independent so later minimum evidence can be added without changing this proof.
