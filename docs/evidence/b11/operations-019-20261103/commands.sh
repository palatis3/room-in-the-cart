#!/bin/zsh
# Executed command record, not an automatic rerun: retained DBs/roles already exist.
# Review any replay and give it a new disposable scope before running setup.
REPO='/Users/palatis/Room in the Cart'
FROZEN='/tmp/ritc-b11-operations019-20261103'
NODE="$REPO/.tools/node-v22.14.0-darwin-arm64/bin/node"
PGBIN="$REPO/.tools/postgres/bin"
cd "$REPO"
git archive dbf9b41ecf1914df78a536825c01da2f90a220fc service shared > /tmp/ritc-b11-operations019-source.tar
mkdir "$FROZEN"
tar -xf /tmp/ritc-b11-operations019-source.tar -C "$FROZEN"
cp -cR service/node_modules "$FROZEN/service/node_modules"
mkdir "$FROZEN/evidence"
git status --short > "$FROZEN/evidence/live-status-at-freeze.txt"
git ls-tree -r dbf9b41ecf1914df78a536825c01da2f90a220fc service shared > "$FROZEN/evidence/git-tree.txt"
cd "$FROZEN/service"
"$NODE" node_modules/typescript/bin/tsc -p tsconfig.json > ../evidence/build.log 2>&1
cd "$FROZEN"
"$PGBIN/psql" -X -qAt -v ON_ERROR_STOP=1 -h /tmp -p 55432 -d postgres -f evidence/shared-role-snapshot.sql > evidence/shared-roles-before.json
"$PGBIN/psql" -X -v ON_ERROR_STOP=1 -h /tmp -p 55432 -d postgres -f evidence/setup.sql > evidence/setup.log 2>&1
# Initial committed runner stopped at S27 fixture CONNECT denial. Initial TAP/results retained.
"$NODE" evidence/run-committed-tests-initial.mjs
"$PGBIN/psql" -X -v ON_ERROR_STOP=1 -h /tmp -p 55432 -d postgres -f evidence/setup-shared-worker-connect.sql > evidence/setup-shared-worker-connect.log 2>&1
"$NODE" evidence/drain-interrupted-fixture.mjs > evidence/interrupted-fixture-drain.log 2>&1
# Only S27 rerun and previously unexecuted measurement/pure suites:
"$NODE" evidence/run-committed-tests.mjs remaining
# Exact clean per-suite environment/URLs are in committed-test*-commands.json.
env -i PATH="$REPO/.tools/node-v22.14.0-darwin-arm64/bin:/usr/bin:/bin" \
 TEST_DATABASE_URL='postgresql://ritc_b11_ops019_app_20261103@localhost/ritc_b11_ops019_20261103?host=%2Ftmp&port=55432' \
 TEST_ADMIN_DATABASE_URL='postgresql://palatis@localhost/ritc_b11_ops019_20261103?host=%2Ftmp&port=55432' \
 TEST_WORKER_DATABASE_URL='postgresql://ritc_b11_ops019_worker_20261103@localhost/ritc_b11_ops019_20261103?host=%2Ftmp&port=55432' \
 node --test evidence/retained019-rehearsal.mjs > evidence/retained019-rehearsal.log 2>&1
"$NODE" evidence/verify-restored019-state.mjs ritc_b11_ops019_20261103 evidence/state-before-dump.json > evidence/state-before-dump.log 2>&1
"$PGBIN/psql" -X -qAt -v ON_ERROR_STOP=1 -h /tmp -p 55432 -d ritc_b11_ops019_restore_20261103 \
 -c "SELECT jsonb_build_object('database',current_database(),'user_tables',count(*)) FROM pg_tables WHERE schemaname IN ('ritc','auth','public');" > evidence/restore-target-before.json
"$PGBIN/pg_dump" -h /tmp -p 55432 -d ritc_b11_ops019_20261103 --format=custom --file=evidence/synthetic019-post-erasure.dump --verbose > evidence/pg-dump.log 2>&1
"$PGBIN/pg_restore" -h /tmp -p 55432 -d ritc_b11_ops019_restore_20261103 --single-transaction --exit-on-error --no-owner --verbose evidence/synthetic019-post-erasure.dump > evidence/pg-restore.log 2>&1
"$NODE" evidence/verify-restored019-state.mjs ritc_b11_ops019_restore_20261103 evidence/state-after-restore.json > evidence/state-after-restore.log 2>&1
/usr/bin/python3 evidence/compare-snapshots.py
"$PGBIN/psql" -X -qAt -v ON_ERROR_STOP=1 -h /tmp -p 55432 -d postgres -f evidence/shared-role-snapshot.sql > evidence/shared-roles-after.json
cmp evidence/shared-roles-before.json evidence/shared-roles-after.json
# Final role/database/connection metadata: final-local-lifecycle.json.
# Registry raw ACL diagnostics: raw-registry-acl-source.json / -restore.json.
# No DROP DATABASE, DROP ROLE, ALTER existing role/password or pg_ctl stop ran.
