# Workflow improvements — November 9, 2026

The workflow changes are implemented and published to
`codex/xcode27-ci-migration-20261109` through
`e2bbdad0564c071e6bdf272bcce3bea7972f3485`. The canonical working branch remains
`codex/parallel-ios-ci`; these changes are not merged to main.

| Commit | Change |
| --- | --- |
| `9f4dfa22` | Reject configured/observed performance-environment mismatches before expensive native work. |
| `17f0a7d3` | Exact-revision qualification receipts, compact evidence policy and separate merge/release checklist. |
| `230f503a` | Opt-in bounded live/persisted scroll diagnostic with original metrics and strict gates preserved. |
| `5157b785` | Separate fake-CLI startup readiness from its unchanged hang-timeout assertion; production behavior unchanged. |
| `b29d9993` | Incremental command-stage receipts and a build-free capability-only route. |
| `219d2f66` | Reuse a fresh verified same-job toolchain identity; reject stale or mismatched receipts while retaining live runtime checks. |
| `d2016380` | Accept exit64 only for exact simulator log-help commands with expected usage/tokens and no collector errors. |
| `259c42ba` | Record bounded process/pipe phase timings and discarded late-byte counts; deadline and admission failures remain unchanged. |
| `e2bbdad0` | Scope returned inventory to the selected UUID, retaining exact identity/state/availability/runtime checks and all budgets. |

All **363 offline tests pass** (11.699 seconds), and all **17 native queue
nodes** pass workflow validation. The five-slot capacity policy, original test
assertions, metric identities and baseline limits are unchanged.
No historical evidence was deleted. Independent review verified that the new
mode cannot compile, restore products, start log transport or invoke XCTest.

## Hosted evidence and remaining diagnosis

| Run / revision | Actual result |
| --- | --- |
| [42561415704](https://github.com/palatis3/room-in-the-cart/actions/runs/42561415704), `df49c37d` | Focused core passed all 11 jobs, including 717 models and two original Dinner journeys. This is not combined/full qualification. |
| [42561773341](https://github.com/palatis3/room-in-the-cart/actions/runs/42561773341), `df49c37d` | Three native cases passed; strict rendered evidence passed. Launch stored no metrics; scroll lacked required duration. No baseline approved. |
| [42566724355](https://github.com/palatis3/room-in-the-cart/actions/runs/42566724355), `230f503a` | Attempt 1 failed pasteboard setup. One failed-job retry reused its compiled artifact, passed setup, then failed opaque capability preflight. Neither attempt started XCTest. |
| [42570562637](https://github.com/palatis3/room-in-the-cart/actions/runs/42570562637), `b29d9993` | Capability-only mode correctly skipped build/products/XCTest. Its receipt identified the post-boot `xcodebuild -version` collector budget expiry. Later capability commands were not reached. |
| [42573256459](https://github.com/palatis3/room-in-the-cart/actions/runs/42573256459), `219d2f66` | Same-job identity and live inventories passed; exact stream help returned64 with2116 stderr bytes. No build/transport/XCTest. |
| [42574682497](https://github.com/palatis3/room-in-the-cart/actions/runs/42574682497), `d2016380` | Same-job identity passed; device discovery exceeded10s (exit-15,10.459s including cleanup). Help was not reached. No build/transport/XCTest. |
| [42576978686](https://github.com/palatis3/room-in-the-cart/actions/runs/42576978686), `259c42ba` | Device inventory deadline again; spawn1.419s, child still running, no normal/late output. New phase evidence retained; no runtime/help/build/transport/XCTest. |
| [42578578778](https://github.com/palatis3/room-in-the-cart/actions/runs/42578578778), `e2bbdad0` | Scoped UUID query still hit10s; spawn0.740s, child running, no normal/late bytes. No runtime/help/build/transport/XCTest. |

Run42570562637 records a 10-second budget, exit -15, zero captured bytes and
16.801 seconds including cleanup. Boot took 70 seconds and the entire capability
step 98 seconds; those are different intervals. The collector starts its deadline
before spawning and checks expiry before draining pipes. Zero consumed bytes does
not prove zero emitted bytes, and the receipt does not prove a 10-second child
hang. Its surrounding journal writes are outside the command-stage timer.
No unchanged retry or timeout increase followed this result.

The same-job identity correction now removes only the fourth duplicate version
query. Writer and consumer bind revision, run, attempt, job, runner, simulator,
selected developer directory and enforcement mode. Missing/mismatched supplied
receipts fail closed; standalone collection still verifies directly. The identity
is ordinary job provenance, not a signed attestation. The changed environment
helper's protected source hash was deliberately updated and reviewed; original
metric identities, thresholds and test source pins remain unchanged.

Local public `log help stream/show/emit` each returned64 with valid usage. The
narrow handling fix had43 focused tests and353 full-suite tests atd2016380.
Run42574682497 did not reach help, leaving hosted/local text equality and hosted
help handling unverified at that revision. Device discovery passed in9.798s in
run42573256459 but timed out in42574682497 on a different runner. This is not a
controlled performance comparison. Inspect collector timing/output behavior and
simulator readiness before another bounded experiment. The next narrow proposal
was scalar process/pipe phase timings and a bounded nonblocking late-byte
observation on timeout. That proposal is now implemented and independently reviewed
at259c42ba, without changing failure/deadline behavior. One capability-only hosted
run42576978686 failed on that exact revision at the same inventory deadline.
Spawn took1.419s; the child was running when the deadline was observed, and both
immediate nonblocking reads would block. No normal or late bytes were retained;
no runtime/help/build/transport/XCTest was reached. The stage took11.063s including
cleanup. This distinguishes that observation from unread buffered output but does
not explain the service/scheduling delay. Pre-boot
inventories cannot replace fresh post-boot state. Do not repeat unchanged runs
or claim performance collection/baseline acceptance.

## Operating rules going forward

Use one owner per independent failure; preserve the first failure and ask a
specific question before another diagnostic. Reuse compatible build products and
retained artifacts. Combine qualified fixes into one immutable commit, then run
full regression on that commit. Focused passes from different revisions cannot
replace it. The receipt checker verifies offline consistency, not live branch
protection or App Store authorization. Keep compact reports and hash-bound
originals; private originals may remain on this Mac.

The combined app candidate is now integrated locally by exact source equality.
[Installation and limits](../combined-candidate-integration-20261109/README.md). English, Spanish largest-text,
audio on two OS versions, repair and meal-move checks have focused passing proof.
Unsigned Release compilation and bundle checks also pass on that same source.
iOS 17.0/17.5 still fail in the XCTest logging callback; remaining combined
qualification is tracked in the current handoff. Physical,
human, provider and signed-distribution gates remain separate.

## Retained originals

- Qualification checker review and trial receipt: `.build/QualificationReceiptNov09/`.
- Collector patches, independent review and validation: `.build/Xcode27ScrollDiagnosticNov09/preflight-r2/`.
- Prior hosted bundles: `.build/Xcode27PrimaryMigrationNov09/hosted-*`; downloaded/exported once.
- Earlier capability evidence: `preflight-r2/hosted-42570562637/`, relative to the collector directory. Terminal receipt SHA256 `82f3fb2581f94055c0332ff9855db07436dcfe8cb5b47d031d5326c1fef3a4e9`; single 636-byte artifact ZIP SHA256 `6e457d28048db840c61df0f9f552e92e6edf229d2f0ccc6ba46a53cd71f396ee`.
- Identity-reuse review and validation: `.build/Xcode27ScrollDiagnosticNov09/identity-reuse-r1/`; reviewed patch SHA256 `7a5566ca64ac70e4376f59619bd3e9ccfba47ea8b7e1ca8ef2f4c36dafc09fa4`.
- Help handling and353-test validation: `.build/Xcode27ScrollDiagnosticNov09/help-exit-r1/`; reviewed patch SHA256 `2d4a45722c90110646dd21e7a77c9806525a6757f284e7ade14098266c471cfa`.
- Latest hosted evidence in that directory: `hosted-42574682497/`; terminal receipt SHA256 `30e1a903ed1b08b008a2048ce3be95c70edd5403960617dc17d9fb5338dddb3a`; single1192-byte artifact ZIP SHA256 `c30d9cfee446b6b29e9912b7cb461249cace88da54f9acdd1ceac96c21b5eb75`.
- Independent minimum-OS reductions: `.build/MinimumOSXCTestReproducerNov09/r1`, `r2` and `r3`; R3 now passes its reduced sequence after restoring sibling controls. The original XCTest crash is not reproduced or resolved. [Bound result and limits](../minimum-ios-reduction-20261109/README.md).
- Phase timing patch/review and361-test validation: `.build/Xcode27ScrollDiagnosticNov09/phase-timing-r1/`; patch SHA256 `663657d00ebc5516475a94dc10489318da18b0d1cfcf22a7c6558736be3526ad`.
- Phase timing hosted originals: `phase-timing-r1/hosted-42576978686/`; terminal SHA256 `d4ca143488441f60261ab72bfe1cc85a91b38d3029b64b87e0b381094275fd13`, ZIP SHA256 `f20b56201251310b1818d9dfc2c414714a820d8be4b48a4b0e72f5a2e72ff7d0`.
- Scoped inventory hosted originals: `uuid-inventory-r1/hosted-42578578778/`; terminal SHA256 `90dc359de3c521806dd802dc164f024a3c55e5d351810f6a66285d7912c59d38`, ZIP SHA256 `897b2090ea2c35e34bf9acd1628bc6f682d6119150965c574efca0349e8e1b1b`.
- Fake-boot readiness validation: `.build/BootReadinessTestNov09/`.

These are retained local originals, not a claim of independent off-Mac archival.
See [CI operating instructions](../../../CI-VALIDATION.md),
[current handoff](../../../CURRENT-HANDOFF.md) and the
[first-release checklist](../../../RELEASE-EXECUTION.md).
