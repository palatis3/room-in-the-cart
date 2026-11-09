# Bounded simulator inventory and candidate qualification

The combined candidate now gives fresh device/runtime discovery a separate
30-second infrastructure allowance, with a three-minute capability step. Other
commands retain ten seconds. App metrics, baseline limits, native execution limits,
warning checks, source pins, cleanup and five-runner admission are unchanged.

Prior scoped inventory expired at ten seconds with a live child and no available
pipe output. The new allowance is a bounded infrastructure policy decision, not
a calibrated performance target. No automatic retry is added.

Astra reviewed the change. Controlled-clock checks accept output at15seconds only
for inventory, reject output at the30-second boundary, and retain failure/cleanup
for missing output. Actual command routing and the outer-step envelope are checked.
All366 offline tests pass in11.854seconds; all17 workflow queue nodes and actionlint
checks pass. Hosted qualification is pending one capability-only probe. It cannot
approve missing metrics, the original minimum-iOS journey, merge or release.

The default workflow now states the qualification sequence: measurement recovery,
minimum-iOS fix, freeze one combined commit, full regression, then merge-gate review.
Physical-device/human/provider/distribution acceptance remains separate. Existing
compact evidence and exact-revision checks remain in force.

## Retained local evidence

- `.build/Xcode27ScrollDiagnosticNov09/inventory-budget-r1/plan.json` — SHA256 `dd2f4121cdb84872f73f58cebee0173867b87ec8644d9a23774c6aeeedd802e1`.
- `.build/Xcode27ScrollDiagnosticNov09/inventory-budget-r1/offline-tests.log` — SHA256 `059336ef6903574e597c14db2e7d75e0abceb63a0fffc9e9d912ebd569da0b37`.
- `.build/Xcode27ScrollDiagnosticNov09/inventory-budget-r1/workflow-lint.json` — SHA256 `41d5ea771fb6187481cc1f98faa9892eff24c91bef7049bc6e1ef0b41abc759e`.
