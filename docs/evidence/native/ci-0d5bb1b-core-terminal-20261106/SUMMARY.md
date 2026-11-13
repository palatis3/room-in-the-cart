# Candidate 0d5bb1b — original attempt1 evidence

Evidence gathering only; no blanket release acceptance.

| Run | Conclusion |
|---|---|
| 42316648565 | failure |
| 42316648633 | success |
| 42316648635 | failure |
| 42316648577 | success |
| 42316648580 | success |

Compiled inventory: 601 model tests and 52 ordinary UI tests. Candidate plan determines all group counts/orders.

| Group | Selected | Passed | Failed | Skipped | Runtime warnings | Strict exit |
|---|---:|---:|---:|---:|---:|---:|
| models | 601 | 601 | 0 | 0 | 0 | 0 |
| ui-04 | 6 | 5 | 1 | 0 | 0 | 1 |
| ui-03 | 5 | 5 | 0 | 0 | 0 | 0 |
| ui-05 | 5 | 5 | 0 | 0 | 0 | 0 |
| ui-02 | 5 | 5 | 0 | 0 | 0 | 0 |
| ui-08 | 5 | 5 | 0 | 0 | 0 | 0 |
| ui-09 | 6 | 6 | 0 | 0 | 2 | 0 |
| ui-06 | 5 | 5 | 0 | 0 | 0 | 0 |
| ui-10 | 6 | 5 | 1 | 0 | 0 | 1 |
| ui-07 | 5 | 5 | 0 | 0 | 1 | 0 |
| ui-01 (separate root scoped replay) | 4 | 3 | 1 | 0 | 2 | 1 |

UI01 default collector extraction remains refused at the unchanged50MB member limit. The separate root bounded128MB inspection and strict failure are retained explicitly; this is not a default guard pass.

Ordinary UI observed totals: 49 passed, 3 failed, 0 skipped; 5 runtime warnings within the existing scoped allowances. Native failures and the UI10 runner restart remain failed gates.

Original archives verified: 26. Frozen candidate inputs verified: 536. Historical freezes reverified unchanged.

See FINAL-AUDIT.json for separate StoreKit, package/sanitizer, native-wire, performance/persistence, source/runtime, security-coverage and timing evidence. Missing metrics, failures, skips or never-started jobs remain explicit; prior failures are preserved.
