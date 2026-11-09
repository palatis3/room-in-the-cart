# Minimum-iOS callback reduction — November 9, 2026

The revised isolated SwiftUI/XCTest reduction **passes on iOS 17.5**, but does
**not reproduce or resolve the original app's XCTest logging callback crash**.
Original app compatibility and combined qualification remain incomplete.

R2 had reduced a multi-control ingredient Form row to a single field. Its
accessibility frame covered the whole 343×84.5-point cell, and the existing center
tap did not establish keyboard focus. R3 restores the original sibling controls
and nested field helper with local fixture state. The amount now exposes a
311×22-point child, matching the original app's observed field shape. No focus
gesture, forced first responder, changed tap or increased test allowance was added.

The one Spanish case completed both edits, both Done probes, Review and Edit:

| Evidence | Result |
| --- | --- |
| Build for testing | Exit 0, 24.17 seconds |
| Native test | Exit 0, 38.93 test seconds / 44.25 command seconds |
| Strict result verification | Exit 0; exactly one expected case; no reported runtime warnings or restarts |
| Explicit operations | 92 query entrypoints, 17 actions, 4 gestures, 8 snapshots, 4 screenshots; within unchanged caps |
| Before-typing receipt | Retained, 416 bytes; cached field frame (32,351.5,311,22); no added accessibility reads |
| Root visual review | All four images inspected; keyboard appears/disappears as expected and the edited blank/4 values remain |
| Preservation | Source/products and original result hashes unchanged; exports completed once on a verified clone |

This small case removes the original app's larger state, accessibility tree and
accumulated logging. Its success cannot close the earlier full-journey failures.
Do not repeat it unchanged or suppress runtime logging to claim compatibility.

The local fixture alone uses `-collect-test-diagnostics never`, retaining normal
runtime checkers and explicit attachments. Production workflow policy is unchanged.
The initial build-review text matcher expected different punctuation in the two
known AppIntents metadata notices and failed; the shell nevertheless launched the
next command. Root immediately verified both notices against retained output,
recorded the correction, and retained that same test handle. No unexpected compiler
diagnostic or retry occurred. Future phases must use separate checked invocations.

## Retained evidence

All originals are local under `.build/MinimumOSXCTestReproducerNov09/`:

- R1/R2 failures and R2 fidelity review remain preserved.
- R3 frozen manifest: `r3/manifest.json`, SHA256
  `594e352389c94b849818a3ce0a4a48d8555c0c01f0ee15d3811bf8883b0f1e38`.
- R3 bound execution and visual review: `r3/execution/result-review.json`, SHA256
  `bf76fcbbe0bc71d6b3a3efbc2d304736e441f94636daeb56a0c64b810cfc455c`.
- Once-inspected original/clone, summaries, issue data and attachments:
  `r3/execution/inspection/`.

Apple's [support table](https://developer.apple.com/xcode/system-requirements)
lists iOS 17 or later simulator support for Xcode 27.1. Chromium's
[upstream callback fix](https://chromium.googlesource.com/chromium/src/+/0a50e97c47f570ed9a414dedbe89e4f58b2885f5)
removed its custom framework injection. Our inspected project does not use that
injection, so the precedent does not establish a repair here. Source notes are
retained in `official-notes/callback-upstream-review.md`; no external report was sent.

## Original crash: retained sender provenance

One predicate-only query for the original PID67330 over05:45:09–05:45:15UTC
stopped at the4MiBstdout cap after0.913s. No app journey was rerun. Private
0700/0600 storage contains the unchanged capped raw prefix; no raw message bodies
are included in this report.

The prefix has2678complete JSON records over0.128840s, all from subsystem
`com.apple.dt.xctest` and the exact XCTAutomationSupport image UUID in the crash.
2579 records belong to the original faulting main thread. Repeated format hashes
include fixed attribute/fetch terms. This directly identifies concentrated
framework logging in the retained prefix; it does not establish total emitted
volume, drops, the quarantine threshold or the null callback argument. The last
complete record ends5.404440s before the crash. No wider query or suppression is
justified by this result.

A read-only binary UUID comparison also confirms the original crash loaded the
17.5 Main Thread Checker and RPAC images. An older26.2 path in the generated test
plan alone did not describe the actual loaded image; it is not grounds to replace
injected frameworks.

- Private prefix review manifest: `r3/execution/original-pid-retained-logs/prefix-review/manifest.json`, SHA256 `b2b5d06a873084c6cbf0ec711e9ff5afb615b30e9bb8032ce8bbda45c0e4672a`.
- Actual image comparison: `r3/execution/checker-image-review.json`.
- Prepare an upstream report from the preserved original failures and identify
  the passing R3 as a non-reproducing reduction. No external report is submitted.
