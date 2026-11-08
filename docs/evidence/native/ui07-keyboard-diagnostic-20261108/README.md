# Original UI07 keyboard diagnostic

The isolated eight-case sequence passed locally, strict **8/8**, with the original order, actions, assertions and 720/900-second limits. The test export recorded zero runtime warnings. The console analysis found no animation-idle messages or runner restarts across 9,513 lines, including build output. This run did **not** reproduce the original timeout and does not establish a repair.

The pinned ordinary Debug source is `f9c9bcfddbcb84ebcd503aa89446e969357bf084` plus the reviewed two-file callback diagnostic. Its compilation conditions are exactly `DEBUG COMPARISON_KEYBOARD_DIAGNOSTIC`, with no contributor fixture entry point. All source pins still match. Xcode27.1 / iPhone17 / iOS26.2 build23C54 differs from the hosted Xcode26.3 environment. The original result bundle was copied before inspection and reverified unchanged afterward.

The separate app-stdout export reached its 256,000,000-byte expanded-file limit and exited SIGXFSZ. Its incomplete temporary and exact-object receipts are retained privately; no complete callback-capture or missing-event inference is made. The retained prefix ends before the Spanish case begins and is dominated by accessibility/automation diagnostics. Its zero UI07 markers cannot establish absent callbacks. The parser was not run on that incomplete export, and no larger export is justified for this clean nonreproduction. This limit does not invalidate the separately completed strict test/warning checks. [Exact verification and hashes](verification.json).

The unchanged production keyboard helper remains installed. Earlier responder and persistent-content experiments remain rejected under their recorded acceptance checks. Post-tap screenshots show eventual dismissal only; they cannot establish responsiveness during an earlier wait. Additional instrumentation needs a distinct evidential purpose before another native experiment.

Original run and private export: `.build/CI15F216Nov08/ui-07-diagnostic-execution-r2/runs/diagnostic-r2/`. No test retry, source fallback or synchronization suppression was used.
