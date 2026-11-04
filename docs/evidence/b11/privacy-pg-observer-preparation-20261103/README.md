# Paused: PostgreSQL committed-source candidate

The current bounded task is complete and saved in scratch. **Not installed, composed, activated or deployed.** Parent owns review, shared-file installation and Git. No further work is scheduled by this lane.

Reviewable patch: `postgres-source-candidate.patch` (four new files only).

SHA-256: `88a27c12f83ddbf3f379c8133f8fba3a19856a04be6633836a8531762deacf90`.

Exact source/compiled/test/SQL identities: `MANIFEST.json` and `evidence/second-candidate-sha256.txt`. Baseline HEAD is `8d607950a64a38a05293f8343ba59b49a2261000`; parent caller-context edits are outside this frozen baseline and need separate combined integration.

## Verified scope

- Full strict TypeScript compile and independent review passed.
- Real local PostgreSQL17.11 / pg8.23.1 / Node22.14.0: **11/11 tests, zero skips**, 3031.973708ms.
- Exact source/event/original acceptance, bounded job list, independently authenticated receipt, effective role/ACL drift, real pool-wait cancellation, blocked SQL rollback and actual late-COMMIT uncertainty/retry verified.
- `evidence/postgres-source-second.tap` is the passing evidence; failed initial/diagnostic logs are retained.
- `review/INDEPENDENT-REVIEW.md` found no remaining concrete candidate blocker.

## Local role/database/process handoff

Used unchanged existing `ritc_guardian_test_verifier` OID67144, LOGIN/INHERIT, no privileged flags, member only of `ritc_guardian_verifier`. Only newly owned disposable databases received CONNECT/schema/five-wrapper grants and stricter inherited/PUBLIC ACL revocations. No LOGIN/password/membership/cluster-role/old-database mutation.

The runner removed both new databases and verified unchanged nonsecret role/membership snapshots. Final read-only inventory found zero databases under `ritc_journal_pg_source_` or `ritc_journal_pg_wrong_`. **Exact generated database names/OIDs were not retained before cleanup**; this evidence limitation is explicit, with no new run performed during winddown. See `evidence/postgres-runtime-observations.json` and `evidence/POSTGRES-SOURCE-HANDOFF.md`.

All three workers (source, SQL/tests, independent review) completed. All owned test/compile processes exited; no owned database client/test server remains. Shared PostgreSQL is not ours to stop and was left running. Android remains closed; no native/device/account/provider action occurred in this task.

## Remaining integration / activation boundaries

Parent review and explicit installation of the four-file patch remain. Narrow caller hooks are proposed in `review/CALLER-HOOK-PROPOSAL.md`; root HTTP/PrivacyService/PrivacyCall edits were not modified here. Candidate024 has no observer grants, source registration or default runtime enablement.

Existing deployments require separate effective-ACL/observer provisioning review: four legacy trigger helpers retain PUBLIC EXECUTE, which the strict source guard rejects. The fixture revoked those only in its own disposable databases. No automatic live remediation is proposed by this patch.

Remote immutable records/checkpoint authority/uncertainty persistence, real deployment credentials and operational activation remain unproved and disabled. Fixture keys/receipts are synthetic; PostgreSQL connections, SQL permissions, transaction commits and cancellation observations are real. An already dispatched COMMIT remains uncertain after cancellation and cannot be claimed rolled back.
