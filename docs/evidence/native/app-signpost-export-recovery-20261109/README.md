# App signpost collection and export recovery

This is a local diagnostic of a historical Release snapshot with compile-gated
observation hooks. It does not qualify the combined candidate, resolve the hosted
missing-duration cause or approve the Xcode 27.1 performance baseline.

The final collection attempt reused the verified build. Its original scrolling
XCTest completed 1/1 in 117.328 seconds; the app recorded six observer invocations.
XCTest and the 60-second trace recorder both exited normally with no signals.
The native log contains five duration samples and three memory series. Observer
invocations are not substituted for XCTest measurement samples.

The original receipt remains **unqualified**: exporting the signpost table exceeded
the separate 8 MiB XML limit. The retained partial export contains 24,553 complete
rows through 19.941 seconds of a 60.591-second recording. That gives an approximate
26.4 MB full-export estimate, supporting a bounded 64 MiB / 30-second export-only
continuation. This changes collection tooling limits, not test assertions.

Root independently confirmed every bound process was terminal and all 216 capture
files (44,020,880 bytes) were stable across five seconds. A fresh verified trace
copy can be exported while preserving the original receipt, failed export and
process history. Strict XCTest, fixture and measurement checks remain independent
of transport; final diagnostic qualification requires them all.

## Recovery results

Root verified the frozen 24-file continuation package and independently passed all
41 offline controls. The single new export completed normally in 3.883 seconds,
producing 13,921,452 bytes. Transport validation finds all six exact observer
envelopes, each containing its named UIKit scroll interval. These are coverage
envelopes, not XCTest sample indexes or measurement boundaries.

Original strict XCTest, runtime-warning and runner-acknowledgement checks pass.
The first result inspector then failed before performance evaluation because its
`performance.log` output collided with retained `Performance.log` on the Mac's
case-insensitive filesystem. That failed inspection remains unchanged. The missing
original performance check ran once against verified copies of the already saved
summary, metrics, toolchain receipt and SQLite fixture, using
`performance-checker.log`. It completed in 0.085 seconds with all copied inputs and
the original inspection unchanged. No result re-export or app rerun was needed.

The original checker verifies five scroll-duration samples (median 2.583362583
seconds), three memory series, and the saved fixture: 500 lines, 500 contributions,
zero checkoffs, revision 3. Animation-hitch samples remain unavailable. This result
is diagnostic only and cannot approve a performance baseline or establish the
cause of the hosted omission. Original failed capture and inspection receipts are
preserved alongside the succeeding export and metric-check receipts.

The read-only combined verifier passes all required gates. Root verified its
seven-file package and all eight focused controls, including the case-insensitive
filename regression. [verification.json](verification.json) records the combined
diagnostic qualification and hashes of every retained receipt. Release acceptance
remains false.

## Retained inputs

All paths below are relative to `.build/AppSignpostCaptureNov09/`:

| Input | SHA-256 |
| --- | --- |
| `root-execution-r4/source.json` | `5f156dc80b241c5914b7b9c098e6d44074700dc61e3540d70a710f1b00992bd3` |
| `root-execution-r3/build/products.json` | `d23656755a0c7f3d9ebdf19110b29b472f1e76705ddcdb8777dbd727afa6782b` |
| `root-execution-r4/capture/attempt/receipt.json` | `4e5c7a5f7ba6eb683ee1c1f74365ab6ae0a8968c5d38d9258eda91fc20388c7a` |
| `root-execution-r4/capture-root-audit.json` | `3cc403860349a4f615cd53f1089120019975347cedf3c200ce5603c4a3a68573` |

Earlier attempts remain separate: the first build lacked the public `notify`
import; exact helper probes subsequently passed for arm64 and x86_64. The next
collection exceeded its aggregate trace cap and was stopped, so it remains invalid.
The successful normal collection used the same finished products with a measured,
bounded aggregate allowance. Raw traces, TOC host metadata and result bundles stay
local; only compact receipts and hashes belong in the public repository.
