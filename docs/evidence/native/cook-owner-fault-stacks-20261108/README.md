# R4 cook-owner fault stacks: exact retained-record assessment

The original direct MainActor `LocalCookSpeech.pause` boundary is **not present in these current r4 stacks**. The application's Pause call is now on its dedicated owner thread. However, framework synchronous waits remain on that owner and on the main dispatch loop, so the candidate is **not a QoS repair or strict qualification**.

Root's original five UI cases passed natively, including real Play/Pause/Resume/Stop, but strict inspection returned 1 because the first runtime warning lacked `Complete Issue Description.txt` (zero attachments). The two xcresult warning occurrences remain unchanged. The eight retained Fault records below corroborate additional waiter stacks; **eight log records are not a replacement strict-warning count**. Original actual-app proof is in [the separate sealed package](../cook-thread-owner-actual-app-20261108/README.md).

## Binding and collection

The predicate-only retained-log query returned eight records / 55,674 bytes, SHA256 `cfc9e0ea68b8ca0abe1e3dae3a884ec4b44831c088db60a3d529a7b5428b4416`. All match PID 69990, the owned simulator device path, runtime-issues/Hang Risk/Fault, and the exact 16:30:35.773–16:31:32.229 UTC case window. [Raw records](raw-eight-faults.json), [query receipt](query-receipt.json), [provenance](provenance.json).

The earlier `--process` plus `--predicate` attempt hit its 1 MiB cap and did not constrain output to the intended intersection. Preserve its [failed receipt](capped-query-receipt.json); only the hash of its private raw prefix is published. It is incomplete, not absence evidence. The successful successor uses PID/name/subsystem/category in one AND predicate. No new app run or trace was used for collection.

Local `dwarfdump` binds executable UUID **DF1B0D04-3418-31C3-A700-2A04478BFC46** to each record's process image UUID and debug-library UUID **A5F012DA-1A1F-3765-924D-BA245EC94D9D** to the app frames. Both files match the **actual fixture** `fixture-r1/product-manifest.json` hashes; the earlier generic-build manifest is not substituted. [Binary binding](binary-binding.json). Seven runtime images were independently UUID-checked before `atos`; private TextToSpeech symbols that remain unnamed are retained as offsets, not invented method names. [App symbols](app-symbols.json), [framework symbols](framework-symbols.json).

The decoded UUID/offset payload in `eventMessage` is the blocked stack. The structured `backtrace.frames` is retained separately as the emission backtrace. They are not conflated.

## Current waiter boundaries

All eight blocked stacks begin with Foundation `_NSThreadPerformInfo wait` and `performSelector:onThread:…waitUntilDone:`, above TextToSpeech frames; the runtime message names the `NSCondition wait` antipattern.

| UTC time | Thread / QoS | App or framework boundary |
|---|---|---|
| 16:31:11.142389 | 26132822 / User-initiated | `CookAVSpeechEngine.isSpeaking` → `observedIdle` → owner `perform(start)` |
| 16:31:11.226244 | 26131913 / User-interactive | TextToSpeech block from main dispatch queue; only app entry-point frames |
| 16:31:12.576539 | same main thread | Another TextToSpeech/main-dispatch wait |
| 16:31:13.758964 | owner / User-initiated | `CookAVSpeechEngine.pause` → owner `perform(pause)` |
| 16:31:13.767501 | main / User-interactive | TextToSpeech/main-dispatch wait |
| 16:31:15.329978 | main / User-interactive | TextToSpeech/main-dispatch wait |
| 16:31:16.257455 | main / User-interactive | TextToSpeech/main-dispatch wait |
| 16:31:16.930742 | owner / User-initiated | `CookAVSpeechEngine.isSpeaking` → owner `perform(stop)` |

Exact XCTest activity starts are Play **16:31:10.632**, Pause **13.488**, Resume **15.121**, Stop **16.718**. The owner records follow the respective tap activity starts by 0.510389, 0.270964 and 0.212742 seconds. **These differences are not native-call or wait durations.** Framework-main records span the intervals after Play, Pause and Resume. [Action receipt](action-timing.json), [classification](timing-classification.json), [full symbolicated stacks](symbolicated-blocked-stacks.json).

No captured blocked stack contains CookInstalledVoices enumeration or CookAudioSession preparation. That limits attribution of these eight records; it does not prove that all preparation work is harmless. The five main records have TextToSpeech → libdispatch main-queue → main run-loop paths, not a new direct application `LocalCookSpeech.pause` call. Moving the application's Pause call off MainActor did not eliminate main-framework waits.

## Native state reads: necessary versus potentially redundant

No owner source was changed based on this assessment. [Exact source context](source-context.json) supports these distinctions:

- The first Start's `observedIdle` reads `isSpeaking` before any utterance has been admitted. For a fresh exclusively owned synthesizer, an explicit never-spoken/idle bookkeeping proof could make that initial query unnecessary. Record 0 exposes the cost of the current query; it does not justify deleting every idle guard.
- Stop currently evaluates both native state getters before passing values to `CookSpeechStopPolicy`. If an utterance is admitted and no matching terminal callback has been observed, that policy always calls native Stop regardless of those flags. Reads in that specific branch are logically unnecessary for its decision. The raw stack does not capture `active`/`terminalSeen`, so record 7 cannot establish which branch applied at that instant.
- Pre-start/already-idle Stop and matched-terminal recovery use idle observations to distinguish successful no-work cancellation from a false Stop of active/paused speech. The current contract must keep that proof, or replace it with equally strong explicit ownership facts; false active Stop must remain a barrier.
- Matching didFinish/didCancel plus owner-observed idle is the existing terminal retirement rule. Removing terminal idle checks or treating a callback/Bool alone as acoustic silence would weaken it. A new Start following earlier speech also needs a justified idle/admission rule, not an assumption carried from fresh initialization.

A scoped future reduction in redundant getter calls may remove an application-triggered wait without addressing the five main-framework waits or Pause's own synchronous native wait. This evidence does not locate the logical signaling thread/queue, measure wait latency, establish hard-preemptive Stop, prove acoustics, or warrant changing QoS/logging/strict gates. Root review precedes any source correction.
