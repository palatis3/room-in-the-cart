Candidate `23a73a890afbaa23d3c58ae6b0cf63a8b2e2fb71`, fixture run `42021894739`. A worthwhile candidate change is batching13 contributor suites into five balanced whole-suite groups:22→14 jobs, preserving the existing seven shared-editor singleton journeys, Records privacy isolation and the separate dinner profile.

Exact inventory:44 selectors (39 contributor,5 dinner). Twenty strict-accepted jobs cover42 cases. Known-trip native assertions passed659.362s but strict warning validation failed; Records reports one failed case through the safe redacted report only. Both original results remain failed.

Groupable suites contain80.5 case-minutes but each job adds median358.7s non-case work (range308.7–620.1s). Median post-last-suite work inside the test step is11.7s, including finalization/exports/guard; export time alone is not exposed. Current22 jobs consumed273.4 Mac runner-minutes.

| Whole-suite groups | Total jobs | Modeled runner-min | Ideal five-slot wall, longest/feedback first | Largest grouped case sum | One900s case/group test-step screen, high overhead |
|---:|---:|---:|---:|---:|---:|
| 13 | 22 | 269.9 | 58.0/59.3min | 14.1min | 31.0min |
| 8 | 17 | 240.0 | 52.0/52.8min | 14.1min | 32.1min |
| 6 | 15 | 228.1 | 46.1/52.6min | 14.1min | 35.3min |
| 5 | 14 | 222.1 | 47.2/49.3min | 16.9min | 38.3min |
| 4 | 13 | 216.1 | 46.9/49.4min | 20.8min | 42.2min |
| 3 | 12 | 210.2 | 43.6/46.9min | 27.6min | 49.0min |

The five-group option saves an estimated47.8 runner-minutes of repeated setup versus13 separate groupable jobs. Group bodies span14.8–16.9min. Three/four groups save more setup but leave less room for a slow case under the unchanged40-minute test-step limit. The14-job design is an estimated setup saving pending fresh grouped hosted validation, not a measured end-to-end speedup.

Actual fixture completion was118.7min after both builds were ready; first fixture started11.5min later and fixture concurrency peaked at5. Five runners are shared with other workflows. The queue-free simulation cannot predict those waits. Both-profile build dependency stays unchanged (it held dinner eligibility by11.6min).

The exact proposed selector lists and suite membership are in proposed-14-job-groups.json and proposed-selectors/. All44 selectors occur exactly once. Source review found explicit fixture launches/app termination and initial reset patterns; simulator/runner state interaction across newly adjacent suites remains the material validation risk. No assertions, resets, timeout limits, retries or guards should change.

Minimal implementation: teach shard_members a fixed five-group whole-suite ownership map, validate profiles/Records/editor exclusions, keep compile/source inventory validation before grouping, and retain current dynamic workflow count/selector loading. Add coverage/protected-isolation/new-method and invalid-map regressions. The existing workflow already supports multi-suite selector lists; only planning label/comment needs clarification.
