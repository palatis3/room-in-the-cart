# Native Done touch observation — inconclusive identity

The diagnostic app and built-app checks passed. The original English dinner
journey failed at the unchanged 44-point accessibility-frame assertion before
its first Done tap (38.200-second native case; native exit 65, strict exit 1).
No animation-idle misses were observed. This is not a keyboard repair or journey
pass. The original source/products/results remain preserved and verified.

The one-shot public UIKit observer produced a 1,686-byte report bound to the
run UUID, exact source, original case interval, app PID 71364, and matching
installed launcher/debug-dylib identities. It found one semantic Done view among
320 views, but could not bind it to an enabled public UIControl under its strict
identity rules. It returned `unknown` in 0.869 ms before sampling any points.
Do not interpret this as a small target, no target, or successful touch coverage.

Root reviewed the [before screenshot](before-done.png) and
[geometry](before-done.txt): Done accessibility frame (314,66,68,36), navigation
bar (0,62,402,54), Back (16,62,44,44). The keyboard is open and the cleared Amount
is retained. No Done action was executed.

The product specification requires a 44×44-point hit area. Apple's
[automation frame API](https://developer.apple.com/documentation/xcuiautomation/xcuielementattributes/frame)
describes screen coordinates, while public
[hit testing](https://developer.apple.com/documentation/uikit/uiview/hittest(_:with:))
routes a point through the view hierarchy. This unavailable control mapping does
not justify treating the smaller automation frame as the complete touch area.

Next: replace that unsupported measurement assumption in an isolated test
proposal with direct target-edge behavior, retaining all quantity, disabled
acceptance, review, approval and relaunch checks. Keep finite touch samples and
physical accessibility acceptance distinct. Do not repeat this observer or loosen
its identity checks to manufacture coverage.

[Bound observation](observation.json) · [Verification](verification.json)

Private execution package: `.build/EnglishKeyboardReviewNov08/native-done-hit-execution-r1`.
Build session 72869, test 42046 and inspection 61210 are terminal. Inspection and
fixed-file collection are complete; do not repeat them. The reused source/DD now
contain this diagnostic, while the exact pre-observer R3 source and products are
under this package's `preservation/` directory. Canonical app source is unchanged.
