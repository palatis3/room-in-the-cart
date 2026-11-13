# Render-only result: framework wait reproduced; do not advance to playback

**Decision:** stop pursuing buffer generation plus separate playback as the repair for this known warning on the tested iOS 26.2/23C54 runtime. The render-only app reproduced the relevant main-framework waiter without an application-owned player or engine. Raising the copy cap or implementing a player would not address this evidence. No further native run is justified for this hypothesis by these results alone.

This conclusion is scoped: it does not prove every possible configuration/OS/voice fails, nor that buffer rendering is unusable for other features. It falsifies the proposed simple separation of synthesis from playback as a way to bypass the recorded framework-main wait in the tested configuration. A different candidate needs new evidence for a controllable boundary, not another unchanged r5/render-only run or a quieter gate.

## Exact attribution

The retained runtime JSON contains **18 Fault log records**, PID **88226**, TID **27142959**, from 19:54:58.720802 through 19:55:00.653263 -0500. The metadata independently identifies that TID as main. Nine relevant binaries were UUID-checked with read-only `dwarfdump` before `atos -arch arm64 -l 0`: seven installed iOS 26.2/23C54 framework images, the frozen diagnostic executable and its debug dylib. Both diagnostic binaries also match the retained product SHA256 manifest. Executable UUID is `3717FD25-9277-3C97-8139-FB76E8B4EF9B`; debug UUID is `2EE2FC16-4276-310E-9CB7-6B253A49A7D9`.

All four distinct blocked-stack variants share the same structure:

`Foundation _NSThreadPerformInfo.wait → synchronous NSObject.performSelector(onThread:waitUntilDone:) → TextToSpeech → main dispatch queue → main run loop → UIKit/SwiftUI app entry`

Private TextToSpeech frames remain unnamed offsets; no private method identity is invented. The only diagnostic-app frames are generated `$main` and debug entry-point frames. **None contains Mailbox.receive, PCM-copy/memory operations, owner file writing, RenderCore.write, native Stop or its caller.** Thus the recorded blocked stacks are framework-main work, not a newly attributed direct probe callback or owner-thread wait. This does not identify the logical signaling thread or measure blocked duration.

Seven records (0, 2, 4, 6, 8, 10, 12) have their first six UUID/offset pairs identical to retained hosted original-app faults. All 18 share the three Foundation wait frames and the next TextToSpeech frame. `blocked-stacks.json` preserves decoded eventMessage blocked stacks, separately from structured emission-frame counts; `uuid-bound-symbols.json` preserves exact binary binding. These 18 log records are **not 18 validated XCTest warning occurrences**.
Retained content bindings: corrected probe source SHA256 `ee81219a9b551a9061dabc7792908d1c6b27fb8c0ec495f548f1a9016deeaafa`; scalar metadata attachment SHA256 `400a9e4eea30aaba7585a788dc5c476ae8c0fea53f0950033f4fceb008c53afd`; original 18-record runtime JSON SHA256 `6ee211f29349dc03bade43b43d187387bf65ffbb81dd2c4d0169105e04607261`. `input-receipt.json` additionally pins the original uncompiled source, three-spelling correction, test source, product/source manifests, native log/result receipt and strict warning receipts. All pinned inputs were rehashed unchanged after review.


The first fault is 0.404802 seconds after the XCTest tap activity starts. The first buffer callback is 1.356572 seconds after attempt creation, which occurs during that tap; the cap failure is at 2.242559 seconds. Using tap start as a conservative lower bound, the first warning precedes the first app buffer-copy/file path and cap failure. This ordering assumes ordinary shared-clock ordering across the short case; there is no exact app monotonic-to-wall-clock anchor, and none of these differences is a wait duration. The main-framework stack attribution does not depend on a precise timing alignment.

## The separate probe failure

The original proposed source did not compile because it used an obsolete Swift CoreFoundation spelling. The retained corrected copy differs only in **three** `kCFRunLoopDefaultMode` → `CFRunLoopMode.defaultMode` replacements, as independently checked against the before-copy. The corrected build passed. Preparation missed that compile-time issue; both the original failure and correction remain part of the record.

The native process returned **65**, its one case failed in **7.873 seconds**, and strict inspection returned **1**. The first test assertion rejected `status = failed`, so later assertions were not a completed independent verification of all metadata fields. The data nonetheless explains the bounded probe's failure:

- Installed en-US/default-rate rendering produced mono, noninterleaved float32 PCM at 22,050 Hz.
- The native write call returned after about 0.125 ms; this is that call's measured return interval, not render latency or absence of later framework waits.
- The owner reported Default class **21**; callbacks and terminal reported main/User-interactive class **33**. Public class reporting does not expose transient QoS overrides.
- Buffer indices 5, 6 and 7 arrived within **35.375 microseconds**. Two roughly 1 KiB copied buffers exhausted the **two-copy count** before the owner could drain them. Peak copied bytes were only **2,048**, far below the 1 MiB byte cap. This is an overrestrictive count limit for the observed burst, not evidence of large-memory exhaustion.
- Seven accepted callbacks accounted for 1,790 frames / 7,160 PCM bytes; only five buffers, 1,278 frames / 5,112 PCM bytes, were written. The difference is 512 frames / 2,048 bytes. There is no complete-audio result. The private CAF's observed peak size was 9,208 bytes.
- The field `lateCallbacksBeforeReport = 352` is misleading if read as after-terminal callbacks. Its source increments on rejection after **either sticky failure or seal**, so it includes callbacks dropped after the cap failure while the renderer continued. No complete postfailure frame accounting survives. `zeroBuffers = 0` does not establish that the synthesizer never emitted a zero buffer: postfailure callbacks were rejected before that counter could update.
- A matching didFinish arrived, then the failure-path Stop returned false in approximately 4 microseconds. That does not restore discarded output or make the attempt successful. The app reports directory deletion and release of its native references; this is not proof of all framework resources retiring or acoustic behavior.

The count limit failed safely and truthfully, but was not sufficient to complete this short fixture. Fixing that probe limitation would investigate callback throughput/completeness, a different objective. It cannot remove the already reproduced framework-main warning and should not be used to obtain a nominal green result for the warning-repair task.

## Strict acceptance and next action

The selected case has **one exported aggregate XCTest runtime-warning activity**, distinct from the 18 unified-log Fault records, with **zero Complete Issue Description attachments**. The strict checker correctly rejects both the failed case and unavailable warning evidence. Unified-log stacks corroborate attribution but do not substitute for the missing required attachment. No checker relaxation, warning suppression, timeout change, fallback-only pass or acoustic claim follows.

The smallest useful next action is evidence consolidation: retain this minimal standalone source/product binding and the compact framework-main attribution alongside the original app/r4/r5 evidence as a reproducible framework issue. Root can use that package for an Apple issue if separately requested; nothing was submitted. There is no additional source-supported app repair or necessary parameter rerun established here. Keep the player/engine phase deferred and continue independent app work. Any later revival should be driven by new API/runtime evidence or a separate justified playback feature, with full behavior/resource qualification still required.

This review read existing artifacts and used only UUID inspection/symbolication. It made no source edits, build/test/native executions, simulator changes or new result/log exports. Raw runtime logs remain private in the original execution directory; this directory contains derived assessment, hashes and symbol attribution only.
