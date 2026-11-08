# Follow-up workflow efficiency

The core Swift package, Release, Swift CodeQL and UI build jobs now depend on
the Linux source checks. In the retained baseline that job took 24 seconds
(18:18:12–18:18:36 UTC). Invalid source/generated-file/workflow inputs stop these
four entry jobs before macOS allocation. The existing final gate still rejects
failed or skipped requirements; independent service/web checks remain parallel.

Performance validation now has a Linux preflight and an optional manual case
selector. Full PR/release runs retain launch, rendered and scroll. A manual
focused run builds the same optimized products and validates the full compiled
inventory before selecting one case, with the same slot, thresholds, strict
evidence checks and timeouts. It can avoid two unrelated test jobs during a
single-case investigation; it does not eliminate the shared build.

All 250 Python tests pass, including rejection of a missing unselected compiled
performance method and a check that preflight invokes no native tools. Paired
actionlint 1.7.12/workflow validation passes. `performance-selection-checks.json`
uses synthetic symbols to exercise selection; it is not native performance
evidence. Hosted execution of this performance change remains pending.

The earlier focused fixture change is running at commit `48c9f713` in
[run 42524447359](https://github.com/palatis3/room-in-the-cart/actions/runs/42524447359).
The planner and contributor build passed, the dinner build was skipped, and
exactly one store-quote group was admitted. Its test result is still pending at
this checkpoint. No duplicate full batch was launched for these workflow edits.

The operating workflow is now: one focused reproduction, preserved first-failure
evidence, one qualified fix set, then a full PR batch. Use a development branch
without an open PR for focused work. Reuse matching local build directories with
source/product provenance. Keep the five-slot cap and failure diagnostics.

Repeated absent keyboard-card waits measured about 93 seconds in the old quote
failure, but are not removed here: robust late-card handling still needs native
verification. No test expectations, release coverage or time budgets were relaxed.

References: [GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
and [reusable workflow context](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts).
