# B11 local operations through schema 019 — 2026-11-03

The committed service/shared source through migrations 001–019 passed the local operational extension. A synthetic post-erasure backup restored into a fresh isolated database with **all 60 table contents / 1,385 rows identical**, plus effective database/table/column permissions, views, triggers, constraints, indexes, functions and RLS policies. Representative 018 quote/grant and 019 consent/feedback/billing data remained nonempty and usable; the separately erased actor's data remained absent. This is local scoped evidence, not production restore or full B11 acceptance.

The earlier 001–017 **53-table / 163-row baseline** remains separately preserved in [the earlier report](../operations-20261103/README.md) and `/Users/palatis/Documents/Codex/2026-11-03/task-2/operations-resume-evidence`. No baseline files or databases were replaced.

## Source and preserved artifacts

- Frozen commit: `dbf9b41ecf1914df78a536825c01da2f90a220fc`; committed service changes are from `fd3aa49`. Exactly **100 tracked service/shared files** were archived and verified against their Git blob IDs after execution. Concurrent native/UI/docs changes were excluded.
- Frozen root: `/tmp/ritc-b11-operations019-20261103`. Complete durable clone: `/Users/palatis/Documents/Codex/2026-11-03/task-2/operations019-resume-evidence`.
- Source archive SHA-256: `c71db5bfc32ac2d275236a9d3aa42f37e7a2d174d5c379c37505239e3c288542`.
- Synthetic dump SHA-256: `73c6b493ba1aa6c8525fa90c712ed40e7d3e19d45ccc53c7db6b024a5c287e4c`.
- Dependencies were locally copied with APFS clone copying; no network installation/update ran. A fresh TypeScript build produced 58 emitted files; the repository's live dist was never used. Manifests cover 100 source files, 58 emitted files, and 2,368 dependency files/symlinks. Tool versions remained Node 22.14.0, TypeScript 5.7.3 and PostgreSQL/dump/restore 17.11.
- `artifact-identities.json`, `manifest-identities.json`, `source-manifest.json`, `compiled-manifest.json`, `dependencies-manifest.json`, full source archive and dump preserve exact identities. No product source edit was necessary or made.

No applicable AGENTS.md was found in the prior repository/ancestor/service/scripts/tests/docs inspection. The current committed migration, test, service and privacy contract sources were read before execution. The old requirements inventory was not treated as current-schema execution evidence.

## Executed suites

Suites ran sequentially in the new owned source database. These counts belong to this frozen source; they are not combined with root's broader native/wire gates.

| Execution | Final result | Evidence |
|---|---:|---|
| Existing auth maintenance operations |5 passed, 0 failed/skipped|`auth-operations.log`|
| Existing privacy HTTP/integration |9 passed, 0 failed/skipped|`privacy-integration.log`|
| Existing S27 quote HTTP/integration |14 passed, 0 failed/skipped|`store-quotes-integration.log`|
| Existing measurement integration |8 passed, 0 failed/skipped; parent plus 7 subcases|`measurement-integration.log`|
| Existing quote math + measurement pure tests |13 passed, 0 failed/skipped|`quote-measurement-pure.log`|
| Controlled retained 018/019 fixture |7 passed, 0 failed/skipped; parent plus 6 subcases|`retained019-rehearsal.log`|

The S27 native-wire opt-in was not enabled. No simulator, ADB or native device action ran.

The first S27 run had 13 passes and 1 fixture failure: PUBLIC CONNECT had intentionally been revoked on the new databases, but that committed harness explicitly uses the pre-existing shared `ritc_test_worker` login. CONNECT was initially granted only to our two new logins. The resulting database connection denial was a fixture setup omission. `store-quotes-integration-initial-connect-denial.log` retains it. A scoped CONNECT grant was added only to the two owned 019 databases. The one interrupted synthetic deletion job was then drained with the actual privacy worker and local provider stub (`interrupted-fixture-drain.json`), and the unchanged committed S27 suite passed 14/14. This did not require a product change.

## Nonempty data and erasure boundaries

The controlled fixture used actual loopback HTTP routes, local signed fixture JWTs, real device enrollment/authorization, real service classes and PostgreSQL. It retained one household with an explicit per-adult budget grant, immutable entered pair, explicit proposal, separate shopper adoption, four mutation receipts, two current adult measurement consents and one canonical closed-pickup response. Grocery/billing payload fields were rejected by the code-only feedback allowlist. Uppercase consent identity normalized to the existing UUID; retry returned the same feedback identity; changed answers conflicted. The eligible week came from actual server-recorded placement/closure, using HTTP financial review to close the placed pickup.

The same fixture exercised withdrawal and attempted consent resurrection; duplicate devices/deliveries, renewal and two seats still yielded one willing household. Dedicated controls retained the expected aggregate: active Production-labelled fixture 1, live grace 1, Sandbox 0, no-consent 0, refunded 0, expired 0. Billing/status reads did not create consent.

**Provider and billing verification were synthetic boundaries.** Logout/deletion used in-process stubs; the deletion stub removed only this fixture database's synthetic auth.sessions rows. Billing used the actual BillingService with in-process `verifyTransaction`/`current` gateway stubs. Production labels were synthetic data; no real Apple signature, purchase, membership, provider account or guardian verification was performed. No raw provider key/password/device capability or signing private key was stored in the identities file.

A separate actor first had nonempty 018 adopted/proposed quote proof and grant, 019 consent/feedback and synthetic billing state. Actual privacy acceptance revoked access and removed feedback; the actual dedicated worker completed erasure. The dump retained zero quote pairs/proposals/adoptions/grants, measurement consent/feedback, billing state and actor mutation receipts for that erased actor's household. Its identity remained blocked and job complete with cleared issuer/subject. The independent retained household's quote and measurement data survived. Global new-table counts in the dump were 19 grants, 99 pairs, 9 proposals, 9 adoptions, 152 mutation receipts, 7 measurement consents and 1 feedback row; these include the retained existing-suite fixtures.

## Fresh restore and permission rehearsal

`pg_dump --format=custom` backed up only `ritc_b11_ops019_20261103` after fixture clients closed. `ritc_b11_ops019_restore_20261103` was independently created from template0 and verified to contain zero user tables. `pg_restore --single-transaction --exit-on-error --no-owner` restored into it. Both databases remain owned by local administrator `palatis`; no cluster-global dump, role restore or parent data clone occurred.

`state-before-dump.json`, `state-after-restore.json` and `restore-comparison.json` prove equality of 60 tables / 1,385 rows and 10 schema/permission categories: relations, columns, constraints, indexes, functions, views, triggers, column ACLs, database ACLs and RLS policies. New view definitions and server-closure/consent/eligibility/erasure triggers were included. The registry's raw ACL again changed from explicit owner-only to PostgreSQL NULL/default owner-only; `raw-acl-diagnostic.json` retains it. The verifier compares sorted effective ACLs via PostgreSQL `acldefault`, not the storage representation.

Both source and restored fixtures passed:

- Worker raw-table denials for every new 018/019 table and private auth/privacy tables; narrow maintenance function execution remained available. App login was rejected as a worker.
- No-tenant and foreign-tenant row isolation; a cross-tenant INSERT failed with 42501.
- Quote proof UPDATE/DELETE denied; consent identity/version UPDATE denied while only withdrawn_at UPDATE remained granted; feedback INSERT/DELETE allowed, UPDATE denied.
- Rollback-only attempts to resurrect withdrawn consent, insert a second canonical household/shop/week response, or forge the eligible week failed with the expected constraint errors. Every probe rolled back; no permission probe changed retained data.
- Authenticated real repository/service reads preserved the shopper's chosen basis, explicitly granted adult read and canonical feedback, while ungranted/foreign adults were denied. These after-restore reads used a fresh local fixture signer, live exact synthetic provider sessions and the repository's supported existing trusted-device context. They did not restore raw device tokens and are not another HTTP or native-wire run. Actual HTTP paths were exercised by the committed suites and controlled seed beforehand.
- The erased identity/job/data state and all willing-household controls remained unchanged after restore.

## Exact database/role lifecycle

All connections used the existing local Unix socket `/tmp`, port 55432. New databases: `ritc_b11_ops019_20261103` and `ritc_b11_ops019_restore_20261103`. New logins: `ritc_b11_ops019_app_20261103` inheriting only ritc_app, and `ritc_b11_ops019_worker_20261103` inheriting only ritc_worker. They own no tables and have no superuser, bypass-RLS, CREATE ROLE or CREATE DATABASE rights; no password was assigned. PostgreSQL logins are cluster-global; pool URLs were restricted to these fixture databases.

PUBLIC CONNECT was removed from both new databases; owner and the two dedicated logins plus unchanged-harness `ritc_test_worker` retain scoped CONNECT. `restore-comparison.json` includes matching effective database ACLs. Existing `ritc_app`, `ritc_worker`, and `ritc_test_worker` role flags/memberships and password absence were unchanged; before/after snapshots are byte-identical. Password checks recorded only NULL/not-NULL, never secret values. No root database or existing role/password was altered.

All fixture HTTP servers and pools closed. `final-local-lifecycle.json` records **zero active connections** to the two 019 fixture databases. Both databases/logins, dump, source/build/dependencies and logs are retained. The old baseline remains intact. Shared PostgreSQL was left running under root's control.

## Open operational gates and source-only inventory

This is a restore of a dump **already containing erasure markers and already-redacted data**. It does not prove stale backup recovery from before a later deletion. An external erasure journal, quarantine and replay-before-serving mechanism remains unsupported/unproven. Production retention horizon, backup expiry/purge, provider/log retention and real scheduled maintenance remain open. Test retention numbers are not an approved deployment policy.

No provider/SMTP/Apple action, deployment, remote migration, production backup or stale pre-erasure deletion replay ran. Root reports 72 web tests and built public help/privacy/terms/support sources; those surfaces remain **source/build only, unpublished, with public contact awaiting the user**. This lane did not independently rerun or publish them. No full requirements audit or all-route acceptance is claimed.
