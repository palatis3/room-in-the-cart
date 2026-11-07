# Permanent S14/S26 CI integration review

**Required CI-policy edits: none.** After root accepts the exact native outcomes, integrate the unchanged S14 method into existing `ios/UITests/FreeJourneyUITests.swift`, the two S26 methods into existing `ios/Tests/DinnerFeatureModelTests.swift`, and the separately reviewed Notes label fix. These existing files already belong to the ordinary targets. No new project entry, job, fixture gate, manual selector list, slot allocation or timeout change is needed.

## Exact selectors and existing selection contract

- `RoomInTheCartUITests/FreeJourneyUITests/testUnavailableRecipeSourceLeavesServingsAndPortionAllocationEditableAfterRestart`
- `RoomInTheCartTests/DinnerFeatureModelTests/testIdeaPreparationAbandonRepeatSaveAcceptAndChooseHaveSeparateEffects`
- `RoomInTheCartTests/DinnerFeatureModelTests/testIdeaGenerateSaveAndAcceptRecheckDeniedRuntimeWithoutAnyCommit`

Current ordinary CI has no manually maintained per-case required-selector inventory. `discover_ios_tests.py` obtains Xcode's compiled flat enumeration; `plan_ios_tests.py` requires every enabled ordinary case to appear exactly once, routes model methods to `models`, and greedily balances UI methods over the existing10UI shards. Only the dedicated StoreKit scenario suite may be disabled. Generated selector files and matrix expected counts become the exact execution requirement for that build.

`run_ios_test_shard.sh` runs those exact selectors serially with720s default/900s maximum case allowance. `check_ios_test_results.py` checks exact selected/result inventory, all-pass counts, no skips or expected failures, one start/pass pair per case, one successful log banner, and the existing narrow warning policy. The current workflow keeps the55-minute job/40-minute execution step and five native concurrency slots. None of those policies should change for this integration.

The policy guarantees coverage of the **compiled** ordinary inventory; it is not a separate promise that a specific source method can never be deleted. This review does not introduce an unrelated mandatory-test registry. Root should require these three exact selectors once each in the new compiled enumeration and generated plan when accepting the integration.

Do not add these methods to the StoreKit selectors, Swift-package inventory or fixture profiles. S26 native model methods are not Swift-package tests, and S14 ordinary entry is not a seeded dinner fixture. Do not add a warning allowance just because a new case produces a warning. Existing `ios/**` PR coverage selects the relevant native workflows, and core CI itself is unfiltered.

## Duration update after a passing result

Until a valid measurement exists, S14 uses the current300-second **scheduling estimate**, not an execution limit. The S26 methods require no UI duration entry.

After a complete, strictly accepted local S14 pass, the only appropriate optional scheduling edit is:

- Add `local_seconds[exact S14 selector] = ceil(passing durationInSeconds)` to `scripts/ios_test_durations.json`.
- Add a provenance entry identifying the accepted source/bundle/result hashes, selector, device/runtime/Xcode and retained result path.
- Keep `local_multiplier:4`, existing hosted precedence, default estimate and all timeout limits unchanged. The planner applies the multiplier itself; do not multiply the stored local value twice.
- Never use the failed103.569s run1, partial execution, or a model duration. Do not put a local result under hosted_seconds. A later strictly accepted hosted pass can supply a real hosted weight.

No duration patch is supplied while root owns an unfinished run. No future job count, expected count or UI shard name should be hard-coded.

## Offline checks executed

All work was read-only against main; generated review output lives only here. No native build/test/simulator/Git action was performed.

- Existing planner unit checks:6passed.
- Existing strict result-verifier unit checks:31passed.
- Existing PR-trigger coverage checks:6passed.
- Existing supported UI-automation API contract:1passed.
- Generated Xcode project check:passed; existing-file method additions need no project generation change.
- Localization check:passed; Notes uses an already translated Notes/Notas key.
- `offline-integration-check.py`: pure planner rehearsal using a retained804 compiled inventory plus the three proposed selectors. All original652 enabled cases and the three additions are selected once (655total), both S26 cases land in models, S14 in one UI shard, expected counts agree, and disabling **each** proposed regression is rejected. The ordinary11shard shape is unchanged. This old-inventory rehearsal is not current compiled discovery, current test counts, a fixed S14shard assignment or native acceptance.

`offline-integration-result.json` hashes the retained inventory and current planner/duration policy. The proposed source methods also occur exactly once in their scratch candidates. Root should now verify actual integrated compiled discovery and strict native results using the existing workflow; this review neither monitors nor accepts the ongoing native attempt.
