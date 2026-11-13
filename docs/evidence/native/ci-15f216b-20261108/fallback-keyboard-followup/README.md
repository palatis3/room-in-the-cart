# Shared fallback keyboard investigation

Both local runs compiled on Xcode 27.1 and used iPhone 17 / iOS 26.2 (23C54), the original two selectors, serial execution and unchanged 720/900-second limits. Neither run passed strict acceptance. Hosted Xcode 26.3 confirmation remains separate.

| Run | Recipe review / lost reply | Protected food / trip | Runtime warnings | Runner restarts |
|---|---|---|---|---|
| Original `15f216b` source | Passed, 96.833 s | Timed out, 720 s | 0 recorded | 1 |
| Selection and ingredient-keyboard tracing | Timed out, 720 s | Passed, 661.965 s | 0 recorded | 1 |

The baseline first stalled after Pack name Done. The diagnostic first stalled after recipe quantity Done in its first case and trip-budget Done in its second case. Its 19 recorded animation-idle messages comprise ten within the first case, one after its timeout, and eight within the second case. These different boundaries do not establish a common cause.

The diagnostic's original recipe toggle succeeded: one setter changed the selected value from 0 to 1, accessibility readback changed to 1, and the ingredient link appeared. The hosted toggle failure did not reproduce. Three later lifecycle-gap observations remain in the trace.

All four instrumented ingredient Done callbacks ran. Focus still reported the entering field when each callback returned, then cleared 39–50 ms later; process-wide keyboard-hide notifications followed 446–480 ms after return. Those successful callbacks occurred after the earlier trip-editor idle delays. They do not establish what happened during the stalled transition or prove animation completion. Tracing also changes timing.

[Comparison](comparison.json) pins the run receipts, console files and copied evidence. [Callback timings](callback-timings.json) retain the exact scope and limitations. [Line-number correction](line-number-correction.json) distinguishes universal-newline checker numbering from LF-delimited offsets. Original result bundles, source and baseline products were preserved; raw app stdout remains private.

A separate, uninstalled experiment adds public responder resignation after the existing focus clear in the shared Done helper. This evidence does not qualify that experiment as a fix.
