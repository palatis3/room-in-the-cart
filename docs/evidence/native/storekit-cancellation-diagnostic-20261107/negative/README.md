# Cancellation stage diagnostic: timeout survival control

**The diagnostic retained its exact last-entered stage through this artificial local XCTest timeout. The native test intentionally failed; the original hosted cancellation timeout remains unresolved.**

Starting from the compiled positive diagnostic snapshot for base candidate `8d1a79b22981148839c6e3d0827c6710f877a369`, the negative source differs only by one 180-second `Task.sleep` and its identifying comment in the test-only forwarding purchase method. The sleep is after `storefront.purchase.begin` and before the real adapter call. All 459 source entries were compared; no other source or assertion changed. All 167 negative product hashes match the retained manifest. Both default and maximum XCTest allowances remain **120 seconds**, with serial testing enabled.

The corrected execution ran exactly one cancellation case. It timed out at 120 seconds and XCTest restarted its runner once; the restarted runner executed zero additional tests. Native exit was **65**, strict-verifier exit **1**, and `supervisorExpired` was false. The strict verifier correctly rejected the timeout and restart. This is passing validation of an expected failure, never a passing native-test gate.

Exactly **25 contiguous stderr markers** have matching `keepAlways` plain-text attachment payloads linked to the failed cancellation case. The last retained marker is:

```text
StoreKitCancellationTrace seq=25 elapsed=0.818443709 seconds stage=storefront.purchase.begin
```

The still-open scopes are `body`, `model.purchase`, and `storefront.purchase`. Simulation installation and unfinished-transaction preflight completed. No purchase-end, postpurchase, or teardown marker was recorded. Five stored payloads required bounded Zstandard decoding; both stored and decoded hashes are retained. All **93 original result-bundle members** match the preinspection manifest and remained unchanged. No other attachment/media was extracted. Root’s cleanup receipt records successful shutdown and deletion of the owned negative simulator.

## Selection error preserved separately

The supervisor's first invocation selected nonexistent target `RoomInTheCartStoreKitTests`, returned **70**, and recorded no test-case start or stage marker. Its log explicitly reports that the target is not in the test plan/scheme. This was a selection failure, not a test timeout or test outcome. The retained `execution-complete.json` generic `expected` field describes supervisor intent, not the observed cause.

The corrected invocation changed only that selector to `RoomInTheCartTests` and the result-bundle output path. Source, built products, simulator, locale, serial setting, and 120-second limits remained the same. It was the **first actual execution** of the negative test, not a retry of a failing case. Both invocation/result/log sets are included.

## Integration recommendation and limits

Integrate **only the positive diagnostic patch** and explicitly scoped positive/negative evidence. Do not integrate `negative-source-only.patch` or the 180-second sleep. Preserve all timeout/restart rejection rules and the original hosted failure. No further local repetition is needed for this logger-survival check.

The injected sleep precedes the real adapter purchase; it does not reproduce a StoreKit defect or identify the original hosted await. This control establishes marker retention for this local timeout/restart, not arbitrary crashes or all toolchains. Local iOS 26.2/23C54 matches the original runtime, but local Xcode 27.1 differs from hosted Xcode 26.3. The original hosted run `42337977943` / artifact `13560692753` still has an unresolved English timeout. No product correction, exact published-candidate pass, or full-V1 release acceptance follows.

`audit-result.json` records conclusions and input comparisons; `attachment-audit.json` binds all 25 payloads; `original-negative-bundle-sha256.json` binds the original bundle; `freeze.json` binds this package. Original bundles/products remain in the recorded scratch paths. The read-only audit script uses separately retained copied metadata and decoded allowlisted text under `negative-payload-audit-inputs` and performs no native/test/simulator/Git actions.
