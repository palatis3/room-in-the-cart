# Unfiltered request audit after the text heading fix

The audit completed with native65/strict1 and39 findings. Every category remained
enabled, the callback returned false, and the original functional/no-write/access
revocation assertions continued after the audit. No failure was waived. The
canonical app remained unchanged; only the isolated test copy contained the audit.

| Category | Previous run | Current run |
| --- | ---: | ---: |
| Partially unsupported Dynamic Type | 29 | 29 |
| Unsupported Dynamic Type | 2 | 2 |
| Clipped text | 3 | 2 |
| Contrast | 2 | 3 |
| Potentially inaccessible text | 1 | 3 |

These are findings, not a count of confirmed product bugs or fixes. All39 custom
callbacks match the39 automatic issue descriptions and log failures; timestamp
correlation spread is9ms. Original source and result bundle were preserved. The
one-time exports and reconciliation are complete.

The heading is no longer named by a clipping report, but the two current clipping
reports have no element identity, so they cannot establish audit-level closure
for any particular target. Independent standard/largest-text bounds, contrast,
screenshots and Release qualification for the new heading are recorded in
[its scoped evidence](../protected-heading-text-20261108/README.md).

The contrast reports name Review decision (y26.3–78.3), Review before applying
(y95.7–136), and Add packs to this shop (y136–192.3). These callback coordinates
place the first two in the navigation region and the third near its edge. The
retained pre-audit screenshot is reviewed and shows the heading and named lunches
fully visible, but is not a simultaneous capture of each callback. Occlusion or
audit-induced movement remains a hypothesis, not a reason to suppress findings.
The newer two named contrast pairs are distinguished from the prior37 audit in
`previous37-comparison.json`. Unattributed findings stay unmatched.

Next measurement should capture the actual callback viewport for clipped,
contrast and inaccessible-text reports, and measure the named contrast targets
when fully visible. Do not rerun this unchanged audit or repeat its exports just
to obtain a different count.

Canonical manifest: `7a98427be259ea40764fdae396013ebe78cf8a43cf02d4b9508ee849c9284d99`.
Audit manifest: `1243ca4127d0149a0775fe561e4db6ddc5f9607a6820ddae3e9eacb0872b13b6`.
Private original and inspected clone remain under
`.build/RequestDecisionAccessibilityNov08/after-text-heading-r1/`.
