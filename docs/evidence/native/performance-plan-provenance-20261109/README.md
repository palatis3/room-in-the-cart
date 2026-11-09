# Performance archive provenance — November 9

Performance consumers now verify the selected test plan and five Release
executables before simulator setup. Producer receipts travel in the existing
Products archive. Source, plan, executable, Info.plist and mode mismatches fail
early; same-run, same-source earlier producer attempts remain valid on retries.
No jobs, selectors, native flags, metric requirements or baselines changed.

Allowlisted instrumentation settings and known library availability are retained
as observations. Unknown values and arbitrary environment/path contents are not
published. Matching receipts do not establish the effective test-process
environment or loaded libraries, and do not repair missing performance metrics.
This checks the listed executable/metadata identity, not every archive resource.

Validation:

- All **409** offline Python checks passed, including15new provenance cases.
- Workflow lint and independent validation passed for all17queue nodes.
- Independent review matched the strict plan layout to a retained real Xcode27.1
  Release plan. Read-only compatibility also matched all five executable and
  Info.plist hashes against the successful local product manifest.
- Tampered/missing products, plan/source changes, wrong run identity, future
  producer attempts, unsafe paths, unknown values and deadlines are covered.
- No native test or hosted run was dispatched for this change. Its first hosted
  consumer observation remains pending a justified candidate run.

Retained originals: `.build/WorkflowFinalNov09/` and
`.build/Xcode27ScrollDiagnosticNov09/plan-provenance-r1/` on this Mac.
These are local retained originals, not an independently retrieved remote archive.

| Proof | SHA-256 |
| --- | --- |
| Final validation receipt | `f557e8c34143424da847e4954318f4f736a09d835e17054aae11bd09f1a8d1c8` |
| Full offline log | `53d186ec9a91efee49f19b33932309c617eb0736c47228cc9234b6238ad54907` |
| Workflow lint report | `ffb04533aec264def22430d0aa3f4b6803aa59054750b273ba8251dcd0b7d418` |
| Reviewed implementation patch | `86d3e76a2413e91c5311b79ce225f1237a8db1cb4df69b193ba9d010c8756e9d` |

Follow [CI-VALIDATION](../../../CI-VALIDATION.md): finish focused repairs, freeze
one exact revision, then qualify that combined candidate. Merge and App Store
readiness remain separate; previous focused passes are not current full coverage.
