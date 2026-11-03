# B09 bounded capture handoff — not the complete B09 release

`CaptureReviewView(initialText:localeIdentifier:onReviewed:)` provides typed entry, explicit system paste, optional on-device speech, and selected-photo OCR. It returns `ReviewedCapture` only after the user accepts captured wording, edits it, confirms the wording/amounts/units/exclusions, and presses **Continue to list review**. The callback is delivered at most once per capture model. Capture contains no ledger, store, HTTP, analytics or household service dependency.

## Parent ledger connection

Present the view in a NavigationStack sheet from the existing list import screen. On review, put `capture.text` into the ledger's editable import draft and stage it with `ShoppingLedger.stageImport`, preserving the existing explicit quantity/duplicate decisions and final `commitImport`. Do not call `commitImport` directly from the capture callback. Keep the receiving shop/workspace identity and revision fixed; if they changed while the sheet was open, return to review for the intended destination. Dismiss/close on persona or household switch as well as ordinary route exit.

Map `CaptureSource.typed` → `.typed`, `.paste` → `.paste`, `.speech` → `.voice`. The current domain has no photo-OCR source. Add `.photoOCR` with the domain owner and update localized exhaustive switches before wiring photo capture; do not mislabel it as typed/paste. `ReviewedCapture.id` is stable for this capture, `originalText` preserves the recognized source wording, and `sourceImageData` is optional in-memory selected-image evidence. A parent may retain it only through its explicit reviewed attachment path; capture never writes it to disk or uploads it. The sheet shows a bounded image preview for comparison and discards its private state on exit/background.

## Permissions and devices

The root owner must add and localize these Info.plist privacy descriptions before custom speech is available:

- `NSMicrophoneUsageDescription`: “Use the microphone to dictate a list on this iPhone. Review the words before adding anything.” / “Usa el micrófono para dictar una lista en este iPhone. Revisa las palabras antes de añadir algo.”
- `NSSpeechRecognitionUsageDescription`: “Recognize your spoken list on this iPhone so you can review and edit it.” / “Reconoce tu lista hablada en este iPhone para que puedas revisarla y editarla.”

Missing descriptions, denied permissions, unsupported languages, unavailable microphones and unavailable on-device recognition all preserve typed entry. The recognizer requests permissions only after a tap, accepts English/Spanish locales only, verifies `supportsOnDeviceRecognition`, and sets `requiresOnDeviceRecognition = true`. It never falls back to online recognition. Recording stops on user action, final result, route/background exit or after 45 seconds. Audio buffers are not written, logged or retained after stopping. No synthesized readback exists in this slice.

PhotosPicker grants only the selected image; this path does not request broad photo-library permission or camera access. System-managed retrieval of an iCloud-backed selected photo may occur before the image is delivered; food text is never sent to a server by this module. Vision OCR uses local English/Spanish language support with automatic correction disabled. Original recognized wording and low-confidence lines remain visible. It does not authenticate a barcode, price, ingredient safety, payment or arrival.

Bounds are 20,000 characters/200 lines and 12 MB/30 megapixels per image. OCR runs off the main actor on a downsampled image, with cancellation forwarded to Vision and stale results ignored by generation. Paste never reads the clipboard on launch.

## Tests and evidence

The scratch suite tests typed fallback, denied/unavailable speech, candidate acceptance, edited wording/original evidence, repeated callbacks, at-most-once result delivery, limits, exclusions in both languages, late speech/OCR completion after close, and deterministic OCR reading order across all permutations of three nearby rows. It also exercises actual local Vision recognition on a generated two-line image. No live microphone permission or device speech-success claim is implied by injected-service tests.

Before release, perform on-device English/US-Spanish microphone and speech permission refusal separately, supported/unsupported recognition paths in airplane mode, noisy-kitchen and negation correction, interrupted recordings, low-light bilingual photo review, large text, VoiceOver, and scoped dismissal. Human review of Spanish copy remains required. The bounded capture module is installed in `ios/Features/Capture` with `ios/Tests/CaptureTests.swift`. All 14 scratch-package capture tests passed, including actual local Vision OCR on a synthetic image; the module/tests typecheck for iOS 17 and the en/es catalog compiles. Root wiring, privacy descriptions, physical-device speech/permission tests and remaining B09 work are separate. Readback files remain in scratch pending their own review.

## Explicit next B09 scope

- N02 structured item/count/unit/pack/purpose/destination review beyond the existing ledger's item/quantity/duplicate stage; contributor request-only routing and existing operation-key semantics.
- N04 optional per-device/profile/locale product-name correction store, explicit remember/forget controls, future suggestions only, and no rewriting previous requests.
- N03 dated cook-instruction readback using local synthesis, pause/stop/repeat, cancellation on route change and VoiceOver interruption/resumption policy.
- N07 spoken guest proposal connected to the B08 guest/entitlement planner port, with exact meal/count and pack/lunch/cap preview before Apply.
- E02 camera capture, barcode identification/manual match, package attachment persistence, and receipt/recipe-specific structured review. No prices, receipt posting, food arrival or safe-ingredient claim can follow automatically.
- Share extension with a bounded explicit staging inbox; protected WidgetKit shortcut/App Group projection; printable list; aisle/store sort; local reminder authorization and stale-deadline routing. These need separate target/app-group/deep-link/device work and are not implemented here.

Apple APIs: [on-device recognition requirement](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition), [microphone permission](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)), [local text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images).
