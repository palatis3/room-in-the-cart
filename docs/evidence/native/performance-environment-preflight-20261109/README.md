# Reject incompatible performance environments before native work

Commit `9f4dfa22` (now published) adds configured compatibility validation on Linux, actual
runtime/device/toolchain validation before compilation and a repeated identity
check before consumer boot. Calibration bypasses only baseline availability,
not identity. The old approved baseline and full late metric checks are unchanged.
294 offline tests, pinned workflow validation of17 native queues, shell parsing
and whitespace checks pass. No native run was dispatched by that isolated follow-up. Subsequent hosted
results and the newer workflow changes are recorded in the workflow follow-up report.

## Retained local verification originals

The files below remain on this Mac in this evidence directory. Only this compact
report is committed; the hashes identify retained originals, not independent
off-Mac archival. [Current workflow results](../ci-workflow-followup-20261109/README.md).

| File | SHA256 |
| --- | --- |
| `python-tests-r2.log` | `74302d3dec9baada3cdfd51846b4904a8e630a6567fcf1141ce5496af35d62ed` |
| `review-r2.patch` | `e5d2e28dc8bed19195310d6cdc8d7e573989e5e0ef4fffac635d4b97e5407377` |
| `validation-receipt-r2.json` | `202e366f3a0ef8df2b5bed003411097d3d6cda92869c72f6c56b892e354778df` |
| `workflow-lint-r2.json` | `35adcc1bc661abb5e4aa456a709dc2e3f6a7887444a744f8701879cc3e861653` |
