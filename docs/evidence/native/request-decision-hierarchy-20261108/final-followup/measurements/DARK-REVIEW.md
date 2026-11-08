# Completed dark capture review

The actual empty price prompt has core RGB **(180, 196, 185), #B4C4B9**, on **(28, 41, 35), #1C2923**: **8.2952389540:1**, above 4.5:1. This is the original rendered crop, not a token-only calculation.

The 1014×66 RGB8 sRGB PNG matches the exported receipt hash `f06708c05df0c07ca55fda0527de44c4e7f473de5cffb80902b98a9ef948cde3`. Its frame TXT identifies `household.decision.price`, the complete empty-price placeholder, and frame {{32.0, 787.3}, {338.0, 22.0}}, consistent with a 3× crop. The complete prompt is visible, without a caret, border, icon or other label.

The unchanged generic method retains 31 glyph components; all 31 have the same core RGB as their modal color, representing 5,994 core pixels. Four narrow letter components are conservatively excluded by the caret-like filter. The entire crop independently has the same RGB as its strongest-contrast color (6,339 pixels); no isolated brighter mark supplies the result. Antialiased edge colors remain lower contrast, as expected.

`dark-measurement.json` contains the generic method output, component boxes and color histogram. `dark-review.json` records visual review, whole-crop corroboration, attachment metadata, source hashes and frame provenance. Every entry in the existing light manifest was checked unchanged before dark evidence was added. The measured captured-state core contrasts are light **7.08:1** and dark **8.30:1**, both above 4.5:1.

`final-manifest.json` preserves measurement scripts, reviews, numerical reports, both attachment receipts and all receipt-linked captures. No native execution or canonical edits were involved. These two captured states do not close the 41-finding audit or establish physical/AX5 accessibility.
