# Native viewport integration — 2026-11-03

The shared app now uses an expandable Edit row at accessibility text sizes and a bounded Shop scrolling viewport above its tab bar. Ordinary-size comparison editing, calculations and persistence are unchanged. Stable identifiers support diagnosis; the broad accessibility audit remains unfiltered and failing.

The first isolated integration run executed **214 tests: 206 model tests and six UI tests passed; two UI tests failed; zero skipped**. [Summary](current-candidate-native-summary.json), [source hashes](current-candidate-source-hashes.json) and [empty source-change report](current-candidate-source-changes.json) identify the tested snapshot. The six UI passes cover known save/restart, unknown quantities/restart, Spanish/original item name, largest-text dark save, viewport-contained Save, and the new expandable Edit row returning to the retained draft. This snapshot predates the separate dinner binding crash repair and subsequent features.

The two failures were the broad audit and the new complete-source/saved-details visibility check. The latter retained a **457.5-point source row in a 546-point viewport**, positioned at y259 after repeated default-velocity drags. [Measured frames](current-candidate-source-visibility-frames.txt) and the original result bundle retain this failure. The test's gestures alternated past the tall row. The follow-up centers the measured row using a slow drag and a hold before lifting; it retains the exact full-containment assertion, all original functional assertions and all audit categories.

The follow-up executed **three functional passes and one audit failure**, zero skipped: [summary](accessible-viewport-followup-summary.json), [hashes](accessible-viewport-followup-hashes.json), [source-change report](accessible-viewport-followup-source-changes.json). The three passes prove:

- Shop's repair shortcut fits fully above the tabs and opens the real urgent-repair screen at both default and largest text sizes.
- The comparison's Pack A/Pack B headers, source note and Save control can each be fully revealed at the largest text size.
- After the durable save, the combined confirmation and complete date can be fully revealed above the tabs. Its measured frame is `(16,155,343,435)` within the `(0,64,375,546)` visible results area.

Retained screenshots: [largest repair shortcut](accessible-largest-shop-repair-visible.png), [default repair shortcut](accessible-default-shop-repair-visible.png), [complete source note](accessible-largest-text-complete-comparisonsourcenote.png), [complete saved confirmation/date](accessible-largest-text-complete-saved-details.png).

The follow-up retains **32 diagnostic detail attachments across audited viewports**, not 32 independently established defects: [unfiltered details](accessible-viewport-followup-issues.json). Contrast, Dynamic Type and clipping assurance remain open. The saved-details screenshot also warrants a separate return-navigation check: its navigation strip appears blank, whereas the earlier large-Edit screenshot includes the back button/title. Successful content containment does not close that visual/navigation question.

Both runs used the iPhone SE (2nd generation) simulator on iOS 17.0, build 21A328. They do not establish physical-device VoiceOver, Switch Control, all locales/screens, or release acceptance. The current-OS Free journey and dinner crash repair have their own evidence and must not inherit these passes.

Local bundles/logs: `.build/CurrentCandidateNative.xcresult`, `.build/current-candidate-native.log`, `.build/AccessibleViewportFollowup.xcresult`, `.build/accessible-viewport-followup.log`. Full screenshots, frame attachments and audit crops remain in the corresponding `.build/*-attachments` directories.
