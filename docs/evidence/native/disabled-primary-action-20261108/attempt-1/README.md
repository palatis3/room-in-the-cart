# First candidate: custom buttons pass; automatic dinner row remains too faint

The exact 556-file iOS source manifest is `be308a336e69d2b316df79efd8d71ff3e3e9824b516c0091934bd05f2ea9462d`. The three-file change is retained in `change.patch`. All executions use local Xcode 27.1/27A9275 and iOS 26.2/23C54. Original results were copied before inspection and verified unchanged; no retry, timeout increase, logging suppression or warning waiver was used.

| Execution | Native / strict | What it proves |
| --- | --- | --- |
| Request fixtures, light | 3/3, both exits 0 | Unknown-price and unaccepted-overage buttons retain disabled AX state, reject physical taps, and preserve no-extra-write assertions. Correction and explicit consent permit the original once-only save. Largest-text action wraps completely. |
| Request fixtures, dark | 2/2, both exits 0 | Carried-request correction and largest-text behavior also pass in dark appearance. |
| Ordinary dinner, English and Spanish, light | 2/2, both exits 0 | Unknown ingredient quantity prevents acceptance; physical taps leave the review unchanged. Restoring the actual quantity allows one accepted idea, retained after restart, with the shopping list still empty. **Rendered disabled text nevertheless fails contrast.** |

All seven executions record zero runtime-warning occurrences and no observed animation-idle or runner-restart messages in their supplied logs. This does not resolve the separate hosted UI09 animation stall or cook speech-warning failure.

Root reviewed all 14 PNGs. Request-button glyph cores measure **15.21385:1 in light** and **13.74643:1 in dark**, each repeated across 23 glyph components. The normal-size straight outline measures 4.64082:1 and 5.86720:1 respectively across three full 700-pixel rows. The distributed glyph method excludes crop-edge components; the native percentile helper alone is not used to infer the measured glyph color. Independent light review reproduced the result and recorded 56 faint corner-antialias pixels remaining at crop edges, at most 1.40155:1. These do not account for the passing glyph measurement.

The automatic Form `dinnerAcceptIdea` button still attenuates the entire label. Both ordinary screenshots measure **3.11166:1**, RGB `(139,148,146)` on white, across 11 English and 12 Spanish glyph components. The ROI excludes the border and adjacent text and uses original sRGB pixels. This is a visual qualification failure despite passing interaction and warning checks. The ordinary tests at this revision capture the failure but do not yet assert label contrast; that missing regression assertion must be added with the correction.

The caller review covers 41 custom-style Buttons, one custom-style NavigationLink and one direct automatic-Form label. It finds no interactive label children. The historical automatic dinner row was introduced in `a618028` to make its entire accessible row activate; the correction must preserve that hit area, disabled semantics, explicit acceptance and persistence. Do not simply revert that fix or continue the unchanged remaining phases to claim acceptance.

Current minimum-iOS-17, ordinary dark appearance and final Release qualification for a corrected candidate remain outstanding. These scoped results close no broad accessibility audit finding and do not replace human VoiceOver, Switch Control or US-Spanish acceptance.

`provenance.json` maps byte-identical retained files to private originals. Each compact `run.json` binds its full private run receipt, native log and preserved result manifest by hash; the large products and result bundles remain private. `measure_field.py` preserves the actual pixel decoder and component method. Its historical prompt-specific wording does not change the explicit button-label ROIs and visual review recorded here.
