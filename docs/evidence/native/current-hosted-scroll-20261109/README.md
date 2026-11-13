# Current-candidate hosted scroll — November 9

[Run42592941333](https://github.com/palatis3/room-in-the-cart/actions/runs/42592941333)
attempt1 tested `e95fcec9988a2fb4b7e98e3d543d89b790f16c95`. It is terminal failure,
not a successful calibration. Inputs: scroll only, baseline enforcement false,
both optional-capture flags false. No other repository runs were active or queued
when dispatched. The original performance test and metric requirements were intact.

The optimized build passed. The original scroll XCTest passed1/1 in122.086seconds;
the independent saved-pickup check found500lines/contributions, one paste import
and zero checkoffs. Strict measurement validation failed because required duration
`com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration` was absent.
Only the three memory series, each with five samples, were present. The original
result SQLite and JSON export agree; this is not an established export-parser loss.
No calibration report or baseline approval resulted.

The post-hoc query completed but captured zero matching events. That does not
establish whether the app emitted signposts. No unchanged retry was dispatched.

## Observed comparison

The current app/test source matches the locally tested909f revision; e95 adds only
documentation. Original test, fixture, scheme and metric checker also match the
earlier hosteddf49 source. Xcode27.1/27A9275, iPhone17 arm64, iOS27.0/24A434 and
Release/Test Scheme Action match local results. Both local original cases produced
their required duration samples. Hosted macOS27.0.1/26A434 differs from local27.2;
hosted products are archived/restored between jobs. Hosted selects an image-provided
simulator, whereas the local cases used newly created devices. Those are observed
differences, not proven causes. CPU pressure and actual launched-process environment
were not captured.

Hosted setup recorded67.001s boot,74.294s installed-app inventory,2.074s absence
check and40.893s pasteboard seed. These are setup observations, not app latency or
proof of host contention.

## Retained originals

Local-only evidence is under
`.build/HostedPerformanceCurrentNov09/hosted-42592941333/`. Only the original scroll
artifact was downloaded, once; its digest matches GitHub. Retain these originals
for project lifetime. No build archive was redundantly downloaded.

| Original | SHA-256 |
| --- | --- |
| `terminal-scroll-report.json` | `de8ca47e75503040e415b33aed29d62c6190d450dd8bba02a6a7c0104e26fed6` |
| `first-failure.json` | `726fc9ac9395d96cc386bd2af1cd179e793ee4ead8e2779e7b99b7df81019f89` |
| Original artifact13663171664 ZIP | `41794d4d2ae984da6fbd27cf5774e3f8f6b8569a70cf08f5b66761995fbb8fc5` |
| Original result `database.sqlite3` | `25573d7988870d7a64d123f539bbcf232703f8fd4f2dcc26c4210878d2d6cb88` |

Next evaluate a newly created, job-owned simulator with the exact same runtime and
type, using existing verified ownership/cleanup support. This changes a concrete
state-provenance difference; it is not a claimed repair until native evidence exists.
Keep strict metrics, warnings and all deadlines. Hosted launch, minimum-iOS and full
combined qualification remain open.
