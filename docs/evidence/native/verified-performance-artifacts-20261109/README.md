# Verified performance artifacts; duration still missing

[Run42611979729](https://github.com/palatis3/room-in-the-cart/actions/runs/42611979729)
finished with a strict evidence failure at exact source
`d3eb3ea2e2d5240f8c9af414e3a1e0fa85f7ca91`. This was one original scroll-only
calibration case on a fresh owned simulator, with optional signpost capture and
baseline enforcement disabled. It was not a full release acceptance run.

## Results

- Producer and consumer provenance gates passed. Selected plan, five executables,
  three protected source files and allowlisted settings matched. The independent
  producer receipt matched the consumer's bound receipt hash.
- Native XCTest passed1/1 in119.078seconds. The export contains only three memory
  series with five samples each. Required
  `com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration`
  is absent, so strict evidence validation correctly failed.
- Persisted pickup verification passed:500lines,500contributions,0checkoffs,
  revision3, SQLite quick-check ok. Snapshot preservation and owned-device deletion
  passed. Result UUID and owned simulator UUID match; runtime build24A434.
- No performance baseline was approved, and no unchanged retry was dispatched.

## New environment observation

The generated test-runner checker-library reference was readable on the producer
(338880bytes) but missing at that same reference during the consumer's pre-setup
receipt. This is a host-filesystem observation. Consumer observation occurs before
simulator setup/boot, whereas producer observation follows build-for-testing.
It does **not** prove the reference remained missing at execution, what the process
loaded, or why the duration metric is absent. Investigate that timing before any
path-rebinding proposal. Product corruption or plan mismatch is unsupported for
the selected artifacts checked by this run; unobserved process state remains open.

Protected performance source/scheme/checker behavior remained unchanged, but the
candidate also contains the separate CoreDomain deletion-history fix since the
prior040ec583 run. This is not a product-byte-identical causal comparison.

## Custody

Original metadata, two GitHub-digest-verified small ZIPs and selected receipts remain
under `.build/HostedPerformanceCurrentNov09/hosted-42611979729/`. The91MB product
archive was not downloaded; the selected evidence ZIPs total about2.1MB.

| Retained artifact | SHA-256 |
| --- | --- |
| `terminal-scroll-report.json` | `21694793ccaae2798e327be770bf347bc819fb1a8afb90a632361021b188f4ef` |
| `first-failure.json` | `95f4cdf0f38abdc773d8321a966431f21db24332d44dcd50ef3b15d5e31edd4b` |
| Producer receipt | `1e175aee7dbae20025ab0e20adcb39cfef5ea7f1a903714b4617b968d233c3e7` |
| Consumer receipt | `d0c800dae49f5da62caa7ffe1102597450bab6d545a767d24f8bdb2cf851f7b2` |

These are compact evidence references, not a claim of full-archive identity,
effective-process inspection, or a remote backup of local originals.
