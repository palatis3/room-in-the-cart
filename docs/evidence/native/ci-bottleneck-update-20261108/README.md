# CI bottleneck update — November 8, 2026

Contributor and dinner fixture consumers now depend only on their own build.
The original 17 rows and their five-slot assignments are partitioned without
changing selectors. A new aggregate gate rejects failed/cancelled/unexpectedly
skipped required work; an unselected manual profile must remain skipped.

English and Spanish LocalStoreKit consumers now share one build-for-testing
artifact from the same run. Both compiled configurations, the bundled local
StoreKit resource, the original 15 selectors per locale and all strict runtime
checks remain required. A Linux preflight checks the workflow before compilation;
a final gate requires the build and both locale results.

Validation: all 261 Python tests pass, paired actionlint 1.7.12 validation passes
all eight workflows and 17 native job definitions, and 33 changed-workflow shell
blocks pass bash syntax checks. Tests exercise missing/disabled/narrowed compiled
configurations, wrong artifact revision, and gate failure/cancellation/skip paths.
No application source or acceptance threshold changed.

The earlier complete batch used 687.37 macOS runner-minutes over 150.70 minutes,
about 91.22% of five-slot capacity. Its two StoreKit jobs together used 26m31s,
including compilation, simulator setup and result collection. Shared products
remove duplicate compilation but add an artifact transfer and another job setup;
actual hosted savings must be measured, not inferred from that baseline.

Hosted validation started at source commit
`50e893637d5047b1d276232fdf30b0e46c658abd` on
`codex/ci-bottlenecks-20261108` (no open PR/full regression dispatch):

- [Deep checks](https://github.com/palatis3/room-in-the-cart/actions/runs/42541290758): terminal failure: preflight, both sanitizers, shared StoreKit build and English15/15 passed. Spanish14/15 passed; Ask to Buy approval failed its unchanged delivery predicate. The new aggregate gate correctly rejected it. See spanish-storekit-review.md for retained evidence and the limits of historical comparison.
- [Focused quote fixture](https://github.com/palatis3/room-in-the-cart/actions/runs/42541292817): terminal success: planner/build, one original quote journey (425.622s), strict verification and the new Fixture gate passed; unused dinner build/tests were correctly skipped.

Both runs are terminal. The failed deep run must not be blindly rerun. A local billing recovery candidate is being qualified separately.
The shared StoreKit build plus two locale jobs used1008seconds of macOS time,
versus1591seconds in the earlier passing cohort. Because the new Spanish
scenario failed, this is timing evidence, not a like-for-like successful-run
speedup or full-suite acceptance. No new hosted run is active from this validation batch. The complete PR and
release scopes remain required. See docs/CI-VALIDATION.md for the working loop.
