# Exact existing-verifier alternative command — prepared, not executed

Executable argv (no ambient credentials, role creation or membership operation):

```sh
/Users/palatis/Documents/Codex/2026-11-03/task-2/privacy-journal-implementation/evidence/run-full-reviewed-alternative.sh
```

That script changes to `.../privacy-journal-implementation/full/service` and executes:

```sh
/usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C LANG=C '/Users/palatis/Room in the Cart/.tools/node-v22.14.0-darwin-arm64/bin/node' scripts/journal-full-drill-existing-verifier.mjs > ../../evidence/full-drill.log 2>&1
```

The clean environment removes every inherited PG* option/service/SSL/credential setting and connection URL from Node and its pg_dump/restore children. All pools use explicit `/tmp:55432`, password callback returning empty fixture password, database/user fields, and no inherited PostgreSQL URL/options. Owner is `palatis`, app/worker are existing approved `ritc_b11_j022_app`/`ritc_b11_j022_worker`, proof login is existing `ritc_guardian_test_verifier` exactly as-is. No CREATE/ALTER ROLE, password or membership SQL is in the harness. Frozen migrations retain their reviewed existing base-group IF-NOT-EXISTS declarations; preflight requires all groups/fixture roles already present and aborts mismatches rather than repairing them.

New DBs only: `ritc_b11_j022_src_20261103` and `ritc_b11_j022_restore_20261103`, collision checked, template0, owner palatis. ACL footprint only on those new DBs: REVOKE PUBLIC CONNECT; GRANT CONNECT to the three exact existing app/worker/proof fixture logins. No preserved/other database ACL changes. No role/credential/membership change. PUBLIC/inherited behavior elsewhere is not claimed denied.

Preflight confirms existing proof role LOGIN, verifier membership exactly, no app/worker/superuser/BYPASSRLS/CREATEDB/CREATEROLE/REPLICATION. Post-migration actual proof connection checks `current_user=session_user`, no owner-role membership over DB/schema/tables, same negative privilege flags and no app/worker. Actual private journal/plan/receipt/context SELECT and private helper EXECUTE denials are exercised alongside app/worker. Source and restore client pools/HTTP servers are closed; DBs/dumps/journal/manifests retained.

The local synthetic sequence is backup-before-acceptance, real fixture guardian enrollment/provider-signature/child-email-bound consent/native sign-in/pairing activation, actual journal-aware privacy HTTP acceptance and stub provider erasure, fenced head, owned quarantined restore, exact owner plan/full leased eraser+atomic receipts, negative scopes/preimages/permissions and retained-other-data probes. No real external email/provider, deployment, remote migration, production policy or scheduled erasure.

Pinned candidate hashes:

| File | SHA256 |
|---|---|
|staging/service/src/privacy-journal.ts|`5bc1944554aa6057805b087bd77adad128aff795458d8a17eb30ddda213f8c1c`|
|staging/service/src/privacy.ts|`723670077537ff014e7137b213cd6876579996577842baa9bf1c223f8b048f17`|
|staging/service/migrations/022_privacy_journal.sql|`d64716764dd1e9b1131c7aab53faa1e67cf518875011271452ee0120d4ead5cb`|
|full/service/scripts/journal-full-drill-existing-verifier.mjs|`35c933ab9d9cda2c5db03c7fba6fbf9fce3e1883064d9b5c1cc00deeef126261`|
|evidence/run-full-reviewed-alternative.sh|`0b2a51d444d4797a6b8a0d969873b9a3a30afcf3f450317c6dfc824d989e0ffc`|
|stable021|`73e33d596776a1874aeb4715b16abed3f18829d1415ed6b0dd2799e356df4c04`|

Readiness: command/harness prepared and unexecuted. Scratch auth.ts has been refreshed from owner-approved live SHA256 `1ada4617b38cae94985a7ee39ec4b973f38737f7e96111e1f00d837c40b4538e`; current full candidate compiles clean. Frozen 114-file backend/shared manifest `evidence/full-001-022-source-freeze.json` SHA256 `b4b6c4aea838aae20fb9eb8c69a7b4fba004ca79f2bbdfafef6e82dc54d85cbc`, source archive SHA256 `4a2351298deb257fe104728ec83932d9fe00be779cd87ad3fecbe7aff185f44b`; old initial manifest retained separately. Parent/reviewer must approve this exact alternative separately from the rejected new LOGIN-role operation. No approval is inferred from elapsed time. A later stable023 integration remains a separately required final drill; this command stages only001–022.

Reviewer P1 addressed in current022: an exact signed browser after-image may clear email_cipher only when email_present=false; secret presence/binding changes or reconstruction reject. Existing021 guards remain. The prepared drill includes real pending challenge, wrong preimage and app/worker helper-denial negatives. The tentative newline-escaping concern was retracted; no query change was made, and a real residual matching credential negative is added.

Attempt1 passed automatic command review and stopped before DB creation on node-postgres name[] result decoding; exact verifier membership was correct. Harness query now casts membership names to text[] for exact array comparison; role predicate/privileges unchanged. Initial log retained as evidence/full-drill-attempt1-preflight-name-array.log.
