# Corrected-SDK minimum iOS and post-setup performance observations

Both first attempts are terminal failures at candidate
`79ea8c03c21f900d7eaa4db0ed2b92014404ac96`. Neither is merge or release acceptance.
Original results remain retained; no unchanged rerun was dispatched.

## Minimum iOS

The full original Spanish Dinner selector ran on owned iPhoneSE3/iOS17.0/21A328,
Spanish es_US, light/Large, serially with unchanged720/900second test limits.
It used the corrected SDK27.1 products and561-input source from the
[source-removal qualification](../source-removal-journey-20261109/README.md).
Diagnostics were on-failure; earlier minimum-OS investigations used never.

The testcase failed after197.227seconds: XCTest could no longer obtain an app
snapshot after entering the supply source. Native exit65/strict1; the entire
xcodebuild finished naturally after836.511seconds including diagnostics. Source,
products and original result are unchanged. No timeout/restart was used.

Two retained SpringBoard events explicitly report appPID67561 exited with
SIGSEGV11 at12:53:28.964UTC. The bounded log query retained its getpwuid_r warning;
these positive events are diagnostic evidence, not a successful test result.
Separate host ReportCrash events show interrupted reporting connections, missing
post-report data and no saved app report. They do not prove the reporter crashed.
The result's968diagnostic files/300MB contain no fresh matching app crash report;
the relevant app/test output contains no recovered exception stack. The app output
includes110MB of accessibility diagnostics. Its volume alone does not prove cause.

The SDK correction alone did not make the journey pass. The previous XCTest
logging-callback mechanism is not established for this fault without a stack.
Next discriminating action: bounded, exact-PID LLDB capture of the first fatal
signal or Darwin exception on the same full journey. Debugger timing/exception
handling makes that diagnostic-only, never positive minimum-OS acceptance.
Do not disable activity logging, alter assertions or attach by ambiguous name.
The plan is prepared, not executed; no OS security setting was changed.

Originals: `.build/MinimumOSCorrectSDKNov09/r1/` (local-only).

| File | SHA256 |
| --- | --- |
| `run.json` | `a76fa81e75946ac3beb5d2223b178617e7d5ddd709c36730c6050d832c41336e` |
| `inspection/verification.json` | `586ceb6e304285c69ba029a586888cc3dd6d14a16900cefcf67f82c7a3c94c60` |
| `inspection/diagnostics-manifest.json` | `fdb638a11905a5cc219455f3b125d6fbcd3a79b71b53fa70e718e1d3b3233db6` |
| `crash-review/termination-positive-summary.json` | `8602977415d613825cbfd63933daa7532af44c656a9e2ed4e836b540f00c6205` |
| `crash-review/reporting-interruption-summary.json` | `bcfce1288ba0ed95aa4e58f899a9a9bc8c77b8ffad1c9f89bb12cab8efc9efaf` |

## Hosted performance

[Run42620394385](https://github.com/palatis3/room-in-the-cart/actions/runs/42620394385),
attempt1, completed at13:10:43UTC. The original scroll XCTest passed1/1 in
115.850seconds. Strict evidence step14 failed: three memory series each contain
five samples, but required Scroll_DraggingAndDeceleration.duration is absent.
The500-row store, runtime24A434 identity, preservation and owned cleanup pass.

Producer provenance found the declared checker library readable (338880bytes,
SHA2561ab99e516a208f4ce91fcde55af17ee83a4aedfc9687ec1eeade456943ea32e8).
The reference remained missing on the consumer both before and after actual
simulator setup immediately before XCTest. The two consumer receipts are
byte-identical, SHA256ac5ff8d261870ad9c2e0d00ecba4c8413400027775b62ad19dfe5db775d31c56.
Plan/product/protected-source binding passed. This resolves the earlier timing
uncertainty; it does not establish which libraries loaded or why metrics are absent.

The hosted build log has no SDK/sysroot warning; observed SDK arguments use27.1.
Package targets link relocatable objects, unlike the local dynamic-framework
case. Final hosted Mach-O SDK metadata is unobserved. Do not transpose the local
SDK finding into a hosted causal claim. No plan rebinding, checker disabling,
metric relaxation or new baseline approval occurred.

Sol6.1 retained two digest-verified small ZIPs and compact reports under
`.build/HostedPerformanceAfterSetupNov09/monitor/`; the91MB product archive was
not downloaded. Originals are local-only, not independently archived remotely.
The next investigation must distinguish declared configuration from effective
runtime loading or verify the consumer runtime's equivalent library before any
reviewed plan change; another unchanged run adds no evidence.

| File | SHA256 |
| --- | --- |
| `terminal-scroll-report.json` | `41c2d0a9fc474e500ed3fead401486ea02a751c3a922d15db3413e34b67bf42d` |
| `retained-artifact-proof.json` | `4defdc41f3dacf04b0c454b254519e416198460e4a9cd107672b5c5b20058cfa` |
