# f90 hosted Release performance

Attempt 1 completed successfully at 01:11:45 UTC on November 8. The Release build and all three test jobs checked out PR merge `9cedaab61ecaedebc51479ffee39a4f2c14b68b4`, whose tree matches candidate `f90ad75a2e561891b2014ecb234d19639bcaed4c`. The approved baselines applied to Release on iPhone 17, iOS 26.2 (23C54), arm64, Xcode 26.3 (17C529). Each job ran exactly one selected test, which passed with zero skips, runner restarts or recorded XCTest runtime warnings. [Hosted run](https://github.com/palatis3/room-in-the-cart/actions/runs/42428215952) · [Pinned proof](proof.json)

| Measurement | Observed | Maximum |
|---|---:|---:|
| Responsive cold-launch median | 2.405281 s | 5.5 s |
| Rendered search p95 | 2,815.461 ms | 4,750 ms |
| Rendered checkoff p95 | 2,519.272 ms | 3,750 ms |
| Scroll duration median | 2.597978 s | 3.25 s |
| Scroll absolute memory median | 94,002.944 kB | 150,000 kB |
| Scroll peak memory median | 94,281.472 kB | 155,000 kB |
| Scroll maximum peak memory | 94,347.008 kB | 160,000 kB |

The scroll result contains five samples in the required XCTest duration series. The separate UIKit diagnostic records one complete pair in each of the warm-up and five measured swipe windows. The largest difference between a measured pair and the corresponding XCTest sample is 0.579 ms rounded up. XCTest reported no animation hitch measurements. [XCTest scroll metrics](scroll-xctest-metrics.json) · [UIKit diagnostic](scroll-signpost-diagnostic.json)

The rendered case records twenty samples per timing series and passes all six functional search checks across relaunch. The hosted SQLite readbacks record 500 rows and 500 contributions in each pickup, with twenty rendered checkoffs and zero scroll checkoffs. [Rendered timings](rendered-timing.json) · [Functional search](rendered-functional-search.json) · [XCTest launch metrics](launch-xctest-metrics.json)

Bounded ZIP range collection transferred 49,284 bytes. The proof records the GitHub archive metadata, selected member SHA-256 and CRC values, source pins, and verification scope. Local verification replayed exact selectors and console lifecycles, the complete launch performance check, the rendered and scroll measurement calculations, and all baseline comparisons. Hosted receipts cover XCTest warning detail and the SQLite readbacks. Media and complete result bundles were outside the local collection scope.
