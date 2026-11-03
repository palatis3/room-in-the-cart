# B11 operations020 — restart checkpoint, 2026-11-03

**Incomplete: source freeze prepared; no020 operational execution or restore proof yet.** The user's Codex restart checkpoint arrived before database setup/build/test execution. This report must not be read as a passing020 drill.

## Preserved stage

- Exact committed baseline: `ae00e3bb8322a684f43526c9e360f082ed0c0c68` (default PrivacyService composition, scheduled maintenance, migration020). In-progress021 and all dirty/untracked working source are excluded.
- Frozen source: `/tmp/ritc-b11-operations020-20261103`; durable copy: `/Users/palatis/Documents/Codex/2026-11-03/task-2/operations020-resume-evidence`.
-110 tracked source files from `service`, `shared`, `api/maintenance.js`, and `vercel.json` were verified against their exact Git blob IDs. Source archive SHA256: `16b83013d071a655121109e40d21e067313b437d453f30c925bfcce4568355bf`.
-2,368 dependency files/symlinks were locally APFS-cloned from the separately preserved019 tree. No network install/update ran. `source-manifest.json` and `dependencies-manifest.json` record identities. No live service/dist was copied; **no build or compiled identity exists yet**.
- Only read-only proposed-name collision and existing fixture-role membership checks ran on Unix socket `/tmp:55432`. Proposed DBs `ritc_b11_ops020_20261103` and `ritc_b11_ops020_restore_20261103` and proposed own logins `ritc_b11_ops020_app_20261103` / `ritc_b11_ops020_worker_20261103` were absent. **None was created.** No migration/DB/role/password/grant mutation ran.
- Existing `ritc_test_worker` already inherits ritc_worker and not ritc_app. Existing `ritc_test_combined_worker` already inherits both. This observation is not a new grant; membership must be rechecked on restart before running unchanged harnesses.
- The operations020 task has no running HTTP service, pool, worker, transaction or tool-process session. The read-only psql process exited normally. Shared PostgreSQL remains running. No automatic or scheduled task was registered.

`restart-stage.json` is the authoritative current stage. There is **no020 test TAP, dump, restored database, health equality, or effective-permission execution result yet**. The earlier019 source/dump/DBs/report remain intact under `operations019-resume-evidence` and `docs/evidence/b11/operations-019-20261103`; they remain proof only of their post-erasure clone. They do not prove this newer runtime composition or a stale pre-erasure restore.

## Commands already executed

From repository `/Users/palatis/Room in the Cart`:

1. Read relevant frozen/working operations/privacy contracts, current020 migration and dedicated runtime tests; inspect the019 evidence/verifier/controlled fixture.
2. Read-only psql catalog query for the exact proposed database/role names and two existing shared fixture-role memberships. The first unprivileged socket attempt hit filesystem sandbox `Operation not permitted`; the approved local read-only retry succeeded. No service/database defect was inferred.
3. `git archive ae00e3bb8322a684f43526c9e360f082ed0c0c68 service shared api/maintenance.js vercel.json` into `evidence/frozen-tracked-source.tar`; extract only that archive; save `git ls-tree -r` and the live status at freeze. An initial Python extraction attempted unsupported `tarfile.extractall(filter=...)` on the local Python; safe extraction retried successfully after validating archive paths. This was a local preparation compatibility issue, not a product change.
4. `cp -cR /tmp/ritc-b11-operations019-20261103/service/node_modules /tmp/ritc-b11-operations020-20261103/service/node_modules`.
5. Verify every frozen source Git blob and record SHA256/dependency manifests; retain this checkpoint and durable copy. No tests/builds ran.

## Remaining authorized steps after restart

No command below has run. Recheck the new names are unused; do not overwrite anything if the cluster changed.

1. Build the frozen service with the repository's pinned Node22.14.0 and local TypeScript dependency; preserve emitted-file hashes. Keep021 excluded. Before mutation, record existing shared role flags/membership and password NULL/not-NULL only, never secret values.
2. Create only the two new owned020 fixture DBs/template0 and two new non-owner/non-bypass app/worker logins. Do not change existing role flags/passwords/memberships. Revoke PUBLIC CONNECT only on the new DBs; grant the own logins plus unchanged-harness `ritc_test_worker` and `ritc_test_combined_worker` CONNECT only on those DBs from the outset. Both shared roles already have the harness-expected membership; if that changed, coordinate instead of altering them.
3. Sequentially run the frozen dedicated `service/scripts/test-operations.mjs` against explicit `OPERATIONS_TEST_DATABASE_URL` / `OPERATIONS_TEST_ADMIN_DATABASE_URL` (not a parallel application fixture). It applies migrations and runs5 auth-maintenance plus10 actual scheduled-runtime cases. Use only its fictional provider fetch stubs. Its scheduled runtime must remain cleanup-only: pending privacy jobs unclaimed/un-erased, no account provider deletion.
4. Run the frozen9 privacy integration cases, then the preserved controlled018/019 retained-versus-erased fixture with its existing in-process deletion/billing stubs. Do not run the whole service/application/S27/pure suite just to repeat unchanged coverage. Review/adapt only dedicated evidence harness names/paths for the new owned scope, not product/tests.
5. Run the committed3 runtime-privacy composition cases **after** the controlled erasure fixture. They exercise actual createRuntime preview/status/exit while deletion stays503 and leave a pending synthetic receipt. This ordering prevents the controlled PrivacyMaintenance stub from accidentally draining the default-runtime pending fixture. That remaining pending job gives a real nonempty020 health aggregate for source/restore checks.
6. Reuse/adapt the019 read-only restore verifier in the new evidence directory for20 migrations and new role/DB names. Add worker-only `ritc.operations_health()` effective execute grants, actual app denial, worker role/raw-table denials and a nonempty aggregate record. Migration020 adds a SECURITY DEFINER aggregate function, **no table**; report records/counters accurately. Reuse authenticated018/019 reads, consent/canonical protections, billing controls and erased/retained checks. Verify actual operations status via the frozen worker runtime/CLI without running another housekeeping mutation after the snapshot.
7. Close seed/test clients; take a full custom dump of the new source after erasure, verify the restore target is empty, restore into the new owned clone, compare all table data/schema/functions/views/triggers/RLS/effective ACLs plus health counters and scoped runtime reads. Retain raw registry owner-ACL representation diagnostics and canonical/effective reasoning. No provider call should occur during restore checks; scheduled maintenance is cleanup-only.
8. Preserve separate source/build/dependency identities, exact commands/TAP, full dump, before/after comparisons, final role snapshots and zero own active connections. Retain fixture DBs/dumps and shared PostgreSQL; stop only own clients/services. Publish the dedicated020 report/evidence without changing the019 baseline.

The external deletion-journal proposal remains **unapproved and unimplemented** at `/Users/palatis/Documents/Codex/2026-11-03/task-2/b11-deletion-journal-proposal/PROPOSAL.md`. No022 migration is reserved/created. Do not turn this post-erasure clone extension into a stale-backup replay claim. No real provider, Apple, email, deployment, guardian enrollment or remote migration is authorized by this checkpoint.
