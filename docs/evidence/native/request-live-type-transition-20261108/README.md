# Live Dynamic Type: expiry text review

The existing request review adapted from standard **large → AX5 → large without relaunch**, and the targeted native case and unchanged strict inspection passed (1/1; native 0, strict 0; zero recorded runtime warnings). This isolated test extension retained the original request/cancel/no-write/access-revocation assertions. It is not closure of the broader accessibility audit.

The run used Xcode 27.1/27A9275, iPhone 17 Pro simulator, iOS 26.2/23C54, light appearance and standard contrast. Both host changes/readbacks and final restoration to large succeeded. The preserved inspector verified source/original-result integrity. This package rehashed all 18 required attachments against that receipt and copied only the reviewed screenshots and six geometry records; it did not rerun tests or export results.

## Visual and geometry findings

All nine remaining PNGs were viewed: the date full screen at each stage, plus title/date ink crops at each stage. “Preview expires” and “Dec 31, 2098 at 7:00 PM” remain complete and readable, with no visible target-text clipping, ellipsis or overlap. At AX5 the row changes from side-by-side single-line text to stacked two-line title and date. Both target elements remain inside the measured viewport.

| Stage | Title bounds, points | Date bounds, points | Visible layout |
| --- | --- | --- | --- |
| Before / large | 119 × 20.333 | 186.333 × 20.333 | One line each, side by side |
| AX5 | 187 × 125.333 | 315.333 × 125.333 | Two lines each, stacked |
| Restored / large | 119 × 20.333 | 186.333 × 20.333 | Original size and layout restored |

Before/restored title ink files are byte-identical; before/restored date ink files are also byte-identical. Screen position changes with scrolling, so the complete before/restored screens are not identical. Each reviewed date full screen is byte-identical to that stage's title full screen already reviewed by the root agent; duplicate full screens are omitted here.

All six existing bounds/hittability and pixel-contrast helper assertions passed. The bounds helper allows two points of height tolerance; its UIFont line height and required text bounds are reference calculations, not app font introspection. Contrast checks enforce a 4.5 helper threshold, but actual ratios were not exported. Height growth includes wrapping and must not be presented as a measured font-size multiplier.

## Included evidence and scope

- `verification.json`: sanitized terminal outcome, settings, source pins, transition readbacks and restoration.
- `geometry.json` and `geometry/`: six labeled original geometry records.
- `screens/`: three full screens and six existing ink crops, with meaningful stage names.
- `visual-review.json`: exact nine original PNG names and review findings.
- `attachment-binding.json`: all 18 attachment names, hashes and selected-copy mapping.
- `source-receipt-hashes.json` and `file-hashes.json`: provenance and package integrity.

These screenshots show a scrolled section; other rows can be outside its viewport. This review establishes the displayed expiry text's live adaptation in this journey only. It does not establish internal audit sampling behavior, all intermediate text categories, VoiceOver, dark appearance, every request state, or general accessibility compliance. Original broader audit findings remain open. No raw native log, private device path, simulator identifier, or result bundle is included.
