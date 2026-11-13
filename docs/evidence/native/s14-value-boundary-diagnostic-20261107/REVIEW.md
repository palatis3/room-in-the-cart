# S14 hosted failure review — pinned 1080fad

Verdict: the available evidence establishes an input-value boundary failure, but does not establish a product persistence bug, a keyboard/focus cause, or an incorrect native value. No causal product patch is proposed. The separate test-only patch captures the missing public observations while preserving the failed decision and exact assertions.

## Exact failure boundary

- Candidate: `1080fad4999cb6c4ff34c20e99e5b72247e23e23`; Core run 42352333755, attempt 1, ui-01 job 128344458144. Sol's pinned proof verifies the checkout merge tree against the candidate.
- `FreeJourneyUITests.swift:613` calls `enter("8", "Current amount for this group", replacing: true)` after manual quantities have changed from 3/3/6 to 4/4/8. Stale portion bindings are intentionally discarded by manual quantity edits, requiring explicit re-entry.
- The helper fails at line 529: the existing native `value == "8"` predicate does not complete within its unchanged five-second allowance. The later exact equality at line 531 is not reached because `continueAfterFailure` is false.
- Hosted log records tapping this text field, typing an empty deletion string, typing `8`, checking an optional Done control, and the failing predicate. This sequence proves attempted input, not focus, actual field value, or which subsystem caused the mismatch.
- The new binding save at line 614, reopening at line 616, restart at line 621 and persistence assertion at line 627 have NOT occurred. This failure cannot be labeled a failed save/restart persistence assertion.
- Structured failed duration: 292.9422519207001 seconds. Native lane: 3 executed, 2 passed, 1 failed; strict exit 1; no runner restart. No new execution was performed by this review.

## Compared prior passing evidence

The earliest `docs/evidence/native/recipe-source-editing-20261107` run passed this test in 215.623 seconds. Its original Notes-label fix addresses a different field/boundary and is already present in the hosted candidate.

The closer `DinnerThemeReview20261107/run4/independent-regressions` normal, noninstrumented run passed the unchanged S14 test in 222.074 seconds, including entry of 8, saving, reopening, restart and all original-value preservation assertions. The retained source manifest binds nine reviewed production sources byte-for-byte to the candidate: Theme, DinnerEditors, DinnerWeekEditors, DinnerDrafts, DinnerFeatureModel, DinnerDecisionSheet, DinnerAccessShield, DinnerPlanningHome and RoomInTheCartApp. These include the semantic-theme changes made after the earliest run.

The S14 method and shared fill, reveal, tap, launch, restart and dinnerRoot methods are byte-identical between that retained run4 test source and the hosted source. Full test-file differences consist of scratch visual methods in run4 and a later unrelated share-readiness diagnostic in the candidate. `closest-passing-source-comparison.json` records file/method hashes; `run4-to-hosted-test-source.diff` preserves the comparison. This is historical source-bound success, not a current execution result or proof that the hosted failure is harmless.

## Product-path review

DinnerGuestsView owns its binding drafts in State and renders the current amount through a text binding. DinnerBindingDraft starts from the existing allocation or an empty string. Saving remains explicit. The inspected view/model code does not identify a deterministic reset between this tap and value assertion. A periodic access shield and the lack of a focus assertion are observations, not demonstrated causes. No success, provider result or persistence outcome is inferred.

## Small diagnostic proposal

`s14-failed-value-diagnostic.patch` changes only S14's local assertField helper against the exact hosted source SHA256 `95fdc9cd634864757db3a5289ee31bedb7688af57b734f3a36fcc63170afc707`.

It stores the existing five-second waiter result. Only after that result fails, and before the first assertion or any save/navigation/teardown interaction, it attaches the field's actual native value, placeholder, label, identifier, existence, enabled/hittable state, frame and software-keyboard presence. Observations happen after the fixed failed decision and may themselves require native snapshots; they are not simultaneous measurements at the exact timeout instant. Keyboard presence is not proof of focus. No unsupported/private focus API is used.

The original query, five-second allowance, completed-result assertion, native exact-value equality and every later persistence/recipe assertion remain unchanged. There is no retry, refocus, retype, value substitution, broad helper change or production edit. This is diagnostic instrumentation, not a fix, and needs root-owned compilation/native validation if selected.

## Evidence limits and handling

Sol retrieved only bounded selected summary/test-node/plan/log members. Those show “Capturing element debug description” but do not contain the captured AX value/description. No screenshot, activity payload or result bundle was retrieved or inspected in this review. Full archive digest is intentionally unverified; selected members were checked by Sol. See the pinned `ui-01-proof/REVIEW.md`, `verification.json` and range-download receipt.

All work here is source/read-only investigation plus isolated synthetic scratch outputs. No main source, Git, hosted state, native tests or simulators were changed. No Records raw artifacts were accessed or written. Root owns any integration and reproduction. Keep CI S14 unresolved until actual boundary evidence supports a cause and a validated change.
