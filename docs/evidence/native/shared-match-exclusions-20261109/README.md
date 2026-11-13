# Explicit exclusions at shared match acceptance

Foundation 2.1 F02 requires an excluded ingredient to be rejected before it can
become an accepted match. Original HTTP regressions demonstrated two violations:
`delivery.match` and `pantry.match` returned 200 for explicitly excluded sources.
Coverage later rejected the food, but the saved match could still appear accepted.

The service now returns 409 `match_exclusion_conflict` before acceptance, using the
existing explicit-text exclusion rule. After recovery it checks effective retained
needs, including protected groups, rather than obsolete sealed restrictions.
Rejected writes leave no match, revision or operation receipt. Compatible matches,
authority/idempotency controls and removal of legacy bad matches remain covered.
The native client explains the conflict in English/Spanish, retains the rejected
command for explicit reviewed cleanup, and no longer treats a terminal delivery
rejection as a successful save. An uncertain waiting response keeps its existing
retry behavior.

## Verification

- Original negative controls: 2 failures, both unexpected 200 responses.
- Focused actual PostgreSQL/HTTP: 38 passed, 0 skipped.
- Fast service: 450 passed, 1 database-only skip.
- Full service integration: 250 passed, 3 browser-only skips.
- Native Debug build and bundle check:pass; 134.777 seconds.
- All 19 SharedShopFlowTests: pass, including both new rejection cases and the
  existing lost-response/authority controls; 35.298 seconds including Xcode setup.
  Exact-selector strict validation passes; source and products remain unchanged.
- Localization structure: 26 catalogs / 4,308 English-Spanish entries pass; human
  linguistic review remains separate.

[Compact receipt and original hashes](verification.json) binds the actual source,
logs and retained local originals. The build also contains an isolated Release-only
post-measure observer; it is excluded from these Debug cases. The disposable local
database was stopped and removed. No migration, hosted rollout, provider activation,
full combined CI or release acceptance is claimed. Shared authenticated mixed-device
F02 acceptance still requires its separate execution.
