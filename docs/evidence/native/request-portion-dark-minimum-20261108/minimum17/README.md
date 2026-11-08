# Protected portions · minimum iOS17 qualification

The two original S24 cases pass on **iPhoneSE (3rd generation) Simulator, iOS17.0 build21A328, light appearance**, at standard Large and AX5. Exact source matches the independently preserved26.2 light/dark runs: `d55bb442efa527fad09edb2e83297a4b6458be92358996774fe7cd8779c60f18`.

| Test | Result | Duration |
|---|---|---:|
| `testCerealCheckoutAndTwoProtectedLunchesAreVisibleTogetherAndCancelDoesNotWrite` |Pass|77.75s|
| `testLargestTextShowsCompleteProtectedLunchNamesAndDates` |Pass|121.78s|

[Strict result](run/strict.txt): native0/strict0,2/2, zero recorded runtime warnings, zero observed animation-idle messages and runner restarts. [Run receipt summary](run/receipt-summary.json) retains exact argv, Xcode27.1 build27A9275, runtime/system identity, light/Large/increased-contrast-disabled setup, source and preservation fields. AX5 is selected by the original case. Original cancellation/no-write and full checkout/protected-lunch assertions remain intact.

## Exact target evidence

[Capture summary](capture-summary.json) binds eight original portion PNGs and eight first-line frame records to their selectors/names/timestamps/hashes. The [standard full viewport](images/standard-checkout-and-two-lunches.png) has a separate [receipt summary](context-receipt-summary.json). All17 original attachment files were independently hash-verified; full AX trees/activity outputs remain private. No export or inspection was repeated.

[Root directly viewed](root-review.json) all nine PNGs and reviewed the eight frame records. Standard label/value frames are20.5pt high versus native body20.287pt. AX5 labels occupy two complete lines125.5pt high; values are63.5pt versus native body63.248pt. These are element-frame heights, not glyph measurements; the existing2pt native text-bounds tolerance remains explicit in the test overlay preserved in the [light proof](../../request-portion-typography-20261108/README.md).

The standard viewport preserves $40.69total, $2.69overage, $37.20before, $1.99fee and both named dated protected lunches together. Portion labels and digits are complete in the selected images. This is scoped screenshot/test evidence, not every scroll state or route.

## Pixel measurements and limits

[File-only measurements](measurement/results.json) use the existing safe original-pixel decoder, checking CRCs and opacity without resizing or color conversion. All eight sRGB crops show RGB23/41/37 on white, **15.2138498279:1**. Repeated label component support is recorded; each value is one digit, with `distributedColorSupport=false` retained and no multiglyph inference.

[Copy/verification receipt](copy-and-verification-receipt.json) records exact copied files and independently unchanged light/dark proof hashes. The existing completed export receipts report source/original preservation. No native/simulator/build/test, xcresult export/reinspection, product edits, deployment or commit occurred in packaging.

Scope is minimum17 **light** at Large/AX5. Minimum17dark, physical VoiceOver, all-route accessibility and original36/fresh41audit closure are not established. English animation-timeout qualification remains separate. [Unsigned Release verification](../release/README.md) is a separate build result, not an expansion of this UI scope. The minimum17 manifest is independent of the sealed light/dark packages.
