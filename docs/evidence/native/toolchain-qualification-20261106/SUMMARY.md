# Qualification run 42261730525, attempt 1

Candidate `5376a01227d9ccf2cba53123b7887c83531088de`; app/test source `8f864eafc3887ea16be996124d55fa2ca2708706` remains unchanged. Terminal workflow: **failure**. This is calibration only; release acceptance and cause-fixed claims remain false.

| Invocation | Native result | Warnings | Independent verdict |
| --- | --- | --- | --- |
| ui06 | 5 passed / 0 failed / 0 skipped | 0 | passed |
| spanish | 4 passed / 0 failed / 0 skipped | 0 | passed |
| scroll | 1 passed / 0 failed / 0 skipped | 0 | Case verification: ValueError: Missing required performance metric: com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration |

Build succeeded in Debug and Release. Exact observed environment: Xcode 26.4.1 (17E202), iOS 26.4.1 (23E254a), iPhone 17 arm64. Observed runtime identifier is `com.apple.CoreSimulator.SimRuntime.iOS-26-4`. Debug inventory: 652 enabled plus 15 disabled StoreKit cases; Release planner inventory: exactly three performance methods. All 2,276 source-manifest entries and 440 product-manifest entries are retained; case manifests match the build.

Scroll native case passed in 453.087 seconds with zero warnings, but the required scroll-duration series is absent. Only three memory metric series with five samples each exist. Root independently confirmed the same three memory rows in the original ZIP’s XCResult SQLite measurement database. The separate app-ledger SQLite readback was **not reached**, because the original metric checker exits first.

Owned simulator cleanup succeeded with hosted absence verification for all four jobs. Cleanup stdout was truncated, limiting independent raw-inventory replay. Four original evidence ZIPs pass API digest/size and bounded ZIP checks; every extracted original file still matches its ZIP bytes. Product archive remains metadata-only. Live product-byte guards ran on the host; the local audit compares retained manifests.

All 151 frozen verifier inputs and the prior c34 failure freeze remain unchanged. Original Bash prebuild failure, original UI06 timeout, KnownTrip timeout, original performance failure, and old unexecuted UI coverage remain preserved. Results on this unapproved profile do not replace old acceptance evidence.

UI06 largest-type/dark smoke passed in 174.585 s, but synchronization symptoms remain: urgent-repair restart logged the same missing animation-completion notification after a 60.04 s idle gap, then passed in 184.957 s. The first reminder case has a 27.81 s idle gap without an explicit timeout diagnostic. These log delays are distinct from the strict runtime-warning count. Spanish saved-offer restart passed in 694.714 s; no explicit synchronization timeout/animation diagnostic appears in any Spanish-history case, and its largest consecutive log timestamp gap is 5.06 s.

Details: `FINAL-AUDIT.json`, `evidence/verified-*.json`, `evidence/scroll-failure-proof.json`, `root-scroll-review.json`. The adjacent `freeze.json` hashes the final retained evidence.
