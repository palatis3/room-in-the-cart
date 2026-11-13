# Independent local witness runtime review

**The retained result supports local standalone-witness compatibility on Xcode 27.1 / iOS 26.2, and instrumented nonreproduction.** The actual built-in scroll metric still produced its five required samples while the separate witness returned no measurements. This does not qualify hosted Xcode 26.3, explain the original missing series, establish uninstrumented equivalence, or justify a performance pass for the original failure. No new native action was performed for this review.

## Native result and measurement identity

`native-invocation.json` targets exactly `RoomInTheCartUITests/ReleasePerformanceUITests/testScrollingPerformanceOnFiveHundredItemPickup`, test-without-building, the recorded local Performance product, and owned simulator B7C06557-2E53-4BAF-A963-A5F9866351C4. Runtime receipt and result agree on iPhone 17 / iOS 26.2 (23C54); Xcode is 27.1 (27A9275), not hosted 26.3 (17C529). Native and strict exit receipts are both 0. Test summary and strict log establish **1/1 passed**, **228.49-second case duration**, one start/one passing completion, zero runtime warnings and no runner restart. Case duration includes setup and XCTest work; it is not the scroll metric.

`metrics.json` contains four built-in rows, each with five values: absolute memory, peak memory, memory delta and Scroll_DraggingAndDeceleration.duration. The five native duration samples are:

`2.583126125, 2.5663787090000003, 2.583303958, 2.582466166, 2.583091292` seconds.

Independently recomputed median: **2.583091292 seconds**. The native console prints the same series at six-decimal precision. No custom witness metric row, fabricated duration or hitch series appears. Absence of hitch data is not hardware/frame-hitch qualification. This review checked native console/export agreement, not a second original-xcresult SQLite metric extraction. No repository performance baseline was modified; this compatibility result is not a full release gate decision.

## Actual witness and endpoint correspondence

The retained attachment manifest binds `4999183A-C377-4749-B9AF-8EF5B890A504.json` to the exact scroll selector and same device. Its payload has 25 events, seven created instances, six report callbacks and zero omissions. Instance 1 is created-only. Instances 2–7 each retain exactly created → willBegin → didStop → report. This directly demonstrates the public copy/lifecycle/empty-array technique operated in this one local run without the old wrapper assertion failure; it does not establish behavior on another toolchain.

Schema-2 endpoint capture reports 106 parsed candidates, zero unparsed candidates, one matched process and **24/24 scoped endpoints**, status retained, zero omitted. This includes resets/inter-window events as well as measured-gesture pairs. All six gesture windows contain one matching begin/end pair. Both input hashes in correlation.json independently match the actual retained files.

Independently recalculated interval overlaps and signed margins from the original witness and endpoint JSON, without running correlate.py. Instances 2–7 overlap activity indices 0–5 uniquely, with no unmatched or duplicate activity. Each selected pair has matching process/signpost tokens and ordered begin/end timestamps. All output margins and UTC-versus-monotonic deltas match the independently computed values.

| Instance / activity | Begin after witnessed start (ms) | Witnessed end after endpoint (ms) |
|---|---:|---:|
| 2 / 0 | 211.224 | 9.448 |
| 3 / 1 | 209.202 | 7.702 |
| 4 / 2 | 266.191 | 9.401 |
| 5 / 3 | 203.854 | 9.582 |
| 6 / 4 | 229.264 | 14.320 |
| 7 / 5 | 344.050 | 10.415 |

Minimum numerical end margin is 0.007701873779296875 seconds; maximum absolute date/monotonic delta disagreement is 0.000023851783935491255 seconds. These are observations, not clock-accuracy/error bounds. Report 0 was not discarded or assigned warm-up identity to force a match. Six reporting windows remain distinct from the five native measured samples. Callback clocks/sequence are recorder observations after lock acquisition, not exact concurrent callback entry order. Witness report bounds are not proof of the built-in collector's private bounds or delivery.

The correlation's observations-only classification is appropriate for these actual inputs after the previously reviewed fixes. It does not upgrade the validator to a complete producer-schema validator or make any individual numeric containment a causal diagnosis.

## Source, products, persistence and cleanup

Independently rehashed **all 459 diagnostic source/configuration files and all 163 product-manifest files**: zero mismatches. Base and diagnostic manifests have identical path sets; exactly `ios/UITests/ReleasePerformanceUITests.swift` differs. Thus 458 manifested files retain base bytes; this is not a count of shipping-runtime files. All preparation-validation file hashes also match, including the reviewed recorder, metric, overlay and revised correlator. The source overlay is `d1f2c40dfbf1603366ecf6309d264c3372ddce260ca97d4cfd7806b00622c06b`; measured body/options/built-in construction preservation remains as established by the earlier static review. This confirms the recorded post-run identity claim at review time.

Opened only the synthetic consistent-ledger backup read-only through Python SQLite: quick_check ok, head revision 2, one shop, 500 lines, 500 contributions and one Paste-source batch. This independently supports the retained ledger readback counts, separate from XCTest metric output. No live simulator or database was accessed and no raw user Records were inspected.

Cleanup receipt records successful shutdown and deletion (both exit 0) of the same owned simulator. I did not issue native commands or inspect/change live processes; root reports all owned native processes terminal. This is receipt-based cleanup verification, not a new independent simulator inventory.

## Warning correction

`build.log` contains **four warning lines**, not only the two initially listed in local-result.json: AppIntents metadata extraction skipped at lines 4527/4945, plus signed Widget and Share extension binaries not stripped at lines 4843/4848. The latter are build notices, not runtime failures. Preserve all four in any summary. Zero runtime warnings is accurate and must not be restated as a warning-free build. Root was notified of this metadata correction during review.

No other blocking discrepancy found in the bounded evidence review. No hosted dispatch, source/Git mutation, build or native rerun occurred; only this runtime-review.md was written.

## Principal evidence hashes
- `local-result.json`: `7da585b296ec0c68419162be1ac43c1c65ab5b7ae944e12cf32fe3256b6758c2`
- `native-invocation.json`: `ffb129cc54fe09f4b93388f56ba80787c29e0e77533e8cca3b55ed719db885d7`
- `native-result.json`: `36bcc271e31019cd773133d749bde1204ba810e9054b8608c84cbec836ca0a84`
- `strict-result.json`: `982b9e9bfb10ffe83cad665807abcfd3fa97b37822db5ab7831157a499548a9e`
- `strict.log`: `f840a0ca750f9dc58ef688210f38c1e605f60fc8791cf74bc939842670763268`
- `test-summary.json`: `602a7bc6cf41fba0ba249e39634152686801b69a636337104d680c78558dba6b`
- `metrics.json`: `7b85ef019959b54793c979d616892895153924d8349105cb81ae217caf231d0d`
- `witness-attachment/manifest.json`: `84d0626e02811bd6d8be96c763284631a702124865a338f1892c4e7f5a0f08f5`
- `witness-attachment/4999183A-C377-4749-B9AF-8EF5B890A504.json`: `722befe152cff2aaaf790f81044597d304a6aac6de5b8a64e77339b185c63244`
- `scroll-signpost-diagnostic.json`: `75fc1c736261f9406f1e6820667f45eb90fb22a0e29fdfce4b8b3eb5958cbed4`
- `correlation.json`: `87e48443a53d92ad6584d8f12938e619a9f0498de6c0ad4edbdb6213f99f2f87`
- `base-source.json`: `a93a416a58958258df8635d8f5649a51732c009dfb340dc7e4dd9392b3deb617`
- `diagnostic-source.json`: `2a373d3fa4b42cd13d67e223e123e4a7f6f94ed2ee27f5070eed8c351998c959`
- `product-manifest.json`: `ec141dfc664955dcc169e3c352de27f0703031e898d8cf51639ae8d1b946bb63`
- `post-run-identity.json`: `5b1ed6783b5057ad1bc40423baa9c49236b8385417820f3fea4f80b6bbac89d4`
- `runtime.json`: `bac2ed51d1e4662fc96feca8cc92a9e8fbd86d0e73d1055481b1a0b79d10b550`
- `ledger-readback.json`: `2aeba3201ca3341556ee6baf818f7fac69557bfb859da3f2280965b5be98e1cd`
- `ledger-consistent-readback.sqlite`: `cfe83ec41aa8ff9afde70fe72de38ce17cbe01cf53a27108ed988ba32de0c014`
- `cleanup.json`: `3e12bf46092eec62e251ae612ff057cbb3c11e86390764d16f977b4f3f1c3bdd`
- `Performance.log`: `cf38baa1cadc8e0b571b46e7efb714e44830839df93a26cced8788ff9d51009e`
- `build.log`: `5df9d1d43a7a2f0ab990751ba182ede397f3900a414be1fb7d823db25a4a3c8c`
