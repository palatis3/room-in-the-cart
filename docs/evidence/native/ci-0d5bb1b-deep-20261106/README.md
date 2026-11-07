# Deep checks passed on the published candidate

[Run 42316648633](https://github.com/palatis3/room-in-the-cart/actions/runs/42316648633), original attempt 1, completed successfully for candidate `0d5bb1b22e9e84cd4b8c2b07317f91cfc703b60c`.

- English and Spanish StoreKit configurations each passed all 15 selected cases, with zero recorded runtime warnings, retries or test-run restarts.
- Address Sanitizer and Thread Sanitizer each passed 389 package cases, with three explicitly declared native-wire skips. The separate native-wire workflow has its own evidence.
- The collector verified all four original ZIP digests, extracted members, native inventories and exact checkout logs. Inspections used copies of the native result bundles.
- Root independently rehashed all 732 frozen files; no mismatch was found. `root-byte-review.json` identifies the freeze; `audit.json` records detailed case, environment and checker results.

This is scoped to this deep workflow and committed source. Other workflows in the combined candidate retain their own running/terminal states. Local follow-up changes after `0d5bb1b`, actual App Store purchases, paid-team signing and full release acceptance are not covered. Earlier failed runs remain retained.
