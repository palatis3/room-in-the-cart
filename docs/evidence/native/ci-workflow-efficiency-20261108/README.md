# CI feedback efficiency — November 8, 2026

The completed fe3e143 batch took 150.70 minutes. Its 43 macOS jobs consumed 687.37 runner-minutes: 91.22% of available five-slot wall capacity. Five jobs were active for 108.23 minutes, four for 22.83, three for 16.88, two for 1.52 and one for 1.18. Job execution windows include setup, upload and post-job work; they are not per-test durations. GitHub timestamps are retained for all six workflows.

Core UI jobs took 18.3–32.6 minutes; grouped contributor fixture jobs 17.5–31.9 minutes. Simulator setup commonly took 1–3 minutes/job. Swift CodeQL took 36.1 minutes including 32.3 minutes of instrumented compilation. Core product preparation took 10.7 minutes; fixture preparation about 11.3–11.5 minutes. Products already build once per profile and are shared across test jobs. With this utilization, additional splitting alone is unlikely to halve the full batch.

Implemented locally: optional manual selection of one exact fixture group, with only its required build profile. Normal PR/release selections retain all 17 groups. All original selectors and strict runtime/privacy/timeout gates remain. The target name is validated against the complete source-derived inventory before any macOS build. A focused diagnostic pass does not satisfy full release acceptance.

Validation: actionlint 1.7.12 plus the existing exact queue-key validator passes all workflows; all 245 Python tests pass. New negative cases reject non-manual narrowing, unknown/injected/ambiguous names and empty plans. Every valid manual group preserves its existing identity/slot and chooses only its required profile. Hosted execution of the new optional path is still unverified; this change has not yet been pushed or dispatched.

For the local workflow, the unchanged-product measurement's two cases took 131.197 seconds; its on-failure simctl diagnose collection then took its 600-second timeout. A subsequent candidate's collection completed quickly. This demonstrates a possible diagnostic tail, not a ten-minute cost on every failure. CI diagnostics remain enabled. Preserve useful native logs/results/screenshots, use stable incremental build paths, and reserve additional probes for a specific unresolved question.

Official scheduling reference: https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency . Existing five explicit job-level concurrency slots and queue configuration are retained.
