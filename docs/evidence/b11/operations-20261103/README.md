# B11 local operations execution — 2026-11-03

The existing auth-maintenance suite passed **5/5**, and the existing synthetic privacy HTTP/integration suite passed **9/9**, both with zero failures/skips. A local PostgreSQL custom dump of their **post-erasure synthetic state** restored into a freshly created isolated database. All **53 table contents / 163 rows**, effective relation permissions, column/constraint/index/function definitions and RLS policies matched. This is narrow local operational evidence, not production or full B11 acceptance.

## Frozen identity and isolation

- Repository: `/Users/palatis/Room in the Cart`.
- Tracked source: commit `b0cbcd7973bf2a2fa5766e48da87be941aa1fcfd`; exactly **89 tracked service/shared files**, all verified against their Git blob IDs after execution. `git-tree.txt`, `source-manifest.json` and `frozen-tracked-source.tar` preserve their identities.
- Source archive SHA-256: `4e488dfe52a6e6e7dae1d81205f9fe0a9047072b73562261fca10b040faa3527`.
- Frozen root: `/tmp/ritc-b11-operations-20261103`; durable complete clone: `/Users/palatis/Documents/Codex/2026-11-03/task-2/operations-resume-evidence`.
- The archive includes migrations **001–017**. Concurrent working-tree changes, S27, migration018, optional measurement019, and the repository's existing dist were excluded. These results do not certify those later sources.
- Dependencies were copied locally with APFS clone copying from the installed service node_modules; no package installation or dependency update occurred. The frozen TypeScript sources were rebuilt into a new dist. `dependencies-manifest.json` identifies 2,368 dependency files/symlinks; `compiled-manifest.json` identifies 54 emitted files. `manifest-identities.json` records aggregate manifest hashes.
- Runtime: Node **22.14.0**, TypeScript **5.7.3**, PostgreSQL and dump/restore tools **17.11**. Tool executable SHA-256 identities are in `artifact-identities.txt`.

No applicable AGENTS.md existed in the inspected repository/ancestor/service/scripts/tests/docs locations. The execution followed `service/scripts/test-operations.mjs`, `service/tests/maintenance.operations.mjs`, `service/tests/privacy.integration.mjs`, `service/API-PRIVACY.md`, and existing B11 evidence.

## Actual local database and role scope

All connections used the existing shared cluster's Unix socket **`/tmp`, port55432**, with no remote database. Only these new fixture databases and new logins were created:

| Item | Scope |
|---|---|
| `ritc_b11_ops_20261103` | Dedicated operations/privacy synthetic fixture; migration administrator/owner `palatis`. |
| `ritc_b11_ops_restore_20261103` | Fresh `template0` restore destination; verified zero user tables before restore. Owner `palatis`. |
| `ritc_b11_ops_app_20261103` | New non-owner, non-superuser, non-bypass login inheriting `ritc_app`; no `ritc_worker` membership. |
| `ritc_b11_ops_worker_20261103` | New non-owner, non-superuser, non-bypass login inheriting `ritc_worker`; no `ritc_app` membership. |

The new logins have no newly assigned passwords, CREATE ROLE, CREATE DATABASE, replication or bypass rights. CONNECT was revoked from PUBLIC on both fixture databases and granted to these fixture logins. Their explicit pool URLs point only to these databases. PostgreSQL logins are cluster-global; this is local fixture scope, not per-database production identity provisioning.

The existing `ritc_app`, `ritc_worker`, and shared `ritc_test_worker` were preserved. The harness's unconditional `GRANT ritc_worker TO ritc_test_worker` was already satisfied and changed no membership. `shared-roles-before.json` and `shared-roles-after.json` are byte-identical for recorded flags/configuration/memberships. No existing role or password was altered or removed. No parent fixture/database data was read or mutated; cluster metadata was inspected to avoid collisions and verify lifecycle.

The operations runner was invoked with its two dedicated OPERATIONS_TEST URLs and an explicit dedicated TEST_WORKER URL. TEST_DATABASE_URL / TEST_ADMIN_DATABASE_URL were absent from its clean environment, so it could not target the parallel application fixture through those inherited variables.

## Executed checks and provider simulation

`auth-operations.log` records the real local PostgreSQL execution of worker-role restrictions, durable retry after logout outage, no reuse of revoked refresh credentials, exclusive claims/wrong-lease rejection/abandoned-lease recovery, expired-access `expired_unconfirmed` handling, absent exact-session completion and bounded expiry/email cleanup. Provider logout functions were **in-process synthetic stubs** using fictional token strings; the no-provider case was deliberately tested. No real identity-provider network call occurred.

`privacy-integration.log` records real loopback HTTP, signed fixture JWTs, application/worker PostgreSQL pools, and real migrations. Its provider adapter was a **synthetic stub** that removed only fixture rows from auth.sessions, with an intentionally thrown outage. Tests covered recent authentication/configuration gates, pending-to-complete deletion, exact subject erasure preserving another member, household exit, explicit household child-profile handling, synthetic billing-payload removal/retired purchase markers, foreign scope rejection, identity-lock/worker-lease boundaries, and redacted retained accounting evidence. Fixture guardian proofs and billing rows were synthetic; no real guardian or Apple membership was verified.

## Post-erasure backup and fresh restore

`pg_dump --format=custom` backed up only `ritc_b11_ops_20261103`, after the tests and after all test clients closed. The destination had zero user tables (`restore-target-before.json`). `pg_restore --single-transaction --exit-on-error --no-owner` then restored the dump into `ritc_b11_ops_restore_20261103`; owner remained local administrator `palatis`. No cluster-global dump or role restore ran.

Dump SHA-256: `1799bbb0c8d992f6d45aef4d3314b245d23b78368347809a2123d63395bd9ff6`.

The read-only verifier (`verify-restored-state.mjs`) checked every user table under auth/public/ritc, stable schema metadata, migrations/checksums and application/worker access on source and restored fixtures. `restore-comparison.json` records equality. Restored semantic checks included:

- 4 complete privacy jobs with cleared issuer/subject and application/provider completion timestamps; 4 identity-erasure markers; 5 erased targets; 6 redacted/revoked profiles; 1 retained retired-purchase hash.
- 1 preserved other-author private request; 1 retained accounting amount 1234 with its source redacted to `Removed financial evidence`; corresponding financial revision 2.
- Zero browser_auth rows remaining after bounded operations-fixture cleanup.
- Application login rejected as a worker and denied raw privacy-job reads/worker operations; worker denied raw privacy jobs/browser-auth/provider-session reads while retaining narrow maintenance-function EXECUTE rights.

The first raw schema comparison correctly detected a representation difference: the migration registry's explicit owner-only ACL became NULL, meaning its default owner-only ACL. `raw-acl-diagnostic.json` and initial/expanded snapshots retain that result. The final verifier expands NULL through PostgreSQL `acldefault`, sorts effective ACL entries, and proves identical effective relation permissions. No service/product defect or source edit was needed.

This drill restored a dump **already containing erasure markers and already-redacted data**. It does **not** prove restoring a backup from before a later deletion. No external deletion-marker/target journal with a quarantine-and-reapply mechanism was found in the existing harness. Preserving that journal outside the restored database, replaying erasure before serving a stale backup, proving its maximum horizon, production backup expiry/purge and owner-approved retention policy remain **unsupported/unrun production restore gates**. The local fixture's configured test retention values are not an approved deployment policy.

## Retention, cleanup and remaining execution

Both fixture databases, their two new logins, the full dump, frozen dependencies/source/build, diagnostic snapshots and logs are retained for deliberate replay. No task database or role was dropped. Test HTTP servers and pools exited through their after hooks, and verifier pools closed. `final-local-lifecycle.json` records **zero active connections** to either fixture database. The shared PostgreSQL server was left running under the parent's control.

No simulator, ADB, SMTP, real provider logout/deletion, Apple membership action, live guardian verification, deployed cron, remote migration/deployment, production retention, stale-backup deletion replay or production restore was executed. No full requirements audit was performed by this lane. Commands and fixture SQL are retained in `commands.sh` / `setup.sql`; execute setup only against a new explicitly disposable scope because the retained names now exist.

Only dedicated B11 operations evidence was added by this lane. No application/service/shared source fix was necessary or made.
