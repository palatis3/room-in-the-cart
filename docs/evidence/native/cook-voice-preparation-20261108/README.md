# Installed-voice preparation

The app now discovers installed readback voices on a dedicated user-initiated queue. The synthesizer, utterances and playback controls remain on MainActor. The catalog belongs to one playback: Pause/Resume reuse it; Stop and a new playback invalidate it. Generation checks reject late lookup and audio-session completions without releasing a newer owner that reused the same playback ID. English/Spanish installed-voice selection and the visible-text fallback remain unchanged.

The iOS SDK explicitly marks AVSpeechSynthesisVoice Sendable; it marks the synthesizer and utterance non-Sendable. This change crosses the queue only with voice objects. It does not move the synthesizer between executors or change authority checks.

## Review and validation

Root and an independent reviewer examined the exact source pins in the run receipts. Neither found an actionable correctness or race defect. Six new deterministic tests cover cancellation, superseded lookup, a late activation using the same playback ID, Stop/VoiceOver/authority changes, catalog reuse/refresh and missing voices.

- Focused readback tests: 16/16 native and strict passes.
- Full ordinary Debug model selection: 702/702 native and strict passes. The 16 focused cases are included in these 702.
- Both inspections found zero recorded runtime warnings and zero observed idle/restart messages; source and original result bundles remained unchanged.
- The compiled ordinary Debug app passed executable, assets, privacy, environment and embedded-extension validation.
- The final-source unsigned generic arm64 iPhone Release build and compiled-bundle checks passed. This is compilation validation, not distribution signing or device execution.
- The original five shared-cook fixture journeys passed in their original order, including actual Play/Pause/Resume/Stop taps. Their strict check failed: the existing speech priority warning still has no Complete Issue Description attachment. Warning count is unavailable, not zero. The log has zero observed idle/restart messages. Source and original result bundle remained unchanged. See the fixture receipts.

The native runs use Xcode 27.1, iPhone 17 Simulator and iOS 26.2 (23C54). Model runs use ordinary Debug products; fixture conditions are separately recorded. No timing instrumentation is installed in the product.

## Limits

The earlier diagnostic observed an approximately 84 ms main-thread voice lookup and a 62 ms Pause call under Debug/XCTest/Thread Performance Checker. Those are diagnostic call intervals, not physical-device or Release frame-time measurements. Moving lookup off MainActor does not establish that Pause or framework QoS warnings are fixed. The existing strict warning gate remains unchanged. Hosted CI, physical-device acceptance and full release readiness remain separate.

Private original results and logs remain under `.build/CookVoicePreparationNov08/`. Public receipts preserve the bounded outcomes and exact source patch; they do not include the raw result bundles.

## Minimum OS follow-up

iOS 17.0 on iPhone SE passed all 16 focused readback tests with zero recorded runtime warnings. The original five UI journeys passed four cases and failed the saved-copy test because it queried a TextField while the actual editor was a TextView. Playback controls were exercised; the original failure is preserved in `minimum-os/`.

A portable editor-role lookup retains exact full-value equality. The complete affected journey subsequently passed on iOS 17 light and iOS 26.2 dark with zero recorded runtime warnings. These are separate runs, not a relabeling of the original five-case result. [Saved-copy follow-up](../shared-cook-history-surfaces-20261108/README.md) records styling, stronger dismissal assertions and the separate unresolved first dark share-dismissal failure.
