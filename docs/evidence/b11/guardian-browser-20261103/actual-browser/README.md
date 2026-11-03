# Actual guardian browser acceptance — local fixture

Desktop ChatGPT in-app browser, 127.0.0.1:4188 HTTP, 2026-11-03. Synthetic accounts/codes, no SMTP/provider/network service, no external credentials. This is actual visible UI plus isolated protocol fixture proof; it does not replace backend wire or Android acceptance.

Passed covered sign-in → device pairing → explicit guardian fixture approval → Finish → existing own-request screen. Active full reload recovered only with the scoped cookie. Dropped claim/finish sockets produced exact duplicate POSTs with one effect each; no manual retry was claimed where the browser recovered directly. Approved full reload preserved the explicit inability to reconstruct original pairing and generated no replacement POST. Foreign household bootstrap and generic authentication without admission denied access.

A deterministic accepted Finish with malformed body and no cookie remained unconfirmed. After full reload it showed no requests link, form, pairing, Retry or Finish; counters proved no replacement POST. The final same scenario passed on the corrected page build in English and Spanish; duplicated recovery wording found during acceptance was fixed and rechecked.

See run-observations.json for exact source hashes, scenario-specific counters, screenshot/AX hashes and limits. Files01–08 preserve earlier observations,09–11 verify final display correction. Earlier passing state/transport checks used page bd0518a...; final display-only correction page13ca45d... did not change state/API code.

Pending/approved enrollment still needs its original in-memory page or an explicitly newly reviewed guardian setup. No persistent browser credential recovery was invented. Actual current Android acceptance remains a separate open task.

Owned fixture and browser tab closed. No simulator used.
