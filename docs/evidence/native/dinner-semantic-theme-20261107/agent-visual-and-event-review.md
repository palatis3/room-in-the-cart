# Run5 event-only and Dark rendering review

Run5 is a successful instrumented nonreproduction: native 0 / strict 0, Dark 211.673 s and Light 196.964 s. The inspector records one start/pass per selector and zero runtime warnings; root reports no skips/restarts and owned-simulator cleanup. This does not repair or erase run4's Dark timeout/restart. No product fix or optional-layer experiment is justified by a healthy event sequence alone.

## Event evidence and capture limits

Both narrow log digests independently match their summary/receipts. Dark PID 36828 and Light PID 37385 use instrumented image UUID 8AD68CA9-B297-3C0F-9092-F2C021288CE5. Live capture has contiguous diagnostic sequence 1–128 and one cap marker per PID; each contains seven Done entry/exit and seven hide pairs before the cap. There is no evidence for later app-handler events after that intentional cap. Live contains 163 idle replies and 64 unmatched-stop framework warnings per PID but zero requests because its predicate omitted “animations are idle.” Persisted capture supplies 163 requests and 163 replies, plus 64 warnings, per PID. Framework warning counts are not XCTest runtime-warning counts.

Persisted logs retain no Dark diagnostic payloads and only Light sequences 121–128 plus its cap marker. This observed disagreement demonstrates why persisted absence cannot be interpreted as missing app delivery. Live collection ended exit 0 on SIGINT; persisted export exited 0 within its recorded narrow invocation window. Neither is a complete global animation trace. Request messages lack correlation IDs, so equal totals do not prove individual request pairing.

First Done, using only live envelope timestamps:

| Boundary | Dark | Light |
| --- | --- | --- |
| done.enter, focus title (1) | 02:25:40.948307 | 02:29:07.796475 |
| done.exit | 02:25:40.948419 | 02:29:07.796605 |
| received willHide | 02:25:40.976274 | 02:29:07.824513 |
| focus.change title→nil (0) | 02:25:40.981469 | 02:29:07.829400 |
| received didHide | 02:25:41.382767 | 02:29:08.234196 |
| idle reply | 02:25:41.384808 | 02:29:08.239055 |

All times are 2026-11-07 -0500. done.exit still reads focus 1 immediately after the original focus-nil assignment; the later focus.change to 0 positively observes the update. This is not a stuck-focus finding. Live didHide→reply intervals are 2.041 ms and 4.859 ms. Persisted copies of framework events have slightly different envelope timestamps, so do not splice sub-millisecond ordering across captures. Notification payload duration is 0.0 here, while observed hide notification separation is about 0.4 s; it is not a guarantee of instantaneous/global animation completion. No layer probe was enabled, and app events cannot establish remote keyboard/XCTest tracking state.

The successful chain resolves what this healthy invocation did. It does not supply the missing Done/focus events from uninstrumented run4, identify a cause, or show instrumentation fixed anything. Instrumentation, fresh process/runtime history and run-to-run variability remain confounds. Keep event-only instrumentation outside production; retain optional layers for a later concrete question rather than broadening now.

## Actual Dark images and AX

Reviewed six exact PNG/AX pairs, with hashes and color-report bindings in manifest.json. PNGs are 1206×2622 for a 402×874-point screen (3×); full rendered inspection was combined with AX bounds. Color-frequency reports corroborate presence only; no numerical per-element contrast or every-touch-target certification is claimed.

- **Idea review actions:** one mint filled Accept idea with dark label; mint secondary Save editable draft and Continue editing on the dark working surface. All three labels are complete and separate. AX rows span y585–667, 667–719 and 719–771; tab bar starts y791. No bottom-bar overlap in this final ordinary-scroll capture. The earlier recipe heading at the top is behind the native navigation fade, not a primary-action clipping defect.
- **Idea review supply:** title, servings 2, Wraps 4 units, review caveat and supply quantities are readable; the supply-review action is mint. Accept idea is partly behind the tab bar at this scroll position (AX y777.67–859.67); this capture alone cannot certify its visibility. The subsequent actions capture and unchanged v4 hittability/frame assertions establish that ordinary scrolling reveals it and both secondary actions. Do not describe both screenshots as having all actions visible. The supply button's reported AX label frame is only 20.33 points high despite its surrounding source frame modifier; no 44-point effective hit-region claim is inferred from the screenshot.
- **Reusable review:** title, 3 servings, Wraps 6 units, Dinner group 3 servings and both actions are complete. Save accepted dinner is filled and Continue editing is a distinct secondary action, well above system bars (rows y385–467 and 467–519).
- **Completion:** the two-line saved message and filled Done are complete on the working surface, with Done row y188.33–270.33. No overlap or clipping observed.
- **Reusable top:** filled title, servings 3 and multiline Notes are readable; empty source/exclusions/lead/completed prompts remain visibly secondary on the surface. Ingredient content entering the lower native fade is not used to certify its readability at this scroll position.
- **Idea assumptions:** secondary assumptions prompt, both off switches, explanatory text, secondary Add serving group and filled Review are readable in the content region. These are the earlier empty-idea state; later exact switch checks and idea-review captures are separate. The upper Add ingredient row is partly under the navigation fade and is not used as action-visibility evidence here.

The last two images corroborate current completed-run field/prompt rendering; the other secondary surfaces already have the separate run2 partial visual review and were not redundantly declared re-reviewed here. No new central-content clipping was found in these six images. This remains ordinary English/default-size, diagnostic-build evidence, not full VoiceOver, largest text, Spanish, disabled/error-state or whole-app acceptance. Independent S14/Spanish behavior validation on normal run4 products remains separate. IdeaSupply and DinnerFeedback follow-up deltas are not present in run5.
