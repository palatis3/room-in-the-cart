# One Spanish Done diagnostic

Diagnostic-only overlay on exact `b359d0743c2db77bb81a00a1c7e69036aa12ab77`. It is not a production fix, release acceptance, or a reproduction claim. The root reviewer owns applying, committing, compiling, local wiring, branch publication and the single manual hosted dispatch. This preparation did none of those actions.

## Source boundary

The only instrumented sources are Theme.swift, ComparisonView.swift and RoomInTheCartUITests.swift. `preservation.py` removes DEBUG instrumentation and the equivalent one-call dismiss wrapper/optional static call-site parameter, then requires the three exact b359 source hashes. All original buttons, Done hit geometry, focus writes, typing, waits, assertions, saved-value checks and selector remain. No private XCTest API, idleness override, animation suppression, UI seeding, toggle/tap retry or keyboard-default modification is introduced.

Opt in explicitly with the runner environment `TEST_RUNNER_RITC_SPANISH_DONE_DIAGNOSTIC=1`; the original test forwards the stripped runner variable to its app launches. When enabled, the app installs public UIKit keyboard/editing notifications once per process. Done entry/exit, aggregate visible focus and comparison focus changes emit only fixed enum tokens. Call sites are reduced to `comparison`, `other` or `process`; file paths and contents are never emitted. Process-wide notifications do not identify a particular field. The existing `inputFocused = nil` executes exactly once in its original closure.

The journal lives only at `Library/Caches/SpanishDoneDiagnostic/process-<PID>.events` within the owned app data container. It is exclusively created (0600, O_EXCL, O_NOFOLLOW), never truncated/reused, main-actor serialized, and limited to 2,048 events / 256 KiB per process. Each synchronous FileHandle write contains one full line:

```
SDD1|PID|SEQUENCE|SYSTEM_UPTIME|FIXED_EVENT|FIXED_SCOPE
```

The same line is emitted with OSLog notice level under subsystem `dev.roominthecart.spanishdone`, category `events`. Journal open/write/limit errors emit fixed `SDD_ERROR` markers and stop recording; they never change the app's UI action or turn a test into a pass. No typed text, food name, model object, arbitrary identifier or notification payload is read. There is no per-event fsync, timer, hidden view, layout measurement, asynchronous actor hop, responder resignation or animation setting in the app instrumentation. File I/O, observers and external recording can nevertheless change scheduling; a pass remains nonreproduction.

The original bQuantity Done call is bracketed only with flushed runner PID/uptime markers. No extra accessibility query or screenshot is inserted before the tap. The original app launch/relaunch and all business assertions are unchanged.

## Host and local runner

`run.py prepare` requires a clean exact EXPECTED_SHA, changes from b359 limited to this overlay, no untracked source/harness inputs, and source normalization proof. Representative mode pins arm64 Xcode26.3/17C529, iPhone17 and iOS26.2/23C54; actual hosted image version is recorded rather than assumed reproducible. It creates one uniquely named owned simulator, verifies boot exit and rejects the observed exit-zero migration failure. It does not erase, retry or use an existing device. Local `--wiring` relaxes only the toolchain/runtime pin, records `wiringOnly: true`, and requires both an explicit runtime identifier and `DIAGNOSTIC_RUNTIME_BUILD` in the local driver. Inventory selection matches identifier plus build, so duplicate identifiers with different builds are handled deliberately. Representative mode never substitutes another build. After boot, before build and before test, the runner independently queries the owned device’s `SIMULATOR_RUNTIME_BUILD_VERSION`. `identity.json` records expected, inventory and actual builds separately; numbered `runtime-check-*.json` observations and `runtime-selection.json` retain mismatch or missing-build evidence. Any mismatch aborts without substitution or retry. It still requires the exact reviewed diagnostic source commit and a newly owned simulator.

`build.sh` verifies the actual booted runtime build before any xcodebuild, then compiles the original core Debug scheme without contributor fixture conditions, enumerates and strictly checks the complete compiled inventory, requires the Spanish selector exactly once, freezes every product/source hash and archives the products. A failed enumeration is retained; there is no recovery retry. Do not reuse old169 stock/history binaries: they contain the earlier Done layout and a different build profile.

`run.py execute` starts a narrow OSLog stream and host-owned simulator video before launching exactly one xcodebuild. Capture PIDs/start times are retained. It uses only:

`RoomInTheCartUITests/RoomInTheCartUITests/testSpanishEntryPreservesOriginalFoodNameAndSavedAnswer`

The test uses normal XCTest idling, parallel testing NO, timeouts YES, default720/max900 seconds and collect-test-diagnostics never. The workflow's 21-minute execution ceiling and 70-minute overall budget leave separate build/collection overhead; testcase allowances are unchanged. A before-bQuantity-Done marker schedules exactly two external screenshots at approximately +5 and +15 seconds, each with its own bounded command timeout. These host observations do not ask XCTest to become idle. The original test process return code is saved independently; cancellation signals remain failures, including interruption after xcodebuild has already returned zero. Existing invocation evidence forbids a second invocation or retry.

Cleanup signals only capture child objects started by this invocation. Video gets a graceful SIGINT and bounded wait; forced termination is capture failure. The always-run collector preserves raw test status before checking frozen-source and simulator ownership. If either check fails, it records `validationNotRun` and capture failure; it cannot claim strict-result replay in that case. When both pass, the original strict warning/result validator runs independently of capture status. It copies only up to eight bounded regular fixed-name journals, never the rest of the app data container, and independently exports persisted OSLog. Ownership checks require the exact UUID, unique name and runtime before collection or shutdown. Final cleanup shuts down only that owned device, leaving it available for inspection; it never deletes a device.

## Capture verdict and limits

`test-status.json` retains the actual xcodebuild status. `test-result.json` records original strict-result verification or export failures. `capture-status.json` separately records capture integrity. A test failure remains failure even when capture is complete; an incomplete capture remains incomplete even when XCTest passed.

Complete capture requires all of the following:

- Per-process journals begin with observer activation, have contiguous sequences/monotonic uptime, contain only fixed tokens, and match the live and persisted event sequences exactly.
- One complete ordered runner marker pair, comparison bQuantity focus from exactly one app PID before the before-marker, and events from that same PID strictly after the returned Done marker. Another relaunched app process cannot supply this coverage. Missing return/coverage is conservatively incomplete, even if partial evidence is useful.
- Live stream survives until controlled stop, video exits normally with a nonempty retained file, and both external screenshots succeed and pass full PNG chunk/CRC/compression/scanline validation.

The movie is retained but deliberately reported `videoDecoded: false`; successful recorder exit is not a decode claim. Machine completeness relies on the two decoded stills. Root should play the movie to inspect the actual pre-tap hit area and motion. The timed stills alone may miss a fast transition and do not establish exactly where the touch landed. An empty persisted export, sink discrepancy, journal failure, partial file, missing screenshot or forced recorder stop fails capture. The analyzer never emits an absent-event causal conclusion, even with structurally complete capture: `absenceInferenceAllowed` remains false and `causalConclusion` null.

Both PNGs are synthetic UI-test screen data from this single comparison test; no RecordsMedia case or prior media archive is selected or collected. The journal itself contains no user text.

## Review and execution sequence

1. Apply this overlay in an isolated diagnostic branch rooted at b359, not on the current acceptance candidate. Commit the reviewed files; EXPECTED_SHA must identify that exact clean diagnostic commit. Only the existing registered `.github/workflows/ios-fixtures.yml` is replaced, and only on the diagnostic branch. It has manual dispatch as its sole trigger; do not merge it to main or open a diagnostic PR that triggers acceptance workflows.
2. Run the synthetic checks below. Root then performs local instrumentation wiring with an explicit installed runtime using `local-wiring.sh`. This is an actual full original-selector run, not a stand-in for hosted reproduction; inspect Swift concurrency/FileHandle compilation, opt-in propagation, scope tokens, all three sinks, marker pairing and capture cleanup. On failure, retain it and investigate rather than rerun automatically.
3. Only after root review, push the inert diagnostic branch and verify its SHA/workflow trigger. The previously registered fixtures workflowID407500252 can then be explicitly dispatched once on that ref with matching `expected_sha`. No workflow is dispatched by these helpers. Do not cancel the independent active b359 acceptance run.
4. Preserve original outcomes. A singleton pass is nonreproduction under this instrumentation/environment. This implementation does not automatically run the four-case UI02 prefix; any history follow-up requires a separate reviewed experiment using retained frozen products and explicit ordering.

Local wiring command, for root execution only after review/commit:

```
EXPECTED_SHA=<exact-reviewed-diagnostic-commit> \
DIAGNOSTIC_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-2 \
DIAGNOSTIC_RUNTIME_BUILD=23C54 \
bash diagnostics/spanish-done/local-wiring.sh
```

Offline checks already exercised during preparation:

```
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s diagnostics/spanish-done -p 'test_*.py' -v
bash -n diagnostics/spanish-done/build.sh
bash -n diagnostics/spanish-done/local-wiring.sh
actionlint -shellcheck='' -pyflakes='' .github/workflows/ios-fixtures.yml
```

The synthetic tests mock every native command/process. They cover sink gaps/duplicates/unknown data/limits, the prior empty-export failure, malformed marker pairs, PNG corruption/oversize/pending-recording text, bounded regular-file collection, graceful/forced capture cleanup, two bounded screenshot commands, unchanged one-selector720/900 invocation, preserving raw failure when collection fails, exact b359 source normalization, duplicate runtime identifiers with exact-build selection, missing-build refusal, actual boot mismatch retention/refusal, cross-PID coverage rejection, and cancellation after a zero test exit. They do not compile or execute the Swift instrumentation. No simulator/native-test/hosted operation was run in preparation.

## Observed hosted setup follow-up

Run42203081911 on commit161ab64 stopped before compilation or XCTest: bootstatus reported Finished, but the single runtime-build getenv query exceeded its30-second command deadline. No wrong build was observed; actualBuild remained unknown. The retained artifact and owned shutdown are separate from any app outcome.

The follow-up allows90seconds for that one metadata query and records its elapsed time and deadline. It still makes one query per required phase, refuses unknown or mismatched builds, and adds no retry. Other command deadlines, overall workflow/step limits, original720/900test allowances, Swift instrumentation, selector and business assertions remain unchanged. Local wiring for the unchanged Swift overlay is retained at161ab64; the two added negative/bounded setup checks exercise only the revised environment guard.

## Bounded simulator readiness

The second setup-only run42204324021 stopped on the first simulator inventory command at30seconds, before creating a device. In the original passing b359 core UI09 job, the equivalent inventory/selection took143.179seconds under an8-minute step with no30-second subprocess cap. [Upstream measurements](https://github.com/actions/runner-images/issues/15247) also report first-call durations up to152.9seconds on the older runner image; this supports a cold-start allowance but does not establish the cause of either failed setup here.

Inventory now makes one call with180seconds. Other one-shot simctl control reads/creation use90seconds; unrelated Git/toolchain calls remain30seconds. Each wrapper call records start/end/elapsed/deadline and success, exit failure or timeout in control-commands.jsonl, excluding stdout, environment and credentials. No warmup duplicate, query retry, simulator reset, toolchain or runtime substitution is added. Boot remains420seconds. The prepare8-minute and total70-minute limits stay hard caps.

The execution step allows21minutes for up to3control commands, the unchanged720/default900/maximum testcase limits, startup and capture finalization. Cleanup allows3minutes for one90-second identity lookup and30-second shutdown. These outer ceilings are not a guarantee that every worst-case delay fits; any outer timeout remains incomplete/failure. Collection keeps its8-minute cap and retains raw status before ownership/capture checks. No interrupted or incomplete result becomes a pass.
