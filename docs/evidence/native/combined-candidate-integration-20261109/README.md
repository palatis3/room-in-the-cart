# Combined Dinner and audio candidate — November 9, 2026

The eight reviewed R4 files are now installed in the canonical local app
candidate. All **561 product inputs match the previously tested frozen source**.
This consolidates the implementation; it does not claim full CI, minimum-iOS,
merge or App Store acceptance.

The Dinner changes keep field labels and long supply descriptions readable,
make the supply field's full row focus its editor, retain ingredient identity
across review/edit, and expose Edit at the top of long reviews. UI checks preserve
the original outcomes while avoiding repeated traversal and unnecessary snapshots.

The audio changes serialize shared audio-session ownership, distinguish playback
intent from its current preparation/lease, reject stale completions, and sequence
capture takeover after the matched playback Stop acknowledgement and release.
Controlled regressions cover those transitions. This does not establish acoustic
silence, physical-route behavior or removal of all synchronous framework waits.

## Validation and limits

Root reviewed the Dinner/UI delta; Astra independently reviewed audio ownership
and the exact eight-file integration. Frozen originals and prior canonical bytes
remain preserved. No unrelated app source was replaced.

Existing evidence applies to these identical product inputs:

- Original English Dinner and Spanish largest-text Dinner journeys: native/strict pass.
- Audio/capture/projection regressions: 64 cases passed on each of iOS 17.0 and 26.2.
- Original Free repair and cross-week meal-move journeys: native/strict pass.
- Unsigned Release compilation and app-bundle checks: pass.

After installation, generated-project, theme and localization checks pass. The
localization check covers 26 catalogs and 4307 English/Spanish entries; dynamic
compositions and human language review remain separate. Native tests were not
repeated solely for copying the same verified bytes. The final full regression
must run against the combined commit before merge.

The original Spanish journey still fails on iOS 17.0/17.5 in the XCTest logging
callback. The passing small reduction does not close it. Largest-text stock-summary
sampling, physical-device audio/capture behavior, wider accessibility review,
provider setup and signed distribution remain incomplete.

## Identity and retained originals

- Product source manifest: `.build/DinnerAudioCombinedNov09R4/source.json`, SHA256
  `ea06e1901c7921deb33eb322d667053de2f47534c8273f7487413457540fd968`.
- Prior scoped qualification: `.build/DinnerAudioCombinedNov09R4/qualification-checkpoint.json`,
  SHA256 `cac7f9d637877bebb88e1c822510c1fcbdd06e0f0f31c365d46d9011bb8c87cf`.
  Its historical `canonicalInstalled: false` predates this installation and is
  intentionally preserved.
- Installation/before-and-after hashes: `.build/CombinedCandidateIntegrationNov09/installation.json`,
  SHA256 `5df4735c766c8f10013ef5dc2ebaa3a03e601f87c7a0368154baf26c4c6da87a`.
- New local static checks: `.build/CombinedCandidateIntegrationNov09/static-validation.json`.

The exact destinations are `ios/Features/Capture/{CookReadbackModel,LocalCookSpeech,OnDeviceSpeechCapture}.swift`,
`ios/Features/Dinners/{DinnerEditors,DinnerIdeaSupplyViews}.swift`,
`ios/Features/Dinners/Dinners.xcstrings`, `ios/Tests/CookReadbackTests.swift`, and
`ios/UITests/FreeJourneyUITests.swift`.
