# Balance the existing five CI slots

Move only Swift CodeQL from shared slot2 to slot4, with its exact workflow-policy pin. The original0d5cohort placed33m05s of measured CodeQL work on the longest lane while slot4had the least completed work. This is a bounded backlog-balancing change, not a guaranteed wall-time reduction or provider-capacity claim.

All matrices, selectors, order within jobs, dependencies, runtimes, timeouts, acceptance gates, queue settings and cancellation rules remain unchanged. Fourteen native definitions still share only the original five groups. The final ApprovedProposal and StaleReviewedSave fixture pair still shares slot2; this change does not directly make them overlap.

The existing17workflow-policy,4slot-policy and23planner tests pass. Actionlint plus the unchanged narrow queue-key bridge validates all14queue nodes. Independent review confirms exactly two one-line edits and matching snapshots. The first driver resolved a virtual-environment interpreter symlink to system Python and lacked PyYAML; those setup failures are retained. Only the two affected checks were rerun with the correct pinned-environment path; no dependency or policy relaxation occurred.

No current run was cancelled, retried or superseded. A future cohort must establish actual scheduling effects. The retained timing review explains evidence and limitations; validation.json proves that the rest of the parsed workflow and all matrix producers remain identical.
