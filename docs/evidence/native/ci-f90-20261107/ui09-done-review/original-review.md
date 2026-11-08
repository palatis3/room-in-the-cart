# Original f90 UI09 timeout: evidence review

No product or test fix is justified by the captured evidence. This case exhausts its 720-second allowance in repeated animation-idle waits that begin after the branch field's Done tap; it does not reach comparison/save/reopen behavior. The later `40.90` entry is where the allowance expires, not where the first stalled boundary occurs.

Original boundary: run 42428215935 attempt1, job 128588297174, artifact 13600243874 `iphone-results-ui-09-1`, source `f90ad75a2e561891b2014ecb234d19639bcaed4c`. The full 24,337,702-byte artifact is retained privately in this scratch directory and verified against SHA256 `8147db2595fee5d0dcf7f0aaa012f4138ae5e8c8ad22e8ba2100a8daa4191c45`. Its original xcresult was extracted to an inspection copy. This was read-only investigation: no native launch/retry, timeout change, source patch or workflow change occurred.

The result remains 7/8 with zero exported XCTest runtime-warning occurrences and one runner restart. The failed selector is `ContextualNavigationUITests/testFirstRunCheckOneChangeCanLeaveOrSaveAndReopenExactRetailerEvidence()`. It is the first selected case, on Xcode 26.3/iOS 26.2 arm64 iPhone 17. Its reset workspace launches app PID 8951; runner PID 8535 later restarts as 47317 before the remaining seven cases. Their passes do not repair this failure.

## Exact sequence

- The case opens Check one change, leaves without saving, verifies no pickup was created, and opens it again. It types the change and taps the first Done at 88.70s; that completes normally. Initial keyboard acquisition was already slow (post-tap idle wait 55.90→85.37s), but no 60-second notification miss appears there.
- Branch-field tap 99.67s, keyboard exists 102.50s, type `North Market West` 102.54s. Its Done tap starts 104.63s, synthesized event 105.10s, post-event idle wait 105.43s; the first animation-completion miss is 165.52s.
- The source field's tap, typing and Done all subsequently incur the same waits. The before-total tap starts 540.05s but its event is synthesized only 601.24s. Keyboard existence succeeds 662.78s; `40.90` typing starts 662.92s and is still in pre-event idle waiting at the 720s deadline. Additional activity continues before the runner is replaced; preserve it, not just the deadline banner.
- `wait-timeline.json`: nine 60-second animation misses before 720s and two afterward; original runner-restart marker at Tests.log line 241. No retries or timeout allowances were changed.

## Original app/runner evidence

The app's last animation-idle reply is 01:59:12.477, before branch Done. After its synthesized event at 01:59:13, app 8951 promptly sends a main-run-loop-idle reply at 01:59:13.285 but receives an animation-idle request without a subsequent animation-idle reply. Its last observed main-run-loop-idle reply is 02:10:33.548, so the trace does not establish a continuously blocked main thread. The runner receives the main-loop reply and waits for animation completion. `first-stall-runner-excerpt.txt`, `first-stall-keyboard-idle-excerpt.txt` and `app-idle-events.txt` retain original line numbers.

Immediately after that first 60-second wait, the 02:00:13.630 keyboard query returns an empty matching-snapshot set. This supports keyboard absence at that later observation. It does not independently prove the Done closure executed, the precise focus transition, keyboard didHide notification, or Core Animation completion.

The timeout stackshot covers 02:09:28.936–02:09:33.919. App main thread: 277/297 samples in the run-loop Mach wait; 20/297 executing run-loop blocks, mostly XCTest accessibility snapshot work. Runner includes `typeText:`/pre-event quiescence and expectation waits. This does not support a save/calculation busy loop at the sampled time and cannot reconstruct the earlier Done handler. `timeout-stack-excerpt.txt` retains selected original stack lines; the full spindump remains scratch only.

## Touch/focus and unavailable visuals

The original synthesized first and second Done events both use point (364,517), including down/up points; the later source Done uses the same point. The app's pre-second-Done trace identifies `oneChange.branch` as Keyboard Focused. Equal event coordinates establish the requested synthesis point, not the actual view hit or handler dispatch.

The exact-case screen-recording attachment is a 60-byte error: `Unexpected Error: Finished test run with pending attachment.` All retained tap snapshots contain only an application root with zero children. There is no usable screenshot or video to establish clipping, a covered Done button or post-tap layout. `done-tap-boundaries.json` pins attachment hashes and decoded event points. No screenshot was fabricated or replaced by a later run.

## Source and next discriminator

`CheckOneChangeView.swift` and `Theme.swift` are byte-identical between f90 and the reviewed current source. Done calls only `field = nil`; the shared `keyboardDoneAction` conditionally shows a bottom safe-area inset. The failing test body and its `fill`, launch/restart and content-reveal path remain unchanged. Current test-file changes concern the unrelated store-quote branch/header and diagnostic boundary; `source-f90/`, `source-current/`, `source-manifest.json` and `source-diff.patch` preserve exact bytes.

The earlier urgent-repair second-Done investigation (`diagnostics/keyboard-dismiss/PREPARATION.md`) has a similar missing-animation-reply boundary. That is related diagnostic context, not proof of the same cause. If root chooses further work, the narrow discriminator is compile-guarded Done enter/exit, fixed field-code focus transitions, keyboard will/did-hide and scene events in this CheckOneChange view, preserving original taps, readbacks, eight-case selection, timeouts and Release exclusion. Do not log field text, change the shared focus driver, suppress animation waits, add retries, or claim a production repair from this observation alone. No such instrumentation is applied or proposed as an approved fix here.

The bounded app diagnostic scan is recorded separately; the original zero-runtime-warning result is not a claim that raw OS logs contain no diagnostics. Raw multi-case app/runner logs and the full archive remain in scratch; only narrow evidence excerpts should be promoted.
