# Independent consent diagnostic review

**The original seven-case diagnostic passed, but live capture finalization was incomplete.** The live collector was alive before stop, then its owner exited **-9** and `capture-final.json` was absent. The persisted export exited 0 but contained **zero structural events**, while live output contained **18**. Neither stream establishes exhaustive delivery; absent events remain inconclusive. This pass does not reproduce or explain the earlier hosted consent failure and establishes no app fix or release acceptance.

## Verified execution and preservation

Run **42293938170**, workflow **407500252**, attempt **1**, `workflow_dispatch`, exact head **f019f16124a1edf4d825c2a860efb0c2ca1488cd** and branch `codex/diagnose-consent-history-804030e` were independently checked through authoritative API metadata. Both expected jobs completed successfully. Only `consent-build-evidence-1` and `consent-run-evidence-1` were collected once after terminal completion. The binary artifact was excluded.

Both evidence ZIPs passed the unchanged fixture limits: compressed bytes <150,000,000; members <10,000; total expanded bytes <1,000,000,000; each member <50,000,000; unique normalized relative paths; no links, special files, encryption or traversal. Exact byte counts and API SHA-256 digests match: build **365,883 bytes**, run **43,901,572 bytes**. No bound was relaxed. See each `*-archive-proof.json` for every member hash. No Records artifact or raw Records media was collected.

Original ZIP and extracted member bytes remain preserved under this directory. The original hosted `Tests.xcresult` was copied to `local-replay/Tests.xcresult`, verified byte-for-byte, and only that copy was inspected. Fresh summary/tests exports and the unchanged base-804 strict checker both passed. Original extracted hashes before and after match; hosted original-result hashes also match the raw bundle. The artifact's already-inspected hosted replay bundle remains preserved separately and was not used as the original.

Independent replay confirms **7 passed / 0 failed / 0 skipped**, all seven exact selectors and actual start order, and **zero runtime warnings after seven detailed warning exports**. The runtime is **arm64, iPhone 17, iOS 26.2 / 23C54**, with the exact owned execution UDID. Hosted Xcode is **26.3 / 17C529**. Local recorded-result inspection used Xcode **27.1 / 27A9275**; no local build or native test was run.

The complete compiled contributor plan matches the retained original reference. Source-before/source-after manifests in both jobs equal the independently hashed exact commit tree. Product manifests agree before/after and between jobs; build/run archive-hash receipts agree. Build and run used distinct owned simulators, with successful recorded shutdown/deletion. Because binaries were excluded, product bytes were not independently rehashed locally; this part is agreement among preserved hosted manifests/receipts. Native execution retained the original 720/900 allowances, parallel testing NO, collection `never`, and one seven-selector invocation. Native elapsed time was **989.8 seconds**.

## Positive consent observations

`consent-positive-observations.json` correlates app launches using explicit PIDs in XCTest terminate records, not a guessed timezone. The local Settings test passed in **57.863 seconds** and its three launch PIDs were 43139, 44107 and 45345.

PID **43139**, the first local Settings launch, has the positive sequence:

1. `fixture.ready`: both models ready, both workspaces present and distinct.
2. `binding.enter`: requested true, ready true, workspace present, previous enabled false.
3. `consent.set.enter`: requested true, workspace present, previous enabled false.
4. `consent.set.exit`: requested true, workspace present, enabled true.
5. `binding.exit`: requested true, ready true, workspace present, enabled true, same workspace true.

The observed binding-entry-to-exit monotonic interval is **0.001621 seconds**. This establishes the synchronous setter/write/readback in this passing invocation, not durable storage timing, actual UIKit hit targeting, or a cause for the earlier failure. The test log records the first toggle tap at t=10.48s and the subsequent control read at t=12.46s; the pass preserves the original assertion. PID 44107 positively records the second-workspace enable and subsequent primary-workspace disable; the last launch has its ready marker and the unchanged test's persistence assertions pass.

All 18 parsed events are live-only; six process activations are observed. The original parser output is retained unchanged, and an independent report adds known operation outcomes (`live_status=failed`, `export_status=ok`). Both remain inconclusive. Live timezone is unknown; export UTC is supported by the actual `log show --timezone UTC` command and offset-qualified window. The parser's one malformed scoped line is the live tool's predicate announcement, not a malformed event payload; the original parser result was not weakened or rewritten.

## Capture-stop review and bounded follow-up

The source and receipts support a collector shutdown defect candidate, independently of the consent behavior. `pinned-source/diagnostics/measurement-consent/hosted/harness.py:344` sends TERM, waits 12 seconds, then the fallback at line 346 signals owned processes and **immediately kills the helper** without a second completion window. This can prevent its final receipt. The recorded interval from approximate native completion to export startup is **13.203 seconds**, consistent with that fallback. Live stderr records the stream child's SIGTERM; the owner receipt records -9. These observations do not prove the exact suspended frame.

The recorded interpreter path is CPython 3.15.2. Its upstream macOS timed-wait implementation catches `OSError` around kqueue and falls back; the harness's `InterruptedError` stop exception is an `OSError` subclass and can be consumed there. This is a concrete source-supported explanation for the first TERM not reaching the harness handler, but the hosted installed library bytes were not retained, so it remains an inference. [CPython 3.15.2 subprocess implementation](https://github.com/python/cpython/blob/v3.15.2/Lib/subprocess.py#L2066-L2119)

`stop_owned_capture()` also writes the same `capture-cleanup.json` on every call. Later collect/cleanup observations overwrite the earlier escalation receipt, so the retained `identityMatched=false` values cannot reconstruct that earlier phase.

Proposed follow-up is collector-only: use a private stop exception outside `OSError` (or an explicit owned-child shutdown protocol), retain distinct stop/escalation receipts before each action, and give the owned child/helper a bounded completion window before escalating matching live process groups. First validate with synthetic wait/process objects covering swallowed OSError, clean TERM, delayed exit, escalation, missing final receipt and PID mismatch. Keep native selectors/actions/720/900/40-minute limits unchanged. No patch, new native run, retry, or dispatch was performed or proposed as an immediate action.

Detailed proof: `audit-proof.json`, `consent-positive-observations.json`, `capture-stop-review.json`, `case-order-and-pids.json`, `pinned-source-proof.json`, and `local-replay/`. Root collector session 91398 and its files were not accessed or modified.
