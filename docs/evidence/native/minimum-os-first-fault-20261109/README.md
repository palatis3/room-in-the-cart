# Minimum-iOS first-fault capture

The full original Spanish Dinner journey on iPhoneSE3/iOS17.0/21A328 now has a
direct first-fault capture from the corrected-SDK27.1 build. This identifies the
immediate failing callback; it is not a passing minimum-OS qualification.

## Captured failure

The verified app stopped at `EXC_BAD_ACCESS (code=1, address=0x0)` with register
`x0=0` in `_platform_strcmp$VARIANT$Base`. The next frame is
`runtime_issue_os_log_fault_callback` in `XCTAutomationSupport`, UUID
`5E2B971F-94C7-3E45-AA1B-A0354B1D3288`. The stack then includes libtrace's
high-volume logging quarantine and accessibility snapshot children/descendants
query evaluation. It does not establish why the callback received the null value
or prove that an app logger supplied it.

All32 bounded frames, six registers and relevant module UUIDs/slides were saved
in a complete10199-byte capture. PID, UID, start time, installed executable
hash/UUID and the entire installed app bundle were checked against preserved
products. No logging, warning or checker suppression was used.

The debugger confirmed `Detach(False)` succeeded and exited. A subsequent OS
check found that the exact app remained stopped but was no longer traced.
After independent review and identity revalidation, one targeted `SIGCONT`
resumed that remaining stop; the app exited immediately. No signal group, retry,
reattachment or security-setting change was used. This extra cleanup is separately
recorded. Debugger timing and the stopped interval invalidate duration comparisons
and positive acceptance claims for this diagnostic.

The original xcodebuild finalized naturally with native65/strict1: one failed
case,346.338test seconds and352.536wrapper seconds. The result and attachments
were inspected/exported once; source, products and original result remain
unchanged in their retained evidence. No native process or debugger remained at
completion.

## Controller correction and next experiment

First attempt r1 failed before any attachment because the wrapper and embedded
LLDB used different monotonic clock origins. Its uninstrumented native case
failed117.629seconds; that first failure and a root-authored no-attachment recovery
receipt are preserved. R2 transmits an epoch deadline and converts remaining time
to the debugger's own monotonic clock. It also records safe pre-controller
validation failures. All22 offline controller controls and installed import-only
validation pass. LLDB API deadlines remain explicitly cooperative across blocked
SB calls; they are not claimed as enforceable hard wall-clock limits.

The final healthy native query was the review title lookup around119seconds,
not the later line2217 fallback reported after application loss. The local
`assertReviewedText` helper asks for static-text descendants containing a matching
label; it intends to match the static-text element's own label. A separate
one-line `containing` to `matching` candidate rebuilt in16.090seconds but failed
the unchanged uninstrumented full journey:145.596test seconds/native65/strict1.
Xcode finalized naturally752.058seconds, including approximately606seconds outside
the testcase with on-failure diagnostics. Its source/products/original result were
verified unchanged after one inspection/export. The candidate is not installed in
canonical source and is not a repair or speed improvement. No broader query
rewrite or another unchanged run is justified by this result.

## Custody

Source manifest:`bbe56492fa0890d1705b44b8e63f805621eaf5637152735d6ffa0cc971a629fd`.
Product manifest:`780efdedff4d84bfb126d14a412c3e357addc80a16d5baf5206264fc328b372e`.
Before preparing the new query candidate, source/products and executable modes
were cloned and verified under
`.build/NativeQualificationArchivesNov09/bbe56492fa0890d1705b44b8e63f805621eaf5637152735d6ffa0cc971a629fd/sdk27.1-products-780efdedff4d84bf/`.
Old execution paths now contain the successor: do not rerun historical scripts
or describe those paths as still holding the old candidate.

R1 originals/controller archive: `.build/MinimumOSFirstFaultNov09/r1/`.
R2 originals: `.build/MinimumOSFirstFaultNov09/r2/execution/` (local-only).

| R2 original | SHA256 |
| --- | --- |
| `run.json` | `cabf2a344be56bb9f53a34edd27035c970fb5969bc2d2a9422c47a5919ce50ba` |
| `debugger/state.json` | `8b43b3acfeb7ed189c4fc26609733c37d78a53df6be0d2a06b5b07e3b411c201` |
| `debugger/capture.json` | `5ff3dc7a617f36bcdf65edf43e80444ed30524634f8c11ef05893b6cd6a23fe9` |
| `detached-stop-resume.json` | `cf0d468defc27c05ab232c3e1ca585849bfb5bfd3726cb57cc3d5c8428400827` |
| `inspection/verification.json` | `06caef2cf84c87dd838259ff101adcaea3bd2a3b43eb4fe9da8fda1f4e0ddab4` |
| `installed-app.json` | `f34433bc74bea03872579a79d90b5bb4ac68a11d5ad049d4726dc810297f398a` |

The rejected direct-label candidate remains locally in
`.build/MinimumOSDirectLabelNov09/`; current scratch execution paths hold that
candidate and must not be confused with the archived qualified source.

| Candidate original | SHA256 |
| --- | --- |
| `preparation.json` | `ed4ff8024096ff879037dd61178757f3e95358f7c4ec68a9f9e5f5d999e801cc` |
| `source.json` | `83cb0b28776cd26cc0d6458600d76647f0abd9ba90bce391f77f38db257ac32e` |
| `build/products.json` | `a666b70e53e9a97fdbfaa75000143a0818badf8e5e4fe71b40389ea6b95e932f` |
| `spanish/run.json` | `1277d0d4392a43a822cb8409470e1385212b046bdd537be1bfcb15eb5c30f516` |
| `spanish/inspection/verification.json` | `c5895008b4d841dea3cbcc73c46e893297e19ff41d82096ba9cd3e34977a99da` |

## Saved-image follow-up without another journey

A bounded 64-instruction inspection of the separately identified iOS 17.5 image
(UUID `417562C6-9B3A-3531-9650-5AF0B2667075`) matches both retained 17.5 crash
return addresses. The callback guards its record pointer, then loads the compared
string from record offset 16 and calls `strcmp` without guarding that field.
The input producer, field contract and reason for null remain unknown. This is
not an equivalence claim for the different iOS 17.0 image above or a product fix.
No app, test, live-process attachment or further log collection ran. Root verified
the retained hashes and relevant instructions against the unchanged image.

Originals: `.build/MinimumOSXCTestReproducerNov09/static-callback-provenance-r1/`.
Manifest SHA256 `ecf144228f921ea0787eb4b3c5ceb41c251bd353d8e40a7450d270a5fdd1d4e4`;
receipt SHA256 `fc95a756fecac6c184faf2159299bf59ab4872b124b3a3c1832d546306486592`.
The command completed in 0.012 seconds with 3,513 output bytes.
