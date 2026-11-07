# UI04 public quantity-focus diagnostic

This folder contains compact receipts copied from `.build/UI04FocusDiagnostic20261106/`. References below to the scratch root and the freeze's relative paths refer to that original directory, where result bundles and logs remain.

Prepared and validated an isolated diagnostic overlay against exact published candidate `0d5bb1b22e9e84cd4b8c2b07317f91cfc703b60c`. Only `ios/UITests/RoomInTheCartUITests.swift` changes. The shipping implementation is unchanged, and the overlay is not installed in the main checkout or dispatched to GitHub.

The first build failed before any test started because the local SDK rejected `NSStringFromCGRect`. The retained build1 source/patch/log/result identify that failure. Revision 2 uses `String(describing:)` and clarifies that JSON omits field text/values while two screenshots retain synthetic form contents. Its first executed case passed: `testLargestTextEditActionGrowsInContentAndReturnsToEntry`, 151.23 seconds (rounded), strict exit 0, zero recorded warnings and no test restart. All 457 archived source-file hashes remain unchanged during that execution.

The original field-entry order, scroll helper, one native B-quantity tap, typing, Done checks, saved values and later Edit/result assertions remain. Observations surround A-price Done and the B-quantity tap. Four JSON attachments record public geometry, match counts and keyboard/Done presence; only the two named B screenshots were exported/viewed. No record/recovery media was inspected.

In this local pass, A-price Done changes keyboard/Done counts from 1/1 to 0/0. Before B tap, one enabled/hittable field is at `(32,532,338,64)`, below navigation and above tabs, with no keyboard/Done. After that single tap, the field is at approximately `(32,437.67,338,65)` and keyboard/Done counts are 1/1. Both screenshot states agree with these public observations, and subsequent typed-value and full-case assertions pass.

These are sequential observations taking 1.6–3.1 seconds per sample plus screenshot overhead; they can alter timing. They are not atomic first-responder observations. Local compiler/coordinator Xcode 27.1 / 27A9275 differs from the original hosted Xcode 26.3 / 17C529, although the fresh iPhone 17 runtime is the same iOS 26.2 / 23C54. This validates the capture mechanism and records a passing transition; it does not reproduce or resolve the original hosted failure. No workaround, re-tap, timeout increase or weakened assertion was introduced.

Original results, failed build and logs remain under this scratch root. Strict replay/export used a separate inspection copy. Owned simulator 665DA3F2-A776-4E58-9FF2-66ED9269A35F was shut down and deleted; the user's preview was untouched. No local native process remains running.

Next: finish the original combined cohort. Use this prepared overlay only if the still-unresolved hosted focus failure requires a targeted same-toolchain observation; do not treat repeated local passes as a causal fix or supersede the active cohort to obtain them.
