# Dinner editor readability candidate

This is an isolated candidate, not yet installed in the canonical app. Persistent
wrapping ingredient labels keep names, amount purpose, notes, exclusions and
Remove ingredient readable. Supply review has a full in-content heading and
persistent yield/price/source labels. Editable leaves retain their names, IDs,
bindings and focus; numeric fields remain horizontal and textual fields can grow.
No Dynamic Type cap, smaller-font workaround or business-rule change is included.

The original journey retains all five Done coordinate probes, exact values,
unknown-quantity rejection, acceptance contrast/padding, explicit supply approval,
relaunch persistence and the unchanged shopping-list check. Progress-aware lazy
row navigation and native editable-element queries support the taller form.
The temporary retained-state diagnostic is excluded from the source candidate.

## Qualification

- Product candidate source7f68068a87a58630d4875a48bd9bbf40a39d8a42594d55a57a3c94523d3e1e1c:
  original English Large journey native0/strict0, zero idle misses. Root/helper
  reviewed all11 screenshots and10 geometry/target records. This qualifies sampled
  English content and interactions, not global accessibility or VoiceOver.
- Final R2 sourcee45a7cae9013d1510bdd5bd04a98cf09e747e87d39a7187ac950e2a370824623:
  app bytes unchanged from that English product candidate; test-only follow-ups
  use editable queries in two original cases and progress-aware Review taps.
  Build/bundle and exact-source localization/project/automation checks pass.
  The initial source-check wrapper incorrectly asserted that a validator returns0
  instead ofNone; corrected orchestration passed without any source change.
- R2 Spanish AX5 is terminal native65/strict1, zero idle misses. Both Amount Done
  probes passed, but the restore edited cabbage while Tortillas stayed blank.
  The repeated Amount label resolved to a different lazy row after scrolling.
  The final trace shows Tortillas unresolved, beans1cup and cabbage4cups (originally1).
  Acceptance correctly remained disabled. Large restored; exports done once.
- R3 source1173047f5a367d44384a7d64919ab117c85bc45929f880d266eee5ae707f1573
  adds leaf identifiers from existing ingredient UUID focus keys, captures the
  original Amount ID, and asserts identity/prior value before both edits. Original
  tests, gestures, timeout and business rules remain. Build/bundle pass; Spanish
  AX5 reached all5Done and approval with the original UUID restored, then exceeded
  its720s allowance at relaunch. Native65/strict1, zero idle misses, all required
  screenshots/geometry complete; Large restored and original result unchanged.
  Total command792.436s includes timeout cleanup. Persistence is still unverified.
  Root/helper reviewed11screens; body heading is complete, native title truncated.
  Selected-food menu value also truncates, requiring the R4 display correction.
- R4 source58e371426c6080af493d3cc38a6f063ac68c73541a5c1f5c9e7bd63ed436ee35
  checks upper review facts before early enabled acceptance, then searches back
  toward the supply row. R3 spent49gestures on this block, including20 to Accept
  and20 back to the title. The first unknown warning search also begins toward
  the preceding content rather than reaching the bottom first. Every original
  assertion,24gesture limit and deadline remains. A wrapping accessible summary
  mirrors the native food selection and has an added exact no-match assertion.
  Runtime/visual qualification is pending; speedup is not yet measured.
- Final-English, minimum OS, two affected original cases, unsigned Release and
  combined hosted regression remain outstanding.

The preserved failure evidence in dinner-scroll-progress-20261109 remains valid.
Do not count the earlier short root-recovery probe as full-journey acceptance.
The candidate patch is against canonical app/test baseline before installation.
