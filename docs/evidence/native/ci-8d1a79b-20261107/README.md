# Original 8d1a79b CI cohort — terminal evidence

All six original attempt-1 workflows are terminal. Core and Deep failed; Performance, Security, Native wire and Fixtures succeeded. The collectors exited naturally. Nothing was retried, cancelled or dispatched to obtain this result.

| Gate | Outcome |
| --- | --- |
| Native models | 604/604 passed |
| Ordinary native UI | 51/53 passed; normal and Reduce Motion share-sheet Close readiness failed |
| StoreKit configurations | English14/15, Spanish15/15; English simulated cancellation exceeded120seconds |
| Release performance | All3 native, measurement and baseline gates passed |
| Fixtures | 47/47 passed across14shards |
| Package and sanitizers | Each389passed with3declared native-wire skips |
| Native service integration | Four Node cases and six Swift scenarios passed |

Six ordinary-UI and six fixture warning occurrences satisfy the existing exact selector/activity/count allowances. English StoreKit and Reduce Motion UI each retain a runner restart. These are retained failures, not app-only causal diagnoses. See [the audit](FINAL-AUDIT.json) for exact selectors, artifacts, limits, source bindings and run links, and [the fixture proof](fixture-terminal-proof.json) for its exact selection. Records remains redacted-report/plan-only; no raw Records result, log or media was read.

The exact candidate is8d1a79b22981148839c6e3d0827c6710f877a369; PR mergee7dc8bf0f3ac256b320f9f82cd1887f1beccfbb6 has the identical treef39e75df75ff2225492f95d7237650bdddc56e69. Root independently rehashed all9,472frozen files (1,611,237,149bytes), in addition to the monitor's verification. The full manifest refers to the preserved scratch collection under `.build/CIResearch20261106/candidate-8d1a79b`; raw archives/results/logs are not duplicated in this publication.

Root corrected a copied performance evidence auditor's stale merge pin only after both collectors were confirmed terminal. Its original and any prior verdict/absence were preserved separately. The corrected replay verifies all available performance checkout logs and all three setup sequences; complete checkout provenance is separately audited. No native result or hosted outcome changed.

Swift CodeQL reports27rules/0findings, with254repository runtime sources plus generated assets represented. Eleven extraction diagnostics and292unresolved AST nodes remain limitations. The full database archive guard refusal is retained and its payload remains uninspected. The older source-audit freeze had hashed its stdout before the final print; it is preserved. The separate post-execution manifest records the actual final log hash65be7e62347b5d6a8603b0dd5cf7f9a77f7f9c6233d340a5829fb98afd0935eb.

This cohort does not cover subsequent local commits or establish release acceptance. The three failures remain open; diagnostic evidence and later fixes require their own proof.
