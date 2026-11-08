# Actual speech-call timing, original five-case sequence

All five original cook/recovery/closeout cases passed in their original order. Strict verification still fails on the reproduced QoS warning's missing Complete Issue Description. The supplied7,518-line console has zero observed animation-idle misses or runner restarts. Original source and result bundle remain unchanged. [Strict result](strict-verification.txt) · [Inspection](verification.json) · [Run identity](run-identity.json)

Bounded post-terminal queries retained38 numeric markers forming19 validated pairs across all12 instrumented operations, and six actual HangRisk fault records. All pairs share the expected source/runtime-image identity and case scope; no pairing or operation-coverage problem was found. Both exporters returned0 but each retained the same44-byte `getpwuid_r` stderr. The parser consequently remains `incomplete-or-review-required`. Independent review supports the positive measurements while preserving that status and the strict failure. No lossless-retention, absent-warning or performance-pass claim follows. [Summary and exact paired values](timing-summary.json) · [Independent review](independent-review.md)

| Observed synchronous scope | Elapsed milliseconds | Calling context |
|---|---:|---|
| Installed-voice enumeration | 84.114750 | MainActor / main thread |
| Speak API | 0.241750 | MainActor / main thread |
| Immediate Pause API | 61.634125 | MainActor / main thread |
| Resume method, including its guard | 0.017541 | MainActor / main thread |
| Immediate Stop API | 0.029625 | MainActor / main thread |
| Audio activation scope, maximum of two | 75.363375 | Existing background audio queue |

These are one Debug/XCTest/Thread Performance Checker run's elapsed call intervals. They are not exclusive CPU time, a measured rendering freeze, an exact NSCondition wait duration, or Release/physical-device latency. Direct intervals exclude their own marker writes; enclosing method scopes can include nested marker overhead. [Instrumentation patch](diagnostic.patch) shows unchanged speech actions with bounded numeric-only markers; the code was never installed into canonical product source.

The Pause fault is bracketed by its same-thread markers, with exact current-binary symbols corroborating LocalCookSpeech.pause and CookReadbackModel.pause. The first fault occurs88.469ms after voice-enumeration exit, so that warning cannot be attributed to the measured enumeration from this evidence. The other five retained prefixes resemble earlier framework signatures, but these current records are on the main thread and must not be mislabeled as background-worker faults. The six-event4.657917-second window is not a blocking duration.

This finding motivates reviewing asynchronous installed-voice preparation while preserving synthesizer ownership and immediate Stop. It does not establish a remedy for Pause or the broader QoS warning. That product change requires separate tests; no warning allowance, collection-mode change or automatic diagnostic repeat is justified here.

The private complete evidence remains under `.build/CookSpeechTimingNov08/execution-r1/run/` and `independent-review-r1/`. A separate sibling inspector corrected a selector-path mismatch and disabled bytecode writes before any inspection; sealed execution inputs were unchanged. Raw system/application logs are not included here. [Source pins](source-pins.json) · [Published manifest](manifest.json)
