# CI workflow follow-through — November 9

The combined revision adds a manual, scroll-only fresh-simulator diagnostic and
failure-safe collection before simulator cleanup. Default PR/release coverage,
the five shared slots, original performance test/fixture/validators and approved
baseline remain unchanged. Failed attempted runs preserve a WAL-consistent
synthetic ledger snapshot; failed preservation blocks explicit device deletion.
This prepares a controlled comparison, not a performance baseline approval.

Validation:104focused checks and394full offline checks pass; pinned actionlint
plus queue validation pass all17native job definitions. Real temporary SQLite
WAL data is preserved in the new backup test; original main/WAL hashes match.
No fresh-device hosted result is claimed by this preparation report.

Membership/Restoration test fixtures now use per-fixture response routing instead
of mutable global routing. Both original-API negative controls fail as predicted;
the fixed candidate passes all74affected cases (72original +2new), native/strict0,
with no runtime or compiler warnings. Tested Xcode27.1/27A9275, iPhone17arm64,
iOS27.0/24A434. Canonical installation matches all561qualified product inputs,
source manifest `f0706a9cd416a0fa738e973f1bbb516dc5ac3a751a8b2d2e4db395dc58ea2559`.
This is scoped fixture reliability proof, not thread-sanitizer or full-app acceptance.

The active handoff was condensed from513lines while preserving its complete prior
version at immutable commit ebbbdb30. Raw originals remain local under
`.build/Xcode27ScrollDiagnosticNov09/` and `.build/MembershipRestorationIsolationNov09/`;
source/products/modes and735prior evidence files were verified before final custody.
Only the owned local simulator was shut down. No historical evidence was deleted.

| Retained proof | SHA-256 |
| --- | --- |
| Workflow patch | `be74fc05991ec3860a2e06ee09a71952880579146167abf16f5851d2d2b5327f` |
| 394-check offline log | `fe097a92aa33560c57f217c1ed60e7e681783b887a9a38512ef7a6437bb96813` |
| Workflow validation | `9ae682d049e43cbd8a9ce2de27f09918a8318e2ac27c15b3976a860b66f3b334` |
| Native qualification manifest | `c8d42fbe231c578788b8868975d8d162e59e0c6ff13ff80fcc379d1d2dde0641` |
| Canonical installation | `d9ab7ecae21908896c2d99995cf36b28283eebaf303198072cf124e4ac408fae` |

The working order remains [CI-VALIDATION](../../../CI-VALIDATION.md): diagnose,
qualify focused fixes, freeze one combined SHA, then run complete regression and
merge gates. Minimum-iOS framework failures, hosted metrics and full combined
qualification remain open. [RELEASE-EXECUTION](../../../RELEASE-EXECUTION.md) keeps
physical/human/provider/signing requirements distinct from merge readiness.
