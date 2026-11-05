Candidate `23a73a890afbaa23d3c58ae6b0cf63a8b2e2fb71`, ordinary run `42021894668`. Keep ten UI groups for now and review only the accepted-duration update.

Evidence covers51 terminal cases:33 strict accepted passes,15 raw passes in three failed artifacts, two720-second timeouts, and one348.256-second Reduce Motion Close-readiness assertion failure. All failures remain failed; this is not a green candidate or a complete strict passing suite.

Successful UI jobs spent290–442 seconds outside individual case durations (median363s). That includes boot, XCTest startup, exports/guard and upload; queue waiting is separate. The build dependency cost652s, including297s in the combined boot/enumeration/planning step. Peak observed matrix concurrency was four although max-parallel permits five. Matrix completion was99.8min after build ready; the five-runner projections below exclude observed queue contention.

Minutes, using dedicated five-runner simulations; runner-minutes include all UI setup plus the observed458-second model job. Nominal uses48 fresh per-case passed observations plus older passing estimates for three currently failed cases. Failure stress uses their actual failed elapsed durations, never as passing weights.

| Plan | Nominal runner-min | Nominal wall (declared/LPT) | Failure wall (declared/LPT) | Largest failure test step, approximate |
|---|---:|---:|---:|---:|
| old-10 | 225.0 | 48.9/48.7 | 56.6/52.4 | 33.5 |
| strict33-5 | 194.8 | 44.5/43.1 | 52.7/52.7 | 49.9 |
| strict33-8 | 212.9 | 49.6/49.6 | 52.2/51.7 | 38.2 |
| strict33-10 | 225.0 | 51.1/49.7 | 53.9/53.4 | 30.2 |
| strict33-12 | 237.1 | 55.3/54.9 | 57.3/57.3 | 26.6 |
| strict33-isolate-twoTimeouts-10 | 225.0 | 58.0/49.0 | 63.4/53.2 | 25.4 |
| strict33-isolate-allThreeFailures-10 | 225.0 | 65.1/50.7 | 65.7/51.4 | 29.7 |
| strict33-isolate-twoLongestStrictPasses-10 | 225.0 | 57.4/49.0 | 69.9/53.9 | 35.8 |

Five UI groups save about30.3 runner-minutes of repeated setup versus ten, but the failure workload can breach the40-minute test-step limit. More groups shorten individual jobs but add setup; no tested increase demonstrates a reliable total-time improvement. Dispatch order materially changes modeled wall time, so balanced case sums alone do not establish fastest completion.

Isolating known failing selectors within ten total groups can make their first-wave artifacts available sooner; this is a feedback tradeoff, not a measured speedup or a repair for either keyboard timeout. Isolating the longest passing cases has no demonstrated benefit. The current checkout-only group arose from a1000s local fallback; its new hosted case took336.915s and no longer warrants that weight.

The scratch patch updates only33 strict accepted per-case weights, rounded up. Notable changes: checkout1000→337; long paste300→66; PickupOffer715→557; pairing79→145; main FreeJourney546→636. Older failed-case estimates remain unchanged. The15 raw passed observations are retained separately for sensitivity, not promoted to strict acceptance. No shard count, coverage, retry, test body, timeout or result/warning guard changes are proposed.

The42 comparison configurations, per-case provenance/hashes and exact hypothetical selector sets are in comparison.json, report.json and hypothetical-plans.json. Every alternative preserves51 ordinary selectors exactly once and580 model selectors. Existing six Python planner tests and git apply --check passed. No shared edits/native executions/hosted mutations; no Records artifacts were accessed.
