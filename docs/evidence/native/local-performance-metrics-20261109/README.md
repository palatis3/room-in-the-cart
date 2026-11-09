# Local original performance measurements — November 9

Candidate `909f7c9b3e00d391c223a8f39f29eb23c54ce412`; original tests and all metric
contracts unchanged. Local Xcode 27.1/27A9275, iPhone 17, iOS 27.0/24A434, arm64,
Release / Test Scheme Action. Each case used a fresh dedicated simulator.

## Outcome

| Check | Observed result |
| --- | --- |
| Release performance build | Exit 0, 498.926 seconds; compiled inventory contains exactly the three original cases. |
| Bundle verification | Passed on unchanged products after correcting the local checker's missing frozen-config path. Original failure retained. |
| Original scroll | Native 0, strict 0, performance evidence 0; 76.07 test seconds, 99.633 command seconds; zero recorded runtime warnings. |
| Scroll duration | Five samples; median 2.566831834 seconds. All three required memory series also contain five samples. |
| Scroll persistence | SQLite check passed; 500 rows, 500 contributions, one paste import, zero checkoffs. |
| Original cold launch | Native 0, strict 0, performance evidence 0; 118.775 command seconds; five responsive-launch samples, median 6.917329292 seconds. |
| Hitch samples / approved baseline | Hitch samples unavailable. No new baseline approved or enforced; release acceptance remains false. |

This proves the original launch and scroll metric identifiers can produce complete
required measurements locally on this toolchain/runtime tuple. It does not repair
hosted run42561773341's missing measurements or establish their cause. Different
hosts, execution conditions and source revisions prevent a controlled attribution.
These timings are observations, not newly approved performance limits.

## Optional collector remains unqualified

The instrumented attempt passed setup and command capability checks, then stopped
before XCTest because its stream parser rejected a text banner and stderr. A
bounded synthetic-only probe with delayed emits received all three signposts and
the footer `{"count":3,"finished":1}`. It retained the same
`getpwuid_r did not find a match for uid 501` warning. The immediate-emission probe
received none and therefore cannot establish subscription readiness.

The existing parser treats the banner as malformed JSON and nonzero terminal
counts as unqualified. A future framing correction must bind the exact expected
banner and validate terminal count/schema against received records. Keep the
stderr gate intact; this probe does not authorize warning suppression. No parser,
warning policy, app source, performance test or metric threshold changed here.
Original uninstrumented tests were run independently; they do not qualify the
optional collector.

## Custody and scope

All 561 source inputs remained unchanged. The previous Debug products were archived
before the Release build; the resulting 376-file product tree was separately
archived with verified hashes and executable modes. Source manifest:
`7e9f3a6c427ff90dd2b35f56acdbd78179e1ac28ab08c459b27e89c83ac7ff7a`.
Product manifest:
`6053a60d6f0f953fa35633216c3892c4a8d7e921a9d7c7fef9f8f5e13c2cd419`.

Standard result exports added `database.sqlite3`. The first scroll inspector's
inventory-equality aggregate therefore remains false. Its subsequent custody
review verifies all 33 original native files byte-for-byte unchanged, no removals
and only that added database; all exports and actual validators passed. The launch
inspector separately records original-file preservation and the added database.
Neither result bundle was rerun or re-exported to change the outcome.

Raw originals remain local-only under
`.build/LocalPerformanceCaptureNov09/execution-r1/`. Retain them for project lifetime.
The compact binding is `final-evidence-sha256.json` there. Key original digests:

| Relative to that directory | SHA-256 |
| --- | --- |
| `.build/performance-original/calibration.json` | `8cc4adfdb26760df4f886bc5553ba85ab33de87c704f31141b84d5732a7e0de9` |
| `inspection-original/export-custody-review.json` | `351cdcdd053eade98a542b6bf5475458b07cc705a81d1aa38ab785a91db2f855` |
| `.build/performance-launch/calibration.json` | `51d0c234a31cf6c199cf5725f55c1af2164a2b66436b557063515b3dab11a92f` |
| `inspection-launch/receipt.json` | `b084e538096de9dffd8a79a7243e9b9c6d3317d7dd2740fcf0a074b7dc566afe` |

Products live in the existing immutable source archive's
`builds/6053a60d6f0f953fa35633216c3892c4a8d7e921a9d7c7fef9f8f5e13c2cd419/` child.
Its custody receipt SHA is
`58e24dea30abc193ff3722faff77b3ac8935ec54524c971378073dae6bc734bc`.
Current free storage was 11.82 GiB after preservation, above the 8 GiB reserve.

No hosted run, full combined regression, merge or release was performed. Next
compare the retained hosted/local environments before choosing one focused hosted
experiment; do not repeat successful local cases or approve hosted baselines from
local timings. Minimum-iOS and other first-version acceptance remain open.
