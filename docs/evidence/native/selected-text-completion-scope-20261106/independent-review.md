# Independent review: selected-text completion scope

**No blocking defect found in the two-file correction or deterministic regression fixture.** Pinning the composition nonce before the import and checking it after success or error prevents the old operation from restoring/clearing presentation state after background or an explicit scope-generation change. It leaves the durable confirmed import and acknowledgment recovery path intact.

## Production scope

`ios/App/DeviceSurfacesComposition.swift:289–309` adds only the captured nonce and two post-await guards, plus comments. Comparison with retained `negative-source` confirms no change to journal save, baseline CAS, bridge.commit, private scope validation, receipt validation or error recovery for an unchanged generation. The success guard also prevents an obsolete completion from clearing a later presentation or starting old reconciliation. The catch guard prevents journal readback, baseline restoration and stale error publication from that completion.

The existing `defer` still clears busy on both early returns. This does not clear a new operation's busy state: the composition's existing busy guard prevents another Add/review/recover from starting before the outstanding Add completes. Background/scope teardown increments nonce and clears draft/baseline; returning to the same authority later does not restore the old nonce, so the check fences that transition too.

A nonce mismatch deliberately skips only UI reconciliation. It does not delete the journal or undo an already confirmed SQLite write. In the tested path, `SurfaceImportBridge.commit` first stores `.committing`; `LedgerSelectedTextPort.commit` then saves through LedgerModel and rejects completion after its generation changes. Foreground/reopen can recognize the exact saved receipt, acknowledge the existing inbox operation and remove the journal without creating another batch. This preserves intentional recovery rather than treating confirmation as an unconfirmed draft.

## Test seam and assertions

`NativeCompositionStartupTest.swift:210–266` uses the already-supported ledger clock, passed through the existing fixture at lines 279–286. The hook is installed only after setup and review, so setup clock calls cannot trigger it. `LedgerModel.change:198–201` evaluates that clock while constructing the pending save, after candidate validation/encoding and before awaiting SQLite save. Bridge confirmation has already been written at that point. The hook backgrounds only the composition; it does not recursively edit the ledger, fake a store result, inject private data, change production scheduling or rely on sleeps/racing tasks.

All model work and the test are MainActor-isolated. The clock callback is synchronous. The direct Combine `$draft.sink` has no receive(on)/asynchronous delivery hop and examines its delivered value; it therefore observes a transient nonnil publication even if later reconciliation clears it. The initial subscription emission is ignored while `interrupted` is false. `interrupted` is set before background, and the hook runs once. The optional closure's capture cycle is broken immediately after Add and again with defer on every exit; the observer is cancelled with defer. Existing fixture callers retain Date.init by default.

Assertions cover: hook actually fired; no post-background nonnil publication; unauthorized presentation and nil draft; durable journal still `.committing` with exact approved preview/decisions; pending inbox receipt; exactly one saved import/revision; explicit foreground and reopen consume the same operation, remove the journal and leave one line/one batch with no second revision. This is meaningful persistence/recovery coverage, not a final UI-only assertion.

The negative log records exactly the intended transient-publication failure at line 240, one case failed in 0.479 seconds. The current regression file is byte-identical to the retained negative-source test. Thus the fixed check has not been weakened after observing failure. The root-owned positive suite completed before review finalization; its retained result verification follows below.

## Limits

This deterministically exercises the **error completion after background** with an actual committed ledger write. The success-side nonce guard and a different persona/workspace switch are reviewed structurally, not separately forced by this test. It does not simulate a real OS scene transition or assert native sheet pixels. It proves no republishing from this Add completion path, not that every asynchronous DeviceSurfaces method is race-free. Generation protection depends on existing lifecycle/scope invalidation continuing to increment nonce; the patch does not redesign that mechanism.

## Provenance

Both current files match `fixed-source.json`. Reviewed `fix.patch`, direct source and a read-only diff against `negative-source`; no Git commands, source edits, builds, test execution, native/network tools or agents. Only this report was written.

SHA-256:
- `ios/App/DeviceSurfacesComposition.swift`: `06443824f1943b77bd0dbf40103b973f1690a46cf014562e1fe0363c0a49a0fc`
- `ios/Tests/NativeCompositionStartupTest.swift`: `c673820baa07f7ee3edd3cbcd5e1873345a51fad94087c06e39b3fecca786e8a`
- `.build/SelectedTextCompletionScope20261106/negative-source/ios/App/DeviceSurfacesComposition.swift`: `6c55c3a9160c6dd2d6837a4d47972c109fcf3dfd601d4df641ec738aefbcbfa1`
- `.build/SelectedTextCompletionScope20261106/negative-source/ios/Tests/NativeCompositionStartupTest.swift`: `c673820baa07f7ee3edd3cbcd5e1873345a51fad94087c06e39b3fecca786e8a`
- `.build/SelectedTextCompletionScope20261106/fix.patch`: `532bbfc67dafa71aad1ede7feee451552c5b231b3546a978a733cfea90826732`
- `.build/SelectedTextCompletionScope20261106/negative.log`: `ad0242171ada596b1e60fec365b0218fa812a08bde796d43d3daeec35b96a3e5`
- `.build/SelectedTextCompletionScope20261106/fixed-source.json`: `5e453b375d1a61ddbeb73b7618eea7e2bf7691a6ec583666ced2163dfe2823e5`

## Terminal result verification

Independently read `fixed-summary.json`, `fixed-tests.json`, `fixed-strict.log`, `fixed-strict-exit.json` and `fixed.log`: **31/31 cases passed**, zero failed/skipped, strict exit 0, zero runtime warning occurrences, one start and one passing completion per selected case, and no test-runner restart lines. The new `testBackgroundDuringConfirmedImportDoesNotRepublishReviewAndStillRecoversOnce` passed in **0.24745607376098633 seconds**. The same scoped run includes the prior cancellation, interrupted acknowledgment, prior-confirmed-attempt, racing-receipt and real-ledger restart checks. No compiler diagnostic warning lines were found in this fixed run log.

Both reviewed current source files still match their `fixed-source.json` hashes above. Root reports separately checking all 457 manifested files; this review independently rehashed the two reviewed files, not that entire tree. This positive result supports the stated deterministic error-path/persistence correction and does not extend the native/success-path/other-method limits above. No additional execution was performed.

Result SHA-256:
- `fixed-summary.json`: `542e2875aef3991332823c4a5c41db353c7f4d5e1f35e0016a398702fc892d0f`
- `fixed-tests.json`: `3ea106743bdb12f07cd71d229b5740784ef80fb8c72a1e882a5598c075b05ca8`
- `fixed-strict.log`: `0c60c0c0463826eefe5fe336e511ce4a70215754b4947ce5a9cb8ac1d846d563`
- `fixed-strict-exit.json`: `982b9e9bfb10ffe83cad665807abcfd3fa97b37822db5ab7831157a499548a9e`
- `fixed.log`: `2dad51a8e5bacf4a9e375ecbca7564bf159eb3b770b765d0e7a0f0e979f70db7`
