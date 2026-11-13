# UI04 initial quantity focus remains unresolved

Published candidate `0d5bb1b` failed `testLargestTextEditActionGrowsInContentAndReturnsToEntry` during **initial Pack B quantity entry**, before reaching the Edit assertions. UI04's other five tests passed. The original case duration is 96.172 seconds, with zero recorded runtime warnings and no test-run restart.

The retained native event requests one tap at `(201,521)`; the later failure hierarchy places the single B-quantity field at `(32,489,338,64)`. The failure screenshot and selected video frames show the field and no keyboard. This supports a missed-focus symptom, not a causal conclusion about the pre-touch layout or SwiftUI focus state. No busy-loop, wrong-field, obscured-field or Edit-action cause is established. XCTest's own event retries are distinct from rerunning a failed case.

Root then ran the **unchanged hosted app and test products** on a fresh local iPhone17 simulator with the same iOS26.2/23C54 runtime. The single original selector passed in144.06s, strict0, zero recorded warnings/restarts. All254 extracted product file hashes, including the original xctestrun, were unchanged afterward. Product ZIP artifact13550818501 has SHA256 `aa55ff443249a3e4e3731ec64a5e566db92fc108c22757d32ef96897dc248594`.

The local coordinator was Xcode27.1/27A9275, whereas the hosted build and coordinator were Xcode26.3/17C529. This local nonreproduction therefore does not replace the hosted failure or establish a fix. App/test source, timeout and warning policy were not changed for this control. The main checkout's later changes were not used.

`hosted-failure-proof.json` identifies the original job, archive and source chronology. `control-*` record the isolated invocation and strict results. `product-extraction.json`, `product-after-run.json` and `root-review.json` bind the binary and evidence hashes. Original ZIPs remain untouched; native exports used inspection copies. Only the failed comparison case's synthetic media was viewed. The next diagnostic, if required, should observe field geometry and public keyboard/Done state around the unchanged tap before introducing a focus workaround.
