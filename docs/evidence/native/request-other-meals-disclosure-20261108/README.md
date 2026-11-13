# Named, full-row Other meals disclosure

The request review’s “Other meals in this shop” header now uses the existing labeled disclosure style. On iOS 17, the original control exposed an unnamed 10.5 × 13.5 point chevron beside a separate label. The correction makes the full label a named button with at least a 44-point target and a localized expanded/collapsed value.

The final source (`a5624f8…`, 556 pinned inputs) passes the complete added journey in three configurations:

| Configuration | Native / strict result | Case time |
|---|---|---:|
| iPhone SE 3, iOS 17.0, light, Large text | Pass / pass | 88.61 s |
| iPhone 17 Pro, iOS 26.2, light, Large text | Pass / pass | 85.70 s |
| iPhone 17 Pro, iOS 26.2, dark, largest accessibility text | Pass / pass | 427.16 s |

Each execution taps the actual label to expand and collapse; verifies the ordinary dinner’s name, date, kind and four portions; and preserves both protected lunches, the $37.20/$40.69/$2.69 amounts, disabled Apply and zero writes before, during and after. All three strict checks report zero recorded runtime warnings, with no observed animation-idle or runner-restart markers. Root reviewed all 15 selected screenshots and 24 discovery/control records. The unsigned arm64 iPhone Release build and compiled-bundle validation also pass on the same source.

The existing fixture gains an opt-in ordinary dinner; its defaults are unchanged. The new case is registered exactly once in the existing contributor group, increasing fixture inventory from 70 to 71 without adding runner slots. All 16 planner tests pass. Typed queries and reuse of unchanged snapshot attributes reduce repeated XCTest accessibility reads without removing behavioral assertions, suppressing logging or changing deadlines.

Evidence:

- [Original defect](baseline/README.md).
- [Initial correction: partial rendering followed by a crash](fixed-attempt/README.md).
- [Two-query adjustment: another failed full journey](query-attempt-r2/README.md).
- [Final results and Release receipt](qualified/summary.json), [source hashes](qualified/source-manifest.json), and [artifact hashes](qualified/file-hashes.json).

The earlier crashes remain recorded; the passing follow-up does not establish a general Apple framework repair. These are scoped simulator and compilation results, not physical VoiceOver, Spanish runtime, complete accessibility-audit or distribution acceptance. Existing Spanish strings are retained. At largest text, the label is complete but wraps onto two lines when collapsed and three when expanded because the chevron widths differ; a stable indicator-width refinement remains useful. Other app and release requirements remain open.
