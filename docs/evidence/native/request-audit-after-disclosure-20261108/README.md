# S24 unfiltered audit after stable disclosure heading

The unfiltered current-iOS audit **fails with 37 findings** on the protected-lunch viewport. Native exit 65 and strict exit 1 are retained. Production source is unchanged at manifest `ffd68bf9a00de16e7be6c7d2121b2502da3b134626b5b3810cd65820434fd763`; the isolated snapshot adds only the audit callback. Every category is enabled and the issue handler returns false. The original test continued through its no-write/access-ended assertions.

Executed November 8, 2026, 20:24:43–20:30:03 UTC, iPhone 17 Pro simulator / iOS 26.2 (23C54), English, light, standard Large text, increased contrast disabled. Result inspection finished at 20:30:13 UTC. Original result and sources verified unchanged. All 37 callback attachments correlate to automatic reports; no suppression was applied.

| Category | Findings |
|---|---:|
| Contrast | 2 |
| Potentially inaccessible text | 1 |
| Dynamic Type unsupported | 2 |
| Dynamic Type partially unsupported | 29 |
| Text clipped | 3 |

`findings.json` retains target/category/context reconciliation against the historical 41. Five old reports are not observed in this viewport: Apply contrast and Dynamic Type, Cancel preview Dynamic Type, and clipping for Apply and Cancel preview. Those controls are outside this screenshot; **not observed does not mean closed**. Unattributed reports are not guessed or matched by count.

Root reviewed the retained viewport. The reported Review decision control occupies y26.3–78.3, behind the navigation area; it is not fully visible. The protected-meal heading and expiry title/date are visible at standard size. These observations justify direct fully visible contrast and largest-text bounds measurements, not a false-positive waiver. No audit finding is marked closed here. Thirty-seven reports need investigation; they are not necessarily 37 independent product defects.

Next: measure Review decision after real scrolling, and protected heading/expiry title/date at standard and AX5 text on unchanged production source. Preserve all reports when assessing those measurements. Physical assistive testing, other locales/appearance/device states and complete first-version acceptance remain open.

Private original result: `.build/RequestDecisionAccessibilityNov08/after-disclosure-r1/run/native.xcresult`. The included scripts document the exact execution; they depend on retained private helper paths and are not portable CI scripts. No new CI push or deployment occurred.
