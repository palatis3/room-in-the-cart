# Bounded simulator inventory and candidate qualification

The combined candidate now gives fresh device/runtime discovery a separate
30-second infrastructure allowance, with a three-minute capability step. Other
commands retain ten seconds. App metrics, baseline limits, native execution limits,
warning checks, source pins, cleanup and five-runner admission are unchanged.

Prior scoped inventory expired at ten seconds with a live child and no available
pipe output. The new allowance is a bounded infrastructure policy decision, not
a calibrated performance target. No automatic retry is added.

Astra reviewed the change. Controlled-clock checks accept output at 15 seconds only
for inventory, reject output at the 30-second boundary, and retain failure/cleanup
for missing output. Actual command routing and the outer-step envelope are checked.
All 366 offline tests pass in 11.854 seconds; all 17 workflow queue nodes and actionlint
checks pass. The one hosted capability-only probe failed at device discovery;
it cannot approve missing metrics, the original minimum-iOS journey, merge or release.

The default workflow now states the qualification sequence: measurement recovery,
minimum-iOS fix, freeze one combined commit, full regression, then merge-gate review.
Physical-device/human/provider/distribution acceptance remains separate. Existing
compact evidence and exact-revision checks remain in force.

## Retained local evidence

- `.build/Xcode27ScrollDiagnosticNov09/inventory-budget-r1/plan.json` — SHA256 `dd2f4121cdb84872f73f58cebee0173867b87ec8644d9a23774c6aeeedd802e1`.
- `.build/Xcode27ScrollDiagnosticNov09/inventory-budget-r1/offline-tests.log` — SHA256 `059336ef6903574e597c14db2e7d75e0abceb63a0fffc9e9d912ebd569da0b37`.
- `.build/Xcode27ScrollDiagnosticNov09/inventory-budget-r1/workflow-lint.json` — SHA256 `41d5ea771fb6187481cc1f98faa9892eff24c91bef7049bc6e1ef0b41abc759e`.

## Hosted result

[Run 42580515105](https://github.com/palatis3/room-in-the-cart/actions/runs/42580515105)
tested commit `c97bbc00d148265bbde76b4515ef376880f4debc`. Toolchain identity and
simulator boot passed. Fresh device inventory reached its 30-second deadline,
exit -15, 31.001 seconds including cleanup, with zero normal or late bytes. The
child was still running; immediate reads from both pipes would block. Spawn took
9.971 seconds, followed by 20.110 seconds from pipes ready to the deadline. These
are observed phases, not proof of the underlying service or scheduling cause.

Runtime inventory and logging help were never reached; no compilation, transport
or XCTest ran. The separate budget did not resolve the bottleneck. Stop this
probe line here: investigate runner contention or a supported simulator readiness
signal before another changed experiment, rather than extending the deadline
again. No baseline or full-regression acceptance is claimed.

- `.build/Xcode27ScrollDiagnosticNov09/inventory-budget-r1/hosted-42580515105/capability-evidence-13656723345.zip` — SHA256 `0f49150e1e84aaa74db4a040106b249c7ad6c9704b0ac78a31a9b169c0f9d065`.

- `.build/Xcode27ScrollDiagnosticNov09/inventory-budget-r1/hosted-42580515105/capability-evidence-13656723345/capabilities.json` — SHA256 `f62a929d0b5b73a11ce0b7731671daf709d3a6eb5f10d7a1f1dee4700658e8d3`.
