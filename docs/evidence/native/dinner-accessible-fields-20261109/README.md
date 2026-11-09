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

## Earlier qualification checkpoints

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
  R4 reaches the final list assertion at715.60s, then times out during teardown;
  native65/strict1, zero idle misses. All11 screenshots reviewed: full selection
  summary wraps, all5Done values/geometry retained. The reordered review block
  fell from49 to29gestures; final acceptance occurred56.77s earlier thanR3.
  This is measured navigation progress, not a passing full journey. Large restored.
- R5 source2def49047a4bfb0bb82ee25b138714ad1851af8a2edd6bfee57b04c4c257524d
  adds native Edit/Editar during idea review and retains bottom Continue editing.
  Both execute the same transition. Original assertions/deadlines remain. Build,
  bundle and source checks pass. Spanish AX5 remains native65/strict1 at the
 720s timeout, with all required evidence complete and zero idle misses. Total
  drags fell199→176, but total runtime did not improve; retained timing review
  distinguishes fewer gestures from faster completion. Large restored.
- R6 sourcedc1b3def23b3f631aa613cc11ec7b1671335430143ea85063057dac323c19c9c
  reuses same-iteration snapshot bounds and skips unnecessary screen capture
  for already hittable targets without a full-row requirement. It also matches
  toolbar accessible and visible Edit/Editar names. Assertions/limits remain.
  Build/bundle/source checks pass; original Spanish AX5 then English are active.
- Final-English, minimum OS, two affected original cases, unsigned Release and
  combined hosted regression remain outstanding.

The preserved failure evidence in dinner-scroll-progress-20261109 remains valid.
Do not count the earlier short root-recovery probe as full-journey acceptance.
The candidate patch is against canonical app/test baseline before installation.

## Combined candidate follow-up, November 9

Combined Dinner/audio R4 source manifest is
`ea06e1901c7921deb33eb322d667053de2f47534c8273f7487413457540fd968`.
The isolated source/products remain under `.build/DinnerAudioCombinedNov09R4`,
with prior source/products preserved before every rebuild. App code is not yet
installed canonically. The changed supply row now focuses its native text field
when tapped; confirmed-stock status wraps vertically. The native confirmation
lookup uses a typed exact identifier, retaining label/type/count assertions.

Original English passes native/strict in238.47seconds command time. Review of all
13images and10geometry receipts verifies the full stock-status text and all5Done
transitions. This closes the R6 English ellipsis for this candidate/profile, not
all-language/layout acceptance. Both sets of64audio/capture/projection regressions
and the complete Free dinner/repair/settlement/next-shop journey pass strict checks.
The cross-week movement case also passed native/strict validation.

Spanish17.0 R3 progressed beyond the former input-focus failure, then crashed in
XCTest's logging callback/quarantine; R4 repeated that same framework signature
at an earlier query before the narrowed confirmation lookup. Both failed journeys,
originals and IPS are retained locally. No log suppression or unchanged retry was
used. Official iOS17.5/21F79 was installed for separate compatibility qualification;
its later failed result is recorded below. No17.0 acceptance is claimed. Current execution state is in
`docs/CURRENT-HANDOFF.md`; final combined/full-CI/release gates remain open.

The same R4 original Spanish AX5 journey on iOS26.2 now passes native0/strict0:
696.241s test time,712.819s command time, all original assertions, no observed
animation-idle misses, and unchanged source/products/result bytes. The simulator
text size was restored to Large. All13images and10geometry records were reviewed:
full in-form heading, separate selection summary, Editar and all5Listo dismissals
are readable and preserve values. The confirmed-stock summary is not sampled at
AX5, so its visual wrapping is not newly qualified. The native compact title and
picker truncate at this size but have complete visible in-form alternatives.
The first keyboard sample includes the system bilingual onboarding panel; the
recorded dismissal succeeds. Retained proof and hashes:
`.build/DinnerAudioCombinedNov09R4/spanish-ax5/{inspection,visual-review}`.

The separate unchanged Spanish journey on17.5/21F79 failed native65/strict1 in
the same XCTest callback/log-quarantine family as17.0, now at ledger review lookup
before supply confirmation. A preserved matching IPS and source/product/runtime
binding are in `spanish-ios17_5/crash-review`, manifest SHA256
`b5abefeebff7cd86789484cdce7a62db1d061a202ddbb8852e5e3cfdb3870e1c`.
Do not repeat unchanged full journeys or claim a query-only repair. A bounded
independent reproducer is the next proposed causal experiment. Unsigned Release
now passes native0/bundle0 in418.832s, in a separate directory for the same source;
no canonical app install, combined hosted regression or minimum-OS acceptance is claimed.
