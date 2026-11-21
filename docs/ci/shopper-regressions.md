# Shopper regression checks

Ordinary pull requests and merges into main run the iPhone model and UI suites. The full iOS test plan checks that the named shopper regressions reach an enabled shard. The existing result checks verify that each selected case ran and passed. Use the shard log and its XCTest result to investigate a failure. The public website also runs its bilingual and browser interaction tests in CI.

When fixing a shopper issue, exercise the visible control that caused it, including its original language, text size and device conditions. Verify the consequence a shopper cares about. For example, after changing tomorrow’s four-serving dinner to tonight for two, reopen the meal and the reusable recipe. The meal should now serve two and the reusable recipe should still serve four. A test that stops after tapping Save misses that regression. If a test is renamed or replaced, update its required selector and keep the same outcome covered.

For a fix that changes what a shopper sees, include a before-and-after replay of the affected trip in the pull request. Record the shopper goal, device settings, build and what survived reopening. Include the automated regression and disclose any step that still needs assistance. For a release-wide experience score, repeat the complete walkthrough below. Unit and UI tests verify outcomes on each build. A new observed score requires a new walkthrough.

## Repeat the experience audit

Use the [120 original criteria](shopper-criteria.csv) to compare a release candidate or a changed journey with the last measured build. Record both build identifiers. Start each participant with the original task, equivalent fictional data and the same device settings. Keep the route, prior score and expected answer out of the participant brief. Save the participant’s own impression before revealing any rubric.

| Journey | Outcome to revisit |
| --- | --- |
| Short grocery list | Correct a misspelling, save Produce, undo checking the wrong item and verify what is still needed after reopening. |
| Pasted shopping note in Spanish | Resolve a possible repeat, correct a count, keep an optional quantity, then read back each item. |
| Pasted recipe | Preserve the original note and add only the selected missing ingredient to the named grocery list. |
| Dated dinner | Change one occurrence’s day and servings. Verify the dated meal, recipe and groceries on return. |
| Packaged pantry food | Record an unopened package already at home. Keep the label wording and a personal check date distinguishable. |
| Pantry use in Spanish | Record an unmeasured use against the intended storage location, then ask how much remains. Check both lots. |
| Receipt from Files | Review an amount printed below its item and keep part of the food in its chosen location. Recover all receipt decisions. |
| Receipt correction | Correct the printed line and accept its paid value. Confirm only the intended amount reaches Pantry. |
| Pack comparison | Choose whole packs under the item budget and recover the reason for the choice, including leftover food. |
| Shelf price and pickup | Correct a shelf price in place and keep a local pickup with the known can count. Verify no duplicate price or order. |
| Private list copy | Preview only selected groceries and cancel. Return to the same list without sending a message. |
| Family help | Explain the child’s role and the guardian’s first action, find support, and return to the same unchecked groceries. |

Rate only observed decisions, with a screenshot, action log or saved-state readback. The anchors are 100 for independent first-attempt success with a clear cue, 75 for success with minor effort, 50 for a recoverable detour, 25 for partial or assisted success, and 0 for a blocked or materially wrong outcome. Missing observations stay unscored.

Within each trip, average the observed decisions in each domain. Weight correctness and trust (O) 35%, effort and findability (E) 25%, comprehension and feedback (C) 20%, inclusive access (A) 15%, and return value and continuity (R) 5%. Show the raw score and any consequence ceiling. A harmful irreversible commitment, unintended disclosure or lost data caps the trip at 25. A blocked or materially wrong core outcome caps it at 49. A core task completed only with assistance or an undocumented workaround caps it at 69.

A full round requires 12 equally weighted trips, each with at least 25 observed criteria and two in every domain. For a before-and-after comparison, use shared decisions for the same task, retain both original grades and list any exclusions. Report each worsening trip and lost outcome alongside the average. An individual fix can be checked with a targeted replay and its own results. Record comprehension, visual judgment, unexpected taps and needed assistance separately from automated pass counts. Keep simulated participants and recruited human observations identifiable in the report.

The [required test list](../../scripts/ios_shopper_regressions.json) maps each journey to the exact compiled tests that protect it. After two full walkthroughs, run the score comparison against their evidence directories.

```sh
python3 scripts/compare_shopper_journeys.py path/to/before path/to/after --fail-on-decline
```

Each directory contains numbered folders 01 through 12 with trip.json, ratings.json and the cited evidence. The comparison prints both scores for each journey, and flags an individual decline even if the overall average rises. An insufficiently observed trip withholds the cohort score. Where the same criterion covered different decisions, pass the reviewers’ JSON list with `--exclusions`. Each entry identifies the shopper, criterion, judge and reason. A fresh walkthrough supplies the evidence for an experience score.
