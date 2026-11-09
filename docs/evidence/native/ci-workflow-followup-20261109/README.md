# Workflow improvements — November 9, 2026

The workflow changes are implemented and published to
`codex/xcode27-ci-migration-20261109` through
`b29d999375a1e2cceb1004a49c6156611567012b`. The canonical working branch remains
`codex/parallel-ios-ci`; these changes are not merged to main.

| Commit | Change |
| --- | --- |
| `9f4dfa22` | Reject configured/observed performance-environment mismatches before expensive native work. |
| `17f0a7d3` | Exact-revision qualification receipts, compact evidence policy and separate merge/release checklist. |
| `230f503a` | Opt-in bounded live/persisted scroll diagnostic with original metrics and strict gates preserved. |
| `5157b785` | Separate fake-CLI startup readiness from its unchanged hang-timeout assertion; production behavior unchanged. |
| `b29d9993` | Incremental command-stage receipts and a build-free capability-only route. |

All **336 offline tests pass** (13.276 seconds), and all **17 native queue
nodes** pass workflow validation. The five-slot capacity policy, source pins,
original test assertions, metric identities and baseline limits are unchanged.
No historical evidence was deleted. Independent review verified that the new
mode cannot compile, restore products, start log transport or invoke XCTest.

## Hosted evidence and remaining diagnosis

| Run / revision | Actual result |
| --- | --- |
| [42561415704](https://github.com/palatis3/room-in-the-cart/actions/runs/42561415704), `df49c37d` | Focused core passed all 11 jobs, including 717 models and two original Dinner journeys. This is not combined/full qualification. |
| [42561773341](https://github.com/palatis3/room-in-the-cart/actions/runs/42561773341), `df49c37d` | Three native cases passed; strict rendered evidence passed. Launch stored no metrics; scroll lacked required duration. No baseline approved. |
| [42566724355](https://github.com/palatis3/room-in-the-cart/actions/runs/42566724355), `230f503a` | Attempt 1 failed pasteboard setup. One failed-job retry reused its compiled artifact, passed setup, then failed opaque capability preflight. Neither attempt started XCTest. |
| [42570562637](https://github.com/palatis3/room-in-the-cart/actions/runs/42570562637), `b29d9993` | Capability-only mode correctly skipped build/products/XCTest. Its receipt identified the post-boot `xcodebuild -version` collector budget expiry. Later capability commands were not reached. |

The last result records a 10-second budget, exit -15, zero captured bytes and
16.801 seconds including cleanup. Boot took 70 seconds and the entire capability
step 98 seconds; those are different intervals. The collector starts its deadline
before spawning and checks expiry before draining pipes. Zero consumed bytes does
not prove zero emitted bytes, and the receipt does not prove a 10-second child
hang. Its surrounding journal writes are outside the command-stage timer.
No unchanged retry or timeout increase followed this result.

Source review found four version queries in that one job: the toolchain guard,
record/select step, environment guard and post-boot collector. A future narrow
change can deduplicate verification using an exact same-job identity receipt,
while retaining standalone checks and checking the actual consumer runner. This
would remove redundant work; it would not establish that the collector or missing
performance metrics are fixed. Review the bounded next experiment before dispatch.

## Operating rules going forward

Use one owner per independent failure; preserve the first failure and ask a
specific question before another diagnostic. Reuse compatible build products and
retained artifacts. Combine qualified fixes into one immutable commit, then run
full regression on that commit. Focused passes from different revisions cannot
replace it. The receipt checker verifies offline consistency, not live branch
protection or App Store authorization. Keep compact reports and hash-bound
originals; private originals may remain on this Mac.

The combined app candidate remains isolated. English, Spanish largest-text,
audio on two OS versions, repair and meal-move checks have focused passing proof.
Unsigned Release compilation and bundle checks also pass on that same source.
iOS 17.0/17.5 still fail in the XCTest logging callback; remaining combined
qualification is tracked in the current handoff. Physical,
human, provider and signed-distribution gates remain separate.

## Retained originals

- Qualification checker review and trial receipt: `.build/QualificationReceiptNov09/`.
- Collector patches, independent review and validation: `.build/Xcode27ScrollDiagnosticNov09/preflight-r2/`.
- Prior hosted bundles: `.build/Xcode27PrimaryMigrationNov09/hosted-*`; downloaded/exported once.
- Latest capability evidence: `preflight-r2/hosted-42570562637/`, relative to the collector directory. Terminal receipt SHA256 `82f3fb2581f94055c0332ff9855db07436dcfe8cb5b47d031d5326c1fef3a4e9`; single 636-byte artifact ZIP SHA256 `6e457d28048db840c61df0f9f552e92e6edf229d2f0ccc6ba46a53cd71f396ee`.
- Fake-boot readiness validation: `.build/BootReadinessTestNov09/`.

These are retained local originals, not a claim of independent off-Mac archival.
See [CI operating instructions](../../../CI-VALIDATION.md),
[current handoff](../../../CURRENT-HANDOFF.md) and the
[first-release checklist](../../../RELEASE-EXECUTION.md).
