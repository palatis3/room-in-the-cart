# ui-05 exact Menu idle-phase proposal

The evidence justifies one selector-specific alternate phase in the existing bounded warning policy. This is a verifier policy update, not an app fix or proof of a framework root cause. The original hosted failure remains retained.

Both current warning occurrences are the exact existing `_UIReparentingView` message under adjacent internal parents `Tap "ledgerShopPicker" Button` → `Wait for dev.roominthecart.app.debug to idle`. Their distinct issue attachment UUIDs are `06E48B20-6856-40D4-A29B-C01C610800DA` and `145416F7-9276-4F95-9345-EBACC6BFF70B`. Exact-case details/activities/summary agree on the iPhone17 arm64 iOS26.2 build23C54 / Test Scheme Action context. Sol's full archive and scope receipts remain authoritative for collection; I read only the supplied small JSON/source records.

The retained isolated Menu evidence supports this phase distinction: `ci-menu-warning-20261105/standalone-attempt-1.json` recorded pickup-Menu synthesis; `standalone-fresh-scenarios.json` recorded two exact pickup-open issues under that isolated app's Menu idle wait, while unopened controls were separate scenarios. Existing policy already recognizes idle for other precisely identified Menu selectors. This supports adding the observed idle phase for `FreeJourneyUITests/testMealWeekKeepsOriginalPickupWhenShopSelectionChanges`; it does not justify an app-wide warning exclusion.

Production checker change is four added lines in `OBSERVED_MENU_WARNING_ALTERNATE_PHASES`. Original selector, exact pickup tap, message, device/build/configuration, adjacent ancestry, issue UUID validation and combined cap of two remain unchanged. Mixed phases still reject; there is no separate cap per phase. No test-result/lifecycle gate changes.

Validation:

- Exact original warned-case JSON replay: old checker `unexpected-warnings`, two issues; candidate `passed`, the same two issues. This replay is the warning layer only and does not rewrite the original hosted result.
- 32 checker unit tests pass, including one new selector-specific regression with both permitted phases, one/two versus three issue counts, wrong tap/phase/device/configuration/selector/activity type/message, mixed/deeper/missing ancestry, duplicate UUID, mismatched counts and wrong case identity negatives.
- Existing idle-negative fixture used this formerly unreviewed selector; it now uses an explicitly unreviewed pickup selector, retaining the negative's purpose.
- Initial local unit preparation failed four assertions: the copied mixed-path test initially split synthesis into synthesis, and the old negative selector had become intentionally permitted. Those test-fixture errors were corrected; `tests.log` is retained, final result is `tests-v2.log`. No native attempt occurred.

Files: `menu-idle.patch`, `scripts/` candidates, `base/` unchanged inputs, `manifest.json`, `exact-case-warning-replay.json`, validation logs and `validation.json`. Root owns integration and any broader offline checks. No main/Git/hosted/native changes.
