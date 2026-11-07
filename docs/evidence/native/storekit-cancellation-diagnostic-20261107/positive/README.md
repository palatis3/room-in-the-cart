# StoreKit cancellation stage diagnostic: local positive evidence

**Diagnostic-only nonreproduction. The original hosted English timeout remains unresolved; no product fix or release acceptance is established.**

Original candidate `8d1a79b22981148839c6e3d0827c6710f877a369`, deep run `42337977943` attempt 1, English job `128299120073`, artifact `13560692753`: 14 passed, 1 timed out, 0 skipped. Cancellation exceeded the 120-second allowance and XCTest restarted its runner. Original ZIP SHA-256 is `f2d7d89ed4221654e391043fed88249249c36f6e1325c2f39ac6350d67fd432c`. Retained failure details do not identify the suspended await.

The local isolated source snapshot adds only `diagnostic.patch` to the cancellation test. Its English suite ran the same 15 cases in the original order, with the same 120-second limit and serial execution. Build/native exit codes and strict verification are all zero: **15 passed, 0 failed, 0 skipped, 0 recorded runtime warnings**. Cancellation completed in approximately 0.266 seconds. The recorded `strictExit: 0` and complete strict log establish verification completion despite the unavailable process handle.

The payload audit independently verifies all **50 stage attachments** against the exact stderr lines, plus the cancellation summary `historyStates=[2]; current=0; unfinished=0`. All 51 are `keepAlways` plain-text attachments linked to the exact cancellation test. The 50 markers run contiguously from setup through teardown, including purchase preflight and the real purchase boundary. Fifteen payloads used Zstandard storage; bounded decoding retained both stored-member and decoded-text hashes. No other attachment/media was exported.

All 459 source hashes, 167 retained product hashes, and the same 167 executed product hashes match their receipts. The built test file matches the proposed diagnostic. All **173 original positive bundle members** and **78 original hosted bundle members** were hashed before/after this audit and remain unchanged. SQLite metadata was queried read-only from a separate copy of the prior inspection derivative. The original bundles were never passed to a tool by this audit.

## Limits

- Local iOS 26.2/23C54 matches the hosted runtime, but local Xcode 27.1 and iPhone 17 Pro differ from hosted Xcode 26.3 and iPhone 17.
- Instrumentation adds observation work and may change scheduling. A passing instrumented run neither explains nor clears the original failure.
- These payloads prove normal-completion persistence. Timeout/crash persistence requires separate evidence; the root-owned negative control is outside this package.
- No Spanish diagnostic run is included. Original Spanish 15/15 does not clear English.
- Zero recorded runtime warnings is not a warning-free build claim. Build warnings remain in the retained build log.
- Root’s cleanup receipt records successful shutdown and deletion of the owned positive diagnostic simulator only. It does not claim broader device cleanup. No product correction, exact published-candidate pass, or full-V1 release acceptance is claimed.

`audit-result.json` summarizes checks; `attachment-audit.json` binds the 51 payloads; `payload-storage-decoding.json` records storage decoding; `freeze.json` binds this package. Original logs, bundles, and products remain under `.build/StoreKitCancellation20261106/local-diagnostic/`. Source/product manifests and invocation/exit receipts are included without binaries or raw media. `audit-positive.py` records the read-only/scratch audit logic and uses the separately retained decoded inputs under `positive-payload-audit-inputs`.
