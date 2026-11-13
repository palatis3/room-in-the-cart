# Plain-style Done candidate — changed layout, edge failure retained

Exactly two `.buttonStyle(.plain)` modifiers changed the prior app candidate.
The direct behavior test, input order, points policy and business/restart checks
remained byte-identical. Compilation and built-app checks passed in24.175s.
The English case failed after145.000s; native65/strict1 and zero idle misses.
Prior/current source, products and original result preservation verify.

The style did change layout: Done now reports a44×44 accessibility frame at
(338,62), replacing automatic styling's68×36 frame at(314,66). Its center(360,84)
successfully dismissed keyboard/Done and retained the whitespace/editor. The
unknown-quantity and disabled-acceptance flow completed. The restored-Amount top
sample(360,62) did not dismiss the keyboard within5s. Supply and later approval/
relaunch were not reached. This candidate is not qualified or installed.

Root reviewed the [top-before screenshot](top-before.png), showing black Done
text and changed decoration, and all three exported geometry records.
[Center success](center-result.txt) · [Exact failed target](top-target.txt) ·
[Verification](verification.json). The before screenshot is not post-failure
visual proof; the native assertion/log establishes subsequent keyboard persistence.

The failed coordinate lies on the exact minimum edge of both the44pt target
frame and the navigation bar. This is a relevant measurement limitation:
finite pixel centers, shape boundaries and event quantization need review before
attributing it to missing interior touch coverage. No causal explanation is yet
proven. The earlier test used exact min edges and one-pixel-inset max edges.
Any correction to that sampling policy must be principled, symmetric and applied
identically to automatic-style control and plain candidate, retaining these
failures. Do not shift only the failed point to obtain a pass or infer complete
hit coverage from the44pt frame alone.

Private execution package: `.build/EnglishKeyboardReviewNov08/native-done-plain-execution-r1`.
Preparation94234, build42907/PID75063, test48485/PID75366 and inspection17748 are
terminal. Inspection is complete and must not be repeated. Reused source/DD now
hold the plain candidate; its preservation folder retains direct-touch automatic
source/products. Canonical app source remains unchanged. Full release acceptance
and physical accessibility remain open.
