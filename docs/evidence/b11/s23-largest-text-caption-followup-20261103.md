# S23 largest-text amount/use caption follow-up

This is a narrow layout follow-up to the passing FinalNative470 S23 evidence. It does not amend the accepted green result or its known caption ellipsis. The earlier evidence remains unchanged at `s23-duplicate-request-review-20261103.md`, SHA-256 `3e71edf2dd9b9f5fe32f3bddf459cb86c5807795bab7738043cbbca1336baa34`, for frozen source `4b91cfce67372ca1b047985ce3531cd806d627c0eb4a60311ed0bead9beb7af0`.

## Observed issue and change

The retained US-Spanish largest-accessibility-text screenshot `.build/FinalFixture-20261103-attachments/9231471D-A711-4B69-B2AA-99E6C927D966.png` shows Lee's amount/use caption ending in an ellipsis. Its paired accessibility tree, `5EA0FC0F-CB4B-4244-841A-A86068CC422F.txt`, retains the full caption, **Cantidad y uso, tal como se escribieron**, and the complete original request value, **2 boxes for the school snack drive**. The lead independently inspected and confirmed the visible truncation.

`RequestDuplicateComparisonView.swift` now applies `.fixedSize(horizontal: false, vertical: true)` to that amount/use caption Text. The caption still wraps within the proposed width and now requests its full intrinsic vertical height. The original amount/use value already used this modifier. Font, Dynamic Type, localization, original text, author identity, selected-request marker, outcome, accessibility identifiers and decision behavior are unchanged. This follow-up changes exactly one view modifier; it adds no mirrored layout test.

## Validation and immutable source identities

Swift frontend parsing passed for the changed view. No device, simulator, heavy build or git operation was run by this lane. The lead subsequently reran the unchanged Spanish largest-text UI case on the follow-up frozen source; its passing result and inspected caption frames are recorded below. The prior FinalNative470 UI passes remain attributed to their original source hash.

| File / identity | SHA-256 |
|---|---|
| Previous passing `RequestDuplicateComparisonView.swift` | `11088e22ac1bea6960a771fb078b774ab9f62ff6b4a1f014bc23a3a10f272330` |
| Follow-up `ios/Features/Household/RequestDuplicateComparisonView.swift` | `4a4da2faaf97320549b8bf20c0cc3c98f2882eeb387ba5080ea0d7f5cb4af63e` |
| Unchanged `ios/UITests/RequestDuplicateComparisonUITests.swift` | `b3e4cf1033a5bd396969600c9d65a3e24e6814c93ce89852ded0b840b6cfd0af` |
| Unchanged accepted S23 evidence document | `3e71edf2dd9b9f5fe32f3bddf459cb86c5807795bab7738043cbbca1336baa34` |

## Passing native caption confirmation

The lead's **NativePolish470** frozen source SHA-256 is **`36479321a5cadd46a6226c553d3e6946958e04b822dbf7aff73b2457a4f6c0bc`**. On iPhone 17e, the existing `RequestDuplicateComparisonUITests/testSpanishLargeTypeKeepsOriginalRequestWordsAndReadOnlyComparison` passed **1/1, 0 failures, 361.533 seconds**, completing at 2026-11-03 18:26:13 America/New_York. This is the unchanged US-Spanish / `UICTContentSizeCategoryAccessibilityXXXL` case, including page-boundary inspection, selected-request identity, both original author/use strings and cancellation without writes.

Authoritative run artifacts are `.build/NativePolishFixture-20261103.xcresult`, `.build/NativePolishFixture-20261103.log` and `.build/NativePolishFixture-20261103-attachments/manifest.json`. The lead owns promoted artifacts and git operations. The screenshots below were opened and visually inspected, and their paired accessibility trees were read:

| Caption | Screenshot in `.build/NativePolishFixture-20261103-attachments/` | Paired accessibility tree | Observation |
|---|---|---|---|
| Lee | `EAE07EB9-1A83-4E25-A4B0-E3C7D9155117.png` | `ECB09878-7949-4367-B5C6-50EA3882437E.txt` | **Cantidad y uso, tal como se escribieron** wraps fully across three lines, without an ellipsis. Lee and the original CEREAL wording remain separate. The caption's AX frame is 153.3 points high and preserves its exact full label and request-scoped identifier. |
| Sam | `FC4B55DB-FD53-48C6-8BC9-A2C9A1026185.png` | `66BA4E82-3952-48AE-9438-AA17058E05A8.txt` | The same full Spanish caption wraps across three lines without an ellipsis below Sam's selected-request marker and original Cereal wording. Its AX frame is also 153.3 points high. |

The original amounts continue below their respective captions through ordinary vertical scrolling. The unchanged passing test requires the exact **1 box for breakfasts** and **2 boxes for the school snack drive** values to become visible in their own request-scoped fields; the full strings and distinct identifiers remain in AX. The final post-Cancel hierarchy `948B3569-28C5-4783-A12A-C71A249235BB.txt` records **0 applied decisions, 1 saved basket line and 4 loaded requests**.

This confirms the observed caption ellipsis is resolved in the scoped Spanish largest-text simulator path. It does not rerun the English case or model suite on NativePolish470 and does not certify physical-device or live human VoiceOver behavior. The earlier English/Spanish green record for source `4b91cfce67372ca1b047985ce3531cd806d627c0eb4a60311ed0bead9beb7af0` remains byte-for-byte unchanged, including its historically correct bounded ellipsis observation. No production source or test was changed during this evidence update.
