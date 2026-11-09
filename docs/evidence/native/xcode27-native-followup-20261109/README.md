# Xcode 27.1 native follow-up — November 9

## Installed fixture corrections

Five declaration changes are installed from the independently reviewed, tested
candidate. Four URLProtocol subclasses no longer assert an unavailable whole-object
`Sendable` conformance. The private media fixture is now `Encodable`, matching
its encoding-only use; production decoding and encoded version fields are unchanged.
No request handling, callbacks, assertions or synchronization were removed.

Xcode 27.1/27A9275 Debug build and app-bundle validation passed in 211.313 seconds.
All five targeted warnings are absent, with no new compiler errors. Six remaining
warning lines originate from package SDK selection and an imported StoreKitTest
header; this is not a claim of a warning-free toolchain.

All 55 existing selected regressions passed native and strict validation on the
owned iPhone 17 Pro iOS 26.2 simulator:20 request-pack, 6 meal-context, 4 membership HTTP,
12 restoration, 4 stock-privacy and 9 media cases. Selection includes delayed-response
and corrupt/version/recovery cases. Exact selector coverage was verified, rather
than inferring success from the native process exit. The original result and
source are unchanged. Canonical installation matches all 561 candidate product
inputs; the declaration changes are the only five differences from R4.

This repairs declarations, not all fixture concurrency. Unlocked static registries
and some mutable vault/server state remain documented in the private source review.
A follow-up must test overlapping fixture lifetimes and preserve deliberately held
responses; adding a lock around only a pointer is not sufficient. Full combined
CI, minimum-iOS and release acceptance are still open.

## Minimum-iOS investigation — not installed

Bounded symbol attribution resolved all 44 retained callsites against the exact
iOS 17.5 XCTAutomationSupport UUID. Dominant records originate in accessibility
attribute fetches and element-type reads. This does not uniquely attribute them
to our helpers or establish the underlying callback defect.

A separately frozen candidate cached element types and avoided irrelevant frame
reads in two existing scroll-helper loops. Review found no semantic change to
assertions, geometry, traversal exclusions or limits. It compiled and passed bundle
checks, but the one original Spanish Dinner journey failed native 65/strict 1 after
advancing into supply Done. Command duration 186.108 seconds; no idle-miss messages.
All source/products and original result bytes were preserved.

The new app IPS is bound to PID 97258, 07:58:24.2331Z and exact compiled/installed
image identities. Its first 13 faulting frames exactly match the prior callback/
quarantine crash. The later failure point does not establish a fix or measured
performance improvement. The helper change remains scratch-only. No unchanged
rerun, warning suppression or deployment-floor change was made.

## Retained evidence

- `.build/Xcode27WarningReviewNov09/execution-r1/source.json` — SHA256 `bf2df6f24c150ec2d8d4e53e69ba7a0a97349a4714ca03b93ec6a92c4490fd30`.
- `.build/Xcode27WarningReviewNov09/execution-r1/build-warning-review.json` — SHA256 `a245e16fe8e0267b24d5ae8454cc5097b4e09d6a6a14ab2b916d06398f88805d`.
- `.build/Xcode27WarningReviewNov09/execution-r1/fixture-regression/run.json` — SHA256 `82936a4a3f4f558a76d09aec3bb55bf3f45b1a6d6e965bba465bd2d1b41682d4`.
- `.build/Xcode27WarningReviewNov09/execution-r1/fixture-regression/inspection/verification.json` — SHA256 `749238a711411d3a66893082490b65c45c529cbc99a4ae0e75c57ef1e050dfaa`.
- `.build/Xcode27WarningReviewNov09/execution-r1/installation.json` — SHA256 `6ef9fecd42d27fd6ffa606eb01533d645f2e45670de5917c59dfb5de1620fb9a`.
- `.build/DinnerSnapshotTraversalNov09/r1/plan.json` — SHA256 `57212f5c334d21c0fd4c68e6f755c741c8d7882f78e8b8931175a7efd8ef5895`.
- `.build/DinnerSnapshotTraversalNov09/r1/spanish-ios17_5/inspection/verification.json` — SHA256 `d0e074906fd88f6489715d89a1091856b3d7f824c5048bba779a949e9608ad48`.
- `.build/DinnerSnapshotTraversalNov09/r1/spanish-ios17_5/crash-review/manifest.json` — SHA256 `5b09e5c6fc096ce283ea0d93749a787f9d30973945b6bf239dc7e679d12cbb11`.
- `.build/MinimumOSXCTestReproducerNov09/r3/execution/original-pid-retained-logs/symbol-review/manifest.json` — SHA256 `516743f94ff68a4954125948dc340bdffa387c224a1213a6531f44bed04d2958`.
