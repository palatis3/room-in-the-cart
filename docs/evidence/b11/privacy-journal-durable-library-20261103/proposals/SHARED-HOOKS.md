# Shared hooks proposed for root review; not installed

This proposal accompanies the scratch option A library. It does not configure a provider, change runtime availability, install SQL, create a role, grant membership, select remote storage, or enable erasure. Existing `createRuntime` continues constructing `PrivacyService(repository)` without a deletion provider, numeric policy or journal.

## Existing authorization and commit order must remain

Retain `recent(identity)`, the live exact provider-session assertion, configured deletion provider/policy/journal/authenticated-method checks, provider availability check, and the SQL adult/household/guardian/revision/disposition gates in their current order. The SQL-produced immutable acceptance event remains the only `beforeCommit` input. No caller-supplied target JSON, new endpoint, or remote signing endpoint is added.

The trusted service must await a durable intent and independent admitted head, then check the still-current request signal/deadline immediately before starting COMMIT. Only after actual SQL COMMIT does `afterCommit(eventId)` perform a private committed-source lookup, publish the committed observation/head, validate its independently signed receipt and acknowledge its exact immutable commit sequence/hash. Existing status-capability validation must continue preceding any status reconciliation. Worker eligibility stays SQL-gated on journal acknowledgements. The scheduled handler stays cleanup-only.

## Call context / cancellation hook

Current `privacy.ts` uses a five-second `Promise.race` around an already-started journal Promise. That does not propagate cancellation. Proposed integration passes a caller-owned context (`attemptId`, absolute `deadlineUnixMs`, `AbortSignal`) to the new library and lets the adapter compose/propagate its deadline to every transport/source phase. The service also checks cancellation before initiating COMMIT. A disconnected request must be represented by a server-created signal, never a client Boolean/header claiming cancellation or authority.

The exact library method signatures are in its dedicated contract file. A later reviewed patch can extend the existing port call context or explicitly adapt the new port at the trusted service boundary; the local fsync port must not be silently advertised as cancellable. Do not merely replace one non-canceling race with another. Do not let queueing refresh a deadline.

Already-issued SQL COMMIT or acknowledgement may have completed even when a transport/caller timeout is observed. This remains an uncertain outcome resolved using the original immutable operation/status capability. Under the approved contract, an acknowledgement sent while valid can finish late and permit eligibility after the committed observation/head were durable. No new rule banning eligibility after HTTP timeout is assumed.

## Private committed-source adapter hook

The new library requires one constructor-fixed private source capability. Future implementation must expose only bounded operations:

- Read the registered origin with exact source/deployment identity, lineage, schema/configuration pins and fenced state.
- Read one committed event by exact event UUID, rejecting a different returned UUID or changed digest.
- Read the original committed acceptance for the exact job, uniquely kind `acceptance`, for strict progress validation before any object is persisted.
- Enumerate a bounded, dependency-ordered set of unacknowledged event IDs for one exact job; any pagination/order changes require tests and a fixed total work budget.
- Acknowledge only the exact event/digest and admitted commit sequence/hash after independent receipt validation at the trusted Node boundary.

Current migration022 gives neither app nor worker raw access to origin/outbox/ack tables. Preserve that. The existing four-argument SQL acknowledgement validates immutable event/digest and exact replay identity; it does **not** validate an external authority signature. Any additional trust boundary in a source implementation must repeat receipt validation rather than treating the supplied receipt as a SQL guarantee.

A restricted observer implementation and any necessary owner-defined SQL read helpers/grants require separate root review. This proposal does not provision a LOGIN, password, role membership, broad SELECT privilege, app/worker owner inheritance, or owner pool in the ordinary runtime.

The installed `pg` query interface does not accept an AbortSignal in the currently inspected query path. Passing an ignored `signal` property is not cancellation. A future PostgreSQL adapter must demonstrate its actual cancellation/timeout behavior, dedicated connection lifecycle and uncertainty handling; the current library's injected source contract cannot prove that on its own.

The source implementation must recheck cancellation after asynchronous pool acquisition and immediately before actual SQL dispatch. Invoking `source.acknowledge` before abort does not authorize a query that only starts afterward. Only SQL already dispatched while the call was valid has the approved late-completion semantics. An abandoned connection-acquisition attempt must release any eventual unused connection without dispatching a query.

## Optional shared-schema reuse

The candidate already imports the current `journalCanonical`, `journalHash` and `validatePrivacyRestoreEvents`. Existing v1 event/head/record envelope schemas and `validateEvent` are private, so the candidate duplicates their strict envelope shapes. A later narrow export of pure event/record parsers could remove that duplication. This is a maintenance improvement, not a prerequisite for installing the unused library. A per-record parser must not be described as proving full-chain dependencies or a fenced export; those remain the existing full verifier's responsibility. No such export is included or applied in this patch.

## Remote authority and recovery dependencies

The ordinary writer uses mandatory constructor-fixed immutable-record, checkpoint-authority and durable uncertainty interfaces. Their implementation must provide authenticated transport, strongly consistent persistent state and atomic generation/head/operation transitions. Local in-memory fixtures exercise the real client library but do not establish those infrastructure guarantees.

A non-expiring uncertainty claim must outlive process loss and prevent a fresh ordinary writer from silently resetting uncertain work. Completion is allowed only after the required durable authenticated outcome; a lost completion response cannot invalidate an already-proven safe outcome. Operator reconciliation, generation fencing, source fencing, rollback/seal and key/retention administration are separate capabilities. They are not added to the ordinary writer or auto-invoked by construction.

The eventual receipt/head protocol and helper names must be reviewed against the final candidate, not inferred from this integration proposal. No activation should occur solely because library unit tests pass.
