# Independent product/UX recheck — plan v2

**Verdict: approve the implementation plan from the product/UX perspective.** All three material findings from my v1 audit are resolved. No new material product gap found in the revisions. This is not implementation, runtime verification, deployment or release approval, nor an assertion about the other judges' verdicts.

Reviewed immutable draft: `IMPLEMENTATION-PLAN-v2.md`, SHA256 **`491d032c7f246c89de6d02d677bf2e35c527ff7cbcf2b9a0717fe628c1c2b813`** (verified). Read the complete v1→v2 diff against my previously reviewed v1 and the original 28-feature request/preflight. Source baseline remains `e06bde5c`; PR #10 merge and final source freeze are still separately required. No code edits, builds, tests or CI dispatch.

## Material findings closed

1. **Standalone Tonight (#4): resolved.** V2 explicitly supplies Shop → My Pantry → Tonight and Dinners → Tonight, with workspace/authorized-household read context independent of the selected shop. Empty library/no matches gets recipe save/import/manual actions; one reviewed recipe enables offline matching. Browsing/cancel cannot create a pickup. Destination selection/creation is explicit and one confirmed choice creates one occurrence. The acceptance sequence covers no shop, no recipes and the use-soon route.
2. **Qualitative quantities (#2): resolved.** Some left/Have enough supersede earlier numeric availability with unknown while retaining historical counts. Existing reservations remain unresolved, Have enough can separately suppress prompting, and metadata-only opening/moving preserves count. The eight-wrap/two-held → unknown → recount-three example now verifies the desired two-held/one-free result and single application.
3. **Cooking with incomplete pantry tracking (#17/#26): resolved.** Used but untracked is distinct from Not used. Meal completion, known deductions, unresolved-use rows and independently counted leftovers have explicit outcomes. An identifiable lot with unknown use loses numeric availability; insufficient stock offers reviewed correction or unresolved use, never a negative/fabricated balance. Stable event lineage and later-count handling prohibit delayed double deductions. Acceptance covers tortillas, untracked salt, unknown oil, two real leftovers, retry and Undo.

## Additional revisions checked

- Navigation retains Shop/Dinners/Records and gives pantry, Tonight, cooking, feedback, settings and history concrete homes. Deleted/stale routes fall back without making phantom pickups.
- The tier contract keeps core manual/offline capture, pantry, use-soon, saved price evidence, cooking/timers/completion, feedback and first-task recovery Free. Deterministic Tonight/estimates/reminders introduce no new paywall; any existing-assistance mapping must be explicit or default Free.
- Preference read grants are separate from pantry edit rights; organizer-only preference writes prevent accidental authority expansion. Pantry counts do not automatically authorize named meal completion or reservation edits, preserving the distinction between physical truth and planning authority.
- Migration/pending-workflow and durable projection changes preserve conservative visible recovery rather than silently freeing stock or claiming compound success. These are appropriate product outcomes; detailed transaction correctness remains with the integrity judge and eventual verification.
- H1 can deliver useful Tonight/manual use-soon before verified FoodKeeper guidance; H2 remains required to complete estimated dates. J1–J4 separate real cooking completion, cooking UI/timers, meal feedback and staple prompts without dropping requested scope. Widgets still require actual opt-in dinner/use-soon summaries, not generic shortcuts alone.
- No regressions found in receipt review, natural multi-item speech, duplicate requests, two-store equivalent costing, single-dinner swap/Undo, reserved lunch behavior, consent, EN/ES/accessibility or account-free recovery contracts already reviewed in v1.

All **28** requested entries remain present (1–21, 23–26, 28–30). Remaining device/human verification and external-guidance content gates are labeled honestly and do not masquerade as implemented behavior.

## Editorial cleanup only

V2 contains literal leading `+` characters on several newly inserted paragraphs/blank lines and before the `### #1` heading. Strip those diff-marker artifacts when producing the final readable document. This is not a material plan correction; record the final artifact hash as usual. If subsequent edits change user outcomes or the contracts above, send that revision for another recheck.
