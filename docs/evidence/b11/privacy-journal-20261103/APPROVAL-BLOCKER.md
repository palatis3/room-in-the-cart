# Full001–022 guardian fixture approval blocker

The stable021 migration was verified as SHA256 `73e33d596776a1874aeb4715b16abed3f18829d1415ed6b0dd2799e356df4c04`. The complete backend plus022 adaptations is frozen under `full/` and builds locally. The original new-role action remains rejected and was never run. A separately reviewed existing-fixture-role alternative subsequently passed automatic command review and the local001–022 drill; see the appended resolution.

The narrowly scoped requested operation was to create new local login `ritc_b11_j022_guardian`, with NOSUPERUSER/NOBYPASSRLS/NOCREATEDB/NOCREATEROLE/NOREPLICATION, membership only in existing `ritc_guardian_verifier`, and CONNECT grants only on newly owned full-drill databases. No existing role credential/membership or other database ACL was to change. Public/inherited database behavior elsewhere was not claimed to be denied.

Attempted command (no secrets):

```sh
'/Users/palatis/Room in the Cart/.tools/postgres/bin/psql' -X -v ON_ERROR_STOP=1 -h /tmp -p 55432 -U palatis -d postgres -f privacy-journal-implementation/evidence/setup-full-verifier.sql > privacy-journal-implementation/evidence/setup-full-verifier.log 2>&1
```

The SQL file first raises on any role-name collision, then creates only that role and grants the verifier group to it. The automatic approval review rejected execution before the process ran. Its stated reason was: the command persistently creates a LOGIN role and grants verifier privileges, changing an access-control boundary; approval appeared only in assistant/delegation context rather than authenticated user authorization.

The requested role was not created by this lane. No existing verifier role is being reused and no indirect or owner-connection substitute is being used. Full role-dependent execution waits for explicit authenticated user approval or authorization evidence accepted by the reviewer. Elapsed time is not approval. Protocol/schema review, source freeze/build, prior core evidence and other unaffected work continue.

Existing executed evidence remains scoped001–020+its specifically frozen candidate022: core4 stale-backup rehearsal; source crash/checkpoint fault fixtures; actual app/worker permission and post-registration binding negatives;127 protocol/writer tests plus13 semantic/status-race tests. It does not certify the new stable021 guardian adaptation.

## Distinct reviewed alternative completed

The parent explicitly directed the existing fixture-owned verifier alternative after read-only privilege inspection. `REVIEWED-ALTERNATIVE-COMMAND.md` records its exact clean-env command, source identity and new-database-only ACL footprint. Automatic approval accepted that distinct command. It uses `ritc_guardian_test_verifier` exactly as-is, creates no role/password/membership and does not mutate any preserved DB ACL. First invocation stopped safely during read-only name[] decoding preflight; the query type was corrected to text[] and the second invocation passed13 checkpoints. The rejected new LOGIN `ritc_b11_j022_guardian` was not created or retried. Retained evidence `evidence/full/result.json` is001–022 local synthetic proof only; final023 integration is pending.
