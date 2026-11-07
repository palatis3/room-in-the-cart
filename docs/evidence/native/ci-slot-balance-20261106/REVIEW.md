# Five-slot scheduling tail review — candidate 0d5bb1b

The retained evidence supports **serialization imposed by the static slot assignment**. It does **not** establish a shortage of provider runners. Five is the configured maximum across shared macOS slot groups, not a guarantee of five simultaneous jobs or a pool from which any queued job can take an idle slot.

The source/current workflow and planner files inspected are byte-identical to frozen `0d5bb1b22e9e84cd4b8c2b07317f91cfc703b60c`. `ci_mac_slots.py` assigns and validates `index % 5`. Fixture row 7, ApprovedProposal, and row 12, StaleReviewedSave, therefore both use `ritc-macos-slot-2`; row 2, contributor-balanced-01, does too. The fixture workflow has `max-parallel: 5`, but each row is still pinned to its individual group. All native leaf groups retain `queue: max` and `cancel-in-progress: false`. Matrix parallelism cannot remove a same-group collision.

## What the timestamps establish

Four retained fixture snapshots from **02:23:24.904008 through 02:34:55.363989 UTC on 2026-11-07** show ApprovedProposal as the only executing fixture and StaleReviewedSave pending. The other five cohort workflows were terminal by 02:22:59. ApprovedProposal subsequently succeeded and StaleReviewedSave acquired a runner; the earlier pending state is not an unresolved provider failure.

| Slot 2 job | First step | Last step | Runner step span |
|---|---|---|---:|
| contributor-balanced-01,128237134973 | 01:40:45 | 02:03:01 | 22m 16s |
| core UI07,128243330965 | 02:03:08 | 02:22:50 | 19m 42s |
| ApprovedProposal,128251753602 | 02:22:56 | 02:35:17 | 12m 21s |
| StaleReviewedSave,128265229305 | 02:35:24 | Still active in reviewed snapshot | Incomplete |

ApprovedProposal's native step ran 02:26:18–02:34:44. Its job completion was 02:35:20; Stale's job start was 02:35:23 and first step 02:35:24. These short successive gaps support an occupied-slot explanation. They do not identify every scheduler/provider transition or prove that another runner would have been supplied immediately on a different slot. The current retained state has progressed to **StaleReviewedSave executing**, not ApprovedProposal executing.

All known work assigned to slots 0, 1, 3, 4 had completed its final step by 02:08:15,02:14:42,02:16:02,02:02:22 respectively. These are observations for the six-run cohort, not a claim about provider-wide capacity or unrelated repository jobs.

| Slot | Completed runner-step seconds | Completed macOS job instances |
|---:|---:|---:|
| 0 | 6,976 (116m16s) | 10 |
| 1 | 7,367 (122m47s) | 9 |
| 2 | 8,611 (143m31s), excluding active Stale | 8 |
| 3 | 6,550 (109m10s) | 7 |
| 4 | 4,738 (78m58s) | 5 |

This is one cohort, including failure paths that may shorten execution; Stale is incomplete. It is not a validated scheduler speedup. These sums use each job's first and last step, including setup/cleanup. They are neither CPU time nor total workflow wall time. Slot 2 also carried performance-build, English StoreKit, Swift CodeQL, UI02 and scroll. Swift CodeQL alone occupied33m 05s. Dependency readiness, fixture matrix admission and provider acquisition remain distinct potential contributors; this review does not assign all waiting to one cause.

## Smallest evidence-backed next change

**First recommendation: move only the fixed Swift CodeQL job from slot 2 to slot 4 for a future candidate.** This requires changing the one concurrency-group value in `.github/workflows/ci.yml` and its exact expected value in `scripts/check_ci_workflows.py:POLICY`. Slot4 is the lowest-load lane in this cohort, while the measured33m 05s CodeQL job is on the longest lane. Reassigning that measured work gives illustrative completed-work totals of 6,626s on slot 2 (still excluding Stale) and 6,723s on slot 4. This is load arithmetic, **not a predicted wall-time saving**.

This change leaves `index % 5`, every matrix row and row order, job identity, dependency, selector and within-job test order unchanged. It also preserves exactly the existing five shared group names, all 14 reviewed native leaf definitions, runtime/toolchain pins, limits, baseline/strict checks, `queue: max`, and leaf cancellation policy. It avoids a new scheduling framework. It can alter cross-workflow admission/interleaving, so a future cohort must retain first/last-step and pending-state evidence again. Do not apply or resubmit anything to the current cohort.

**Limitation:** moving CodeQL balances the earlier backlog; ApprovedProposal and Stale still collide structurally. If the specific requirement is to allow that final pair to overlap, the smallest direct policy change is one identity-keyed fixture override assigning StaleReviewedSave to slot 4 while leaving its row at index 12. The current validator deliberately rejects that override, so both assignment and validation must explicitly recognize that exact `(profile, shard)` identity, reject unknown/duplicate/out-of-range overrides, and retain all other rows unchanged. Do not silently weaken validation to accept arbitrary slots. A simple rotation/permutation of the five labels will not separate rows 7 and 12: they remain congruent modulo5. This direct override has a larger code/policy surface than the fixed-job reassignment; do not combine both changes without a separately reviewed comparison.

Before a future change, the existing workflow-policy, planner identity/order and lint checks should verify the intended exact assignment and reject an unreviewed sixth slot or workflow-specific namespace. No selectors, test grouping, retries, cancellation, timeouts or acceptance criteria need to change. No speedup or new native acceptance is claimed from this review.

## Retained inputs and scope

- Frozen core audit: `core-collection/FINAL-AUDIT.json`, SHA256 `ba6f5d36b85f06038c9f2a3c600ff0cf8b21032ccd038255612c7aadbefc8d2a`; its `freeze.json` SHA256 remains `f810a4206ba32d4ab97c09bede703427a713bfaf593bfa265c699304373226c0`.
- Fixture owner metadata: `fixture-collection/fixture-42316648586-jobs.json`, `fixture-scheduling-history.jsonl`, and the 02:36:31.930250Z owner snapshot. Aggregate completed spans were read with fixture state observed at 02:38:04.085788Z; Stale was still active and is excluded from completed totals.
- Current five participating macOS workflows, four slot/planner modules, and `check_ci_workflows.py` were compared byte-for-byte with the frozen candidate copies. Slot helper SHA256 `23e5dae583f1fc10b523348d034f66fad39196a16b7df179e5720221c22ec41a`; workflow-policy SHA256 `f2f7eba7c69cf5304a97aedfcb789b916c25a00096514f80494528bd2b6fd449`.
- Read-only metadata/source analysis and pure fixture matrix generation only. No unit/native tests, source or Git changes, hosted mutation, retry, cancellation, collector changes, or frozen-core modification. Fixture collection remains owned by its existing collector.
