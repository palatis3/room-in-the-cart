# Pinned compatibility qualification · November 6, 2026

Original candidate `8f864eafc3887ea16be996124d55fa2ca2708706` remains unaccepted. Its two executed keyboard-idle timeouts, missing required scroll measurement and 30 runner-capacity nonexecutions are preserved separately.

One manual qualification was dispatched from `c34a473f2b0d62678da3a6eebb1bcbd2900cbdc6` on a separate diagnostic branch. Exactly four workflow/support files differ from 8f; app code, test bodies, checkers, baselines and ordinary release workflows are unchanged. One build job precedes three parallel fixed invocations: the five-case UI06 history, four-case Spanish history and unwrapped Release scroll case. Original test allowances, count/order/identity checks, warning rules and required measurement samples remain intact.

The target is macOS 26 arm64, Xcode 26.4.1 build 17E202, iPhone 17 and iOS 26.4.1 build 23E254a. Runtime identifiers are discovered only from exact version/build metadata and then retained and checked unchanged. Frozen products are reused, and simulator cleanup outcomes are recorded before evidence upload. Root reran all 12 new guard tests and shell/YAML checks after applying the independently reviewed patch; the proposal's full static validation passes 57 checks. Hosted behavior is not assumed from those local checks.

The new performance environment has no approved baseline. Structural calibration is explicitly nonacceptance and does not change release thresholds. A pass would establish one compatibility observation, not an intermittent-cause fix. KnownTrip is outside this bounded sample and remains open. No automatic retry is configured; no additional acceptance or calibration run is claimed here.

[Dispatch receipt](dispatch.json) · [Live qualification run](https://github.com/palatis3/room-in-the-cart/actions/runs/42259468210)

The first attempt is terminal: the environment booted and all 57 validator tests passed, but `extra[@]: unbound variable` stopped the Debug command before compilation. No native test, measurement or SQLite readback occurred. Cleanup reported success; the retained raw inventory was truncated. [Frozen first-attempt evidence](first-attempt-audit.json). A script compatibility fix is being prepared; no repeat has been requested.

The Bash command-array fix is now published only on diagnostic commit `5376a01227d9ccf2cba53123b7887c83531088de`. [Non-native smoke proof](bash-fix-smoke-proof.json) reproduces the old failure and verifies exact fixed Debug/Release arguments plus failure propagation. Root reran all 15 guards. One [corrected dispatch](corrected-dispatch.json) started run [42261730525](https://github.com/palatis3/room-in-the-cart/actions/runs/42261730525); no test result is claimed yet. This is the first opportunity for native execution after correcting the pre-build harness failure.
