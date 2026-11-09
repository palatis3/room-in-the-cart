# Workflow improvements — November 9, 2026

The workflow changes are implemented and published to
`codex/xcode27-ci-migration-20261109` through
`d2016380cbac0a49497c79806ea64431800394d6`. The canonical working branch remains
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

All **353 offline tests pass** (14.016 seconds), and all **17 native queue
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
narrow handling fix has43 focused tests; the full offline suite passes353. The
latest hosted run did not reach help, so hosted/local text equality and the help
fix's hosted behavior remain unverified. Device discovery passed in9.798s in the
prior run but timed out in the latest one on a different runner. This is not a
controlled performance comparison. Inspect collector timing/output behavior and
simulator readiness before another bounded experiment. The next narrow proposal
is scalar process/pipe phase timings and a bounded nonblocking late-byte
observation on timeout, without changing failure/deadline behavior. Pre-boot
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
- Earlier capability evidence: `preflight-r2/hosted-42570562637/`, relative to the collector directory. Terminal receipt SHA256 `82f3fb2581f94055c0332ff9855db07436dcfe8cb5b47d031d5326c1fef3a4e9`; single 636-byte artifact ZIP SHA256 `6e457d28048db840c61df0f9f552e92e6edf229d2f0ccc6ba46a53cd71f396ee`.
- Identity-reuse review and validation: `.build/Xcode27ScrollDiagnosticNov09/identity-reuse-r1/`; reviewed patch SHA256 `7a5566ca64ac70e4376f59619bd3e9ccfba47ea8b7e1ca8ef2f4c36dafc09fa4`.
- Help handling and353-test validation: `.build/Xcode27ScrollDiagnosticNov09/help-exit-r1/`; reviewed patch SHA256 `2d4a45722c90110646dd21e7a77c9806525a6757f284e7ade14098266c471cfa`.
- Latest hosted evidence in that directory: `hosted-42574682497/`; terminal receipt SHA256 `30e1a903ed1b08b008a2048ce3be95c70edd5403960617dc17d9fb5338dddb3a`; single1192-byte artifact ZIP SHA256 `c30d9cfee446b6b29e9912b7cb461249cace88da54f9acdd1ceac96c21b5eb75`.
- Independent minimum-OS reductions: `.build/MinimumOSXCTestReproducerNov09/r1` and `r2`; R2 built then failed before typing with no keyboard focus, native65/strict1. No original XCTest crash reproduction or compatibility pass. R2's source manifest SHA256 `42e630063253427c70fe7ff3dfdc13f908d8c5590531ea865b9345ae225c08f8`.
- Fake-boot readiness validation: `.build/BootReadinessTestNov09/`.

These are retained local originals, not a claim of independent off-Mac archival.
See [CI operating instructions](../../../CI-VALIDATION.md),
[current handoff](../../../CURRENT-HANDOFF.md) and the
[first-release checklist](../../../RELEASE-EXECUTION.md).
