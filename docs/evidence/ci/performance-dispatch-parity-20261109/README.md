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

Hosted successor [42700832046](https://github.com/palatis3/room-in-the-cart/actions/runs/42700832046)
verified commit `506fef51dff21f894a9f0bc85a1ccb20640a7b01` and passed all 227
Ubuntu controls. The producer then rejected the `xcodebuild` file hash before
compilation. Its observed hash was not emitted, and the failed check preceded
receipt creation; no artifact existed. Tool-identity retention is the next scoped
correction. The helper, app build, XCTest and required metrics were not reached.

The failure-time reporting correction now retains bounded expected/observed
tool, SDK and version identities before exact admission. It preserves a failed
setup receipt even before any command or build log exists. Original accepted
identities and the exact admission functions are unchanged. The existing always
uploaded prepare directory carries the report.

Sixteen focused regressions pass. Four final-row deadline/file-drift subcases
fail against the preserved first patch and pass after review correction. The
new suite is part of the actual cheap workflow step: both final profiles now
pass **243 checks across nine suites**, in about 6.4 seconds, on matching source
manifests. Workflow lint and all 17 queue definitions pass. Frozen patches, logs
and local file-only identity inventory remain in `preflight-retention-r1/` and
`preflight-retention-r2/`; final workflow integration receipts are
`dispatch-retention-final-diagnostic/` and `dispatch-retention-final-ordinary/`.
A hosted retry is needed to obtain the previously unreported tool identity.

Hosted runs [42703089031](https://github.com/palatis3/room-in-the-cart/actions/runs/42703089031)
and [42705491175](https://github.com/palatis3/room-in-the-cart/actions/runs/42705491175)
verified failure-time retention. The latter passed 254 early controls and retained
a digest-verified 5,000-byte archive. All four Xcode tools have matching bytes
outside their declared signature regions and identical CodeDirectories; their
CMS signing envelopes differ. The actual CoreSimulator executable also differs
(1174.21 hosted versus 1174.9.2 local); equivalence is not claimed.

Commit `8f58b7f40480b05ff17b2e00810e35b03763051b` admits the one complete
reviewed hosted four-tool hash set alongside the original local set. Mixed,
missing, unknown and changed tool identities remain rejected. SDK pins and
subsequent actual executable stability checks remain intact. This is diagnostic
compatibility, not baseline approval or hosted signature-chain verification.

Both complete local workflow profiles pass **263 checks**, in 6.564 and 5.951
seconds. They ran in an isolated committed-source checkout, excluding unfinished
app changes; every source hash was checked against that commit. Local originals
are `reviewed-hosted-profile-r1/` and `hosted-profile-candidate-r1/`. The successor
[42707391568](https://github.com/palatis3/room-in-the-cart/actions/runs/42707391568)
is the single focused hosted observation for this change. Its outcome must be
recorded separately; these local checks do not establish native success.

The successor 42707391568 passed all 263 early controls, observer helper admission
and Release build/package/upload. Its separate consumer passed restored-product
provenance and fresh-simulator setup, then stopped during startup. The ninth
app-data container query hit its five-second deadline while the testmanager logs showed
runner installation in progress, about 19.55 seconds after native dispatch. The
original startup budget was 120 seconds. No test-case verdict, trace or required
duration was established. Later custody/export failures follow that interruption.

Producer and consumer diagnostic ZIPs are digest-verified, with 52 verified consumer
archive members. Originals and root verification are in
`hosted-42707391568/`. This proves hosted build/transport and failure preservation;
it does not answer the missing-metric question. A narrow startup-budget correction
is being reviewed before another run; no baseline or cleanup waiver is approved.

Commit `ca3cf777c93196300bf5045b9d60a8e41315eabe` corrects that early cutoff:
only initial app-data discovery uses the remaining existing 120-second startup
budget. Later installed-container queries retain five seconds. Every wait checks the
owned native/query identities and output/disk budgets; only the observed ENOENT
response counts as an absent container. A query exiting between polling and
identity sampling is reaped normally; live identity changes still reject. Final
output is checked after termination before reading. Receipt validation continues
to reject every signaled process; no cleanup exception was added.

All 102 observer controls pass, including 16 new fake-clock/process cases. Both
complete workflow profiles pass 279 controls in 5.766 and 5.847 seconds. All input
bytes/modes match the committed Git tree. Batched tree verification replaces
per-file Git subprocesses; both profiles plus source verification took 12.36 seconds.
Frozen originals are `startup-container-budget-r1/` and `startup-candidate-r1/`.
[Focused successor 42711707477](https://github.com/palatis3/room-in-the-cart/actions/runs/42711707477)
targets that exact revision. Native observer qualification remains pending its
terminal result; the run also contains the separately validated new app/backend
slice, so it is not a controlled before/after performance comparison.


The focused successor42711707477 is terminal. All279 early checks, helper
preparation and Release build/package passed. App-data discovery exhausted the
original120-second startup deadline; runner installation began at+118.057 seconds.
No selected case, trace or required measurement was established. The five-second
lookup failure did not recur. Root verified both ZIP digests,21 retained files and
all54 TAR members against the original archive receipt. Retained first failure:
`hosted-42711707477/{monitoring-receipt,root-verification}.json`.

Review of the prior successful run42639339096 found fixture readiness at about
+133.833 seconds after native dispatch. The observer's original absolute120-second
ARM limit would reject that known successful journey. A bounded phase-budget
correction is therefore justified for review; polling contention remains unproved.
No unchanged retry, performance baseline or full-app qualification follows from
this diagnostic evidence.


The reviewed correction separates dispatch-to-binding (180 seconds), binding-to-ARM
(120 seconds), and ARM-to-normal-native-completion (120 seconds), with a 420-second
absolute limit. Phase deadlines start once, and ready statuses or slow identity
checks cannot bypass expiry. Receipts now identify phase transitions and failure
timing. This changes diagnostic startup allowance, not performance baselines or
required measurements. Existing tracing, protocol, ownership and cleanup checks
remain unchanged; installed-container queries still have five seconds.

All 121 observer controls pass. Both actual cheap workflow profiles pass **298
checks**, in 9.381 and 9.372 seconds while an independent app build was running.
Root verified the frozen payload hashes and unchanged protected inputs.
[Phase verification](phased-startup-verification.json) binds the originals in
`phased-startup-budget-r1/` and `phased-candidate-r1/`. A hosted successor has not
yet been dispatched; the missing-metric question remains open.


## Initial installed-bundle discovery

Run [42728845944](https://github.com/palatis3/room-in-the-cart/actions/runs/42728845944)
at4f5efb100a1b901d2e8e09f1f0dbe30f5a058f75 passed324 early checks, helper typecheck
and Release producer. The original scroll XCTest started and app-data discovery
succeeded. Initial installed-app lookup then hit its independent five-second limit
with92.434 seconds remaining in the existing binding budget. No selected verdict,
required metric or trace was established. Root verified21 retained files, both
diagnostic ZIPs and all77 archive members; the first fault is preserved.

The successor extends the existing startup-query path to both initial installed
bundle lookups. They share the original180-second binding deadline with app-data
discovery, including same-owned-process acquisition. A lookup cannot reset that
deadline. Post-binding queries remain limited to five seconds. Identity, phase,
absolute-wall, signal-rejection and original measurement gates are unchanged.
All155 observer controls pass, including eight new regressions and expected
failures against the prior implementation. Complete ordinary/observer preflight
profiles must pass against the final committed successor before one changed
hosted diagnostic. [Compact verification](initial-bundle-verification.json).
