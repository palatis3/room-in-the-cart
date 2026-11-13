# Performance launch-readiness review — 2026-11-06

**Approve the proposed single explicit readiness assertion in `openPickupList`, as a bounded setup synchronization change.** No broader generic `reveal` change is warranted by this evidence. This is source-level review, not proof that a new native run passes or that Apple's missing scrolling series is repaired.

## Evidence and diagnosis

Reviewed local artifacts from run `42301547684`, candidate `f117439994835e0090376f4a29d81c478a6b86b4`, rendered shard `iphone-performance-rendered-1`. Source proof records the candidate as a six-file simulator-setup overlay of `804030e68473d022e72b464940061c01c611a0bd`, with native tests/application/fixture and performance gates unchanged. The recorded environment is Xcode 26.3 (17C529), iPhone 17 simulator, iOS 26.2 (23C54).

`Performance.log:21–40` shows:

| Relative time | Observation |
|---|---|
| 0.81–0.82s | App open/launch begins. |
| 8.03s | Automation session setup. |
| 10.08s | XCTest waits for app idle. |
| 11.33s | Immediate Shop button existence check. The next branch, corroborated by helper source, means it did not return true. |
| 11.41s | CollectionView existence check; helper chooses its ScrollView fallback. |
| 11.44s | First swipe attempts to operate on that ScrollView. |
| 11.45–13.52s | ScrollView lookup and retries. |
| 14.46s onward | Accessibility snapshot requested; swipe fails with “No matches found.” |
| 22.81–23.25s | Teardown records failure screenshot and terminates app. |

The later exported hierarchy (`attachments/49226ACC-46D3-418E-AC16-B17113955A66.txt:23,39,52–56`) contains `shopContentScroll`, the `openPickupList`/Start pickup button and a selected Shop tab. Attachment metadata places that hierarchy at epoch 1794003471.075; the later screenshot is at 1794003475.709. These later observations do not describe the earlier missing-element query. The screenshot was reviewed by the parent; this review independently read its manifest and the hierarchy, not its pixels.

The source path is `testRenderedFiveHundredItemPickup → importFixture → app.launch → openPickupList → tap → reveal`. `reveal` checks existence once, then assumes either a collection or scroll container exists. Here that assumption is premature. A launch/accessibility-readiness race is supported; the underlying reason for delayed accessibility availability (application startup, simulator or automation timing) is not established. This is the first navigation action, before fixture creation/import, before the 20 search/checkoff samples and before either JSON attachment. The selected rendered test failed (1 failed, 0 passed), and its metrics CSV manifest is empty. It supplies no successful rendered benchmark and no scrolling-metric observation.

## Proposed change and boundaries

At the beginning of `openPickupList`, immediately before the current `tap`:

```swift
XCTAssertTrue(app.tabBars.buttons["Shop"].waitForExistence(timeout: 10))
```

This requires the actual intended root control, fails explicitly if readiness never arrives, and uses the same root signal and 10-second allowance already used by the cold-launch case. `continueAfterFailure = false` is already set. An explanatory assertion message would improve diagnosis but is not required for correctness.

The call sites cover initial fixture entry for both rendered and scrolling tests and the rendered test's later relaunch. They are outside the rendered search/checkoff timers and outside the scroll `measure` closure; the cold-launch case does not call this helper and remains unchanged. Preserve all current timing starts/stops, five measurement iterations, 20 rendered samples, fixture and native Paste validation, row identities, functional checks, readiness/import deadlines, swipe behavior, baselines and required metrics.

This adds **up to 10 seconds of bounded setup waiting per helper call**; it does not increase any existing sample timeout, performance limit, baseline or workflow budget. The rendered path calls it twice; the scrolling path once. Actual XCTest operation overhead is separate. It should not be described as making no possible wall-clock difference. The wait is a condition check, not a fixed sleep, extra warm-up pass or retry of the whole test.

Existence is not a promise of hittability or successful import. The existing tap helper and subsequent assertions remain responsible for those failures. Do not broaden this into automatic relaunch/retry, a blanket delay in every `reveal`, or relaxed assertions: none is necessary to address the demonstrated precondition failure. The later hierarchy is compatible with readiness arriving within the proposed window, but it cannot prove that a counterfactual polling run would succeed.

## Verification scope

Read-only examination of source, log, summary, attachment manifest/hierarchy, toolchain and provenance. No tests, native tools, hosted actions, retries or source/Git edits. Only this scratch report and hash manifest were written. The parent coordinates any future collector. A subsequent authorized native run must independently establish setup completion and all existing strict metrics/baseline gates; retain this failed run as evidence.

The current native test source is byte-identical to the frozen candidate-verifier source: **false**.
