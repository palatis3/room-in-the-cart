# Worker-control evidence reconciliation — 2026-11-08

**The retained background export contains five foreground-control events followed by five worker-control events. It does not establish ten worker faults or a worker reproduction of the direct Pause stack.** This additive review corrects those claims while preserving every original frozen file and manifest unchanged. It establishes no production fix, new native result, or speech acceptance.

The original `background-qos.json` first five JSON records are exactly equal to the complete `framework-qos.json` (retained here as `foreground-qos.json`). The earlier comparison consumed the entire background export without PID/time filtering. This explains the erroneous cross-run attribution; it does not imply that the original diagnostics were fabricated or that all worker warnings disappeared.

| Scope | PID | Local timestamp, UTC−05:00 | Events | Exact first-six signatures |
|---|---:|---|---:|---:|
| Earlier foreground control | 70394 | Nov 7 12:23:39.547976–12:23:42.277012 | 5 | 5 |
| Worker control only | 70758 | Nov 7 12:24:29.915204–12:24:32.611440 | 5 | 4 |

The worker test started at 12:24:25.167 and passed at 12:24:34.427 (original reported duration 9.260 seconds), matching the later records. `worker-test-excerpt.txt` preserves original log lines 150–208, including org.local.speechControl and Speak/Pause/Resume/Stop actions. This is an old result, not a replay performed for this review. The retained source queues all four commands on one default-QoS serial queue and lazily creates its synthesizer there. It is byte-identical to the previously pinned worker source; this review does not freshly verify an executable against that source.

`reconciliation.json` independently decodes each raw event's hex **blocked stack**, separately from the structured emission backtrace retained in the raw JSON. Scoped worker events match f90 events **0, 1, 3, 4 and 5**, using the first six exact UUID/offset pairs. The f90 **event 2 Pause** prefix matches foreground event 1 and **no scoped worker event**. Four distinct worker signatures account for five matches because one signature recurs. A prefix match is not a full-stack/execution match; absence of a Pause match in this short capture does not establish elimination.

## What is corrected

The following earlier claims are superseded by this review, not silently rewritten:

- Parent `README.md`: “serial-worker control still emitted ten faults” and matching all six including Pause.
- Parent `mitigation-review.md`: “same six-frame Pause signature occurs in the retained serial-worker control.”
- Parent `prior-expanded-control-match.json`: `hostedPauseMatchingWorkerEvents` contains the **foreground PID 70394** record, not a worker-run record.
- Parent `prior-control-summary.json` and the older `.build/SharedCookReadback-df8e36d-Nov07/qos/comparison.json`/verification summaries: worker totals and all-signature matching used the unfiltered ten-record export.
- `.build/CI15F216Nov08/cook-speech-review/README.md` and its inherited comparisons: the statement that all five new hosted signatures, including the f90-like Pause path, match the worker control inherits this same overbroad attribution. The newer hosted native five passes and strict failure are unaffected.

The audio-session-only, installed-voice-only, standalone foreground speech reproduction, and exact hosted app Pause symbolization are unaffected by this filtering correction.

## QoS, caller and duration limits

Every scoped worker event reports **User-interactive waiting on Default**, with `-[NSCondition wait]`; emission thread ID is 22684028. Their blocked stacks traverse Foundation/TextToSpeech, libdispatch, CoreFoundation's runloop, UIKit/SwiftUI and app entry offsets. They do not show a direct worker command closure at the wait. Thus the remaining evidence is consistent with framework-dispatched UI/runloop waits even with command ownership moved off-main; it does not identify an app-owned lock or the complete lower-priority owner's stack. The configured worker queue's `.default` QoS must not be substituted for the diagnostic's reported waiter QoS.

The exact hosted f90 Pause symbols remain `CookReadbackModel.pause()` → `LocalCookSpeech.pause()` → synchronous `pauseSpeaking(.immediate)` → the framework wait. Both app types are explicitly MainActor. A caught synchronous wait on that path is real; its length and user-visible responsiveness impact remain unmeasured. The worker capture has no corresponding direct Pause stack, so it cannot be used to prove that moving the command never helps that particular call boundary.

The worker events span **2.696236 seconds**. This is an event window, **not a wait duration**. Pause's XCTest synthesis-to-idle interval is 5.89→6.19 seconds relative to test start (about 0.30 seconds); it includes event delivery and is also not an API-call duration. Raw diagnostic details have no wait-duration field. No command-entry/return timing or continuous main-runloop responsiveness measurement was collected. The old native pass checks button operations, not acoustic pause/resume fidelity or the product's cancellation/authority guarantees.

## Consequence and next useful work

No new production remedy follows from this correction. The existing app already queues audio-session activation/deactivation off-main. Moving only selected methods would split ownership of a non-Sendable synthesizer; moving the full lifecycle requires acknowledgements, generation/order checks, delegate handling and protection against queued Speak/Resume after authority invalidation. Returning before Stop completion changes the existing synchronous boundary. The minimal worker source qualifies none of those product semantics.

If separately scheduled, measure actual adapter command entry/return and main-runloop responsiveness with PID/time-scoped runtime faults while preserving the real controls and authority rules. This would address missing duration/caller evidence; rerunning the unchanged old control would not. Keep framework faults and the strict missing-description failure visible. No warning suppression, timeout change, synthetic pause replacement, new native execution or production patch is proposed here.

## Reproduction and provenance

`python3 audit.py` reads only the retained JSON files, asserts exact foreground-prefix duplication and distinct PID/time scopes, decodes the blocked stacks, and reproduces `reconciliation.json` on stdout. It does not execute Swift or access result bundles. `provenance.json` records original paths, complete hashes and original excerpt line ranges, plus all 28 reverified parent frozen files. `file-hashes.json` covers this additive directory except itself. Original raw JSON contains diagnostic paths, UUIDs/offsets and fixed diagnostic messages; it contains no cook wording, recipient payload, credentials or signed URLs. Full logs, media, stdout, binaries and result bundles are excluded.

No canonical product/CURRENT edits, native/build/UI action, remote action or commit occurred during this reconciliation.
