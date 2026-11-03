#!/bin/zsh
# Recorded executed commands; this is an audit record, not an automatic rerun.
# Retained fixture DBs/roles already exist. Review before any deliberate replay.
REPO='/Users/palatis/Room in the Cart'
FROZEN='/tmp/ritc-b11-operations-20261103'
NODE="$REPO/.tools/node-v22.14.0-darwin-arm64/bin/node"
PGBIN="$REPO/.tools/postgres/bin"

# Snapshot from fixed HEAD, excluding untracked/concurrent work and old dist:
cd "$REPO"
git archive b0cbcd7973bf2a2fa5766e48da87be941aa1fcfd service shared > /tmp/ritc-b11-operations-source.tar
mkdir "$FROZEN"
tar -xf /tmp/ritc-b11-operations-source.tar -C "$FROZEN"
cp -cR service/node_modules "$FROZEN/service/node_modules"
mkdir "$FROZEN/evidence"
git status --short > "$FROZEN/evidence/live-status-at-freeze.txt"
git ls-tree -r b0cbcd7973bf2a2fa5766e48da87be941aa1fcfd service shared > "$FROZEN/evidence/git-tree.txt"

cd "$FROZEN/service"
"$NODE" node_modules/typescript/bin/tsc -p tsconfig.json > ../evidence/build.log 2>&1

# Shared role metadata and only new isolated fixture DBs/logins:
"$PGBIN/psql" -X -qAt -v ON_ERROR_STOP=1 -h /tmp -p 55432 -d postgres -f "$FROZEN/evidence/shared-role-snapshot.sql" > "$FROZEN/evidence/shared-roles-before.json"
"$PGBIN/psql" -X -v ON_ERROR_STOP=1 -h /tmp -p 55432 -d postgres -f "$FROZEN/evidence/setup.sql" > "$FROZEN/evidence/setup.log" 2>&1

env -i PATH="$REPO/.tools/node-v22.14.0-darwin-arm64/bin:/usr/bin:/bin" HOME='/Users/palatis' TMPDIR='/tmp' \
  OPERATIONS_TEST_DATABASE_URL='postgresql://ritc_b11_ops_app_20261103@localhost/ritc_b11_ops_20261103?host=%2Ftmp&port=55432' \
  OPERATIONS_TEST_ADMIN_DATABASE_URL='postgresql://palatis@localhost/ritc_b11_ops_20261103?host=%2Ftmp&port=55432' \
  TEST_WORKER_DATABASE_URL='postgresql://ritc_b11_ops_worker_20261103@localhost/ritc_b11_ops_20261103?host=%2Ftmp&port=55432' \
  node scripts/test-operations.mjs > ../evidence/auth-operations.log 2>&1

env -i PATH="$REPO/.tools/node-v22.14.0-darwin-arm64/bin:/usr/bin:/bin" HOME='/Users/palatis' TMPDIR='/tmp' \
  TEST_DATABASE_URL='postgresql://ritc_b11_ops_app_20261103@localhost/ritc_b11_ops_20261103?host=%2Ftmp&port=55432' \
  TEST_ADMIN_DATABASE_URL='postgresql://palatis@localhost/ritc_b11_ops_20261103?host=%2Ftmp&port=55432' \
  TEST_WORKER_DATABASE_URL='postgresql://ritc_b11_ops_worker_20261103@localhost/ritc_b11_ops_20261103?host=%2Ftmp&port=55432' \
  node --test tests/privacy.integration.mjs > ../evidence/privacy-integration.log 2>&1

cd "$FROZEN"
# Initial verifier captured raw relacl (initial snapshots retained):
# node evidence/verify-restored-state.mjs ritc_b11_ops_20261103 evidence/state-before-dump.json
"$PGBIN/psql" -X -qAt -v ON_ERROR_STOP=1 -h /tmp -p 55432 -d ritc_b11_ops_restore_20261103 \
  -c "SELECT jsonb_build_object('database',current_database(),'user_tables',count(*)) FROM pg_tables WHERE schemaname IN ('ritc','auth','public');" > evidence/restore-target-before.json
"$PGBIN/pg_dump" -h /tmp -p 55432 -d ritc_b11_ops_20261103 --format=custom --file=evidence/synthetic-post-erasure.dump --verbose > evidence/pg-dump.log 2>&1
"$PGBIN/pg_restore" -h /tmp -p 55432 -d ritc_b11_ops_restore_20261103 --single-transaction --exit-on-error --no-owner --verbose evidence/synthetic-post-erasure.dump > evidence/pg-restore.log 2>&1
# Initial raw and then expanded schema diagnostics are retained as state-*.json.
# Final read-only verifier uses equivalent canonical effective ACLs:
env -i PATH="$REPO/.tools/node-v22.14.0-darwin-arm64/bin:/usr/bin:/bin" HOME='/Users/palatis' TMPDIR='/tmp' \
  node evidence/verify-restored-state.mjs ritc_b11_ops_20261103 evidence/state-source-effective-acl.json > evidence/state-source-effective-acl.log 2>&1
env -i PATH="$REPO/.tools/node-v22.14.0-darwin-arm64/bin:/usr/bin:/bin" HOME='/Users/palatis' TMPDIR='/tmp' \
  node evidence/verify-restored-state.mjs ritc_b11_ops_restore_20261103 evidence/state-restore-effective-acl.json > evidence/state-restore-effective-acl.log 2>&1

"$PGBIN/psql" -X -qAt -v ON_ERROR_STOP=1 -h /tmp -p 55432 -d postgres -f evidence/shared-role-snapshot.sql > evidence/shared-roles-after.json
cmp evidence/shared-roles-before.json evidence/shared-roles-after.json
# Final lifecycle check queried pg_database / pg_roles and pg_stat_activity for only
# the two named fixture DBs/roles; exact result is final-local-lifecycle.json.
# All pools/HTTP test servers closed. Retain fixtures; no DROP or pg_ctl stop ran.
