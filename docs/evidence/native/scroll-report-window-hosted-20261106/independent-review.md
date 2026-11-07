# Independent hosted scroll-witness preparation review

**No blocking static defect found for the proposed bounded diagnostic.** This is not hosted Xcode 26.3 qualification, proof of a performance fix, or release acceptance. The branch was still based at exact `0d5bb1b22e9e84cd4b8c2b07317f91cfc703b60c` with three uncommitted modified files when reviewed. Bind the eventual diagnostic commit to the reviewed bytes before the single intended dispatch.

## Exact source binding

Branch: `codex/scroll-report-window-20261106`. Working-tree diff against 0d5 contains exactly the following paths, with no untracked source files. Each candidate file is byte-identical to the retained local qualification copy or its reviewed endpoint-parser copy.

| Changed file | Candidate SHA256 |
|---|---|
| `ios/UITests/ReleasePerformanceUITests.swift` | `d1f2c40dfbf1603366ecf6309d264c3372ddce260ca97d4cfd7806b00622c06b` |
| `scripts/scroll_signpost_diagnostic.py` | `be4a3f473c7e5dc6bc952df4c82e350a8ad58c4c2fb8721e71efabfa441f7de9` |
| `scripts/test_scroll_signpost_diagnostic.py` | `a3b94cec9424acfed37a1e102c5f79ef240d984154ecc80ee31e6dbd78942c4c` |

The complete reviewed diff is `reviewed.patch`, SHA256 `cd2e3fc0687122fbc06d9cdf8efcca279b18f17c29986467780fc7a6fcc174d3`. `source-binding.json` retains base/candidate identities, qualification paths and protected-file hashes; SHA256 `573b500b41dabf1259cb95f63bb6ae818c0cd008c9a483078a9fe3ba939b4796`.

All other tracked files remain 0d5 bytes. Independently checked 18 protected files, including all eight workflows, the 500-row fixture, baseline, strict XCTest/performance validators, setup/runtime selector, all three planners and slot helper. The main checkout's subsequent CodeQL slot rebalance and application fixes are not part of this diagnostic branch. The three standalone recorder/metric/patch files in `diagnostics/scroll-report-window` also match the qualified scratch copies. Relevant source and corrected-result entries were rehashed against the local qualification freeze.

## Measurement and diagnostic behavior

The complete existing `measure` block and `measurementOptions()` are byte-identical to 0d5. Reset, swipe velocity/order, startMeasuring/stopMeasuring, assertions, iteration count and built-in scroll/memory/hitch construction/order remain unchanged. The standalone witness is appended after those metrics; it neither wraps/delegates to a built-in metric nor supplies a fabricated metric/sample. Its copies have fresh ordinals and share the bounded per-test recorder. Callback retention is scalar-only, locked, capped at 128 with explicit omissions; JSON serialization and attachment happen after measurement returns.

The schema 2 parser is exactly the previously reviewed copy. It retains bounded, scoped endpoint fields plus numeric UTC origin and relative activity-window offsets; no raw PID/signpost identifier or unrelated log line is emitted. It preserves incomplete/ambiguous/truncated outcomes rather than selecting replacement pairs. Existing metric and persisted-pickup acceptance remain independent.

Instrumentation can perturb timing or framework collection. Callback clocks are sampled after lock acquisition, not exact concurrent callback-entry timestamps. The supplied report bounds belong to this custom witness and do not establish the built-in collector's private boundaries or event delivery. Do not infer a warm-up/report ordinal, discard a callback to force five samples, or replace the required duration series with endpoint pairs. Framework failure or absent attachment makes the diagnostic unavailable; it is not reproduction of an otherwise passing native test's missing-series condition.

Local retained qualification is **Xcode 27.1/27A9275, iOS 26.2/23C54**: corrected receipt reports 1/1 native/strict pass, zero runtime warnings, five built-in duration samples, and six witness reports. It is instrumented nonreproduction on a different Xcode, not hosted26.3 compatibility. The corrected record retains four build notices. Root reports 16 parser and 10 performance-validator tests passing; the retained parser log independently shows 16 passing tests. This reviewer inspected records/source binding and did not rerun unit/native tests or build/typecheck anything.

## Trigger and evidence scope

- A plain push to this non-main branch without a PR is not matched by the retained workflows' push triggers. Opening a PR would broaden the trigger scope; the proposed no-PR path avoids that.
- One manual `ios-performance.yml` invocation selects **one build plus all three original performance case jobs**, not a scroll-only execution. The compiled-inventory guard remains in place.
- `workflow_dispatch.enforce_baselines` defaults to **false**. The root's planned explicit **true** is necessary; the consumer jobs then pass the unchanged baseline to the unchanged checker.
- The original Xcode 26.3 selection, strict runtime checks, limits, shared five-slot groups, per-case selectors and no-retry behavior are unchanged. Workflow-level concurrency is scoped by workflow/ref; leaf groups remain shared. Repeating a dispatch on the same ref could supersede its previous workflow under the existing policy, so this review concerns the single proposed invocation only.
- Existing `always()` exports/upload retain available original result, metrics, attachments and diagnostic receipt after failure. Filtered raw signpost/activity inputs remain temporary and are removed by the existing trap. The unchanged workflow's diagnostic fallback is schema 1 `capture_incomplete`/`collector_error`; collectors must classify that as unavailable, not a valid schema 2 receipt.
- Correlation is not added to hosted acceptance by this patch. After collection, bind witness and endpoint receipts to the same immutable commit, built product, original result, selector and device before using the separately reviewed offline correlator. Inspect only copies and retain omissions/clock uncertainty. A missing witness or schema 2 receipt must not be reported as a successful diagnostic merely because the native metric gate passes.

Only this scratch review, source-binding receipt and reviewed patch were written. No source/Git/hosted mutation, native execution, retry, dispatch or collector operation was performed. Original 0d5 failures and frozen evidence remain unchanged.
