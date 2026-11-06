# Independent Done target review — 2026-11-06

Read-only review of retained baseline and candidate evidence; no app/test binary execution, simulator work, source/product edits, hosted actions, or retries. xcresulttool exported attachments into this review directory. Original failed path-quoting attempt remains untouched at source/.build/done-target-baseline; it is not a completed test baseline.

## Result

The local evidence supports a real improvement in the sampled Done touch margins. Baseline center delivered Done and dismissed the keyboard; all four corner probes did neither. Candidate delivered Done enter/exit and keyboard didHide in each of five separate app processes, and all five attachment results report dismissal. This establishes the sampled hit-region improvement, not the cause or resolution of the earlier hosted keyboard/idle stalls.

| Probe | Baseline PID / dismissed | Candidate PID / dismissed |
|---|---|---|
| center | 77840 / yes | 79228 / yes |
| topLeft | 77933 / no | 79303 / yes |
| topRight | 77989 / no | 79351 / yes |
| bottomLeft | 78052 / no | 79387 / yes |
| bottomRight | 78102 / no | 79426 / yes |

Named RITC_DONE_POINT records followed by the terminating nonzero PID correlate probes to processes; no launch-array-index inference. Baseline synthesized tap attachments independently confirm every probe's exact point and PID. Named result attachments, before/after screenshots, epoch times, and live event processes agree. Representative screenshots inspected: baseline center-before and bottomRight-after retain the keyboard; candidate bottomRight-after has dismissed it. Candidate successful bundle retains 15 explicit screenshots/results; it does not retain the automatic synthesized-event attachments available in the failed baseline bundle.

Baseline exposed frame is [344.3333,534,41.6667,20.3333]; candidate is [342,522,44,44]. Coordinates use the current AX frame center plus (0,0) or (±18,±18). Candidate center shifts about 1.17 points left and 0.17 points up, so these are matched relative-position probes, not identical absolute pixels.

## Identity and execution

All 532 source-manifest entries verified for each snapshot, using before-hit-target-probe/Theme-baseline.swift for baseline Theme and the then-frozen candidate source for candidate. The only source-manifest delta is ios/App/Theme.swift: move the font/frame into explicit Button Text label, set minimum width/height 44, add Rectangle contentShape, preserve action/instrumentation/identifier. Test source is byte-identical. The 179 recorded product file hashes match all 179 corresponding files in each preserved products.tar.gz. See hash-verification.json and source-delta.json. Archived products were read and hashed, never executed. Capture's own frozen-inputs-unchanged.json also reports source/products true in both runs.

Both use the same single selector StockReviewUITests/testDiagnosticDoneTouchTargetMargins, contributor Debug conditions (DEBUG CONTRIBUTOR_CAPTURE_UI_FIXTURE STOCK_REVIEW_UI_FIXTURE AWAY_CARRYOVER_UI_FIXTURE), Xcode/SDK 27.1 xctestrun, iPhone 17 arm64 iOS 26.2 build 23C54, no parallel testing, and original 720/900 execution allowances. Fresh distinct owned simulators are recorded in test-summary.json. One test executed per bundle, no retries: baseline failed the intentional all-five assertion at 91.966s; candidate passed at 82.544s. Strict verifier exits 1/0 respectively. Both report zero runtime warnings. This is local Xcode 27.1 evidence, not hosted Xcode 26.3 equivalence.

## Capture limits

Live baseline stream: 74 events, five PIDs; persisted export: 39 events from only PIDs 77989/78052/78102. Live candidate stream: 110 events, five PIDs; export: 87 events from only PIDs 79303/79351/79387/79426. Every exported (PID, monotonic uptime, event, site) tuple exists in the corresponding live stream. Baseline export omits the center and topLeft launches; candidate export omits center and one further event. Therefore persisted export is explicitly incomplete. Both capture-alive-before-stop markers are 1, which proves process liveness at that check, not exhaustive log delivery. Positive events are direct evidence; absent baseline margin Done events are supported by independent keyboard-visible results, not assumed guaranteed log completeness. See probe-event-verification.json.

## Scope of probe design

Five samples do not map every point of a 44×44 region or prove every accessibility modality, device, locale, font size, toolbar context, or real finger contact. All four baseline corner x offsets are within the original 41.67-point width, so the negative baseline primarily demonstrates missing vertical margins; it does not isolate a horizontal-width defect. The test samples four points 4 points inside the candidate bounds rather than exact edges. Frame center is the AX-derived anchor, not an independently measured original outer wrapper. Screenshots and synthesized taps support the intended toolbar locations. Each probe begins with a fresh reset app and focused amount field, avoiding dependence on the preceding probe's keyboard state. The four-second dismissal observation could conflate delivery with transition failure on its own; the matching Done and keyboard event evidence discriminates this run. No evidence here establishes that central taps causing the hosted idle stalls would be repaired by this geometry change.
