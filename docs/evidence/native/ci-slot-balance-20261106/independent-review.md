# Independent review — CodeQL slot reassignment

**No blocking findings.** The reviewed diff contains only the intended two scalar changes: `ios-swift-codeql` moves from shared slot 2 to existing slot 4, and the workflow policy pins that same assignment. The before snapshots match HEAD; the after snapshots match the current files exactly. Each after file is exactly its before file with the one reviewed replacement.

| File | Before SHA256 | After SHA256 |
|---|---|---|
| `.github/workflows/ci.yml` | `12b1df6bf660aa404dca51e477683eed71f416cbc3a4e37fee8f3fa8b747e13c` | `32050e785e9e447b809821c9cca04ea851a2f4549ba6f59f4b84e059e3880faa` |
| `scripts/check_ci_workflows.py` | `f2f7eba7c69cf5304a97aedfcb789b916c25a00096514f80494528bd2b6fd449` | `4eebda05322d01251fece1aa94297a3dbe24309076456116af0e4b717dcb0157` |

The five shared slot names, all 14 reviewed native leaf definitions, queue/cancellation policy, matrix identities and row orders, selectors, shard boundaries, dependencies, runtime/toolchain pins, timeouts and acceptance checks are unchanged. The slot helper and all three planners are byte-identical to HEAD. This changes admission placement and can change cross-workflow interleaving; it does not add a slot or runner.

## Validation records reviewed

| Check | Retained result |
|---|---|
| Workflow policy tests | 17 passed using the corrected venv interpreter; exit 0 |
| Slot policy tests | 4 passed; original exit 0 |
| Planner tests | 23 passed; original exit 0 |
| Workflow/lint bridge | Corrected wrapper exit 0; 14 queue nodes independently validated; no policy errors or unexpected diagnostics |

The initial workflow-policy and lint attempts both exited1 with `ModuleNotFoundError: No module named yaml`. Their recorded command used the resolved system interpreter. Both original logs and `checks.json` remain present. `correct-venv-checks.json` records rerunning only those two affected commands through the original venv path, with exit 0. There is no evidence of a source, dependency or validation-policy change to make them pass.

The retained actionlint 1.7.12 process itself exited1 for its 14 known `queue` syntax diagnostics. The existing narrow bridge independently validated those exact queue nodes; its final report passed. This is not a claim that raw actionlint returned 0. All eight workflow source hashes in that report match the current files. I inspected these existing results and exact source/snapshot identities; I did not rerun tests or invoke native tooling.

## Limits retained

- The 33m 05s CodeQL workload redistribution is arithmetic from one cohort, including failure paths. It is not a measured or promised wall-time speedup, and it does not prove provider capacity.
- ApprovedProposal and StaleReviewedSave remain fixture indices 7 and 12, both on slot 2. No matrix override was applied; the final fixture pair can still serialize.
- The previous 0d5 UI failures, scroll missing-series failure, archive refusals and security extraction limitations are unchanged. This scheduling edit supplies no new native/release acceptance.
- No Git/source/hosted mutation or collector operation was performed by this review. Only this report was written.

Evidence: `checks.json`, `correct-venv-checks.json`, their referenced logs, `actionlint.json`, and the two before/after snapshots in this directory.
