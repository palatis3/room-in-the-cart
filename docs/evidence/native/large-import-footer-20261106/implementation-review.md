# Independent large-import footer implementation review

No blocking source defect found in the bounded two-file change. The implementation makes the existing confirmation action reachable directly after Review without changing import decisions or persistence. Native fixed-result verification remains pending at this review; no tests, builds, Git commands or simulator actions were performed by the reviewer.

## Scope and behavior

Compared current files against the retained `before/` copies using a read-only textual diff. In `ios/Features/Ledger/LedgerSheets.swift:100–106`, a preview-only bottom safe-area inset holds the single existing `ledgerCommitImport` action. There is no duplicate in the Form, no overlay covering Form rows, and no hard height or clipping constraint. The original text, source image, editable row bindings, duplicate decisions, edit-original/edit-captured paths, Cancel, interactive-dismiss guard, capture authorization/invalidation and scene-background handling are retained.

The extracted confirmation handler at lines 151–166 is identical to the previous inline handler after indentation normalization. It still checks captured-source authorization, constructs the same decisions from the same preview, calls the same `editShop` key and `commitImport`, and dismisses only on success. The only enablement change is adding `model.hasPendingSave`, preventing a fresh Add while Retry/Discard owns a pending save. All source from `liveCaptureBinding` onward is byte-identical to the retained before copy, including row and validation helpers. No fixture, performance loop, threshold or metric change is present in these two files.

## Recovery layout and focus

`showingImportStatus` (142–144) requires a preview and saving, pending save or error. Its complementary branches (29–32 and 96–98) render exactly one `LedgerSaveStatus`: first Form section during an active issue, original bottom position otherwise. The unchanged component retains full errors, progress, Retry, Discard and saved context; its existing successful Retry callback still dismisses (146–148). Recovery uses the Form's normal scrolling and keyboard avoidance rather than compressing long errors into the footer.

The task key includes preview identity, error text, saving and pending individually (123–139), so an error replacement while a pending save remains true is observed, as is entry into a preview with an existing issue. The task yields, checks cancellation and active state, scrolls to the inserted section, and sets outer status accessibility focus. This addresses the source-level problem that a newly mounted child already containing an error cannot rely solely on its internal `onChange(error)`.

A single `Task.yield()` is not proof that SwiftUI has completed layout. Static review cannot establish the actual scroll/focus response, VoiceOver announcement, or reachability of long recovery controls at largest text with a keyboard. Those are explicit native validation limits, not an observed defect. The planned three ordinary journeys do not force a write failure or test recovery layout; their success must not be described as proof of that state.

## Regression assertions and negative control

`ios/UITests/ContextualNavigationUITests.swift:125–132` adds checks only after the original 500-line native Paste, edit/undo, keyboard Done, short-scroll Review and editable-preview assertions. No previous assertion, gesture or timeout is removed. Without any preview reveal/swipe, the new checks require one existing confirmation button, hittable and enabled, with its full vertical frame below navigation and inside the window and height at least 44 points. This is meaningful evidence for initial accessible confirmation of this largest-text distinct-line preview. The native test does not tap Add or create a failed-save state; separate duplicate/restart and long-filtered cancellation journeys cover their own behaviors. Window bounds and hittability are not a complete assertion of every safe-area/keyboard permutation.

The retained `negative-source` production file is byte-identical to the before copy; its test file is byte-identical to the reviewed current test. `negative.log:1077` reports the exact new immediate-presence assertion failure; lines 1084–1090 report one test, one failure, 69.934 seconds. The invocation selects only `ContextualNavigationUITests/testLargeTextKeepsLongNativePasteEditableAndReviewReachable`; result exit is 65. This supports a real old-product regression failure after the original checks, not a successful fixed-product result. The negative log includes an AppIntents metadata warning and a debugger-version lookup diagnostic; no zero-build-warning claim is made.

## Reviewed identities

- Current `ios/Features/Ledger/LedgerSheets.swift`: `5de62273f7549831cdfd44268cc24953d19e7507fc840d632d0a81a21551c878`
- Before `ios/Features/Ledger/LedgerSheets.swift`: `ed8fedf68f925bf7f70b02cf799acbd2f46d6d9b527bf8ee7aa6800f96e06849`
- Current `ios/UITests/ContextualNavigationUITests.swift`: `ac70599b0e770d1c7eeb408c00912606c838fb27038671eadeea3ad9a13817fc`
- Before `ios/UITests/ContextualNavigationUITests.swift`: `4d48351fdc8a09111484426583c69e23de6cac04553883ba461c15209b71812f`
- `negative.log`: `456ae607f96a27432ea963f07da5c3f7967eccd2da4cba84dcf3547991ed62ce`
- `negative-invocation.json`: `f5440f8d236a485c852f34afd73f4292fff8aad7d2207d17d010723de0d97b64`
- `negative-result.json`: `fc506d15866376fbe2d4a48bce0a6117a93213253b3452bd45a194748ff50857`
- `negative-source.json`: `a939cfef899d6aa1324d80843f3fb5e72f3025ec1634c14a37e56417b6ce1ae2`
