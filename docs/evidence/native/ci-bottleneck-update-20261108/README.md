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

Hosted verification is pending. Publish a development branch without an open PR
and dispatch deep checks plus the previously passing focused quote fixture.
Do not replace full PR/release coverage with these focused results. The operating
procedure is in docs/CI-VALIDATION.md; do not launch duplicate active diagnostics.
