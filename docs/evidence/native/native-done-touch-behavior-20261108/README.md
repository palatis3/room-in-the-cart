# Direct Done touch behavior — center passes, top sample fails

The unchanged R3 app was tested without the observer. The test substitutes actual
coordinate behavior for the unsupported assumption that the accessibility frame
is the entire touch area. It preserves original typing, unknown-quantity rejection,
explicit review/approval, value persistence and relaunch assertions. No test point
was moved after observing a failure.

Build and built-app checks passed (45.299 seconds). The original English journey
failed after147.306 seconds: native65/strict1, zero animation-idle misses. Original
results, source and prior source/products remain unchanged and verified.

The first cleared Amount interaction tapped the center (348,84). Keyboard and Done
disappeared, the editor remained, and the exact whitespace quantity survived.
The journey continued through unknown-quantity review and disabled acceptance.
[Before](center-before.png) · [After](center-after.png) · [Target](center-target.txt) ·
[Successful interaction](center-result.txt).

After restoring Amount to4, the test tapped (348,62), the top midpoint of its
planned centered44×44 region (326,62,44,44). That region fit inside the navigation
bar and did not intersect Back. The keyboard remained after the original5-second
wait, failing at FreeJourneyUITests.swift:1977. [Before](top-before.png) ·
[Exact target](top-target.txt). Supply, final approval and relaunch were not reached.
The retained screenshot is before this failed tap; the native assertion/log proves
the subsequent keyboard persistence, not an exported after screenshot.

Root reviewed all three screenshots and three geometry records. The visible Done
AX frame remains(314,66,68,36). This result establishes failed behavior at the
selected top coordinate; it does not map every possible hit region, identify which
view consumed that tap, or prove that no differently positioned44-point region
exists. It is not physical accessibility or full journey acceptance.

Next: review native toolbar styling/control construction against the actual target
behavior. Keep this test unchanged for any app candidate. Do not retry an unchanged
candidate, inflate the accessibility frame, or move the point to obtain a pass.

Private package: `.build/EnglishKeyboardReviewNov08/native-done-touch-execution-r1`.
Preparation5682, build27809/PID73222, test61472/PID73556 and inspection55172 are
terminal. Inspection is complete; do not repeat it. Reused source/DD now hold this
candidate; the previous observer source/products are in this package's preservation
folder. Canonical app source is unchanged. [Verification](verification.json).
