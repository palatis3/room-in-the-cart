# Reduce Motion share readiness on 08309eb

On November 7, 2026, the iPhone 17 simulator on iOS 26.2 (23C54) failed to show an actionable system share Close control during the 15-second readiness check. The hosted shard passed its other five cases. A fresh local simulator of the same model and runtime passed the original Reduce Motion case with the downloaded products in 152.04 seconds. The local run executed the case alone. In CI it followed `testAuthorizationHoldIsOptionalAndSeparateFromCheckoutCap`. The source was `08309eb7f622436e2e369198135717edf6dab62c`. [GitHub Core ui-07, attempt 1](https://github.com/palatis3/room-in-the-cart/actions/runs/42366985966/job/128401513671)

## What XCTest observed

Times below are from the test runner on November 7. Controller rows show receipt of an accessibility `ViewDidAppear` notification. Screenshot rows show when XCTest added the attachment.

| Event | Hosted (UTC) | Local (UTC−05) |
| --- | --- | --- |
| Began tapping Share dated list | 12:38:58.472 | 08:06:04.544 |
| Entered Close readiness wait | 12:39:00.696 | 08:06:05.211 |
| App-side UIActivityViewController appeared | 12:39:01.651 | 08:06:06.144 |
| App-side SHSheetRemoteSceneViewController appeared | 12:39:01.651 | 08:06:06.145 |
| Separate process reported UIActivityContentViewController appeared | 12:39:22.331 | 08:06:06.145 |
| Waiter returned | 12:39:15.962, timed out | 08:06:06.887, completed |
| Failed-boundary screenshot added | 12:39:16.240 | — |
| Pre-restoration screenshot added | 12:39:20.289 | — |
| Began reopening Settings during teardown | 12:39:20.293 | — |
| Began tapping header.closeButton | — | 08:06:06.889 |

The app-side and remote controller notifications arrived **20.680 seconds apart** in CI and **0.001 seconds apart** locally. The hosted remote notification arrived **6.369 seconds after the timeout**, while teardown was opening Settings. The first recorded accessibility status notification for that remote PID (20680) was at 12:39:18.454. The hosted readiness attachment reports Reduce Motion enabled and an observed 15.336598-second wait. Both original screenshot payloads are byte-identical and visibly show a dimmed frozen handoff without a panel or Close. The failed hierarchy includes `ActivityListView` and `ShareSheet.RemoteContainerView` without actionable children.

The hosted run reached the app's presentation code. The evidence narrows the observed delay to presentation or observation of the system share content. Notification receipt does not establish exact screen draw time, service startup time, or why presentation was slow. Locally, the real Close action and the following assertions ran, including cancellation history, the exact frozen snapshot, and unconfirmed placement after relaunch. The hosted case stopped before Close.

A focused next diagnostic would preserve the original ui-07 prefix and readiness gate and capture simulator unified logs for the share UI process and scene activation between the tap and teardown. Correlate their timestamps with the runner's app-side and remote notifications. The current bundle retains app and XCTest logs but lacks an independent system-service trace for that interval. The observed delay does not establish a product or selector fix.

## Reproduce the comparison

The hosted result came from artifact `13574996550` (`iphone-results-ui-07-1`). GitHub lists its ZIP SHA-256 as `1c7509c2384ffeed16a1832cd50a252e719414550c9f44581be492105d4e5eee`. The product artifact was `13573065556` (`iphone-test-products-1`), with GitHub ZIP SHA-256 `21487582c2cd90b291a2c0d55c766f294233eb2e620c3b0cc6795f814caebfad`. The extracted product tarball SHA-256 is `c0bdf5ab70dd929b54b3987bb6a241705db45c7ddca08856d455963effe18ca3`. All 242 regular product files, excluding AppleDouble metadata, match the local extracted copies byte for byte. The local xcodebuild invocation in `cold-share.log` references this extracted xctestrun with `test-without-building`.

From the repository root, export the retained results and inspect the surrounding timestamped runner lines. The same hosted bundle is available inside the result artifact.

```sh
evidence=.build/SharedIngredientReview20261107
review=$(mktemp -d)
xcrun xcresulttool export diagnostics --path "$evidence/hosted-ui07/Tests.xcresult" --output-path "$review/hosted"
xcrun xcresulttool export diagnostics --path "$evidence/cold-share.xcresult" --output-path "$review/local"
rg -n -B1 -A1 'controllerClass = (UIActivityViewController|SHSheetRemoteSceneViewController|UIActivityContentViewController);' "$review" -g 'Session-*.log'
rg -n 'started activity.*Tap "(Share dated list|header.closeButton)"|entering wait loop for 15.00s with expectations: .*exists == 1 AND hittable == 1|Returning result .*0x600000(d42e80|d58960)|started activity.*(Share-readiness-failed-before-debug-hierarchy|Reduce-Motion-failure-before-settings-restoration|Open com.apple.Preferences)' "$review" -g 'Session-*.log'
```

| Evidence | SHA-256 |
| --- | --- |
| Hosted Session-RoomInTheCartUITests-2026-11-07_123211-9fGyVh.log | `d6a00a5b922b1a2e03fa3f16b5db36dc4fea389ab2fa937a001d2fd8ace6cc43` |
| Local Session-RoomInTheCartUITests-2026-11-07_080349-ib7wlV.log | `a69657c59140f20745d3a1fd7800ce6562a748b86358713525444b0d827eaf24` |
| Both original PNGs (Share-readiness-failed-before-debug-hierarchy and Reduce-Motion-failure-before-settings-restoration) | `e06d4924a6407817afa1c74b3453c75199f65b40c95af60a5711fa5c8d5d9a25` |
| Share-readiness-failed-boundary attachment | `4d73d1d6976b883af3156a51ce18c22126b081211220766631512b1248626c88` |
