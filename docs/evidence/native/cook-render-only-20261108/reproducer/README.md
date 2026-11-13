> Execution note: this retained copy was built and tested after correcting three CoreFoundation symbol spellings. See ../README.md for the failed native/strict results. The original preparation protocol below is historical.

# Standalone cook speech render-only probe — unbuilt proposal

This standalone app and one UI test implement only the independently useful render-only first stage of the reviewed buffer-speech assessment. It is a falsification probe, not a replacement for app readback or a 20,000-character qualification. Nothing in this package was compiled, installed, launched or tested natively during preparation.

The project reuses the repository's two-target standalone toggle project structure, renamed to `CookRenderDiagnostic` and `CookRenderDiagnosticUITests`. App bundle ID: `org.roominthecart.diagnostics.cookrender`; test bundle ID adds `.uitests`. It has no dependency on the RoomInTheCart app, production data, network, player/engine, microphone/recognition, audio capture or explicit audio-session activation. The generated Info.plist has no recording/recognition permission strings or background-audio mode.

## Exact fixture and ownership

One explicit Render once tap admits one generation per app launch. Only installed en-US is accepted; absence fails rather than skipping or selecting a fallback. The utterance uses the default speech rate. The exact existing English text literal comes from `CookReadbackTests.instruction`'s default `text` parameter, source line 6. Its UTF-8 length is 63 bytes and SHA256 is `2704786f1a091e0ff325e09861304582ef3849ead4c47809e93629628a90c1ef`. The original model fixture defaults its locale to es-US; this explicitly scoped experiment uses the same English text with the requested en-US voice. No text is repeated, truncated or added. The literal appears only in the reviewable app source; runtime UI, attachments and deliberate logging contain no text or audio. Source/provenance hashes are in the package receipt.

A dedicated run-loop thread has `qualityOfService = .default`. Synthesizer, utterance, delegate and private file ownership stay there. MainActor only submits Start and receives final scalar metadata. The unspecified callback thread copies into a capped mailbox; it performs no disk writes or synchronous wait for main/owner. Owner file writes occur outside the mailbox lock. Matching terminal events require both synthesizer and utterance identity, and callbacks capture this single generation's mailbox. No new generation can start.

`qos_class_self()` and thread IDs are recorded at relevant boundaries, with the field deliberately named `reportedQoSClass`. The public SDK's `pthread/qos.h` says QoS overrides are not visible through that API; this is **not proof of effective scheduler priority or absence of donation**. The test checks that the owner reports Default before Start/write and is not main. Callback context is evidence, not an assumption of owner-thread callbacks.

## Bounds and evidence

The probe allows two copied buffers with at most 1 MiB combined payload reservations, one private CAF, at most 32 MiB observed file size (PCM admission reserves 64 KiB for container overhead), 512 scalar events and 256 KiB serialized metadata. Source buffer sizes are validated before copy allocation. Reservations include owner-held packets until their autoreleasepool ends. Unsupported/changed format, capacity overflow, write error, metadata overflow or timeout is a failed attempt; no dropped/truncated audio is accepted as completion. Opaque framework allocations are not bounded by these application-owned limits. File size is checked after writes and after close; this is a measured bound, not a guarantee of zero transient filesystem overshoot.

The private temporary directory/file use 0700/0600 permissions, complete file protection and no-backup directory metadata. The file is closed and the owned directory removed before a normal report; deletion outcome is recorded. The audio is never attached or exported. If cleanup fails, the test fails. Root must remove the distinct diagnostic installation after inspection when an aborted attempt leaves cleanup unknown; no broad container export is needed.

The owner deadline and independently scheduled Default-QoS watchdog are 30 seconds. They do not preempt a blocked native call. A watchdog report preserves unknown cleanup/native retirement and cannot later become a pass. The UI test waits 35 seconds for a report; this does not bound XCTest's own UI idling. Root's existing bounded native supervision remains required. No timeout was relaxed and no retry was added.

A normal result is named `observed-end`: one matched didFinish, at least one zero-frame buffer, positive accounted/written frames, no pending copies, an unchanged format and 250 ms of observed callback quiet. The quiet interval and zero buffer are **not documented EOF/completeness guarantees**. The metadata explicitly says completion is observation only. Renderer finish is not acoustic proof; this app never plays audio. Late callbacks before the report fail test validation, while later behavior cannot be inferred from this finite observation.

On failure, the owner invalidates callback admission and attempts native Stop once on its own thread. Stop return/duration are metadata, not a new acceptance path. If no matching native terminal was observed, the one native core remains retained until process exit; it is not replaced or declared retired. A blocked owner may never reach cleanup; watchdog reporting makes that unknown explicit. There is no separately implemented preparation-cancellation experiment in this first package.

The single UI test attaches `CookRenderMetadata.json`, checks observations/limits/cleanup and terminates the diagnostic app. It does not grant runtime-warning acceptance. The unchanged strict result checker must independently inspect the original result and complete runtime-warning diagnostics. Missing issue attachments stay a strict failure. A render-only reproduction of the known framework-main fault is sufficient to falsify the proposed overall warning repair without implementing playback.

## Root-only protocol and commands — not executed

1. Review the package manifest, source/header pins, one selector and permissions. Preserve a frozen copy. Select a dedicated/authorized simulator only after the current native lane is free. These commands neither select nor create a simulator. Do not reuse production DerivedData or an existing result path.
2. Build this standalone project once into a fresh diagnostic directory. Review all compiler diagnostics; the Swift sources have had structural/source review only, not typechecking. Freeze the built products, xctestrun file and executable UUID/hash before running.
3. Run the single original diagnostic test once with normal XCTest and 720/900 allowances. Preserve the original native log/result on every outcome, including timeout, missing voice or callback overflow. Root's established external process/disk watchdog must own this command; no new execution harness is provided.
4. After terminal native execution, use the existing inspector/strict checker. Retain only the metadata attachment and required test/warning diagnostics; never archive the private CAF or app container. Review any framework-generated log text before publishing a sanitized evidence subset; preserve private originals. Keep strict/native outcomes separate.

Example variables below are intentionally unset placeholders; root chooses fresh absolute paths and the authorized simulator. `CONTROL` is this directory after copying/applying the proposal in scratch, `RUN` is a new evidence directory, and `REPO` is the canonical repository for the unchanged checker.

```bash
: "${CONTROL:?Absolute reviewed standalone directory}"
: "${RUN:?Fresh absolute evidence directory}"
: "${SIMULATOR_ID:?Root-selected authorized simulator UUID}"
: "${REPO:?Canonical repository with pinned unchanged checker}"
mkdir "$RUN"
set -o pipefail
xcodebuild -project "$CONTROL/CookRenderDiagnostic.xcodeproj" -scheme CookRenderDiagnostic \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -parallel-testing-enabled NO -jobs 2 -derivedDataPath "$RUN/DerivedData" \
  CODE_SIGN_IDENTITY=- build-for-testing 2>&1 | tee "$RUN/Build.log"
```

Stop for root review of the build and product pins before this separate command block:

```bash
runs=("$RUN"/DerivedData/Build/Products/CookRenderDiagnostic_iphonesimulator*.xctestrun)
test "${#runs[@]}" -eq 1 && test -f "${runs[0]}"
selector=CookRenderDiagnosticUITests/CookRenderDiagnosticUITests/testRenderOneInstalledEnglishFixtureWithoutPlayback
printf '%s\n' "$selector" > "$RUN/selectors.txt"
native_exit=0
xcodebuild -xctestrun "${runs[0]}" -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -resultBundlePath "$RUN/Tests.xcresult" -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 720 \
  -maximum-test-execution-time-allowance 900 -collect-test-diagnostics on-failure \
  "-only-testing:$selector" test-without-building > "$RUN/Tests.log" 2>&1 || native_exit=$?
printf '%s\n' "$native_exit" > "$RUN/native-status.txt"
```

After the native process is terminal, root's existing bounded result-inspection process can execute the following unchanged APIs. Failed export/strict inspection remains failure; no original is edited or replaced. Export only the named metadata attachment through the existing reviewed attachment inspector, not a new broad export here.

```bash
xcrun xcresulttool get test-results summary --path "$RUN/Tests.xcresult" --compact > "$RUN/test-summary.json"
xcrun xcresulttool get test-results tests --path "$RUN/Tests.xcresult" --compact > "$RUN/test-details.json"
strict_exit=0
python3 "$REPO/scripts/check_ios_test_results.py" --selectors "$RUN/selectors.txt" --expected-count 1 \
  --summary "$RUN/test-summary.json" --tests "$RUN/test-details.json" \
  --result-bundle "$RUN/Tests.xcresult" --test-log "$RUN/Tests.log" \
  > "$RUN/verification.txt" 2>&1 || strict_exit=$?
printf '%s\n' "$strict_exit" > "$RUN/strict-status.txt"
```

A clean result would only support further review. Playback, audible Stop/latency, Spanish, real app authorization, long-input limits and physical VoiceOver/routes remain out of scope. No player phase should be added merely to finish this experiment when render-only already falsifies the warning hypothesis.
