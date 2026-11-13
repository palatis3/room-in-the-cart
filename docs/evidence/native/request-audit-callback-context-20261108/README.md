# Request accessibility callback context

The unfiltered audit completed with native exit 65 and strict exit 1. It reports
36 findings: 29 partially unsupported Dynamic Type, two unsupported Dynamic Type,
two clipping, two contrast, and one potentially inaccessible-text finding.
All categories remained enabled and every callback returned false. The original
functional/cancellation/no-write/access-revocation assertions continued. No app
source or test assertion changed; an isolated test copy adds diagnostic captures.
The original journey took 113.453 seconds. Source and original result are preserved.

All 36 custom descriptions reconcile to the automatic issue descriptions and
console failures, with 9 ms timestamp-correlation spread. Inspection and all five
exports are complete; do not repeat them. The previous 39-report audit is retained.
The change in count is not evidence that three bugs were repaired.

Six callback screenshots and matching full accessibility hierarchies were captured:
both contrast reports, the inaccessible-text report, the first Dynamic Type report,
and both clipping reports. Root reviewed all six. Screenshots were attached about
176–200 ms after callback entry; their hierarchies followed within 957 ms. Five
screenshots have identical hashes, while the first differs. All show the same
standard-size content layout. These are callback-time views, not captures of the
framework's internal font-size sampling. Apple documents the issue's type and
optional element in [XCUIAccessibilityAuditIssue](https://developer.apple.com/documentation/xcuiautomation/xcuiaccessibilityauditissue).

## What this establishes

- Both clipping reports now identify the expiry row: “Preview expires” and
  “Dec 31, 2098 at 7:00 PM.” These also receive the two fully unsupported Dynamic
  Type reports. Their standard-size text is visibly complete in the callback
  images, with AX heights 20.3 points. This identifies targets; it does not waive
  the larger-size clipping reports.
- The named contrast report is “Review decision.” Its AX frame is y26.3–78.3,
  behind top chrome; that button is not visible in the callback screenshot.
  Earlier separate fully visible contrast checks remain relevant, but do not
  prove the audit's internal sampling context.
- The second contrast report and inaccessible-text report still have no element
  identity. They remain unattributed. No callback screenshot shows a new visible
  clipping defect.

The expiry row already passes separate standard/largest-text bounds and contrast
checks across current light/dark and minimum iOS 17. [Existing qualification](../protected-heading-text-20261108/README.md).
The next discriminating measurement is a live system text-size transition with
this row visible, without relaunching or changing its production layout. That
can distinguish actual update behavior from the audit's internal observation;
another unchanged audit count cannot.

Canonical 556-input manifest: `8d0eb48f5f54f1ac22b43a01966509d9637b34ec88d9f13a06d3a145967f5d1a`.
Isolated diagnostic manifest: `c0e83935417cd067d6adaab85240346f358d210e3c91a1e8f203ce3021acd508`.
Original bundle, cloned inspection and all private run products remain under
`.build/RequestDecisionAccessibilityNov08/callback-context-r1/`.
