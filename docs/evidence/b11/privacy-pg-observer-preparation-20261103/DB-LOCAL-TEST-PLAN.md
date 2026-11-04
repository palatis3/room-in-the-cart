# Proposed disposable PostgreSQL test plan

The runner connects only to the existing local `/tmp:55432` cluster as its existing owner. It checks that `ritc_app`, `ritc_worker`, `ritc_guardian_verifier`, `ritc_test_runtime` and `ritc_test_worker` already exist before applying unchanged migrations 001–023. Their conditional CREATE ROLE branches therefore cannot execute. It snapshots all nonsecret role attributes and memberships before the run and compares them after cleanup.

The observer is the unchanged existing LOGIN `ritc_guardian_test_verifier`. Its only reachable membership must be `ritc_guardian_verifier`; no reachable role may have superuser, BYPASSRLS, CREATEDB, CREATEROLE or REPLICATION. The runner never creates or alters roles, passwords, memberships or role settings.

The only planned databases are two new owner-owned names `ritc_journal_pg_source_<random UUID>` and `ritc_journal_pg_wrong_<random UUID>`. The runner revokes PUBLIC database privileges on those new databases, then grants CONNECT only to the observer, `ritc_test_runtime` and `ritc_test_worker`. It creates synthetic auth fixture tables and applies migrations 001–024 inside those two databases. It revokes PUBLIC CREATE on their public schemas.

To remove inherited guardian capabilities solely in each new database, it revokes ALL on all ritc tables, sequences and functions from `ritc_guardian_verifier`. It also revokes PUBLIC EXECUTE on all ritc functions, because migrations 001/002 leave default PUBLIC EXECUTE on four trigger functions; app/worker explicit grants are retained. It then grants ritc schema USAGE directly to the unchanged observer login and EXECUTE on exactly these new functions:

- `ritc.privacy_journal_source_binding(text,uuid,text,text,oid)`
- `ritc.privacy_journal_source_event(text,uuid,text,text,oid,uuid)`
- `ritc.privacy_journal_source_acceptance(text,uuid,text,text,oid,uuid)`
- `ritc.privacy_journal_source_unacknowledged(text,uuid,text,text,oid,uuid,integer)`
- `ritc.privacy_journal_source_acknowledge(text,uuid,text,text,oid,uuid,text,bigint,text)`

There are no grants to app or worker for any new function or journal table. Schema preflight and actual connection tests require no effective observer table, column, sequence, schema CREATE, database CREATE/TEMP, extra ritc EXECUTE or owner/app/worker authority. Negative guard tests temporarily add a column privilege, extra function privilege or function EXECUTE to PUBLIC only in a new disposable database, assert rejection and revoke the privilege before the next test.

Tests insert synthetic immutable origin/registration and synthetic outbox events into the new databases as owner. Wrong-database registration intentionally pins the source database OID in the second new database. Real PostgreSQL locks test read and acknowledgement blocking, timeout, abort, backend destruction, transaction rollback, unchanged acknowledgement rows and safe idempotent retry. A test-only owned deferred trigger delays actual COMMIT; the test aborts that socket during COMMIT, then independently checks whether the row actually committed after backend removal for the uncertain late-response case; it is never added to the live repository or any old database. No remote provider completion is manufactured.

Cleanup terminates connections only where datname equals one of the two newly generated database names, drops those databases, then verifies the original cluster role/membership snapshots are unchanged. No old database ACL is touched.
