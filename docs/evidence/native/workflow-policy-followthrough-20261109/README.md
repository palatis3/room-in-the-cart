# Workflow improvements carried forward

This update implements the diagnostic workflow follow-through. It does not
qualify the app for merge or approve Xcode 27.1 performance limits.

## Working rules and enforcement

| Improvement | Implementation | Remaining qualification |
| --- | --- | --- |
| Resolve measurements before baselines | Full-release source preflight rejects incompatible configured performance profiles before native fan-out. Existing strict checks still reject missing measurements. | Hosted launch/scroll measurements and reviewed new baseline. |
| Qualify one combined revision | Exact dispatch/checkout SHA guard, qualification receipt checker and candidate freeze procedure. | Full regression at the final combined commit; focused results from other revisions cannot substitute. |
| Diagnose minimum iOS | Preserve the full original Spanish journey, first failure and source/product identities. The corrected-SDK failure confirms SIGSEGV, but its stack is still missing. | Reviewed first-fault debugger diagnostic, then uninstrumented original-journey acceptance. |
| Optimize before adding shards | Existing five native slots remain. Compact CI feedback now ranks the five longest measured delays before jobs start separately from execution and slow steps. | Compare like-for-like runs before claiming a speedup or changing slot allocation. |
| Keep evidence compact | Existing qualification receipt validates hashes and recorded custody of retained originals; new reports link to preserved originals rather than duplicating raw exports. | Preserve originals for project lifetime; expiring Actions links alone are insufficient. |
| Separate merge and release | `RELEASE-EXECUTION.md` retains separate physical-device, human review, provider and signed-distribution gates. | CI success alone does not close those gates. |

The new wait ranking uses job creation/start timestamps. It includes dependency
and scheduling delays and is **not pure runner queue time**. Skipped jobs,
unstarted jobs and zero waits do not enter the ranking. Every unsuccessful job
remains visible even when timing tables are limited to five rows. No extra API
request or log download is needed; existing terminal snapshots are reused.

The last retained performance run illustrates why this distinction matters:
[42620394385](https://github.com/palatis3/room-in-the-cart/actions/runs/42620394385)
spent about 10.3 minutes building and 2.9 minutes preparing its fresh simulator,
while recorded job creation-to-start delays were only seconds. This one run is
not evidence of general runner capacity or a before/after speed improvement.
Its strict missing-metric failure remains unresolved; see the
[preserved diagnostic report](../diagnostic-followthrough-20261109/README.md).

Local disk availability at this update was approximately 13 GiB. No simulator
download, raw-artifact deletion, baseline relaxation or unchanged full regression
was performed for this workflow change.

## Next diagnostic without another build

The existing performance workflow now records the selected runtime's checker
identity during capability-only execution and after ordinary consumer setup.
`observe_runtime_checker.py` records its size, SHA256 and arm64 Mach-O UUID;
consumer mode binds the existing successful provenance receipt and unchanged
test-plan hash, then compares bytes with the producer's declared checker.
The original declared-path observations remain unchanged.

This is filesystem identity only: `loadedState` remains `unknown`, and neither
a match nor a native test pass establishes effective test-host loading. No
checker is disabled, no plan is rewritten and no performance limit is changed.
The receipt uses the existing artifacts/jobs; the capability-only path compiles
nothing and invokes no XCTest. Its hosted execution is still outstanding.

## Validation

All **431 offline tests pass** in12.503seconds. Workflow lint and all17 native
queue definitions pass; the five shared slots remain unchanged. The configured
full-release performance preflight still rejects the unapproved27.1 environment
before native fan-out, as intended. No native app test or hosted observer run
was performed for this change.

Original validation files are retained locally in
`.build/WorkflowPolicyImplementationNov09/`:

| File | SHA256 |
| --- | --- |
| `offline-tests.log` | `1ae211d7f2898ee1c6a23c16e4b709645349da547aa8b13cebc1efb31e9db657` |
| `workflow-lint.json` | `2db1a78a6568f536294b539c64c74a7c6fa33c6ef0dc13ecaac3f825eabfbae9` |
| `validation.json` | `39739be99c4d8816f42b93e256faf28b01264dba292ba348d8f066643b39db54` |
