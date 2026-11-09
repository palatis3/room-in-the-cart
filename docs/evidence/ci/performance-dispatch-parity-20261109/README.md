# Validate the actual dispatch profile before spending Mac time

Hosted run 42697685059 stopped in its Ubuntu planner. Ordinary test fixtures
inherited the enabled observer flag, and artifact assertions still expected the
former literal upload path. Neither macOS job ran. Local checks of the complete
step then exposed the same issues in two more test files, without another hosted
attempt. Those fixtures now isolate their ordinary profiles and explicitly verify
both upload branches. Production workflow commands and acceptance remain unchanged.

`scripts/check_performance_dispatch.py` reads and executes the actual cheap step
from the workflow, expanding the selected inputs and workflow environment. It
refuses unknown expressions, changed job/step environments and non-Ubuntu jobs.
It records input hashes, the rendered script, bounded output and a receipt, and
fails if source changes during execution. It runs with the selected local Python;
it does not claim to reproduce the hosted operating system or native runtime.
Supported profiles are manual dispatch and explicitly modeled pull requests.
Reusable workflow calls are rejected because they have different input defaults.

The complete eight-suite step passes **227 checks** under both the actual observer
profile and ordinary profile, in 5.883 and 5.860 seconds respectively. Root verified
both source manifests, logs and receipts against current inputs. Six controls for
the parity tool also pass. No build, simulator or native test ran in these checks.

The earlier 281-control preparation total covered incremental checkpoints. It was
not a valid final preflight pass after the workflow changed. This complete-step
evidence supersedes that count for dispatch readiness; original logs, payloads and
the hosted failure remain unchanged.

Retained originals: `.build/HostedAppObservationNov09/hosted-42697685059/`,
`planner-fixture-isolation-r1/`, `provenance-fixture-isolation-r1/`,
`dispatch-parity-r1` through `dispatch-parity-r4`, and
`dispatch-parity-ordinary-r1`, `dispatch-parity-final-diagnostic` and
`dispatch-parity-final-ordinary`. The final pair follows review of supported events.
The first three parity attempts retain their local
setup/assertion failures. The compact verification file binds successful receipts
and source manifests. A new hosted build/observation remains necessary; no metric,
baseline, minimum-iOS or complete candidate acceptance is implied.
