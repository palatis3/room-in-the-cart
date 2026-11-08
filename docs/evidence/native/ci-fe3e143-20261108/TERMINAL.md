# Published fe3e143 cohort — terminal

All six workflows are terminal as of November 8, 2026, 20:51 UTC. The authenticated workflow/job inventory is retained in `terminal-workflows.json`. No rerun, cancellation or replacement push was used.

| Workflow | Result | Jobs passed / failed |
|---|---|---:|
| Deep checks | Passed | 4 / 0 |
| Security | Passed | 3 / 0 |
| Native Swift HTTPS and PostgreSQL | Passed | 1 / 0 |
| Build and test | Failed | 18 / 2 |
| Fixture checks | Failed | 18 / 2 |
| Release performance | Failed | 3 / 1 |

These are job counts, not test-case counts. Four failing execution jobs need follow-up; the fifth failed job is the aggregate CI gate:

- UI01: the English dinner-pattern journey exceeded its 720-second execution allowance. UI02–10 passed. [Retained failure](early-failures/README.md).
- Scroll performance: an iteration reported three metrics versus four initially. Launch and rendered-screen performance passed. [Retained failure](early-failures/README.md).
- Shared cook recovery/closeout: four cases passed and the recipient-copy case failed because confirmation remained off after the switch tap. Its runtime warning inventory is also unavailable; that is a separate unresolved evidence failure. [Retained failure](shared-cook-failure/README.md).
- Known/unknown store quote adoption: the offscreen break-even target could not be resolved during a live snapshot lookup, before its dollar-value assertion. [Retained failure](known-trip-failure/README.md).

The cohort is not green and does not establish release readiness. Local accessibility and regression improvements after this commit have separate scoped evidence. Qualify the prepared follow-ups before the next deliberate push; the previous reason to hold a push (unfinished cohort) is now resolved.
