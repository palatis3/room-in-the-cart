# Independent PostgreSQL source review

Verdict: no remaining concrete blocker found in the frozen scratch PostgreSQL source and proposed migration 024. The candidate remains uninstalled and uncomposed. This review does not approve production activation or establish remote journal durability.

Review baseline: `/Users/palatis/Room in the Cart`, reported HEAD `8d607950a64a38a05293f8343ba59b49a2261000`. The reviewer read that repository without changing it, inspected the scratch source, SQL, runner and actual test evidence, and ran independent TypeScript checks. The reviewer changed only this report; no database, role, credential, membership, provider, deployment, native application or Git operation was performed. The reviewer has no running background process.

## Frozen identities

The final actual PostgreSQL run is bound by `evidence/second-candidate-sha256.txt`:

| File | SHA-256 |
| --- | --- |
| `service/src/privacy-journal-pg-source.ts` | `286a3cde6bb711b38dc9f0473d23c96e28fdaae6e4c4ed1222ffc150723337a6` |
| `service/dist/privacy-journal-pg-source.js` | `bd4a7436e1a0184ee201eb0b9fbc5fbc8db2593620cbfbdd0b1747cc58054fcb` |
| `service/migrations/024_privacy_journal_source.sql` | `cba685feb94dd472069dc0435b17cabc570376eded8994c9536b7c6af2ab26eb` |
| `service/tests/privacy-journal-pg-source.integration.mjs` | `148ce970bc50ca0bbe9076332dd6637513c15a8e52df143c5db55879eceda07e` |
| `service/scripts/test-privacy-journal-pg-source.mjs` | `ee0aee0742296b4c305617352ea9ca6baacff12592f12e8014d06b2860e9fb7c` |

## Findings resolved during review

- The initial SQL guard checked fewer effective capabilities than the checkout guard. The final guard repeats the checks inside every wrapper using the explicit session actor OID. It rejects switched role state, reachable privileged/app/worker/owner roles, database CREATE/TEMP and ownership, schema creation/ownership, raw table/column/sequence rights, function ownership and extra effective function execution across user schemas. A grant made while a wrapper waits after checkout is rejected when execution resumes. `SECURITY DEFINER` changes `current_user`; the guard correctly uses `session_user` and the role setting instead.
- The SQL namespace filter now uses literal `^pg_`, avoiding the underscore wildcard in `LIKE 'pg_%'`. A synthetic function in schema `pga` is a regression case. The expected wrappers must retain their trusted owner, definer mode, fixed search path and observer grant, with no PUBLIC/app/worker execution. All five wrappers reject direct column grants, extra execution and source-wrapper PUBLIC/app/worker ACL drift.
- The registration table has an explicit owner RLS policy. Every new function explicitly revokes PUBLIC/app/worker access; migration 024 creates no login, membership, observer grant or registered source.
- The first connection draft allowed ambient pg credential/options fallback. The final private configuration fixes endpoint, login, password callback, options, encoding, TLS negotiation and replication mode. Remote connections require pinned TLS. It fixes a private pure JavaScript Client and disables pipelining; ambient native forcing fails closed. This preserves the reviewed installed `pg` 8.23.1 socket-destruction path. The pure JavaScript driver does not use the ambient `PGBINARY` value for query mode.
- Source methods now consistently return promises. The queued-abort test was corrected to expect destruction of the eventually acquired client, rather than retention of its backend.

## Source and admission boundary

Constructor pins and connection configuration are captured privately. Database name/OID, actual session/current role and role OID, trusted function owner and registered source/origin pins are checked. Each SQL wrapper independently repeats source, database, actor, capability, origin and fence checks. The origin SHARE lock serializes the wrapper transaction with a monotonic source fence.

Event reads resolve exact committed immutable outbox rows, validate envelope fields and canonical payload digest, and reject oversized content. Original acceptance comes from the immutable acceptance event, not mutable job fields. Job enumeration requires an existing acceptance, uses an explicit acceptance-first then creation-time/event-ID order, and checks a bounded `n+1` result before returning any list.

Acknowledgement independently authenticates the strict admission receipt before pool acquisition. It binds commit transition, event, digest, sequence, record hash and exact committed job, validates content against the original acceptance, then repeats receipt verification after the awaited SQL timeout budget and immediately before dispatch. Existing SQL digest/conflict/idempotency checks remain. The durable client separately requires exact stored bytes, original admitted acceptance and current admitted coverage before invoking this source; the current client was reviewed read-only.

## Actual cancellation and uncertainty evidence

`evidence/postgres-source-second.tap` records **11/11 passed**, zero failures/cancellations/skips. The reviewed tests use actual local PostgreSQL connections and the compiled source. They cover committed visibility, fixed source/database/role pins, persisted envelope/digest/size failures, denied capabilities, concurrent grants after checkout, forged receipt rejection before SQL, exact acknowledgement retries, and cancellation.

The cancellation cases inspect actual `pg_stat_activity` lock waits and backend disappearance. Preaborted/expired calls create no backend. A canceled pool waiter dispatches no later SQL and destroys its eventual client. A blocked read rejects promptly, its backend disappears within the SQL bound, and a fresh connection succeeds. A canceled blocked acknowledgement does not commit after unblock. An automatic deadline leaves neither acknowledgement nor idle transaction. A deferred trigger pauses a real COMMIT; losing its response reports uncertainty, the already-issued acknowledgement commits, and an exact retry retains its original identity.

The adapter checks the owned deadline/signal after asynchronous acquisition and immediately before every actual query, including BEGIN, budget/configuration, guards, wrappers and COMMIT. Startup statement/lock/idle timeouts already bound initial BEGIN; per-call budgets tighten those limits. Abort calls `release(true)` on the fixed non-pipeline client, destroying its active connection. It does not enqueue rollback behind blocked work or rely on ignored `query.signal`/client-only timeout behavior.

Socket destruction is not proof of instantaneous server cancellation. A blocked backend can remain until the server timeout detects the disconnected client. Pending pool acquisition is not itself cancellable by pg; the call rejects promptly, while the fixed five-second connection timeout and eventual-client destruction bound cleanup. An already-issued COMMIT may have succeeded. The uncertainty flag is set before real acknowledgement COMMIT dispatch, and no later dispatch starts after abort. Approved safe late acknowledgement after genuine durable proof remains permitted; no new rule forbidding worker eligibility after HTTP timeout was added.

Independent validation used the existing Node v22.14.0/TypeScript toolchain:

```text
tsc --noEmit -p service/tsconfig.json: exit 0
targeted strict ES2022/NodeNext/noUncheckedIndexedAccess/exactOptionalPropertyTypes check: exit 0
```

The reviewer inspected the final 11-case PostgreSQL result rather than starting a second database mutation run. The runner reports unchanged cluster roles/memberships and removal of both disposable databases. Its role inventory excludes credentials, and its code contains no role/password/membership mutation. Fixture-only grants and revocations are confined to the newly owned databases.

## Activation prerequisites and limits

The first real fixture correctly failed closed on legacy PUBLIC-executable trigger helpers. The successful fixture revoked extra function privileges only in its disposable databases before granting the five wrappers to the unchanged existing observer login. An existing deployment must receive a separate effective-ACL review and explicit narrowly scoped remediation before availability. Migration 024 alone neither provisions that observer nor repairs existing ACLs. The existing guardian group membership was acceptable only because it had no effective extra powers in those isolated databases; its rights elsewhere were not changed.

Authority receipts, event content and keys in this fixture are synthetic, with private keys held only in memory. Real PostgreSQL admission verification and failure behavior are proved here; real immutable storage, independent remote authority/uncertainty persistence, physical restart/recovery and remote latency are not. This report does not review the parent's final HTTP/caller-context implementation. No runtime composition, production source registration, live migration, provider activation or deployment occurred in this reviewer task.
