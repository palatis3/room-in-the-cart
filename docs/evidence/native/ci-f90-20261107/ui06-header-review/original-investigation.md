# Original UI06 execution-allowance failure

Run 42428215935, attempt1, job128579225683, f90ad75a2e561891b2014ecb234d19639bcaed4c. `ContextualNavigationUITests.testEnteredStoreQuotesKeepTripCostsSeparateAndAdoptOnlyReviewedSavedProof` exceeded the configured 720-second allowance. Native shard result is7/8 passed, zero exported runtime warnings and one runner restart. This was the first selector; there is no preceding-case prefix to reproduce. The original failure remains valid. No native execution, canonical edits, retry, timeout change or causal correction was performed/proposed.

## Boundary and observed progress

The source and all relevant helpers are byte-identical to f90, as are DinnerQuotesView and DinnerFeatureModel. Entry already groups text fields under the real Done control; it is not the shared fixture's per-field keyboard pattern.

The case entered both store quotes and acknowledged their review switches, checked unresolved trip cash, entered the missing4, checked checkout/trip differences, saved proof, cancelled then explicitly adopted it, checked stale adoption disabled, relaunched, edited/saved a corrected comparison, and performed its second intentional relaunch at707.19s. At720s it was scrolling to `Compare two store trips`, source line703. It then tapped that row at721.93, opened original comparison1 at728.84, read original result data and stale-proof text, and announced `S27-original-observations-survive-corrected-comparison` at753.74. Teardown began753.98; a runner restart followed. Continued activity is not a passing terminal result and cannot erase the execution-allowance failure.

The final announced screenshot is absent from every SQLite Attachments row. Only the actual retained screenshots were exported: complete store differences451.81s and reopened adopted/stale comparison607.49s. The latter visibly shows checkout35, incremental trip4, combined39; differences-4/-3/+1; stale-proof explanation; and disabled adoption controls. It does not certify the missing final screenshot.

## Where time accumulated

`activity-duration-summary.json` uses completed top-level pre-timeout activities, not app CPU profiling:

| Activity category | Count | Seconds |
|---|---:|---:|
| Drag/scroll |68|194.18|
| Find/query |751|156.51|
| Existence query |389|141.15|
| Tap |66|112.86|
| Open/relaunch |3|35.02|
| Text entry |22|22.18|
| Other |188|41.21|

No completed top-level activity exceeded20.216s. The two longest adjacent UI queries were Find20.216s and exists16.819s for `Checkout plus trip cash, second minus first: $1.00` at t412–449. Original Session confirms both were remote UI-query waits, completed after20.212 and16.817s and returned the expected StaticText. The intervening hit-point calculation returned a visible point. Numerous AX PID-status notifications occurred during those waits; retained evidence does not establish their cause, resource pressure, or responsibility for the latency. This supports cumulative driver/query/scroll cost with a query-latency spike, not a demonstrated final-navigation hang, keyboard deadlock, or incorrect product result.

Current generic reveal/assert helpers re-query existence/hittability and full viewport properties. Reducing queries or changing query shape might improve performance, but this run does not establish which change would remove the latency without altering visibility guarantees. No such speculative patch is prepared. The existing first-switch before/after diagnostics also cost time; removing those would not establish the timeout's cause.

## Diagnostics and source limits

Zero structured runtime warnings is retained alongside raw diagnostics. Session contains invalid-UI-element reads for disappearing Done controls; long-query windows contain AX PID notifications. Original raw invocation retains multiple matching destinations, 720default/900maximum allowances, and the explicit timeout/restart. The first runner Session was selected by its exact012739 filename; the post-restart014315 Session was not substituted. Source has synchronous local comparison/result rendering and user-triggered save/adoption; no source defect or unintended recurring refresh was established.

`docs/evidence/native/saved-store-quotes-20261107/iphone-17-verification.txt` records a prior local whole-case pass597.73s with zero warnings; this is not equivalent-host validation of the current hosted failure. The older quote-switch diagnostic retrospective addresses a different off-switch failure. Neither justifies relaxing this deadline.

## Narrow next verification

If root authorizes another diagnostic, retain this exact first-case context and complete journey under the original720-second allowance, source/profile/device and warning/restart gates. Preserve existing native activities and capture host/process timing concurrently without additional UI queries. Compare the same phase boundaries and remote query durations against a representative hosted26.3/26.2 attempt; a local27.x pass establishes only nonreproduction. If a repeat isolates a query hot path, evaluate one semantics-preserving query/viewport optimization against full original assertions. Do not split away later persistence assertions, add retries, raise limits or claim a fix from post-timeout console continuation.

## Collection integrity

Artifact13599975417,29,920,421bytes, API SHA256 `9f17675363410ebf5fb08bfebb140fc3f5efff0ede13cc1041df3e28f3b06ef6`. The full ZIP was not downloaded/hash-verified. Bounded ranges preserve exact pins, HTTP206/range checks, archive-member type/path/size/ratio/CRC checks and SHA receipts. Original SQLite/root metadata, two retained screenshots and the exact first runner Session are preserved separately from the inspection copy. Initial guards refused selection of an absent third screenshot and ambiguous two-session selection; the subsequent collectors explicitly selected the two existing screenshots and original-session filename. No archive safety budget was relaxed. Review receipt pins source/export hashes and missing-final-attachment observation. Monitor's small log/results/selector receipts remain in sibling `ui-06/`.

## Follow-up: concrete known-top header search

Detailed phase review subsequently isolated a source-supported driver inefficiency: after adoption, the known first-section branch header search makes16upwarddrags before3downwarddrags, consuming85.89seconds(t476.88–562.77). The complete scratch-only case-local proposal and exact raw excerpt are under `top-header-candidate/`. It preserves the full case and limits; it does not attribute the independent37second remote-query spike or prove a future native pass. No canonical code was changed.
