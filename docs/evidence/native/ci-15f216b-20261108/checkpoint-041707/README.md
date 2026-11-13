# Hosted candidate checkpoint — November 8, 04:17:07 UTC

Four of six workflows for `15f216b01e41c111ec99bbd812419cec32e6a5e4` remain terminal success. Core and fixtures are still executing. Core now has two observed failed jobs: the earlier Chromium startup failure and UI05. No run has been cancelled, dispatched or repeated. [Exact snapshot](checkpoint.json)

UI05 executed all six cases: five passed, one failed, with zero skips, recorded runtime warnings or runner restarts. `PickupOfferUITests.testSavedOfferReopensAndUpdatesResponseAfterRestart` read `Ma` immediately after one `typeText("Main branch")`, before saving or restarting. The preceding confirmed-stock journey passed. [Original verification](ui-05.json) · [Serial boundary](ui-05-failure-boundary.log)

The original teardown screenshot subsequently shows the complete `Main branch` value. No intervening typing or other input appears in the serial log. This supports an asynchronous readback boundary; it does not establish persisted truncation or a product correction. A bounded exact-value readiness assertion is under review. The original failure remains unresolved until the reviewed correction is executed and confirmed on the relevant hosted toolchain. [Later screenshot](ui-05-later-readback.png)

UI08 passed seven cases. Contributor groups 01 and 05 passed three and fourteen cases respectively. All three strict receipts record zero skips, runtime warnings or runner restarts. [UI08](ui-08.json) · [Contributor 01](contributor-balanced-01.json) · [Contributor 05](contributor-balanced-05.json)

The passing [04:03 performance and UI checkpoint](../checkpoint-040352/README.md) remains valid in its scope. Neither checkpoint establishes a combined green candidate or App Store readiness.
