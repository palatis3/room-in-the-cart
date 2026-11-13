# Protected meal heading: complete native text bounds

The review sheet now uses a native text heading for “Protected meal commitments.”
The previous decorative-lock Label exposed a frame that omitted the left edge of
lower wrapped lines at the largest text size. Removing that decoration preserves
the wording, headline font, wrapping and heading accessibility trait, and gives
the entire heading one complete text frame. Financial and permission behavior is
unchanged.

The existing largest-text journey now checks the heading and expiry title/date
for complete rendered bounds, visible/hittable position and measured screenshot
contrast. It retains the original protected-lunch checks, disabled Apply,
cancellation and zero-write assertions. No selector, timeout or threshold was
relaxed. The original standard-text checkout/two-lunch journey also runs.

| Configuration | Standard journey | Largest-text journey | Native / strict |
| --- | ---: | ---: | --- |
| iOS 26.2 light | 73.620 s | 140.922 s | 0 / 0 |
| iOS 17.0 light | 79.43 s | 124.23 s | 0 / 0 |
| iOS 26.2 dark | 69.04 s | 136.30 s | 0 / 0 |

All six test executions passed with zero recorded runtime warnings, zero runner
restarts and no observed animation-idle messages in the supplied logs. Original
bundles and frozen source remained unchanged during their one-time inspections.
Root reviewed twelve retained images: the standard checkout/lunch screen, largest
heading full screen and crop, and largest expiry screen for each configuration.
The iOS 17 layout hyphenates at the largest size; the complete words and actual
2098 fixture expiry remain visible. These screenshots are synthetic fixture data.

The heading frame now starts at x32 and includes every line: current OS
327×187.333 points (reference height187.248), minimum OS243×249.5
(reference249.248). The existing two-point measurement tolerance is unchanged.
Expiry title and actual date also pass their original bounds/contrast conditions.

Unsigned generic-iPhone arm64 Release compilation and built-app/extension checks
passed on the same source. Reusing the verified Release cache completed that
qualification in about25seconds. Prior products were APFS-preserved and verified
before rebuilding. This is compilation evidence, not signed distribution.

Source manifest: `7a98427be259ea40764fdae396013ebe78cf8a43cf02d4b9508ee849c9284d99`.
Private native evidence stays under `.build/S24TextHeadingNov08/`; receipts and
reviewed captures are retained here. The previous rejected wrapper and baseline
failure remain in `request-named-audit-measurements-20261108`.

These are scoped regression passes. The earlier unfiltered accessibility audit
has not been rerun on this candidate, and its complete finding set remains open.
No claim of full-screen accessibility or full release acceptance follows.
