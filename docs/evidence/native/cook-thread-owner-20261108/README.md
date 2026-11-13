# Cook speech owner: isolated build and 40-test qualification

R3 passed generic iOS Simulator build-for-testing and exactly **40/40 selected tests** on the owned iPhone 17 Simulator, iOS 26.2/23C54. Native exit and strict inspection exit were both 0; no skips, failures or test runtime warnings were recorded. This is model and real-thread transport qualification with a confined fake speech engine. It is **not actual AVSpeech playback/acoustic acceptance, canonical installation, or a repair claim for the original QoS warning**.

The candidate is installed only in the detached `cook-owner-r2` worktree based on `e8b3c9f506f52025897a0d0eab9e96fd78215f44`. Canonical dinner/theme edits were intentionally excluded. The [556-file final source manifest](source/final-source-manifest.json) has SHA256 `6fb75b908ad294becfb3abdf06778bb8d2b98c4a411fbef8f15c068729726ae3`. The [complete five-file patch](source/final-integration.patch), [full 40-test source](source/CookReadbackTests.swift), [selectors](tests/selectors.txt), and [method preservation receipt](source/test-body-preservation.json) are included. All original 16 test bodies are byte-identical; all 40 r2→r3 bodies are byte-identical.

## Completed evidence

| Stage | Result and scope |
|---|---|
| Earlier pure Swift value prototype | Separate r2 prototype: 12 tests passed; no real thread/AV engine proof. [Receipt](receipts/pure-prototype-run.json). |
| First real-adapter r2 compile | Exit 65, source unchanged. Sole emitted error: missing AVFoundation import for `AVSpeechSynthesisVoice` in tests; two callback defaults emitted Sendable-conversion warnings. [Run](receipts/r2-failed-build.json), [primary diagnostics](receipts/r2-primary-diagnostics.json). |
| Narrow r3 correction | Two default arguments became capture-free explicitly Sendable closures; tests gained `import AVFoundation`. No suppression/unchecked annotation/test-body change. [Delta](source/r3-correction.patch), [pins](source/r3-preparation.json). |
| R3 generic Simulator compile | Exit 0, 16:07:53–16:12:06 UTC. Incremental same-DD build after preserving 84 r2 product entries and failed evidence. New speech compiler warnings absent; other warnings remain below. [Run](receipts/r3-build.json), [review](receipts/r3-build-review.json), [preservation](receipts/r2-preservation.json). |
| R3 selected tests | 16 original + 11 async model/notification + 13 real-owner lifecycle cases, 16:12:32–16:12:46 UTC. Serial jobs2, unchanged 720/900 limits, no retries or diagnostic suppression. [Run](receipts/r3-model-run.json), [strict report](tests/strict.txt), [summary](receipts/summary.json). |
| Inspection integrity | Original result, source and 236 compiled-product entries unchanged when inspected before the next phase. [Verification](receipts/strict-verification.json), [product hashes](receipts/compiled-products.json), [original-result hashes](receipts/original-result-before.json), [runtime warnings](receipts/runtime-warnings.json). |

Owner cases use the production Thread/CFRunLoopSource/mailbox/core and a non-Sendable fake engine constructed inside its owner thread. They verify creation/calls/destruction on one non-main thread; held Pause with MainActor revocation; Stop before queued Resume; false Stop and idle-preparation barriers; late/wrong terminal identity; repeated/late shutdown; deinit/new-view barriers; actual NotificationCenter delivery; and forced nested-run-loop reentrancy with consumed-wake recovery. They do not replace the engine with a delayed MainActor protocol callback.

## Remaining compiler warnings

The generic build was successful, **not warning-free**. These five existing test-warning sites remain (each emitted for both architectures):

| Existing site | Warning |
|---|---|
| `HouseholdRequestPackFixtureSupport.swift:93` | S24FixtureProtocol unavailable Sendable inheritance |
| `MembershipTests.swift:1294` | MembershipURLProtocol unavailable Sendable inheritance |
| `NavigationRestorationTests.swift:302` | RestorationProtocol unavailable Sendable inheritance |
| `PickupStockPrivateScopeIntegrationTests.swift:43` | StockScopeProtocol unavailable Sendable inheritance |
| `RecordsMediaTests.swift:9` | Initialized immutable property will not decode |

R3 also emitted incompatible-sysroot warnings for HouseholdClient, DeviceSurfaces and CoreDomain dynamic package products on both architectures. R2 emitted two analogous RecordArchive warnings. [Warning attribution](warning-attribution.json) retains all r3 primary warning lines and exact earlier log occurrences for every named site/package. Package source was unchanged by this proposal; the underlying sysroot cause remains unresolved. Prior occurrence is not a waiver. No-warning results from the 40 tests are not presented as absence of build warnings.

## Review and limits

Root reviewed ownership, mailbox/facade/model/view, shutdown liveness, terminal admission and Stop retry visibility. Independent review identified the terminal-getter reentrancy gap, then reviewed the full-turn guard and deterministic nested-source test and verified frozen identities/original test preservation. These are chat-delivered static reviews, recorded separately from execution in [provenance](provenance.json).

The actual-AV shared-cook fixture phase was ongoing when this package was prepared; its changing log was not read and its outcome is excluded. Real English/Spanish installed-voice behavior, repeat/natural end/background, audio-device route/VoiceOver acoustics and minimum-iOS native behavior still require their own evidence. The original framework condition-wait duration/signaler is unresolved. There is no hard acoustic Stop bound, QoS lowering, log mute, idleness bypass or warning waiver here. Canonical source, parent acceptance/handoff documents and commits were not changed by this packaging task.
