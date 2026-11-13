# Attempt 6 Discard misdispatch: independent review

The retained evidence establishes an application defect: selecting the presented Discard action was followed by a durable save of the change that should have been discarded. Applying `.buttonStyle(.borderless)` independently to both recovery buttons is a narrow, source-supported correction. No additional model change is indicated by the current evidence. This review is not a fixed-run result.

## Evidence chain

The host's retry-verified snapshot and its discard-failed snapshot are exactly equal to `post-discard-readback.json.before`: durable head/revision count 2, one import batch, two contributions, recovery wraps count 2 and recovery pears count 3, payload SHA256 `ec4cd39ad1764c0c6218eb395c6f83675bb146fe292f3d6e8d3433ccc26e8cf5`. The second failed save therefore did not commit while the host held its writer lock. Both held transactions record totalChanges=0; the second lock was released before the recovery action.

The retained discard-before-tap observation has two global Discard hierarchy matches, exactly one hittable: the presented action at (32,587.67,201.67,187.33), and an inaccessible underlying action at (32,1000.33,201.67,187.33). The test targets Discard within the single ledgerImportForm, not a global first match. Native log lines 1234–1241 record one Discard tap at 210.94s, synthesized event at 211.07s, and no import Form at 212.08s. There is no second Add or Retry tap in this interval. The retained failure screenshot also shows the underlying shopping screen after the import review disappeared.

Post-discard readback independently records head/revision count 3, two batches and three contributions, including a new imported `discarded oat jars` line at count 4. This is durable mutation, not just sheet dismissal or an accessibility-query failure. The test aborted on the vanished Form, before its final discard-cancelled verification; do not describe that final verification as executed or passed. The separate readback supplies the durable failure evidence.

## Source mechanism and alternatives

LedgerSaveStatus puts Retry and Discard inside the same VStack used as one Form/List status row. Before the fix both used the container's automatic button style. Its Retry handler calls model.retrySave and invokes onRetried on success; the import sheet supplies dismiss as that callback. Its Discard handler only calls model.discardPendingSave and has no dismissal callback.

The reviewed LedgerModel is byte-identical to attempt6's source manifest. retrySave writes the retained pending payload via store.save; discardPendingSave only reloads store.load, clears pending state and error, and never saves a new payload. Both guard saving. If a row interaction dispatches the Retry task first, it sets saving=true before awaiting storage, so Discard can then return at its guard while Retry saves and dismisses. That sequence fits both durable mutation and sheet disappearance. The row dispatch explanation is strongly supported by source and observed results, but no closure-entry instrumentation was captured; it should not be described as a direct trace proving both closures ran.

A hidden duplicate button alone does not explain this failure because the selected target was Form-scoped and the retained global hit test shows one accessible foreground Discard. An accidentally triggered Add is also not supported: Add was disabled while pending, its model change path refuses another mutation while pending exists, and the failure interval logs only Discard. The ordinary failed Add had already returned its save error and the host verified unchanged durable state; no automatic LedgerModel retry scheduler exists in the reviewed call sites. The observed behavior is consistent with Retry dispatch from the shared recovery row, rather than a write in discardPendingSave.

## Fix scope and verification

The exact current LedgerHomeView diff adds a comment and `.buttonStyle(.borderless)` directly to each of the two buttons. Both need an explicit independent style; leaving Retry automatic would leave a row-level recovery action available. Button labels, destructive role, accessibility identifier, saving-disabled guards, async handlers, callbacks, model behavior and SQL semantics remain unchanged. The same component is used by several Form/List surfaces, so the correction applies consistently at the shared component. Existing nearby list-row controls already use borderless styling.

Preserve the exact attempt6 native method and unchanged host protocol for the negative-to-fixed comparison. A sufficient fixed outcome includes successful Retry once, two unique persisted contributions after restart, Discard leaving the review open and re-enabling Add, Cancel/restart showing the discarded text absent, host discard-cancelled snapshot exactly matching retry-saved, final done, and native exit zero. Hittability/geometry observations and screenshots should remain retained. No additional model edits or weakened assertions are justified before this comparison.

This agent read retained JSON/logs and the screenshot, inspected source and a read-only diff, and wrote only this report plus hashes. It did not run native code, invoke simulator control, access a database, edit source, or rerun tests. Artifact hashes are in discard-fix-review-hashes.json.
