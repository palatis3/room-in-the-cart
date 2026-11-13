# Independent review of completed speech timing capture

The positive samples support **84.114750 ms elapsed inside installed-voice enumeration** and **61.634125 ms elapsed inside immediate Pause**, on the main thread of the actual instrumented adapter. These are synchronous call intervals, not exclusive CPU time, an NSCondition wait duration, or a measured duration of frozen rendering. No main-loop observer was installed. This review grants no runtime-warning acceptance and changes no parser result.

The completed parser remains `incomplete-or-review-required`, with no malformed/pairing/coverage problems: 38 valid markers, 19 pairs, all 12 operations. Native exit is 0; strict exit is 1. Both bounded log queries returned exit 0 and parseable arrays below the 8 MB caps, but each emitted the same 44-byte stderr: `getpwuid_r did not find a match for uid 501`. The message does not invalidate the identity and arithmetic of the positive samples. It also does not establish lossless capture; no claim of absent warnings or complete system-wide fault enumeration follows. Both exported arrays contain only `logEvent` records; no loss record is present in these filtered exports, which is not proof that no loss occurred.

## Independent checks

`audit.py` reads completed local files only. It independently parses all numeric markers, validates PID/boot/image and per-domain sequential calls, pairs the phases, checks same-thread/mach-tick order and exact case bounds, and compares all 19 independently calculated durations with the existing review. It verifies all 4,550 source-file hashes, both overlaid source hashes, command/selector/patch pins, and the two actual built Mach-O SHA-256/LC_UUID identities. It decodes all six raw blocked stacks and retains their separate structured emission backtraces. The 22 reviewed input files have identical hashes before and after this audit. No subprocess, native/result tool, simulator action, source change, or rerun was used. The original run/inspection receipts supply the completed run and original-bundle preservation history; this audit does not rerun those inspections.

The source is pinned to `e186dcf4e8fdb7b63646d1494cc7f1555e58777f` plus the reviewed two-file timing overlay. `source-pins.json` retains its original proposal-time status; completed execution is established by `run/run.json`, not by relabeling that frozen proposal. Candidate LocalCookSpeech SHA-256 is `260e30a46599501bc0034c42223c52b5dde48ded0c756b559dc8975f8afc5dcd`; candidate SharedDeliveryUITests SHA-256 is `97ceef0df87502de89c6a3df6661333b61022859c30dc8667c9d35f10d004c2f`. The runtime is iOS 26.2 build 23C54, Xcode 27.1 build 27A9275, as recorded by the completed run. The original five selectors/order are retained.

All 38 notices and six faults share PID **80665**, boot UUID `DB3998B1-2EF4-4C74-BA15-D1348E4C60E0`, and executable UUID `B24B8AED-2672-3FE1-BAB1-1AE7F6C8AC3C`. Notice sender UUID `450A7E28-01F8-3E1D-88A2-8680D1C19ACE` matches the SHA-pinned built debug dylib. Its SHA-256 is `c1df88d56757d8deaff53fca3f29d26dc4352ea0d2417b4f08170c23039c383b`; executable SHA-256 is `0ff5335b0b086a170699e5015fdea3ab85a97677dccb3ee7dbe9503861ec6ae5`. This is a source/build-product/runtime-image identity chain, not an independent installed-file SHA comparison or reproducible-build assertion.

## Timing and fault boundaries

Both selected pairs have `main=1`, domain 1, thread **25325802**. The source marks `LocalCookSpeech` MainActor and brackets the unchanged API calls. Entry logging finishes before the recorded begin; end is sampled before exit logging. These two direct API durations exclude their own logging writes. Broader method timings may include nested logging and are not interchangeable with direct API timings.

| Operation | Call | Monotonic begin → end (ns) | Elapsed | Log entry → exit UTC |
|---|---:|---|---:|---|
| speechVoices | 4 | 943499761825375 → 943499845940125 | 84.114750 ms | 09:38:27.651235 → 09:38:27.735424 |
| pauseSpeaking(.immediate) | 6 | 943502451717375 → 943502513351500 | 61.634125 ms | 09:38:30.341117 → 09:38:30.402837 |

Marker `DispatchTime.uptimeNanoseconds` and unified-log `machTimestamp` are separate units. Arithmetic uses only paired marker nanoseconds; fault bracketing uses ordered unified-log ticks on the same boot/thread, corroborated by wall timestamps. No assumed clock conversion is used. Logging timestamps delimit emission, not independently sampled API-entry instruction addresses.

All six faults report User-interactive waiting on Default and `-[NSCondition wait]`. All occur within the exact completed readback case and have logged thread 25325802. The event window is **4.657917 seconds**, not aggregate or individual blocking duration.

| Fault | UTC | Frames | Retained f90 exact UUID/offset comparison |
|---:|---|---:|---|
| 0 | 09:38:27.823893 | 23 | first 20 match event 0 |
| 1 | 09:38:28.847136 | 23 | first 20 match events 1/5 |
| 2 | 09:38:30.401132 | 62 | first 6 match Pause event 2; later current-app frames differ |
| 3 | 09:38:30.420261 | 23 | first 20 match event 3 |
| 4 | 09:38:31.889239 | 23 | first 20 match event 4 |
| 5 | 09:38:32.481810 | 23 | first 20 match events 1/5 |

Fault 0 is emitted 88.469 ms after the voice-enumeration exit marker. Its stack does not establish that the 84.114750 ms enumeration was the reported QoS wait. Fault 2 is inside the Pause marker bracket on the same thread. Pure Mach-O symbol-table lookup in the exact current dylib maps its app offset `0x313d0c` to `LocalCookSpeech.pause` +152, `0x314d18` to the protocol witness +12, and `0x2c745c` to `CookReadbackModel.pause` +124. This is strong call/stack correlation; it does not turn the complete 61.634125 ms call duration into a measured NSCondition wait duration. Symbol-table lookup is not full source-line symbolication of every stack frame.

The other five prefixes correspond to signatures present in the corrected prior worker control. That comparison does **not** label their current execution as background worker work: current records share the main-thread ID, and their decoded stacks include framework dispatch and application main frames. The historical direct Pause signature was absent from the properly PID-scoped worker sample, as documented in `worker-reconciliation-20261108`; the contaminated earlier ten-worker/all-signatures claim remains rejected.

The evidence establishes actual main-thread elapsed call costs in this one instrumented run and a Pause-path QoS event. It does not identify an app-owned synchronous queue wait, establish a supported replacement ownership model, validate the missing Complete Issue Description, prove UI frame responsiveness, or justify a warning exemption. No production repair is claimed. Any mitigation decision must preserve pause/resume/Stop ordering and delegate authority, and separately account for the other framework signatures.
