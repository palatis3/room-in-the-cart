# Full-release performance preflight

The release entry point previously launched core, deep, fixture, native-wire and
staging native work alongside performance after source validation. Its performance
planner could then reject a known baseline mismatch while the other suites used
Mac slots. The new Linux source-preflight step rejects that mismatch before the
entire native fan-out. Independent security/dependency checks remain available.

`scripts/check_release_performance_preflight.py` reads existing performance
workflow pins and reuses the configured-environment compatibility validator.
There is no calibration override for full release. Focused calibration still uses
the existing performance workflow. No jobs, slots, selectors, deadlines, approved
profiles or final metric checks changed. This prevents known wasted work; no
full-batch speedup has been measured.

Validation against parent `f20553398467004075e691f4f28f043c470bc3a7`:

- All **411 offline tests pass**; all **17 native queue nodes** pass workflow lint.
- New coverage proves incompatible-profile rejection, synthetic compatible-profile
  success, workflow-pin drift rejection, no native queries, and guard ordering.
- The real current profile deliberately exits **1**: Xcode27.1/iOS27.0 has no
  approved profile. This is the expected guard result, not release acceptance.
- Independent Astra review found no actionable issue. Hosted execution of this
  new step and the full combined regression remain outstanding.

Original local verification files remain in `.build/ReleaseBatchPreflightNov09/`.
They are local-only retained evidence, not an independent remote archive. The
compact receipt binds the three executable source files and each original log:

| Original | SHA256 |
| --- | --- |
| `validation.json` | `4e00001ad2270df84431b7c21fb39b2ac5b22180e2817054aedf55aed65b2ff9` |
| `python-tests.log` | `c9cbd1b728cfb8118aba37bc241ae288d3ba275a0eb23fdad112ac2ff2909449` |
| `workflow-lint.json` | `cb5b44f512b21f5204d0923e7f6c5ef50b043c2462e5a957475547b81ae11508` |
| `current-baseline.stderr` | `2c63dc6184f3179721a110b157491bf0380d98ed5d1d5bb54a24461bbf4582e0` |

The operating sequence remains: diagnose missing metrics and minimum-iOS failures;
finish focused fixes; freeze one combined commit; qualify all required gates at
that revision. Keep five slots, measure expensive test work before adding shards,
retain compact reports with originals, and track App Store requirements separately.
See [CI procedure](../../../CI-VALIDATION.md) and
[release checklist](../../../RELEASE-EXECUTION.md).
