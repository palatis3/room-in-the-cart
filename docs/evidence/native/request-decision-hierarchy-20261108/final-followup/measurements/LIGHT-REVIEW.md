# Completed light capture review

The actual empty price prompt has core RGB **(71, 93, 85), #475D55**, on **(255, 255, 255), #FFFFFF**: **7.0830264403:1**, above 4.5:1. This is the original rendered crop, not a token-only calculation.

The 1014×66 RGB8 sRGB PNG matches the exported receipt hash `1f4067e1fb8acbe16bb8428566f5d35d2cd818d2c02d5eae32c07c2dd2b84cea`. Its frame TXT identifies `household.decision.price`, the complete empty-price placeholder, and frame {{32.0, 787.3}, {338.0, 22.0}}, consistent with a 3× crop. The complete prompt is visible, without a caret, border, icon or other label.

The generic method retains 31 glyph components; all 31 have the same core RGB as their modal color, representing 5,994 core pixels. Four narrow letter components are conservatively excluded by the caret-like filter. Inspecting the entire crop independently also finds the same RGB as its strongest-contrast color; no isolated darker mark supplies the result. Antialiased edge colors remain lower contrast, as expected.

`light-measurement.json` contains the unchanged generic method output, component boxes and color histogram. `light-review.json` records visual review, whole-crop corroboration, attachment metadata, source hashes and frame provenance. No dark results, native execution or canonical edits were involved. This single captured-state result does not close the 41-finding audit or establish physical/AX5 accessibility.
