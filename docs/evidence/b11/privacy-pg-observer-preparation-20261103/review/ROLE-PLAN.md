# Proposed local fixture role plan

Baseline: repository HEAD 8d607950a64a38a05293f8343ba59b49a2261000. This is a scratch candidate; no shared source installation or hosted work.

Read-only inventory used local PostgreSQL /tmp port 55432, database postgres, setup principal palatis. No passwords or role secrets were read. Existing ritc_guardian_test_verifier is LOGIN, has no superuser/BYPASSRLS/CREATEDB/CREATEROLE/replication flags, and belongs only to ritc_guardian_verifier. No standalone unprivileged login is available.

## Scope before any mutation

Create one newly named disposable database `ritc_journal_pg_source_<random UUID>`, owned by existing palatis. Owner is setup/DDL/fixture control only, never the source adapter or runtime principal. Apply exact frozen migrations 001–024 after read-only preflight verifies all three existing migration group roles (ritc_app, ritc_worker, ritc_guardian_verifier). Their existing conditional CREATE ROLE branches must remain unentered. No role creation, ALTER ROLE, passwords, membership GRANT/REVOKE, or existing-database ACL changes.

Only within that new database:

- Revoke PUBLIC CONNECT/TEMP and public-schema CREATE; explicitly grant CONNECT to the existing observer, app and worker fixture logins used in negative cases.
- Remove ritc_guardian_verifier's function EXECUTE privileges in this database, including inherited guardian verifier capabilities. Do not change that group's membership or permissions in any other database.
- Grant ritc_guardian_test_verifier only ritc schema USAGE and EXECUTE on the five proposed source observer wrappers. Do not grant raw table/column/sequence rights or owner/source-signing authority.
- Register the synthetic fixed source identity, actual new database OID and exact observer role OID using owner-only immutable registration. The origin lineage/schema/configuration pins remain exact.
- App/worker fixture roles keep the ordinary migration capabilities; receive no source wrapper or raw journal grants. Their denied calls are negative tests.

The adapter and SQL guard reject unexpected session/current identity, wrong database/source pins, any reachable owner/app/worker role or dangerous role attribute, DB CREATE/TEMP, schema CREATE, effective raw table/column/sequence rights, and any extra ritc function execution. An otherwise powerless existing guardian group membership is allowed only after these effective capabilities are checked. No claim of globally removing its preexisting rights elsewhere.

## Review and execution status

Reported to parent before mutation. Independent reviewer accepted the plan subject to effective-privilege checks. SQL worker is preparing exact runner and grants; **no fixture database mutation is cleared yet**. Execution requires a reviewed concrete runner implementing this scope. Preserve source/checksum inventory, effective-role/ACL evidence and actual cancellation outcomes. No credential or personal-data evidence.

## Observed prerequisite from first real fixture run

The baseline retains PUBLIC EXECUTE on legacy trigger functions immutable_row, lock_household_access, consent_revoke_once and billing_adult_seat. The adapter correctly rejected those extra effective function privileges. In the new disposable databases only, setup additionally revokes ALL ON ALL FUNCTIONS IN SCHEMA ritc FROM PUBLIC before granting the five wrappers. App/worker explicit grants remain. This stricter fixture ACL was reported to the parent before applying; it changes no existing database or cluster role.

Proposed024 alone does not provision a production observer or remediate an existing deployment's legacy PUBLIC ACLs. Exact effective-privilege review/revocation is a separate activation prerequisite. There is no permissive fallback if extra inherited access remains.
